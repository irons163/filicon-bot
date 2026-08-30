import Foundation
import Testing
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices

private actor CancellationProbe {
    private(set) var starts = 0
    private(set) var cancellations = 0
    private(set) var sendCompletions = 0

    func started() { starts += 1 }
    func cancelled() { cancellations += 1 }
    func sendCompleted() { sendCompletions += 1 }
}

private actor ManualGate {
    private var waiter: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { waiter != nil }

    func wait() async {
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        waiter?.resume()
        waiter = nil
    }
}

private struct CancellableProbeProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "cancellable", displayName: "Cancellable", requiresAPIKey: false)
    let probe: CancellationProbe

    func models() async throws -> [AIModel] { [.init(id: "probe")] }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.started()
                do {
                    try await Task.sleep(for: .seconds(5))
                    continuation.yield(.completed(.stop))
                    continuation.finish()
                } catch {
                    await probe.cancelled()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Test func cancellingConversationCancelsActiveTransportAndClearsQueuedTurn() async throws {
    let probe = CancellationProbe()
    let registry = ProviderRegistry()
    await registry.register(CancellableProbeProvider(probe: probe))
    let coordinator = TurnCoordinator(registry: registry)
    let conversationID = UUID()
    let request = InferenceRequest(conversationID: conversationID, modelID: "probe", messages: [])

    let first = Task {
        do { try await coordinator.send(request: request, providerID: "cancellable") { _ in } } catch {}
        await probe.sendCompleted()
    }
    #expect(await waitUntil { await probe.starts == 1 })

    let second = Task {
        do { try await coordinator.send(request: request, providerID: "cancellable") { _ in } } catch {}
        await probe.sendCompleted()
    }
    #expect(await waitUntil { await coordinator.queuedCount(conversationID: conversationID) == 1 })
    await coordinator.cancel(conversationID: conversationID)

    #expect(await waitUntil { await probe.sendCompletions == 2 })
    #expect(await probe.starts == 1)
    #expect(await probe.cancellations == 1)
    #expect(await coordinator.isActive(conversationID: conversationID) == false)
    first.cancel()
    second.cancel()
}

@Test func callerCancelledBeforeEnqueueNeverStartsProvider() async {
    let probe = CancellationProbe()
    let registry = ProviderRegistry()
    await registry.register(CancellableProbeProvider(probe: probe))
    let coordinator = TurnCoordinator(registry: registry)
    let conversationID = UUID()
    let request = InferenceRequest(conversationID: conversationID, modelID: "probe", messages: [])
    let gate = ManualGate()

    let send = Task {
        await gate.wait()
        do { try await coordinator.send(request: request, providerID: "cancellable") { _ in } } catch {}
        await probe.sendCompleted()
    }
    #expect(await waitUntil { await gate.isWaiting })
    send.cancel()
    await gate.open()

    #expect(await waitUntil { await probe.sendCompletions == 1 })
    #expect(await probe.starts == 0)
    #expect(await coordinator.isActive(conversationID: conversationID) == false)
    send.cancel()
}

@Test func modelRefreshGuardRejectsStaleConversationAndGeneration() {
    var guardState = ModelRefreshGuard()
    let firstID = UUID()
    let secondID = UUID()
    let first = guardState.begin(accountGeneration: 7, conversationID: firstID, providerID: "openai")

    #expect(guardState.accepts(first, accountGeneration: 7, selectedConversationID: firstID, selectedProviderID: "openai"))
    #expect(!guardState.accepts(first, accountGeneration: 8, selectedConversationID: firstID, selectedProviderID: "openai"))
    #expect(!guardState.accepts(first, accountGeneration: 7, selectedConversationID: secondID, selectedProviderID: "anthropic"))

    let newer = guardState.begin(accountGeneration: 7, conversationID: firstID, providerID: "openai")
    #expect(!guardState.accepts(first, accountGeneration: 7, selectedConversationID: firstID, selectedProviderID: "openai"))
    #expect(guardState.accepts(newer, accountGeneration: 7, selectedConversationID: firstID, selectedProviderID: "openai"))
}
