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

    public init(memories source: [AgentMemory], accountID: String, agentID: UUID, query: AgentMemoryQuery = .init("")) throws {
        let visible = source.filter { $0.accountID == accountID && ($0.scope == .user || $0.agentID == agentID) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func fact(_ memory: AgentMemory) -> AgentMemoryFact { AgentMemoryFact(memory, readerID: agentID) }
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
            let ranked = distinct.map { (memory: $0, relevance: query.relevance(of: $0.fact)) }.sorted { left, right in
                if left.relevance != right.relevance { return left.relevance > right.relevance }
                let (leftMemory, rightMemory) = (left.memory, right.memory)
                if !profile {
                    // Equivalent relative ordering to log2(importance) + date / 30 days:
                    // a note has importance 0.5, a log 1. No wall-clock expiry or erasure.
                    let left = leftMemory.createdAt.timeIntervalSince1970 / (30 * 86_400) - (leftMemory.tier == .note ? 1 : 0)
                    let right = rightMemory.createdAt.timeIntervalSince1970 / (30 * 86_400) - (rightMemory.tier == .note ? 1 : 0)
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
