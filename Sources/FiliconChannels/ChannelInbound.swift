import Foundation

/// Credential-free evidence of the owner/configuration at acceptance. An
/// imported envelope alone is not a background execution or delivery grant.
public struct ChannelInboundReceipt: Codable, Hashable, Sendable {
    public let envelopeID: String
    public let connectionID: UUID
    public let accountID: String
    public let agentID: UUID
    public let configurationRevision: UUID

    func isConsistent(with envelope: ChannelEnvelope) -> Bool {
        envelopeID == envelope.id && connectionID == envelope.connectionID
            && !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && accountID.utf8.count <= 256
            && !accountID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            && ["slack", "discord"].contains(envelope.address.platform)
    }
}

/// Durable admission bookkeeping, not permission. Restored running rows are
/// interrupted; model output or external delivery may already have happened.
public struct ChannelInboundRun: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Hashable, Sendable { case running, completed, failed, cancelled, interrupted }
    public let id: UUID
    public let receipt: ChannelInboundReceipt
    public let conversationID: UUID
    public let messageID: UUID
    public let startedAt: Date
    public internal(set) var status: Status
    public internal(set) var finishedAt: Date?
}

/// Process-local host fence. Configuration writes retire it synchronously,
/// including remove/recreate (ABA). The callback closes the host's run scope;
/// it runs outside this lock to avoid inverse repository/publication lock order.
public final class ChannelInboundAdmission: @unchecked Sendable {
    public let receipt: ChannelInboundReceipt
    public let envelope: ChannelEnvelope
    let issuerID: UUID
    private let lock = NSLock()
    private var active = true
    private let invalidate: @Sendable () -> Void

    init(receipt: ChannelInboundReceipt, envelope: ChannelEnvelope, issuerID: UUID,
         invalidate: @escaping @Sendable () -> Void) {
        self.receipt = receipt; self.envelope = envelope; self.issuerID = issuerID; self.invalidate = invalidate
    }
    public var isActive: Bool { lock.withLock { active } }
    public func check() throws {
        try withCurrent { try Task.checkCancellation() }
    }
    public func withCurrent<Result>(_ operation: () throws -> Result) throws -> Result {
        try lock.withLock {
            guard active else { throw CancellationError() }
            return try operation()
        }
    }
    public func close() {
        let changed = lock.withLock { let previous = active; active = false; return previous }
        if changed { invalidate() }
    }
}

struct WeakChannelInboundAdmission { weak var value: ChannelInboundAdmission? }
