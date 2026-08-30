import Foundation
import CryptoKit
import Testing
@testable import FiliconChannels

private enum ConnectorFailure: Error { case transient }

private final class MockChannelURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private struct CapturedRequest: @unchecked Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data?
    init(_ request: URLRequest) {
        url = request.url; method = request.httpMethod; headers = request.allHTTPHeaderFields ?? [:]
        if let httpBody = request.httpBody { body = httpBody }
        else if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            body = data
        } else { body = nil }
    }
    func header(_ field: String) -> String? { headers.first { $0.key.caseInsensitiveCompare(field) == .orderedSame }?.value }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CapturedRequest] = []
    func append(_ request: URLRequest) { lock.withLock { storage.append(CapturedRequest(request)) } }
    var requests: [CapturedRequest] { lock.withLock { storage } }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    init(_ value: Date) { storage = value }
    var value: Date { lock.withLock { storage } }
    func set(_ value: Date) { lock.withLock { storage = value } }
}

private func mockedChannelSession(handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) -> URLSession {
    MockChannelURLProtocol.handler = handler
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockChannelURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func channelResponse(_ request: URLRequest, status: Int = 200, json: Any) throws -> (HTTPURLResponse, Data) {
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    return (response, try JSONSerialization.data(withJSONObject: json))
}

private func channelDataResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:], data: Data) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, data)
}

private func casAttachment(_ data: Data, filename: String, mimeType: String) -> ChannelAttachment {
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return .init(blobID: digest, filename: filename, mimeType: mimeType, byteCount: Int64(data.count))
}

private actor ConnectorProbe {
    var attempts = 0
    var keys: [UUID] = []
    var failUntil = 0
    var authExpired = false
    func configure(failUntil: Int = 0, authExpired: Bool = false) {
        self.failUntil = failUntil
        self.authExpired = authExpired
    }
    func send(key: UUID) throws {
        attempts += 1
        keys.append(key)
        if authExpired { throw ChannelServiceError.authExpired("sign in again") }
        if attempts <= failUntil { throw ConnectorFailure.transient }
    }
}

private struct ProbeConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "probe", displayName: "Probe")
    let probe: ConnectorProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws {
        try await probe.send(key: idempotencyKey)
    }
}

