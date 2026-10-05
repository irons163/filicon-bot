import Foundation

/// Native transcript bookkeeping, never an inference or execution permission.
/// Kept outside Conversation snapshots so saving stale content cannot mark it read.
public struct ConversationUnreadState: Codable, Hashable, Sendable {
    public private(set) var lastActivityAt: Date
    public private(set) var lastViewedAt: Date
    public private(set) var isManuallyUnread: Bool
    public private(set) var unreadCount: Int

    public init(lastActivityAt: Date = Date(timeIntervalSince1970: 0),
                lastViewedAt: Date = Date(timeIntervalSince1970: 0),
                isManuallyUnread: Bool = false, unreadCount: Int = 0) {
        self.lastActivityAt = lastActivityAt.timeIntervalSince1970.isFinite ? lastActivityAt : Date(timeIntervalSince1970: 0)
        self.lastViewedAt = lastViewedAt.timeIntervalSince1970.isFinite ? lastViewedAt : Date(timeIntervalSince1970: 0)
        self.isManuallyUnread = isManuallyUnread
        self.unreadCount = max(0, unreadCount)
    }

    /// Several newly published messages can share one atomic native save.
    /// A replay or an older arrival cannot advance the timestamp or count.
    @discardableResult
    public mutating func markActivity(at: Date, count: Int = 1) -> Bool {
        guard at.timeIntervalSince1970.isFinite, at > lastActivityAt, count > 0 else { return false }
        lastActivityAt = at
        let (sum, overflow) = unreadCount.addingReportingOverflow(count)
        unreadCount = overflow ? Int.max : sum
        return true
    }

    @discardableResult
    public mutating func markViewed(at: Date, preserveManualUnread: Bool = true) -> Bool {
        guard at.timeIntervalSince1970.isFinite, !(preserveManualUnread && isManuallyUnread),
              isManuallyUnread || at > lastViewedAt else { return false }
        lastViewedAt = max(lastViewedAt, at)
        isManuallyUnread = false
        unreadCount = 0
        return true
    }

    @discardableResult
    public mutating func markRead(at: Date) -> Bool {
        guard at.timeIntervalSince1970.isFinite else { return false }
        let before = self
        lastViewedAt = max(lastViewedAt, lastActivityAt, at)
        isManuallyUnread = false
        unreadCount = 0
        return self != before
    }

    @discardableResult
    public mutating func markUnread(at: Date, newestMessageAt: Date? = nil) -> Bool {
        guard at.timeIntervalSince1970.isFinite else { return false }
        let before = self
        if lastActivityAt == Date(timeIntervalSince1970: 0) { lastActivityAt = at }
        // The reference uses a one-millisecond boundary before the newest divider.
        lastViewedAt = min(lastViewedAt, lastActivityAt.addingTimeInterval(-0.001), at.addingTimeInterval(-0.001))
        if let newestMessageAt, newestMessageAt.timeIntervalSince1970.isFinite,
           newestMessageAt > Date(timeIntervalSince1970: 0) {
            lastViewedAt = min(lastViewedAt, newestMessageAt.addingTimeInterval(-0.001))
        }
        isManuallyUnread = true
        unreadCount = max(unreadCount, 1)
        return self != before
    }

    private enum CodingKeys: String, CodingKey { case lastActivityAt, lastViewedAt, isManuallyUnread, unreadCount }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let activity = try values.decode(Date.self, forKey: .lastActivityAt)
        let viewed = try values.decode(Date.self, forKey: .lastViewedAt)
        let count = try values.decode(Int.self, forKey: .unreadCount)
        guard activity.timeIntervalSince1970.isFinite, viewed.timeIntervalSince1970.isFinite, count >= 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid conversation unread state"))
        }
        self.init(lastActivityAt: activity, lastViewedAt: viewed,
            isManuallyUnread: try values.decode(Bool.self, forKey: .isManuallyUnread), unreadCount: count)
    }
}

/// Host-only user bookkeeping action. Not part of a model tool or import payload.
public enum ConversationReadAction: Sendable {
    case viewed(preserveManualUnread: Bool)
    case read
    case unread
}

extension ChatMessage {
    /// Mirrors reference message/send-message/user-attachment arrivals, excluding
    /// peer incoming traffic, unfinished drafts and bookkeeping-only cards.
    public func raisesConversationActivity(conversationID: UUID, binding: DirectConversationAgentBinding?) -> Bool {
        guard [.user, .assistant].contains(role), deliveryStatus == .succeeded else { return false }
        if let source = agentMessageSource {
            guard source.kind == .publication, let binding,
                  binding.accountID == source.accountID, binding.agentID == source.authorAgentID else { return false }
        }
        if let external = externalChannelPublication,
           external.route == .directConversation, external.conversationID == conversationID,
           external.owner == binding, matchesExternalPublication(external) { return true }
        if transcriptCards.contains(where: { card in
            guard case .secretRequest(let secret) = card.payload, let request = secret.directRequest, let binding else { return false }
            return request.binding == binding && request.conversationID == conversationID
        }) { return true }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty || remoteAttachment != nil || remoteImages != nil
    }
}
