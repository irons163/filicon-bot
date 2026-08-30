import Foundation
import FiliconDomain

public typealias CredentialResolver = @Sendable () async throws -> String

private enum WireFormat: Sendable { case openAIResponses, openAIChat, anthropic, gemini, ollama }

private struct JSONValue: @unchecked Sendable {
    let object: [String: Any]
    init(_ text: String) throws {
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8)), let object = value as? [String: Any] else {
            throw ProviderError.malformedEvent(text)
        }
        self.object = object
    }
    func string(_ path: String...) -> String? { value(path) as? String }
    func int(_ path: String...) -> Int? { value(path) as? Int }
    func dictionary(_ path: String...) -> [String: Any]? { value(path) as? [String: Any] }
    private func value(_ path: [String]) -> Any? {
        var current: Any = object
        for key in path { guard let next = (current as? [String: Any])?[key] else { return nil }; current = next }
        return current
    }
}

private struct DecodeState {
    var terminal = false
    var started = false
    var pendingFinishReason: FinishReason?
    var tools: [String: ToolAccumulator] = [:]
    var completedToolIDs = Set<ToolCallID>()
    var nextGeminiID = 0
    var hadTools = false
}

private struct ToolAccumulator {
    var id: ToolCallID
    var name: ToolName
    var arguments = ""
    var started = false
}

private struct HTTPStreamingProvider: AIProvider {
    let descriptor: ProviderDescriptor
    let availableModels: [AIModel]
    let baseURL: URL
    let credential: CredentialResolver?
    let format: WireFormat
    let session: URLSession
    let catalog: ProviderModelCatalog

    func models() async throws -> [AIModel] { await catalog.snapshot().models }
    func modelCatalog(forceRefresh: Bool) async -> ProviderModelCatalogSnapshot { await catalog.snapshot(forceRefresh: forceRefresh) }

