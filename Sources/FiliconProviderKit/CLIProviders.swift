import Foundation
import FiliconDomain

public struct CodexCLIProvider: AIProvider {
    public let descriptor = ProviderDescriptor(id: "codex-cli", displayName: "Codex CLI", requiresAPIKey: false)
    public let executableURL: URL?
    private let runner: any CLIProcessRunning

    public init(executableURL: URL? = CodexCLIProvider.discoverExecutable(),
                runner: any CLIProcessRunning = FoundationCLIProcessRunner()) {
        self.executableURL = executableURL; self.runner = runner
    }

    public static func discoverExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        CLIExecutableDiscovery.find("codex", knownPaths: [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex"
        ], environment: environment)
    }

    public var isAvailable: Bool { executableURL != nil }

    public func models() async throws -> [AIModel] {
        guard isAvailable else { return [] }
        let capabilities = AIModelCapabilities(reasoningEfforts: Set(ReasoningEffort.allCases))
        return [
            AIModel(id: "codex-default", displayName: "Codex CLI default", capabilities: capabilities),
            AIModel(id: "gpt-5.6-sol", displayName: "GPT-5.6 Sol", capabilities: capabilities),
            AIModel(id: "gpt-5.6-terra", displayName: "GPT-5.6 Terra", capabilities: capabilities),
            AIModel(id: "gpt-5.6-luna", displayName: "GPT-5.6 Luna", capabilities: capabilities),
        ]
    }

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        CLIProviderStream.make(request: request) { try invocation(for: request) }
    }

    private func invocation(for request: InferenceRequest) throws -> CLIInvocation {
        guard let executableURL else { throw ProviderError.transport("Codex CLI is not installed or is not executable") }
        try CLIProviderStream.validate(request)
        var arguments = ["exec", "--json", "--sandbox", "read-only", "--skip-git-repo-check"]
        if request.modelID.rawValue != "codex-default" { arguments += ["--model", request.modelID.rawValue] }
        if request.reasoningEffort != .disabled {
            arguments += ["--config", "model_reasoning_effort=\"\(request.reasoningEffort.rawValue)\""]
        }
        arguments.append("-")
        return CLIInvocation(process: .init(executableURL: executableURL, arguments: arguments,
                                            standardInput: try CLIProviderStream.promptData(request)),
                             runner: runner, parser: CodexEventParser())
    }
}

public struct ClaudeCodeCLIProvider: AIProvider {
    public let descriptor = ProviderDescriptor(id: "claude-code-cli", displayName: "Claude Code CLI", requiresAPIKey: false)
    public let executableURL: URL?
    private let runner: any CLIProcessRunning

    public init(executableURL: URL? = ClaudeCodeCLIProvider.discoverExecutable(),
                runner: any CLIProcessRunning = FoundationCLIProcessRunner()) {
        self.executableURL = executableURL; self.runner = runner
    }

    public static func discoverExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        CLIExecutableDiscovery.find("claude", knownPaths: [
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.local/bin/claude", "~/.npm-global/bin/claude"
        ], environment: environment)
    }

    public var isAvailable: Bool { executableURL != nil }

    public func models() async throws -> [AIModel] {
        guard isAvailable else { return [] }
        let capabilities = AIModelCapabilities(reasoningEfforts: [.disabled, .low, .medium, .high, .xhigh])
        return [
            AIModel(id: "claude-default", displayName: "Claude Code default", capabilities: capabilities),
            AIModel(id: "sonnet", displayName: "Claude Sonnet", capabilities: capabilities),
            AIModel(id: "opus", displayName: "Claude Opus", capabilities: capabilities),
            AIModel(id: "haiku", displayName: "Claude Haiku", capabilities: capabilities),
        ]
    }

    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        CLIProviderStream.make(request: request) { try invocation(for: request) }
    }

    private func invocation(for request: InferenceRequest) throws -> CLIInvocation {
        guard let executableURL else { throw ProviderError.transport("Claude Code CLI is not installed or is not executable") }
        try CLIProviderStream.validate(request)
        var arguments = ["--print", "--input-format", "text", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--no-session-persistence", "--tools", ""]
        if request.modelID.rawValue != "claude-default" { arguments += ["--model", request.modelID.rawValue] }
        if request.reasoningEffort != .disabled {
            let effort = request.reasoningEffort == .xhigh ? "max" : request.reasoningEffort.rawValue
            arguments += ["--effort", effort]
        }
        return CLIInvocation(process: .init(executableURL: executableURL, arguments: arguments,
                                            standardInput: try CLIProviderStream.promptData(request)),
                             runner: runner, parser: ClaudeEventParser())
    }
}

