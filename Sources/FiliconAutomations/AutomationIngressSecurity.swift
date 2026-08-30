import CryptoKit
import Foundation

public struct AutomationHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public enum AutomationHTTPRequestParser {
    public enum Result: Sendable { case incomplete, complete(AutomationHTTPRequest), rejected(AutomationIngressError) }

    public static func parse(_ data: Data, limits: AutomationIngressLimits = .init()) -> Result {
        guard let delimiter = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > limits.maximumHeaderBytes ? .rejected(.invalidRequest) : .incomplete
        }
        guard delimiter.lowerBound <= limits.maximumHeaderBytes,
              let head = String(data: data[..<delimiter.lowerBound], encoding: .utf8) else {
            return .rejected(.invalidRequest)
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .rejected(.invalidRequest) }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .rejected(.invalidRequest) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected(.invalidRequest) }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty, headers[key] == nil else { return .rejected(.invalidRequest) }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let rawLength = headers["content-length"], let length = Int(rawLength), length >= 0 else {
            return .rejected(.invalidRequest)
        }
        guard length <= limits.maximumBodyBytes else { return .rejected(.bodyTooLarge) }
        let bodyStart = delimiter.upperBound
        guard data.count >= bodyStart + length else { return .incomplete }
        guard data.count == bodyStart + length else { return .rejected(.invalidRequest) }
        return .complete(.init(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                               body: data.subdata(in: bodyStart..<(bodyStart + length))))
    }
}

public struct AutomationIngressAuthentication: Sendable {
    public let nonce: String
    public let timestamp: Date?
    public init(nonce: String, timestamp: Date?) { self.nonce = nonce; self.timestamp = timestamp }
}

