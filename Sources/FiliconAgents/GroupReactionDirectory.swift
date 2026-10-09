import Foundation

public struct GroupReactionDirectory: Sendable {
    public struct Entry: Encodable, Equatable, Sendable {
        public let message_address: String
        public let sender: String
        public let excerpt: String
        fileprivate let messageID: UUID
        private enum CodingKeys: String, CodingKey { case message_address, sender, excerpt }
    }
    public let entries: [Entry]

    public init(history: [RoomMessage], groupID: UUID, actorID: UUID) {
        let messages = history.filter { $0.groupID == groupID }
        let idCounts = Dictionary(grouping: history, by: \.id).mapValues(\.count)
        let addressCounts = Dictionary(grouping: messages.compactMap(\.shortAddress), by: { $0 }).mapValues(\.count)
        entries = messages.suffix(40).compactMap { message in
            guard idCounts[message.id] == 1, message.memberOutcome == nil, message.routineWake == nil,
                  message.senderID != actorID, let address = message.shortAddress,
                  addressCounts[address] == 1, GroupMessageAddressing.isValid(address, for: message),
                  !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(message.images ?? []).isEmpty || !(message.files ?? []).isEmpty
                    || message.remoteAttachment != nil || message.externalPublication != nil
            else { return nil }
            return Entry(message_address: address, sender: message.senderID.map { "agent:\($0.uuidString)" } ?? "user",
                excerpt: String(message.text.prefix(240)), messageID: message.id)
        }
    }

    public func messageID(for address: String) -> UUID? { entries.first { $0.message_address == address }?.messageID }
    public func contains(_ messageID: UUID) -> Bool { entries.contains { $0.messageID == messageID } }
}
