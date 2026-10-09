import Foundation

public enum MessageReactionEmoji {
    public static func isValid(_ value: String) -> Bool {
        guard value.count == 1, value.utf16.count <= 16 else { return false }
        return value.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (value.unicodeScalars.contains { $0.value == 0xFE0F } && value.unicodeScalars.contains { $0.properties.isEmoji })
    }
}

public struct DirectReactionDirectory: Sendable {
    public struct Entry: Encodable, Equatable, Sendable {
        public let message_address: String
        public let sender: String
        public let excerpt: String
        fileprivate let messageID: UUID
        private enum CodingKeys: String, CodingKey { case message_address, sender, excerpt }
    }
    public let conversationID: UUID
    public let entries: [Entry]

    public init(conversation: Conversation, historyComplete: Bool) {
        conversationID = conversation.id
        let history = historyComplete ? conversation.messages : []
        let idCounts = Dictionary(grouping: history, by: \.id).mapValues(\.count)
        let addressCounts = Dictionary(grouping: history.compactMap(\.shortAddress), by: { $0 }).mapValues(\.count)
        let reservations = conversation.messageAddressReservations
        let owners = Dictionary(grouping: reservations, by: \.value).mapValues { $0.map(\.key) }
        entries = history.suffix(40).compactMap { message in
            guard message.role == .user, message.deliveryStatus == .succeeded,
                  message.agentMessageSource == nil, message.transcriptCards.isEmpty,
                  message.toolActivities.isEmpty, message.reasoningText.isEmpty,
                  idCounts[message.id] == 1, let address = message.shortAddress,
                  addressCounts[address] == 1, DirectMessageAddressing.isValid(address, for: message),
                  reservations[message.id.uuidString] == nil || reservations[message.id.uuidString] == address,
                  owners[address] == nil || owners[address] == [message.id.uuidString],
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !message.attachments.isEmpty || message.remoteAttachment != nil || message.remoteImages != nil
            else { return nil }
            return Entry(message_address: address, sender: "user", excerpt: String(message.text.prefix(240)), messageID: message.id)
        }
    }

    public func messageID(for address: String, in conversationID: UUID) -> UUID? {
        guard conversationID == self.conversationID else { return nil }
        return entries.first { $0.message_address == address }?.messageID
    }

    public func contains(_ messageID: UUID) -> Bool { entries.contains { $0.messageID == messageID } }
}

public struct DirectReactionMutation: Equatable, Sendable {
    public let message: ChatMessage
    public let applied: Bool
    public init(message: ChatMessage, applied: Bool) { self.message = message; self.applied = applied }
}
