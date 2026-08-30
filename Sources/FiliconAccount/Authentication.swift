import CryptoKit
import Foundation

public struct OAuthTokens: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date?
    public init(accessToken: String, refreshToken: String, expiresAt: Date? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt
    }
}

public struct AuthorizationRequest: Equatable, Sendable {
    public var url: URL
    public var state: String
    public init(url: URL, state: String) { self.url = url; self.state = state }
}

public protocol AccountSecretStore: Sendable {
    func read(_ key: String) async throws -> Data?
    func write(_ value: Data, for key: String) async throws
    func delete(_ key: String) async throws
}

public protocol AccountProvider: Sendable {
    func exchange(code: String, redirectURI: URL, verifier: String) async throws -> OAuthTokens
    func refresh(refreshToken: String) async throws -> OAuthTokens
    func profile(accessToken: String) async throws -> AccountProfile
    func entitlement(accessToken: String) async throws -> Entitlement
    func usage(accessToken: String) async throws -> UsageProjection
}

public enum AccountProviderError: Error, Equatable, Sendable {
    case cancelled, authorizationRejected, refreshRejected, network, provider(String)
}

public enum AuthenticationError: Error, Equatable, Sendable {
    case noPendingAuthorization, invalidConfiguration, invalidCallback, stateMismatch, stateExpired
    case callbackAlreadyUsed, authorizationRejected, superseded, notSignedIn, invalidCredential
}

private struct StoredTokens: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date?
    var revoked: Bool

    init(accessToken: String, refreshToken: String, expiresAt: Date?, revoked: Bool = false) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresAt = expiresAt; self.revoked = revoked
    }

    private enum CodingKeys: String, CodingKey { case accessToken, refreshToken, expiresAt, revoked }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Date.self, forKey: .expiresAt)
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
    }
}

private struct PendingAuthorization: Sendable {
    var state: String
    var verifier: String
    var expiresAt: Date
}

