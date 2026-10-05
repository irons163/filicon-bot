import CryptoKit
import Foundation

public typealias ChannelSecretResolver = @Sendable (String) async throws -> String
public typealias ChannelBlobReader = @Sendable (ChannelAttachment) async throws -> Data
public typealias ChannelBlobIngestor = @Sendable (Data, String, String) async throws -> ChannelAttachment
public typealias ChannelSleep = @Sendable (Duration) async throws -> Void

private final class ChannelNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public enum RESTChannelConnectorError: Error, LocalizedError, Sendable {
    case invalidConfiguration(String), invalidResponse, remote(String), attachmentsRequireUpload
    case unsafeRemoteURL, attachmentTooLarge(String), unsupportedAttachmentType(String), attachmentIntegrity
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let v), .remote(let v): v
        case .invalidResponse: "The channel service returned an invalid response."
        case .attachmentsRequireUpload: "This connector needs a content-addressed blob resolver to transfer attachments."
        case .unsafeRemoteURL: "The channel service returned an untrusted URL or redirect."
        case .attachmentTooLarge(let v): "Attachment \(v) exceeds the 25 MB channel limit."
        case .unsupportedAttachmentType(let v): "Attachment type \(v) is not allowed."
        case .attachmentIntegrity: "Attachment bytes failed their SHA-256 integrity check."
        }
    }
}

enum ChannelAttachmentPolicy {
    static let maximumBytes: Int64 = 25 * 1_024 * 1_024
    static func validate(filename: String, mimeType: String, count: Int64) throws {
        guard count >= 0, count <= maximumBytes else { throw RESTChannelConnectorError.attachmentTooLarge(filename) }
        guard !filename.isEmpty, filename != ".", filename != "..", filename.utf8.count <= 255,
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RESTChannelConnectorError.attachmentIntegrity
        }
        let normalized = mimeType.lowercased()
        let safeSyntax = normalized.utf8.count <= 128
            && normalized.range(of: "^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$", options: .regularExpression) != nil
        let ok = safeSyntax && (normalized.hasPrefix("image/") || normalized.hasPrefix("audio/") || normalized.hasPrefix("video/") || normalized.hasPrefix("text/") || ["application/pdf", "application/json", "application/zip", "application/octet-stream"].contains(normalized))
        guard ok else { throw RESTChannelConnectorError.unsupportedAttachmentType(mimeType) }
    }
    static func verify(_ attachment: ChannelAttachment, _ data: Data) throws {
        try validate(filename: attachment.filename, mimeType: attachment.mimeType, count: Int64(data.count))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard attachment.byteCount == Int64(data.count), attachment.blobID == digest else { throw RESTChannelConnectorError.attachmentIntegrity }
    }
    static func detectedMIMEType(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(16))
        if bytes.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { return "image/png" }
        if bytes.starts(with: [0xff, 0xd8, 0xff]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.starts(with: Array("%PDF-".utf8)) { return "application/pdf" }
        if bytes.starts(with: [0x50, 0x4b, 0x03, 0x04]) { return "application/zip" }
        if let string = String(data: data.prefix(4_096), encoding: .utf8) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{" || trimmed.first == "[" { return "application/json" }
            if !trimmed.isEmpty { return "text/plain" }
        }
        return "application/octet-stream"
    }
}

private struct ChannelHTTP: Sendable {
    let session: URLSession
    let sleep: ChannelSleep
    func data(_ request: URLRequest, origins: Set<String>) async throws -> (Data, HTTPURLResponse) {
        var retries = 0
        while true {
            let (data, response) = try await session.data(for: request, delegate: ChannelNoRedirectDelegate())
            guard let http = response as? HTTPURLResponse, let final = http.url, final.scheme == "https",
                  origins.contains(Self.origin(final)), request.url.map({ Self.origin($0) == Self.origin(final) }) == true else { throw RESTChannelConnectorError.unsafeRemoteURL }
            if http.statusCode == 429, retries < 3 {
                retries += 1
                let jsonDelay = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["retry_after"] as? Double
                let delay = max(0, min(120, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? jsonDelay ?? 1))
                try await sleep(.milliseconds(Int64(delay * 1_000))); continue
            }
            return (data, http)
        }
    }
    static func origin(_ url: URL) -> String { "\(url.scheme ?? "")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")" }
}

