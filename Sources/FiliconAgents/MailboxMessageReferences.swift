import Foundation

/// Immutable host snapshot for navigation, separate from the model's 40-item directory.
public struct MailboxMessageReferences: Sendable {
    public struct Destination: Sendable {
        public let message: RoomMessage
        public let incoming: AgentMessage
    }
    private struct Scope: Hashable, Sendable {
        let origin: UUID
        let sender: UUID
        let recipient: UUID
    }
    private struct Index: Sendable {
        let entries: [Destination]
        let positions: [UUID: Int]
        let directory: GroupMessageReferenceDirectory
    }
    private let scopes: [UUID: Scope]
    private let indexes: [Scope: Index]

    public init(history: [AgentMessage] = [], addresses: [UUID: String] = [:], humanInputs: Set<UUID> = []) {
        // Count across *all* scopes, including invalid publications: a duplicate identity
        // must not become navigable merely because the other copy is filtered out.
        var counts: [UUID: Int] = [:]
        for item in history {
            counts[item.id, default: 0] += 1
            for publication in item.delivery?.publications ?? [] {
                counts[publication.id, default: 0] += 1
            }
        }
        var scopes: [UUID: Scope] = [:]
        var entries: [Scope: [Destination]] = [:]
        for item in history {
            guard let origin = item.delivery?.originConversationID else { continue }
            let scope = Scope(origin: origin, sender: item.senderID, recipient: item.recipientID)
            if counts[item.id] == 1 { scopes[item.id] = scope }
            let human = humanInputs.contains(item.id) || item.questionResponse != nil || item.secretResponse != nil
            let input = RoomMessage(id: item.id, groupID: origin, senderID: human ? nil : item.senderID,
                text: item.text, createdAt: item.createdAt, images: item.images ?? [])
            let publications = (item.delivery?.publications ?? []).filter {
                $0.groupID == origin && $0.senderID == item.recipientID && $0.memberOutcome == nil
            }
            for var message in [input] + publications where counts[message.id] == 1 {
                message.shortAddress = addresses[message.id]
                entries[scope, default: []].append(Destination(message: message, incoming: item))
            }
        }
        self.scopes = scopes
        self.indexes = entries.mapValues { destinations in
            Index(entries: destinations,
                  positions: Dictionary(uniqueKeysWithValues: destinations.enumerated().map { ($0.element.message.id, $0.offset) }),
                  directory: GroupMessageReferenceDirectory(history: destinations.map(\.message), groupID: destinations[0].message.groupID))
        }
    }

    public func target(for url: URL, from publicationID: UUID, replyingTo incomingID: UUID) -> Destination? {
        guard let index = index(from: publicationID, replyingTo: incomingID),
              let id = index.directory.target(for: url, from: publicationID) else { return nil }
        return destination(id, before: publicationID, index: index)
    }

    /// Quotes navigate only to their canonical saved target, not a caller-supplied UUID.
    public func quotedTarget(from publicationID: UUID, replyingTo incomingID: UUID) -> Destination? {
        guard let index = index(from: publicationID, replyingTo: incomingID),
              let position = index.positions[publicationID],
              let target = index.entries[position].message.replyToMessageID else { return nil }
        return destination(target, before: publicationID, index: index)
    }

    public func referenceTarget(_ id: UUID, from publicationID: UUID, replyingTo incomingID: UUID) -> Destination? {
        guard let index = index(from: publicationID, replyingTo: incomingID),
              let position = index.positions[id],
              let address = index.entries[position].message.shortAddress,
              let url = URL(string: "sand-msg:\(address)"),
              index.directory.target(for: url, from: publicationID) == id else { return nil }
        return destination(id, before: publicationID, index: index)
    }

    private func destination(_ id: UUID, before sourceID: UUID, index: Index) -> Destination? {
        guard let source = index.positions[sourceID],
              let target = index.positions[id], target < source else { return nil }
        return index.entries[target]
    }

    private func index(from publicationID: UUID, replyingTo incomingID: UUID) -> Index? {
        guard publicationID != incomingID, let scope = scopes[incomingID],
              let index = indexes[scope], let position = index.positions[publicationID],
              index.entries[position].incoming.id == incomingID else { return nil }
        return index
    }
}
