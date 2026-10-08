import Foundation

public enum AgentExecutionLane: Sendable {
    /// Default to protecting work unless the host explicitly classifies it.
    case user, background
}

public struct AgentExecutionSuperseded: LocalizedError, Sendable {
    let groupMemberAttempt: GroupMemberExecutionAttempt?
    public init() { groupMemberAttempt = nil }
    init(groupMemberAttempt: GroupMemberExecutionAttempt?) { self.groupMemberAttempt = groupMemberAttempt }
    public var errorDescription: String? {
        "Interrupted by higher-priority work."
    }
}

/// One execution lane per agent in a running app. Different origins retain
/// separate history and permissions; sharing a lane shares neither of those.
/// Cancellation never releases an active lane before its operation unwinds.
public actor AgentExecutionScheduler {
    public struct Snapshot: Equatable, Sendable {
        public let isActive: Bool
        public let queuedCount: Int
    }

    private struct Submission {
        let token: UUID
        let lane: AgentExecutionLane
        let priority: Bool
        let groupMemberAttempt: GroupMemberExecutionAttempt?
        let run: @Sendable () async -> Void
        let reject: @Sendable () -> Void
    }
    private struct Active {
        let token: UUID
        let task: Task<Void, Never>
        let lane: AgentExecutionLane
        let groupMemberAttempt: GroupMemberExecutionAttempt?
        var superseded = false
    }
    private var active: [UUID: Active] = [:]
    private var pending: [UUID: [Submission]] = [:]
    private let makeID: @Sendable () -> UUID

    public init(makeID: @escaping @Sendable () -> UUID = { UUID() }) { self.makeID = makeID }

    public func withExclusiveAccess<Value: Sendable>(
        agentID: UUID,
        lane: AgentExecutionLane = .user,
        priority: Bool = false,
        groupMemberAttempt: GroupMemberExecutionAttempt? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if let groupMemberAttempt {
            guard groupMemberAttempt.agentID == agentID else { throw CancellationError() }
            try await groupMemberAttempt.validate()
        }
        let token = makeID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let submission = Submission(token: token, lane: lane, priority: priority, groupMemberAttempt: groupMemberAttempt, run: {
                    do {
                        try Task.checkCancellation()
                        try await groupMemberAttempt?.beginExecution()
                        let result = try await operation()
                        try Task.checkCancellation()
                        continuation.resume(returning: result)
                    } catch {
                        let superseded = await self.supersession(agentID: agentID, token: token)
                        if let superseded { continuation.resume(throwing: superseded) }
                        else { continuation.resume(throwing: error) }
                    }
                }, reject: { continuation.resume(throwing: CancellationError()) })
                if priority {
                    // Never jump ahead of queued user work or older priority
                    // messages. Only ordinary background entries are bypassed.
                    let index = pending[agentID]?.lastIndex(where: { $0.lane == .user || $0.priority }).map { $0 + 1 } ?? 0
                    pending[agentID, default: []].insert(submission, at: index)
                    if active[agentID]?.lane == .background, active[agentID]?.task.isCancelled == false {
                        active[agentID]?.superseded = true
                        active[agentID]?.groupMemberAttempt?.close()
                        active[agentID]?.task.cancel()
                    }
                } else { pending[agentID, default: []].append(submission) }
                startNext(agentID: agentID)
            }
        } onCancel: {
            Task { await self.cancel(agentID: agentID, token: token) }
        }
    }

    public func snapshot(agentID: UUID) -> Snapshot {
        .init(isActive: active[agentID] != nil, queuedCount: pending[agentID]?.count ?? 0)
    }

    /// Account transitions cancel queued and active work, but do not unlock an
    /// active operation early. A new account must wait for that work to stop.
    public func cancelAll() {
        let queued = pending.values.flatMap { $0 }
        pending.removeAll()
        for submission in queued { submission.reject() }
        for id in Array(active.keys) {
            active[id]?.superseded = false
            active[id]?.groupMemberAttempt?.close()
            active[id]?.task.cancel()
        }
    }

    private func startNext(agentID: UUID) {
        guard active[agentID] == nil, var queue = pending[agentID], !queue.isEmpty else { return }
        let submission = queue.removeFirst()
        pending[agentID] = queue.isEmpty ? nil : queue
        let task = Task {
            await submission.run()
            finish(agentID: agentID, token: submission.token)
        }
        active[agentID] = .init(token: submission.token, task: task, lane: submission.lane,
            groupMemberAttempt: submission.groupMemberAttempt)
    }

    private func supersession(agentID: UUID, token: UUID) -> AgentExecutionSuperseded? {
        guard let current = active[agentID], current.token == token, current.superseded else { return nil }
        return .init(groupMemberAttempt: current.groupMemberAttempt)
    }

    private func finish(agentID: UUID, token: UUID) {
        guard active[agentID]?.token == token else { return }
        active[agentID] = nil
        startNext(agentID: agentID)
    }

    private func cancel(agentID: UUID, token: UUID) {
        if let running = active[agentID], running.token == token {
            active[agentID]?.superseded = false
            running.groupMemberAttempt?.close()
            running.task.cancel()
        } else if let index = pending[agentID]?.firstIndex(where: { $0.token == token }),
                  let submission = pending[agentID]?.remove(at: index) {
            if pending[agentID]?.isEmpty == true { pending[agentID] = nil }
            submission.reject()
        }
    }
}