public struct SlackChannelConnector: ChannelConnector {
    public let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Slack", supportsThreads: true, supportsAttachments: true)
    private let http: ChannelHTTP; private let resolveSecret: ChannelSecretResolver
    private let readBlob: ChannelBlobReader?; private let ingestBlob: ChannelBlobIngestor?; private let pollingInterval: Duration
    private static let apiOrigins: Set<String> = ["https://slack.com"]
    private static let fileOrigins: Set<String> = ["https://files.slack.com", "https://files.slack-edge.com"]
    public init(session: URLSession = .shared, pollingInterval: Duration = .seconds(3), resolveSecret: @escaping ChannelSecretResolver,
                readBlob: ChannelBlobReader? = nil, ingestBlob: ChannelBlobIngestor? = nil,
                sleep: @escaping ChannelSleep = { try await Task.sleep(for: $0) }) {
        http = .init(session: session, sleep: sleep); self.pollingInterval = pollingInterval; self.resolveSecret = resolveSecret; self.readBlob = readBlob; self.ingestBlob = ingestBlob
    }
    public func profile(connection: ChannelConnection) async throws -> ChannelProfile? {
        let token = try await resolveSecret(connection.secretReference)
        return try await profile(token: token)
    }
    private func profile(token: String) async throws -> ChannelProfile? {
        let j = try await api("auth.test", token: token)
        guard let id = j["user_id"] as? String else { return nil }
        return .init(id: id, displayName: j["user"] as? String ?? "Slack bot", workspaceID: j["team_id"] as? String)
    }
    public func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = connection.cursor
                do {
                    let token = try await resolveSecret(connection.secretReference), own = try await profile(token: token)
                    let channels = Self.channelIDs(connection.accountLabel)
                    guard !channels.isEmpty else { throw RESTChannelConnectorError.invalidConfiguration("Enter one or more Slack channel IDs.") }
                    while !Task.isCancelled {
                        var newest = cursor
                        for channel in channels {
                            var next: String?
                            repeat {
                                var q: [URLQueryItem] = [.init(name: "channel", value: channel), .init(name: "limit", value: "100")]
                                if let cursor { q.append(.init(name: "oldest", value: cursor)) }; if let next { q.append(.init(name: "cursor", value: next)) }
                                let j = try await get("conversations.history", query: q, token: token)
                                for m in (j["messages"] as? [[String: Any]] ?? []).reversed() {
                                    guard let ts = m["ts"] as? String, ts != cursor else { continue }
                                    newest = Self.newer(ts, newest)
                                    guard m["user"] as? String != own?.id, m["bot_id"] == nil, m["subtype"] as? String != "bot_message" else { continue }
                                    let files = try await download(m["files"] as? [[String: Any]] ?? [], token: token)
                                    continuation.yield(Self.envelope(m, ts: ts, channel: channel, connection: connection, attachments: files))
                                }
                                next = ((j["response_metadata"] as? [String: Any])?["next_cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                            } while next != nil && !Task.isCancelled
                        }
                        cursor = newest; try await Task.sleep(for: pollingInterval)
                    }
                } catch is CancellationError { continuation.finish() } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws {
        let token = try await resolveSecret(connection.secretReference)
        if message.attachments.isEmpty {
            var p: [String: Any] = ["channel": address.channelID, "text": message.text, "client_msg_id": idempotencyKey.uuidString]; if let t = address.threadID { p["thread_ts"] = t }
            _ = try await api("chat.postMessage", token: token, payload: p); return
        }
        guard let readBlob else { throw RESTChannelConnectorError.attachmentsRequireUpload }
        var completed: [[String: String]] = []
        for a in message.attachments {
            let bytes = try await readBlob(a); try ChannelAttachmentPolicy.verify(a, bytes)
            let grant = try await api("files.getUploadURLExternal", token: token, payload: ["filename": a.filename, "length": a.byteCount])
            guard let url = (grant["upload_url"] as? String).flatMap(URL.init(string:)), let id = grant["file_id"] as? String, Self.fileOrigins.contains(ChannelHTTP.origin(url)) else { throw RESTChannelConnectorError.unsafeRemoteURL }
            var r = URLRequest(url: url, timeoutInterval: 60); r.httpMethod = "POST"; r.httpBody = bytes; r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await http.data(r, origins: Self.fileOrigins); guard (200..<300).contains(response.statusCode) else { throw RESTChannelConnectorError.remote("Slack upload failed") }
            completed.append(["id": id, "title": a.filename])
        }
        var p: [String: Any] = ["files": completed, "channel_id": address.channelID, "initial_comment": message.text]; if let t = address.threadID { p["thread_ts"] = t }
        _ = try await api("files.completeUploadExternal", token: token, payload: p)
    }
    public func addReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws {
        let token = try await resolveSecret(connection.secretReference)
        _ = try await api("reactions.add", token: token, payload: ["channel": address.channelID, "timestamp": eventID, "name": emoji])
    }
    public func removeReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws {
        let token = try await resolveSecret(connection.secretReference)
        _ = try await api("reactions.remove", token: token, payload: ["channel": address.channelID, "timestamp": eventID, "name": emoji])
    }
    private func api(_ method: String, token: String, payload: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: "https://slack.com/api/\(method)")!, timeoutInterval: 30); r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let payload { r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: payload); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (d, h) = try await http.data(r, origins: Self.apiOrigins); guard (200..<300).contains(h.statusCode), let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw RESTChannelConnectorError.invalidResponse }
        guard j["ok"] as? Bool == true else { let e = j["error"] as? String ?? "Slack request failed"; if ["invalid_auth", "token_expired", "account_inactive"].contains(e) { throw ChannelServiceError.authExpired(e) }; throw RESTChannelConnectorError.remote(e) }; return j
    }
    private func get(_ path: String, query: [URLQueryItem], token: String) async throws -> [String: Any] {
        var c = URLComponents(string: "https://slack.com/api/\(path)")!; c.queryItems = query; var r = URLRequest(url: c.url!); r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (d, h) = try await http.data(r, origins: Self.apiOrigins)
        guard (200..<300).contains(h.statusCode), let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw RESTChannelConnectorError.invalidResponse }
        guard j["ok"] as? Bool == true else {
            let error = j["error"] as? String ?? "Slack request failed"
            if ["invalid_auth", "token_expired", "account_inactive"].contains(error) { throw ChannelServiceError.authExpired(error) }
            throw RESTChannelConnectorError.remote(error)
        }
        return j
    }
    private func download(_ files: [[String: Any]], token: String) async throws -> [ChannelAttachment] {
        guard !files.isEmpty else { return [] }; guard let ingestBlob else { throw RESTChannelConnectorError.attachmentsRequireUpload }; var out: [ChannelAttachment] = []
        for f in files {
            let n = f["name"] as? String ?? "Slack file", count = Int64(f["size"] as? Int ?? 0)
            guard count >= 0, count <= ChannelAttachmentPolicy.maximumBytes else { throw RESTChannelConnectorError.attachmentTooLarge(n) }
            guard let u = ((f["url_private_download"] ?? f["url_private"]) as? String).flatMap(URL.init(string:)), Self.fileOrigins.contains(ChannelHTTP.origin(u)) else { throw RESTChannelConnectorError.unsafeRemoteURL }
            var r = URLRequest(url: u); r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); let (d, h) = try await http.data(r, origins: Self.fileOrigins)
            guard (200..<300).contains(h.statusCode), Int64(d.count) == count else { throw RESTChannelConnectorError.attachmentIntegrity }
            let detected = ChannelAttachmentPolicy.detectedMIMEType(d); try ChannelAttachmentPolicy.validate(filename: n, mimeType: detected, count: Int64(d.count))
            let a = try await ingestBlob(d, n, detected); try ChannelAttachmentPolicy.verify(a, d); out.append(a)
        }; return out
    }
    private static func envelope(_ m: [String: Any], ts: String, channel: String, connection: ChannelConnection, attachments: [ChannelAttachment]) -> ChannelEnvelope {
        let rs = (m["reactions"] as? [[String: Any]] ?? []).compactMap { x -> ChannelReaction? in guard let n = x["name"] as? String else { return nil }; return .init(emoji: n, count: x["count"] as? Int ?? 0, actorIDs: x["users"] as? [String] ?? []) }
        return .init(connectionID: connection.id, externalEventID: ts, address: .init(platform: "slack", channelID: channel, threadID: m["thread_ts"] as? String), senderID: m["user"] as? String ?? "slack", senderDisplayName: m["username"] as? String ?? m["user"] as? String ?? "Slack", text: m["text"] as? String ?? "", timestamp: Date(timeIntervalSince1970: Double(ts) ?? Date().timeIntervalSince1970), cursor: ts, attachments: attachments, reactions: rs)
    }
    fileprivate static func channelIDs(_ v: String) -> [String] { v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    private static func newer(_ c: String, _ current: String?) -> String { current.map { c.compare($0, options: .numeric) == .orderedDescending ? c : $0 } ?? c }
}

