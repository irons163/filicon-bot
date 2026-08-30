import Foundation
import Testing
@testable import FiliconMCP

@Suite("MCP OAuth PKCE flow")
struct MCPOAuthFlowTests {
    @Test func preparesBoundedPKCERequestAndExchangesExactCallback() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let pending = MCPOAuthPendingCoordinator()
        let transport = OAuthTransportStub(body: #"{"access_token":"secret","token_type":"bearer","refresh_token":"refresh","scope":"tools.read"}"#)
        let flow = MCPOAuthFlowCoordinator(pendingCoordinator: pending, transport: transport, now: { now })
        let configuration = try MCPOAuthConfiguration(
            clientID: "public-client",
            authorizationEndpoint: URL(string: "https://login.example.test/authorize?prompt=consent")!,
            tokenEndpoint: URL(string: "https://login.example.test/token")!,
            scopes: ["tools.read", "tools.write"], audience: "https://mcp.example.test"
        )
        let callback = URL(string: "http://127.0.0.1:49152/oauth/callback")!

        let prepared = try await flow.begin(
            serverID: "example", accountKey: "work", configuration: configuration, callbackURL: callback
        )
        let query = try #require(URLComponents(url: prepared.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(query.contains(.init(name: "client_id", value: "public-client")))
        #expect(query.contains(.init(name: "response_type", value: "code")))
        #expect(query.contains(.init(name: "state", value: prepared.pending.state)))
        #expect(query.contains(.init(name: "code_challenge_method", value: "S256")))
        #expect(query.first(where: { $0.name == "code_challenge" })?.value?.count == 43)
        #expect(query.contains(.init(name: "prompt", value: "consent")))

        let completed = URL(string: "\(callback.absoluteString)?code=auth-code&state=\(prepared.pending.state)")!
        let token = try await flow.complete(callbackURL: completed, request: prepared, configuration: configuration)
        #expect(token.authorizationHeaderValue == "Bearer secret")
        #expect(token.refreshToken == "refresh")
        let request = try #require(await transport.lastRequest())
        #expect(request.url == configuration.tokenEndpoint)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody.flatMap { String(data: $0, encoding: .utf8) })
        #expect(body.contains("code=auth-code"))
        #expect(body.contains("code_verifier="))
        #expect(!body.contains("secret"))
    }

    @Test func rejectsInsecureEndpointsDuplicateCallbackValuesAndReplay() async throws {
        #expect(throws: MCPOAuthFlowError.self) {
            try MCPOAuthConfiguration(
                clientID: "client",
                authorizationEndpoint: URL(string: "http://example.test/authorize")!,
                tokenEndpoint: URL(string: "https://example.test/token")!
            )
        }
        let pending = MCPOAuthPendingCoordinator()
        let flow = MCPOAuthFlowCoordinator(
            pendingCoordinator: pending,
            transport: OAuthTransportStub(body: #"{"access_token":"token"}"#),
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let configuration = try configuration()
        let callback = URL(string: "http://localhost:49876/oauth/callback")!
        let prepared = try await flow.begin(serverID: "server", accountKey: "default", configuration: configuration, callbackURL: callback)
        let duplicate = URL(string: "\(callback)?code=a&code=b&state=\(prepared.pending.state)")!
        await #expect(throws: MCPOAuthFlowError.invalidCallback) {
            try await flow.complete(callbackURL: duplicate, request: prepared, configuration: configuration)
        }
        let valid = URL(string: "\(callback)?code=a&state=\(prepared.pending.state)")!
        _ = try await flow.complete(callbackURL: valid, request: prepared, configuration: configuration)
        await #expect(throws: MCPOAuthError.self) {
            try await flow.complete(callbackURL: valid, request: prepared, configuration: configuration)
        }
    }

    @Test func expiryProviderErrorsRedirectsAndOversizedResponsesFailClosed() async throws {
        let clock = OAuthClock(Date(timeIntervalSince1970: 3_000))
        let pending = MCPOAuthPendingCoordinator()
        let transport = OAuthTransportStub(body: #"{"access_token":"token"}"#)
        let flow = MCPOAuthFlowCoordinator(pendingCoordinator: pending, transport: transport, now: { clock.value })
        let configuration = try configuration()
        let callback = URL(string: "http://127.0.0.1:49999/oauth/callback")!
        let expired = try await flow.begin(serverID: "server", accountKey: "one", configuration: configuration, callbackURL: callback, lifetime: 1)
        clock.value = clock.value.addingTimeInterval(2)
        await #expect(throws: MCPOAuthFlowError.expired) {
            try await flow.complete(
                callbackURL: URL(string: "\(callback)?code=a&state=\(expired.pending.state)")!,
                request: expired, configuration: configuration
            )
        }

        clock.value = Date(timeIntervalSince1970: 4_000)
        let denied = try await flow.begin(serverID: "server", accountKey: "two", configuration: configuration, callbackURL: callback)
        await #expect(throws: MCPOAuthFlowError.provider("access_denied")) {
            try await flow.complete(
                callbackURL: URL(string: "\(callback)?error=access_denied&state=\(denied.pending.state)")!,
                request: denied, configuration: configuration
            )
        }

        let tooLarge = OAuthTransportStub(
            response: .init(statusCode: 200, finalURL: configuration.tokenEndpoint, body: Data(repeating: 0x41, count: 1_048_577))
        )
        let boundedFlow = MCPOAuthFlowCoordinator(pendingCoordinator: pending, transport: tooLarge, now: { clock.value })
        let request = try await boundedFlow.begin(serverID: "server", accountKey: "three", configuration: configuration, callbackURL: callback)
        await #expect(throws: MCPOAuthFlowError.responseTooLarge) {
            try await boundedFlow.complete(
                callbackURL: URL(string: "\(callback)?code=a&state=\(request.pending.state)")!,
                request: request, configuration: configuration
            )
        }
    }

    private func configuration() throws -> MCPOAuthConfiguration {
        try .init(
            clientID: "client",
            authorizationEndpoint: URL(string: "https://oauth.example.test/authorize")!,
            tokenEndpoint: URL(string: "https://oauth.example.test/token")!
        )
    }
}

private actor OAuthTransportStub: MCPOAuthTokenTransport {
    private let response: MCPOAuthHTTPResponse
    private let usesExpectedEndpoint: Bool
    private var request: URLRequest?

    init(body: String) {
        response = .init(
            statusCode: 200,
            finalURL: URL(string: "https://login.example.test/token")!,
            body: Data(body.utf8)
        )
        usesExpectedEndpoint = true
    }

    init(response: MCPOAuthHTTPResponse) {
        self.response = response
        usesExpectedEndpoint = false
    }

    func exchange(request: URLRequest, expectedEndpoint: URL) async throws -> MCPOAuthHTTPResponse {
        self.request = request
        if usesExpectedEndpoint {
            return .init(statusCode: response.statusCode, finalURL: expectedEndpoint, body: response.body)
        }
        guard response.finalURL == expectedEndpoint else { throw MCPOAuthFlowError.insecureRedirect }
        return response
    }

    func lastRequest() -> URLRequest? { request }
}

private final class OAuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ value: Date) { stored = value }
    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
