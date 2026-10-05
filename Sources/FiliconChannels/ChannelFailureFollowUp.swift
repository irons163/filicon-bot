import Foundation

/// Allow-listed facts for a failure notice. Connector error bodies may contain
/// tokens or arbitrary server text and must never become a model instruction.
public enum ChannelFailureReason: String, Codable, Hashable, Sendable {
    case authorizationExpired, connectionUnavailable, configurationChanged
    case connectorUnavailable, unsupportedCapability, invalidPublication, transportFailed

    public var descriptionForModel: String {
        switch self {
        case .authorizationExpired: "The channel authorization expired. Offer help reconnecting."
        case .connectionUnavailable: "The original channel connection is unavailable or disabled."
        case .configurationChanged: "The reviewed channel configuration changed before delivery."
        case .connectorUnavailable: "The channel connector is unavailable."
        case .unsupportedCapability: "The connector does not support this publication."
        case .invalidPublication: "The channel publication did not pass validation."
        case .transportFailed: "The channel transport failed; no successful delivery was confirmed."
        }
    }

    static func classify(_ error: any Error) -> Self {
        if let error = error as? ChannelServiceError {
            switch error {
            case .authExpired: return .authorizationExpired
            case .unknownConnection, .disabledConnection: return .connectionUnavailable
            case .unknownConnector: return .connectorUnavailable
            case .unsupportedCapability: return .unsupportedCapability
            case .invalidConnection, .invalidEnvelope, .invalidOutbound: return .invalidPublication
            }
        }
        if let error = error as? ChannelPublicationError {
            switch error {
            case .invalid, .idempotencyConflict: return .invalidPublication
            case .unavailable: return .connectionUnavailable
            case .ambiguous, .stale: return .configurationChanged
            }
        }
        return .transportFailed
    }
}

/// Durable at-most-once admission for an original direct member's failure wake.
/// This is bookkeeping, never consent to resend, permission, or a human turn.
public struct ChannelFailureFollowUp: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable {
        case running, completed, failed, cancelled, interrupted
    }
    public let id: UUID // The authoritative failure wake ID, also the model run ID.
    public let deliveryID: UUID
    public let connectionID: UUID
    public let accountID: String
    public let agentID: UUID
    public let conversationID: UUID
    public let startedAt: Date
    public internal(set) var status: Status
    public internal(set) var finishedAt: Date?

    init(wake: ChannelFailureWake, authorization: ChannelDeliveryAuthorization,
         origin: ChannelDeliveryOrigin, at: Date) {
        id = wake.id; deliveryID = wake.deliveryID; connectionID = wake.connectionID
        accountID = authorization.ownerAccountID; agentID = authorization.agentID
        conversationID = origin.conversationID; startedAt = at; status = .running
    }

    func isConsistent(with delivery: ChannelDelivery) -> Bool {
        guard let authorization = delivery.authorization, let origin = delivery.origin,
              delivery.status == .deadLetter, origin.route == .directConversation,
              origin.isConsistent(agentID: authorization.agentID, outbound: delivery.outbound),
              delivery.id == deliveryID, delivery.connectionID == connectionID,
              authorization.ownerAccountID == accountID, authorization.agentID == agentID,
              origin.conversationID == conversationID, startedAt.timeIntervalSince1970.isFinite else { return false }
        if status == .running { return finishedAt == nil }
        return finishedAt.map { $0.timeIntervalSince1970.isFinite && $0 >= startedAt } == true
    }
}
