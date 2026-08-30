import Foundation
import FiliconDomain

/// Identifies one pagination request chain. A consumer can reject a page whose
/// fence no longer matches its latest request without inspecting page contents.
public struct PaginationFence: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ConversationCursor: Codable, Hashable, Sendable {
    public let updatedAt: Date
    public let id: UUID

    public init(updatedAt: Date, id: UUID) {
        self.updatedAt = updatedAt
        self.id = id
    }
}

public struct ConversationPageRequest: Codable, Hashable, Sendable {
    public let fence: PaginationFence
    public let after: ConversationCursor?
    public let limit: Int

    public init(fence: PaginationFence = PaginationFence(), after: ConversationCursor? = nil, limit: Int = 50) {
        self.fence = fence
        self.after = after
        self.limit = limit
    }
}

public struct ConversationPage: Codable, Hashable, Sendable {
    public let fence: PaginationFence
    /// Metadata-only conversations, newest first. `messages` is always empty.
    public let items: [Conversation]
    public let nextCursor: ConversationCursor?
    public let hasMore: Bool

    public init(fence: PaginationFence, items: [Conversation], nextCursor: ConversationCursor?, hasMore: Bool) {
        self.fence = fence
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct MessageCursor: Codable, Hashable, Sendable {
    public let ordinal: Int
    public let id: UUID

    public init(ordinal: Int, id: UUID) {
        self.ordinal = ordinal
        self.id = id
    }
}

public struct MessagePageRequest: Codable, Hashable, Sendable {
    public let fence: PaginationFence
    public let before: MessageCursor?
    public let limit: Int

    public init(fence: PaginationFence = PaginationFence(), before: MessageCursor? = nil, limit: Int = 100) {
        self.fence = fence
        self.before = before
        self.limit = limit
    }
}

public struct MessagePage: Codable, Hashable, Sendable {
    public let fence: PaginationFence
    /// Messages are chronological within each page even though pages travel
    /// backwards from the newest message.
    public let items: [ChatMessage]
    public let nextCursor: MessageCursor?
    public let hasMore: Bool

    public init(fence: PaginationFence, items: [ChatMessage], nextCursor: MessageCursor?, hasMore: Bool) {
        self.fence = fence
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
