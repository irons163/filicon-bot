import CryptoKit
import Foundation

public enum MCPOAuthFlowError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidCallback
    case expired
    case insecureRedirect
    case responseTooLarge
    case provider(String)
    case transport

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): "Invalid MCP OAuth configuration: \(detail)"
        case .invalidCallback: "The MCP OAuth callback is malformed or does not match this request."
        case .expired: "The MCP OAuth request expired. Start authentication again."
        case .insecureRedirect: "MCP OAuth refused an unexpected or insecure redirect."
        case .responseTooLarge: "The MCP OAuth token response exceeded the safe size limit."
        case .provider(let detail): "MCP OAuth failed: \(detail)"
        case .transport: "The MCP OAuth token service could not be reached securely."
        }
    }
}

public struct MCPOAuthConfiguration: Hashable, Sendable {
    public let clientID: String
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let scopes: [String]
    public let audience: String?

    public init(
        clientID: String,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        scopes: [String] = [],
        audience: String? = nil
    ) throws {
        let clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, clientID.utf8.count <= 1_024,
              !clientID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MCPOAuthFlowError.invalidConfiguration("client ID")
        }
        try Self.requireSecureEndpoint(authorizationEndpoint, label: "authorization endpoint")
        try Self.requireSecureEndpoint(tokenEndpoint, label: "token endpoint")
        guard scopes.count <= 64,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: \.isWhitespace) }) else {
            throw MCPOAuthFlowError.invalidConfiguration("scopes")
        }
        let audience = audience?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard audience?.utf8.count ?? 0 <= 2_048,
              audience?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) != true else {
            throw MCPOAuthFlowError.invalidConfiguration("audience")
        }
        self.clientID = clientID
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scopes = scopes
        self.audience = audience?.isEmpty == true ? nil : audience
    }

    private static func requireSecureEndpoint(_ url: URL, label: String) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw MCPOAuthFlowError.invalidConfiguration(label)
        }
    }
}

public struct MCPOAuthPreparedRequest: Hashable, Sendable {
    public let pending: MCPOAuthPending
    public let authorizationURL: URL
    fileprivate let verifier: String
    fileprivate let expiresAt: Date
}

public struct MCPOAuthToken: Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let tokenType: String
    public let scope: String?

    public var authorizationHeaderValue: String { "\(tokenType) \(accessToken)" }
}

public struct MCPOAuthHTTPResponse: Sendable {
    public let statusCode: Int
    public let finalURL: URL
    public let body: Data

    public init(statusCode: Int, finalURL: URL, body: Data) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.body = body
    }
}

public protocol MCPOAuthTokenTransport: Sendable {
    func exchange(request: URLRequest, expectedEndpoint: URL) async throws -> MCPOAuthHTTPResponse
}

private final class MCPOAuthNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

public struct URLSessionMCPOAuthTokenTransport: MCPOAuthTokenTransport {
    public static let maximumResponseBytes = 1_048_576
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            self.session = URLSession(configuration: configuration)
        }
    }

    public func exchange(request: URLRequest, expectedEndpoint: URL) async throws -> MCPOAuthHTTPResponse {
        do {
            let (data, response) = try await session.data(for: request, delegate: MCPOAuthNoRedirectDelegate())
            guard data.count <= Self.maximumResponseBytes else { throw MCPOAuthFlowError.responseTooLarge }
            guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                  Self.sameEndpoint(finalURL, expectedEndpoint) else {
                throw MCPOAuthFlowError.insecureRedirect
            }
            return .init(statusCode: http.statusCode, finalURL: finalURL, body: data)
        } catch let error as MCPOAuthFlowError {
            throw error
        } catch {
            throw MCPOAuthFlowError.transport
        }
    }

    private static func sameEndpoint(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port && lhs.path == rhs.path && lhs.query == rhs.query
    }
}

