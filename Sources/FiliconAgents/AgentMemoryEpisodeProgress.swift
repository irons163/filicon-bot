import Foundation

/// Value-only episode progress. The service must check saved consent before
/// recording, executing or committing; possession of this value grants no access.
public struct AgentMemoryEpisodeProgress: Codable, Equatable, Sendable {
    public struct Turn: Codable, Equatable, Sendable {
        public let id: UUID
        public let occurredAt: Date
        public let user: String
        public let assistant: String
    }
    public let accountID: String
    public let agentID: UUID
    public let originID: UUID
    public let revision: UUID
    public private(set) var turns: [Turn] = []
    private var recentIDs: [UUID] = []
    public static let interval = 6

    public init(accountID: String, agentID: UUID, originID: UUID, revision: UUID) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 512 else { throw AgentMemorySuggestionError.invalid }
        self.accountID = accountID; self.agentID = agentID
        self.originID = originID; self.revision = revision
    }

    /// Hidden/superseded/incomplete turns must be excluded by the caller.
    /// Duplicate completed exchanges never advance the six-turn counter.
    @discardableResult public mutating func record(id: UUID, at: Date, user: String, assistant: String) throws -> Bool {
        guard at.timeIntervalSince1970.isFinite else { throw AgentMemorySuggestionError.invalid }
        guard !recentIDs.contains(id), Self.isMemorable(user),
              !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              assistant.trimmingCharacters(in: .whitespacesAndNewlines) != "PASS" else { return false }
        turns.append(.init(id: id, occurredAt: at, user: Self.clip(user, limit: 2_000),
                           assistant: Self.clip(assistant, limit: 2_000)))
        recentIDs.append(id)
        if turns.count > 64 { turns.removeFirst(turns.count - 64) }
        if recentIDs.count > 128 { recentIDs.removeFirst(recentIDs.count - 128) }
        return true
    }

    public var ready: [Turn] { turns.count >= Self.interval ? turns : [] }

    /// Called after an attempted summary, including failure. Preserve exchanges
    /// arriving while the model was running; never replay the failed batch.
    public mutating func finish(_ batch: [Turn]) {
        let completed = Set(batch.map(\.id))
        turns.removeAll { completed.contains($0.id) }
    }

    public mutating func clearPending() { turns.removeAll() }

    /// Matches the reference's legacy English trivial-exchange filter. This is
    /// not a semantic classifier or a promise to filter greetings in all locales.
    public static func isMemorable(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if text.utf16.count > 40 || text.contains("?") { return true }
        let normalized = text.lowercased()
            .replacingOccurrences(of: #"[\s!.…,~)\]]+$"#, with: "", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !trivial.contains(normalized)
    }

    public static func narrative(_ raw: String) -> String? {
        let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let bounded = clip(normalized, limit: 500)
        return bounded.isEmpty || bounded.uppercased() == "NONE" ? nil : bounded
    }

    // Match JavaScript's UTF-16 budget without producing an orphan surrogate.
    private static func clip(_ text: String, limit: Int) -> String {
        var units = Array(text.utf16.prefix(limit))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    private static let trivial: Set<String> = ["hi", "hey", "hello", "yo", "sup", "thanks", "thank you", "ty", "thx", "ok", "okay", "k", "kk", "cool", "nice", "great", "awesome", "perfect", "yes", "yep", "yeah", "no", "nope", "sure", "got it", "gotcha", "lol", "haha", "np", "done", "good", "bye"]

    private enum CodingKeys: String, CodingKey { case accountID, agentID, originID, revision, turns, recentIDs }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(accountID: c.decode(String.self, forKey: .accountID),
                      agentID: c.decode(UUID.self, forKey: .agentID),
                      originID: c.decode(UUID.self, forKey: .originID),
                      revision: c.decode(UUID.self, forKey: .revision))
        let pending = try c.decode([Turn].self, forKey: .turns)
        let ids = try c.decode([UUID].self, forKey: .recentIDs)
        guard pending.count <= 64, ids.count <= 128,
              Set(ids).count == ids.count, Set(pending.map(\.id)).count == pending.count,
              pending.allSatisfy({ ids.contains($0.id) && $0.occurredAt.timeIntervalSince1970.isFinite &&
                  $0.user.utf16.count <= 2_000 && $0.assistant.utf16.count <= 2_000 }) else {
            throw AgentMemorySuggestionError.invalid
        }
        turns = pending; recentIDs = ids
    }
}
