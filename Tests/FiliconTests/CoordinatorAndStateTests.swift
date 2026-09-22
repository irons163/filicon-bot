import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices

private actor CancellationProbe {
    private(set) var starts = 0
    private(set) var cancellations = 0
    private(set) var sendCompletions = 0
    private let startSignal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private let cancellationSignal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var transports: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func started() { starts += 1; startSignal.continuation.yield(()); startSignal.continuation.finish() }
    func cancelled() { cancellations += 1; cancellationSignal.continuation.yield(()); cancellationSignal.continuation.finish() }
    func sendCompleted() { sendCompletions += 1 }
    func waitUntilStarted() async throws {
        for await _ in startSignal.stream { return }
        throw CancellationError()
    }
    func waitUntilCancelled() async throws {
        for await _ in cancellationSignal.stream { return }
        throw CancellationError()
    }
    func holdTransport() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { transports[token] = $0 }
        } onCancel: {
            Task { await self.cancelTransport(token) }
        }
    }
    private func cancelTransport(_ token: UUID) { transports.removeValue(forKey: token)?.resume(throwing: CancellationError()) }
}

private actor ManualGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

    func wait() async {
        if opened { return }
        await withCheckedContinuation {
            waiter = $0
            started.continuation.yield(())
            started.continuation.finish()
        }
    }

    func waitUntilWaiting() async throws {
        for await _ in started.stream { return }
        throw CancellationError()
    }

    func open() {
        opened = true
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
                    try await probe.holdTransport()
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

private actor ToolSchemaProbe {
    private(set) var receivedRequests: [InferenceRequest] = []

    func record(_ request: InferenceRequest) { receivedRequests.append(request) }
}

private struct NoopToolExecutor: ToolExecutor {
    let descriptor = ToolDescriptor(name: "read")

    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        .init(callID: call.id, content: [.text("ok")])
    }
}

private struct NoToolCallingProvider: AIProvider {
    let descriptor = ProviderDescriptor(
        id: "no-tools", displayName: "No tools", requiresAPIKey: false, supportsToolCalling: false
    )
    let probe: ToolSchemaProbe

    func models() async throws -> [AIModel] { [.init(id: "probe")] }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                continuation.yield(.textDelta("ok"))
                continuation.yield(.completed(.stop))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(10),
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
    }
    return await condition()
}

@Test(.timeLimit(.minutes(1))) func cancellingConversationCancelsActiveTransportAndClearsQueuedTurn() async throws {
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
    defer { first.cancel() }
    try await probe.waitUntilStarted()

    let second = Task {
        do { try await coordinator.send(request: request, providerID: "cancellable") { _ in } } catch {}
        await probe.sendCompleted()
    }
    defer { second.cancel() }
    try #require(await waitUntil { await coordinator.queuedCount(conversationID: conversationID) == 1 })
    await coordinator.cancel(conversationID: conversationID)

    await first.value; await second.value
    try await probe.waitUntilCancelled()
    let completions = await probe.sendCompletions, starts = await probe.starts, cancellations = await probe.cancellations
    expectNoDifference(completions, 2)
    expectNoDifference(starts, 1)
    expectNoDifference(cancellations, 1)
    let active = await coordinator.isActive(conversationID: conversationID)
    expectNoDifference(active, false)
}

@Test(.timeLimit(.minutes(1))) func callerCancelledBeforeEnqueueNeverStartsProvider() async throws {
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
    do { try await gate.waitUntilWaiting() }
    catch { send.cancel(); await gate.open(); await send.value; throw error }
    send.cancel()
    await gate.open()

    await send.value
    let completions = await probe.sendCompletions, starts = await probe.starts
    expectNoDifference(completions, 1)
    expectNoDifference(starts, 0)
    let active = await coordinator.isActive(conversationID: conversationID)
    expectNoDifference(active, false)
}

@Test func coordinatorDoesNotInjectToolSchemasIntoProvidersThatOptOut() async throws {
    let probe = ToolSchemaProbe()
    let registry = ProviderRegistry()
    await registry.register(NoToolCallingProvider(probe: probe))
    let executor = NoopToolExecutor()
    let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog([executor]))
    let request = InferenceRequest(conversationID: UUID(), modelID: "probe", messages: [])

    try await coordinator.send(request: request, providerID: "no-tools") { _ in }

    let received = await probe.receivedRequests
    #expect(received.count == 1)
    #expect(received.first?.tools.isEmpty == true)
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
