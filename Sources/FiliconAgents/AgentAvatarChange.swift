import Foundation

/// Host-bound own-avatar proposal. Image bytes are prepared by the host, not
/// reopened from a model-selected path after approval.
public struct AgentAvatarChange: Sendable, Equatable {
    public enum Operation: String, Sendable { case set, clear }
    public let operation: Operation
    public let agentID: UUID
    public let pet: AgentPetAvatar?
    public let previousAvatar: AgentAvatar?
    public let image: PreparedAgentAvatar?
    public static let maximumImageSourceBytes = 5 * 1_024 * 1_024

    public init(operation: Operation, agentID: UUID, pet: AgentPetAvatar? = nil, previousAvatar: AgentAvatar?,
                image: PreparedAgentAvatar? = nil) {
        self.operation = operation; self.agentID = agentID
        self.pet = pet; self.previousAvatar = previousAvatar
        self.image = image
    }

    /// Filicon's default companion is Codex; clearing never deletes image files.
    public var avatar: AgentAvatar { image?.avatar ?? .pet(pet ?? .codex) }
    public var isValid: Bool {
        if operation == .clear { return pet == nil && image == nil }
        if let image { return pet == nil && image.sourceByteCount > 0 && image.sourceByteCount <= Self.maximumImageSourceBytes }
        return pet != nil
    }
}

public enum AgentAvatarChangeError: String, LocalizedError, Sendable {
    case invalid = "Invalid avatar proposal. Set requires exactly one supported source; clear accepts no source. File images require host-enabled source preparation, image approval and storage, with an absolute path and at most 5 MiB. URLs, owner IDs and unknown fields are not accepted."
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
