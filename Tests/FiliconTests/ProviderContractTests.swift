import Foundation
import Testing
import CustomDump
@testable import FiliconDomain
@testable import FiliconProviderKit
import FiliconAppServices

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func contractSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ContractURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var collected = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            collected.append(buffer, count: count)
        }
        data = collected
    } else {
        throw ProviderError.malformedEvent("missing request body")
    }
    guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ProviderError.malformedEvent("missing request body")
    }
    return body
}

private func collect(_ provider: any AIProvider, model: ModelID = "fixture", messages: [ChatMessage] = []) async throws -> [InferenceEvent] {
    var events: [InferenceEvent] = []
    for try await event in provider.stream(.init(conversationID: UUID(), modelID: model, messages: messages)) { events.append(event) }
    return events
}

private func collect(_ provider: any AIProvider, request: InferenceRequest) async throws -> [InferenceEvent] {
    var events: [InferenceEvent] = []
    for try await event in provider.stream(request) { events.append(event) }
    return events
}

@Suite(.serialized)
struct ProviderContractTests {
    @Test(arguments: ["responses", "chat", "anthropic", "gemini"])
    func privateTextOnlyExchangeDoesNotInventEmptyToolCallsOrResultMessages(format: String) async throws {
        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request)
            let rowKey = format == "responses" ? "input" : format == "gemini" ? "contents" : "messages"
            let rows = try #require(body[rowKey] as? [[String: Any]])
            expectNoDifference(rows.count, 2)
            let last = try #require(rows.last)
            expectNoDifference(last["role"] as? String, format == "gemini" ? "model" : "assistant")
            #expect(last["tool_calls"] == nil)
            if format == "anthropic" {
                let content = try #require(last["content"] as? [[String: String]])
                expectNoDifference(content, [["type": "text", "text": "PRIVATE_EPHEMERAL_RESULT"]])
            } else if format == "gemini" {
                let parts = try #require(last["parts"] as? [[String: String]])
                expectNoDifference(parts, [["text": "PRIVATE_EPHEMERAL_RESULT"]])
            } else { expectNoDifference(last["content"] as? String, "PRIVATE_EPHEMERAL_RESULT") }
            let completion: String
            switch format {
            case "responses": completion = "data: {\"type\":\"response.completed\",\"response\":{\"usage\":{}}}\n\ndata: [DONE]\n\n"
            case "chat": completion = "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            case "anthropic": completion = "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
            default: completion = "data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n"
            }
            return (200, Data(completion.utf8))
        }
        let provider: any AIProvider
        switch format {
        case "responses": provider = OpenAIProvider(credential: { "FAKE_KEY" }, session: contractSession())
        case "chat": provider = OpenRouterProvider(credential: { "FAKE_KEY" }, session: contractSession())
        case "anthropic": provider = AnthropicProvider(credential: { "FAKE_KEY" }, session: contractSession())
        default: provider = GeminiProvider(credential: { "FAKE_KEY" }, session: contractSession())
        }
        let request = InferenceRequest(conversationID: UUID(), modelID: "fixture", messages: [.init(role: .user, text: "Isolated initial input")],
            toolExchanges: [.init(assistantText: "PRIVATE_EPHEMERAL_RESULT", calls: [], results: []), .init(calls: [], results: [])])
        let events = try await collect(provider, request: request)
        #expect(events.contains(.completed(.stop)))
    }

    @Test func providerUsageIncludesCacheAndCostWithoutDoubleCountingCumulativeFrames() async throws {
        ContractURLProtocol.handler = { _ in
            let fixture = """
            data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":40}}}}

            data: [DONE]

            """
            return (200, Data(fixture.utf8))
        }
        let openAI = try await collect(OpenAIProvider(credential: { "key" }, session: contractSession()))
        #expect(openAI.contains(.usage(.init(inputTokens: 100, outputTokens: 20, cacheReadTokens: 40))))

        ContractURLProtocol.handler = { _ in
            let fixture = """
            data: {"id":"r","choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":80,"completion_tokens":10,"prompt_tokens_details":{"cached_tokens":30},"cost":0.00125}}

            data: [DONE]

            """
            return (200, Data(fixture.utf8))
        }
        let router = try await collect(OpenRouterProvider(credential: { "key" }, session: contractSession()))
        #expect(router.contains(.usage(.init(inputTokens: 80, outputTokens: 10, cacheReadTokens: 30, costMicros: 1_250))))

        ContractURLProtocol.handler = { _ in
            let fixture = """
            data: {"type":"message_start","message":{"id":"a","usage":{"input_tokens":70,"output_tokens":0,"cache_read_input_tokens":25,"cache_creation_input_tokens":5}}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}

            data: {"type":"message_stop"}

            """
            return (200, Data(fixture.utf8))
        }
        let anthropic = try await collect(AnthropicProvider(credential: { "key" }, session: contractSession()))
        var total = Usage()
        for case .usage(let value) in anthropic { total.mergeCumulative(value) }
        #expect(total == .init(inputTokens: 70, outputTokens: 9, cacheReadTokens: 25, cacheWriteTokens: 5))

        ContractURLProtocol.handler = { _ in
            let fixture = """
            data: {"candidates":[{"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":60,"candidatesTokenCount":8,"cachedContentTokenCount":22}}

            """
            return (200, Data(fixture.utf8))
        }
        let gemini = try await collect(GeminiProvider(credential: { "key" }, session: contractSession()))
        #expect(gemini.contains(.usage(.init(inputTokens: 60, outputTokens: 8, cacheReadTokens: 22))))
    }

    @Test func ssePreservesDataAndHandlesEveryLineEndingIncrementally() {
        var parser = SSEParser()
        #expect(parser.feed(Data("data:  leading and trailing  \r".utf8)) == [])
        #expect(parser.feed(Data("\ndata:\ttab-kept\r\rdata: last\n".utf8)) == [" leading and trailing  \n\ttab-kept"])
        #expect(parser.feed(Data("\n".utf8)) == ["last"])
        #expect(parser.feed(Data("data: [DONE]\n\n".utf8)) == ["[DONE]"])
    }

    @Test func openRouterUsesChatCompletionsPreservesSystemAndTerminates() async throws {
        ContractURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (503, Data()) }
            #expect(request.url?.path == "/api/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            let body = try jsonBody(request)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["role"] as? String == "system")
            #expect(messages.first?["content"] as? String == "rules")
            let fixture = "data: {\"id\":\"r1\",\"choices\":[{\"delta\":{\"content\":\"hi\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
            return (200, Data(fixture.utf8))
        }
        let provider = OpenRouterProvider(credential: { "secret" }, session: contractSession())
        #expect(provider.descriptor.id == "openrouter")
        let events = try await collect(provider, messages: [.init(role: .system, text: "rules"), .init(role: .user, text: "hello")])
        #expect(events.contains(.responseStarted(id: "r1")))
        #expect(events.contains(.textDelta("hi")))
        #expect(events.filter { if case .completed = $0 { true } else { false } }.count == 1)
        #expect(events.contains(.completed(.stop)))
    }

    @Test func providerSpecificSystemShapesAreCorrect() async throws {
        let system = ChatMessage(role: .system, text: "rules")
        let user = ChatMessage(role: .user, text: "hello")

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request)
            #expect(body["system"] as? String == "rules")
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 1)
            return (200, Data("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\ndata: {\"type\":\"message_stop\"}\n\n".utf8))
        }
        #expect(try await collect(AnthropicProvider(credential: { "key" }, session: contractSession()), messages: [system, user]).contains(.completed(.length)))

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request)
            let instruction = try #require(body["systemInstruction"] as? [String: Any])
            #expect(instruction["parts"] != nil)
            let contents = try #require(body["contents"] as? [[String: Any]])
            #expect(contents.count == 1)
            return (200, Data("data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n".utf8))
        }
        #expect(try await collect(GeminiProvider(credential: { "key" }, session: contractSession()), messages: [system, user]).contains(.completed(.stop)))

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request)
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["role"] as? String == "system")
            return (200, Data("{\"done\":true,\"done_reason\":\"stop\"}\n".utf8))
        }
        #expect(try await collect(OllamaProvider(session: contractSession()), messages: [system, user]).contains(.completed(.stop)))
    }

    @Test func imageAttachmentsUseEachProvidersNativeWireShape() async throws {
        let metadata = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "pixel.png", mimeType: "image/png", byteCount: 3, kind: .image)
        let message = ChatMessage(role: .user, text: "inspect", attachments: [metadata])
        let request = InferenceRequest(
            conversationID: UUID(), modelID: "fixture", messages: [message],
            attachmentsByMessageID: [message.id: [.init(metadata: metadata, data: Data([1, 2, 3]))]]
        )
        let encoded = Data([1, 2, 3]).base64EncodedString()

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request), input = try #require(body["input"] as? [[String: Any]])
            let content = try #require(input[0]["content"] as? [[String: Any]])
            #expect(content.contains { $0["type"] as? String == "input_image" && ($0["image_url"] as? String)?.hasSuffix(encoded) == true })
            return (200, Data("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{}}}\n\ndata: [DONE]\n\n".utf8))
        }
        _ = try await collect(OpenAIProvider(credential: { "key" }, session: contractSession()), request: request)

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request), messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages[0]["content"] as? [[String: Any]])
            let image = try #require(content.first { $0["type"] as? String == "image" })
            #expect((image["source"] as? [String: Any])?["data"] as? String == encoded)
            return (200, Data("data: {\"type\":\"message_stop\"}\n\n".utf8))
        }
        _ = try await collect(AnthropicProvider(credential: { "key" }, session: contractSession()), request: request)

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request), contents = try #require(body["contents"] as? [[String: Any]])
            let parts = try #require(contents[0]["parts"] as? [[String: Any]])
            #expect((parts.last?["inlineData"] as? [String: Any])?["data"] as? String == encoded)
            return (200, Data("data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n".utf8))
        }
        _ = try await collect(GeminiProvider(credential: { "key" }, session: contractSession()), request: request)

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request), messages = try #require(body["messages"] as? [[String: Any]])
            #expect((messages[0]["images"] as? [String]) == [encoded])
            return (200, Data("{\"done\":true,\"done_reason\":\"stop\"}\n".utf8))
        }
        _ = try await collect(OllamaProvider(session: contractSession()), request: request)

        ContractURLProtocol.handler = { request in
            let body = try jsonBody(request), messages = try #require(body["messages"] as? [[String: Any]])
            let content = try #require(messages[0]["content"] as? [[String: Any]])
            let image = try #require(content.first { $0["type"] as? String == "image_url" })
            #expect(((image["image_url"] as? [String: Any])?["url"] as? String)?.hasSuffix(encoded) == true)
            return (200, Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        }
        _ = try await collect(OpenRouterProvider(credential: { "key" }, session: contractSession()), request: request)
    }

    @Test func geminiMapsLengthRefusalAndTruncatedEOF() async throws {
        ContractURLProtocol.handler = { _ in (200, Data("data: {\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}\n\n".utf8)) }
        #expect(try await collect(GeminiProvider(credential: { "key" }, session: contractSession())).contains(.completed(.length)))

        ContractURLProtocol.handler = { _ in (200, Data("data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}\n\n".utf8)) }
        do {
            _ = try await collect(GeminiProvider(credential: { "key" }, session: contractSession()))
            Issue.record("Expected refusal")
        } catch let error as ProviderError {
            guard case .refusal = error else { Issue.record("Unexpected error: \(error)"); return }
        }

        ContractURLProtocol.handler = { _ in (200, Data("data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}\n\n".utf8)) }
        do {
            _ = try await collect(GeminiProvider(credential: { "key" }, session: contractSession()))
            Issue.record("Expected truncated EOF")
        } catch let error as ProviderError {
            guard case .truncated = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test(arguments: ["STOP", "MAX_TOKENS", "FINISH_REASON_UNSPECIFIED", "CANCELLED"])
    func geminiToolCallsCannotHideAnUnsuccessfulFinishReason(reason: String) async throws {
        ContractURLProtocol.handler = { _ in
            let fixture = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"id\":\"call-1\",\"name\":\"effect\",\"args\":{}}}]},\"finishReason\":\"\(reason)\"}]}\n\n"
            return (200, Data(fixture.utf8))
        }
        let events = try await collect(GeminiProvider(credential: { "fixture-key" }, session: contractSession()))
        let terminal = events.compactMap { if case .completed(let value) = $0 { value } else { nil } }
        let expected: FinishReason = switch reason {
        case "STOP": .toolUse
        case "MAX_TOKENS": .length
        case "CANCELLED": .cancelled
        default: .unknown
        }
        expectNoDifference(terminal, [expected])
    }

    @Test(arguments: ["MAX_TOKENS", "FINISH_REASON_UNSPECIFIED", "CANCELLED"])
    func geminiHTTPToolResponseMustFailBeforeTheHostExecutorRuns(reason: String) async throws {
        ContractURLProtocol.handler = { _ in
            let fixture = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"functionCall\":{\"id\":\"call-1\",\"name\":\"effect\",\"args\":{}}}]},\"finishReason\":\"\(reason)\"}]}\n\n"
            return (200, Data(fixture.utf8))
        }
        let effects = ContractToolEffects()
        let loop = ToolLoop(provider: GeminiProvider(credential: { "fixture-key" }, session: contractSession()),
                            catalog: ToolCatalog([ContractEffectExecutor(effects: effects)]))
        let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let run = await loop.start(.init(conversationID: scope, modelID: "fixture", messages: []), context: .init(conversationID: scope))
        do {
            for try await _ in run.events {}
            await run.finish()
            Issue.record("An unsuccessful Gemini tool response must fail")
        } catch {
            await run.cancelAndWait()
            switch reason {
            case "MAX_TOKENS": expectNoDifference(error as? ProviderError, .truncated("length"))
            case "CANCELLED": #expect(error is CancellationError)
            default: expectNoDifference(error as? ProviderError, .invalidResponse)
            }
        }
        let executions = await effects.executions
        expectNoDifference(executions, 0)
    }

    @Test func normalizesStreamAndHTTPFailures() async throws {
        ContractURLProtocol.handler = { _ in (200, Data("data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\"}}\n\n".utf8)) }
        do {
            _ = try await collect(AnthropicProvider(credential: { "key" }, session: contractSession()))
            Issue.record("Expected rate limit")
        } catch let error as ProviderError {
            #expect(error == .rateLimit("busy"))
        }

        ContractURLProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await collect(OpenRouterProvider(credential: { "bad" }, session: contractSession()))
            Issue.record("Expected authentication error")
        } catch let error as ProviderError {
            guard case .authentication = error else { Issue.record("Unexpected error: \(error)"); return }
        }

        ContractURLProtocol.handler = { _ in (200, Data("{\"error\":\"model unavailable\"}\n".utf8)) }
        do {
            _ = try await collect(OllamaProvider(session: contractSession()))
            Issue.record("Expected transport error")
        } catch let error as ProviderError {
            #expect(error == .transport("model unavailable"))
        }
    }
}

private actor ContractToolEffects {
    private(set) var executions = 0
    func executed() { executions += 1 }
}

private struct ContractEffectExecutor: ToolExecutor {
    let descriptor = ToolDescriptor(name: "effect")
    let effects: ContractToolEffects
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await effects.executed()
        return .init(callID: call.id, content: [.text("HOST_RESULT")])
    }
}
