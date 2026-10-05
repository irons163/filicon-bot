import Foundation

/// Display-only evidence copied from the host outbox. Decoding this value does
/// not authorize a send, source read, retry, chat mutation, or model wake.
public struct ExternalChannelTranscriptPublication: Codable, Hashable, Sendable {
    public enum Route: String, Codable, Hashable, Sendable { case directConversation, groupConversation }
    public enum Kind: String, Codable, Hashable, Sendable { case text, attachment }
    public enum Status: String, Codable, Hashable, Sendable { case queued, sending, retrying, delivered, deadLetter }
    public struct Source: Codable, Hashable, Sendable {
        public let url: String
        public let alt: String?
        public init(url: String, alt: String?) { self.url = url; self.alt = alt }
    }
    public struct File: Codable, Hashable, Sendable {
        public let digest: String
        public let filename: String
        public let mimeType: String
        public let byteCount: Int64
        public init(digest: String, filename: String, mimeType: String, byteCount: Int64) {
            self.digest = digest; self.filename = filename; self.mimeType = mimeType; self.byteCount = byteCount
        }
    }
    public struct Delivery: Codable, Hashable, Sendable {
        public let status: Status
        public let attemptCount: Int
        public let deliveredAt: Date?
        public init(status: Status, attemptCount: Int, deliveredAt: Date?) {
            self.status = status; self.attemptCount = attemptCount
            self.deliveredAt = deliveredAt.map(ExternalChannelTranscriptPublication.stableDate)
        }
    }
    public let deliveryID: UUID
    public let connectionID: UUID
    public let owner: DirectConversationAgentBinding
    public let route: Route
    public let conversationID: UUID
    public let senderID: UUID
    public let senderName: String
    public let runID: UUID
    public let callID: String
    public let replyToMessageID: UUID?
    public let queuedAt: Date
    public let kind: Kind
    public let text: String
    public let sources: [Source]
    public let files: [File]
    public let platform: String
    public let channelID: String
    /// Platform thread, never confused with the local quote above.
    public let threadID: String?
    public var delivery: Delivery

    public init(deliveryID: UUID, connectionID: UUID, owner: DirectConversationAgentBinding, route: Route,
        conversationID: UUID, senderID: UUID, senderName: String, runID: UUID, callID: String,
        replyToMessageID: UUID?, queuedAt: Date, kind: Kind, text: String, sources: [Source], files: [File],
        platform: String, channelID: String, threadID: String?, delivery: Delivery) {
        self.deliveryID = deliveryID; self.connectionID = connectionID; self.owner = owner; self.route = route
        self.conversationID = conversationID; self.senderID = senderID; self.senderName = senderName
        self.runID = runID; self.callID = callID; self.replyToMessageID = replyToMessageID
        self.queuedAt = Self.stableDate(queuedAt); self.kind = kind; self.text = text
        self.sources = sources; self.files = files; self.platform = platform
        self.channelID = channelID; self.threadID = threadID; self.delivery = delivery
    }
    private static func stableDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    public var isValid: Bool {
        guard queuedAt.timeIntervalSince1970.isFinite,
              senderID == (route == .directConversation ? conversationID : owner.agentID),
              Self.label(owner.accountID, limit: 16_384), Self.label(senderName, limit: 8_000), Self.label(callID, limit: 2_048),
              Self.label(platform, limit: 512), Self.label(channelID, limit: 512),
              threadID.map({ Self.label($0, limit: 512) }) ?? true,
              replyToMessageID != deliveryID, text.count <= 8_000, sources.count <= 64,
              sources.reduce(0, { $0 + $1.url.utf8.count + ($1.alt?.utf8.count ?? 0) }) <= 64_000,
              files.count == (sources.isEmpty ? 0 : 1), kind != .attachment || sources.count == 1,
              kind != .text || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              delivery.attemptCount >= 0,
              (delivery.status == .delivered) == (delivery.deliveredAt != nil),
              delivery.deliveredAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= queuedAt }) ?? true else { return false }
        return sources.allSatisfy { source in
            Self.label(source.url, limit: 16_384)
                && ["file", "https"].contains(URLComponents(string: source.url)?.scheme?.lowercased() ?? "")
                && (source.alt.map { Self.label($0, limit: 2_000) && $0.count <= 500 } ?? true)
        } && files.allSatisfy { file in
            file.digest.utf8.count == 64 && file.digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && Self.label(file.filename, limit: 255) && ![".", ".."].contains(file.filename)
                && !file.filename.contains("/") && !file.filename.contains("\\")
                && Self.label(file.mimeType, limit: 255) && file.byteCount >= 0 && file.byteCount <= 25 * 1_024 * 1_024
        }
    }
    private static func label(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The publication itself is immutable; only delivery evidence may advance.
    public func samePublication(as other: Self) -> Bool {
        var copy = self; copy.delivery = other.delivery
        return copy == other
    }
    public func shouldAdvance(from previous: Self) -> Bool {
        guard samePublication(as: previous), isValid, previous.isValid,
              previous.delivery.status != .delivered, previous.delivery.status != .deadLetter,
              delivery.attemptCount >= previous.delivery.attemptCount else { return false }
        if delivery.attemptCount > previous.delivery.attemptCount { return true }
        func rank(_ status: Status) -> Int {
            switch status { case .queued: 0; case .sending: 1; case .retrying: 2; case .delivered, .deadLetter: 3 }
        }
        return rank(delivery.status) > rank(previous.delivery.status)
    }
    public var transcriptCard: TranscriptCard {
        .init(id: deliveryID, lifecycle: delivery.status == .delivered ? .sent : delivery.status == .deadLetter ? .failed : .pending,
            createdAt: queuedAt, updatedAt: delivery.deliveredAt ?? queuedAt,
            payload: .widget(.init(title: "External channel message", widgetKind: "externalChannelPublication", externalPublication: self)))
    }
    public var directMessage: ChatMessage {
        .init(id: deliveryID, role: .assistant, text: text, createdAt: queuedAt,
            transcriptCards: [transcriptCard], replyToMessageID: replyToMessageID)
    }
}

extension ChatMessage {
    public var externalChannelPublication: ExternalChannelTranscriptPublication? {
        guard transcriptCards.count == 1, case .widget(let widget) = transcriptCards[0].payload,
              widget.widgetKind == "externalChannelPublication" else { return nil }
        return widget.externalPublication
    }

    /// Reactions and the host-assigned alias are intentionally not publication
    /// fields. Everything else must match before a stored receipt is reused.
    public func matchesExternalPublication(_ value: ExternalChannelTranscriptPublication) -> Bool {
        var copy = self
        copy.reactions = []; copy.shortAddress = nil
        return value.isValid && copy == value.directMessage
    }
}
