import Foundation

/// Pending suggestions are NOT memories and never participate in recall/search.
public struct AgentMemorySuggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let accountID: String
    public let agentID: UUID
    public let exchangeID: UUID
    public let fact: String
    public let evidence: String
    public let tier: AgentMemory.Tier
    public let createdAt: Date

    public init(id: UUID = UUID(), accountID: String, agentID: UUID, exchangeID: UUID,
                fact: String, evidence: String, tier: AgentMemory.Tier, createdAt: Date = .now) {
        self.id = id; self.accountID = accountID; self.agentID = agentID; self.exchangeID = exchangeID
        self.fact = fact; self.evidence = evidence; self.tier = tier; self.createdAt = createdAt
    }

    public var isValid: Bool {
        !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fact.count <= 1_000 && fact.utf8.count <= 4_000
            && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && evidence.count <= 1_000 && evidence.utf8.count <= 4_000
            && createdAt.timeIntervalSince1970.isFinite
            && !(fact + evidence).unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct AgentMemorySuggestionSettings: Codable, Equatable, Sendable {
    public let accountID: String
    public let agentID: UUID
    public var enabled: Bool
    public var revision: UUID?
    public init(accountID: String, agentID: UUID, enabled: Bool = false, revision: UUID? = nil) {
        self.accountID = accountID; self.agentID = agentID; self.enabled = enabled; self.revision = revision
    }
}

struct AgentMemorySuggestionReceipt: Codable, Sendable {
    let accountID: String
    let agentID: UUID
    let exchangeID: UUID
}

public struct AgentMemorySuggestionSnapshot: Equatable, Sendable {
    public let settings: AgentMemorySuggestionSettings
    public let suggestions: [AgentMemorySuggestion]
    public init(settings: AgentMemorySuggestionSettings, suggestions: [AgentMemorySuggestion]) {
        self.settings = settings; self.suggestions = suggestions
    }
}

public enum AgentMemorySuggestionError: String, LocalizedError, Sendable {
    case stale = "Memory suggestions changed or are no longer available. Refresh and try again."
    case invalid = "The memory suggestion response was invalid. No facts were saved."
    public var errorDescription: String? { rawValue }
}

/// Stop/account changes fence the final synchronous save, including an actor hop.
public final class AgentMemorySuggestionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let ancestors: [AgentMemorySuggestionLifetime]
    /// Immutable parent graph: a batch may depend on several foreground scopes.
    /// Keep all their locks through the final synchronous save, not just through
    /// a preflight check that could race a subsequent Stop/account transition.
    public init(parents: [AgentMemorySuggestionLifetime] = []) {
        var unique: [ObjectIdentifier: AgentMemorySuggestionLifetime] = [:]
        for parent in parents {
            unique[ObjectIdentifier(parent)] = parent
            for ancestor in parent.ancestors { unique[ObjectIdentifier(ancestor)] = ancestor }
        }
        ancestors = Array(unique.values)
    }
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try commit {}
    }
    func commit<T>(_ action: () throws -> T) throws -> T {
        let scopes = (ancestors + [self]).sorted {
            UInt(bitPattern: ObjectIdentifier($0)) < UInt(bitPattern: ObjectIdentifier($1))
        }
        for scope in scopes { scope.lock.lock() }
        defer { for scope in scopes.reversed() { scope.lock.unlock() } }
        guard scopes.allSatisfy({ $0.active }) else { throw CancellationError() }
        try Task.checkCancellation()
        return try action()
    }
}

public enum AgentMemorySuggestionParser {
    /// Reject the whole response if malformed; never turn partially parsed output
    /// into facts. Evidence must be an exact excerpt from the current human text.
    public static func parse(_ text: String, user: String, accountID: String, agentID: UUID,
                             exchangeID: UUID) throws -> [AgentMemorySuggestion] {
        guard text.utf8.count <= 8_192,
              let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              Set(root.keys) == ["suggestions"], let rows = root["suggestions"] as? [[String: Any]], rows.count <= 4 else {
            throw AgentMemorySuggestionError.invalid
        }
        var result: [AgentMemorySuggestion] = []
        var seen: Set<String> = []
        for row in rows {
            guard Set(row.keys) == ["fact", "evidence", "tier"],
                  let fact = row["fact"] as? String, let evidence = row["evidence"] as? String,
                  let tier = (row["tier"] as? String).flatMap(AgentMemory.Tier.init(rawValue:)),
                  !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fact.count <= 1_000, fact.utf8.count <= 4_000,
                  !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  evidence.count <= 1_000, evidence.utf8.count <= 4_000, user.contains(evidence),
                  !fact.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !evidence.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AgentMemorySuggestionError.invalid
            }
            let value = fact.trimmingCharacters(in: .whitespacesAndNewlines)
            if seen.insert(key(value)).inserted {
                result.append(.init(accountID: accountID, agentID: agentID, exchangeID: exchangeID,
                                    fact: value, evidence: evidence, tier: tier))
            }
        }
        return result
    }

    public static func key(_ fact: String) -> String {
        fact.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
