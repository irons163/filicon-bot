import Foundation

/// An exact host-selected destination and payload. Only ChannelService can
/// issue a proposal; callers must review the public fields before committing.
/// A proposal is not consent, a queued receipt, or proof of remote delivery.
public struct ChannelPublication: Sendable, Equatable, Encodable, CustomReflectable {
    public let agentID: UUID
    public var ownerAccountID: String { connection.authorizationAccountID }
    public let connectionID: UUID
    public let displayName: String
    public let address: ChannelAddress
    public let outbound: ChannelOutbound
    let issuerID: UUID
    let connection: ChannelConnection
    let configurationRevision: UUID
    let processRevision: UUID?
    let connectorRevision: UUID
    let connectorDescriptor: ChannelConnectorDescriptor

    init(agentID: UUID, connection: ChannelConnection, address: ChannelAddress,
         outbound: ChannelOutbound, issuerID: UUID, configurationRevision: UUID, processRevision: UUID?,
         connectorRevision: UUID, connectorDescriptor: ChannelConnectorDescriptor) {
        self.agentID = agentID; self.connection = Self.configuration(connection)
        connectionID = connection.id; displayName = connection.displayName
        self.address = address; self.outbound = outbound; self.issuerID = issuerID
        self.configurationRevision = configurationRevision; self.processRevision = processRevision
        self.connectorRevision = connectorRevision
        self.connectorDescriptor = connectorDescriptor
    }
    static func configuration(_ connection: ChannelConnection) -> ChannelConnection {
        var value = connection
        value.cursor = nil
        value.lastActivityAt = nil
        return value
    }

    // Never put the credential reference, remote profile or internal fence in
    // approval JSON or ordinary debug mirrors.
    private enum CodingKeys: CodingKey { case agentID, ownerAccountID, connectionID, displayName, address, outbound }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(agentID, forKey: .agentID)
        try values.encode(ownerAccountID, forKey: .ownerAccountID)
        try values.encode(connectionID, forKey: .connectionID)
        try values.encode(displayName, forKey: .displayName)
        try values.encode(address, forKey: .address)
        try values.encode(outbound, forKey: .outbound)
    }
    public var customMirror: Mirror {
        Mirror(self, children: ["agentID": agentID, "ownerAccountID": ownerAccountID,
            "connectionID": connectionID, "displayName": displayName,
            "address": address, "outbound": outbound])
    }
}

/// The durable, credential-free binding checked before each transport attempt.
/// Legacy human queue entries have no binding and retain their original policy.
public struct ChannelDeliveryAuthorization: Codable, Hashable, Sendable {
    public let ownerAccountID: String
    public let agentID: UUID
    public let configurationRevision: UUID
    init(ownerAccountID: String, agentID: UUID, configurationRevision: UUID) {
        self.ownerAccountID = ownerAccountID; self.agentID = agentID
        self.configurationRevision = configurationRevision
    }
}

public enum ChannelPublicationError: String, LocalizedError, Equatable, Sendable {
    case invalid = "The channel destination or publication is invalid."
    case unavailable = "No enabled channel connection owned by this agent and account is available for that platform."
    case ambiguous = "This agent has multiple enabled connections on that platform. Choose the exact connection in Channels instead."
    case stale = "The reviewed channel connection changed. Nothing new was queued; request approval again."
    case idempotencyConflict = "That delivery identity belongs to a different channel publication."
    public var errorDescription: String? { rawValue }
}

/// The host closes this synchronous fence on Stop, account or dispatch changes.
/// Closure cannot race the final durable enqueue. Already queued messages are
/// not recalled; their current status must be read from ChannelService.
public final class ChannelPublicationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private let parent: ChannelPublicationLifetime?
    private var active = true
    private var receipts: [UUID: (ChannelPublication, ChannelDeliveryOrigin?, ChannelDelivery)] = [:]
    /// Child turn closure leaves sibling turns available; request closure fences
    /// every child commit under the same parent-first lock order.
    public init(parent: ChannelPublicationLifetime? = nil) { self.parent = parent }
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try parent?.check()
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
        }
    }
    public func queuedReceipt(idempotencyKey: UUID) -> ChannelDelivery? {
        lock.withLock { receipts[idempotencyKey]?.2 }
    }
    func commit(_ proposal: ChannelPublication, origin: ChannelDeliveryOrigin?, idempotencyKey: UUID,
                operation: () throws -> ChannelDelivery) throws -> ChannelDelivery {
        try whileActive {
            if let receipt = receipts[idempotencyKey] {
                guard receipt.0 == proposal, receipt.1 == origin else { throw ChannelPublicationError.idempotencyConflict }
                return receipt.2
            }
            let receipt = try operation()
            receipts[idempotencyKey] = (proposal, origin, receipt)
            return receipt
        }
    }

    private func whileActive<T>(_ operation: () throws -> T) throws -> T {
        if let parent {
            return try parent.whileActive { try whileLocallyActive(operation) }
        }
        return try whileLocallyActive(operation)
    }

    private func whileLocallyActive<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            return try operation()
        }
    }
}