public actor MCPOAuthFlowCoordinator {
    private let pendingCoordinator: MCPOAuthPendingCoordinator
    private let transport: any MCPOAuthTokenTransport
    private let now: @Sendable () -> Date

    public init(
        pendingCoordinator: MCPOAuthPendingCoordinator,
        transport: any MCPOAuthTokenTransport = URLSessionMCPOAuthTokenTransport(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.pendingCoordinator = pendingCoordinator
        self.transport = transport
        self.now = now
    }

    public func begin(
        serverID: String,
        accountKey: String,
        configuration: MCPOAuthConfiguration,
        callbackURL: URL,
        lifetime: TimeInterval = 600
    ) async throws -> MCPOAuthPreparedRequest {
        guard lifetime > 0, lifetime <= 600 else {
            throw MCPOAuthFlowError.invalidConfiguration("lifetime")
        }
        let verifier = Self.randomURLSafe(byteCount: 48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let pending = try await pendingCoordinator.begin(
            serverID: serverID,
            accountKey: accountKey,
            authorizationURL: configuration.authorizationEndpoint,
            callbackURL: callbackURL,
            now: now()
        )
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.append(contentsOf: [
            .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: callbackURL.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "state", value: pending.state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ])
        if !configuration.scopes.isEmpty {
            items.append(.init(name: "scope", value: configuration.scopes.joined(separator: " ")))
        }
        if let audience = configuration.audience { items.append(.init(name: "audience", value: audience)) }
        components?.queryItems = items
        guard let authorizationURL = components?.url else {
            await pendingCoordinator.cancel(serverID: serverID, accountKey: accountKey)
            throw MCPOAuthFlowError.invalidConfiguration("authorization URL")
        }
        return .init(
            pending: pending,
            authorizationURL: authorizationURL,
            verifier: verifier,
            expiresAt: now().addingTimeInterval(lifetime)
        )
    }

    public func complete(
        callbackURL: URL,
        request prepared: MCPOAuthPreparedRequest,
        configuration: MCPOAuthConfiguration
    ) async throws -> MCPOAuthToken {
        guard now() <= prepared.expiresAt,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callbackURL.fragment == nil else { throw MCPOAuthFlowError.expired }
        let items = components.queryItems ?? []
        let states = items.filter { $0.name == "state" }.compactMap(\.value)
        if let error = Self.singleValue(named: "error", in: items) {
            guard states == [prepared.pending.state] else { throw MCPOAuthFlowError.invalidCallback }
            try await pendingCoordinator.validateCompletion(
                serverID: prepared.pending.serverID, accountKey: prepared.pending.accountKey,
                state: prepared.pending.state, callbackURL: callbackURL,
                generation: prepared.pending.generation
            )
            throw MCPOAuthFlowError.provider(Self.safeProviderError(error))
        }
        let codes = items.filter { $0.name == "code" }.compactMap(\.value)
        guard states == [prepared.pending.state], codes.count == 1,
              let code = codes.first, !code.isEmpty, code.utf8.count <= 16_384 else {
            throw MCPOAuthFlowError.invalidCallback
        }
        try await pendingCoordinator.validateCompletion(
            serverID: prepared.pending.serverID, accountKey: prepared.pending.accountKey,
            state: prepared.pending.state, callbackURL: callbackURL,
            generation: prepared.pending.generation
        )
        var tokenRequest = URLRequest(url: configuration.tokenEndpoint, timeoutInterval: 20)
        tokenRequest.httpMethod = "POST"
        tokenRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        tokenRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        tokenRequest.httpBody = Self.form([
            "grant_type": "authorization_code",
            "client_id": configuration.clientID,
            "code": code,
            "redirect_uri": prepared.pending.callbackURL.absoluteString,
            "code_verifier": prepared.verifier,
        ])
        let response = try await transport.exchange(request: tokenRequest, expectedEndpoint: configuration.tokenEndpoint)
        guard response.body.count <= URLSessionMCPOAuthTokenTransport.maximumResponseBytes else {
            throw MCPOAuthFlowError.responseTooLarge
        }
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        guard (200..<300).contains(response.statusCode), let json else {
            let label = (json?["error"] as? String).map(Self.safeProviderError) ?? "HTTP \(response.statusCode)"
            throw MCPOAuthFlowError.provider(label)
        }
        guard let accessToken = json["access_token"] as? String,
              !accessToken.isEmpty, accessToken.utf8.count <= 65_536,
              !accessToken.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw MCPOAuthFlowError.provider("missing or invalid access token")
        }
        let tokenType = (json["token_type"] as? String ?? "Bearer").trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw MCPOAuthFlowError.provider("unsupported token type")
        }
        let refreshToken = json["refresh_token"] as? String
        guard refreshToken?.utf8.count ?? 0 <= 65_536,
              refreshToken?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) != true else {
            throw MCPOAuthFlowError.provider("invalid refresh token")
        }
        return .init(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: "Bearer",
            scope: (json["scope"] as? String).map { String($0.prefix(4_096)) }
        )
    }

    private static func singleValue(named name: String, in items: [URLQueryItem]) -> String? {
        let values = items.filter { $0.name == name }.compactMap(\.value)
        return values.count == 1 ? values[0] : nil
    }

    private static func safeProviderError(_ value: String) -> String {
        let clean = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(clean).prefix(256))
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
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
