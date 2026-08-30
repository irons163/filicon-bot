import Foundation

public enum ApprovalResolution: String, Codable, Sendable {
    case approve
    case deny
}

public struct PendingApproval: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let action: AutoReviewAction
    public let reason: String
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: String = UUID().uuidString.lowercased(),
        action: AutoReviewAction,
        reason: String,
        createdAt: Date = Date(),
        expiresAt: Date
    ) {
        self.id = id
        self.action = action
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var reviewID: String { id }
    public var fence: ApprovalFence { action.context.fence }
}

public enum PendingApprovalError: LocalizedError, Equatable, Sendable {
    case duplicate(String)
    case stale(String)
    case replay(String)
    case expired(String)
    case denied(String)
    case cancelled(String)
    case pendingLimit(agentID: String, maximum: Int)
    case fenceMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .duplicate(let id): "Approval \(id) is already pending."
        case .stale(let id): "Approval \(id) is stale or unknown."
        case .replay(let id): "Approval \(id) was already resolved."
        case .expired(let id): "Approval \(id) expired."
        case .denied(let id): "Approval \(id) was denied."
        case .cancelled(let id): "Approval \(id) was cancelled."
        case .pendingLimit(let agentID, let maximum): "Agent \(agentID) reached its pending approval limit of \(maximum)."
        case .fenceMismatch(let id): "Approval \(id) does not belong to the active account, generation, and run."
        }
    }
}

