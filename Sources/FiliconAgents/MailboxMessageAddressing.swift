import Foundation

/// Uses the source's tNu/tNsM syntax, but keeps each directed mailbox separate.
/// Allocation always sees the full durable log, never a model's bounded context.
enum MailboxMessageAddressing {
    private struct Scope: Hashable {
        let origin: UUID
        let sender: UUID
        let recipient: UUID
    }

    static func isHuman(_ message: AgentMessage, in state: AgentPersistentState) -> Bool {
        state.mailboxHumanInputs.contains(message.id)
            || message.questionResponse != nil || message.secretResponse != nil
    }

    @discardableResult
    static func assignMissing(in state: inout AgentPersistentState) -> Bool {
        let previous = state.mailboxAddresses
        let ids = state.messages.flatMap { [$0.id] + ($0.delivery?.publications ?? []).map(\.id) }
        let counts = Dictionary(grouping: ids, by: { $0 }).mapValues(\.count)
        var timelines: [Scope: [RoomMessage]] = [:]
        for message in state.messages {
            guard let delivery = message.delivery else { continue }
            let scope = Scope(origin: delivery.originConversationID, sender: message.senderID, recipient: message.recipientID)
            var input = RoomMessage(id: message.id, groupID: scope.origin,
                senderID: isHuman(message, in: state) ? nil : message.senderID,
                text: message.text, createdAt: message.createdAt, images: message.images ?? [])
            input.shortAddress = previous[input.id]
            var items = [input] + (delivery.publications ?? []).filter {
                $0.groupID == scope.origin && $0.senderID == scope.recipient && $0.memberOutcome == nil
            }
            for index in items.indices {
                items[index].shortAddress = previous[items[index].id] ?? items[index].shortAddress
            }
            timelines[scope, default: []].append(contentsOf: items.filter { counts[$0.id] == 1 })
        }
        for var timeline in timelines.values {
            GroupMessageAddressing.assignMissing(in: &timeline)
            for message in timeline {
                if let address = message.shortAddress { state.mailboxAddresses[message.id] = address }
            }
        }
        return previous != state.mailboxAddresses
    }
}
