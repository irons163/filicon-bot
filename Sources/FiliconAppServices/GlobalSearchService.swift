import Foundation
import FiliconDomain
import FiliconPersistence

/// The newest in-memory transcript entry supplied by the caller while a turn
/// is streaming and before the canonical SQLite snapshot catches up.
public struct LiveMessageSearchInput: Hashable, Sendable {
    public let conversationID: UUID
    public let messageID: UUID
    public let role: MessageRole
    public let timestamp: Date
    public let body: String
    public let isHidden: Bool

    public init(
        conversationID: UUID,
        messageID: UUID,
        role: MessageRole,
        timestamp: Date,
        body: String,
        isHidden: Bool = false
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.role = role
        self.timestamp = timestamp
        self.body = body
        self.isHidden = isHidden
    }
}

extension ConversationStore {
    /// Searches the message index first. Any missing/not-ready/corrupt index or
    /// query failure falls back to a bounded scan of canonical message rows.
    /// Live inputs replace persisted hits with the same identity.
    public func searchGlobalMessages(
        _ query: String,
        includeHidden: Bool = false,
        latestLiveInputs: [LiveMessageSearchInput] = [],
        visibility: [ConversationVisibilityOverride] = []
    ) async throws -> [GlobalMessageSearchHit] {
        let repository = try resolveRepositoryForGlobalSearch()
        try await ensureLegacyImportForGlobalSearch(into: repository)
        let persisted: [GlobalMessageSearchHit]
        do {
            persisted = try await repository.searchMessages(query, includeHidden: includeHidden, visibility: visibility)
        } catch {
            persisted = try await repository.linearMessageSearch(query, includeHidden: includeHidden, visibility: visibility)
        }

        let terms = query.split(whereSeparator: { $0.isWhitespace }).prefix(GlobalSearchLimits.maximumTerms).map { String($0).lowercased() }
        let effectiveVisibility = try await repository.resolvedConversationVisibility(visibility)
        let live = latestLiveInputs
            .filter { includeHidden || !(effectiveVisibility[$0.conversationID] ?? $0.isHidden) }
            .filter { input in
                let body = String(input.body.prefix(GlobalSearchLimits.maximumIndexedBodyCharacters)).lowercased()
                return !terms.isEmpty && terms.allSatisfy { body.contains($0) }
            }
            .sorted { $0.timestamp == $1.timestamp ? $0.messageID.uuidString > $1.messageID.uuidString : $0.timestamp > $1.timestamp }
            .map {
                GlobalMessageSearchHit(
                    conversationID: $0.conversationID,
                    messageID: $0.messageID,
                    role: $0.role,
                    timestamp: $0.timestamp,
                    snippet: Self.globalSearchSnippet($0.body, terms: terms)
                )
            }

        var seen: Set<String> = []
        var perConversation: [UUID: Int] = [:]
        var merged: [GlobalMessageSearchHit] = []
        for hit in live + persisted {
            let identity = hit.conversationID.uuidString + "/" + hit.messageID.uuidString
            guard seen.insert(identity).inserted,
                  perConversation[hit.conversationID, default: 0] < GlobalSearchLimits.maximumPerConversation else { continue }
            perConversation[hit.conversationID, default: 0] += 1
            merged.append(hit)
            if merged.count == GlobalSearchLimits.maximumResults { break }
        }
        return merged
    }

    /// Recovered media-search semantics deliberately return no results if the
    /// derived media index is unavailable; media never scans attachment JSON.
    public func searchGlobalMedia(_ query: String = "", includeHidden: Bool = false,
                                  visibility: [ConversationVisibilityOverride] = []) async throws -> [GlobalMediaSearchHit] {
        let repository = try resolveRepositoryForGlobalSearch()
        try await ensureLegacyImportForGlobalSearch(into: repository)
        do { return try await repository.searchMedia(query, includeHidden: includeHidden, visibility: visibility) }
        catch { return [] }
    }

    private static func globalSearchSnippet(_ body: String, terms: [String]) -> String {
        let bounded = String(body.prefix(GlobalSearchLimits.maximumIndexedBodyCharacters))
        guard !bounded.isEmpty else { return "" }
        let lower = bounded.lowercased()
        let first = terms.compactMap { lower.range(of: $0)?.lowerBound }.min()
        let start = first.map { bounded.index($0, offsetBy: -min(60, bounded.distance(from: bounded.startIndex, to: $0))) } ?? bounded.startIndex
        let end = bounded.index(start, offsetBy: min(240, bounded.distance(from: start, to: bounded.endIndex)))
        return (start == bounded.startIndex ? "" : "…") + bounded[start..<end].replacingOccurrences(of: "\n", with: " ") + (end == bounded.endIndex ? "" : "…")
    }
}
