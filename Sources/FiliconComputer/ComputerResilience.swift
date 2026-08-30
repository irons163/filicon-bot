import Foundation

public enum DiskPressureLevel: String, Codable, Sendable, Comparable {
    case healthy, soft, hard
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let ranks: [Self: Int] = [.healthy: 0, .soft: 1, .hard: 2]
        return ranks[lhs]! < ranks[rhs]!
    }
}

public struct DiskVolumeSnapshot: Sendable, Equatable {
    public var deviceID: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public init(deviceID: String, totalBytes: Int64, availableBytes: Int64) { self.deviceID = deviceID; self.totalBytes = totalBytes; self.availableBytes = availableBytes }
}

public struct DiskPressureClassifier: Sendable {
    public static let gib: Int64 = 1_073_741_824
    public init() {}
    public func classify(_ sample: DiskVolumeSnapshot, previous: DiskPressureLevel = .healthy) -> DiskPressureLevel {
        guard sample.totalBytes > 0 else { return .healthy }
        let ratio = Double(sample.availableBytes) / Double(sample.totalBytes)
        if sample.availableBytes <= 2 * Self.gib || ratio <= 0.05 { return .hard }
        if previous == .hard && (sample.availableBytes <= 3 * Self.gib || ratio <= 0.08) { return .hard }
        if sample.availableBytes <= 8 * Self.gib || ratio <= 0.15 { return .soft }
        if previous == .soft && (sample.availableBytes <= 10 * Self.gib || ratio <= 0.20) { return .soft }
        return .healthy
    }
}

public actor DiskPressureMonitor {
    public static let reminderIntervalMilliseconds: Int64 = 5 * 60_000
    private let classifier = DiskPressureClassifier()
    private var states: [String: DiskPressureLevel] = [:]
    private var lastReminder: [String: Int64] = [:]
    public init() {}
    public func observe(_ sample: DiskVolumeSnapshot, nowMilliseconds: Int64) -> (level: DiskPressureLevel, shouldRemind: Bool) {
        let previous = states[sample.deviceID] ?? .healthy
        let next = classifier.classify(sample, previous: previous)
        let transition = next != previous
        let heartbeat: Bool
        if let last = lastReminder[sample.deviceID] {
            heartbeat = next != .healthy && nowMilliseconds >= last && nowMilliseconds - last >= Self.reminderIntervalMilliseconds
        } else {
            heartbeat = next != .healthy
        }
        let remind = next != .healthy && (transition || heartbeat)
        states[sample.deviceID] = next
        if remind { lastReminder[sample.deviceID] = nowMilliseconds }
        return (next, remind)
    }
    public func aggregate() -> DiskPressureLevel { states.values.max() ?? .healthy }
}

public actor MigrationLease {
    public static let defaultTTLMilliseconds: Int64 = 5 * 60_000
    private let clock: any ComputerClock
    private let ttl: Int64
    private var expiresAt: Int64?
    public init(clock: any ComputerClock = SystemComputerClock(), ttlMilliseconds: Int64 = defaultTTLMilliseconds) { self.clock = clock; ttl = ttlMilliseconds }
    public func setMigrating(_ value: Bool) async { expiresAt = value ? await clock.nowMilliseconds() + ttl : nil }
    public func isMigrating() async -> Bool {
        guard let expiresAt else { return false }
        if await clock.nowMilliseconds() >= expiresAt { self.expiresAt = nil; return false }
        return true
    }
}

public actor ComputerBusyGuard {
    private var owners: Set<String> = []
    public init() {}
    public func acquire(owner: String) throws { guard !owner.isEmpty, owners.insert(owner).inserted else { throw RemoteComputerError.operationBusy } }
    public func release(owner: String) { owners.remove(owner) }
    public func requireIdle(force: Bool = false) throws { if !force && !owners.isEmpty { throw RemoteComputerError.operationBusy } }
    public var isBusy: Bool { !owners.isEmpty }
}

public struct ComputerRetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var initialDelayMilliseconds: Int64
    public var maximumDelayMilliseconds: Int64
    public var multiplier: Double
    public init(maximumAttempts: Int = 3, initialDelayMilliseconds: Int64 = 1_000, maximumDelayMilliseconds: Int64 = 30_000, multiplier: Double = 2) {
        self.maximumAttempts = max(1, maximumAttempts); self.initialDelayMilliseconds = max(0, initialDelayMilliseconds)
        self.maximumDelayMilliseconds = max(0, maximumDelayMilliseconds); self.multiplier = max(1, multiplier)
    }
    public func delay(forAttempt attempt: Int) -> Int64 {
        guard attempt > 0 else { return 0 }
        let computed = Double(initialDelayMilliseconds) * pow(multiplier, Double(attempt - 1))
        guard computed.isFinite else { return maximumDelayMilliseconds }
        return min(maximumDelayMilliseconds, Int64(min(computed, Double(Int64.max))))
    }
    public func run<T: Sendable>(clock: any ComputerClock = SystemComputerClock(), operation: @Sendable () async throws -> T) async throws -> T {
        var last: Error?
        for attempt in 1...maximumAttempts {
            do { return try await operation() } catch is CancellationError { throw CancellationError() } catch { last = error }
            if attempt < maximumAttempts { try await clock.sleep(milliseconds: delay(forAttempt: attempt)) }
        }
        throw last ?? RemoteComputerError.invalidResponse
    }
}
