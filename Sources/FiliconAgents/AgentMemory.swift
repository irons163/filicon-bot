import Foundation

/// Facts, not transcripts, instructions or permission grants. Existing and
/// human-approved records always retain explicit provenance.
public struct AgentMemory: Identifiable, Codable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable { case explicit, synthesis, episode }
    public enum Tier: String, Codable, Sendable { case profile, log, note }
    public enum Scope: String, Codable, Sendable { case agent, user, project }
    public let id: UUID
    public let accountID: String
    public let agentID: UUID
    public let fact: String
    public let tier: Tier
    public let scope: Scope
    public let project: String?
    public let createdAt: Date
    public let origin: Origin
    public init(id: UUID = UUID(), accountID: String, agentID: UUID, fact: String, tier: Tier = .log,
                scope: Scope = .agent, project: String? = nil, createdAt: Date = Date()) {
        self.id = id; self.accountID = accountID; self.agentID = agentID
        self.fact = fact; self.tier = tier; self.scope = scope; self.project = project; self.createdAt = createdAt
        self.origin = .explicit
    }
    // Only host synthesis code can construct generated provenance. The public
    // write/approval API cannot ask to make an explicit fact auto-editable.
    init(synthesizedID id: UUID, accountID: String, agentID: UUID, fact: String,
         tier: Tier, createdAt: Date) {
        self.id = id; self.accountID = accountID; self.agentID = agentID
        self.fact = fact; self.tier = tier; self.scope = .agent; self.project = nil
        self.createdAt = createdAt; self.origin = .synthesis
    }
    init(episodeID id: UUID, accountID: String, agentID: UUID, fact: String, createdAt: Date) {
        self.id = id; self.accountID = accountID; self.agentID = agentID
        self.fact = fact; self.tier = .log; self.scope = .agent; self.project = nil
        self.createdAt = createdAt; self.origin = .episode
    }
    private enum CodingKeys: String, CodingKey { case id, accountID, agentID, fact, tier, scope, project, createdAt, origin }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        accountID = try values.decode(String.self, forKey: .accountID)
        agentID = try values.decode(UUID.self, forKey: .agentID)
        fact = try values.decode(String.self, forKey: .fact)
        tier = try values.decode(Tier.self, forKey: .tier)
        // Older approvals never consented to sharing. A missing scope stays private.
        scope = try values.decodeIfPresent(Scope.self, forKey: .scope) ?? .agent
        project = try values.decodeIfPresent(String.self, forKey: .project)
        guard scope == .project ? project.map(AgentProject.isValidSlug) == true : project == nil else {
            throw DecodingError.dataCorruptedError(forKey: .project, in: values, debugDescription: "Invalid memory project scope")
        }
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        // Every previously saved Filicon fact required human approval.
        origin = try values.decodeIfPresent(Origin.self, forKey: .origin) ?? .explicit
    }

    public func isVisible(accountID: String, agentID: UUID, joinedProjects: Set<String> = []) -> Bool {
        guard self.accountID == accountID else { return false }
        switch scope {
        case .agent: return project == nil && self.agentID == agentID
        case .user: return project == nil
        case .project: return project.map { AgentProject.isValidSlug($0) && joinedProjects.contains($0) } ?? false
        }
    }
}

/// Human editor pagination, not a model permission or recall limit. A page is
/// a fresh view of the store; callers refresh after edits, not append snapshots.
public struct AgentMemoryEditorPage: Sendable {
    public static let pageSize = 20
    public let memories: [AgentMemory]
    public let index: Int
    public let pageCount: Int
    public let totalCount: Int
    public init(memories: [AgentMemory], index: Int) {
        totalCount = memories.count
        pageCount = max(1, memories.count / Self.pageSize + (memories.count % Self.pageSize == 0 ? 0 : 1))
        self.index = min(max(0, index), pageCount - 1)
        let start = self.index * Self.pageSize
        self.memories = Array(memories.dropFirst(start).prefix(Self.pageSize))
    }
}

public struct AgentMemoryChange: Equatable, Sendable {
    public enum Operation: String, Sendable { case write, forget }
    public let operation: Operation
    public let memory: AgentMemory
    public let project: AgentProject?
    public init(operation: Operation, memory: AgentMemory, project: AgentProject? = nil) {
        self.operation = operation; self.memory = memory; self.project = project
    }
}

