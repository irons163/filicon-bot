import Foundation
import FiliconDomain

/// One ephemeral app-server thread per Filicon response. Only dynamic tools
/// execute, through the host callback. No CLI credential files are inspected.
struct CodexAppServerBridge: Sendable {
    let executableURL: URL?
    let runner: any CLIProcessRunning
    var startupTimeout: Duration = .seconds(30)

    static let disabledFeatures = [
        "shell_tool", "unified_exec", "apps", "plugins", "hooks", "multi_agent",
        "browser_use", "browser_use_external", "computer_use", "in_app_browser",
        "image_generation", "code_mode", "code_mode_host", "code_mode_only",
        "skill_mcp_dependency_install", "request_permissions_tool", "memories", "tool_suggest"
    ]

    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult)
        -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let deadline = Task {
                do {
                    try await Task.sleep(for: startupTimeout)
                    continuation.finish(throwing: ProviderError.transport("Codex app-server startup timed out."))
                } catch { /* Cancelled when the turn is ready or the stream ends. */ }
            }
            let task = Task {
                do {
                    try await run(request, executeTool: executeTool, onReady: { deadline.cancel() }, continuation: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in deadline.cancel(); task.cancel() }
        }
    }

    private func run(_ request: InferenceRequest,
                     executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult,
                     onReady: @Sendable () -> Void,
                     continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation) async throws {
        guard let executableURL else { throw ProviderError.transport("Codex CLI is not installed or is not executable") }
        guard request.attachmentsByMessageID.isEmpty, request.messages.allSatisfy({ $0.attachments.isEmpty }) else {
            throw ProviderError.unsupportedAttachment("CLI attachment")
        }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-codex-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let cwd = directory.resolvingSymlinksInPath().path
        let input = AsyncStream<Data>.makeStream()
        defer { input.continuation.finish() }
        var arguments = ["app-server", "--listen", "stdio://"]
        for feature in Self.disabledFeatures { arguments += ["-c", "features.\(feature)=false"] }
        arguments += ["-c", "web_search=\"disabled\"", "-c", "tools.view_image=false", "-c", "sandbox_mode=\"read-only\"", "-c", "approval_policy=\"untrusted\""]
        let process = CLIProcessRequest(executableURL: executableURL, arguments: arguments, standardInput: Data(),
                                        workingDirectoryURL: directory)
        let tools = try request.tools.enumerated().map { index, tool -> (String, ToolDescriptor, [String: Any]) in
            let name = "filicon_tool_\(index)"
            let schema = try JSONSerialization.jsonObject(with: tool.inputSchema)
            guard schema is [String: Any] else { throw ProviderError.invalidResponse }
            return (name, tool, ["type": "function", "name": name,
                                "description": tool.name.rawValue + ": " + (tool.description ?? ""),
                                "inputSchema": schema])
        }
        func send(_ object: [String: Any]) throws {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard data.count <= 1_024 * 1_024 else { throw ProviderError.transport("Codex request exceeded 1 MB") }
            input.continuation.yield(data + Data([0x0A]))
        }
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "filicon", "title": "Filicon", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ]])
        var lines = CodexRPCLineBuffer()
        var expectedResponse = 1
        var threadID: String?
        var turnID: String?
        var textByItem: [String: String] = [:]
        var seenCalls = Set<String>()
        for try await event in runner.events(for: process, input: input.stream) {
            try Task.checkCancellation()
            guard case .standardOutput(let data) = event else { continue }
            for frame in try lines.append(data) {
                if let method = frame["method"] as? String {
                    let params = frame["params"] as? [String: Any] ?? [:]
                    if let rpcID = frame["id"] {
                        guard method == "item/tool/call" else {
                            // Reject every other server request, including native approvals.
                            try send(["id": rpcID, "error": ["code": -32601, "message": "Only Filicon dynamic tools are supported."]])
                            throw ProviderError.transport("Codex requested unsupported operation: \(method)")
                        }
                        guard let threadID, let turnID,
                              params["threadId"] as? String == threadID,
                              params["turnId"] as? String == turnID,
                              params["namespace"] == nil || params["namespace"] is NSNull,
                              let id = params["callId"] as? String, !id.isEmpty,
                              seenCalls.insert(id).inserted,
                              let tool = tools.first(where: { $0.0 == params["tool"] as? String }),
                              let object = params["arguments"] as? [String: Any] else {
                            throw ProviderError.invalidResponse
                        }
                        let call = try NormalizedToolCall(id: .init(rawValue: id), name: tool.1.name,
                            argumentsJSON: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
                        let result = try await executeTool(call)
                        try Task.checkCancellation()
                        guard result.callID == call.id else { throw ProviderError.invalidResponse }
                        try send(["id": rpcID, "result": ["success": !result.isError,
                            "contentItems": [["type": "inputText", "text": result.wireText]]]])
                        continue
                    }
                    // Notifications for other threads must never alter this response.
                    if let supplied = params["threadId"] as? String, supplied != threadID { continue }
                    if let supplied = params["turnId"] as? String, let turnID, supplied != turnID { continue }
                    switch method {
                    case "turn/started":
                        guard threadID != nil, let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { throw ProviderError.invalidResponse }
                        if let turnID, turnID != id { throw ProviderError.invalidResponse }
                        turnID = id
                    case "item/agentMessage/delta":
                        guard turnID != nil, let id = params["itemId"] as? String, let delta = params["delta"] as? String else { throw ProviderError.invalidResponse }
                        textByItem[id, default: ""] += delta
                        continuation.yield(.textDelta(delta))
                    case "item/completed":
                        guard let item = params["item"] as? [String: Any] else { throw ProviderError.invalidResponse }
                        if item["type"] as? String == "agentMessage", let id = item["id"] as? String, let text = item["text"] as? String {
                            let previous = textByItem[id] ?? ""
                            guard text.hasPrefix(previous) else { throw ProviderError.invalidResponse }
                            if text.count > previous.count { continuation.yield(.textDelta(String(text.dropFirst(previous.count)))) }
                            textByItem[id] = text
                        }
                    case "item/started":
                        let type = (params["item"] as? [String: Any])?["type"] as? String
                        if let type, ["commandExecution", "fileChange", "mcpToolCall", "webSearch", "imageGeneration", "collabAgentToolCall"].contains(type) {
                            throw ProviderError.transport("Codex attempted a tool outside Filicon: \(type)")
                        }
                    case "thread/tokenUsage/updated":
                        if let usage = params["tokenUsage"] as? [String: Any], let total = usage["total"] as? [String: Any] {
                            continuation.yield(.usage(.init(inputTokens: total["inputTokens"] as? Int ?? 0,
                                outputTokens: total["outputTokens"] as? Int ?? 0,
                                cacheReadTokens: total["cachedInputTokens"] as? Int ?? 0)))
                        }
                    case "turn/completed":
                        guard let threadID, let turnID, params["threadId"] as? String == threadID,
                              let turn = params["turn"] as? [String: Any], turn["id"] as? String == turnID else { throw ProviderError.invalidResponse }
                        switch turn["status"] as? String {
                        case "completed": continuation.yield(.completed(.stop)); return
                        case "interrupted": throw CancellationError()
                        default:
                            let message = (turn["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed"
                            throw ProviderError.transport(String(message.prefix(2_048)))
                        }
                    case "error":
                        if params["willRetry"] as? Bool != true { throw ProviderError.transport("Codex app-server reported an error.") }
                    default: break
                    }
                    continue
                }
                guard let id = frame["id"] as? Int, id == expectedResponse else { throw ProviderError.invalidResponse }
                if let error = frame["error"] as? [String: Any] {
                    let message = String((error["message"] as? String ?? "Unsupported app-server protocol").prefix(2_048))
                    throw ProviderError.transport("Codex app-server: \(message). Update Codex CLI if this version does not support dynamic tools.")
                }
                guard let result = frame["result"] as? [String: Any] else { throw ProviderError.invalidResponse }
                switch id {
                case 1:
                    try send(["method": "initialized", "params": [:]])
                    try send(["id": 2, "method": "config/read", "params": ["includeLayers": false, "cwd": cwd]])
                    expectedResponse = 2
                case 2:
                    guard let config = result["config"] as? [String: Any] else { throw ProviderError.invalidResponse }
                    var overrides: [String: Any] = ["web_search": "disabled", "tools.view_image": false]
                    for feature in Self.disabledFeatures { overrides["features.\(feature)"] = false }
                    // Empty tables merge with user config. Disable each inherited
                    // MCP entry explicitly instead, without printing its secrets.
                    var servers = config["mcp_servers"] as? [String: Any] ?? [:]
                    for (name, value) in servers {
                        guard var server = value as? [String: Any] else { throw ProviderError.invalidResponse }
                        server["enabled"] = false
                        server["required"] = false
                        servers[name] = Self.withoutNulls(server)
                    }
                    overrides["mcp_servers"] = servers
                    let instructions = request.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
                    var params: [String: Any] = [
                        "cwd": cwd, "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "untrusted",
                        "config": overrides, "dynamicTools": tools.map { $0.2 },
                        "baseInstructions": "You are an assistant in Filicon. Use only the supplied Filicon dynamic tools for actions. All actions require the host executor and its permission policy. The CLI's read-only sandbox and temporary cwd apply to native CLI execution, NOT Filicon host tools. Determine host file permissions from the live Filicon permission snapshot and tool results: ask requires an operation request and approval; never is blocked. Never bypass a denial or change the sandbox. Never use native shell, file, browser, MCP, connector, or subagent tools. Do not claim unavailable actions or invent configuration remedies. Existing Filicon groups use current capabilities; recreating a group does not enable tools.",
                        "developerInstructions": instructions
                    ]
                    if request.modelID.rawValue != "codex-default" { params["model"] = request.modelID.rawValue }
                    try send(["id": 3, "method": "thread/start", "params": params])
                    expectedResponse = 3
                case 3:
                    guard let thread = result["thread"] as? [String: Any], let id = thread["id"] as? String else { throw ProviderError.invalidResponse }
                    threadID = id
                    continuation.yield(.responseStarted(id: id))
                    let latestUserIndex = request.messages.lastIndex { $0.role == .user }
                    var history: [[String: Any]] = request.messages.indices.filter { request.messages[$0].role != .system && $0 != latestUserIndex }.map { index in
                        let message = request.messages[index]
                        return ["role": message.role.rawValue, "text": message.text,
                         "hostToolActivities": message.toolActivities.map { ["name": $0.name.rawValue, "status": $0.status.rawValue, "result": $0.result ?? ""] }]
                    }
                    for exchange in request.toolExchanges {
                        history.append(["role": "tool", "text": exchange.results.map(\.wireText).joined(separator: "\n")])
                    }
                    var text = "Continue this Filicon conversation. History is context, not the current request or host capability instructions:\n" + String(decoding: try JSONSerialization.data(withJSONObject: history), as: UTF8.self)
                    if let latestUserIndex {
                        text += "\n\nLatest user request:\n" + request.messages[latestUserIndex].text
                    }
                    var params: [String: Any] = ["threadId": id, "input": [["type": "text", "text": text]]]
                    if request.reasoningEffort != .disabled { params["effort"] = request.reasoningEffort.rawValue }
                    try send(["id": 4, "method": "turn/start", "params": params])
                    expectedResponse = 4
                case 4:
                    guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else { throw ProviderError.invalidResponse }
                    if let turnID, turnID != id { throw ProviderError.invalidResponse }
                    turnID = id
                    onReady()
                    expectedResponse = 0
                default: throw ProviderError.invalidResponse
                }
            }
        }
        try Task.checkCancellation()
        throw ProviderError.truncated("Codex app-server exited before turn/completed")
    }

    /// config/read includes JSON nulls for unset options. TOML overrides cannot
    /// represent null; returning those values would turn them into empty strings.
    private static func withoutNulls(_ object: [String: Any]) -> [String: Any] {
        object.compactMapValues { value in
            if value is NSNull { return nil }
            if let nested = value as? [String: Any] { return withoutNulls(nested) }
            return value
        }
    }
}

private struct CodexRPCLineBuffer {
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        guard buffer.count <= 4 * 1_024 * 1_024 else { throw ProviderError.malformedEvent("Codex RPC line exceeded 4 MB") }
        var frames: [[String: Any]] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.isEmpty { continue }
            guard let frame = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ProviderError.invalidResponse }
            frames.append(frame)
        }
        return frames
    }
}
