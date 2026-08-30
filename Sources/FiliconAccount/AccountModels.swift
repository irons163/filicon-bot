import Foundation

public struct AccountProfile: Codable, Equatable, Sendable {
    public static let maximumNameLength = 120
    public static let maximumEmailLength = 320
    public static let maximumAvatarURLLength = 2_048

    public let id: String
    public let email: String?
    public let displayName: String?
    public let avatarURL: URL?

    public init(id: String, email: String? = nil, displayName: String? = nil, avatarURL: URL? = nil) throws {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty, normalizedID.count <= 512, !normalizedID.contains(where: { $0.isNewline || ($0.isASCII && ($0.asciiValue ?? 0) < 0x20) }) else { throw AccountValidationError.invalidIdentifier }
        let email = Self.bounded(email, maximum: Self.maximumEmailLength)
        let name = Self.bounded(displayName?.split(whereSeparator: \Character.isWhitespace).joined(separator: " "), maximum: Self.maximumNameLength)
        let avatar: URL? = avatarURL.flatMap { url -> URL? in
            guard url.absoluteString.count <= Self.maximumAvatarURLLength,
                  url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
        self.id = normalizedID
        self.email = email
        self.displayName = name
        self.avatarURL = avatar
    }

    private enum CodingKeys: String, CodingKey { case id, email, displayName, avatarURL }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(String.self, forKey: .id), email: try? c.decodeIfPresent(String.self, forKey: .email), displayName: try? c.decodeIfPresent(String.self, forKey: .displayName), avatarURL: try? c.decodeIfPresent(URL.self, forKey: .avatarURL))
    }

    private static func bounded(_ value: String?, maximum: Int) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean.count > maximum ? nil : clean
    }
}

public enum AccountValidationError: Error, Equatable, Sendable { case invalidIdentifier, invalidDisplayName, invalidAvatar }

public struct AvatarImage: Equatable, Sendable {
    public static let maximumByteCount = 1_048_576
    public let data: Data
    public let mediaType: String
    public init(data: Data, mediaType: String) throws {
        let mediaType = mediaType.lowercased().split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        guard !data.isEmpty, data.count <= Self.maximumByteCount, mediaType.hasPrefix("image/") else { throw AccountValidationError.invalidAvatar }
        self.data = data; self.mediaType = mediaType
    }
}

public struct AccountSession: Codable, Equatable, Sendable {
    public var profile: AccountProfile
    public var expiresAt: Date?
    public init(profile: AccountProfile, expiresAt: Date? = nil) { self.profile = profile; self.expiresAt = expiresAt }
}

public enum AccountFailure: Codable, Equatable, Sendable {
    case cancelled, authorizationRejected, callbackInvalid, stateExpired, tokenExchange, refreshRejected, secureStorage, network, provider(String)

    private enum CodingKeys: String, CodingKey { case kind, detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? c.decode(String.self, forKey: .kind)) {
        case "cancelled": self = .cancelled; case "authorizationRejected": self = .authorizationRejected
        case "callbackInvalid": self = .callbackInvalid; case "stateExpired": self = .stateExpired
        case "tokenExchange": self = .tokenExchange; case "refreshRejected": self = .refreshRejected
        case "secureStorage": self = .secureStorage; case "network": self = .network
        case "provider": self = .provider(String(((try? c.decode(String.self, forKey: .detail)) ?? "Unknown provider error").prefix(512)))
        default: self = .provider("Unknown account error")
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let value: (String, String?) = switch self {
        case .cancelled: ("cancelled", nil); case .authorizationRejected: ("authorizationRejected", nil)
        case .callbackInvalid: ("callbackInvalid", nil); case .stateExpired: ("stateExpired", nil)
        case .tokenExchange: ("tokenExchange", nil); case .refreshRejected: ("refreshRejected", nil)
        case .secureStorage: ("secureStorage", nil); case .network: ("network", nil)
        case .provider(let detail): ("provider", detail)
        }
        try c.encode(value.0, forKey: .kind); try c.encodeIfPresent(value.1, forKey: .detail)
    }
}

public enum AccountState: Codable, Equatable, Sendable {
    case loggedOut(retainedButRevoked: Bool)
    case signingIn
    case signedIn(AccountSession)
    case refreshing(AccountSession)
    case expired(AccountSession?)
    case error(AccountFailure, previous: AccountSession?)

