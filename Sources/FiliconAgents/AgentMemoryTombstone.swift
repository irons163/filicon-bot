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
    var mutableMemoryIDs: Set<UUID> {
        Set(memories.filter { $0.origin == .synthesis }.map(\.id))
    }
}
