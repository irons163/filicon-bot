import Foundation

/// Only the host-selected agent's update-notification preference is mutable.
public struct AgentSettingsChange: Sendable, Equatable {
    public let agentID: UUID
    public let notifyOnUpdates: Bool
    public let previousValue: Bool
    public let previousRevision: UUID?

    public init(agentID: UUID, notifyOnUpdates: Bool, previousValue: Bool, previousRevision: UUID?) {
        self.agentID = agentID
        self.notifyOnUpdates = notifyOnUpdates
        self.previousValue = previousValue
        self.previousRevision = previousRevision
    }
}

public enum AgentSettingsChangeError: String, LocalizedError, Sendable {
    case invalid = "Settings changes require only target settings, action set and a boolean notify_on_updates. Sidebar visibility and other settings are not supported."
    case stale = "Agent notification settings changed. Reopen the editor or request approval again."
    public var errorDescription: String? { rawValue }
}

/// Stop/account changes revoke a proposal through the final synchronous save.
public final class AgentSettingsChangeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var committed: [(AgentSettingsChange, AgentProfile)] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committedProfile(for change: AgentSettingsChange) -> AgentProfile? {
        lock.withLock { committed.last(where: { $0.0 == change })?.1 }
    }
    func commit(_ change: AgentSettingsChange, operation: () throws -> AgentProfile) throws -> AgentProfile {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            let profile = try operation()
            committed.append((change, profile))
            return profile
        }
    }
}