    func stream(_ input: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try await makeRequest(input)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
                    guard let finalURL = http.url, Self.sameOrigin(request.url!, finalURL) else { throw ProviderError.transport("cross-origin redirect rejected") }
                    guard (200..<300).contains(http.statusCode) else { throw ProviderError.httpStatus(http.statusCode) }
                    var sse = SSEParser(), ndjson = NDJSONParser(), state = DecodeState()
                    var packet = Data(); packet.reserveCapacity(2048)
                    for try await byte in bytes {
                        try Task.checkCancellation(); packet.append(byte)
                        if byte == 0x0A || byte == 0x0D || packet.count >= 2048 {
                            let records = format == .ollama ? ndjson.feed(packet) : sse.feed(packet)
                            packet.removeAll(keepingCapacity: true)
                            try emit(records, state: &state, to: continuation)
                        }
                    }
                    let records = format == .ollama ? ndjson.feed(packet) + ndjson.finish() : sse.feed(packet) + sse.finish()
                    try emit(records, state: &state, to: continuation)
                    guard state.terminal else { throw ProviderError.truncated("EOF arrived without a terminal provider event") }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: ProviderError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func makeRequest(_ input: InferenceRequest) async throws -> URLRequest {
        let catalogSnapshot = await catalog.snapshot()
        let model = catalogSnapshot.models.first { $0.id == input.modelID }
        if catalogSnapshot.source == .dynamic, model == nil { throw ProviderError.modelUnavailable(input.modelID) }
        if let model {
            guard model.capabilities.supports(input.reasoningEffort) else { throw ProviderError.unsupportedReasoningEffort(model: input.modelID, effort: input.reasoningEffort) }
            try validateModalities(input, capabilities: model.capabilities)
        } else if input.reasoningEffort != .disabled {
            throw ProviderError.unsupportedReasoningEffort(model: input.modelID, effort: input.reasoningEffort)
        }
        let key = try await credential?() ?? ""
        let endpoint: URL
        switch format {
        case .openAIResponses: endpoint = baseURL.appending(path: "responses")
        case .openAIChat: endpoint = baseURL.appending(path: "chat/completions")
        case .anthropic: endpoint = baseURL.appending(path: "v1/messages")
        case .gemini: endpoint = baseURL.appending(path: "v1beta/models/\(input.modelID.rawValue):streamGenerateContent").appending(queryItems: [.init(name: "alt", value: "sse")])
        case .ollama: endpoint = baseURL.appending(path: "api/chat")
        }
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch format {
        case .openAIResponses, .openAIChat: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic: request.setValue(key, forHTTPHeaderField: "x-api-key"); request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .ollama: break
        }
        let body: [String: Any]
        switch format {
        case .openAIResponses:
            var value: [String: Any] = ["model": input.modelID.rawValue, "stream": true, "input": try responsesInput(input)]
            if !input.tools.isEmpty { value["tools"] = try input.tools.map(openAIResponseTool) }
            if input.reasoningEffort != .disabled { value["reasoning"] = ["effort": input.reasoningEffort.rawValue, "summary": "auto"] }
            body = value
        case .openAIChat:
            var value: [String: Any] = ["model": input.modelID.rawValue, "stream": true, "messages": try chatMessages(input)]
            if !input.tools.isEmpty { value["tools"] = try input.tools.map(openAIChatTool) }
            if input.reasoningEffort != .disabled { value["reasoning"] = ["effort": input.reasoningEffort.rawValue] }
            body = value
        case .anthropic:
            let outputTokens = input.reasoningEffort == .disabled ? 4_096 : max(4_096, reasoningBudget(input.reasoningEffort) + 1_024)
            var value: [String: Any] = ["model": input.modelID.rawValue, "stream": true, "max_tokens": outputTokens,
                "messages": try anthropicMessages(input)]
            let system = input.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            if !system.isEmpty { value["system"] = system }
            if !input.tools.isEmpty { value["tools"] = try input.tools.map(anthropicTool) }
            if input.reasoningEffort != .disabled { value["thinking"] = ["type": "enabled", "budget_tokens": reasoningBudget(input.reasoningEffort)] }
            body = value
        case .gemini:
            var value: [String: Any] = ["contents": try geminiContents(input)]
            let system = input.messages.filter { $0.role == .system }.map(\.text).joined(separator: "\n\n")
            if !system.isEmpty { value["systemInstruction"] = ["parts": [["text": system]]] }
            if !input.tools.isEmpty { value["tools"] = [["functionDeclarations": try input.tools.map(geminiTool)]] }
            if input.reasoningEffort != .disabled { value["generationConfig"] = ["thinkingConfig": ["thinkingBudget": reasoningBudget(input.reasoningEffort)]] }
            body = value
        case .ollama:
            var value: [String: Any] = ["model": input.modelID.rawValue, "stream": true, "messages": try ollamaMessages(input)]
            value["think"] = input.reasoningEffort == .disabled ? false : input.reasoningEffort.rawValue
            body = value
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func reasoningBudget(_ effort: ReasoningEffort) -> Int {
        switch effort { case .disabled: 0; case .minimal: 512; case .low: 1_024; case .medium: 4_096; case .high: 8_192; case .xhigh: 16_384 }
    }

    private func validateModalities(_ input: InferenceRequest, capabilities: AIModelCapabilities) throws {
        if !input.tools.isEmpty, !capabilities.inputModalities.contains(.tools) { throw ProviderError.unsupportedAttachment("tools") }
        for attachments in input.attachmentsByMessageID.values {
            for attachment in attachments {
                let modality: AIModelModality
                switch attachment.metadata.kind { case .image: modality = .image; case .audio: modality = .audio; case .video: modality = .video; case .document: modality = .document; case .other: throw ProviderError.unsupportedAttachment(attachment.metadata.filename) }
                guard capabilities.inputModalities.contains(modality) else { throw ProviderError.unsupportedAttachment(attachment.metadata.filename) }
            }
        }
    }

    private func dataURL(_ attachment: InferenceAttachment) -> String {
        "data:\(attachment.metadata.mimeType);base64,\(attachment.data.base64EncodedString())"
    }

    private func schemaObject(_ descriptor: ToolDescriptor) throws -> Any {
        do { return try JSONSerialization.jsonObject(with: descriptor.inputSchema) }
        catch { throw ProviderError.malformedEvent("Invalid schema for tool \(descriptor.name.rawValue)") }
    }
    private func argumentsObject(_ call: NormalizedToolCall) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any] else { throw ProviderError.malformedEvent("Invalid arguments for tool \(call.name.rawValue)") }
        return object
    }
    private func openAIResponseTool(_ value: ToolDescriptor) throws -> [String: Any] { ["type": "function", "name": value.name.rawValue, "description": value.description ?? "", "parameters": try schemaObject(value)] }
    private func openAIChatTool(_ value: ToolDescriptor) throws -> [String: Any] { ["type": "function", "function": ["name": value.name.rawValue, "description": value.description ?? "", "parameters": try schemaObject(value)]] }
    private func anthropicTool(_ value: ToolDescriptor) throws -> [String: Any] { ["name": value.name.rawValue, "description": value.description ?? "", "input_schema": try schemaObject(value)] }
    private func geminiTool(_ value: ToolDescriptor) throws -> [String: Any] { ["name": value.name.rawValue, "description": value.description ?? "", "parameters": try schemaObject(value)] }

    private func responsesInput(_ input: InferenceRequest) throws -> [[String: Any]] {
        var rows: [[String: Any]] = try input.messages.map { message in
            let attachments = input.attachmentsByMessageID[message.id] ?? []
            guard !attachments.isEmpty else { return ["role": message.role.rawValue, "content": message.text] }
            var content: [[String: Any]] = message.text.isEmpty ? [] : [["type": "input_text", "text": message.text]]
            for attachment in attachments {
                switch attachment.metadata.kind {
                case .image:
                    content.append(["type": "input_image", "image_url": dataURL(attachment)])
                case .document:
                    content.append(["type": "input_file", "filename": attachment.metadata.filename, "file_data": dataURL(attachment)])
                default: throw ProviderError.unsupportedAttachment(attachment.metadata.filename)
                }
            }
            return ["role": message.role.rawValue, "content": content]
        }
        for exchange in input.toolExchanges {
            if !exchange.assistantText.isEmpty { rows.append(["role": "assistant", "content": exchange.assistantText]) }
            rows += exchange.calls.map { ["type": "function_call", "call_id": $0.id.rawValue, "name": $0.name.rawValue, "arguments": String(decoding: $0.argumentsJSON, as: UTF8.self)] }
            rows += exchange.results.map { ["type": "function_call_output", "call_id": $0.callID.rawValue, "output": $0.wireText] }
        }
        return rows
    }
    private func chatMessages(_ input: InferenceRequest) throws -> [[String: Any]] {
        var rows: [[String: Any]] = try input.messages.map { message in
            let attachments = input.attachmentsByMessageID[message.id] ?? []
            guard !attachments.isEmpty else { return ["role": message.role.rawValue, "content": message.text] }
            var content: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
            for attachment in attachments {
                guard attachment.metadata.kind == .image else { throw ProviderError.unsupportedAttachment(attachment.metadata.filename) }
                content.append(["type": "image_url", "image_url": ["url": dataURL(attachment)]])
            }
            return ["role": message.role.rawValue, "content": content]
        }
        for exchange in input.toolExchanges {
            rows.append(["role": "assistant", "content": exchange.assistantText, "tool_calls": exchange.calls.map { ["id": $0.id.rawValue, "type": "function", "function": ["name": $0.name.rawValue, "arguments": String(decoding: $0.argumentsJSON, as: UTF8.self)]] }])
            rows += exchange.results.map { ["role": "tool", "tool_call_id": $0.callID.rawValue, "content": $0.wireText] }
        }
        return rows
    }
    private func anthropicMessages(_ input: InferenceRequest) throws -> [[String: Any]] {
        var rows = try input.messages.filter { $0.role != .system }.map { message -> [String: Any] in
            let attachments = input.attachmentsByMessageID[message.id] ?? []
            guard !attachments.isEmpty else { return ["role": message.role == .assistant ? "assistant" : "user", "content": message.text] }
            var content: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
            for attachment in attachments {
                let source: [String: Any] = ["type": "base64", "media_type": attachment.metadata.mimeType, "data": attachment.data.base64EncodedString()]
                switch attachment.metadata.kind {
                case .image: content.append(["type": "image", "source": source])
                case .document where attachment.metadata.mimeType == "application/pdf": content.append(["type": "document", "source": source])
                default: throw ProviderError.unsupportedAttachment(attachment.metadata.filename)
                }
            }
            return ["role": message.role == .assistant ? "assistant" : "user", "content": content]
        }
        for exchange in input.toolExchanges {
            var assistant: [[String: Any]] = exchange.assistantText.isEmpty ? [] : [["type": "text", "text": exchange.assistantText]]
            assistant += try exchange.calls.map { call in ["type": "tool_use", "id": call.id.rawValue, "name": call.name.rawValue, "input": try argumentsObject(call)] }
            rows.append(["role": "assistant", "content": assistant])
            rows.append(["role": "user", "content": exchange.results.map { ["type": "tool_result", "tool_use_id": $0.callID.rawValue, "content": $0.wireText, "is_error": $0.isError] }])
        }
        return rows
    }
    private func geminiContents(_ input: InferenceRequest) throws -> [[String: Any]] {
        var rows = try input.messages.filter { $0.role != .system }.map { message -> [String: Any] in
            var parts: [[String: Any]] = message.text.isEmpty ? [] : [["text": message.text]]
            for attachment in input.attachmentsByMessageID[message.id] ?? [] {
                switch attachment.metadata.kind {
                case .image, .audio, .video, .document:
                    parts.append(["inlineData": ["mimeType": attachment.metadata.mimeType, "data": attachment.data.base64EncodedString()]])
                case .other: throw ProviderError.unsupportedAttachment(attachment.metadata.filename)
                }
            }
            return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
        }
        for exchange in input.toolExchanges {
            var parts: [[String: Any]] = exchange.assistantText.isEmpty ? [] : [["text": exchange.assistantText]]
            parts += try exchange.calls.map { call in ["functionCall": ["id": call.id.rawValue, "name": call.name.rawValue, "args": try argumentsObject(call)]] }
            rows.append(["role": "model", "parts": parts])
            rows.append(["role": "user", "parts": exchange.results.map { result in
                ["functionResponse": ["id": result.callID.rawValue, "name": exchange.calls.first(where: { $0.id == result.callID })?.name.rawValue ?? "tool", "response": ["output": result.wireText, "isError": result.isError]]]
            }])
        }
        return rows
    }

    private func ollamaMessages(_ input: InferenceRequest) throws -> [[String: Any]] {
        try input.messages.map { message in
            let attachments = input.attachmentsByMessageID[message.id] ?? []
            for attachment in attachments where attachment.metadata.kind != .image {
                throw ProviderError.unsupportedAttachment(attachment.metadata.filename)
            }
            var row: [String: Any] = ["role": message.role.rawValue, "content": message.text]
            if !attachments.isEmpty { row["images"] = attachments.map { $0.data.base64EncodedString() } }
            return row
        }
    }

    private func emit(_ records: [String], state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        for record in records {
            if record == "[DONE]" {
                guard format == .openAIChat || format == .openAIResponses else { continue }
                if !state.terminal { c.yield(.completed(.unknown)) }; state.terminal = true; continue
            }
            let json = try JSONValue(record)
            switch format {
            case .openAIResponses: try emitOpenAIResponses(json, state: &state, to: c)
            case .openAIChat: try emitOpenAIChat(json, state: &state, to: c)
            case .anthropic: try emitAnthropic(json, state: &state, to: c)
            case .gemini: try emitGemini(json, state: &state, to: c)
            case .ollama: try emitOllama(json, state: &state, to: c)
            }
        }
    }

    private func emitOpenAIResponses(_ j: JSONValue, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        switch j.string("type") {
        case "response.created": c.yield(.responseStarted(id: j.string("response", "id")))
        case "response.output_text.delta": if let text = j.string("delta") { c.yield(.textDelta(text)) }
        case "response.reasoning_summary_text.delta": if let text = j.string("delta") { c.yield(.reasoningDelta(text)) }
        case "response.output_item.added":
            if j.string("item", "type") == "function_call", let name = j.string("item", "name") {
                let key = j.string("item", "id") ?? j.string("item", "call_id") ?? "response-tool-\(state.tools.count)"
                try startTool(key: key, id: j.string("item", "call_id") ?? key, name: name, state: &state, to: c)
            }
        case "response.function_call_arguments.delta":
            let key = j.string("item_id") ?? j.string("call_id") ?? ""
            try appendToolDelta(key: key, delta: j.string("delta") ?? "", state: &state, to: c)
        case "response.output_item.done":
            if j.string("item", "type") == "function_call", let name = j.string("item", "name") {
                let key = j.string("item", "id") ?? j.string("item", "call_id") ?? "response-tool-\(state.tools.count)"
                try completeTool(key: key, id: j.string("item", "call_id") ?? key, name: name, arguments: j.string("item", "arguments"), state: &state, to: c)
            }
        case "response.completed":
            if let usage = j.dictionary("response", "usage") {
                emitUsage(
                    usage, "input_tokens", "output_tokens",
                    cacheRead: nestedInteger(usage, "input_tokens_details", "cached_tokens"),
                    cacheWrite: integer(usage["cache_write_input_tokens"]),
                    to: c
                )
            }
            c.yield(.completed(state.hadTools ? .toolUse : .stop)); state.terminal = true
        case "response.incomplete":
            let reason = j.string("response", "incomplete_details", "reason") ?? "unknown"
            if reason == "max_output_tokens" { c.yield(.completed(.length)); state.terminal = true }
            else if reason.contains("content_filter") { throw ProviderError.refusal(reason) }
            else { throw ProviderError.truncated("OpenAI response incomplete: \(reason)") }
        case "response.failed": throw providerError(j.string("response", "error", "code"), j.string("response", "error", "message") ?? "OpenAI response failed")
        case "error": throw providerError(j.string("error", "type") ?? j.string("code"), j.string("error", "message") ?? j.string("message") ?? "OpenAI stream error")
        default: break
        }
    }

    private func emitOpenAIChat(_ j: JSONValue, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        if let error = j.dictionary("error") { throw providerError(error["code"] as? String ?? error["type"] as? String, error["message"] as? String ?? "Chat Completions error") }
        if !state.started, let id = j.string("id") { c.yield(.responseStarted(id: id)); state.started = true }
        if let choices = j.object["choices"] as? [[String: Any]] {
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any] {
                    if let text = delta["content"] as? String { c.yield(.textDelta(text)) }
                    if let text = delta["reasoning"] as? String { c.yield(.reasoningDelta(text)) }
                    if let tools = delta["tool_calls"] as? [[String: Any]] {
                        for tool in tools {
                            let index = tool["index"] as? Int ?? 0, key = "chat-\(index)"
                            let function = tool["function"] as? [String: Any]
                            if let id = tool["id"] as? String, let name = function?["name"] as? String { try startTool(key: key, id: id, name: name, state: &state, to: c) }
                            if let fragment = function?["arguments"] as? String { try appendToolDelta(key: key, delta: fragment, state: &state, to: c) }
                        }
                    }
                }
                if let finish = choice["finish_reason"] as? String {
                    if finish == "content_filter" { throw ProviderError.refusal(finish) }
                    if finish == "tool_calls" { for key in state.tools.keys.sorted() where !state.completedToolIDs.contains(state.tools[key]!.id) { try completeTool(key: key, state: &state, to: c) } }
                    c.yield(.completed(finishReason(finish))); state.terminal = true
                }
            }
        }
        if let usage = j.dictionary("usage") {
            emitUsage(
                usage, "prompt_tokens", "completion_tokens",
                cacheRead: nestedInteger(usage, "prompt_tokens_details", "cached_tokens"),
                cacheWrite: integer(usage["cache_write_input_tokens"]),
                costMicros: dollarMicros(usage["cost"]),
                to: c
            )
        }
    }

    private func emitAnthropic(_ j: JSONValue, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        switch j.string("type") {
        case "message_start":
            c.yield(.responseStarted(id: j.string("message", "id")))
            if let usage = j.dictionary("message", "usage") {
                emitUsage(
                    usage, "input_tokens", "output_tokens",
                    cacheRead: integer(usage["cache_read_input_tokens"]),
                    cacheWrite: integer(usage["cache_creation_input_tokens"]),
                    to: c
                )
            }
        case "content_block_start":
            if j.string("content_block", "type") == "tool_use", let id = j.string("content_block", "id"), let name = j.string("content_block", "name") {
                let key = "anthropic-\(j.int("index") ?? state.tools.count)"
                try startTool(key: key, id: id, name: name, state: &state, to: c)
                if let input = j.dictionary("content_block", "input"), !input.isEmpty { try completeTool(key: key, argumentsData: try JSONSerialization.data(withJSONObject: input, options: .sortedKeys), state: &state, to: c) }
            }
        case "content_block_delta":
            if let text = j.string("delta", "text") { c.yield(.textDelta(text)) }; if let text = j.string("delta", "thinking") { c.yield(.reasoningDelta(text)) }
            if let fragment = j.string("delta", "partial_json") { try appendToolDelta(key: "anthropic-\(j.int("index") ?? 0)", delta: fragment, state: &state, to: c) }
        case "content_block_stop":
            let key = "anthropic-\(j.int("index") ?? 0)"
            if state.tools[key] != nil, !state.completedToolIDs.contains(state.tools[key]!.id) { try completeTool(key: key, state: &state, to: c) }
        case "message_delta":
            if let stop = j.string("delta", "stop_reason") { state.pendingFinishReason = finishReason(stop) }
            if let usage = j.dictionary("usage") {
                emitUsage(
                    usage, "input_tokens", "output_tokens",
                    cacheRead: integer(usage["cache_read_input_tokens"]),
                    cacheWrite: integer(usage["cache_creation_input_tokens"]),
                    to: c
                )
            }
        case "message_stop": c.yield(.completed(state.pendingFinishReason ?? .unknown)); state.terminal = true
        case "error": throw providerError(j.string("error", "type"), j.string("error", "message") ?? "Anthropic stream error")
        default: break
        }
    }

    private func emitGemini(_ j: JSONValue, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        if let block = j.string("promptFeedback", "blockReason") { throw ProviderError.refusal("Gemini prompt blocked: \(block)") }
        if let error = j.dictionary("error") { throw providerError(error["status"] as? String, error["message"] as? String ?? "Gemini stream error") }
        if let candidates = j.object["candidates"] as? [[String: Any]] {
            for candidate in candidates {
                if let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] {
                    for text in parts.compactMap({ $0["text"] as? String }) { c.yield(.textDelta(text)) }
                    for part in parts {
                        guard let function = part["functionCall"] as? [String: Any], let name = function["name"] as? String else { continue }
                        let id = function["id"] as? String ?? "gemini-\(state.nextGeminiID)"; state.nextGeminiID += 1
                        let data = try JSONSerialization.data(withJSONObject: function["args"] as? [String: Any] ?? [:], options: .sortedKeys)
                        let key = "gemini-key-\(id)"; try startTool(key: key, id: id, name: name, state: &state, to: c); try completeTool(key: key, argumentsData: data, state: &state, to: c)
                    }
                }
                if let finish = candidate["finishReason"] as? String {
                    if ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"].contains(finish) { throw ProviderError.refusal("Gemini finish reason: \(finish)") }
                    c.yield(.completed(state.hadTools ? .toolUse : finishReason(finish))); state.terminal = true
                }
            }
        }
        if let usage = j.dictionary("usageMetadata") {
            emitUsage(
                usage, "promptTokenCount", "candidatesTokenCount",
                cacheRead: integer(usage["cachedContentTokenCount"]),
                to: c
            )
        }
    }

    private func emitOllama(_ j: JSONValue, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        if let message = j.string("error") { throw providerError(nil, message) }
        if let text = j.string("message", "content"), !text.isEmpty { c.yield(.textDelta(text)) }
        if (j.object["done"] as? Bool) == true {
            c.yield(.usage(.init(inputTokens: j.int("prompt_eval_count") ?? 0, outputTokens: j.int("eval_count") ?? 0)))
            c.yield(.completed(finishReason(j.string("done_reason") ?? "stop"))); state.terminal = true
        }
    }

    private func emitUsage(
        _ usage: [String: Any]?,
        _ inputKey: String,
        _ outputKey: String,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        costMicros: Int64 = 0,
        to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation
    ) {
        guard let usage else { return }
        c.yield(.usage(.init(
            inputTokens: integer(usage[inputKey]),
            outputTokens: integer(usage[outputKey]),
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite,
            costMicros: costMicros
        )))
    }

    private func integer(_ value: Any?) -> Int {
        if let value = value as? Int { return max(0, value) }
        if let value = value as? NSNumber { return max(0, value.intValue) }
        return 0
    }

    private func nestedInteger(_ object: [String: Any], _ parent: String, _ child: String) -> Int {
        integer((object[parent] as? [String: Any])?[child])
    }

    private func dollarMicros(_ value: Any?) -> Int64 {
        let dollars: Double
        if let value = value as? Double { dollars = value }
        else if let value = value as? NSNumber { dollars = value.doubleValue }
        else { return 0 }
        guard dollars.isFinite, dollars > 0, dollars <= Double(Int64.max) / 1_000_000 else { return 0 }
        return Int64((dollars * 1_000_000).rounded())
    }
    private func startTool(key: String, id: String, name: String, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        let callID = ToolCallID(rawValue: id), toolName = ToolName(rawValue: name)
        guard !id.isEmpty, !name.isEmpty else { throw ProviderError.malformedEvent("Tool call identity is empty") }
        if let current = state.tools[key] {
            guard current.id == callID, current.name == toolName else { throw ProviderError.malformedEvent("Tool call correlation changed for \(key)") }
            return
        }
        guard !state.completedToolIDs.contains(callID), !state.tools.values.contains(where: { $0.id == callID }) else { throw ProviderError.malformedEvent("Duplicate tool call ID \(id)") }
        state.tools[key] = ToolAccumulator(id: callID, name: toolName, started: true); state.hadTools = true
        c.yield(.toolCallStarted(id: callID, name: toolName))
    }
    private func appendToolDelta(key: String, delta: String, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        guard var value = state.tools[key] else { throw ProviderError.malformedEvent("Arguments arrived before tool start for \(key)") }
        value.arguments += delta; state.tools[key] = value
        c.yield(.toolCallArgumentsDelta(id: value.id, delta: delta))
    }
    private func completeTool(key: String, id: String? = nil, name: String? = nil, arguments: String? = nil, argumentsData: Data? = nil, state: inout DecodeState, to c: AsyncThrowingStream<InferenceEvent, Error>.Continuation) throws {
        if state.tools[key] == nil, let id, let name { try startTool(key: key, id: id, name: name, state: &state, to: c) }
        guard let value = state.tools[key] else { throw ProviderError.malformedEvent("Tool completion arrived before start for \(key)") }
        guard !state.completedToolIDs.contains(value.id) else { throw ProviderError.malformedEvent("Duplicate tool completion \(value.id.rawValue)") }
        let data = argumentsData ?? Data((arguments ?? value.arguments).utf8)
        let call: NormalizedToolCall
        do { call = try NormalizedToolCall(id: value.id, name: value.name, argumentsJSON: data) }
        catch { throw ProviderError.malformedEvent("Tool \(value.id.rawValue) arguments are not one complete JSON object") }
        state.completedToolIDs.insert(value.id); c.yield(.toolCallCompleted(call))
    }
    private func finishReason(_ value: String) -> FinishReason {
        switch value.lowercased() {
        case "stop", "end_turn", "stop_sequence": .stop
        case "length", "max_tokens", "max_output_tokens": .length
        case "tool_use", "tool_calls": .toolUse
        case "cancelled", "canceled": .cancelled
        default: .unknown
        }
    }
    private func providerError(_ type: String?, _ message: String) -> ProviderError {
        let type = (type ?? "").lowercased()
        if type.contains("auth") || type.contains("permission") || type.contains("api_key") { return .authentication(message) }
        if type.contains("rate") || type.contains("quota") || type.contains("resource_exhausted") || type.contains("overloaded") { return .rateLimit(message) }
        if type.contains("safety") || type.contains("content_filter") || type.contains("refusal") { return .refusal(message) }
        return .transport(message)
    }
    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }
}

