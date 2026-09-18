import Foundation
import FiliconDomain

/// A host-built, reviewable change, not an arbitrary replacement profile.
public struct AgentProfileChange: Sendable, Equatable, Codable {
    public enum Operation: String, Sendable, Codable { case create = "CreateAgent", update = "UpdateAgent" }
    public let operation: Operation
    public let requesterID: UUID
    public let targetID: UUID
    public let name: String
    public let description: String
    public let providerID: ProviderID
    public let modelID: ModelID
    public let previousName: String?
    public let previousDescription: String?

    public init(operation: Operation, requesterID: UUID, targetID: UUID, name: String, description: String,
                providerID: ProviderID, modelID: ModelID, previousName: String? = nil, previousDescription: String? = nil) {
        self.operation = operation; self.requesterID = requesterID; self.targetID = targetID
        self.name = name; self.description = description; self.providerID = providerID; self.modelID = modelID
        self.previousName = previousName; self.previousDescription = previousDescription
    }
}

public enum AgentProfileChangeError: LocalizedError, Sendable {
    case invalidFields, unavailable, stale, duplicate, limitReached
    public var errorDescription: String? {
        switch self {
        case .invalidFields: "Provide a nonempty name (up to 120 characters) and a description of at most 2,000 characters. Updates cannot clear fields."
        case .unavailable: "The requesting or target agent is unavailable. You cannot update yourself with this tool."
        case .stale: "The agent changed while awaiting approval. Inspect the current profile and request approval again."
        case .duplicate: "This profile change was already requested. Do not repeat it with a different tool call."
        case .limitReached: "The four-change limit for this user request has been reached."
        }
    }
}

/// Revocation fences the synchronous commit itself, including the actor hop
/// after approval. It grants no authority: the host must authorize each change.
public final class AgentProfileChangeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var committed: [(AgentProfileChange, AgentProfile)] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    /// A receipt is recorded only after the profile is durably saved. Ancillary
    /// failures (for example quota bookkeeping) must not invite duplicate writes.
    public func committedProfile(for change: AgentProfileChange) -> AgentProfile? {
        lock.withLock { committed.last(where: { $0.0 == change })?.1 }
    }
    func commit(_ change: AgentProfileChange, operation: () throws -> AgentProfile) throws -> AgentProfile {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            let profile = try operation()
            committed.append((change, profile))
            return profile
        }
    }
}
