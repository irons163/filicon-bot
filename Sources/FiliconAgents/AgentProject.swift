import Foundation

/// Account-local collaboration metadata, NOT a filesystem grant or chat group.
public struct AgentProject: Identifiable, Codable, Equatable, Sendable {
    public static func isValidSlug(_ slug: String) -> Bool {
        (1...64).contains(slug.utf8.count) && slug.wholeMatch(of: /^[a-z0-9]+(?:-[a-z0-9]+)*$/) != nil
    }
    public var id: String { slug }
    public let accountID: String
    public let slug: String
    public let name: String
    public let summary: String
    public let createdAt: Date
    public internal(set) var memberIDs: Set<UUID>
    public internal(set) var revision: UUID
}

public enum AgentProjectAction: String, Sendable { case create, join, leave }

/// Only AgentService can construct a proposal from a current store snapshot.
public struct AgentProjectChange: Equatable, Sendable {
    public let action: AgentProjectAction
    public let agentID: UUID
    public let previous: AgentProject?
    public let proposed: AgentProject
    public var createsProject: Bool { previous == nil }
}

public enum AgentProjectError: String, LocalizedError, Sendable {
    case invalid = "Project changes accept create/join/leave and one exact lowercase slug (letters, digits and single hyphens, up to 64 bytes). Create also requires a name (up to 200 UTF-8 bytes) and optional description (up to 1,000 UTF-8 bytes), without control characters. No paths or permission fields."
    case unavailable = "The project or active agent is unavailable in this account."
    case unchanged = "This agent already has the requested project membership. Nothing changed."
    case limit = "This account already has 50 collaboration projects. No project was created."
    case stale = "Project membership changed while approval was pending. Request approval again."
    public var errorDescription: String? { rawValue }
}

public final class AgentProjectChangeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var receipts: [AgentProjectChange] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committed(_ change: AgentProjectChange) -> Bool { lock.withLock { receipts.contains(change) } }
    func commit(_ change: AgentProjectChange, operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
            receipts.append(change)
        }
    }
}
