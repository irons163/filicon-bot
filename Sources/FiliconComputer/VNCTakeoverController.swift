import Foundation

public enum VNCControlOwner: String, Codable, Sendable { case agent, user }
public struct VNCTakeoverLease: Codable, Equatable, Sendable {
    public let controllerID: String
    public let generation: UInt64
    public let deadlineMilliseconds: Int64
}
public struct VNCControlSnapshot: Codable, Equatable, Sendable {
    public let owner: VNCControlOwner
    public let lease: VNCTakeoverLease?
    public let userPresent: Bool
}
public enum VNCTakeoverError: Error, Equatable, Sendable { case alreadyControlled, staleGeneration, expired, replay, invalidDeadline }

/// Single-controller lease state machine. Explicit user presence always wins
/// and invokes the handback callback used to cancel remote input/WebAuthn.
public actor VNCTakeoverController {
    public static let maximumLeaseMilliseconds: Int64 = 30_000
    private let now: @Sendable () -> Int64
    private let handback: @Sendable (_ priorControllerID: String, _ generation: UInt64) async -> Void
    private var owner: VNCControlOwner = .user
    private var lease: VNCTakeoverLease?
    private var userPresent = false
    private var generation: UInt64 = 0
    private var consumed: Set<UUID> = []

    public init(now: @escaping @Sendable () -> Int64, handback: @escaping @Sendable (String, UInt64) async -> Void) {
        self.now = now; self.handback = handback
    }

    public func snapshot() async -> VNCControlSnapshot {
        await expireIfNeeded()
        return .init(owner: owner, lease: lease, userPresent: userPresent)
    }

    public func requestTakeover(controllerID: String, deadlineMilliseconds: Int64, requestID: UUID) async throws -> VNCTakeoverLease {
        try consume(requestID)
        await expireIfNeeded()
        guard !controllerID.isEmpty, validDeadline(deadlineMilliseconds) else { throw VNCTakeoverError.invalidDeadline }
        guard !userPresent else { throw VNCTakeoverError.alreadyControlled }
        if let lease, lease.controllerID != controllerID { throw VNCTakeoverError.alreadyControlled }
        guard generation < .max else { throw VNCTakeoverError.staleGeneration }
        generation += 1
        let newLease = VNCTakeoverLease(controllerID: controllerID, generation: generation, deadlineMilliseconds: deadlineMilliseconds)
        lease = newLease; owner = .agent
        return newLease
    }

    public func heartbeat(controllerID: String, generation: UInt64, deadlineMilliseconds: Int64, requestID: UUID) async throws -> VNCTakeoverLease {
        try consume(requestID)
        await expireIfNeeded()
        guard let lease, lease.controllerID == controllerID else { throw VNCTakeoverError.alreadyControlled }
        guard lease.generation == generation else { throw VNCTakeoverError.staleGeneration }
        guard validDeadline(deadlineMilliseconds) else { throw VNCTakeoverError.invalidDeadline }
        let renewed = VNCTakeoverLease(controllerID: controllerID, generation: generation, deadlineMilliseconds: deadlineMilliseconds)
        self.lease = renewed
        return renewed
    }

    public func cancel(controllerID: String, generation: UInt64, requestID: UUID) async throws {
        try consume(requestID)
        guard let lease, lease.controllerID == controllerID else { return }
        guard lease.generation == generation else { throw VNCTakeoverError.staleGeneration }
        await transitionToUser(prior: lease)
    }

    public func reportUserPresence(_ present: Bool) async {
        userPresent = present
        if present, let lease { await transitionToUser(prior: lease) }
    }

    public func tick() async { await expireIfNeeded() }

    private func expireIfNeeded() async {
        if let lease, lease.deadlineMilliseconds <= now() { await transitionToUser(prior: lease) }
    }

    private func transitionToUser(prior: VNCTakeoverLease) async {
        guard lease == prior else { return }
        lease = nil; owner = .user
        await handback(prior.controllerID, prior.generation)
    }

    private func consume(_ id: UUID) throws {
        guard consumed.insert(id).inserted else { throw VNCTakeoverError.replay }
        if consumed.count > 4_096 { consumed.removeAll(keepingCapacity: true); consumed.insert(id) }
    }

    private func validDeadline(_ deadline: Int64) -> Bool {
        let instant = now()
        let (maximum, overflow) = instant.addingReportingOverflow(Self.maximumLeaseMilliseconds)
        return deadline > instant && (overflow || deadline <= maximum)
    }
}