public enum AgentMemoryError: String, LocalizedError, Sendable {
    case invalid = "Use memory write/forget with one fact of at most 1,000 characters, scope agent/user/project, and tier profile/log/note. Project scope requires an exact joined project slug. Forget requires exact recorded text, the same scope/project, and no tier."
    case stale = "This memory changed or no longer exists. Refresh the memories and request approval again."
    case duplicate = "This fact is already saved for this agent."
    case limit = "Private memory supports at most 8 profile facts. Log and note history has no count limit."
    case sharedDuplicate = "This fact is already saved in shared user memory."
    case sharedLimit = "Shared user memory supports at most 8 profile facts per account. Log and note history has no count limit."
    case unavailable = "The memory owner is unavailable."
    case projectUnavailable = "Project memory requires an active member of an existing project in this account. Use an exact project slug with scope project only."
    case projectDuplicate = "This fact is already saved in this project's shared memory."
    case projectLimit = "Project memory supports at most 8 profile facts per project. Log and note history has no count limit."
    public var errorDescription: String? { rawValue }
}

/// Ephemeral lexical hints, not a stored transcript or an authority to share facts.
/// Keep only bounded, unique terms; never retain the raw request on a tool/session.
public struct AgentMemoryQuery: Sendable {
    private let terms: Set<String>
    public init(_ text: String) { terms = Self.tokenize(text) }

    fileprivate func relevance(of fact: String) -> Int {
        guard !terms.isEmpty else { return 0 }
        return terms.intersection(Self.tokenize(fact)).count
    }

    private static let stopwords: Set<String> = [
        "the", "this", "that", "with", "from", "they", "them", "then", "than", "what", "when",
        "where", "which", "will", "would", "could", "should", "have", "been", "being", "about",
        "just", "like", "your", "does", "were", "also", "into", "over", "only", "some", "more",
        "most", "very", "much", "here", "there", "their", "these", "those", "because", "while",
        "after", "before", "user", "and", "for", "are", "you", "is", "to", "of", "in", "it",
        "le", "la", "les", "de", "des", "du", "un", "une", "et", "pour", "avec", "est",
        "el", "los", "las", "del", "en", "una", "unos", "unas", "con", "para", "por", "que",
    ]

    private static func tokenize(_ text: String) -> Set<String> {
        // Scalar bounds also cover adversarially long grapheme clusters. Folding
        // is locale-independent, with accents/width ignored for literal matching.
        let scalars = Array(text.unicodeScalars.prefix(4_097))
        let prefix = String(String.UnicodeScalarView(scalars.prefix(4_096)))
        let normalized = prefix.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                        locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
        var terms: Set<String> = [], word = "", length = 0
        var previousCJK: Unicode.Scalar?
        func insert(_ term: String) {
            if terms.count < 128, !stopwords.contains(term) { terms.insert(term) }
        }
        func flushWord() {
            if (2...64).contains(length) { insert(word) }
            word = ""; length = 0
        }
        for scalar in normalized.unicodeScalars.prefix(4_096) {
            guard terms.count < 128 else { break }
            if isCJK(scalar) {
                flushWord()
                // Adjacent Han/kana/Hangul pairs work without whitespace or a
                // locale-dependent segmenter; no single-character fuzzy matches.
                if let previousCJK { insert(String(previousCJK) + String(scalar)) }
                previousCJK = scalar
            } else {
                previousCJK = nil
                if CharacterSet.alphanumerics.contains(scalar) {
                    length += 1
                    if length <= 64 { word.unicodeScalars.append(scalar) }
                } else { flushWord() }
            }
        }
        // Do not treat a request truncated mid-word as a complete matching word.
        if scalars.count <= 4_096, normalized.unicodeScalars.count <= 4_096 { flushWord() }
        return terms
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F, // Han
             0x3040...0x30FF, // Hiragana / katakana
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: return true // Hangul
        default: return false
        }
    }
}

/// Read-only recall, never compaction or deletion. Scope filtering precedes ranking
/// and deduplication so inaccessible records cannot hide or leak into visible facts.
public struct AgentMemoryRecall: Sendable {
    public let memories: [AgentMemory]
    public let omittedCount: Int
    public let factsJSON: String
    public let injectedProjects: [String]
    public let alsoMemberOf: [String]

