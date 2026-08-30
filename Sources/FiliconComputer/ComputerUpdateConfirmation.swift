import Foundation

public enum ComputerUpdatePhase: String, Codable, Sendable, Equatable {
    case idle
    case pending
    case settled
    case blocked
    case failed
    case cancelled
}
public enum ComputerUpdateAction: Sendable, Equatable {
    case updateWhenReady
    case updateAnyway
}

public struct ComputerUpdateContext: Sendable, Equatable {
    public var agentID: String?
    public var updateAvailable: Bool
    public var isComputerBusy: Bool
    public var canUpdate: Bool

    public init(agentID: String?, updateAvailable: Bool, isComputerBusy: Bool, canUpdate: Bool = true) {
        self.agentID = agentID
        self.updateAvailable = updateAvailable
        self.isComputerBusy = isComputerBusy
        self.canUpdate = canUpdate
    }
}

public enum ComputerUpdateBackendResponse: Sendable, Equatable {
    case started(operationID: String)
    case startedUntrackable
    case rejected(reason: String)
}

public protocol ComputerUpdateBackend: Sendable {
    func startUpdate(agentID: String, force: Bool) async throws -> ComputerUpdateBackendResponse
}

public struct ComputerUpdateSnapshot: Sendable, Equatable {
    public var phase: ComputerUpdatePhase
    public var context: ComputerUpdateContext
    public var message: String?
    public var operationID: String?
    public var requiresRestart: Bool

    public init(
        phase: ComputerUpdatePhase = .idle,
        context: ComputerUpdateContext,
        message: String? = nil,
        operationID: String? = nil,
        requiresRestart: Bool = false
    ) {
        self.phase = phase
        self.context = context
        self.message = message
        self.operationID = operationID
        self.requiresRestart = requiresRestart
    }
}

public enum ComputerUpdateConfirmationResult: Sendable, Equatable {
    case started(operationID: String)
    case blockedRequiresRestart
    case rejected(reason: String)
    case failed(message: String)
    case cancelled
    case unavailable
    case stale
}

public actor ComputerUpdateConfirmation {
    public static let untrackableMessage = "The computer update started, but its progress cannot be tracked. Restart Filicon after the computer is available again."

    private let backend: any ComputerUpdateBackend
    private var snapshot: ComputerUpdateSnapshot
    private var generation = 0
    private var pendingTask: Task<ComputerUpdateBackendResponse, Error>?
    private var continuations: [UUID: AsyncStream<ComputerUpdateSnapshot>.Continuation] = [:]

    public init(context: ComputerUpdateContext, backend: any ComputerUpdateBackend) {
        self.backend = backend
        self.snapshot = ComputerUpdateSnapshot(context: context)
    }

    public func currentSnapshot() -> ComputerUpdateSnapshot { snapshot }

    public func statuses() -> AsyncStream<ComputerUpdateSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func setContext(_ context: ComputerUpdateContext) {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        snapshot = ComputerUpdateSnapshot(context: context)
        publish()
    }

    @discardableResult
    public func confirm(_ action: ComputerUpdateAction = .updateWhenReady) async -> ComputerUpdateConfirmationResult {
        guard pendingTask == nil,
              snapshot.context.canUpdate,
              snapshot.context.updateAvailable,
              let agentID = snapshot.context.agentID else { return .unavailable }
        if snapshot.context.isComputerBusy, action != .updateAnyway {
            snapshot.phase = .blocked
            snapshot.message = "The computer is busy. Choose Update anyway to interrupt active work."
            publish()
            return .unavailable
        }

        generation &+= 1
        let attempt = generation
        snapshot.phase = .pending
        snapshot.message = nil
        snapshot.operationID = nil
        snapshot.requiresRestart = false
        publish()
        let backend = self.backend
        let task = Task { try await backend.startUpdate(agentID: agentID, force: action == .updateAnyway) }
        pendingTask = task
        do {
            let response = try await task.value
            guard generation == attempt else { return .stale }
            pendingTask = nil
            switch response {
            case .started(let operationID):
                snapshot.phase = .settled
                snapshot.operationID = operationID
                publish()
                return .started(operationID: operationID)
            case .startedUntrackable:
                snapshot.phase = .blocked
                snapshot.message = Self.untrackableMessage
                snapshot.requiresRestart = true
                publish()
                return .blockedRequiresRestart
            case .rejected(let reason):
                snapshot.phase = .blocked
                snapshot.message = reason
                publish()
                return .rejected(reason: reason)
            }
        } catch is CancellationError {
            guard generation == attempt else { return .stale }
            pendingTask = nil
            snapshot.phase = .cancelled
            snapshot.message = nil
            publish()
            return .cancelled
        } catch {
            guard generation == attempt else { return .stale }
            pendingTask = nil
            let message = String(describing: error)
            snapshot.phase = .failed
            snapshot.message = message
            publish()
            return .failed(message: message)
        }
    }

    public func retry(_ action: ComputerUpdateAction = .updateWhenReady) async -> ComputerUpdateConfirmationResult {
        guard snapshot.phase == .failed else { return .unavailable }
        return await confirm(action)
    }

    @discardableResult
    public func cancel() -> ComputerUpdateConfirmationResult {
        generation &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        snapshot.phase = .cancelled
        snapshot.message = nil
        publish()
        return .cancelled
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