private struct CLIInvocation: Sendable {
    var process: CLIProcessRequest
    var runner: any CLIProcessRunning
    var parser: any CLIEventParsing
}

private enum CLIProviderStream {
    static let maximumInputBytes = 1_024 * 1_024

    static func validate(_ request: InferenceRequest) throws {
        if !request.tools.isEmpty { throw ProviderError.unsupportedAttachment("tools") }
        if request.messages.contains(where: { !($0.attachments.isEmpty) }) || !request.attachmentsByMessageID.isEmpty {
            throw ProviderError.unsupportedAttachment("CLI attachment")
        }
    }

    static func promptData(_ request: InferenceRequest) throws -> Data {
        let text = request.messages.map { message in
            "<message role=\"\(message.role.rawValue)\">\n\(message.text)\n</message>"
        }.joined(separator: "\n\n")
        let prompt = "Continue the conversation below. Respond only to the latest request.\n\n" + text + "\n"
        let data = Data(prompt.utf8)
        guard data.count <= maximumInputBytes else { throw ProviderError.transport("CLI input exceeded \(maximumInputBytes) bytes") }
        return data
    }

    static func make(request: InferenceRequest, invocation: @escaping @Sendable () throws -> CLIInvocation)
    -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var invocation = try invocation()
                    for try await event in invocation.runner.events(for: invocation.process) {
                        try Task.checkCancellation()
                        switch event {
                        case .standardOutput(let data):
                            for normalized in try invocation.parser.consume(data) { continuation.yield(normalized) }
                        }
                    }
                    for normalized in try invocation.parser.finish() { continuation.yield(normalized) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch let error as CLIProcessFailure {
                    continuation.finish(throwing: mapCLIError(error.standardError.isEmpty ? error.localizedDescription : error.standardError))
                } catch {
                    continuation.finish(throwing: ProviderError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func mapCLIError(_ message: String) -> ProviderError {
        let lower = message.lowercased()
        if lower.contains("auth") || lower.contains("login") || lower.contains("unauthorized") || lower.contains("401") {
            return .authentication(message)
        }
        if lower.contains("rate limit") || lower.contains("429") { return .rateLimit(message) }
        if lower.contains("refus") || lower.contains("blocked") { return .refusal(message) }
        return .transport(message)
    }
}

private protocol CLIEventParsing: Sendable {
    mutating func consume(_ data: Data) throws -> [InferenceEvent]
    mutating func finish() throws -> [InferenceEvent]
}

private struct JSONLineBuffer: Sendable {
    private var data = Data()
    mutating func append(_ newData: Data) throws -> [[String: Any]] {
        data.append(newData)
        guard data.count <= 2 * 1_024 * 1_024 else { throw ProviderError.malformedEvent("CLI JSON line exceeds 2 MB") }
        var result: [[String: Any]] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[..<newline]
            data.removeSubrange(...newline)
            if let object = try decode(Data(line)) { result.append(object) }
        }
        return result
    }
    mutating func finish() throws -> [[String: Any]] {
        guard !data.isEmpty else { return [] }
        defer { data.removeAll() }
        return try decode(data).map { [$0] } ?? []
    }
    private func decode(_ line: Data) throws -> [String: Any]? {
        let trimmed = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let bytes = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw ProviderError.malformedEvent(String(trimmed.prefix(512)))
        }
        return object
    }
}

private struct CodexEventParser: CLIEventParsing {
    private var lines = JSONLineBuffer()
    private var started = false
    private var terminal = false
    private var agentText = ""
    mutating func consume(_ data: Data) throws -> [InferenceEvent] { try lines.append(data).flatMap { try parse($0) } }
    mutating func finish() throws -> [InferenceEvent] {
        let events = try lines.finish().flatMap { try parse($0) }
        guard terminal else { throw ProviderError.truncated("Codex stream ended without turn.completed") }
        return events
    }
    private mutating func parse(_ json: [String: Any]) throws -> [InferenceEvent] {
        let type = json["type"] as? String ?? ""
        switch type {
        case "thread.started":
            started = true
            return [.responseStarted(id: json["thread_id"] as? String)]
        case "item.completed", "item.updated":
            guard let item = json["item"] as? [String: Any], item["type"] as? String == "agent_message",
                  let text = item["text"] as? String, !text.isEmpty else { return [] }
            let delta: String
            if text.hasPrefix(agentText) { delta = String(text.dropFirst(agentText.count)) }
            else { delta = text }
            agentText = text
            guard !delta.isEmpty else { return [] }
            if !started { started = true; return [.responseStarted(id: nil), .textDelta(delta)] }
            return [.textDelta(delta)]
        case "item.delta":
            let delta = json["delta"] as? String ?? (json["item"] as? [String: Any])?["delta"] as? String
            if let delta { agentText += delta; return [.textDelta(delta)] }
            return []
        case "turn.completed":
            terminal = true
            var result: [InferenceEvent] = []
            if let usage = json["usage"] as? [String: Any] { result.append(.usage(Self.usage(usage))) }
            result.append(.completed(.stop)); return result
        case "turn.failed", "error":
            let error = json["error"] as? [String: Any]
            let message = error?["message"] as? String ?? json["message"] as? String ?? "Codex CLI reported an error"
            throw CLIProviderStream.mapCLIError(message)
        default: return []
        }
    }
    private static func usage(_ json: [String: Any]) -> Usage {
        Usage(inputTokens: int(json, "input_tokens"), outputTokens: int(json, "output_tokens"),
              cacheReadTokens: int(json, "cached_input_tokens"))
    }
}

private struct ClaudeEventParser: CLIEventParsing {
    private var lines = JSONLineBuffer()
    private var started = false
    private var terminal = false
    private var sawDelta = false
    private var emittedText = false
    mutating func consume(_ data: Data) throws -> [InferenceEvent] { try lines.append(data).flatMap { try parse($0) } }
    mutating func finish() throws -> [InferenceEvent] {
        let events = try lines.finish().flatMap { try parse($0) }
        guard terminal else { throw ProviderError.truncated("Claude stream ended without a result event") }
        return events
    }
    private mutating func parse(_ json: [String: Any]) throws -> [InferenceEvent] {
        switch json["type"] as? String ?? "" {
        case "system":
            guard !started else { return [] }; started = true
            return [.responseStarted(id: json["session_id"] as? String)]
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return [] }
            var result: [InferenceEvent] = []
            if event["type"] as? String == "content_block_delta",
               let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String, !text.isEmpty {
                sawDelta = true; emittedText = true; result.append(.textDelta(text))
            }
            if let message = event["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                result.append(.usage(Self.usage(usage)))
            } else if let usage = event["usage"] as? [String: Any] { result.append(.usage(Self.usage(usage))) }
            return result
        case "assistant":
            guard !sawDelta, let message = json["message"] as? [String: Any] else { return [] }
            var result = Self.textEvents(message["content"])
            if !result.isEmpty { emittedText = true }
            if let usage = message["usage"] as? [String: Any] { result.append(.usage(Self.usage(usage))) }
            return result
        case "result":
            if json["is_error"] as? Bool == true || (json["subtype"] as? String)?.contains("error") == true {
                throw CLIProviderStream.mapCLIError(json["result"] as? String ?? "Claude Code CLI reported an error")
            }
            terminal = true
            var result: [InferenceEvent] = []
            if !emittedText, let text = json["result"] as? String, !text.isEmpty { result.append(.textDelta(text)) }
            if let usage = json["usage"] as? [String: Any] { result.append(.usage(Self.usage(usage))) }
            result.append(.completed(.stop)); return result
        default: return []
        }
    }
    private static func textEvents(_ value: Any?) -> [InferenceEvent] {
        guard let blocks = value as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty else { return nil }
            return .textDelta(text)
        }
    }
    private static func usage(_ json: [String: Any]) -> Usage {
        Usage(inputTokens: int(json, "input_tokens"), outputTokens: int(json, "output_tokens"),
              cacheReadTokens: int(json, "cache_read_input_tokens"), cacheWriteTokens: int(json, "cache_creation_input_tokens"))
    }
}

private func int(_ object: [String: Any], _ key: String) -> Int {
    (object[key] as? NSNumber)?.intValue ?? 0
}
