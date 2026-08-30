import Foundation

public enum ConnectionPhase: String, Codable, Sendable { case hidden, loading, connected, reconnecting, unreachable }
public struct ConnectionSnapshot: Codable, Equatable, Sendable {
    public var phase: ConnectionPhase; public var isRetrying: Bool; public var failureCount: Int
    public init(phase: ConnectionPhase = .hidden, isRetrying: Bool = false, failureCount: Int = 0) { self.phase = phase; self.isRetrying = isRetrying; self.failureCount = failureCount }
    private enum CodingKeys: String, CodingKey { case phase, isRetrying, failureCount, connected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let phase = try? c.decode(ConnectionPhase.self, forKey: .phase) { self.phase = phase }
        else if (try? c.decode(Bool.self, forKey: .connected)) == true { self.phase = .connected }
        else { self.phase = .hidden }
        isRetrying = (try? c.decode(Bool.self, forKey: .isRetrying)) ?? false
        failureCount = max(0, (try? c.decode(Int.self, forKey: .failureCount)) ?? 0)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(phase, forKey: .phase); try c.encode(isRetrying, forKey: .isRetrying); try c.encode(failureCount, forKey: .failureCount)
    }
}
public enum ConnectionEvent: Sendable { case show, hide, attemptStarted, succeeded, failed, retryStarted }
public struct ConnectionStateMachine: Sendable {
    public private(set) var snapshot: ConnectionSnapshot
    private var hasConnected = false
    public init(snapshot: ConnectionSnapshot = .init()) { self.snapshot = snapshot; self.hasConnected = snapshot.phase == .connected || snapshot.phase == .reconnecting }
    @discardableResult public mutating func send(_ event: ConnectionEvent) -> ConnectionSnapshot {
        switch event {
        case .hide: snapshot = .init(phase: .hidden)
        case .show: snapshot.phase = hasConnected ? .connected : .loading; snapshot.isRetrying = false
        case .attemptStarted: snapshot.phase = hasConnected ? .reconnecting : .loading; snapshot.isRetrying = false
        case .succeeded: hasConnected = true; snapshot = .init(phase: .connected)
        case .failed: snapshot.failureCount += 1; snapshot.isRetrying = false; snapshot.phase = hasConnected ? .reconnecting : .unreachable
        case .retryStarted: snapshot.isRetrying = true; snapshot.phase = hasConnected ? .reconnecting : .loading
        }
        return snapshot
    }
}
