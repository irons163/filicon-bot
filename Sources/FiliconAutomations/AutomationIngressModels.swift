import Foundation

public enum AutomationIngressProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case generic, slack, github, microsoftTeams, linear, sentry, pagerDuty
    public var id: String { rawValue }
    public var eventKind: String {
        switch self {
        case .microsoftTeams: "microsoftTeams"
        case .pagerDuty: "pagerduty"
        default: rawValue
        }
    }

    /// The exact authentication envelope expected by the local listener. HMAC values are
    /// lowercase SHA-256 hex over the unmodified HTTP body unless a prefix is stated.
    public var authenticationSemantics: String {
        switch self {
        case .generic:
            "x-filicon-signature: v1=HMAC(timestamp + '.' + nonce + '.' + rawBody); x-filicon-timestamp and x-filicon-nonce are required"
        case .microsoftTeams:
            "Teams outgoing webhook Authorization: HMAC base64(HMAC(rawBody)); signing key is base64 text or decoded bytes. HMAC verifies transport, not Filicon user sign-in. Replay protection is bounded; no signed timestamp proves freshness."
        case .slack:
            "x-slack-signature: v0=HMAC('v0:' + x-slack-request-timestamp + ':' + rawBody); timestamp is required"
        case .github:
            "x-hub-signature-256: sha256=HMAC(rawBody); x-github-delivery is required"
        case .linear:
            "linear-signature: HMAC(rawBody); signed payload webhookTimestamp (Unix milliseconds) is required; body digest prevents replay; linear-delivery identifies deliveries, never webhookId"
        case .sentry:
            "sentry-hook-signature: HMAC(rawBody), optionally prefixed sha256=; body digest identifies events and prevents replay within the cache window; Request-ID is diagnostic only; no signed timestamp proves freshness"
        case .pagerDuty:
            "x-pagerduty-signature: only comma-separated v1=HMAC(rawBody) candidates; body digest prevents replay within the cache window; signed event.id identifies events; X-Webhook-Id is diagnostic only; occurred_at is event time, not delivery freshness"
        }
    }
}

public struct AutomationIngressRoute: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var provider: AutomationIngressProvider
    public var secretReference: String
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, provider: AutomationIngressProvider,
                secretReference: String, enabled: Bool = true) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        self.provider = provider
        self.secretReference = secretReference
        self.enabled = enabled
    }

    public var path: String { "/hooks/\(id.uuidString.lowercased())" }
}

public enum AutomationIngressBindMode: String, Codable, CaseIterable, Sendable {
    case loopback
    case localNetwork
}

public struct AutomationIngressLimits: Codable, Hashable, Sendable {
    public var maximumBodyBytes: Int
    public var maximumHeaderBytes: Int
    public var maximumConcurrentRequests: Int
    public var requestsPerMinutePerRoute: Int
    public var replayWindow: TimeInterval

    public init(maximumBodyBytes: Int = 1_048_576, maximumHeaderBytes: Int = 32_768,
                maximumConcurrentRequests: Int = 16, requestsPerMinutePerRoute: Int = 60,
                replayWindow: TimeInterval = 300) {
        self.maximumBodyBytes = max(1_024, min(maximumBodyBytes, 10_485_760))
        self.maximumHeaderBytes = max(4_096, min(maximumHeaderBytes, 131_072))
        self.maximumConcurrentRequests = max(1, min(maximumConcurrentRequests, 128))
        self.requestsPerMinutePerRoute = max(1, min(requestsPerMinutePerRoute, 10_000))
        self.replayWindow = max(30, min(replayWindow, 3_600))
    }
}

public enum AutomationIngressRuntimeState: String, Codable, Sendable {
    case stopped, starting, running, failed
}

public struct AutomationIngressStatus: Codable, Hashable, Sendable {
    public var state: AutomationIngressRuntimeState
    public var bindMode: AutomationIngressBindMode
    public var port: UInt16?
    public var error: String?
    public init(state: AutomationIngressRuntimeState = .stopped,
                bindMode: AutomationIngressBindMode = .loopback,
                port: UInt16? = nil, error: String? = nil) {
        self.state = state; self.bindMode = bindMode; self.port = port; self.error = error
    }
}

public enum AutomationIngressAuditDisposition: String, Codable, Sendable {
    case accepted, rejected
}

public struct AutomationIngressAuditEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let routeID: UUID?
    public let provider: AutomationIngressProvider?
    public let receivedAt: Date
    public let disposition: AutomationIngressAuditDisposition
    public let reason: String
    public let externalEventID: String?
    public init(id: UUID = UUID(), routeID: UUID?, provider: AutomationIngressProvider?,
                receivedAt: Date = Date(), disposition: AutomationIngressAuditDisposition,
                reason: String, externalEventID: String? = nil) {
        self.id = id; self.routeID = routeID; self.provider = provider
        self.receivedAt = receivedAt; self.disposition = disposition
        self.reason = String(reason.prefix(240)); self.externalEventID = externalEventID.map { String($0.prefix(200)) }
    }
}

public enum AutomationIngressError: LocalizedError, Equatable, Sendable {
    case invalidRoute, invalidRequest, unsupportedMethod, unsupportedContentType
    case bodyTooLarge, unauthorized, staleRequest, replay, rateLimited, busy
    case missingSecret, notRunning, localNetworkRequiresOptIn, persistence(String), network(String)
    public var errorDescription: String? {
        switch self {
        case .invalidRoute: "No enabled webhook listener exists for this exact path."
        case .invalidRequest: "Malformed HTTP request."
        case .unsupportedMethod: "Only POST is supported."
        case .unsupportedContentType: "Webhook bodies must use application/json."
        case .bodyTooLarge: "Webhook body exceeds the configured size limit."
        case .unauthorized: "Webhook signature is invalid."
        case .staleRequest: "Webhook timestamp is outside the replay window."
        case .replay: "Webhook delivery was already received."
        case .rateLimited: "Webhook rate limit exceeded."
        case .busy: "Webhook concurrency limit exceeded."
        case .missingSecret: "Webhook secret is unavailable in Keychain."
        case .notRunning: "Webhook listener is not running."
        case .localNetworkRequiresOptIn: "LAN binding requires explicit opt-in."
        case .persistence(let detail), .network(let detail): detail
        }
    }
}

public protocol AutomationIngressSecretProvider: Sendable {
    func secret(for reference: String) async throws -> Data
}

public struct ClosureAutomationIngressSecretProvider: AutomationIngressSecretProvider {
    private let resolver: @Sendable (String) async throws -> Data
    public init(_ resolver: @escaping @Sendable (String) async throws -> Data) { self.resolver = resolver }
    public func secret(for reference: String) async throws -> Data { try await resolver(reference) }
}