public actor PendingApprovalBroker {
    public typealias RegistrationHandler = @Sendable (PendingApproval) async -> Void

    private struct Entry {
        let request: PendingApproval
        let continuation: CheckedContinuation<Void, Error>
        let requiresExecutionClaim: Bool
    }

    public let maximumPendingPerAgent: Int
    private var pending: [String: Entry] = [:]
    private var completed: Set<String> = []
    private var approvedAwaitingExecution: [String: PendingApproval] = [:]
    private var activeFenceByAgent: [String: ApprovalFence] = [:]
    private var activeAccountID: String?

    public init(maximumPendingPerAgent: Int = 8) {
        self.maximumPendingPerAgent = max(1, maximumPendingPerAgent)
    }

    public var pendingApprovals: [PendingApproval] {
        pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    /// Changes execution identity for an agent and immediately cancels work
    /// belonging to an older account, run, or generation.
    public func activate(_ fence: ApprovalFence) {
        if activeAccountID != fence.accountID {
            let obsolete = Array(pending.keys) + Array(approvedAwaitingExecution.keys)
            for id in obsolete { invalidate(id: id) }
            activeFenceByAgent.removeAll()
            activeAccountID = fence.accountID
        }
        activeFenceByAgent[fence.agentID] = fence
        let obsolete = pending.values.compactMap { entry in
            entry.request.fence.agentID == fence.agentID && entry.request.fence != fence
                ? entry.request.id : nil
        }
        for id in obsolete { finish(id: id, error: PendingApprovalError.cancelled(id)) }
        invalidateApproved(except: fence, agentID: fence.agentID)
    }

    /// Use on account changes so operations from the previous signed-in
    /// identity cannot remain resumable, even if agent identifiers differ.
    public func transitionAccount(to accountID: String) {
        let obsolete = pending.values.compactMap {
            $0.request.fence.accountID != accountID ? $0.request.id : nil
        }
        for id in obsolete { finish(id: id, error: PendingApprovalError.cancelled(id)) }
        for id in approvedAwaitingExecution.values.compactMap({
            $0.fence.accountID != accountID ? $0.id : nil
        }) { invalidate(id: id) }
        activeFenceByAgent = activeFenceByAgent.filter { $0.value.accountID == accountID }
        activeAccountID = accountID
    }

    public func cancelAll(agentID: String) {
        let ids = pending.values.compactMap {
            $0.request.fence.agentID == agentID ? $0.request.id : nil
        }
        for id in ids { finish(id: id, error: PendingApprovalError.cancelled(id)) }
        for id in approvedAwaitingExecution.values.compactMap({
            $0.fence.agentID == agentID ? $0.id : nil
        }) { invalidate(id: id) }
        activeFenceByAgent.removeValue(forKey: agentID)
    }

    public func waitForApproval(
        _ request: PendingApproval,
        onRegistered: @escaping RegistrationHandler = { _ in }
    ) async throws {
        try await wait(request, requiresExecutionClaim: false, onRegistered: onRegistered)
    }

    /// Used by execution gates. An approval is not enough by itself: the
    /// approved request must still belong to the active fence when the waiter
    /// resumes and atomically consumes its single-use execution grant.
    func waitForApprovalToExecute(
        _ request: PendingApproval,
        onRegistered: @escaping RegistrationHandler = { _ in }
    ) async throws {
        try await wait(request, requiresExecutionClaim: true, onRegistered: onRegistered)
        try claimExecution(reviewID: request.id, fence: request.fence)
    }

    private func wait(
        _ request: PendingApproval,
        requiresExecutionClaim: Bool,
        onRegistered: @escaping RegistrationHandler
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    request,
                    continuation: continuation,
                    requiresExecutionClaim: requiresExecutionClaim
                )
                if pending[request.id] != nil {
                    Task { await onRegistered(request) }
                }
            }
        } onCancel: {
            Task { await self.cancel(reviewID: request.id, fence: request.fence) }
        }
    }

    public func resolve(
        reviewID: String,
        resolution: ApprovalResolution,
        fence: ApprovalFence
    ) throws {
        if completed.contains(reviewID) { throw PendingApprovalError.replay(reviewID) }
        guard let entry = pending[reviewID] else { throw PendingApprovalError.stale(reviewID) }
        guard entry.request.fence == fence,
              activeFenceByAgent[fence.agentID].map({ $0 == fence }) ?? true else {
            throw PendingApprovalError.fenceMismatch(reviewID)
        }
        guard entry.request.expiresAt > Date() else {
            finish(id: reviewID, error: PendingApprovalError.expired(reviewID))
            throw PendingApprovalError.expired(reviewID)
        }
        switch resolution {
        case .approve: finish(id: reviewID, error: nil)
        case .deny: finish(id: reviewID, error: PendingApprovalError.denied(reviewID))
        }
    }

    public func cancel(reviewID: String, fence: ApprovalFence) {
        guard let entry = pending[reviewID] else {
            if approvedAwaitingExecution[reviewID]?.fence == fence {
                invalidate(id: reviewID)
            }
            return
        }
        guard entry.request.fence == fence else { return }
        finish(id: reviewID, error: PendingApprovalError.cancelled(reviewID))
    }

    public func expire(now: Date = Date()) {
        let expired = pending.values.compactMap { $0.request.expiresAt <= now ? $0.request.id : nil }
        for id in expired { finish(id: id, error: PendingApprovalError.expired(id)) }
    }

    private func register(
        _ request: PendingApproval,
        continuation: CheckedContinuation<Void, Error>,
        requiresExecutionClaim: Bool
    ) {
        if completed.contains(request.id) {
            continuation.resume(throwing: PendingApprovalError.replay(request.id)); return
        }
        guard pending[request.id] == nil else {
            continuation.resume(throwing: PendingApprovalError.duplicate(request.id)); return
        }
        guard request.expiresAt > Date() else {
            rememberCompleted(request.id)
            continuation.resume(throwing: PendingApprovalError.expired(request.id)); return
        }
        if let accountID = activeAccountID, accountID != request.fence.accountID {
            continuation.resume(throwing: PendingApprovalError.fenceMismatch(request.id)); return
        }
        if let active = activeFenceByAgent[request.fence.agentID], active != request.fence {
            continuation.resume(throwing: PendingApprovalError.fenceMismatch(request.id)); return
        }
        let count = pending.values.lazy.filter { $0.request.fence.agentID == request.fence.agentID }.count
        guard count < maximumPendingPerAgent else {
            continuation.resume(throwing: PendingApprovalError.pendingLimit(
                agentID: request.fence.agentID,
                maximum: maximumPendingPerAgent
            )); return
        }
        activeAccountID = request.fence.accountID
        if activeFenceByAgent[request.fence.agentID] == nil {
            activeFenceByAgent[request.fence.agentID] = request.fence
        }
        pending[request.id] = Entry(
            request: request,
            continuation: continuation,
            requiresExecutionClaim: requiresExecutionClaim
        )
        let delay = max(0, request.expiresAt.timeIntervalSinceNow)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.expire()
        }
    }

    private func finish(id: String, error: Error?) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        rememberCompleted(id)
        if let error {
            entry.continuation.resume(throwing: error)
        } else {
            if entry.requiresExecutionClaim {
                approvedAwaitingExecution[id] = entry.request
            }
            entry.continuation.resume()
        }
    }

    private func rememberCompleted(_ id: String) {
        completed.insert(id)
    }

    private func claimExecution(reviewID: String, fence: ApprovalFence) throws {
        guard let request = approvedAwaitingExecution.removeValue(forKey: reviewID) else {
            throw PendingApprovalError.cancelled(reviewID)
        }
        guard request.fence == fence,
              activeAccountID == fence.accountID,
              activeFenceByAgent[fence.agentID] == fence else {
            throw PendingApprovalError.fenceMismatch(reviewID)
        }
        guard request.expiresAt > Date() else {
            throw PendingApprovalError.expired(reviewID)
        }
    }

    private func invalidateApproved(except fence: ApprovalFence, agentID: String) {
        for id in approvedAwaitingExecution.values.compactMap({ request in
            request.fence.agentID == agentID && request.fence != fence ? request.id : nil
        }) { invalidate(id: id) }
    }

    private func invalidate(id: String) {
        if pending[id] != nil {
            finish(id: id, error: PendingApprovalError.cancelled(id))
        } else {
            approvedAwaitingExecution.removeValue(forKey: id)
        }
    }
}
