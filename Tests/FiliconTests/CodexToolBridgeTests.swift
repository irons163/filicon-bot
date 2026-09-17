import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
@testable import FiliconProviderKit

private actor BridgeProbe {
    var contexts: [ToolContext] = []
    func record(_ context: ToolContext) { contexts.append(context) }
}

private struct BridgeExecutor: ToolExecutor {
    let descriptor = ToolDescriptor(name: "fixture_read", description: "Read the isolated test fixture; no arguments.",
        inputSchema: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8))
    var body: @Sendable (NormalizedToolCall, ToolContext) async throws -> NormalizedToolResult
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult { try await body(call, context) }
}

private struct BridgeContextExecutor: ToolExecutor, ToolRuntimeContextProviding {
    let wrapped: BridgeExecutor
    var descriptor: ToolDescriptor { wrapped.descriptor }
    func runtimeContext(for context: ToolContext) async throws -> String { "Verified Filicon host policy: fixture_read=ask; this is not a grant." }
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult { try await wrapped.execute(call, context: context) }
}

/// Exercises the real bridge codec and bidirectional protocol, without cloud use.
private final class BridgeRunner: CLIProcessRunning, @unchecked Sendable {
    enum Mode: Sendable { case success, denied, duplicate, repeated, unknown, wrongThread, wrongTurn, malformed, truncated, rpcError, nativeApproval, hang }
    let mode: Mode
    private let lock = NSLock()
    private var sent: [Data] = []
    private var invocation: CLIProcessRequest?
    private var stopped = false
    init(_ mode: Mode = .success) { self.mode = mode }
    func snapshot() -> ([Data], CLIProcessRequest?, Bool) { lock.withLock { (sent, invocation, stopped) } }
    func events(for request: CLIProcessRequest) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func events(for request: CLIProcessRequest, input: AsyncStream<Data>) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        lock.withLock { invocation = request }
        return AsyncThrowingStream { continuation in
            let task = Task {
                var callCount = 1
                func emit(_ object: [String: Any]) throws {
                    let bytes = try JSONSerialization.data(withJSONObject: object) + Data([10])
                    // Deliberately split frames, including UTF-8 text, across reads.
                    continuation.yield(.standardOutput(Data(bytes.prefix(7))))
                    continuation.yield(.standardOutput(Data(bytes.dropFirst(7))))
                }
                do {
                    for await data in input {
                        self.lock.withLock { self.sent.append(data) }
                        let frame = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                        let id = frame["id"] as? Int
                        switch frame["method"] as? String {
                        case "initialize":
                            if self.mode == .hang { continue }
                            if self.mode == .rpcError {
                                try emit(["id": 1, "error": ["code": -32602, "message": "experimental API unsupported"]]); continue
                            }
                            try emit(["id": 1, "result": ["userAgent": "fixture"]])
                        case "config/read":
                            try emit(["id": 2, "result": ["config": ["mcp_servers": ["existing.server": ["command": "do-not-run", "tool_timeout_sec": NSNull()]]]]])
                        case "thread/start":
                            try emit(["id": 3, "result": ["thread": ["id": "thread-1"]]])
                        case "turn/start":
                            try emit(["id": 4, "result": ["turn": ["id": "turn-1"]]])
                            if self.mode == .truncated { continuation.finish(); return }
                            if self.mode == .nativeApproval {
                                try emit(["id": 50, "method": "item/commandExecution/requestApproval", "params": [:]]); continue
                            }
                            try emit(["id": 50, "method": "item/tool/call", "params": [
                                "threadId": self.mode == .wrongThread ? "other" : "thread-1",
                                "turnId": self.mode == .wrongTurn ? "other" : "turn-1", "callId": "call-1",
                                "tool": self.mode == .unknown ? "unlisted" : "filicon_tool_0",
                                "arguments": self.mode == .malformed ? ["extra": "bad"] : [:]
                            ]])
                        default:
                            if let id, id >= 50, frame["result"] != nil {
                                if self.mode == .duplicate {
                                    try emit(["id": 51, "method": "item/tool/call", "params": ["threadId": "thread-1", "turnId": "turn-1", "callId": "call-1", "tool": "filicon_tool_0", "arguments": [:]]]); continue
                                }
                                if self.mode == .repeated {
                                    callCount += 1
                                    try emit(["id": 49 + callCount, "method": "item/tool/call", "params": ["threadId": "thread-1", "turnId": "turn-1", "callId": "call-\(callCount)", "tool": "filicon_tool_0", "arguments": [:]]]); continue
                                }
                                try emit(["method": "item/agentMessage/delta", "params": ["threadId": "thread-1", "turnId": "turn-1", "itemId": "message-1", "delta": "完成"]])
                                try emit(["method": "item/completed", "params": ["threadId": "thread-1", "turnId": "turn-1", "item": ["type": "agentMessage", "id": "message-1", "text": "完成"]]])
                                try emit(["method": "turn/completed", "params": ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed"]]])
                            }
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel(); self.lock.withLock { self.stopped = true } }
        }
    }
}

@Suite("Codex host tool bridge", .timeLimit(.minutes(2)))
struct CodexToolBridgeTests {
    private let conversationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private func request() -> InferenceRequest {
        .init(conversationID: conversationID, modelID: "gpt-5.6-sol", messages: [.init(role: .user, text: "Read fixture.")])
    }
    private func collect(_ runner: BridgeRunner, executor: BridgeExecutor) async throws -> [InferenceEvent] {
        let provider = CodexCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/codex"), runner: runner)
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([executor]))
        var events: [InferenceEvent] = []
        for try await event in await loop.run(request(), context: .init(conversationID: conversationID)) { events.append(event) }
        return events
    }

    @Test func hostPermissionsAndLatestRequestReachCodexWithoutRelaxingNativeSandbox() async throws {
        let runner = BridgeRunner()
        let provider = CodexCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/codex"), runner: runner)
        let executor = BridgeContextExecutor(wrapped: BridgeExecutor { call, _ in .init(callID: call.id, content: [.text("fixture")]) })
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([executor]))
        let latest = "Resume the original task and request operation approval."
        let request = InferenceRequest(conversationID: conversationID, modelID: "test", messages: [
            .init(role: .user, text: "Only test authorization for this diagnostic."),
            .init(role: .assistant, text: "The workspace is read-only."),
            .init(role: .user, text: latest)
        ])
        for try await _ in await loop.run(request, context: .init(conversationID: conversationID)) {}
        let frames = try runner.snapshot().0.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let start = try #require(frames.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        expectNoDifference(start["sandbox"] as? String, "read-only")
        expectNoDifference(start["approvalPolicy"] as? String, "untrusted")
        #expect((start["developerInstructions"] as? String)?.contains("Verified Filicon host policy: fixture_read=ask") == true)
        #expect((start["baseInstructions"] as? String)?.contains("NOT Filicon host tools") == true)
        let turn = try #require(frames.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
        let input = try #require(turn["input"] as? [[String: String]])
        let text = try #require(input.first?["text"])
        #expect(text.hasSuffix("Latest user request:\n" + latest))
        #expect(text.contains("Only test authorization for this diagnostic."))
        #expect(!text.contains("Verified Filicon host policy")) // Host context is a developer instruction, not history.
        let invocation = try #require(runner.snapshot().1)
        #expect(invocation.arguments.contains("sandbox_mode=\"read-only\""))
        #expect(invocation.arguments.contains("features.shell_tool=false"))
    }

    @Test func hostExecutionResultReturnsToCodexAndUIWithoutDuplicatedText() async throws {
        let runner = BridgeRunner(), probe = BridgeProbe()
        let events = try await collect(runner, executor: BridgeExecutor { call, context in
            await probe.record(context)
            return .init(callID: call.id, content: [.text("fixture-only-result")])
        })
        expectNoDifference(events.filter { if case .textDelta = $0 { true } else { false } }, [.textDelta("完成")])
        let contexts = await probe.contexts
        expectNoDifference(contexts.map(\.conversationID), [conversationID])
        #expect(events.contains(.toolResult(.init(callID: "call-1", content: [.text("fixture-only-result")]))))
        let frames = try runner.snapshot().0.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let reply = try #require(frames.first { ($0["id"] as? Int) == 50 }?["result"] as? [String: Any])
        expectNoDifference(reply["success"] as? Bool, true)
        #expect(String(describing: reply["contentItems"]).contains("fixture-only-result"))
        let start = try #require(frames.first { $0["method"] as? String == "thread/start" }?["params"] as? [String: Any])
        let config = try #require(start["config"] as? [String: Any])
        let servers = try #require(config["mcp_servers"] as? [String: [String: Any]])
        expectNoDifference(servers["existing.server"]?["enabled"] as? Bool, false)
        #expect(servers["existing.server"]?["tool_timeout_sec"] == nil)
        expectNoDifference(start["ephemeral"] as? Bool, true)
        expectNoDifference(start["model"] as? String, "gpt-5.6-sol")
        #expect(!(String(describing: start).contains("text-only response")))
        let invocation = try #require(runner.snapshot().1)
        #expect(invocation.arguments.contains("features.shell_tool=false"))
        #expect(invocation.arguments.contains("features.hooks=false"))
        #expect(!FileManager.default.fileExists(atPath: try #require(invocation.workingDirectoryURL).path))
    }

    @Test func deniedResultIsReturnedAsFailureNotSuccess() async throws {
        let runner = BridgeRunner(.denied)
        let events = try await collect(runner, executor: BridgeExecutor { call, _ in .init(callID: call.id, content: [.text("Permission denied")], isError: true) })
        #expect(events.contains(.toolResult(.init(callID: "call-1", content: [.text("Permission denied")], isError: true))))
        let replies = try runner.snapshot().0.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let result = try #require(replies.first { $0["id"] as? Int == 50 }?["result"] as? [String: Any])
        expectNoDifference(result["success"] as? Bool, false)
    }

    @Test(arguments: [BridgeRunner.Mode.unknown, .wrongThread, .wrongTurn, .malformed, .truncated, .rpcError, .nativeApproval])
    fileprivate func invalidProtocolCannotExecute(_ mode: BridgeRunner.Mode) async {
        let probe = BridgeProbe()
        await #expect(throws: (any Error).self) {
            _ = try await collect(BridgeRunner(mode), executor: BridgeExecutor { call, context in
                await probe.record(context); return .init(callID: call.id, content: [])
            })
        }
        #expect(await probe.contexts.isEmpty)
    }

    @Test func duplicateCallCannotExecuteTwice() async {
        let probe = BridgeProbe()
        await #expect(throws: ProviderError.invalidResponse) {
            _ = try await collect(BridgeRunner(.duplicate), executor: BridgeExecutor { call, context in
                await probe.record(context); return .init(callID: call.id, content: [])
            })
        }
        let contexts = await probe.contexts
        expectNoDifference(contexts.count, 1)
    }