@Suite("External channels", .serialized)
struct ChannelTests {
    private func sandbox() throws -> (URL, ChannelService, ChannelConnection, ConnectorProbe) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let probe = ConnectorProbe()
        let connection = ChannelConnection(connectorID: "probe", displayName: "Workspace", secretReference: "keychain://channels/probe-token")
        return (root, service, connection, probe)
    }

    @Test func metadataRejectsInlineSecretsAndInboundDedupesAcrossRestart() async throws {
        let (root, service, connection, _) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        await #expect(throws: ChannelServiceError.invalidConnection) {
            _ = try await service.saveConnection(.init(connectorID: "probe", displayName: "bad", secretReference: "plaintext-token"))
        }
        _ = try await service.saveConnection(connection)
        let envelope = ChannelEnvelope(
            connectionID: connection.id,
            externalEventID: "event-1",
            address: .init(platform: "probe", channelID: "general", threadID: "thread"),
            senderID: "u1", senderDisplayName: "Alice", text: "hello", cursor: "cursor-1"
        )
        #expect(try await service.ingest(envelope))
        #expect(try await service.ingest(envelope) == false)
        let reopened = try ChannelService(storeURL: root.appending(path: "channels.json"))
        #expect(try await reopened.ingest(envelope) == false)
        #expect(await reopened.connections().first?.cursor == "cursor-1")
        #expect(await reopened.inboundEvents().first?.senderDisplayName == "Alice")
    }

    @Test func sourceCompatibleAddressShapingLabelsAndManifests() {
        #expect(ChannelAddressParser.parse(" slack : C123:thread ") == .init(platform: "slack", channelID: "C123:thread"))
        #expect(ChannelAddressParser.parse("x") == nil)
        #expect(ChannelAddressParser.parse(":x") == nil)
        #expect(ChannelAddressParser.parse("x:") == nil)
        #expect(ChannelMessageShaper.shape(text: "hi", imageURL: "u") == .image(url: "u", caption: "hi"))
        #expect(ChannelMessageShaper.shape(text: nil, attachmentURL: "", alt: "a") == .text("a"))
        #expect(ChannelMessageShaper.shape(text: "") == nil)
        #expect(ChannelCompatibility.normalizedLabel("  A\n B\t C ", platform: "slack") == "A B C")
        #expect(ChannelCompatibility.normalizedLabel("", platform: "slack") == "Slack")
        #expect(BuiltInChannelManifests.all.allSatisfy { $0.availability == .available })
    }

    @Test func outboundRetriesWithStableIdempotencyAndEventuallyDelivers() async throws {
        let (root, service, connection, probe) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        await service.register(ProbeConnector(probe: probe))
        _ = try await service.saveConnection(connection)
        await probe.configure(failUntil: 2)
        let key = UUID(), base = Date(timeIntervalSince1970: 1_000)
        let first = try await service.enqueue(.init(text: "hello"), to: .init(platform: "probe", channelID: "general"), connectionID: connection.id, idempotencyKey: key, at: base)
        let duplicate = try await service.enqueue(.init(text: "ignored"), to: .init(platform: "probe", channelID: "general"), connectionID: connection.id, idempotencyKey: key, at: base)
        #expect(first.id == duplicate.id)
        await service.flush(now: base)
        await service.flush(now: base.addingTimeInterval(1))
        await service.flush(now: base.addingTimeInterval(3))
        #expect(await service.deliveries().first?.status == .delivered)
        #expect(await probe.attempts == 3)
        #expect(await Set(probe.keys) == [key])
        #expect(await service.failureWakes().isEmpty)
    }

    @Test func authExpiryDeadLettersAndCreatesDurableFailureWake() async throws {
        let (root, service, connection, probe) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        await service.register(ProbeConnector(probe: probe))
        _ = try await service.saveConnection(connection)
        await probe.configure(authExpired: true)
        _ = try await service.enqueue(.init(text: "hello"), to: .init(platform: "probe", channelID: "general"), connectionID: connection.id)
        await service.flush()
        #expect(await service.deliveries().first?.status == .deadLetter)
        let wakes = await service.failureWakes()
        #expect(wakes.count == 1)
        #expect(wakes[0].error.contains("expired"))
        let reopened = try ChannelService(storeURL: root.appending(path: "channels.json"))
        #expect(await reopened.failureWakes().count == 1)
        try await reopened.acknowledgeFailureWake(id: wakes[0].id)
        #expect(await reopened.failureWakes().isEmpty)
    }

    @Test func slackConnectorPollsMapsFilesAndSendsThreadRepliesWithBearerToken() async throws {
        let capture = RequestCapture()
        let fileData = Data("%PDF-safe Slack attachment".utf8)
        let session = mockedChannelSession { request in
            capture.append(request)
            switch request.url?.path {
            case "/api/auth.test":
                return try channelResponse(request, json: ["ok": true, "user_id": "SELF", "user": "Filicon", "team_id": "T1"])
            case "/api/conversations.history":
                return try channelResponse(request, json: [
                    "ok": true,
                    "messages": [[
                        "ts": "1725000000.000100", "thread_ts": "1724000000.000001",
                        "user": "U123", "username": "Alice", "text": "hello from Slack",
                        "files": [["id": "F1", "name": "design.pdf", "mimetype": "text/html", "size": fileData.count,
                                   "url_private_download": "https://files.slack.com/files-pri/T1-F1/design.pdf"]]
                    ]]
                ])
            case "/files-pri/T1-F1/design.pdf":
                return channelDataResponse(request, headers: ["Content-Type": "text/html"], data: fileData)
            case "/api/chat.postMessage":
                return try channelResponse(request, json: ["ok": true, "ts": "1725000001.000100"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let connector = SlackChannelConnector(session: session, pollingInterval: .seconds(60), resolveSecret: { reference in
            #expect(reference == "keychain://channels/slack")
            return "xoxb-test"
        }, ingestBlob: { data, filename, mimeType in casAttachment(data, filename: filename, mimeType: mimeType) })
        let connection = ChannelConnection(connectorID: "slack", displayName: "Slack", accountLabel: "C123", secretReference: "keychain://channels/slack")
        var iterator = connector.inbound(connection: connection).makeAsyncIterator()
        let event = try #require(try await iterator.next())
        #expect(event.externalEventID == "1725000000.000100")
        #expect(event.address == .init(platform: "slack", channelID: "C123", threadID: "1724000000.000001"))
        #expect(event.senderDisplayName == "Alice")
        #expect(event.attachments.first?.filename == "design.pdf")

        let key = UUID()
        try await connector.send(.init(text: "reply"), to: event.address, connection: connection, idempotencyKey: key)
        let sent = try #require(capture.requests.first(where: { $0.url?.path == "/api/chat.postMessage" }))
        #expect(sent.header("Authorization") == "Bearer xoxb-test")
        let body = try #require(sent.body)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(payload["channel"] as? String == "C123")
        #expect(payload["thread_ts"] as? String == "1724000000.000001")
        #expect(payload["client_msg_id"] as? String == key.uuidString)
    }

    @Test func discordConnectorUsesSnowflakeCursorAndRejectsExpiredBotToken() async throws {
        let capture = RequestCapture()
        let fileData = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3])
        let session = mockedChannelSession { request in
            capture.append(request)
            if request.httpMethod == "POST" { return try channelResponse(request, status: 401, json: ["message": "401: Unauthorized"]) }
            if request.url?.path == "/api/v10/users/@me" {
                return try channelResponse(request, json: ["id": "SELF", "username": "Filicon", "bot": true])
            }
            if request.url?.host == "cdn.discordapp.com" {
                return channelDataResponse(request, headers: ["Content-Type": "text/plain"], data: fileData)
            }
            return try channelResponse(request, json: [[
                "id": "1200000000000000001", "content": "hello from Discord",
                "timestamp": "2026-08-28T00:00:00Z",
                "author": ["id": "D1", "username": "Bob", "global_name": "Bobby"],
                "attachments": [["id": "A1", "filename": "photo.png", "content_type": "text/html", "size": fileData.count,
                                 "url": "https://cdn.discordapp.com/attachments/987/A1/photo.png"]]
            ]])
        }
        let connector = DiscordChannelConnector(session: session, pollingInterval: .seconds(60), resolveSecret: { _ in "discord-test" },
                                                ingestBlob: { data, filename, mimeType in casAttachment(data, filename: filename, mimeType: mimeType) })
        let connection = ChannelConnection(connectorID: "discord", displayName: "Discord", accountLabel: "987", secretReference: "keychain://channels/discord", cursor: "1200000000000000000")
        var iterator = connector.inbound(connection: connection).makeAsyncIterator()
        let event = try #require(try await iterator.next())
        #expect(event.cursor == "1200000000000000001")
        #expect(event.senderDisplayName == "Bobby")
        #expect(event.attachments.first?.mimeType == "image/png")
        let polled = try #require(capture.requests.first(where: { $0.method == "GET" && $0.url?.path.contains("/channels/987/messages") == true }))
        #expect(polled.header("Authorization") == "Bot discord-test")
        #expect(URLComponents(url: polled.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "after", value: "1200000000000000000")) == true)
        await #expect(throws: ChannelServiceError.self) {
            try await connector.send(.init(text: "reply"), to: event.address, connection: connection, idempotencyKey: UUID())
        }
    }

    @Test func oauthPKCEStateIsBoundExpiringSingleUseAndTokenOriginIsPinned() async throws {
        let session = mockedChannelSession { request in
            try channelResponse(request, json: ["access_token": "secret-access", "token_type": "Bearer"])
        }
        let configuration = try ChannelOAuthConfiguration.slack(clientID: "client")
        let redirect = URL(string: "http://127.0.0.1:45678/oauth/callback")!
        let coordinator = ChannelOAuthCoordinator(session: session)
        let pending = try await coordinator.begin(configuration: configuration, redirectURI: redirect)
        let query = URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(query.first(where: { $0.name == "code_challenge" })?.value?.isEmpty == false)
        let callback = URL(string: "\(redirect.absoluteString)?code=once&state=\(pending.state)")!
        #expect(try await coordinator.complete(callbackURL: callback).accessToken == "secret-access")
        await #expect(throws: ChannelOAuthError.replayed) { _ = try await coordinator.complete(callbackURL: callback) }

        let other = try await coordinator.begin(configuration: configuration, redirectURI: redirect)
        let crossOrigin = URL(string: "http://localhost:45678/oauth/callback?code=x&state=\(other.state)")!
        await #expect(throws: ChannelOAuthError.invalidCallback) { _ = try await coordinator.complete(callbackURL: crossOrigin) }

        let clock = LockedDate(Date(timeIntervalSince1970: 10))
        let expiredCoordinator = ChannelOAuthCoordinator(session: session, now: { clock.value })
        let expired = try await expiredCoordinator.begin(configuration: configuration, redirectURI: redirect, lifetime: 1)
        clock.set(Date(timeIntervalSince1970: 12))
        await #expect(throws: ChannelOAuthError.expired) {
            _ = try await expiredCoordinator.complete(callbackURL: URL(string: "\(redirect.absoluteString)?code=x&state=\(expired.state)")!)
        }

        let redirectedSession = mockedChannelSession { request in
            let response = HTTPURLResponse(url: URL(string: "https://evil.example/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, try JSONSerialization.data(withJSONObject: ["access_token": "stolen"]))
        }
        let pinned = ChannelOAuthCoordinator(session: redirectedSession)
        let pinnedRequest = try await pinned.begin(configuration: configuration, redirectURI: redirect)
        await #expect(throws: ChannelOAuthError.insecureRedirect) {
            _ = try await pinned.complete(callbackURL: URL(string: "\(redirect.absoluteString)?code=x&state=\(pinnedRequest.state)")!)
        }
    }

    @Test func slackExternalUploadDiscordMultipartReactionsAnd429Retry() async throws {
        let capture = RequestCapture()
        let bytes = Data("attachment body".utf8)
        let attachment = casAttachment(bytes, filename: "notes.txt", mimeType: "text/plain")
        let retryLock = NSLock()
        nonisolated(unsafe) var reactionAttempts = 0
        let session = mockedChannelSession { request in
            capture.append(request)
            switch (request.url?.host, request.url?.path) {
            case ("slack.com", "/api/files.getUploadURLExternal"):
                return try channelResponse(request, json: ["ok": true, "upload_url": "https://files.slack.com/upload/v1", "file_id": "F1"])
            case ("files.slack.com", "/upload/v1"):
                return channelDataResponse(request, data: Data())
            case ("slack.com", "/api/files.completeUploadExternal"):
                return try channelResponse(request, json: ["ok": true])
            case ("discord.com", let path?) where path.contains("/reactions/"):
                let attempt = retryLock.withLock { reactionAttempts += 1; return reactionAttempts }
                if attempt == 1 { return channelDataResponse(request, status: 429, data: try JSONSerialization.data(withJSONObject: ["retry_after": 0.001])) }
                return channelDataResponse(request, status: 204, data: Data())
            case ("discord.com", _):
                return try channelResponse(request, json: ["id": "M1"])
            default: throw URLError(.unsupportedURL)
            }
        }
        let connection = ChannelConnection(connectorID: "slack", displayName: "Slack A", accountLabel: "C1", secretReference: "keychain://channels/slack-a")
        let slack = SlackChannelConnector(session: session, resolveSecret: { _ in "slack-token" }, readBlob: { _ in bytes })
        try await slack.send(.init(text: "with file", attachments: [attachment]), to: .init(platform: "slack", channelID: "C1", threadID: "T1"), connection: connection, idempotencyKey: UUID())
        #expect(capture.requests.contains { $0.url?.path == "/upload/v1" && $0.body == bytes })
        let completion = try #require(capture.requests.first { $0.url?.path == "/api/files.completeUploadExternal" })
        let completionBody = try #require(completion.body)
        let completionJSON = try #require(JSONSerialization.jsonObject(with: completionBody) as? [String: Any])
        #expect(completionJSON["thread_ts"] as? String == "T1")

        let discordConnection = ChannelConnection(connectorID: "discord", displayName: "Discord A", accountLabel: "D1", secretReference: "keychain://channels/discord-a")
        let discord = DiscordChannelConnector(session: session, resolveSecret: { _ in "discord-token" }, readBlob: { _ in bytes }, sleep: { _ in })
        try await discord.send(.init(text: "multipart", attachments: [attachment]), to: .init(platform: "discord", channelID: "D1"), connection: discordConnection, idempotencyKey: UUID())
        let multipart = try #require(capture.requests.first { $0.url?.path == "/api/v10/channels/D1/messages" })
        #expect(multipart.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        #expect(try #require(multipart.body).range(of: bytes) != nil)
        try await discord.addReaction("✅", eventID: "M1", address: .init(platform: "discord", channelID: "D1"), connection: discordConnection)
        #expect(retryLock.withLock { reactionAttempts } == 2)
    }

    @Test func multipleAccountsRemainIndependent() async throws {
        let (root, service, _, _) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let first = ChannelConnection(connectorID: "slack", displayName: "Team One", accountLabel: "C1", secretReference: "keychain://channels/slack-one", accountID: "T1")
        let second = ChannelConnection(connectorID: "slack", displayName: "Team Two", accountLabel: "C2", secretReference: "keychain://channels/slack-two", accountID: "T2")
        _ = try await service.saveConnection(first)
        _ = try await service.saveConnection(second)
        let values = await service.connections()
        #expect(values.count == 2)
        #expect(Set(values.map(\.secretReference)) == [first.secretReference, second.secretReference])
    }
}
