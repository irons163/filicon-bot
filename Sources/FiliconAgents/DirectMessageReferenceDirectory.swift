import Foundation
import FiliconDomain

/// Host-only index over a complete direct conversation, never a model prompt window.
/// Partial histories fail closed because an unseen row may duplicate an address.
public struct DirectMessageReferenceDirectory: Sendable {
    private let conversationID: UUID
    private let directory: GroupMessageReferenceDirectory

    public init(conversation: Conversation, historyComplete: Bool) {
        conversationID = conversation.id
        let reservations = conversation.messageAddressReservations
        let owners = Dictionary(grouping: reservations, by: \.value).mapValues { $0.map(\.key) }
        let rows: [RoomMessage] = historyComplete ? conversation.messages.map { message in
            var row = RoomMessage(
                id: message.id, groupID: conversation.id,
                senderID: message.role == .user ? nil : conversation.id,
                text: message.text, remoteAttachment: message.remoteAttachment)
            // Keep every row/address for duplicate detection, including invalid roles.
            row.shortAddress = message.shortAddress
            let address = message.shortAddress
            let owner = message.id.uuidString
            let reservationMatches = reservations[owner] == nil || reservations[owner] == address
            let uniquelyOwned = address.map { owners[$0] == nil || owners[$0] == [owner] } ?? true
            if (message.role != .user && message.role != .assistant)
                || !reservationMatches || !uniquelyOwned {
                row.memberOutcome = .failed
            }
            return row
        } : []
        directory = GroupMessageReferenceDirectory(history: rows, groupID: conversation.id)
    }

    public func target(for url: URL, from messageID: UUID, in conversationID: UUID) -> UUID? {
        guard conversationID == self.conversationID else { return nil }
        return directory.target(for: url, from: messageID)
    }
}
