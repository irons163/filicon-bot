import Foundation

/// Immutable host snapshot for navigation, separate from the model's 40-item directory.
public struct MailboxMessageReferences: Sendable {
    public struct Destination: Sendable {
        public let message: RoomMessage
        public let incoming: AgentMessage
    }
    private let history: [AgentMessage]
    private let addresses: [UUID: String]
    private let humanInputs: Set<UUID>

    public init(history: [AgentMessage] = [], addresses: [UUID: String] = [:], humanInputs: Set<UUID> = []) {
        self.history = history; self.addresses = addresses; self.humanInputs = humanInputs
    }

    public func target(for url: URL, from publicationID: UUID, replyingTo incomingID: UUID) -> Destination? {
        guard let entries = entries(from: publicationID, replyingTo: incomingID), let first = entries.first else { return nil }
        let directory = GroupMessageReferenceDirectory(history: entries.map(\.message), groupID: first.message.groupID)
        guard let id = directory.target(for: url, from: publicationID) else { return nil }
        return destination(id, before: publicationID, entries: entries)
    }

    /// Quotes navigate only to their canonical saved target, not a caller-supplied UUID.
    public func quotedTarget(from publicationID: UUID, replyingTo incomingID: UUID) -> Destination? {
        guard let entries = entries(from: publicationID, replyingTo: incomingID),
              let publication = entries.first(where: { $0.message.id == publicationID }),
              let target = publication.message.replyToMessageID else { return nil }
        return destination(target, before: publicationID, entries: entries)
    }

    public func referenceTarget(_ id: UUID, from publicationID: UUID, replyingTo incomingID: UUID) -> Destination? {
        guard let entries = entries(from: publicationID, replyingTo: incomingID),
              let address = entries.first(where: { $0.message.id == id })?.message.shortAddress,
              let url = URL(string: "sand-msg:\(address)"),
              let destination = target(for: url, from: publicationID, replyingTo: incomingID),
              destination.message.id == id else { return nil }
        return destination
    }

    private func destination(_ id: UUID, before sourceID: UUID, entries: [Destination]) -> Destination? {
        guard entries.filter({ $0.message.id == id }).count == 1,
              let source = entries.firstIndex(where: { $0.message.id == sourceID }),
              let target = entries.firstIndex(where: { $0.message.id == id }), target < source else { return nil }
        return entries[target]
    }

    private func entries(from publicationID: UUID, replyingTo incomingID: UUID) -> [Destination]? {
        guard history.filter({ $0.id == incomingID }).count == 1,
              let incoming = history.first(where: { $0.id == incomingID }),
              let scope = incoming.delivery?.originConversationID,
              incoming.delivery?.publications?.filter({ $0.id == publicationID }).count == 1 else { return nil }
        let allIDs = history.flatMap { [$0.id] + ($0.delivery?.publications ?? []).map(\.id) }
        let counts = Dictionary(grouping: allIDs, by: { $0 }).mapValues(\.count)
        guard counts[publicationID] == 1 else { return nil }
        return history.filter {
            $0.senderID == incoming.senderID && $0.recipientID == incoming.recipientID
                && $0.delivery?.originConversationID == scope
        }.flatMap { item -> [Destination] in
            let human = humanInputs.contains(item.id) || item.questionResponse != nil || item.secretResponse != nil
            let input = RoomMessage(id: item.id, groupID: scope, senderID: human ? nil : item.senderID,
                text: item.text, createdAt: item.createdAt, images: item.images ?? [])
            return ([input] + (item.delivery?.publications ?? []).filter {
                $0.groupID == scope && $0.senderID == incoming.recipientID && $0.memberOutcome == nil
            }).filter { counts[$0.id] == 1 }.map { message in
                var addressed = message
                addressed.shortAddress = addresses[message.id]
                return Destination(message: addressed, incoming: item)
            }
        }
    }
}
