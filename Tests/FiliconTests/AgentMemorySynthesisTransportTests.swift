import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private actor SynthesisTransportProbe {
    var requests: [InferenceRequest] = []
    let entered = AsyncStream<Void>.makeStream()
    func record(_ request: InferenceRequest) { requests.append(request); entered.continuation.yield(()) }
    func wait() async { for await _ in entered.stream { return } }
}
private struct SynthesisTransportProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "synthesis-test", displayName: "Fixture", requiresAPIKey: false)
    let probe: SynthesisTransportProbe
    let events: [InferenceEvent]
    var before: @Sendable () async throws -> Void = {}
    func models() async throws -> [AIModel] { [.init(id: "model")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await probe.record(request); try await before()
                    for event in events { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Memory synthesis transport", .timeLimit(.minutes(1)))
struct AgentMemorySynthesisTransportTests {
    private let session = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func fixture() async throws -> (URL, AgentService, AgentProfile) {
        let root = FileManager.default.temporaryDirectory.appending(path: "synthesis-transport-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let profile = try await agents.create(name: "Owner", instructions: "PRIVATE_PERSONA_DO_NOT_SEND",
            providerID: "synthesis-test", modelID: "model", at: Date(timeIntervalSince1970: 100))
        return (root, agents, profile)
    }

    @Test func stagesUseOnlyFreshInstructionsAndPayloadWithoutTools() async throws {
        let (root, agents, profile) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe()
        await registry.register(SynthesisTransportProvider(probe: probe, events: [.textDelta("{}"), .completed(.stop)]))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init())
        for (stage, instructions, payload) in [(AgentMemorySynthesisStage.proposal, "propose", "evidence"), (.verification, "verify", "proposal and evidence")] {
            let result = try await transport.execute(stage: stage, instructions: instructions, payload: payload,
                profile: profile, sessionID: session, lifetime: .init())
            expectNoDifference(result, "{}")
        }
        let requests = await probe.requests
        expectNoDifference(requests.count, 2)
        expectNoDifference(requests.map { $0.messages.map(\.text) }, [["propose", "evidence"], ["verify", "proposal and evidence"]])
        for request in requests {
            expectNoDifference(request.tools, [])
            expectNoDifference(request.toolExchanges, [])
            expectNoDifference(request.attachmentsByMessageID, [:])
            expectNoDifference(request.reasoningEffort, .disabled)
            expectNoDifference(request.messages.map(\.role), [.system, .user])
            #expect(!String(describing: request).contains("PRIVATE_PERSONA_DO_NOT_SEND"))
        }
    }

    @Test(arguments: ["missing-stop", "length", "tool", "after-stop", "over-limit", "cancel", "changed-model", "timeout"])
    func invalidOrInterruptedStreamDoesNotReturnText(mode: String) async throws {
        let (root, agents, profile) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe(), lifetime = AgentMemorySuggestionLifetime()
        var events: [InferenceEvent] = [.textDelta(#"{"approved":true}"#), .completed(.stop)]
        switch mode {
        case "missing-stop": events = [.textDelta("{}")]
        case "length": events = [.textDelta("{}"), .completed(.length)]
        case "tool": events = [.toolCallStarted(id: "unexpected", name: "write_file")]
        case "after-stop": events.append(.textDelta("late"))
        case "over-limit": events = [.textDelta(String(repeating: "字", count: 342)), .completed(.stop)]
        default: break
        }
        await registry.register(SynthesisTransportProvider(probe: probe, events: events, before: {
            if mode == "cancel" { lifetime.close() }
            if mode == "changed-model" {
                var changed = profile; changed.modelID = "other"
                try await agents.update(changed)
            }
            if mode == "timeout" { try await Task.sleep(for: .seconds(30)) }
        }))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init(),
            timeout: mode == "timeout" ? .milliseconds(20) : .seconds(5))
        await #expect(throws: (any Error).self) {
            try await transport.execute(stage: .verification, instructions: "verify", payload: "{}",
                profile: profile, sessionID: session, lifetime: lifetime)
        }
        let memories = await agents.memories(accountID: "local", agentID: profile.id)
        expectNoDifference(memories, [])
    }

    @Test func explicitCancellationClosesLifetimeAndStopsTransport() async throws {
        let (root, agents, profile) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe(), lifetime = AgentMemorySuggestionLifetime()
        await registry.register(SynthesisTransportProvider(probe: probe, events: [], before: { try await Task.sleep(for: .seconds(30)) }))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init())
        let task = Task { try await transport.execute(stage: .proposal, instructions: "propose", payload: "{}",
            profile: profile, sessionID: session, lifetime: lifetime) }
        await probe.wait()
        await transport.cancel(sessionID: session, lifetime: lifetime)
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(throws: CancellationError.self) { try lifetime.check() }
    }
}
