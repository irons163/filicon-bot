import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices

private actor ToolEventOrderProbe {
    var pendingSaved = false
    var executed = 0
    var started = 0
    var observed = 0
    func observePending() { observed += 1 }
    func savePending() { pendingSaved = true; started += 1 }
    func execute() {
        expectNoDifference(pendingSaved, true)
        executed += 1
    }
}

private struct OrderedToolProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "ordered", displayName: "Ordered", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
            if request.toolExchanges.isEmpty {
                let call = try NormalizedToolCall(id: "read", name: "read", argumentsJSON: Data("{}".utf8))
                continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                continuation.yield(.toolCallCompleted(call))
                continuation.yield(.completed(.toolUse))
            } else { continuation.yield(.completed(.stop)) }
            continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct OrderedToolExecutor: ToolExecutor {
    let probe: ToolEventOrderProbe
    let parallel: Bool
    var descriptor: ToolDescriptor { .init(name: "read", inputSchema: Data("{\"type\":\"object\"}".utf8), parallelSafe: parallel) }
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await probe.execute()
        return .init(callID: call.id, content: [.text("done")])
    }
}

private struct OrderedInteractiveProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "ordered", displayName: "Interactive", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { OrderedToolProvider().stream(request) }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    _ = try await executeTool(.init(id: "read", name: "read", argumentsJSON: Data("{}".utf8)))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Tool event ordering", .timeLimit(.minutes(1)))
struct ToolEventOrderingTests {
    @Test(arguments: [false, true], ["sequential", "parallel", "interactive"])
    func executorWaitsForHostPendingSave(failSave: Bool, path: String) async throws {
        let probe = ToolEventOrderProbe()
        let registry = ProviderRegistry()
        if path == "interactive" { await registry.register(OrderedInteractiveProvider()) }
        else { await registry.register(OrderedToolProvider()) }
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog([OrderedToolExecutor(probe: probe, parallel: path == "parallel")]))
        do {
            try await coordinator.send(request: .init(conversationID: UUID(), modelID: "test", messages: []), providerID: "ordered") { event in
                if case .toolCallStarted = event {
                    await probe.observePending()
                    // Simulate a slow durable host write. Execution may not
                    // overtake this callback, even when the provider is fast.
                    try await Task.sleep(for: .milliseconds(50))
                    if failSave { throw CocoaError(.fileWriteUnknown) }
                    await probe.savePending()
                }
            }
            #expect(!failSave)
        } catch { #expect(failSave) }
        let executions = await probe.executed
        let starts = await probe.started
        let observations = await probe.observed
        expectNoDifference(observations, 1)
        expectNoDifference(executions, failSave ? 0 : 1)
        expectNoDifference(starts, failSave ? 0 : 1)
    }
}
