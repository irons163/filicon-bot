import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices

private let completionConversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
private let completionRequest = InferenceRequest(conversationID: completionConversationID, modelID: "fixture", messages: [])

private enum CompletionOutcome: Equatable, Sendable {
    case success, invalidResponse, cancelled
    case provider(ProviderError)
    case unexpected(String)
}

private func completionOutcome(_ body: () async throws -> Void) async -> CompletionOutcome {
    do { try await body(); return .success }
    catch is CancellationError { return .cancelled }
    catch let error as ProviderError {
        return error == .invalidResponse ? .invalidResponse : .provider(error)
    }
    catch { return .unexpected(String(describing: error)) }
}

private actor CompletionEffects: ToolLoopTransactionHook {
    private var executions = 0
    private var records = 0
    func execute() { executions += 1 }
    func persist(step: Int, calls: [NormalizedToolCall], results: [NormalizedToolResult], context: ToolContext) async throws {
        records += 1
    }
    func snapshot() -> [Int] { [executions, records] }
}

private struct CompletionExecutor: ToolExecutor {
    let descriptor = ToolDescriptor(name: "effect")
    let effects: CompletionEffects
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await effects.execute()
        return .init(callID: call.id, content: [.text("HOST_RESULT")])
    }
}

private final class CompletionFixtureProvider: AIProvider, @unchecked Sendable {
    let descriptor = ProviderDescriptor(id: "completion-fixture", displayName: "Fixture", requiresAPIKey: false)
    private let lock = NSLock()
    private var requests = 0
    let events: [InferenceEvent]
    let failure: ProviderError?
    init(events: [InferenceEvent], failure: ProviderError? = nil) {
        self.events = events; self.failure = failure
    }
    var requestCount: Int { lock.withLock { requests } }
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        let first = lock.withLock { requests += 1; return requests == 1 }
        return AsyncThrowingStream { continuation in
            for event in first ? events : [.completed(.stop), .usage(.init(inputTokens: 1, outputTokens: 0))] { continuation.yield(event) }
            if first, let failure { continuation.finish(throwing: failure) }
            else { continuation.finish() }
        }
    }
}

private struct CompletionInteractiveProvider: InteractiveToolProvider {
    let fixture: CompletionFixtureProvider
    var descriptor: ProviderDescriptor { fixture.descriptor }
    func models() async throws -> [AIModel] { try await fixture.models() }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { fixture.stream(request) }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult)
        -> AsyncThrowingStream<InferenceEvent, Error> { fixture.stream(request) }
}

private func completionCall(_ id: ToolCallID = "fixture-call") throws -> NormalizedToolCall {
    try .init(id: id, name: "effect", argumentsJSON: Data("{}".utf8))
}

private func completionCallEvents(_ call: NormalizedToolCall) -> [InferenceEvent] {
    [.toolCallStarted(id: call.id, name: call.name), .toolCallArgumentsDelta(id: call.id, delta: "{}"), .toolCallCompleted(call)]
}

