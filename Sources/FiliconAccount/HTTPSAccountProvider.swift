import Foundation

public struct HTTPSAccountProviderConfiguration: Sendable {
    public let clientID: String
    public let redirectURI: URL
    public let tokenEndpoint: URL
    public let profileEndpoint: URL
    public let entitlementEndpoint: URL
    public let usageEndpoint: URL
    public let maximumResponseByteCount: Int

    public init(clientID: String, redirectURI: URL, tokenEndpoint: URL, profileEndpoint: URL, entitlementEndpoint: URL, usageEndpoint: URL, maximumResponseByteCount: Int = 1_048_576) throws {
        guard !clientID.isEmpty, clientID.count <= 1_024, HTTPSRequestSafety.validRedirectURI(redirectURI),
              [tokenEndpoint, profileEndpoint, entitlementEndpoint, usageEndpoint].allSatisfy(HTTPSRequestSafety.validEndpoint),
              (1...8_388_608).contains(maximumResponseByteCount) else { throw HTTPSAccountProviderError.invalidConfiguration }
        self.clientID = clientID; self.redirectURI = redirectURI; self.tokenEndpoint = tokenEndpoint
        self.profileEndpoint = profileEndpoint; self.entitlementEndpoint = entitlementEndpoint; self.usageEndpoint = usageEndpoint
        self.maximumResponseByteCount = maximumResponseByteCount
    }
}

public enum HTTPSAccountProviderError: Error, Equatable, Sendable { case invalidConfiguration, invalidResponse, responseTooLarge }

public struct HTTPSAccountProvider: AccountProvider {
    private let configuration: HTTPSAccountProviderConfiguration
    private let session: URLSession

    public init(configuration: HTTPSAccountProviderConfiguration, session: URLSession = .shared) {
        self.configuration = configuration; self.session = session
    }

    public func exchange(code: String, redirectURI: URL, verifier: String) async throws -> OAuthTokens {
        guard redirectURI == configuration.redirectURI, !code.isEmpty, code.count <= 8_192,
              (43...128).contains(verifier.count) else { throw AccountProviderError.authorizationRejected }
        return try await tokenRequest(endpoint: configuration.tokenEndpoint, fields: [
            ("grant_type", "authorization_code"), ("client_id", configuration.clientID), ("code", code),
            ("redirect_uri", redirectURI.absoluteString), ("code_verifier", verifier),
        ], refreshing: false)
    }

    public func refresh(refreshToken: String) async throws -> OAuthTokens {
        guard HTTPSRequestSafety.validBearer(refreshToken) else { throw AccountProviderError.refreshRejected }
        return try await tokenRequest(endpoint: configuration.tokenEndpoint, fields: [
            ("grant_type", "refresh_token"), ("client_id", configuration.clientID), ("refresh_token", refreshToken),
        ], refreshing: true)
    }

    public func profile(accessToken: String) async throws -> AccountProfile {
        let value: ProfileResponse = try await authenticatedGET(configuration.profileEndpoint, token: accessToken)
        return try AccountProfile(id: value.id, email: value.email, displayName: value.displayName, avatarURL: value.avatarURL)
    }

    public func entitlement(accessToken: String) async throws -> Entitlement {
        let value: EntitlementResponse = try await authenticatedGET(configuration.entitlementEndpoint, token: accessToken)
        return Entitlement(state: value.state, reason: value.reason ?? .none)
    }

    public func usage(accessToken: String) async throws -> UsageProjection {
        let value: UsageResponse = try await authenticatedGET(configuration.usageEndpoint, token: accessToken)
        return UsageProjection(fractionUsed: value.fractionUsed, resetsAt: value.resetsAt, includedAllowance: value.includedAllowance, available: value.available, onDemandUsedMinorUnits: value.onDemandUsedMinorUnits, onDemandLimitMinorUnits: value.onDemandLimitMinorUnits)
    }

    private func tokenRequest(endpoint: URL, fields: [(String, String)], refreshing: Bool) async throws -> OAuthTokens {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents(); components.queryItems = fields.map(URLQueryItem.init)
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else { throw statusFailure(response.statusCode, refreshing: refreshing) }
        let value: TokenResponse = try decode(data)
        guard HTTPSRequestSafety.validBearer(value.accessToken), value.refreshToken == nil || value.refreshToken!.count <= AccountController.maximumTokenLength else {
            throw HTTPSAccountProviderError.invalidResponse
        }
        return OAuthTokens(accessToken: value.accessToken, refreshToken: value.refreshToken ?? "", expiresAt: value.expiresIn.map { Date.now.addingTimeInterval(max(0, min($0, 31_536_000))) })
    }

    private func authenticatedGET<T: Decodable>(_ endpoint: URL, token: String) async throws -> T {
        guard HTTPSRequestSafety.validBearer(token) else { throw AccountProviderError.authorizationRejected }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await perform(request)
        guard (200..<300).contains(response.statusCode) else { throw statusFailure(response.statusCode, refreshing: false) }
        return try decode(data)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request, delegate: HTTPSNoRedirectDelegate.shared)
            guard data.count <= configuration.maximumResponseByteCount else { throw HTTPSAccountProviderError.responseTooLarge }
            guard let response = response as? HTTPURLResponse, response.url == request.url else { throw HTTPSAccountProviderError.invalidResponse }
            return (data, response)
        } catch let error as HTTPSAccountProviderError { throw error }
        catch let error as AccountProviderError { throw error }
        catch { throw AccountProviderError.network }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try HTTPSRequestSafety.makeDecoder().decode(T.self, from: data) }
        catch { throw HTTPSAccountProviderError.invalidResponse }
    }

    private func statusFailure(_ status: Int, refreshing: Bool) -> AccountProviderError {
        if refreshing && [400, 401, 403].contains(status) { return .refreshRejected }
        if [400, 401, 403].contains(status) { return .authorizationRejected }
        if status == 408 || status == 429 || status >= 500 { return .network }
        return .provider("HTTP \(status)")
    }
}

private struct TokenResponse: Decodable {
    var accessToken: String; var refreshToken: String?; var expiresIn: TimeInterval?
    enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
}
private struct ProfileResponse: Decodable {
    var id: String; var email: String?; var displayName: String?; var avatarURL: URL?
    enum CodingKeys: String, CodingKey { case id, email, displayName = "display_name", avatarURL = "avatar_url" }
}
private struct EntitlementResponse: Decodable { var state: EntitlementState; var reason: EntitlementReason? }
private struct UsageResponse: Decodable {
    var fractionUsed: Double?; var resetsAt: Date?; var includedAllowance: Bool; var available: Bool
    var onDemandUsedMinorUnits: Int?; var onDemandLimitMinorUnits: Int?
    enum CodingKeys: String, CodingKey {
        case fractionUsed = "fraction_used", resetsAt = "resets_at", includedAllowance = "included_allowance", available
        case onDemandUsedMinorUnits = "on_demand_used_minor_units", onDemandLimitMinorUnits = "on_demand_limit_minor_units"
    }
}

enum HTTPSRequestSafety {
    static func makeDecoder() -> JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
    static func validEndpoint(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return true
    }
    static func validRedirectURI(_ url: URL) -> Bool {
        url.scheme != nil && (url.host != nil || !url.path.isEmpty) && url.user == nil && url.password == nil && url.fragment == nil && url.query == nil
    }
    static func validBearer(_ value: String) -> Bool {
        !value.isEmpty && value.count <= AccountController.maximumTokenLength && !value.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 0x20 })
    }
}

final class HTTPSNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = HTTPSNoRedirectDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
