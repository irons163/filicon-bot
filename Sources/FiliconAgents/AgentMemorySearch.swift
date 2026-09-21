import Foundation

/// One actor snapshot of visible records and the membership that authorizes them.
public struct AgentMemoryAccess: Sendable {
    public let memories: [AgentMemory]
    public let projects: [AgentProject]
    public var joinedProjects: Set<String> { Set(projects.map(\.slug)) }
}

/// Read-only views of already approved facts; never arbitrary agent scope.
public enum AgentMemorySearchScope: String, Codable, Sendable {
    case all, agent, user, project
    public func includes(_ scope: AgentMemory.Scope) -> Bool { self == .all || rawValue == scope.rawValue }
}

public enum AgentMemorySearchError: String, LocalizedError, Sendable {
    case invalid = "Memory search accepts query (up to 256 Unicode scalars), scope all/agent/user/project, and an optional exact project slug with scope project only, or a continuation cursor by itself."
    case stale = "This memory search cursor is invalid or the saved facts changed. Start a new search."
    case limit = "This request reached its 32 memory-search limit. Report the results already available."
    public var errorDescription: String? { rawValue }
}

/// The same provenance and disclosure format as automatic recall. Facts remain data.
public struct AgentMemoryFact: Encodable, Sendable {
    public let fact: String
    public let tier: AgentMemory.Tier
    public let scope: AgentMemory.Scope
    public let project: String?
    public let recordedBy: UUID
    public let canForget: Bool
    public let recordedAt: String

    public init(_ memory: AgentMemory, readerID: UUID) {
        fact = memory.fact; tier = memory.tier; scope = memory.scope; project = memory.project
        recordedBy = memory.agentID; canForget = memory.agentID == readerID
        recordedAt = memory.createdAt.ISO8601Format()
    }
}

/// A deterministic, bounded page over the saved store, not just injected recall.
/// Offsets/cursors are host managed. No regex, file reads, embeddings or mutations.
public struct AgentMemorySearchPage: Sendable {
    public let facts: [AgentMemoryFact]
    public let totalMatches: Int
    public let skippedOversizedCount: Int
    public let nextOffset: Int?

    public init(memories: [AgentMemory], accountID: String, agentID: UUID,
                query: String = "", scope: AgentMemorySearchScope = .all, offset: Int = 0, joinedProjects: Set<String> = []) throws {
        guard query.unicodeScalars.prefix(257).count <= 256,
              query.isEmpty || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentMemorySearchError.invalid
        }
        let matches = memories.filter {
            $0.isVisible(accountID: accountID, agentID: agentID, joinedProjects: joinedProjects) && scope.includes($0.scope)
                && (query.isEmpty || $0.fact.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                 locale: Locale(identifier: "en_US_POSIX")) != nil)
        }.sorted {
            if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
            if $0.project != $1.project { return ($0.project ?? "") < ($1.project ?? "") }
            if ($0.tier == .profile) != ($1.tier == .profile) { return $0.tier == .profile }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard offset >= 0, offset <= matches.count else { throw AgentMemorySearchError.stale }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var result: [AgentMemoryFact] = [], used = 2, skipped = 0, index = offset
        // Leave room for response metadata/cursor inside the 8 KiB wire bound.
        let factBytes = 7_000
        while index < matches.count, result.count < 8 {
            let fact = AgentMemoryFact(matches[index], readerID: agentID)
            let size = try encoder.encode(fact).count
            if size + 2 > factBytes { skipped += 1; index += 1; continue }
            let added = size + (result.isEmpty ? 0 : 1)
            guard used + added <= factBytes else { break }
            result.append(fact); used += added; index += 1
        }
        facts = result; totalMatches = matches.count; skippedOversizedCount = skipped
        nextOffset = index < matches.count ? index : nil
    }
}