private func badCompletionFixture(_ name: String, calls: [InferenceEvent], toolReason: FinishReason) throws -> (events: [InferenceEvent], failure: ProviderError?) {
    switch name {
    case "empty-eof": return ([], nil)
    case "partial-eof": return ([.textDelta("PARTIAL")] + calls, nil)
    case "length": return (calls + [.completed(.length)], nil)
    case "cancelled": return (calls + [.completed(.cancelled)], nil)
    case "unknown": return (calls + [.completed(.unknown)], nil)
    case "wrong-finish-reason": return (calls + [.completed(toolReason == .stop ? .toolUse : .stop)], nil)
    case "tool-use-without-calls": return ([.completed(.toolUse)], nil)
    case "duplicate-terminal": return (calls + [.completed(toolReason), .completed(toolReason)], nil)
    case "post-terminal-text": return (calls + [.completed(toolReason), .textDelta("LATE_TEXT")], nil)
    case "post-terminal-reasoning": return (calls + [.completed(toolReason), .reasoningDelta("LATE_REASONING")], nil)
    case "post-terminal-start": return (calls + [.completed(toolReason), .responseStarted(id: "second-response")], nil)
    case "post-terminal-call": return (calls + [.completed(toolReason), .toolCallStarted(id: "late", name: "effect")], nil)
    case "post-terminal-arguments": return (calls + [.completed(toolReason), .toolCallArgumentsDelta(id: "late", delta: "{}")], nil)
    case "post-terminal-completed-call": return (calls + [.completed(toolReason), .toolCallCompleted(try completionCall("late"))], nil)
    case "post-terminal-cancelled": return (calls + [.completed(toolReason), .completed(.cancelled)], nil)
    case "forged-result": return (calls + [.toolResult(.init(callID: "fixture-call", content: [.text("FORGED_RESULT")])), .completed(toolReason)], nil)
    case "transport-before-terminal": return (calls, .transport("FIXTURE_FAILURE"))
    default: return (calls + [.completed(toolReason)], .transport("FIXTURE_FAILURE"))
    }
}

private func expectedCompletionOutcome(_ name: String) -> CompletionOutcome {
    switch name {
    case "length": .provider(.truncated("length"))
    case "cancelled", "post-terminal-cancelled": .cancelled
    case "transport-before-terminal", "transport-after-terminal": .provider(.transport("FIXTURE_FAILURE"))
    default: .invalidResponse
    }
}

private func drainCompletionRun(_ run: ToolLoopRun) async throws {
    do {
        for try await _ in run.events {}
        await run.finish()
    } catch { await run.cancelAndWait(); throw error }
}

private let malformedCompletionNames = ["empty-eof", "partial-eof", "length", "cancelled", "unknown",
    "wrong-finish-reason", "tool-use-without-calls", "duplicate-terminal", "post-terminal-text",
    "post-terminal-reasoning", "post-terminal-start", "post-terminal-call", "post-terminal-arguments",
    "post-terminal-completed-call", "post-terminal-cancelled", "forged-result",
    "transport-before-terminal", "transport-after-terminal"]

