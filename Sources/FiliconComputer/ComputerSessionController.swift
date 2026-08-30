import Foundation

public enum ComputerSessionPhase: String, Codable, Sendable, Equatable {
    case off
    case starting
    case sleeping
    case local
    case running
    case pulling
    case crashedOut
}
public enum ComputerStatusReadState: String, Codable, Sendable, Equatable {
    case unknown
    case known
    case unavailable
}

public enum ComputerBackendStatus: Sendable, Equatable {
    case off
    case hibernated
    case running(vncURL: URL?)
    case pulling(percent: Double?)
}

public struct ComputerSessionSnapshot: Sendable, Equatable {
    public var phase: ComputerSessionPhase
    public var readState: ComputerStatusReadState
    public var pullPercent: Double?
    public var vncURL: URL?
    public var crashCount: Int
    public var lastError: String?

    public init(
        phase: ComputerSessionPhase = .off,
        readState: ComputerStatusReadState = .unknown,
        pullPercent: Double? = nil,
        vncURL: URL? = nil,
        crashCount: Int = 0,
        lastError: String? = nil
    ) {
        self.phase = phase
        self.readState = readState
        self.pullPercent = pullPercent
        self.vncURL = vncURL
        self.crashCount = crashCount
        self.lastError = lastError
    }
}

public protocol ComputerSessionBackend: Sendable {
    func status(for agentID: String) async throws -> ComputerBackendStatus
    func ensure(for agentID: String) async throws -> ComputerBackendStatus
}

public enum ComputerSessionError: Error, Sendable, Equatable {
    case statusTimedOut
}

private enum ComputerStatusRaceResult: Sendable {
    case value(ComputerBackendStatus)
    case failure(String)
    case timeout
}

public actor ComputerSessionController {
    public static let statusTimeoutMilliseconds: Int64 = 15_000
    public static let crashWindowMilliseconds: Int64 = 60_000
    public static let crashLimit = 3

    private let backend: any ComputerSessionBackend
    private let clock: any ComputerClock
    private let timeoutMilliseconds: Int64
    private var snapshot = ComputerSessionSnapshot()
    private var basePhase: ComputerSessionPhase = .off
    private var crashTimes: [Int64] = []
    private var generation = 0
    private var continuations: [UUID: AsyncStream<ComputerSessionSnapshot>.Continuation] = [:]

    public init(
        backend: any ComputerSessionBackend,
        clock: any ComputerClock = SystemComputerClock(),
        timeoutMilliseconds: Int64 = ComputerSessionController.statusTimeoutMilliseconds
    ) {
        self.backend = backend
        self.clock = clock
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    public func currentSnapshot() -> ComputerSessionSnapshot { snapshot }

    public func statuses() -> AsyncStream<ComputerSessionSnapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    @discardableResult
    public func refresh(agentID: String) async -> ComputerSessionSnapshot {
        await perform(agentID: agentID, ensuring: false)
    }

    @discardableResult
    public func ensure(agentID: String) async -> ComputerSessionSnapshot {
        basePhase = .starting
        if snapshot.phase != .crashedOut {
            snapshot.phase = .starting
            snapshot.lastError = nil
            publish()
        }
        return await perform(agentID: agentID, ensuring: true)
    }

    public func ingest(_ status: ComputerBackendStatus) {
        apply(status)
    }

    /// Mirrors the source behavior: crash-out occurs on the fourth crash in a
    /// rolling 60 second window, and visibility is the explicit recovery edge.
    public func noteRendererCrash() async {
        let now = await clock.nowMilliseconds()
        crashTimes.removeAll { now - $0 >= Self.crashWindowMilliseconds }
        crashTimes.append(now)
        snapshot.crashCount = crashTimes.count
        if crashTimes.count > Self.crashLimit {
            snapshot.phase = .crashedOut
        }
        publish()
    }

    public func viewerBecameVisible() {
        guard snapshot.phase == .crashedOut else { return }
        crashTimes.removeAll()
        snapshot.crashCount = 0
        snapshot.phase = basePhase
        publish()
    }

    public func reset() {
        generation &+= 1
        crashTimes.removeAll()
        basePhase = .off
        snapshot = ComputerSessionSnapshot()
        publish()
    }

    private func perform(agentID: String, ensuring: Bool) async -> ComputerSessionSnapshot {
        generation &+= 1
        let attempt = generation
        let backend = self.backend
        let clock = self.clock
        let timeout = timeoutMilliseconds

        let result = await withTaskGroup(of: ComputerStatusRaceResult.self, returning: ComputerStatusRaceResult.self) { group in
            group.addTask {
                do {
                    let value = try await (ensuring ? backend.ensure(for: agentID) : backend.status(for: agentID))
                    return .value(value)
                } catch {
                    return .failure(String(describing: error))
                }
            }
            group.addTask {
                do {
                    try await clock.sleep(milliseconds: timeout)
                    return .timeout
                } catch {
                    return .failure(String(describing: error))
                }
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        guard generation == attempt else { return snapshot }
        switch result {
        case .value(let status):
            apply(status)
        case .failure(let message):
            snapshot.readState = .unavailable
            snapshot.lastError = message
            if ensuring { basePhase = .off }
            if snapshot.phase != .crashedOut { snapshot.phase = basePhase }
            publish()
        case .timeout:
            snapshot.readState = .unavailable
            snapshot.lastError = String(describing: ComputerSessionError.statusTimedOut)
            if ensuring { basePhase = .off }
            if snapshot.phase != .crashedOut { snapshot.phase = basePhase }
            publish()
        }
        return snapshot
    }

    private func apply(_ status: ComputerBackendStatus) {
        snapshot.readState = .known
        snapshot.lastError = nil
        switch status {
        case .off:
            basePhase = .off
            snapshot.pullPercent = nil
            snapshot.vncURL = nil
        case .hibernated:
            basePhase = .sleeping
            snapshot.pullPercent = nil
            snapshot.vncURL = nil
        case .running(let url):
            basePhase = url == nil ? .local : .running
            snapshot.pullPercent = nil
            snapshot.vncURL = url
        case .pulling(let percent):
            basePhase = .pulling
            snapshot.pullPercent = percent.map { min(100, max(0, $0)) }
            snapshot.vncURL = nil
        }
        if snapshot.phase != .crashedOut { snapshot.phase = basePhase }
        publish()
    }

    private func publish() {
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