public struct DiscordChannelConnector: ChannelConnector {
    public let descriptor = ChannelConnectorDescriptor(id: "discord", displayName: "Discord", supportsThreads: true, supportsAttachments: true)
    private let http: ChannelHTTP
    private let resolveSecret: ChannelSecretResolver
    private let readBlob: ChannelBlobReader?
    private let ingestBlob: ChannelBlobIngestor?
    private let pollingInterval: Duration
    private static let apiOrigins: Set<String> = ["https://discord.com"]
    private static let fileOrigins: Set<String> = ["https://cdn.discordapp.com", "https://media.discordapp.net"]

    public init(
        session: URLSession = .shared,
        pollingInterval: Duration = .seconds(3),
        resolveSecret: @escaping ChannelSecretResolver,
        readBlob: ChannelBlobReader? = nil,
        ingestBlob: ChannelBlobIngestor? = nil,
        sleep: @escaping ChannelSleep = { try await Task.sleep(for: $0) }
    ) {
        http = .init(session: session, sleep: sleep)
        self.pollingInterval = pollingInterval
        self.resolveSecret = resolveSecret
        self.readBlob = readBlob
        self.ingestBlob = ingestBlob
    }

    public func profile(connection: ChannelConnection) async throws -> ChannelProfile? {
        let token = try await resolveSecret(connection.secretReference)
        let json = try await api(path: "/users/@me", method: "GET", token: token, connection: connection)
        guard let id = json["id"] as? String else { return nil }
        let name = (json["global_name"] as? String) ?? (json["username"] as? String) ?? "Discord bot"
        var avatarURL: URL?
        if let avatar = json["avatar"] as? String { avatarURL = URL(string: "https://cdn.discordapp.com/avatars/\(id)/\(avatar).png") }
        return .init(id: id, displayName: name, avatarURL: avatarURL)
    }