public enum AutomationIngressSignatureVerifier {
    public static func verify(provider: AutomationIngressProvider, request: AutomationHTTPRequest,
                              secret: Data, now: Date = Date(), replayWindow: TimeInterval = 300) throws -> AutomationIngressAuthentication {
        switch provider {
        case .slack:
            let rawTimestamp = try required("x-slack-request-timestamp", request)
            let timestamp = try checkedTimestamp(rawTimestamp, now: now, window: replayWindow)
            let supplied = try required("x-slack-signature", request)
            let expected = "v0=" + hmacHex(secret: secret, data: Data("v0:\(rawTimestamp):".utf8) + request.body)
            guard constantTimeEqual(supplied, expected) else { throw AutomationIngressError.unauthorized }
            return .init(nonce: boundedNonce(request.headers["x-slack-request-id"] ?? "\(rawTimestamp):\(bodyDigest(request.body))"), timestamp: timestamp)
        case .github:
            let supplied = try required("x-hub-signature-256", request)
            guard constantTimeEqual(supplied, "sha256=" + hmacHex(secret: secret, data: request.body)) else { throw AutomationIngressError.unauthorized }
            return .init(nonce: boundedNonce(try required("x-github-delivery", request)),
                         timestamp: try optionalCheckedTimestamp(request, now: now, window: replayWindow))
        case .linear:
            let supplied = try required("linear-signature", request)
            guard constantTimeEqual(supplied, hmacHex(secret: secret, data: request.body)) else { throw AutomationIngressError.unauthorized }
            let timestamp = try linearTimestamp(request.body, header: request.headers["linear-timestamp"],
                                                now: now, window: replayWindow)
            return .init(nonce: boundedNonce(request.headers["linear-delivery"] ?? bodyIdentifier(request.body) ?? bodyDigest(request.body)),
                         timestamp: timestamp)
        case .sentry:
            let supplied = try required("sentry-hook-signature", request)
            guard constantTimeEqual(supplied.removingPrefix("sha256="), hmacHex(secret: secret, data: request.body)) else { throw AutomationIngressError.unauthorized }
            return .init(nonce: boundedNonce(request.headers["sentry-hook-request-id"] ?? bodyDigest(request.body)),
                         timestamp: try optionalCheckedTimestamp(request, now: now, window: replayWindow))
        case .pagerDuty:
            let supplied = try required("x-pagerduty-signature", request)
            let candidates = supplied.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces).removingPrefix("v1=") }
            guard candidates.contains(where: { constantTimeEqual($0, hmacHex(secret: secret, data: request.body)) }) else { throw AutomationIngressError.unauthorized }
            return .init(nonce: boundedNonce(request.headers["x-pagerduty-delivery"] ?? bodyIdentifier(request.body) ?? bodyDigest(request.body)),
                         timestamp: try optionalCheckedTimestamp(request, now: now, window: replayWindow))
        case .microsoftTeams:
            let supplied = try required("authorization", request)
            guard supplied.hasPrefix("HMAC ") else { throw AutomationIngressError.unauthorized }
            let encodedSecret = String(decoding: secret, as: UTF8.self)
            let key = Data(base64Encoded: encodedSecret) ?? secret
            let expected = Data(HMAC<SHA256>.authenticationCode(for: request.body, using: SymmetricKey(data: key))).base64EncodedString()
            guard constantTimeEqual(String(supplied.dropFirst("HMAC ".count)), expected) else {
                throw AutomationIngressError.unauthorized
            }
            return .init(nonce: bodyDigest(request.body), timestamp: nil)
        case .generic:
            let rawTimestamp = try required("x-filicon-timestamp", request)
            let nonce = try required("x-filicon-nonce", request)
            let timestamp = try checkedTimestamp(rawTimestamp, now: now, window: replayWindow)
            let supplied = try required("x-filicon-signature", request).removingPrefix("v1=")
            let signed = Data("\(rawTimestamp).\(nonce).".utf8) + request.body
            guard constantTimeEqual(supplied, hmacHex(secret: secret, data: signed)) else { throw AutomationIngressError.unauthorized }
            return .init(nonce: boundedNonce(nonce), timestamp: timestamp)
        }
    }

    public static func genericSignature(secret: Data, timestamp: Int64, nonce: String, body: Data) -> String {
        "v1=" + hmacHex(secret: secret, data: Data("\(timestamp).\(nonce).".utf8) + body)
    }

    private static func required(_ header: String, _ request: AutomationHTTPRequest) throws -> String {
        guard let value = request.headers[header], !value.isEmpty else { throw AutomationIngressError.unauthorized }
        return value
    }
    private static func checkedTimestamp(_ raw: String, now: Date, window: TimeInterval) throws -> Date {
        guard let seconds = TimeInterval(raw) else { throw AutomationIngressError.unauthorized }
        let value = Date(timeIntervalSince1970: seconds)
        guard abs(now.timeIntervalSince(value)) <= window else { throw AutomationIngressError.staleRequest }
        return value
    }
    private static func optionalCheckedTimestamp(_ request: AutomationHTTPRequest, now: Date, window: TimeInterval) throws -> Date? {
        guard let raw = request.headers["x-filicon-timestamp"] else { return nil }
        return try checkedTimestamp(raw, now: now, window: window)
    }
    private static func linearTimestamp(_ body: Data, header: String?, now: Date, window: TimeInterval) throws -> Date {
        let raw: TimeInterval?
        if let header { raw = TimeInterval(header) }
        else if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            raw = (object["webhookTimestamp"] as? NSNumber)?.doubleValue
        } else { raw = nil }
        guard let milliseconds = raw, milliseconds.isFinite else { throw AutomationIngressError.unauthorized }
        let value = Date(timeIntervalSince1970: milliseconds / 1_000)
        guard abs(now.timeIntervalSince(value)) <= window else { throw AutomationIngressError.staleRequest }
        return value
    }
    private static func bodyIdentifier(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        if let value = object["webhookId"] as? String ?? object["id"] as? String { return value }
        return (object["event"] as? [String: Any])?["id"] as? String
    }
    private static func boundedNonce(_ value: String) -> String {
        String(value.prefix(512))
    }
    private static func bodyDigest(_ body: Data) -> String {
        SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
    }
    private static func hmacHex(secret: Data, data: Data) -> String {
        HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
    }
    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
}
