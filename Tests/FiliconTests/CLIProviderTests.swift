import Foundation
import Testing
@testable import FiliconDomain
@testable import FiliconProviderKit

private final class FixtureCLIRunner: CLIProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [Data]
    private let failure: Error?
    private var captured: CLIProcessRequest?

    init(_ fixture: String, splitAt: Int? = nil, failure: Error? = nil) {
        let data = Data(fixture.utf8)
        if let splitAt, splitAt > 0, splitAt < data.count {
            chunks = [Data(data.prefix(splitAt)), Data(data.dropFirst(splitAt))]
        } else { chunks = [data] }
        self.failure = failure
    }

    func events(for request: CLIProcessRequest) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        lock.lock(); captured = request; lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(.standardOutput(chunk)) }
            if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
        }
    }

    func request() -> CLIProcessRequest? {
        lock.lock(); defer { lock.unlock() }; return captured
    }
}

private final class HangingCLIRunner: CLIProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    func events(for request: CLIProcessRequest) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.lock.lock(); self?.terminated = true; self?.lock.unlock()
            }
        }
    }
    func wasTerminated() -> Bool { lock.lock(); defer { lock.unlock() }; return terminated }
}

private func cliRequest(model: ModelID, text: String = "Hello", reasoning: ReasoningEffort = .disabled) -> InferenceRequest {
    .init(conversationID: UUID(), modelID: model,
          messages: [.init(role: .system, text: "Be concise"), .init(role: .user, text: text)],
          reasoningEffort: reasoning)
}

private func collectCLI(_ provider: any AIProvider, _ request: InferenceRequest) async throws -> [InferenceEvent] {
    var result: [InferenceEvent] = []
    for try await event in provider.stream(request) { result.append(event) }
    return result
}

@Suite(.serialized)
struct CLIProviderTests {
    @Test func cliProvidersDoNotReceiveFiliconToolSchemas() {
        #expect(CodexCLIProvider(executableURL: nil, runner: FixtureCLIRunner("")).descriptor.supportsToolCalling == false)
        #expect(ClaudeCodeCLIProvider(executableURL: nil, runner: FixtureCLIRunner("")).descriptor.supportsToolCalling == false)
    }

    @Test func codexJSONLinesAreNormalizedAndArgumentsAreDirect() async throws {
        let fixture = """
        {"type":"thread.started","thread_id":"thread-1"}
        {"type":"item.updated","item":{"type":"agent_message","text":"Hel"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Hello"}}
        {"type":"turn.completed","usage":{"input_tokens":12,"cached_input_tokens":3,"output_tokens":2}}

        """
        let runner = FixtureCLIRunner(fixture, splitAt: 37)
        let provider = CodexCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/codex"), runner: runner)
        let events = try await collectCLI(provider, cliRequest(model: "gpt-5.6-sol", reasoning: .high))

        #expect(events == [.responseStarted(id: "thread-1"), .textDelta("Hel"), .textDelta("lo"),
                           .usage(.init(inputTokens: 12, outputTokens: 2, cacheReadTokens: 3)), .completed(.stop)])
        let invocation = try #require(runner.request())
        #expect(invocation.executableURL.path == "/fixture/codex")
        #expect(invocation.arguments == ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check",
                                         "--model", "gpt-5.6-sol", "--config", "model_reasoning_effort=\"high\"", "-"])
        #expect(String(decoding: invocation.standardInput, as: UTF8.self).contains("<message role=\"user\">\nHello"))
    }

    @Test func claudePartialStreamDoesNotDuplicateAssistantOrResultText() async throws {
        let fixture = """
        {"type":"system","subtype":"init","session_id":"session-1"}
        {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Hi"}],"usage":{"input_tokens":7,"output_tokens":1,"cache_read_input_tokens":2}}}
        {"type":"result","subtype":"success","is_error":false,"result":"Hi","usage":{"input_tokens":7,"output_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}

        """
        let runner = FixtureCLIRunner(fixture, splitAt: 11)
        let provider = ClaudeCodeCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/claude"), runner: runner)
        let events = try await collectCLI(provider, cliRequest(model: "sonnet", reasoning: .xhigh))
        #expect(events.filter { if case .textDelta = $0 { true } else { false } } == [.textDelta("Hi")])
        #expect(events.first == .responseStarted(id: "session-1"))
        #expect(events.last == .completed(.stop))
        #expect(events.contains(.usage(.init(inputTokens: 7, outputTokens: 1, cacheReadTokens: 2, cacheWriteTokens: 1))))
        let invocation = try #require(runner.request())
        #expect(invocation.arguments.contains("--include-partial-messages"))
        #expect(invocation.arguments.contains("--no-session-persistence"))
        #expect(invocation.arguments.suffix(2) == ["--effort", "max"])
    }

    @Test func unavailableCLIsExposeNoModelsAndFailWithoutCredentialInspection() async throws {
        let provider = CodexCLIProvider(executableURL: nil, runner: FixtureCLIRunner(""))
        #expect(try await provider.models().isEmpty)
        await #expect(throws: ProviderError.self) { _ = try await collectCLI(provider, cliRequest(model: "codex-default")) }
        #expect(CLIExecutableDiscovery.find("filicon-definitely-missing", knownPaths: [],
                                            environment: ["PATH": "/definitely/missing"]) == nil)
    }

    @Test func discoveryResolvesActualExecutableAndProviderPathsAreExecutable() {
        let shell = CLIExecutableDiscovery.find("sh", knownPaths: ["/bin/sh"], environment: [:])
        #expect(shell?.path == "/bin/sh")
        if let codex = CodexCLIProvider.discoverExecutable() {
            #expect(FileManager.default.isExecutableFile(atPath: codex.path))
        }
        if let claude = ClaudeCodeCLIProvider.discoverExecutable() {
            #expect(FileManager.default.isExecutableFile(atPath: claude.path))
        }
    }

    @Test func malformedAndAuthenticationFailuresAreBoundedProviderErrors() async throws {
        let malformed = CodexCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/codex"), runner: FixtureCLIRunner("not-json\n"))
        await #expect(throws: ProviderError.self) { _ = try await collectCLI(malformed, cliRequest(model: "codex-default")) }

        let auth = ClaudeCodeCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/claude"), runner: FixtureCLIRunner("", failure: CLIProcessFailure(exitCode: 1, standardError: "Please login")))
        do { _ = try await collectCLI(auth, cliRequest(model: "claude-default")); Issue.record("Expected auth failure") }
        catch let error as ProviderError {
            guard case .authentication = error else { Issue.record("Wrong error: \(error)"); return }
        }
    }

    @Test func cancellingProviderConsumptionTerminatesRunnerStream() async throws {
        let runner = HangingCLIRunner()
        let provider = CodexCLIProvider(executableURL: URL(fileURLWithPath: "/fixture/codex"), runner: runner)
        let task = Task { try await collectCLI(provider, cliRequest(model: "codex-default")) }
        await Task.yield()
        task.cancel()
        _ = await task.result
        for _ in 0..<20 where !runner.wasTerminated() { await Task.yield() }
        #expect(runner.wasTerminated())
    }
}