    public func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var cursor = connection.cursor
                do {
                    let token = try await resolveSecret(connection.secretReference)
                    let own = try await profile(connection: connection)
                    let channels = SlackChannelConnector.channelIDs(connection.accountLabel)
                    guard !channels.isEmpty else { throw RESTChannelConnectorError.invalidConfiguration("Enter one or more Discord channel IDs.") }
                    while !Task.isCancelled {
                        var newest = cursor
                        for channel in channels {
                            var after = cursor
                            while !Task.isCancelled {
                                let messages = try await messagePage(channel: channel, after: after, token: token, connection: connection)
                                for message in messages.reversed() {
                                    guard let id = message["id"] as? String else { continue }
                                    newest = Self.newer(id, newest)
                                    after = Self.newer(id, after)
                                    let author = message["author"] as? [String: Any]
                                    guard author?["id"] as? String != own?.id, author?["bot"] as? Bool != true,
                                          message["webhook_id"] == nil else { continue }
                                    let attachments = try await download(message["attachments"] as? [[String: Any]] ?? [])
                                    continuation.yield(Self.envelope(message, id: id, channel: channel, connection: connection, attachments: attachments))
                                }
                                if messages.count < 100 { break }
                            }
                        }
                        cursor = newest
                        try await Task.sleep(for: pollingInterval)
                    }
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws {
        let token = try await resolveSecret(connection.secretReference)
        let channel = address.threadID ?? address.channelID
        let path = "/channels/\(Self.pathComponent(channel))/messages"
        var payload: [String: Any] = ["content": message.text, "nonce": idempotencyKey.uuidString, "enforce_nonce": true]
        if message.attachments.isEmpty {
            _ = try await api(path: path, method: "POST", token: token, connection: connection, payload: payload)
            return
        }
        guard let readBlob else { throw RESTChannelConnectorError.attachmentsRequireUpload }
        var files: [(ChannelAttachment, Data)] = []
        for attachment in message.attachments {
            let data = try await readBlob(attachment)
            try ChannelAttachmentPolicy.verify(attachment, data)
            files.append((attachment, data))
        }
        payload["attachments"] = files.enumerated().map { ["id": $0.offset, "filename": $0.element.0.filename] }
        let boundary = "Filicon-\(UUID().uuidString)"
        var body = Data()
        Self.appendPart(name: "payload_json", contentType: "application/json", data: try JSONSerialization.data(withJSONObject: payload), boundary: boundary, to: &body)
        for (index, file) in files.enumerated() {
            Self.appendPart(name: "files[\(index)]", filename: file.0.filename, contentType: file.0.mimeType, data: file.1, boundary: boundary, to: &body)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        _ = try await api(path: path, method: "POST", token: token, connection: connection, body: body, contentType: "multipart/form-data; boundary=\(boundary)")
    }

    public func addReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws {
        try await reaction(emoji, eventID: eventID, address: address, connection: connection, method: "PUT")
    }

    public func removeReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws {
        try await reaction(emoji, eventID: eventID, address: address, connection: connection, method: "DELETE")
    }

    private func reaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection, method: String) async throws {
        let token = try await resolveSecret(connection.secretReference)
        let encoded = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        let path = "/channels/\(Self.pathComponent(address.channelID))/messages/\(Self.pathComponent(eventID))/reactions/\(encoded)/@me"
        _ = try await api(path: path, method: method, token: token, connection: connection)
    }

    private func messagePage(channel: String, after: String?, token: String, connection: ChannelConnection) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://discord.com/api/v10/channels/\(Self.pathComponent(channel))/messages")!
        components.queryItems = [.init(name: "limit", value: "100")]
        if let after { components.queryItems?.append(.init(name: "after", value: after)) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.setValue(Self.authorization(token, connection: connection), forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(request, origins: Self.apiOrigins)
        try Self.validate(response, data: data)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw RESTChannelConnectorError.invalidResponse }
        return json
    }

    private func download(_ values: [[String: Any]]) async throws -> [ChannelAttachment] {
        guard !values.isEmpty else { return [] }
        guard let ingestBlob else { throw RESTChannelConnectorError.attachmentsRequireUpload }
        var result: [ChannelAttachment] = []
        for value in values {
            let name = value["filename"] as? String ?? "Discord file"
            let advertisedSize = Int64(value["size"] as? Int ?? -1)
            guard advertisedSize >= 0, advertisedSize <= ChannelAttachmentPolicy.maximumBytes else { throw RESTChannelConnectorError.attachmentTooLarge(name) }
            guard let url = (value["url"] as? String).flatMap(URL.init(string:)), Self.fileOrigins.contains(ChannelHTTP.origin(url)) else { throw RESTChannelConnectorError.unsafeRemoteURL }
            let (data, response) = try await http.data(URLRequest(url: url, timeoutInterval: 60), origins: Self.fileOrigins)
            guard (200..<300).contains(response.statusCode), Int64(data.count) == advertisedSize else { throw RESTChannelConnectorError.attachmentIntegrity }
            let mime = ChannelAttachmentPolicy.detectedMIMEType(data)
            try ChannelAttachmentPolicy.validate(filename: name, mimeType: mime, count: Int64(data.count))
            let attachment = try await ingestBlob(data, name, mime)
            try ChannelAttachmentPolicy.verify(attachment, data)
            result.append(attachment)
        }
        return result
    }

    private func api(path: String, method: String, token: String, connection: ChannelConnection, payload: [String: Any]? = nil, body: Data? = nil, contentType: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://discord.com/api/v10\(path)")!, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(Self.authorization(token, connection: connection), forHTTPHeaderField: "Authorization")
        if let payload { request.httpBody = try JSONSerialization.data(withJSONObject: payload); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let body { request.httpBody = body; request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await http.data(request, origins: Self.apiOrigins)
        try Self.validate(response, data: data)
        if data.isEmpty { return [:] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RESTChannelConnectorError.invalidResponse }
        return json
    }

    private static func validate(_ response: HTTPURLResponse, data: Data) throws {
        if response.statusCode == 401 || response.statusCode == 403 {
            let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String) ?? "Discord authorization failed"
            throw ChannelServiceError.authExpired(detail)
        }
        guard (200..<300).contains(response.statusCode) else {
            let detail = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String) ?? "Discord request failed (HTTP \(response.statusCode))"
            throw RESTChannelConnectorError.remote(detail)
        }
    }

    private static func authorization(_ token: String, connection: ChannelConnection) -> String {
        connection.authKind == .oauth ? "Bearer \(token)" : "Bot \(token)"
    }

    private static func envelope(_ message: [String: Any], id: String, channel: String, connection: ChannelConnection, attachments: [ChannelAttachment]) -> ChannelEnvelope {
        let author = message["author"] as? [String: Any]
        let reference = message["message_reference"] as? [String: Any]
        let threadID = (message["thread"] as? [String: Any])?["id"] as? String ?? reference?["message_id"] as? String
        let reactions = (message["reactions"] as? [[String: Any]] ?? []).compactMap { item -> ChannelReaction? in
            guard let emojiValue = item["emoji"] as? [String: Any], let emoji = (emojiValue["name"] as? String) ?? (emojiValue["id"] as? String) else { return nil }
            return .init(emoji: emoji, count: item["count"] as? Int ?? 0)
        }
        let date = (message["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return .init(connectionID: connection.id, externalEventID: id,
                     address: .init(platform: "discord", channelID: channel, threadID: threadID),
                     senderID: author?["id"] as? String ?? "discord",
                     senderDisplayName: author?["global_name"] as? String ?? author?["username"] as? String ?? "Discord",
                     text: message["content"] as? String ?? "", timestamp: date, cursor: id,
                     attachments: attachments, reactions: reactions)
    }

    private static func newer(_ value: String, _ current: String?) -> String {
        current.map { value.compare($0, options: .numeric) == .orderedDescending ? value : $0 } ?? value
    }
    private static func pathComponent(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value }
    private static func appendPart(name: String, filename: String? = nil, contentType: String, data: Data, boundary: String, to body: inout Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        var disposition = "Content-Disposition: form-data; name=\"\(name)\""
        if let filename {
            let safe = filename.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == "\"" ? "_" : String($0) }.joined()
            disposition += "; filename=\"\(safe)\""
        }
        body.append(Data("\(disposition)\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }
}
