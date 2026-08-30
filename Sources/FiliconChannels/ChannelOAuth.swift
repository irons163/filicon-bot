import CryptoKit
import Foundation

private final class ChannelOAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

public enum ChannelOAuthError: LocalizedError, Equatable, Sendable {
    case unsupportedProvider, invalidCallback, stateMismatch, expired, replayed, insecureRedirect, invalidResponse(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedProvider: "OAuth is not configured for this channel service."
        case .invalidCallback: "The OAuth callback is invalid."
        case .stateMismatch: "The OAuth state did not match."
        case .expired: "The OAuth request expired."
        case .replayed: "The OAuth callback was already used."
        case .insecureRedirect: "OAuth refused a non-loopback callback or unexpected service origin."
        case .invalidResponse(let value): "OAuth failed: \(value)"
        }
    }
}

public struct ChannelOAuthConfiguration: Hashable, Sendable {
    public let providerID: String
    public let clientID: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let scopes: [String]
    public init(providerID: String, clientID: String, authorizationEndpoint: URL, tokenEndpoint: URL, scopes: [String]) throws {
        guard Self.allowedEndpoints[providerID]?.authorization == authorizationEndpoint,
              Self.allowedEndpoints[providerID]?.token == tokenEndpoint else { throw ChannelOAuthError.unsupportedProvider }
        self.providerID = providerID; self.clientID = clientID
        self.authorizationEndpoint = authorizationEndpoint; self.tokenEndpoint = tokenEndpoint; self.scopes = scopes
    }

    public static func slack(clientID: String) throws -> Self {
        try .init(providerID: "slack", clientID: clientID,
                  authorizationEndpoint: URL(string: "https://slack.com/oauth/v2/authorize")!,
                  tokenEndpoint: URL(string: "https://slack.com/api/oauth.v2.access")!,
                  scopes: ["channels:history", "groups:history", "chat:write", "files:read", "files:write", "reactions:read", "reactions:write", "users:read"])
    }

    public static func discord(clientID: String) throws -> Self {
        try .init(providerID: "discord", clientID: clientID,
                  authorizationEndpoint: URL(string: "https://discord.com/oauth2/authorize")!,
                  tokenEndpoint: URL(string: "https://discord.com/api/v10/oauth2/token")!,
                  scopes: ["identify", "bot"])
    }

    private static let allowedEndpoints: [String: (authorization: URL, token: URL)] = [
        "slack": (URL(string: "https://slack.com/oauth/v2/authorize")!, URL(string: "https://slack.com/api/oauth.v2.access")!),
        "discord": (URL(string: "https://discord.com/oauth2/authorize")!, URL(string: "https://discord.com/api/v10/oauth2/token")!),
    ]
}

public struct ChannelOAuthRequest: Hashable, Sendable {
    public let authorizationURL: URL
    public let state: String
    public let expiresAt: Date
}

public struct ChannelOAuthToken: Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?
    public init(accessToken: String, refreshToken: String? = nil, tokenType: String, scope: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.tokenType = tokenType; self.scope = scope
    }
}

public actor ChannelOAuthCoordinator {
    private struct Pending: Sendable { let configuration: ChannelOAuthConfiguration; let verifier: String; let redirectURI: URL; let expiresAt: Date }
    private var pending: [String: Pending] = [:]
    private var consumed: Set<String> = []
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session; self.now = now
    }

    public func begin(configuration: ChannelOAuthConfiguration, redirectURI: URL, lifetime: TimeInterval = 600) throws -> ChannelOAuthRequest {
        guard Self.isLoopback(redirectURI), lifetime > 0 else { throw ChannelOAuthError.insecureRedirect }
        let state = Self.randomURLSafe(byteCount: 32), verifier = Self.randomURLSafe(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let expiry = now().addingTimeInterval(lifetime)
        pending[state] = .init(configuration: configuration, verifier: verifier, redirectURI: redirectURI, expiresAt: expiry)
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: configuration.clientID), .init(name: "redirect_uri", value: redirectURI.absoluteString),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
        ]
        return .init(authorizationURL: components.url!, state: state, expiresAt: expiry)
    }

    public func complete(callbackURL: URL) async throws -> ChannelOAuthToken {
        guard Self.isLoopback(callbackURL), callbackURL.fragment == nil,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { throw ChannelOAuthError.invalidCallback }
        let states = components.queryItems?.filter { $0.name == "state" }.compactMap(\.value) ?? []
        let codes = components.queryItems?.filter { $0.name == "code" }.compactMap(\.value) ?? []
        guard states.count == 1, codes.count == 1, let state = states.first, let code = codes.first, !state.isEmpty, !code.isEmpty else {
            throw ChannelOAuthError.invalidCallback
        }
        if consumed.contains(state) { throw ChannelOAuthError.replayed }
        guard let value = pending.removeValue(forKey: state) else { throw ChannelOAuthError.stateMismatch }
        consumed.insert(state)
        guard value.expiresAt >= now() else { throw ChannelOAuthError.expired }
        guard callbackURL.scheme == value.redirectURI.scheme, callbackURL.host == value.redirectURI.host,
              callbackURL.port == value.redirectURI.port, callbackURL.path == value.redirectURI.path else { throw ChannelOAuthError.invalidCallback }

        var request = URLRequest(url: value.configuration.tokenEndpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form([
            "grant_type": "authorization_code", "client_id": value.configuration.clientID, "code": code,
            "redirect_uri": value.redirectURI.absoluteString, "code_verifier": value.verifier,
        ])
        let (data, response) = try await session.data(for: request, delegate: ChannelOAuthNoRedirectDelegate())
        guard let http = response as? HTTPURLResponse, http.url == value.configuration.tokenEndpoint else { throw ChannelOAuthError.insecureRedirect }
        guard (200..<300).contains(http.statusCode), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChannelOAuthError.invalidResponse(String(data: data, encoding: .utf8) ?? "HTTP error")
        }
        let token = (json["access_token"] as? String) ?? ((json["authed_user"] as? [String: Any])?["access_token"] as? String)
        guard let token, !token.isEmpty else { throw ChannelOAuthError.invalidResponse(json["error"] as? String ?? "missing access_token") }
        return .init(accessToken: token, refreshToken: json["refresh_token"] as? String,
                     tokenType: json["token_type"] as? String ?? "Bearer", scope: json["scope"] as? String)
    }

    public func cancel(state: String) { pending.removeValue(forKey: state); consumed.insert(state) }

    private static func isLoopback(_ url: URL) -> Bool {
        url.scheme == "http" && (url.host == "127.0.0.1" || url.host == "localhost" || url.host == "::1") && url.port != nil
    }
    private static func randomURLSafe(byteCount: Int) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
    }
    private static func form(_ values: [String: String]) -> Data {
        Data(values.sorted { $0.key < $1.key }.map { key, value in
            "\(formComponent(key))=\(formComponent(value))"
        }.joined(separator: "&").utf8)
    }
    private static func formComponent(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
