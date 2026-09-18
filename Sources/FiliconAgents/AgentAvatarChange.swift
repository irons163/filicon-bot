import Foundation

/// Host-bound own-avatar proposal. Never accepts a model-selected owner or path.
public struct AgentAvatarChange: Sendable, Equatable {
    public enum Operation: String, Sendable { case set, clear }
    public let operation: Operation
    public let agentID: UUID
    public let pet: AgentPetAvatar?
    public let previousAvatar: AgentAvatar?

    public init(operation: Operation, agentID: UUID, pet: AgentPetAvatar? = nil, previousAvatar: AgentAvatar?) {
        self.operation = operation; self.agentID = agentID
        self.pet = pet; self.previousAvatar = previousAvatar
    }

    /// Filicon's default companion is Codex; clearing never deletes image files.
    public var avatar: AgentAvatar { .pet(pet ?? .codex) }
    public var isValid: Bool { operation == .set ? pet != nil : pet == nil }
}

public enum AgentAvatarChangeError: String, LocalizedError, Sendable {
    case invalid = "For avatar changes, use target avatar with action set and a listed pet_id, or action clear without pet_id. Paths, URLs and other fields are not supported."
    public var errorDescription: String? { rawValue }
}

/// Synchronous revocation and durable receipt, including the post-approval hop.
public final class AgentAvatarChangeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var committed: [(AgentAvatarChange, AgentProfile)] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committedProfile(for change: AgentAvatarChange) -> AgentProfile? {
        lock.withLock { committed.last(where: { $0.0 == change })?.1 }
    }
    func commit(_ change: AgentAvatarChange, operation: () throws -> AgentProfile) throws -> AgentProfile {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            let profile = try operation()
            committed.append((change, profile))
            return profile
        }
    }
}
