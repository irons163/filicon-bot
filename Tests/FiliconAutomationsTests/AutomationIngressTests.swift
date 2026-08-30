import CryptoKit
import Foundation
import Testing
@testable import FiliconAutomations

private actor IngressEventProbe {
    private(set) var events: [AutomationEvent] = []
    func append(_ event: AutomationEvent) -> Bool { events.append(event); return true }
}

private struct FixedIngressSecrets: AutomationIngressSecretProvider {
    let value: Data
    func secret(for reference: String) async throws -> Data { value }
}

private actor BlockingIngressSecrets: AutomationIngressSecretProvider {
    private let value: Data
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requested = false
    init(value: Data) { self.value = value }
    func secret(for reference: String) async throws -> Data {
        requested = true
        await withCheckedContinuation { continuation = $0 }
        return value
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Automation ingress")
struct AutomationIngressTests {
    private let secret = Data("webhook-secret".utf8)

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func hmac(_ body: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func request(provider: AutomationIngressProvider, route: AutomationIngressRoute,
                         body: Data, now: Date = Date(), nonce: String = UUID().uuidString) -> AutomationHTTPRequest {
        var headers = ["content-type": "application/json"]
        switch provider {
        case .generic:
            let timestamp = Int64(now.timeIntervalSince1970)
            headers["x-filicon-timestamp"] = String(timestamp)
            headers["x-filicon-nonce"] = nonce
            headers["x-filicon-signature"] = AutomationIngressSignatureVerifier.genericSignature(
                secret: secret, timestamp: timestamp, nonce: nonce, body: body
            )
        case .microsoftTeams:
            let digest = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret))
            headers["authorization"] = "HMAC " + Data(digest).base64EncodedString()
        case .slack:
            let timestamp = String(Int64(now.timeIntervalSince1970))
            headers["x-slack-request-timestamp"] = timestamp
            headers["x-slack-request-id"] = nonce
            headers["x-slack-signature"] = "v0=" + hmac(Data("v0:\(timestamp):".utf8) + body)
        case .github:
            headers["x-hub-signature-256"] = "sha256=" + hmac(body)
            headers["x-github-delivery"] = nonce
            headers["x-github-event"] = "pull_request"
        case .linear:
            headers["linear-signature"] = hmac(body)
            headers["linear-delivery"] = nonce
        case .sentry:
            headers["sentry-hook-signature"] = hmac(body)
            headers["sentry-hook-request-id"] = nonce
            headers["sentry-hook-resource"] = "issue"
        case .pagerDuty:
            headers["x-pagerduty-signature"] = "v1=bad, v1=" + hmac(body)
            headers["x-pagerduty-delivery"] = nonce
        }
        return .init(method: "POST", path: route.path, headers: headers, body: body)
    }

    private func json(_ event: AutomationEvent) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any])
    }

    @Test func parserEnforcesFramingHeaderAndBodyLimits() {
        let limits = AutomationIngressLimits(maximumBodyBytes: 1_024, maximumHeaderBytes: 4_096)
        let valid = Data("POST /hooks/id HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        guard case .complete(let parsed) = AutomationHTTPRequestParser.parse(valid, limits: limits) else {
            Issue.record("Expected a complete request"); return
        }
        #expect(parsed.body == Data("{}".utf8))

        let oversized = Data("POST / HTTP/1.1\r\nContent-Length: 1025\r\n\r\n".utf8)
        #expect({ if case .rejected(.bodyTooLarge) = AutomationHTTPRequestParser.parse(oversized, limits: limits) { true } else { false } }())
        let duplicate = Data("POST / HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect({ if case .rejected(.invalidRequest) = AutomationHTTPRequestParser.parse(duplicate, limits: limits) { true } else { false } }())
        let trailing = Data("POST / HTTP/1.1\r\nContent-Length: 0\r\n\r\nx".utf8)
        #expect({ if case .rejected(.invalidRequest) = AutomationHTTPRequestParser.parse(trailing, limits: limits) { true } else { false } }())
    }

    @Test func everyProviderVerifiesAndNormalizesItsDocumentedEnvelope() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let vectors: [(AutomationIngressProvider, String, [String: Any])] = [
            (.generic, #"{"kind":"deploy","externalEventID":"g-1","payload":{"environment":"prod"}}"#, ["environment": "prod"]),
            (.slack, #"{"event_id":"s-1","event":{"type":"app_mention","channel":"C1","text":"hello"}}"#, ["channel": "C1"]),
            (.github, #"{"action":"opened","repository":{"full_name":"acme/app"},"sender":{"login":"octo"},"pull_request":{"merged":false}}"#, ["event": "pr-opened"]),
            (.linear, #"{"type":"Issue","webhookId":"l-1","webhookTimestamp":1800000000000,"data":{"id":"ISSUE","teamId":"TEAM"}}"#, ["event": "issue"]),
            (.sentry, #"{"action":"created","data":{"project":{"slug":"api"}}}"#, ["event": "created"]),
            (.pagerDuty, #"{"event":{"id":"p-1","event_type":"incident.triggered","data":{"id":"INC","service":{"id":"SVC"}}}}"#, ["event": "incident.triggered"]),
            (.microsoftTeams, #"{"id":"t-1","text":"deploy","channelData":{"tenant":{"id":"TEN"},"team":{"id":"TEAM"},"channel":{"id":"CHAN"}}}"#, ["tenantId": "TEN"]),
        ]

        for (provider, rawBody, expected) in vectors {
            let route = AutomationIngressRoute(name: provider.rawValue, provider: provider, secretReference: "keychain:test")
            let body = Data(rawBody.utf8)
            let inbound = request(provider: provider, route: route, body: body, now: now)
            let auth = try AutomationIngressSignatureVerifier.verify(provider: provider, request: inbound,
                                                                      secret: secret, now: now)
            let event = try AutomationIngressEventNormalizer.event(route: route, request: inbound,
                                                                    nonce: auth.nonce, now: now)
            #expect(event.kind == (provider == .generic ? "deploy" : provider.eventKind))
            let payload = try json(event)
            for (key, value) in expected {
                #expect(payload[key].map(String.init(describing:)) == String(describing: value))
            }
        }
    }

    @Test func invalidSignaturesAndSuppliedStaleTimestampsAreRejected() throws {
        let route = AutomationIngressRoute(name: "GitHub", provider: .github, secretReference: "keychain:test")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var valid = request(provider: .github, route: route, body: Data("{}".utf8), now: now)
        var headers = valid.headers
        headers["x-filicon-timestamp"] = "1"
        valid = .init(method: valid.method, path: valid.path, headers: headers, body: valid.body)
        do {
            _ = try AutomationIngressSignatureVerifier.verify(provider: .github, request: valid, secret: secret, now: now)
            Issue.record("Expected stale timestamp rejection")
        } catch let error as AutomationIngressError { #expect(error == .staleRequest) }

        headers["x-filicon-timestamp"] = nil
        headers["x-hub-signature-256"] = "sha256=wrong"
        let invalid = AutomationHTTPRequest(method: "POST", path: route.path, headers: headers, body: valid.body)
        do {
            _ = try AutomationIngressSignatureVerifier.verify(provider: .github, request: invalid, secret: secret, now: now)
            Issue.record("Expected signature rejection")
        } catch let error as AutomationIngressError { #expect(error == .unauthorized) }
    }

    @Test func replayAuditAndRoutesSurviveRestartWithoutPersistingSignatures() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appending(path: "ingress.json"), audit = directory.appending(path: "audit.json")
        let probe = IngressEventProbe()
        let controller = try AutomationIngressController(stateURL: state, auditURL: audit,
            secrets: FixedIngressSecrets(value: secret)) { await probe.append($0) }
        let route = try await controller.saveRoute(.init(name: "Slack", provider: .slack, secretReference: "keychain:slack"))
        var inbound = request(provider: .slack, route: route,
                              body: Data(#"{"event_id":"E","event":{"type":"app_mention"}}"#.utf8))
        var headers = inbound.headers
        headers["x-slack-request-id"] = nil
        inbound = .init(method: inbound.method, path: inbound.path, headers: headers, body: inbound.body)
        #expect(await controller.process(inbound).status == 202)

        let signature = try #require(inbound.headers["x-slack-signature"])
        #expect(!String(decoding: try Data(contentsOf: state), as: UTF8.self).contains(signature))
        let reopened = try AutomationIngressController(stateURL: state, auditURL: audit,
            secrets: FixedIngressSecrets(value: secret)) { _ in true }
        #expect(await reopened.routes().map(\.id) == [route.id])
        #expect(await reopened.process(inbound).status == 401)
        #expect(await reopened.audits().map(\.disposition) == [.rejected, .accepted])
    }

    @Test func rateConcurrencyContentTypeAndTransferEncodingControlsApply() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let blocking = BlockingIngressSecrets(value: secret)
        let controller = try AutomationIngressController(
            stateURL: directory.appending(path: "state"), auditURL: directory.appending(path: "audit"),
            secrets: blocking,
            limits: .init(maximumConcurrentRequests: 1, requestsPerMinutePerRoute: 1)
        ) { _ in true }
        let route = try await controller.saveRoute(.init(name: "Generic", provider: .generic, secretReference: "keychain:test"))
        let first = request(provider: .generic, route: route, body: Data("{}".utf8), nonce: "one")
        let pending = Task { await controller.process(first) }
        while !(await blocking.requested) { await Task.yield() }
        #expect(await controller.process(request(provider: .generic, route: route, body: Data("{}".utf8), nonce: "two")).status == 503)
        await blocking.release()
        #expect(await pending.value.status == 202)
        #expect(await controller.process(request(provider: .generic, route: route, body: Data("{}".utf8), nonce: "three")).status == 429)

        var headers = first.headers
        headers["transfer-encoding"] = "chunked"
        #expect(await controller.process(.init(method: "POST", path: route.path, headers: headers, body: first.body)).status == 400)
        headers["transfer-encoding"] = nil; headers["content-type"] = "text/plain"
        #expect(await controller.process(.init(method: "POST", path: route.path, headers: headers, body: first.body)).status == 415)
    }

    @Test func listenerDefaultsToLoopbackAndLANRequiresExplicitOptIn() async throws {
        let directory = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try AutomationIngressController(
            stateURL: directory.appending(path: "state"), auditURL: directory.appending(path: "audit"),
            secrets: FixedIngressSecrets(value: secret)
        ) { _ in true }
        let route = try await controller.saveRoute(.init(name: "Generic", provider: .generic, secretReference: "keychain:test"))
        do {
            try await controller.start(bindMode: .localNetwork)
            Issue.record("Expected LAN opt-in rejection")
        } catch let error as AutomationIngressError { #expect(error == .localNetworkRequiresOptIn) }

        try await controller.start()
        for _ in 0..<200 where await controller.status().state != .running {
            try await Task.sleep(for: .milliseconds(5))
        }
        let endpoint = try #require(await controller.endpointURL(for: route.id))
        #expect(endpoint.host == "127.0.0.1")
        let body = Data(#"{"kind":"network","externalEventID":"net-1","payload":{}}"#.utf8)
        let signed = request(provider: .generic, route: route, body: body, nonce: "network-nonce")
        var outbound = URLRequest(url: endpoint)
        outbound.httpMethod = "POST"; outbound.httpBody = body
        for (key, value) in signed.headers { outbound.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: outbound)
        #expect((response as? HTTPURLResponse)?.statusCode == 202)
        #expect(String(decoding: data, as: UTF8.self).contains(#""accepted":true"#))
        try await controller.stop()
    }
}
