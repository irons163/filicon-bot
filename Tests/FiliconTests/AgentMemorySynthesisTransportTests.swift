import Foundation
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
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
    var synthesisStages = false
    var episodeStages = false
    var before: @Sendable () async throws -> Void = {}
    func models() async throws -> [AIModel] { [.init(id: "model")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await probe.record(request); try await before()
                    let selected: [InferenceEvent]
                    if synthesisStages {
                        let object = try? JSONSerialization.jsonObject(with: Data((request.messages.last?.text ?? "").utf8)) as? [String: Any]
                        let evidenceID = (object?["evidence"] as? [[String: Any]])?.first?["id"] as? String ?? "turn"
                        let text = request.messages.first?.text.contains("Maintain compact") == true
                            ? #"{"changes":[{"action":"create","content":"Prefers short answers","kind":"profile","sourceEvidenceIds":["\#(evidenceID)"]}]}"#
                            : #"{"approved":true}"#
                        selected = [.textDelta(text), .completed(.stop)]
                    } else if episodeStages {
                        let text = request.messages.first?.text.hasPrefix("Summarize") == true
                            ? "Agreed to build keyboard navigation." : #"{"approved":true}"#
                        selected = [.textDelta(text), .completed(.stop)]
                    } else { selected = events }
                    for event in selected { continuation.yield(event) }
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

    @Test(arguments: [false, true])
    func episodeTransportIsToolFreeAndTimeoutConsumesBatch(timeout: Bool) async throws {
        let (root, agents, profile) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await agents.memoryEpisodeSettings(accountID: "local", agentID: profile.id)
        try await agents.setMemoryEpisodesEnabled(true, expected: initial, lifetime: .init())
        let settings = try await agents.memoryEpisodeSettings(accountID: "local", agentID: profile.id)
        for n in 1...6 {
            try await agents.recordMemoryEpisode(settings: settings, originID: session,
                exchangeID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                at: .init(timeIntervalSince1970: 1_900_000_000), user: "Build keyboard navigation", assistant: "Agreed", lifetime: .init())
        }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe()
        await registry.register(SynthesisTransportProvider(probe: probe, events: [], episodeStages: true, before: {
            if timeout { try await Task.sleep(for: .seconds(10)) }
        }))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init(),
                                                      attemptTimeout: timeout ? .milliseconds(20) : .seconds(10))
        var failed = false
        do {
            let result = try await transport.runEpisode(settings: settings, originID: session, profile: profile,
                                                        sessionID: session, lifetime: .init())
            expectNoDifference(result, .committed)
        } catch { failed = true }
        expectNoDifference(failed, timeout)
        let requests = await probe.requests
        if !timeout { expectNoDifference(requests.count, 2) }
        for request in requests {
            #expect(request.tools.isEmpty)
            expectNoDifference(request.messages.count, 2)
            #expect(!request.messages.contains { $0.text.contains("PRIVATE_PERSONA_DO_NOT_SEND") })
        }
        let progress = try await agents.memoryEpisodeProgress(settings: settings, originID: session)
        expectNoDifference(progress?.turns.count, 0)
    }

    @Test(arguments: ["enabled", "disabled", "stop", "parent", "unprepared", "pass", "synthesis", "cleanup-failed"])
    func foregroundEpisodesAccumulateAcrossSessionsOnlyWithConsent(mode: String) async throws {
        let (root, agents, profile) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe()
        let initial = try await agents.memoryEpisodeSettings(accountID: "local", agentID: profile.id)
        if mode != "disabled" { try await agents.setMemoryEpisodesEnabled(true, expected: initial, lifetime: .init()) }
        if mode == "synthesis" {
            let synthesis = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
            try await agents.setMemorySynthesisEnabled(true, expected: synthesis, lifetime: .init())
        }
        await registry.register(SynthesisTransportProvider(probe: probe, events: [],
            synthesisStages: mode == "synthesis", episodeStages: mode != "synthesis"))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init())
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "messages.json"))
        for n in 1...6 {
            let parent = AgentMemorySuggestionLifetime()
            let messaging = AgentMessagingSession(originConversationID: session, agents: agents, messenger: messenger,
                registry: registry, coordinator: TurnCoordinator(registry: registry), memorySynthesis: transport,
                memorySynthesisLifetime: parent, memoryEpisodeReady: {
                    if mode == "cleanup-failed" { throw AgentMemorySuggestionError.stale }
                })
            if mode != "unprepared" {
                await messaging.prepareMemorySuggestion(profile: profile,
                    exchangeID: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!,
                    user: "Build keyboard navigation")
            }
            await messaging.remember(agentID: profile.id, messages: [], response: mode == "pass" ? "PASS" : "Agreed")
            if mode == "stop" { messaging.revokeProfileChanges() }
            if mode == "parent" { parent.close() }
            await messaging.suggestMemories()
            await messaging.suggestMemories()
            try await messaging.close(preservingMemorySynthesis: true)
        }
        let memories = await agents.memories(accountID: "local", agentID: profile.id)
        expectNoDifference(memories.filter { $0.origin == .episode }.count, mode == "enabled" ? 1 : 0)
        let requests = await probe.requests
        if mode != "synthesis" { expectNoDifference(requests.count, mode == "enabled" ? 2 : 0) }
        if mode == "synthesis" { #expect(!requests.contains { $0.messages.first?.text.hasPrefix("Summarize") == true }) }
    }

    @Test(arguments: ["enabled", "disabled", "unprepared", "pass", "revoked", "disabled-after-prepare"])
    func foregroundSessionSynthesizesOnlyPreparedCompletedOptedInExchanges(mode: String) async throws {
        let (root, agents, profile) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe()
        let initial = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
        if mode != "disabled" { try await agents.setMemorySynthesisEnabled(true, expected: initial, lifetime: .init()) }
        await registry.register(SynthesisTransportProvider(probe: probe, events: [], synthesisStages: true))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init())
        let messaging = AgentMessagingSession(id: session, originConversationID: session, agents: agents,
            messenger: try AgentMessenger(service: agents, storeURL: root.appending(path: "messages.json")), registry: registry,
            coordinator: TurnCoordinator(registry: registry), memorySynthesis: transport)
        if mode != "unprepared" {
            await messaging.prepareMemorySuggestion(profile: profile, exchangeID: session, user: "I prefer short answers")
        }
        await messaging.remember(agentID: profile.id, messages: [], response: mode == "pass" ? "PASS" : "Understood")
        if mode == "revoked" { messaging.revokeProfileChanges() }
        if mode == "disabled-after-prepare" {
            let current = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
            try await agents.setMemorySynthesisEnabled(false, expected: current, lifetime: .init())
        }
        await messaging.suggestMemories()
        await messaging.suggestMemories() // Settled exchanges are consumed once.
        let memories = await agents.memories(accountID: "local", agentID: profile.id)
        expectNoDifference(memories.map(\.fact), mode == "enabled" ? ["Prefers short answers"] : [])
        let requests = await probe.requests
        expectNoDifference(requests.count, mode == "enabled" ? 2 : 0)
        let pending = await messaging.hasMemorySuggestionsToProcess
        expectNoDifference(pending, false)
        try await messaging.close()
    }

    @Test(arguments: ["disabled", "enabled", "disable-proposal", "disable-verification", "disable-reenable"])
    func consentFencesRealTransportAndPersistence(mode: String) async throws {
        let (root, agents, profile) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe()
        let initial = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
        expectNoDifference(initial.enabled, false)
        // Existing suggestion opt-in must not enable automatic rewriting.
        let suggestions = try await agents.memorySuggestions(accountID: "local", agentID: profile.id)
        try await agents.setMemorySuggestionsEnabled(true, expected: suggestions.settings, lifetime: .init())
        let stillDisabled = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
        expectNoDifference(stillDisabled, initial)
        if mode != "disabled" { try await agents.setMemorySynthesisEnabled(true, expected: initial, lifetime: .init()) }
        let settings = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
        await registry.register(SynthesisTransportProvider(probe: probe, events: [], synthesisStages: true, before: {
            let count = await probe.requests.count
            if (mode == "disable-proposal" || mode == "disable-reenable") && count == 1 || mode == "disable-verification" && count == 2 {
                try await agents.setMemorySynthesisEnabled(false, expected: settings, lifetime: .init())
                if mode == "disable-reenable" {
                    let disabled = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
                    try await agents.setMemorySynthesisEnabled(true, expected: disabled, lifetime: .init())
                }
            }
        }))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: .init())
        let date = Date(timeIntervalSince1970: 1_000)
        let run = {
            try await transport.run(settings: settings,
                evidence: [.init(id: "turn", occurredAt: date, user: "I prefer short answers", assistant: "Understood")],
                at: date, profile: profile, sessionID: session, lifetime: .init())
        }
        if mode == "enabled" {
            let result = try await run(); expectNoDifference(result, .committed)
        } else { await #expect(throws: (any Error).self) { try await run() } }
        let memories = await agents.memories(accountID: "local", agentID: profile.id)
        expectNoDifference(memories.map(\.fact), mode == "enabled" ? ["Prefers short answers"] : [])
        expectNoDifference(memories.map(\.origin), mode == "enabled" ? [.synthesis] : [])
        let requests = await probe.requests
        expectNoDifference(requests.count, mode == "disabled" ? 0 : ["enabled", "disable-verification"].contains(mode) ? 2 : 1)
        let other = try await agents.memorySynthesisSettings(accountID: "other", agentID: profile.id)
        expectNoDifference(other.enabled, false)
        if mode == "enabled" {
            let reopened = try AgentService(storeURL: root.appending(path: "agents.json"))
            let restored = try await reopened.memorySynthesisSettings(accountID: "local", agentID: profile.id)
            expectNoDifference(restored, settings)
            let restoredMemories = await reopened.memories(accountID: "local", agentID: profile.id)
            expectNoDifference(restoredMemories, memories)
            await #expect(throws: AgentMemorySuggestionError.stale) {
                try await reopened.setMemorySynthesisEnabled(false, expected: initial, lifetime: .init())
            }
        }
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

    @Test func attemptDeadlineIsSharedAndOnlyResetsForANewProposal() async throws {
        let start = ContinuousClock.now
        let budget = MemorySynthesisDeadline(timeout: .seconds(90))
        await #expect(throws: MemorySynthesisTimeout.self) { try await budget.deadline(for: .verification, now: start) }
        let proposal = try await budget.deadline(for: .proposal, now: start)
        let verification = try await budget.deadline(for: .verification, now: start.advanced(by: .seconds(60)))
        expectNoDifference(proposal, start.advanced(by: .seconds(90)))
        expectNoDifference(verification, proposal)
        await #expect(throws: MemorySynthesisTimeout.self) {
            try await budget.deadline(for: .verification, now: start.advanced(by: .seconds(90)))
        }
        let retry = try await budget.deadline(for: .proposal, now: start.advanced(by: .seconds(92)))
        expectNoDifference(retry, start.advanced(by: .seconds(182)))
    }

    @Test(arguments: ["queue", "proposal", "verification"])
    func wholeAttemptTimeoutCancelsQueuedOrStreamingMaintenance(mode: String) async throws {
        let (root, agents, profile) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let registry = ProviderRegistry(), probe = SynthesisTransportProbe(), scheduler = AgentExecutionScheduler()
        let entered = AsyncStream<Void>.makeStream()
        let occupying = Task {
            if mode == "queue" {
                try await scheduler.withExclusiveAccess(agentID: profile.id, lane: .user) {
                    entered.continuation.yield(())
                    try await Task.sleep(for: .seconds(30))
                }
            }
        }
        defer { occupying.cancel() }
        if mode == "queue" { for await _ in entered.stream { break } }
        let initial = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
        try await agents.setMemorySynthesisEnabled(true, expected: initial, lifetime: .init())
        let settings = try await agents.memorySynthesisSettings(accountID: "local", agentID: profile.id)
        await registry.register(SynthesisTransportProvider(probe: probe, events: [], synthesisStages: true, before: {
            let count = await probe.requests.count
            if mode == "proposal" || (mode == "verification" && count.isMultiple(of: 2)) {
                try await Task.sleep(for: .seconds(30))
            }
        }))
        let transport = AgentMemorySynthesisTransport(agents: agents, registry: registry, scheduler: scheduler,
            timeout: .seconds(20), attemptTimeout: .milliseconds(100))
        let date = Date(timeIntervalSince1970: 1_000)
        await #expect(throws: MemorySynthesisTimeout.self) {
            try await transport.run(settings: settings,
                evidence: [.init(id: "turn", occurredAt: date, user: "I prefer short answers", assistant: "Understood")],
                at: date, profile: profile, sessionID: session, lifetime: .init())
        }
        let requests = await probe.requests
        expectNoDifference(requests.count, mode == "queue" ? 0 : mode == "proposal" ? 3 : 6)
        let facts = await agents.memories(accountID: "local", agentID: profile.id)
        expectNoDifference(facts, [])
        // Timeout must cancel only this submission, not another session's lane.
        if mode == "queue" {
            #expect(!occupying.isCancelled)
            let state = await scheduler.snapshot(agentID: profile.id)
            expectNoDifference(state.isActive, true)
            expectNoDifference(state.queuedCount, 0)
        }
        occupying.cancel()
        _ = await occupying.result
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