private final class ProviderOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let redirected = request.url else { completionHandler(nil); return }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        let same = original.scheme?.lowercased() == redirected.scheme?.lowercased()
            && original.host?.lowercased() == redirected.host?.lowercased() && port(original) == port(redirected)
        completionHandler(same ? request : nil)
    }
}

private func productionProviderSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 15 * 60
    return URLSession(configuration: configuration, delegate: ProviderOriginRedirectDelegate(), delegateQueue: nil)
}

public struct OpenAIProvider: AIProvider, DynamicModelCatalogProviding {
    private let core: HTTPStreamingProvider; public var descriptor: ProviderDescriptor { core.descriptor }
    public init(baseURL: URL = URL(string: "https://api.openai.com/v1")!, models: [AIModel] = [.init(id: "gpt-5.4", capabilities: .init(inputModalities: [.text, .image, .document, .tools], reasoningEfforts: [.disabled, .minimal, .low, .medium, .high]))], credential: @escaping CredentialResolver, session: URLSession? = nil) { let session = session ?? productionProviderSession(); let catalog = ProviderModelCatalog(providerID: "openai", baseURL: baseURL, format: .openAI, fallback: models, credential: credential, session: session); core = .init(descriptor: .init(id: "openai", displayName: "OpenAI", requiresAPIKey: true), availableModels: models, baseURL: baseURL, credential: credential, format: .openAIResponses, session: session, catalog: catalog) }
    public func models() async throws -> [AIModel] { try await core.models() }; public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { core.stream(request) }
    public func modelCatalog(forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot { await core.modelCatalog(forceRefresh: forceRefresh) }
}
public struct OpenRouterProvider: AIProvider, DynamicModelCatalogProviding {
    private let core: HTTPStreamingProvider; public var descriptor: ProviderDescriptor { core.descriptor }
    public init(baseURL: URL = URL(string: "https://openrouter.ai/api/v1")!, models: [AIModel] = [.init(id: "openai/gpt-4.1-mini", capabilities: .init(inputModalities: [.text, .image, .tools]))], credential: @escaping CredentialResolver, session: URLSession? = nil) { let session = session ?? productionProviderSession(); let catalog = ProviderModelCatalog(providerID: "openrouter", baseURL: baseURL, format: .openRouter, fallback: models, credential: credential, session: session); core = .init(descriptor: .init(id: "openrouter", displayName: "OpenRouter", requiresAPIKey: true), availableModels: models, baseURL: baseURL, credential: credential, format: .openAIChat, session: session, catalog: catalog) }
    public func models() async throws -> [AIModel] { try await core.models() }; public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { core.stream(request) }
    public func modelCatalog(forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot { await core.modelCatalog(forceRefresh: forceRefresh) }
}
public struct AnthropicProvider: AIProvider, DynamicModelCatalogProviding {
    private let core: HTTPStreamingProvider; public var descriptor: ProviderDescriptor { core.descriptor }
    public init(baseURL: URL = URL(string: "https://api.anthropic.com")!, models: [AIModel] = [.init(id: "claude-sonnet-4-5", capabilities: .init(inputModalities: [.text, .image, .document, .tools], reasoningEfforts: [.disabled, .low, .medium, .high]))], credential: @escaping CredentialResolver, session: URLSession? = nil) { let session = session ?? productionProviderSession(); let catalog = ProviderModelCatalog(providerID: "anthropic", baseURL: baseURL, format: .anthropic, fallback: models, credential: credential, session: session); core = .init(descriptor: .init(id: "anthropic", displayName: "Anthropic", requiresAPIKey: true), availableModels: models, baseURL: baseURL, credential: credential, format: .anthropic, session: session, catalog: catalog) }
    public func models() async throws -> [AIModel] { try await core.models() }; public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { core.stream(request) }
    public func modelCatalog(forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot { await core.modelCatalog(forceRefresh: forceRefresh) }
}
public struct GeminiProvider: AIProvider, DynamicModelCatalogProviding {
    private let core: HTTPStreamingProvider; public var descriptor: ProviderDescriptor { core.descriptor }
    public init(baseURL: URL = URL(string: "https://generativelanguage.googleapis.com")!, models: [AIModel] = [.init(id: "gemini-2.5-flash", capabilities: .init(inputModalities: [.text, .image, .audio, .video, .document, .tools], reasoningEfforts: [.disabled, .low, .medium, .high]))], credential: @escaping CredentialResolver, session: URLSession? = nil) { let session = session ?? productionProviderSession(); let catalog = ProviderModelCatalog(providerID: "gemini", baseURL: baseURL, format: .gemini, fallback: models, credential: credential, session: session); core = .init(descriptor: .init(id: "gemini", displayName: "Google Gemini", requiresAPIKey: true), availableModels: models, baseURL: baseURL, credential: credential, format: .gemini, session: session, catalog: catalog) }
    public func models() async throws -> [AIModel] { try await core.models() }; public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { core.stream(request) }
    public func modelCatalog(forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot { await core.modelCatalog(forceRefresh: forceRefresh) }
}
public struct OllamaProvider: AIProvider, DynamicModelCatalogProviding {
    private let core: HTTPStreamingProvider; public var descriptor: ProviderDescriptor { core.descriptor }
    public init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, models: [AIModel] = [.init(id: "llama3.2")], session: URLSession? = nil) { let session = session ?? productionProviderSession(); let catalog = ProviderModelCatalog(providerID: "ollama", baseURL: baseURL, format: .ollama, fallback: models, credential: nil, session: session); core = .init(descriptor: .init(id: "ollama", displayName: "Ollama (local)", requiresAPIKey: false), availableModels: models, baseURL: baseURL, credential: nil, format: .ollama, session: session, catalog: catalog) }
    public func models() async throws -> [AIModel] { try await core.models() }; public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> { core.stream(request) }
    public func modelCatalog(forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot { await core.modelCatalog(forceRefresh: forceRefresh) }
}
