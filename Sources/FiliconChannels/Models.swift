import Foundation

public struct ChannelConnectorDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let supportsThreads: Bool
    public let supportsAttachments: Bool
    public init(id: String, displayName: String, supportsThreads: Bool = true, supportsAttachments: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.supportsThreads = supportsThreads
        self.supportsAttachments = supportsAttachments
    }
}

public struct ChannelConnection: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let connectorID: String
    public var displayName: String
    public var accountLabel: String
    public var secretReference: String
    public var enabled: Bool
    public var cursor: String?
    public var lastActivityAt: Date?
    public var agentID: UUID?
    public var authKind: ChannelAuthKind?
    /// Remote connector identity (for example a Slack workspace), not a Filicon account.
    public var accountID: String?
    /// Host ownership for scoped credential operations. Legacy records remain local.
    public var ownerAccountID: String?
    public var authorizationAccountID: String { ownerAccountID ?? "local" }
    public var profile: ChannelProfile?

    public init(
        id: UUID = UUID(), connectorID: String, displayName: String,
        accountLabel: String = "", secretReference: String,
        enabled: Bool = true, cursor: String? = nil, lastActivityAt: Date? = nil,
        agentID: UUID? = nil, authKind: ChannelAuthKind? = nil,
        accountID: String? = nil, profile: ChannelProfile? = nil, ownerAccountID: String? = nil
    ) {
        self.id = id
        self.connectorID = connectorID
        self.displayName = displayName
        self.accountLabel = accountLabel
        self.secretReference = secretReference
        self.enabled = enabled
        self.cursor = cursor
        self.lastActivityAt = lastActivityAt
        self.agentID = agentID
        self.authKind = authKind
        self.accountID = accountID
        self.ownerAccountID = ownerAccountID
        self.profile = profile
    }
}

public enum ChannelAuthKind: String, Codable, Hashable, Sendable { case botToken, oauth }

public struct ChannelProfile: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let avatarURL: URL?
    public let workspaceID: String?
    public init(id: String, displayName: String, avatarURL: URL? = nil, workspaceID: String? = nil) {
        self.id = id; self.displayName = displayName; self.avatarURL = avatarURL; self.workspaceID = workspaceID
    }
}

public struct ChannelAddress: Codable, Hashable, Sendable {
    public let platform: String
    public let channelID: String
    public let threadID: String?
    public init(platform: String, channelID: String, threadID: String? = nil) {
        self.platform = platform
        self.channelID = channelID
        self.threadID = threadID
    }
}

public struct ChannelAttachment: Codable, Hashable, Sendable {
    public let blobID: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int64
    public init(blobID: String, filename: String, mimeType: String, byteCount: Int64) {
        self.blobID = blobID
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
    }
}

public struct ChannelReaction: Codable, Hashable, Sendable {
    public let emoji: String
    public let count: Int
    public let actorIDs: [String]
    public init(emoji: String, count: Int = 1, actorIDs: [String] = []) {
        self.emoji = emoji; self.count = count; self.actorIDs = actorIDs
    }
}

public struct ChannelEnvelope: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(connectionID.uuidString):\(externalEventID)" }
    public let connectionID: UUID
    public let externalEventID: String
    public let address: ChannelAddress
    public let senderID: String
    public let senderDisplayName: String
    public let text: String
    public let timestamp: Date
    public let cursor: String?
    public let attachments: [ChannelAttachment]
    public let reactions: [ChannelReaction]

    public init(
        connectionID: UUID, externalEventID: String, address: ChannelAddress,
        senderID: String, senderDisplayName: String, text: String,
        timestamp: Date = Date(), cursor: String? = nil,
        attachments: [ChannelAttachment] = [], reactions: [ChannelReaction] = []
    ) {
        self.connectionID = connectionID
        self.externalEventID = externalEventID
        self.address = address
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.text = text
        self.timestamp = timestamp
        self.cursor = cursor
        self.attachments = attachments
        self.reactions = reactions
    }
}

public struct ChannelOutbound: Codable, Hashable, Sendable {
    public let text: String
    public let attachments: [ChannelAttachment]
    public init(text: String, attachments: [ChannelAttachment] = []) {
        self.text = text
        self.attachments = attachments
    }
}

public enum ChannelDeliveryStatus: String, Codable, Hashable, Sendable {
    case queued, sending, retrying, delivered, deadLetter
}

public struct ChannelDelivery: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let address: ChannelAddress
    public let outbound: ChannelOutbound
    public let idempotencyKey: UUID
    public var status: ChannelDeliveryStatus
    public var attemptCount: Int
    public var nextAttemptAt: Date
    public var lastError: String?
    public let createdAt: Date
    public var deliveredAt: Date?
    public let authorization: ChannelDeliveryAuthorization?
    public let origin: ChannelDeliveryOrigin?

    public init(
        id: UUID = UUID(), connectionID: UUID, address: ChannelAddress,
        outbound: ChannelOutbound, idempotencyKey: UUID = UUID(),
        status: ChannelDeliveryStatus = .queued, attemptCount: Int = 0,
        nextAttemptAt: Date = Date(), lastError: String? = nil,
        createdAt: Date = Date(), deliveredAt: Date? = nil,
        authorization: ChannelDeliveryAuthorization? = nil,
        origin: ChannelDeliveryOrigin? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.address = address
        self.outbound = outbound
        self.idempotencyKey = idempotencyKey
        self.status = status
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.authorization = authorization
        self.origin = origin
    }
}

public struct ChannelFailureWake: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let connectionID: UUID
    public let deliveryID: UUID
    public let error: String
    public let createdAt: Date
    public let reason: ChannelFailureReason?
    public init(id: UUID = UUID(), connectionID: UUID, deliveryID: UUID, error: String, createdAt: Date = Date(),
                reason: ChannelFailureReason? = nil) {
        self.id = id
        self.connectionID = connectionID
        self.deliveryID = deliveryID
        self.error = error
        self.createdAt = createdAt
        self.reason = reason
    }
}

public enum ChannelServiceError: LocalizedError, Equatable, Sendable {
    case unknownConnector(String), unknownConnection(UUID), disabledConnection(UUID)
    case invalidConnection, invalidEnvelope, invalidOutbound, authExpired(String), unsupportedCapability(String)

    public var errorDescription: String? {
        switch self {
        case .unknownConnector(let id): "Unknown channel connector \(id)."
        case .unknownConnection(let id): "Unknown channel connection \(id)."
        case .disabledConnection(let id): "Channel connection \(id) is disabled."
        case .invalidConnection: "Channel connection metadata is invalid."
        case .invalidEnvelope: "Inbound channel event is invalid."
        case .invalidOutbound: "Outbound channel message is invalid."
        case .authExpired(let detail): "Channel authorization expired: \(detail)"
        case .unsupportedCapability(let value): "This channel does not support \(value)."
        }
    }
}
