import Foundation

public actor LocalRequestGuard {
    private let generation: UUID
    private var consumedRequests: Set<UUID> = []
    private var consumedNonces: Set<UUID> = []
    private var consumedApprovals: Set<UUID> = []
    private var minimumDirectionEpoch: UInt64 = 0

    public init(generation: UUID) { self.generation = generation }

    public func consume(_ scope: LocalRequestScope, now: Date = Date()) throws {
        guard scope.generation == generation else { throw LocalToolError.staleGeneration }
        guard scope.expiresAt > now else { throw LocalToolError.expiredRequest }
        guard !scope.toolCallID.isEmpty else { throw LocalToolError.invalidRequest("toolCallID is empty") }
        guard consumedRequests.insert(scope.requestID).inserted,
              consumedNonces.insert(scope.nonce).inserted else { throw LocalToolError.replayedRequest }
        if let receipt = scope.permissionReceipt {
            guard receipt.expiresAt > now else { throw LocalToolError.expiredRequest }
            guard receipt.directionEpoch >= minimumDirectionEpoch else { throw LocalToolError.expiredRequest }
            guard consumedApprovals.insert(receipt.approvalID).inserted else { throw LocalToolError.replayedRequest }
        }
    }

    /// Called when a new user direction retires prior one-time approvals.
    public func advanceDirectionEpoch(to epoch: UInt64) {
        if epoch > minimumDirectionEpoch { minimumDirectionEpoch = epoch }
    }
}
