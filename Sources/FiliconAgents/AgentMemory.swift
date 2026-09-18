import Foundation

/// Explicitly approved facts, not transcripts, instructions or permission grants.
public struct AgentMemory: Identifiable, Codable, Hashable, Sendable {
    public enum Tier: String, Codable, Sendable { case profile, log }
    public let id: UUID
    public let accountID: String
    public let agentID: UUID
    public let fact: String
    public let tier: Tier
    public let createdAt: Date
    public init(id: UUID = UUID(), accountID: String, agentID: UUID, fact: String, tier: Tier = .log, createdAt: Date = Date()) {
        self.id = id; self.accountID = accountID; self.agentID = agentID
        self.fact = fact; self.tier = tier; self.createdAt = createdAt
    }
}

public struct AgentMemoryChange: Equatable, Sendable {
    public enum Operation: String, Sendable { case write, forget }
    public let operation: Operation
    public let memory: AgentMemory
    public init(operation: Operation, memory: AgentMemory) { self.operation = operation; self.memory = memory }
}

public enum AgentMemoryError: String, LocalizedError, Sendable {
    case invalid = "Use memory write/forget with one fact of at most 1,000 characters, scope agent, and tier profile or log. Forget requires exact recorded text and no tier."
    case stale = "This memory changed or no longer exists. Refresh the memories and request approval again."
    case duplicate = "This fact is already saved for this agent."
    case limit = "Agent memory is limited to 48 facts, including 8 profile facts, and 12,000 characters per account and agent."
    case unavailable = "The memory owner is unavailable."
    public var errorDescription: String? { rawValue }
}

/// Stop and account changes revoke queued commits before any actor suspension.
public final class AgentMemoryChangeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var receipts: [AgentMemoryChange] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committed(_ change: AgentMemoryChange) -> Bool { lock.withLock { receipts.contains(change) } }
    func commit(_ change: AgentMemoryChange, operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
            receipts.append(change)
        }
    }
}