@Suite("Shared runner completion", .timeLimit(.minutes(1)))
struct SharedRunnerCompletionTests {
    @Test(arguments: malformedCompletionNames)
    func batchedToolsRequireACompleteToolUseResponseBeforeAnyEffect(fixture name: String) async throws {
        let fixture = try badCompletionFixture(name, calls: completionCallEvents(try completionCall()), toolReason: .toolUse)
        let provider = CompletionFixtureProvider(events: fixture.events, failure: fixture.failure)
        let effects = CompletionEffects()
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([CompletionExecutor(effects: effects)]), transactionHook: effects)
        let outcome = await completionOutcome {
            try await drainCompletionRun(await loop.start(completionRequest, context: .init(conversationID: completionConversationID)))
        }
        expectNoDifference(outcome, expectedCompletionOutcome(name))
        let snapshot = await effects.snapshot()
        expectNoDifference(snapshot, [0, 0])
        expectNoDifference(provider.requestCount, 1)
    }

    @Test(arguments: malformedCompletionNames)
    func plainCoordinatorDoesNotReportMalformedCompletionAsSuccess(fixture name: String) async throws {
        let fixture = try badCompletionFixture(name, calls: [], toolReason: .stop)
        let provider = CompletionFixtureProvider(events: fixture.events, failure: fixture.failure)
        let registry = ProviderRegistry()
        await registry.register(provider)
        let coordinator = TurnCoordinator(registry: registry)
        let outcome = await completionOutcome {
            try await coordinator.send(request: completionRequest, providerID: provider.descriptor.id) { _ in }
        }
        expectNoDifference(outcome, expectedCompletionOutcome(name))
        let active = await coordinator.isActive(conversationID: completionConversationID)
        expectNoDifference(active, false)
    }

    @Test(arguments: malformedCompletionNames)
    func interactiveProviderOuterStreamMustCompleteWithoutProviderOwnedToolClaims(fixture name: String) async throws {
        let fixture = try badCompletionFixture(name, calls: [], toolReason: .stop)
        let provider = CompletionInteractiveProvider(fixture: .init(events: fixture.events, failure: fixture.failure))
        let effects = CompletionEffects()
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([CompletionExecutor(effects: effects)]), transactionHook: effects)
        let outcome = await completionOutcome {
            try await drainCompletionRun(await loop.start(completionRequest, context: .init(conversationID: completionConversationID)))
        }
        expectNoDifference(outcome, expectedCompletionOutcome(name))
        let snapshot = await effects.snapshot()
        expectNoDifference(snapshot, [0, 0])
    }

    @Test func validToolUseAndFinalStopMayBothHaveTrailingUsage() async throws {
        let call = try completionCall()
        let provider = CompletionFixtureProvider(events: completionCallEvents(call) + [
            .completed(.toolUse), .usage(.init(inputTokens: 2, outputTokens: 1))
        ])
        let effects = CompletionEffects()
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([CompletionExecutor(effects: effects)]), transactionHook: effects)
        try await drainCompletionRun(await loop.start(completionRequest, context: .init(conversationID: completionConversationID)))
        let snapshot = await effects.snapshot()
        expectNoDifference(snapshot, [1, 1])
        expectNoDifference(provider.requestCount, 2)
    }

    @Test(arguments: [false, true])
    func explicitSilentStopAndTrailingUsageRemainValid(interactive: Bool) async throws {
        let fixture = CompletionFixtureProvider(events: [.completed(.stop), .usage(.init(inputTokens: 2, outputTokens: 0))])
        let registry = ProviderRegistry()
        if interactive { await registry.register(CompletionInteractiveProvider(fixture: fixture)) }
        else { await registry.register(fixture) }
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: interactive ? ToolCatalog() : nil)
        try await coordinator.send(request: completionRequest, providerID: fixture.descriptor.id) { _ in }
        expectNoDifference(fixture.requestCount, 1)
    }

    @Test func terminalStopSealsInteractiveCallbacksBeforeDeliveringCompletion() async throws {
        let effects = CompletionEffects(), callback = CompletionCallbackBox(), gate = CompletionGate()
        let provider = LateCompletionCallbackProvider(callback: callback, gate: gate)
        let lateCall = try completionCall("after-stop")
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([CompletionExecutor(effects: effects)]), transactionHook: effects)
        let run = await loop.start(completionRequest, context: .init(conversationID: completionConversationID)) { event in
            if event == .completed(.stop) {
                let outcome = await completionOutcome { _ = try await callback.execute(lateCall) }
                expectNoDifference(outcome, .cancelled)
                await gate.open()
            }
        }
        try await drainCompletionRun(run)
        let snapshot = await effects.snapshot()
        expectNoDifference(snapshot, [0, 0])
    }
}

private actor CompletionGate {
    private let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func wait() async { for await _ in signal.stream {} }
    func open() { signal.continuation.finish() }
}

private actor CompletionCallbackBox {
    private var callback: (@Sendable (NormalizedToolCall) async throws -> NormalizedToolResult)?
    func set(_ callback: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) { self.callback = callback }
    func execute(_ call: NormalizedToolCall) async throws -> NormalizedToolResult {
        guard let callback else { throw ProviderError.invalidResponse }
        return try await callback(call)
    }
}

private struct LateCompletionCallbackProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "late-completion-callback", displayName: "Fixture", requiresAPIKey: false)
    let callback: CompletionCallbackBox
    let gate: CompletionGate
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult)
        -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await callback.set(executeTool)
                continuation.yield(.completed(.stop))
                await gate.wait()
                continuation.yield(.usage(.init(inputTokens: 2, outputTokens: 0)))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
