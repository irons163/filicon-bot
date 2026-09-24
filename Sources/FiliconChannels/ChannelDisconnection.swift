import Foundation

/// Created only by ChannelService from its current store, never from model data.
/// Public fields are safe approval metadata; credentials and message bodies stay private.
public struct ChannelDisconnection: Sendable, Equatable {
    public let agentID: UUID
    public var ownerAccountID: String { connection.authorizationAccountID }
    public let connectionID: UUID
    public let platform: String
    public let displayName: String
    public let accountLabel: String
    public let enabled: Bool
    public let inboundCount: Int
    public let deliveryCount: Int
    public let pendingDeliveryCount: Int
    public let failureCount: Int
    let revision: UUID
    let connection: ChannelConnection

    init(agentID: UUID, connection: ChannelConnection, revision: UUID,
         inboundCount: Int, deliveryCount: Int, pendingDeliveryCount: Int, failureCount: Int) {
        self.agentID = agentID; self.connection = connection; self.revision = revision
        connectionID = connection.id; platform = connection.connectorID
        displayName = connection.displayName; accountLabel = connection.accountLabel; enabled = connection.enabled
        self.inboundCount = inboundCount; self.deliveryCount = deliveryCount
        self.pendingDeliveryCount = pendingDeliveryCount; self.failureCount = failureCount
    }
}

public enum ChannelDisconnectionError: String, LocalizedError, Sendable {
    case invalid = "Channel disconnection requires only target channel, action disconnect and platform slack or discord."
    case unavailable = "No channel connection owned by this agent is available for that platform."
    case ambiguous = "This agent has multiple connections on that platform. Choose the exact connection in Channels instead."
    case stale = "Channel data changed while awaiting approval. Request approval again."
    public var errorDescription: String? { rawValue }
}

/// Stop/account switches revoke pending proposals through the synchronous save.
public final class ChannelDisconnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var receipts: [ChannelDisconnection] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committed(_ change: ChannelDisconnection) -> Bool { lock.withLock { receipts.contains(change) } }
    func commit(_ change: ChannelDisconnection, operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
            receipts.append(change)
        }
    }
}
