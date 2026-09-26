import Foundation
import CryptoKit

/// Prevent automatic synthesis from recreating explicitly forgotten facts.
/// Keep a digest, not another plaintext copy of the deleted fact.
struct AgentMemoryTombstone: Codable, Hashable, Sendable {
    let accountID: String
    let agentID: UUID
    let scope: AgentMemory.Scope
    let project: String?
    let digest: String

    init(_ memory: AgentMemory) {
        accountID = memory.accountID; agentID = memory.agentID
        scope = memory.scope; project = memory.project
        digest = SHA256.hash(data: Data(AgentMemorySuggestionParser.key(memory.fact).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// Host snapshot includes provenance and tombstones, not just visible text.
/// Capturing a snapshot does not authorize synthesis or persist any changes.
struct AgentMemorySynthesisSnapshot: Equatable, Sendable {
    let accountID: String
    let agentID: UUID
    let memories: [AgentMemory]
    let tombstones: Set<AgentMemoryTombstone>
    let inputMemories: [AgentMemory]

    init(accountID: String, agentID: UUID, memories: [AgentMemory], tombstones: Set<AgentMemoryTombstone>) throws {
        self.accountID = accountID; self.agentID = agentID
        self.memories = memories; self.tombstones = tombstones
        let ordered = memories.sorted {
            if ($0.origin == .explicit) != ($1.origin == .explicit) { return $0.origin == .explicit }
            if ($0.tier == .profile) != ($1.tier == .profile) { return $0.tier == .profile }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var selected: [AgentMemory] = [], seen: Set<UUID> = [], bytes = 2
        // Reference prepareSynthesis limits candidates to 512. The additional
        // encoded-byte budget leaves room for current evidence, never truncates
        // saved facts, and does not alter the full snapshot used for stale checks.
        let candidates = ordered.filter { seen.insert($0.id).inserted }.prefix(512)
        for memory in candidates {
            let cost = try encoder.encode(AgentMemorySynthesisInputFact(memory)).count + (selected.isEmpty ? 0 : 1)
            guard bytes + cost <= 64_000 else { continue }
            selected.append(memory); bytes += cost
        }
        inputMemories = selected
    }
    var mutableMemoryIDs: Set<UUID> {
        Set(inputMemories.filter { $0.origin == .synthesis }.map(\.id))
    }
}

struct AgentMemorySynthesisInputFact: Encodable {
    let id: UUID
    let content: String
    let kind: AgentMemory.Tier
    let origin: AgentMemory.Origin
    let createdAt: Date
    init(_ memory: AgentMemory) {
        id = memory.id; content = memory.fact; kind = memory.tier
        origin = memory.origin; createdAt = memory.createdAt
    }
}
