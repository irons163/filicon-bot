import Foundation

/// Explicitly approved facts, not transcripts, instructions or permission grants.
public struct AgentMemory: Identifiable, Codable, Hashable, Sendable {
    public enum Tier: String, Codable, Sendable { case profile, log, note }
    public enum Scope: String, Codable, Sendable { case agent, user }
    public let id: UUID
    public let accountID: String
    public let agentID: UUID
    public let fact: String
    public let tier: Tier
    public let scope: Scope
    public let createdAt: Date
    public init(id: UUID = UUID(), accountID: String, agentID: UUID, fact: String, tier: Tier = .log,
                scope: Scope = .agent, createdAt: Date = Date()) {
        self.id = id; self.accountID = accountID; self.agentID = agentID
        self.fact = fact; self.tier = tier; self.scope = scope; self.createdAt = createdAt
    }
    private enum CodingKeys: String, CodingKey { case id, accountID, agentID, fact, tier, scope, createdAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        accountID = try values.decode(String.self, forKey: .accountID)
        agentID = try values.decode(UUID.self, forKey: .agentID)
        fact = try values.decode(String.self, forKey: .fact)
        tier = try values.decode(Tier.self, forKey: .tier)
        // Older approvals never consented to sharing. A missing scope stays private.
        scope = try values.decodeIfPresent(Scope.self, forKey: .scope) ?? .agent
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

public struct AgentMemoryChange: Equatable, Sendable {
    public enum Operation: String, Sendable { case write, forget }
    public let operation: Operation
    public let memory: AgentMemory
    public init(operation: Operation, memory: AgentMemory) { self.operation = operation; self.memory = memory }
}

public enum AgentMemoryError: String, LocalizedError, Sendable {
    case invalid = "Use memory write/forget with one fact of at most 1,000 characters, scope agent or user, and tier profile, log or note. Forget requires exact recorded text, the same scope, and no tier."
    case stale = "This memory changed or no longer exists. Refresh the memories and request approval again."
    case duplicate = "This fact is already saved for this agent."
    case limit = "Agent memory is limited to 48 facts, including 8 profile facts, and 12,000 characters per account and agent."
    case sharedDuplicate = "This fact is already saved in shared user memory."
    case sharedLimit = "Shared user memory is limited to 48 facts, including 8 profile facts, and 12,000 characters per account across all agents."
    case unavailable = "The memory owner is unavailable."
    public var errorDescription: String? { rawValue }
}

/// Read-only recall, never compaction or deletion. Scope filtering precedes ranking
/// and deduplication so inaccessible records cannot hide or leak into visible facts.
public struct AgentMemoryRecall: Sendable {
    public let memories: [AgentMemory]
    public let omittedCount: Int
    public let factsJSON: String

    public init(memories source: [AgentMemory], accountID: String, agentID: UUID) throws {
        let visible = source.filter { $0.accountID == accountID && ($0.scope == .user || $0.agentID == agentID) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        struct Fact: Encodable {
            let fact: String
            let tier: AgentMemory.Tier
            let scope: AgentMemory.Scope
            let recordedBy: UUID
            let canForget: Bool
            let recordedAt: String
        }
        func fact(_ memory: AgentMemory) -> Fact {
            Fact(fact: memory.fact, tier: memory.tier, scope: memory.scope, recordedBy: memory.agentID,
                 canForget: memory.agentID == agentID, recordedAt: memory.createdAt.ISO8601Format())
        }
        func newestFirst(_ left: AgentMemory, _ right: AgentMemory) -> Bool {
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id.uuidString < right.id.uuidString
        }
        var selected: [AgentMemory] = []
        // Separate pools preserve private-vs-shared precedence and foundational facts.
        for (scope, profile, limit, bytes) in [
            (AgentMemory.Scope.agent, true, 8, 8_000), (.agent, false, 30, 4_000),
            (.user, true, 8, 4_000), (.user, false, 15, 2_000),
        ] {
            var seen: Set<String> = []
            let distinct = visible.filter { $0.scope == scope && ($0.tier == .profile) == profile }
                .sorted(by: newestFirst).filter {
                    let key = $0.fact.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
                    return seen.insert(key).inserted
                }
            let ranked = distinct.sorted {
                if !profile {
                    // Equivalent relative ordering to log2(importance) + date / 30 days:
                    // a note has importance 0.5, a log 1. No wall-clock expiry or erasure.
                    let left = $0.createdAt.timeIntervalSince1970 / (30 * 86_400) - ($0.tier == .note ? 1 : 0)
                    let right = $1.createdAt.timeIntervalSince1970 / (30 * 86_400) - ($1.tier == .note ? 1 : 0)
                    if left != right { return left > right }
                }
                return newestFirst($0, $1)
            }
            var used = 2, count = 0 // JSON array brackets, separators and escaped metadata all count.
            for memory in ranked {
                guard count < limit else { break }
                let cost = try encoder.encode(fact(memory)).count + (count == 0 ? 0 : 1)
                guard used + cost <= bytes else { continue } // Never truncate a recorded fact.
                selected.append(memory); count += 1; used += cost
            }
        }
        memories = selected
        omittedCount = visible.count - selected.count
        factsJSON = String(decoding: try encoder.encode(selected.map(fact)), as: UTF8.self)
    }
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
