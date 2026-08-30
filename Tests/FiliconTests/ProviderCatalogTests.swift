import Foundation
import Testing
@testable import FiliconDomain
@testable import FiliconProviderKit

private final class CatalogURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, String, Data))?
    nonisolated(unsafe) static var responseURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler?(request) ?? { throw URLError(.badServerResponse) }()
            let response = HTTPURLResponse(url: Self.responseURL ?? request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": result.1])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: result.2); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func catalogSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [CatalogURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody { data = body }
    else if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }; var value = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; value.append(buffer, count: count) }; data = value
    } else { throw ProviderError.invalidResponse }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func drain(_ provider: any AIProvider, request: InferenceRequest) async throws {
    for try await _ in provider.stream(request) {}
}

@Suite(.serialized)
struct ProviderCatalogTests {
    @Test func parsesAllOfficialCatalogWireShapesAndCapabilities() async {
        let fixtures: [(String, any DynamicModelCatalogProviding, String)] = [
            ("/v1/models", OpenAIProvider(credential: { "openai-key" }, session: catalogSession()), #"{"data":[{"id":"gpt-5-test","object":"model"}]}"#),
            ("/api/v1/models", OpenRouterProvider(credential: { "router-key" }, session: catalogSession()), #"{"data":[{"id":"vendor/reasoner","name":"Reasoner","context_length":128000,"top_provider":{"max_completion_tokens":8192},"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"supported_parameters":["reasoning","tools"]}]}"#),
            ("/v1/models", AnthropicProvider(credential: { "anthropic-key" }, session: catalogSession()), #"{"data":[{"type":"model","id":"claude-4-test","display_name":"Claude Test"}]}"#),
            ("/v1beta/models", GeminiProvider(credential: { "gemini-key" }, session: catalogSession()), #"{"models":[{"name":"models/gemini-2.5-test","displayName":"Gemini Test","inputTokenLimit":1000000,"outputTokenLimit":65536,"supportedGenerationMethods":["generateContent"]}]}"#),
            ("/api/tags", OllamaProvider(session: catalogSession()), #"{"models":[{"name":"local-thinking","capabilities":["vision","tools","thinking"]}]}"#)
        ]
        for (path, provider, fixture) in fixtures {
            CatalogURLProtocol.handler = { request in
                #expect(request.url?.path == path)
                return (200, "application/json", Data(fixture.utf8))
            }
            let snapshot = await provider.modelCatalog(forceRefresh: true)
            #expect(snapshot.source == .dynamic); #expect(snapshot.models.count == 1)
            #expect(snapshot.models[0].capabilities.reasoningEfforts.contains(.high))
        }
    }

    @Test func fallbackIsExplicitAndCacheAvoidsSecondFetch() async {
        let calls = LockedCounter()
        CatalogURLProtocol.handler = { _ in calls.increment(); return (503, "application/json", Data("busy".utf8)) }
        let provider = OpenAIProvider(credential: { "key" }, session: catalogSession())
        let first = await provider.modelCatalog(forceRefresh: false), second = await provider.modelCatalog(forceRefresh: false)
        #expect(first.source == .builtInFallback && first.isStale && first.errorDescription != nil)
        #expect(second.models == first.models); #expect(calls.value == 1)
    }

    @Test func encodesProviderSpecificReasoningAndRejectsUnsupportedOrRemovedModels() async throws {
        let cases: [(any AIProvider, String, @Sendable ([String: Any]) throws -> Void, Data)] = [
            (OpenAIProvider(credential: { "key" }, session: catalogSession()), "gpt-5-test", { body in #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high") }, Data("data: {\"type\":\"response.completed\",\"response\":{\"usage\":{}}}\n\ndata: [DONE]\n\n".utf8)),
            (OpenRouterProvider(credential: { "key" }, session: catalogSession()), "vendor/reasoner", { body in #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high") }, Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)),
            (AnthropicProvider(credential: { "key" }, session: catalogSession()), "claude-4-test", { body in #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 8192) }, Data("data: {\"type\":\"message_stop\"}\n\n".utf8)),
            (GeminiProvider(credential: { "key" }, session: catalogSession()), "gemini-2.5-test", { body in let generation = body["generationConfig"] as? [String: Any]; #expect((generation?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int == 8192) }, Data("data: {\"candidates\":[{\"finishReason\":\"STOP\"}]}\n\n".utf8)),
            (OllamaProvider(session: catalogSession()), "local-thinking", { body in #expect(body["think"] as? String == "high") }, Data("{\"done\":true,\"done_reason\":\"stop\"}\n".utf8))
        ]
        let catalogs = [
            #"{"data":[{"id":"gpt-5-test"}]}"#, #"{"data":[{"id":"vendor/reasoner","supported_parameters":["reasoning"]}]}"#,
            #"{"data":[{"id":"claude-4-test"}]}"#, #"{"models":[{"name":"models/gemini-2.5-test","supportedGenerationMethods":["generateContent"]}]}"#,
            #"{"models":[{"name":"local-thinking","capabilities":["thinking"]}]}"#
        ]
        for (index, entry) in cases.enumerated() {
            CatalogURLProtocol.handler = { request in
                if request.httpMethod == "GET" { return (200, "application/json", Data(catalogs[index].utf8)) }
                try entry.2(requestBody(request)); return (200, entry.0.descriptor.id == "ollama" ? "application/x-ndjson" : "text/event-stream", entry.3)
            }
            try await drain(entry.0, request: .init(conversationID: UUID(), modelID: ModelID(rawValue: entry.1), messages: [], reasoningEffort: .high))
        }

        CatalogURLProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, "application/json", Data(#"{"data":[{"id":"present"}]}"#.utf8)) }
            return (200, "text/event-stream", Data())
        }
        let provider = OpenAIProvider(credential: { "key" }, session: catalogSession())
        do { try await drain(provider, request: .init(conversationID: UUID(), modelID: "removed", messages: [])); Issue.record("expected removed model rejection") }
        catch { #expect(error as? ProviderError == .modelUnavailable("removed")) }

        let safe = OpenRouterProvider(models: [.init(id: "safe")], credential: { "key" }, session: catalogSession())
        CatalogURLProtocol.handler = { _ in (503, "application/json", Data()) }
        do { try await drain(safe, request: .init(conversationID: UUID(), modelID: "safe", messages: [], reasoningEffort: .high)); Issue.record("expected unsupported effort") }
        catch { #expect(error as? ProviderError == .unsupportedReasoningEffort(model: "safe", effort: .high)) }
    }

    @Test func rejectsCatalogBoundsContentTypeAuthAndCrossOriginFinalURL() async {
        let provider = OpenAIProvider(credential: { "key" }, session: catalogSession())
        CatalogURLProtocol.handler = { _ in (401, "application/json", Data("unauthorized".utf8)) }
        #expect((await provider.modelCatalog(forceRefresh: true)).errorDescription?.contains("authentication") == true)
        CatalogURLProtocol.handler = { _ in (200, "text/html", Data("<html>".utf8)) }
        #expect((await provider.modelCatalog(forceRefresh: true)).source == .builtInFallback)
        CatalogURLProtocol.responseURL = URL(string: "https://attacker.invalid/models")
        CatalogURLProtocol.handler = { _ in (200, "application/json", Data(#"{"data":[{"id":"stolen"}]}"#.utf8)) }
        #expect((await provider.modelCatalog(forceRefresh: true)).errorDescription?.contains("cross-origin") == true)
        CatalogURLProtocol.responseURL = nil
        let rows = String(repeating: #"{"id":"x"},"#, count: 1_001)
        CatalogURLProtocol.handler = { _ in (200, "application/json", Data("{\"data\":[\(rows){\"id\":\"last\"}]}".utf8)) }
        #expect((await provider.modelCatalog(forceRefresh: true)).isStale)
    }

    @Test func staleRefreshGenerationCannotOverwriteNewerCatalog() async {
        let calls = LockedCounter()
        CatalogURLProtocol.responseURL = nil
        CatalogURLProtocol.handler = { _ in
            let ordinal = calls.incrementAndGet()
            if ordinal == 1 { Thread.sleep(forTimeInterval: 0.08) } else { Thread.sleep(forTimeInterval: 0.01) }
            let id = ordinal == 1 ? "older" : "newer"
            return (200, "application/json", Data("{\"data\":[{\"id\":\"\(id)\"}]}".utf8))
        }
        let provider = OpenAIProvider(credential: { "key" }, session: catalogSession())
        let first = Task { await provider.modelCatalog(forceRefresh: true) }
        try? await Task.sleep(for: .milliseconds(5))
        let second = Task { await provider.modelCatalog(forceRefresh: true) }
        #expect(await second.value.models.first?.id == "newer")
        _ = await first.value
        #expect(await provider.modelCatalog(forceRefresh: false).models.first?.id == "newer")
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var storage = 0
    func increment() { lock.lock(); storage += 1; lock.unlock() }
    func incrementAndGet() -> Int { lock.lock(); defer { lock.unlock() }; storage += 1; return storage }
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
}