    public var session: AccountSession? { switch self { case .signedIn(let s), .refreshing(let s): s; case .expired(let s), .error(_, let s): s; default: nil } }
    private enum CodingKeys: String, CodingKey { case kind, retainedButRevoked, session, failure, previous }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? c.decode(String.self, forKey: .kind)) {
        case "signingIn", "logging-in": self = .signingIn
        case "signedIn", "logged-in":
            if let s = try? c.decode(AccountSession.self, forKey: .session) { self = .signedIn(s) } else { self = .loggedOut(retainedButRevoked: false) }
        case "refreshing":
            if let s = try? c.decode(AccountSession.self, forKey: .session) { self = .refreshing(s) } else { self = .loggedOut(retainedButRevoked: false) }
        case "expired": self = .expired(try? c.decodeIfPresent(AccountSession.self, forKey: .session))
        case "error": self = .error((try? c.decode(AccountFailure.self, forKey: .failure)) ?? .provider("Unknown account error"), previous: try? c.decodeIfPresent(AccountSession.self, forKey: .previous))
        default: self = .loggedOut(retainedButRevoked: (try? c.decode(Bool.self, forKey: .retainedButRevoked)) ?? false)
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loggedOut(let retained): try c.encode("loggedOut", forKey: .kind); try c.encode(retained, forKey: .retainedButRevoked)
        case .signingIn: try c.encode("signingIn", forKey: .kind)
        case .signedIn(let s): try c.encode("signedIn", forKey: .kind); try c.encode(s, forKey: .session)
        case .refreshing(let s): try c.encode("refreshing", forKey: .kind); try c.encode(s, forKey: .session)
        case .expired(let s): try c.encode("expired", forKey: .kind); try c.encodeIfPresent(s, forKey: .session)
        case .error(let f, let p): try c.encode("error", forKey: .kind); try c.encode(f, forKey: .failure); try c.encodeIfPresent(p, forKey: .previous)
        }
    }
}

public enum EntitlementState: String, Codable, Sendable {
    case checking, granted, unavailable, paymentRequired, unknown
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
public enum EntitlementReason: String, Codable, Sendable {
    case none, organizationPolicy, setupRequired, notOffered, trialAvailable, paywall, unspecified
    public init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unspecified }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}
public struct Entitlement: Codable, Equatable, Sendable {
    public var state: EntitlementState; public var reason: EntitlementReason
    public init(state: EntitlementState, reason: EntitlementReason = .none) { self.state = state; self.reason = reason }
}
public struct UsageProjection: Codable, Equatable, Sendable {
    public var fractionUsed: Double?; public var resetsAt: Date?; public var includedAllowance: Bool; public var available: Bool; public var onDemandUsedMinorUnits: Int?; public var onDemandLimitMinorUnits: Int?
    public init(fractionUsed: Double?, resetsAt: Date?, includedAllowance: Bool, available: Bool, onDemandUsedMinorUnits: Int? = nil, onDemandLimitMinorUnits: Int? = nil) {
        self.fractionUsed = fractionUsed.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
        self.resetsAt = resetsAt; self.includedAllowance = includedAllowance; self.available = available
        self.onDemandUsedMinorUnits = onDemandUsedMinorUnits.map { max(0, $0) }
        self.onDemandLimitMinorUnits = onDemandLimitMinorUnits.map { max(0, $0) }
    }
    private enum CodingKeys: String, CodingKey { case fractionUsed, resetsAt, includedAllowance, available, onDemandUsedMinorUnits, onDemandLimitMinorUnits }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(fractionUsed: try c.decodeIfPresent(Double.self, forKey: .fractionUsed), resetsAt: try c.decodeIfPresent(Date.self, forKey: .resetsAt), includedAllowance: try c.decode(Bool.self, forKey: .includedAllowance), available: try c.decode(Bool.self, forKey: .available), onDemandUsedMinorUnits: try c.decodeIfPresent(Int.self, forKey: .onDemandUsedMinorUnits), onDemandLimitMinorUnits: try c.decodeIfPresent(Int.self, forKey: .onDemandLimitMinorUnits))
    }
}