    @Test func toolLimitAndMismatchedResultsFailClosed() async {
        let probe = BridgeProbe()
        await #expect(throws: ToolLoopError.toolStepLimit(maximum: ToolLoop.maximumSteps)) {
            _ = try await collect(BridgeRunner(.repeated), executor: BridgeExecutor { call, context in
                await probe.record(context); return .init(callID: call.id, content: [])
            })
        }
        let contexts = await probe.contexts
        expectNoDifference(contexts.count, ToolLoop.maximumSteps - 1)
        let runner = BridgeRunner()
        await #expect(throws: ToolLoopError.resultCallIDMismatch(expected: "call-1", actual: "wrong")) {
            _ = try await collect(runner, executor: BridgeExecutor { _, _ in .init(callID: "wrong", content: [.text("untrusted")]) })
        }
        let frames = runner.snapshot().0.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(!frames.contains { ($0["id"] as? Int) == 50 && $0["result"] != nil })
    }

    @Test func cancellationWhileAwaitingApprovalStopsTheProtocol() async throws {
        let runner = BridgeRunner(), probe = BridgeProbe()
        let run = Task {
            try await collect(runner, executor: BridgeExecutor { call, context in
                await probe.record(context)
                try await Task.sleep(for: .seconds(60))
                return .init(callID: call.id, content: [.text("must not execute")])
            })
        }
        for _ in 0..<200 {
            if await !probe.contexts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await !probe.contexts.isEmpty)
        run.cancel()
        _ = await run.result
        for _ in 0..<200 where !runner.snapshot().2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runner.snapshot().2)
        let frames = try runner.snapshot().0.map { try #require(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        #expect(!frames.contains { ($0["id"] as? Int) == 50 && $0["result"] != nil })
    }

    @Test func actualProcessHasBidirectionalInputAndCancellation() async throws {
        let input = AsyncStream<Data>.makeStream()
        let stream = FoundationCLIProcessRunner().events(for: .init(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [], standardInput: Data()), input: input.stream)
        let run = Task {
            for try await event in stream {
                if case .standardOutput(let data) = event { return data }
            }
            return Data()
        }
        input.continuation.yield(Data("interactive\n".utf8))
        let output = try await run.value
        expectNoDifference(output, Data("interactive\n".utf8))
        input.continuation.finish()
    }

    @Test func stalledStartupTimesOutAndClosesRunner() async throws {
        let runner = BridgeRunner(.hang)
        let bridge = CodexAppServerBridge(executableURL: URL(fileURLWithPath: "/fixture/codex"), runner: runner,
                                         startupTimeout: .milliseconds(100))
        await #expect(throws: ProviderError.transport("Codex app-server startup timed out.")) {
            for try await _ in bridge.stream(request(), executeTool: { call in
                Issue.record("Startup must never execute a tool")
                return .init(callID: call.id, content: [])
            }) {}
        }
        for _ in 0..<200 where !runner.snapshot().2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(runner.snapshot().2)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["FILICON_CODEX_LIVE_TEST"] == "1"))
    func installedCodexExecutesAnIsolatedHostTool() async throws {
        let probe = BridgeProbe()
        let marker = "filicon-live-" + UUID().uuidString
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("\(marker).txt")
        try marker.write(to: fixture, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let executor = BridgeExecutor { call, context in
            await probe.record(context)
            return .init(callID: call.id, content: [.text(try String(contentsOf: fixture, encoding: .utf8))])
        }
        let provider = CodexCLIProvider()
        #expect(provider.isAvailable)
        let request = InferenceRequest(conversationID: conversationID, modelID: "gpt-5.6-sol", messages: [
            .init(role: .user, text: "Call the fixture_read tool exactly once, then reply with its exact result. You cannot know the result without calling it. Do not call any other tool.")
        ])
        let loop = ToolLoop(provider: provider, catalog: ToolCatalog([executor]))
        let run = Task {
            var events: [InferenceEvent] = []
            for try await event in await loop.run(request, context: .init(conversationID: conversationID)) { events.append(event) }
            return events
        }
        let deadline = Task { try await Task.sleep(for: .seconds(90)); run.cancel() }
        defer { deadline.cancel() }
        let events = try await run.value
        let contexts = await probe.contexts
        expectNoDifference(contexts.count, 1)
        let text = events.compactMap { if case .textDelta(let value) = $0 { value } else { nil } }.joined()
        #expect(text.contains(marker))
        #expect(events.contains { if case .toolResult(let result) = $0 { result.wireText == marker && !result.isError } else { false } })
    }
}
