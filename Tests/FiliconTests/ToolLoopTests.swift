import Foundation
import Testing
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices

private final class ScriptedToolProvider: AIProvider, @unchecked Sendable {
    let descriptor = ProviderDescriptor(id: "scripted-tools", displayName: "Scripted", requiresAPIKey: false)
    private let lock = NSLock()
    private var index = 0
    private let script: @Sendable (Int, InferenceRequest) throws -> [InferenceEvent]
    init(script: @escaping @Sendable (Int, InferenceRequest) throws -> [InferenceEvent]) { self.script = script }
    func models() async throws -> [AIModel] { [.init(id: "scripted")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        let step = lock.withLock { let value = index; index += 1; return value }
        return AsyncThrowingStream { continuation in
            do { for event in try script(step, request) { continuation.yield(event) }; continuation.finish() }
            catch { continuation.finish(throwing: error) }
        }
    }
}

private struct ClosureToolExecutor: ToolExecutor {
    let descriptor: ToolDescriptor
    let body: @Sendable (NormalizedToolCall, ToolContext) async throws -> NormalizedToolResult
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult { try await body(call, context) }
}

private actor ToolExecutionProbe {
    var active = 0, maximum = 0, cancelled = 0
    func begin() { active += 1; maximum = max(maximum, active) }
    func end(cancelled wasCancelled: Bool = false) { active -= 1; if wasCancelled { cancelled += 1 } }
}

private actor ToolAuditProbe: ToolLoopTransactionHook {
    private(set) var records: [([NormalizedToolCall], [NormalizedToolResult])] = []
    func persist(step: Int, calls: [NormalizedToolCall], results: [NormalizedToolResult], context: ToolContext) async throws { records.append((calls, results)) }
}

private func toolCall(_ id: String, _ name: String, _ json: String = "{}") throws -> NormalizedToolCall {
    try NormalizedToolCall(id: ToolCallID(rawValue: id), name: ToolName(rawValue: name), argumentsJSON: Data(json.utf8))
}

private func toolEvents(_ call: NormalizedToolCall, text: String = "") -> [InferenceEvent] {
    (text.isEmpty ? [] : [.textDelta(text)]) + [.toolCallStarted(id: call.id, name: call.name), .toolCallArgumentsDelta(id: call.id, delta: String(decoding: call.argumentsJSON, as: UTF8.self)), .toolCallCompleted(call), .completed(.toolUse)]
}

private func collectToolLoop(_ loop: ToolLoop, request: InferenceRequest = .init(conversationID: UUID(), modelID: "scripted", messages: [])) async throws -> [InferenceEvent] {
    var output: [InferenceEvent] = []
    for try await event in await loop.run(request, context: ToolContext(conversationID: request.conversationID)) { output.append(event) }
    return output
}

private let objectSchema = Data("{\"type\":\"object\",\"properties\":{\"value\":{\"type\":\"string\"}},\"required\":[\"value\"],\"additionalProperties\":false}".utf8)

@Test func twoStepLoopPreservesTextCallsResultsAndAudit() async throws {
    let call = try toolCall("c1", "echo", "{\"value\":\"hi\"}")
    let provider = ScriptedToolProvider { step, request in
        #expect(request.reasoningEffort == .high)
        if step == 0 { return toolEvents(call, text: "before tool") }
        #expect(request.toolExchanges.count == 1)
        #expect(request.toolExchanges[0].assistantText == "before tool")
        #expect(request.toolExchanges[0].results[0].wireText == "result-hi")
        return [.textDelta("after tool"), .completed(.stop)]
    }
    let executor = ClosureToolExecutor(descriptor: .init(name: "echo", inputSchema: objectSchema)) { call, _ in .init(callID: call.id, content: [.text("result-hi")]) }
    let audit = ToolAuditProbe(), loop = ToolLoop(provider: provider, catalog: ToolCatalog([executor]), transactionHook: audit)
    let events = try await collectToolLoop(
        loop,
        request: .init(conversationID: UUID(), modelID: "scripted", messages: [], reasoningEffort: .high)
    )
    #expect(events.contains(.textDelta("before tool")))
    #expect(events.contains(.toolResult(.init(callID: "c1", content: [.text("result-hi")]))))
    #expect(events.contains(.textDelta("after tool")))
    #expect(await audit.records.count == 1)
}

@Test func parallelSafeCallsRunTogetherButResultsKeepCallOrder() async throws {
    let first = try toolCall("first", "slow", "{\"value\":\"1\"}"), second = try toolCall("second", "fast", "{\"value\":\"2\"}")
    let provider = ScriptedToolProvider { step, _ in step == 0 ? toolEvents(first) + toolEvents(second) : [.completed(.stop)] }
    let probe = ToolExecutionProbe()
    func executor(_ name: ToolName, delay: Duration) -> ClosureToolExecutor {
        ClosureToolExecutor(descriptor: .init(name: name, inputSchema: objectSchema, parallelSafe: true)) { call, _ in
            await probe.begin(); try await Task.sleep(for: delay); await probe.end()
            return .init(callID: call.id, content: [.text(call.id.rawValue)])
        }
    }
    let loop = ToolLoop(provider: provider, catalog: ToolCatalog([executor("slow", delay: .milliseconds(80)), executor("fast", delay: .milliseconds(5))]))
    let results = try await collectToolLoop(loop).compactMap { if case .toolResult(let value) = $0 { value } else { nil } }
    #expect(await probe.maximum == 2)
    #expect(results.map(\.callID) == ["first", "second"])
}

@Test func oneUnsafeDescriptorForcesWholeStepSequential() async throws {
    let a = try toolCall("a", "a", "{\"value\":\"1\"}"), b = try toolCall("b", "b", "{\"value\":\"2\"}")
    let provider = ScriptedToolProvider { step, _ in step == 0 ? toolEvents(a) + toolEvents(b) : [.completed(.stop)] }
    let probe = ToolExecutionProbe()
    func executor(_ name: ToolName, safe: Bool) -> ClosureToolExecutor { .init(descriptor: .init(name: name, inputSchema: objectSchema, parallelSafe: safe)) { call, _ in await probe.begin(); try await Task.sleep(for: .milliseconds(15)); await probe.end(); return .init(callID: call.id, content: [.text("ok")]) } }
    _ = try await collectToolLoop(ToolLoop(provider: provider, catalog: ToolCatalog([executor("a", safe: true), executor("b", safe: false)])))
    #expect(await probe.maximum == 1)
}

@Test func duplicateUnknownMalformedAndSchemaFailuresAreTyped() async throws {
    let valid = try toolCall("same", "known", "{\"value\":\"ok\"}")
    let executor = ClosureToolExecutor(descriptor: .init(name: "known", inputSchema: objectSchema)) { call, _ in .init(callID: call.id, content: [.text("ok")]) }
    let duplicate = ScriptedToolProvider { _, _ in toolEvents(valid) + toolEvents(valid) }
    await #expect(throws: ToolLoopError.duplicateCallID("same")) { _ = try await collectToolLoop(ToolLoop(provider: duplicate, catalog: ToolCatalog([executor]))) }

    let missing = try toolCall("u1", "missing")
    await #expect(throws: ToolLoopError.unknownTool("missing")) { _ = try await collectToolLoop(ToolLoop(provider: ScriptedToolProvider { _, _ in toolEvents(missing) }, catalog: ToolCatalog([executor]))) }

    let malformed = ScriptedToolProvider { _, _ in [.toolCallStarted(id: "m1", name: "known"), .toolCallArgumentsDelta(id: "m1", delta: "{")] }
    await #expect(throws: ToolLoopError.malformedArguments("m1")) { _ = try await collectToolLoop(ToolLoop(provider: malformed, catalog: ToolCatalog([executor]))) }

    let wrongSchema = try toolCall("s1", "known", "{\"value\":3}")
    do { _ = try await collectToolLoop(ToolLoop(provider: ScriptedToolProvider { _, _ in toolEvents(wrongSchema) }, catalog: ToolCatalog([executor]))); Issue.record("Expected schema mismatch") }
    catch let error as ToolLoopError { guard case .schemaMismatch(let id, _) = error else { Issue.record("Unexpected \(error)"); return }; #expect(id == "s1") }
}

@Test func attemptedNinthStepFailsBeforeEighthExecution() async throws {
    let provider = ScriptedToolProvider { step, _ in toolEvents(try toolCall("step-\(step)", "again", "{}")) }
    let executor = ClosureToolExecutor(descriptor: .init(name: "again")) { call, _ in .init(callID: call.id, content: [.text("continue")]) }
    await #expect(throws: ToolLoopError.toolStepLimit(maximum: 8)) { _ = try await collectToolLoop(ToolLoop(provider: provider, catalog: ToolCatalog([executor]))) }
}

@Test func cancellationLeavesNoExecutorRunning() async throws {
    let call = try toolCall("cancel", "wait", "{}"), probe = ToolExecutionProbe()
    let provider = ScriptedToolProvider { step, _ in step == 0 ? toolEvents(call) : [.completed(.stop)] }
    let executor = ClosureToolExecutor(descriptor: .init(name: "wait")) { call, _ in
        await probe.begin()
        do { try await Task.sleep(for: .seconds(30)); await probe.end(); return .init(callID: call.id, content: [.text("late")]) }
        catch { await probe.end(cancelled: true); throw error }
    }
    let loop = ToolLoop(provider: provider, catalog: ToolCatalog([executor]))
    let consumer = Task { for try await _ in await loop.run(.init(conversationID: UUID(), modelID: "scripted", messages: []), context: .init(conversationID: UUID())) {} }
    for _ in 0..<50 { if await probe.active == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
    consumer.cancel(); _ = try? await consumer.value
    for _ in 0..<50 { if await probe.active == 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await probe.active == 0)
    #expect(await probe.cancelled == 1)
}