    public init(memories source: [AgentMemory], accountID: String, agentID: UUID, query: AgentMemoryQuery = .init(""), joinedProjects: Set<String> = []) throws {
        let visible = source.filter { $0.isVisible(accountID: accountID, agentID: agentID, joinedProjects: joinedProjects) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func fact(_ memory: AgentMemory) -> AgentMemoryFact { AgentMemoryFact(memory, readerID: agentID) }
        func newestFirst(_ left: AgentMemory, _ right: AgentMemory) -> Bool {
            if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
            return left.id.uuidString < right.id.uuidString
        }
        let projectFacts = Dictionary(grouping: visible.filter { $0.scope == .project }, by: { $0.project! })
        // Only joined projects are considered. Empty projects sort after those with facts;
        // ties use the slug, independent of source order or the process locale.
        let projects = joinedProjects.sorted { left, right in
            let lhs = projectFacts[left] ?? [], rhs = projectFacts[right] ?? []
            if lhs.isEmpty != rhs.isEmpty { return !lhs.isEmpty }
            let lhsDate = max(0, lhs.map { $0.createdAt.timeIntervalSince1970 }.max() ?? 0)
            let rhsDate = max(0, rhs.map { $0.createdAt.timeIntervalSince1970 }.max() ?? 0)
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return left < right
        }
        injectedProjects = Array(projects.prefix(3))
        alsoMemberOf = Array(projects.dropFirst(3))
        var selected: [AgentMemory] = []
        // Separate pools preserve private-vs-shared precedence and foundational facts.
        var pools: [(AgentMemory.Scope, String?, Bool, Int, Int)] = [
            (.agent, nil, true, 100, 8_000), (.agent, nil, false, 30, 4_000),
            (.user, nil, true, 50, 4_000), (.user, nil, false, 15, 2_000),
        ]
        for project in injectedProjects {
            pools.append((.project, project, true, 25, 2_500))
            pools.append((.project, project, false, 10, 1_500))
        }
        for (scope, project, profile, limit, bytes) in pools {
            var seen: Set<String> = []
            let distinct = visible.filter { $0.scope == scope && $0.project == project && ($0.tier == .profile) == profile }
                .sorted(by: newestFirst).filter {
                    let key = ($0.project ?? "") + "\u{1f}" + $0.fact.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
                    return seen.insert(key).inserted
                }
            let ranked = distinct.map { (memory: $0, relevance: query.relevance(of: $0.fact)) }.sorted { left, right in
                if left.relevance != right.relevance { return left.relevance > right.relevance }
                let (leftMemory, rightMemory) = (left.memory, right.memory)
                if !profile {
                    // Equivalent relative ordering to log2(importance) + date / 30 days:
                    // Host episode provenance has importance 1.5; text prefixes
                    // cannot elevate a model's public write above ordinary logs.
                    let left = leftMemory.createdAt.timeIntervalSince1970 / (30 * 86_400)
                        + (leftMemory.origin == .episode ? log2(1.5) : leftMemory.tier == .note ? -1 : 0)
                    let right = rightMemory.createdAt.timeIntervalSince1970 / (30 * 86_400)
                        + (rightMemory.origin == .episode ? log2(1.5) : rightMemory.tier == .note ? -1 : 0)
                    if left != right { return left > right }
                }
                return newestFirst(leftMemory, rightMemory)
            }.map(\.memory)
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

/// Bounded duplicate-detection context for private memory extraction. This is a
/// read-only projection, never a retention limit or permission to share history.
public struct AgentMemoryExtractionContext: Sendable {
    public static let archiveScanLimit = 500
    public static let historyLimit = 10
    public static let maximumJSONBytes = 16_000
    public let facts: [String]

    public init(memories: [AgentMemory], accountID: String, agentID: UUID, query: AgentMemoryQuery) throws {
        let privateFacts = memories.filter {
            $0.accountID == accountID && $0.agentID == agentID && $0.scope == .agent && $0.project == nil
        }
        func newest(_ lhs: AgentMemory, _ rhs: AgentMemory) -> Bool {
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        func key(_ fact: String) -> String {
            fact.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        }
        // Use normal recent recall, then add relevant older facts rather than
        // letting relevance consume both the recall and history allocations.
        let recall = try AgentMemoryRecall(memories: privateFacts, accountID: accountID, agentID: agentID)
        let archive = privateFacts.sorted {
            if ($0.tier == .profile) != ($1.tier == .profile) { return $0.tier == .profile }
            return newest($0, $1)
        }.prefix(Self.archiveScanLimit)
        var seen = Set(recall.memories.map { key($0.fact) })
        let history = archive.filter { seen.insert(key($0.fact)).inserted }
            .map { (memory: $0, score: query.relevance(of: $0.fact)) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return newest($0.memory, $1.memory)
            }.prefix(Self.historyLimit).map(\.memory)
        let encoder = JSONEncoder()
        var selected: [String] = [], bytes = 2
        seen.removeAll()
        for memory in recall.memories + history {
            guard seen.insert(key(memory.fact)).inserted else { continue }
            let cost = try encoder.encode(memory.fact).count + (selected.isEmpty ? 0 : 1)
            guard bytes + cost <= Self.maximumJSONBytes else { continue }
            selected.append(memory.fact); bytes += cost
        }
        facts = selected
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