public actor AccountController {
    public static let tokenKey = "account.oauth.tokens"
    public static let maximumStoredCredentialByteCount = 64 * 1_024
    public static let maximumTokenLength = 32 * 1_024

    private let provider: any AccountProvider
    private let secrets: any AccountSecretStore
    private let authorizationEndpoint: URL
    private let clientID: String
    private let callbackURL: URL
    private let now: @Sendable () -> Date
    private var pending: PendingAuthorization?
    private var consumedStates: [String] = []
    private var generation: UInt64 = 0
    private var credentialMutationActive = false
    private var credentialMutationWaiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var state: AccountState = .loggedOut(retainedButRevoked: false)

    public init(provider: any AccountProvider, secrets: any AccountSecretStore, authorizationEndpoint: URL, clientID: String, callbackURL: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider; self.secrets = secrets; self.authorizationEndpoint = authorizationEndpoint
        self.clientID = clientID; self.callbackURL = callbackURL; self.now = now
    }

    @discardableResult
    public func beginSignIn(validFor: TimeInterval = 600) throws -> AuthorizationRequest {
        guard Self.validAuthorizationEndpoint(authorizationEndpoint), Self.validCallback(callbackURL),
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, clientID.count <= 1_024,
              validFor.isFinite, var parts = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false)
        else { throw AuthenticationError.invalidConfiguration }

        generation &+= 1
        let verifier = Self.randomURLSafe(byteCount: 32), oauthState = Self.randomURLSafe(byteCount: 24)
        pending = .init(state: oauthState, verifier: verifier, expiresAt: now().addingTimeInterval(max(1, min(validFor, 3_600))))
        let reserved = Set(["response_type", "client_id", "redirect_uri", "state", "code_challenge", "code_challenge_method"])
        parts.queryItems = (parts.queryItems ?? []).filter { !reserved.contains($0.name) } + [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: callbackURL.absoluteString), .init(name: "state", value: oauthState),
            .init(name: "code_challenge", value: Self.challenge(verifier)), .init(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = parts.url else { pending = nil; throw AuthenticationError.invalidConfiguration }
        state = .signingIn
        return .init(url: url, state: oauthState)
    }

    @discardableResult
    public func handleCallback(_ url: URL) async throws -> AccountState {
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let states = values.filter { $0.name == "state" }.compactMap(\.value)
        guard let pending else {
            if states.count == 1, consumedStates.contains(states[0]) { throw AuthenticationError.callbackAlreadyUsed }
            throw AuthenticationError.noPendingAuthorization
        }
        guard Self.matches(url, callbackURL) else { throw AuthenticationError.invalidCallback }
        guard states.count == 1, states[0] == pending.state else { throw AuthenticationError.stateMismatch }
        guard now() <= pending.expiresAt else {
            consume(pending); state = .error(.stateExpired, previous: nil); throw AuthenticationError.stateExpired
        }
        let oauthErrors = values.filter { $0.name == "error" }.compactMap(\.value)
        guard oauthErrors.count <= 1 else { throw AuthenticationError.invalidCallback }
        if oauthErrors.count == 1 {
            consume(pending)
            state = .error(oauthErrors[0] == "access_denied" ? .authorizationRejected : .provider("Authorization failed"), previous: nil)
            throw AuthenticationError.authorizationRejected
        }
        let codes = values.filter { $0.name == "code" }.compactMap(\.value)
        guard codes.count == 1, !codes[0].isEmpty, codes[0].count <= 8_192 else { throw AuthenticationError.invalidCallback }

        consume(pending) // consume only a fully validated callback, before suspension
        let operation = generation
        do {
            let tokens = try await provider.exchange(code: codes[0], redirectURI: callbackURL, verifier: pending.verifier)
            try check(operation); try await persist(tokens, operation: operation, fallbackRefreshToken: nil)
            let profile = try await provider.profile(accessToken: tokens.accessToken); try check(operation)
            state = .signedIn(.init(profile: profile, expiresAt: tokens.expiresAt)); return state
        } catch let error as AuthenticationError { throw error }
        catch {
            if operation == generation { state = .error(Self.failure(for: error, refreshing: false), previous: nil) }
            throw error
        }
    }

    public func restore() async -> AccountState {
        let operation = generation
        let stored: StoredTokens
        do {
            guard let value = try await readCredential() else {
                try check(operation); state = .loggedOut(retainedButRevoked: false); return state
            }
            try check(operation); stored = value
        } catch let error as AuthenticationError where error == .superseded { return state }
        catch { if operation == generation { state = .error(.secureStorage, previous: nil) }; return state }

        if stored.revoked { state = .loggedOut(retainedButRevoked: true); return state }
        guard Self.valid(stored) else { state = .error(.secureStorage, previous: nil); return state }
        if let expiry = stored.expiresAt, expiry <= now() { state = .expired(nil); return state }
        do {
            let profile = try await provider.profile(accessToken: stored.accessToken); try check(operation)
            state = .signedIn(.init(profile: profile, expiresAt: stored.expiresAt))
        } catch let error as AuthenticationError where error == .superseded { return state }
        catch { if operation == generation { state = .error(Self.failure(for: error, refreshing: false), previous: nil) } }
        return state
    }

    public func refresh() async throws -> AccountState {
        generation &+= 1
        let operation = generation
        guard let previous = state.session else { throw AuthenticationError.notSignedIn }
        let stored: StoredTokens
        do {
            guard let value = try await readCredential(), !value.revoked, Self.valid(value) else { throw AuthenticationError.notSignedIn }
            try check(operation); stored = value
        } catch let error as AuthenticationError { throw error }
        catch { if operation == generation { state = .error(.secureStorage, previous: previous) }; throw error }

        state = .refreshing(previous)
        do {
            let tokens = try await provider.refresh(refreshToken: stored.refreshToken); try check(operation)
            try await persist(tokens, operation: operation, fallbackRefreshToken: stored.refreshToken)
            let profile = try await provider.profile(accessToken: tokens.accessToken); try check(operation)
            state = .signedIn(.init(profile: profile, expiresAt: tokens.expiresAt)); return state
        } catch let error as AuthenticationError { throw error }
        catch {
            if operation == generation {
                let failure = Self.failure(for: error, refreshing: true)
                state = failure == .refreshRejected ? .expired(previous) : .error(failure, previous: previous)
            }
            throw error
        }
    }

    public func logout() async -> AccountState {
        generation &+= 1; pending = nil; state = .loggedOut(retainedButRevoked: false)
        await acquireCredentialMutation(); defer { releaseCredentialMutation() }
        do { try await secrets.delete(Self.tokenKey); state = .loggedOut(retainedButRevoked: false) }
        catch {
            // Persist a tombstone so a failed deletion cannot restore the prior session on next launch.
            let tombstone = StoredTokens(accessToken: "", refreshToken: "", expiresAt: nil, revoked: true)
            if let data = try? JSONEncoder().encode(tombstone) { try? await secrets.write(data, for: Self.tokenKey) }
            state = .loggedOut(retainedButRevoked: true)
        }
        return state
    }

    public func accessProjection() async throws -> (Entitlement, UsageProjection) {
        let operation = generation
        guard case .signedIn = state else { throw AuthenticationError.notSignedIn }
        let stored = try await readCredential(); try check(operation)
        guard let stored, !stored.revoked, Self.valid(stored), case .signedIn = state else { throw AuthenticationError.notSignedIn }
        async let entitlement = provider.entitlement(accessToken: stored.accessToken)
        async let usage = provider.usage(accessToken: stored.accessToken)
        let result = try await (entitlement, usage); try check(operation)
        guard case .signedIn = state else { throw AuthenticationError.notSignedIn }
        return result
    }

    /// Returns the current access token only while this controller still owns a
    /// valid signed-in generation. This is intended for first-party auxiliary
    /// requests (for example feedback) and never persists or logs the token.
    public func bearerTokenForAuthorizedRequest() async throws -> String {
        let operation = generation
        guard case .signedIn = state else { throw AuthenticationError.notSignedIn }
        let stored = try await readCredential(); try check(operation)
        guard let stored, !stored.revoked, Self.valid(stored), case .signedIn = state else {
            throw AuthenticationError.notSignedIn
        }
        return stored.accessToken
    }

    private func readCredential() async throws -> StoredTokens? {
        guard let data = try await secrets.read(Self.tokenKey) else { return nil }
        guard data.count <= Self.maximumStoredCredentialByteCount else { throw AuthenticationError.invalidCredential }
        return try JSONDecoder().decode(StoredTokens.self, from: data)
    }

    private func persist(_ tokens: OAuthTokens, operation: UInt64, fallbackRefreshToken: String?) async throws {
        let refresh = tokens.refreshToken.isEmpty ? (fallbackRefreshToken ?? "") : tokens.refreshToken
        let stored = StoredTokens(accessToken: tokens.accessToken, refreshToken: refresh, expiresAt: tokens.expiresAt)
        guard Self.valid(stored) else { throw AuthenticationError.invalidCredential }
        let data = try JSONEncoder().encode(stored)
        guard data.count <= Self.maximumStoredCredentialByteCount else { throw AuthenticationError.invalidCredential }
        await acquireCredentialMutation(); defer { releaseCredentialMutation() }
        try check(operation); try await secrets.write(data, for: Self.tokenKey)
        do { try check(operation) }
        catch {
            do { try await secrets.delete(Self.tokenKey) }
            catch {
                let tombstone = StoredTokens(accessToken: "", refreshToken: "", expiresAt: nil, revoked: true)
                if let data = try? JSONEncoder().encode(tombstone) { try? await secrets.write(data, for: Self.tokenKey) }
                state = .loggedOut(retainedButRevoked: true)
            }
            throw error
        }
    }

    private func consume(_ value: PendingAuthorization) {
        pending = nil; consumedStates.append(value.state)
        if consumedStates.count > 128 { consumedStates.removeFirst(consumedStates.count - 128) }
    }
    private func acquireCredentialMutation() async {
        if !credentialMutationActive { credentialMutationActive = true; return }
        await withCheckedContinuation { credentialMutationWaiters.append($0) }
    }
    private func releaseCredentialMutation() {
        if credentialMutationWaiters.isEmpty { credentialMutationActive = false }
        else { credentialMutationWaiters.removeFirst().resume() }
    }
    private func check(_ operation: UInt64) throws { guard operation == generation else { throw AuthenticationError.superseded } }

    private static func valid(_ stored: StoredTokens) -> Bool {
        !stored.revoked && !stored.accessToken.isEmpty && stored.accessToken.count <= maximumTokenLength &&
            !stored.refreshToken.isEmpty && stored.refreshToken.count <= maximumTokenLength
    }
    private static func failure(for error: Error, refreshing: Bool) -> AccountFailure {
        guard let error = error as? AccountProviderError else { return refreshing ? .refreshRejected : .tokenExchange }
        switch error {
        case .cancelled: return .cancelled
        case .authorizationRejected: return .authorizationRejected
        case .refreshRejected: return .refreshRejected
        case .network: return .network
        case .provider(let detail): return .provider(String(detail.prefix(512)))
        }
    }
    private static func validAuthorizationEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host?.lowercased() else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        return url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }
    private static func validCallback(_ url: URL) -> Bool {
        guard let scheme = url.scheme, !scheme.isEmpty, url.fragment == nil, url.query == nil,
              url.user == nil, url.password == nil else { return false }
        return url.host != nil || !url.path.isEmpty
    }
    private static func matches(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased() && lhs.host?.lowercased() == rhs.host?.lowercased() &&
            lhs.path == rhs.path && lhs.port == rhs.port && lhs.user == rhs.user && lhs.password == rhs.password && lhs.fragment == nil
    }
    private static func randomURLSafe(byteCount: Int) -> String {
        Data((0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
