import Foundation
import FiliconDomain

/// A hit from the recovered global transcript search contract.
///
/// Filicon's canonical identifiers intentionally map `conversationID` to the
/// recovered `agentId` and `messageID` to the recovered `entryId`. There is no
/// inferred AgentProfile relationship.
public struct GlobalMessageSearchHit: Hashable, Sendable {
    public let conversationID: UUID
    public let messageID: UUID
    public let role: MessageRole
    public let timestamp: Date
    public let snippet: String

    public init(conversationID: UUID, messageID: UUID, role: MessageRole, timestamp: Date, snippet: String) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.role = role
        self.timestamp = timestamp
        self.snippet = snippet
    }
}

public struct GlobalMediaSearchHit: Hashable, Sendable {
    public let conversationID: UUID
    public let messageID: UUID
    public let attachmentID: String
    public let name: String
    public let mimeType: String
    public let kind: AttachmentKind
    public let timestamp: Date
    public let width: Int?
    public let height: Int?

    public init(
        conversationID: UUID,
        messageID: UUID,
        attachmentID: String,
        name: String,
        mimeType: String,
        kind: AttachmentKind,
        timestamp: Date,
        width: Int? = nil,
        height: Int? = nil
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.attachmentID = attachmentID
        self.name = name
        self.mimeType = mimeType
        self.kind = kind
        self.timestamp = timestamp
        self.width = width
        self.height = height
    }
}

public enum GlobalSearchLimits {
    public static let maximumTerms = 8
    public static let maximumIndexedBodyCharacters = 20_000
    public static let maximumPerConversation = 5
    public static let maximumResults = 50
    public static let maximumFallbackConversations = 500
    public static let maximumFallbackMessages = 10_000
}

public enum GlobalSearchIndexReadiness: String, Hashable, Sendable {
    case ready
    case notReady
}

enum GlobalSearchQuery {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: { $0.isWhitespace })
            .prefix(GlobalSearchLimits.maximumTerms)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func fts(_ query: String) -> String {
        terms(query).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }

    static func boundedBody(_ body: String) -> String {
        String(body.prefix(GlobalSearchLimits.maximumIndexedBodyCharacters))
    }

    static func snippet(body: String, terms: [String], maximum: Int = 240) -> String {
        let bounded = boundedBody(body)
        guard !bounded.isEmpty else { return "" }
        let lower = bounded.lowercased()
        let locations = terms.compactMap { lower.range(of: $0.lowercased())?.lowerBound }
        let start: String.Index
        if let first = locations.min() {
            start = bounded.index(first, offsetBy: -min(60, bounded.distance(from: bounded.startIndex, to: first)))
        } else {
            start = bounded.startIndex
        }
        let end = bounded.index(start, offsetBy: min(maximum, bounded.distance(from: start, to: bounded.endIndex)))
        let prefix = start == bounded.startIndex ? "" : "…"
        let suffix = end == bounded.endIndex ? "" : "…"
        return prefix + bounded[start..<end].replacingOccurrences(of: "\n", with: " ") + suffix
    }
}
