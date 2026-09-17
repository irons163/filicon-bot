import Foundation
import FiliconDomain

/// Durable peer context, not a permission store. Histories are isolated by
/// account, originating conversation, and agent; reopening a mailbox must never
/// import another group's private messages or revive an old tool approval.
public actor AgentConversationStore {
    public struct Context: Codable, Equatable, Sendable {
        public let conversationID: UUID
        public var messages: [ChatMessage]
    }

    private struct Record: Codable {
        let accountID: String
        let originID: UUID
        let agentID: UUID
        var context: Context
    }
    private struct Mailbox: Codable {
        let accountID: String
        let participants: [UUID]
        let conversationID: UUID
    }
    private struct State: Codable {
        var records: [Record] = []
        var mailboxes: [Mailbox] = []
    }

    private let url: URL
    private var state: State
    private let makeID: @Sendable () -> UUID

    public init(url: URL, makeID: @escaping @Sendable () -> UUID = { UUID() }) throws {
        self.url = url
        self.makeID = makeID
        state = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode(State.self, from: Data(contentsOf: url)) : State()
    }

    public func mailboxScope(accountID: String, senderID: UUID, recipientID: UUID) throws -> UUID {
        let participants = [senderID, recipientID].sorted { $0.uuidString < $1.uuidString }
        if let mailbox = state.mailboxes.first(where: { $0.accountID == accountID && $0.participants == participants }) {
            return mailbox.conversationID
        }
        let mailbox = Mailbox(accountID: accountID, participants: participants, conversationID: makeID())
        var next = state
        next.mailboxes.append(mailbox)
        try save(next)
        return mailbox.conversationID
    }

    public func context(accountID: String, originID: UUID, agentID: UUID) throws -> Context {
        if let record = state.records.first(where: { $0.accountID == accountID && $0.originID == originID && $0.agentID == agentID }) {
            return record.context
        }
        let context = Context(conversationID: makeID(), messages: [])
        var next = state
        next.records.append(.init(accountID: accountID, originID: originID, agentID: agentID, context: context))
        try save(next)
        return context
    }

    public func appendExchange(accountID: String, originID: UUID, agentID: UUID, incoming: ChatMessage, response: String) throws {
        _ = try context(accountID: accountID, originID: originID, agentID: agentID)
        guard let index = state.records.firstIndex(where: { $0.accountID == accountID && $0.originID == originID && $0.agentID == agentID }) else { return }
        // A repeated completion cannot duplicate the same inbound exchange.
        guard !state.records[index].context.messages.contains(where: { $0.id == incoming.id }) else { return }
        var next = state
        next.records[index].context.messages += [
            .init(id: incoming.id, role: .assistant, text: String(incoming.text.prefix(10_000)), createdAt: incoming.createdAt),
            .init(role: .assistant, text: String(response.prefix(8_000)))
        ]
        next.records[index].context.messages = Array(next.records[index].context.messages.suffix(30))
        try save(next)
    }

    private func save(_ next: State) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        state = next
    }
}
