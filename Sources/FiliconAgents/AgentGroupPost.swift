import Foundation

/// Public, exact audience reviewed by the user. Never contains private persona.
public struct AgentGroupAudience: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let memberIDs: [UUID]
    public let members: [GroupMemberIdentity]
    public init(group: AgentGroup, members: [GroupMemberIdentity]) {
        id = group.id; name = group.name; memberIDs = group.memberIDs; self.members = members
    }
}

public enum AgentGroupPostError: LocalizedError, Sendable {
    case unavailable, changed, busy
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Choose a group you belong to with at least one other active member."
        case .changed: "The group's audience changed. Inspect it and request approval again."
        case .busy: "This group is already running or was already contacted in this request. Use SendMessage in the current room; do not repeatedly broadcast."
        }
    }
}

/// Stop fences the actual durable post, not just the approval callback.
public final class AgentGroupPostLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try Task.checkCancellation()
        try lock.withLock { if !active { throw CancellationError() } }
    }
    func commit(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
        }
    }
}
