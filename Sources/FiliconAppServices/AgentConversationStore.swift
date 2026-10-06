import Foundation
import FiliconDomain
import FiliconPersistence

/// Durable peer context, not a permission store. Histories are isolated by
/// account, originating conversation, and agent; reopening a mailbox must never
/// import another group's private messages or revive an old tool approval.
public actor AgentConversationStore {
    public struct Context: Codable, Equatable, Sendable {
        public let conversationID: UUID
        public var messages: [ChatMessage]
        /// Host-verified visible chat only. The inference/thread ID and private
        /// history remain isolated by origin, even when the agent already has a DM.
        public var projectionConversationID: UUID? = nil
        public var transcriptConversationID: UUID { projectionConversationID ?? conversationID }
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
        /// Optional so older stores decode without silently resetting history.
        var retiredProjectionIDs: Set<UUID>?
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

    /// Read-only origin evidence for a new human card response. This neither
    /// creates a mailbox nor grants a publisher or restores a prior approval.
    public func mailboxParticipants(accountID: String, originID: UUID) -> [UUID]? {
        let matches = state.mailboxes.filter { $0.conversationID == originID }
        guard matches.count == 1, let mailbox = matches.first, mailbox.accountID == accountID,
              mailbox.participants.count == 2, Set(mailbox.participants).count == 2,
              mailbox.participants == mailbox.participants.sorted(by: { $0.uuidString < $1.uuidString }),
              !isProjectionRetired(conversationID: originID) else { return nil }
        return mailbox.participants
    }

    /// Display classification only, including retired or invalid namespaces.
    /// It cannot establish ownership, create a context or authorize a response.
    public func mailboxOriginIDs(accountID: String) -> Set<UUID> {
        Set(state.mailboxes.filter { $0.accountID == accountID }.map(\.conversationID))
    }

    /// Unlike context(), inspection must not invent a private thread or claim
    /// a canonical chat when validating a saved card after reopening.
    public func existingContext(accountID: String, originID: UUID, agentID: UUID) -> Context? {
        let matches = state.records.filter { $0.accountID == accountID && $0.originID == originID && $0.agentID == agentID }
        return matches.count == 1 ? matches.first?.context : nil
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

    public func isProjectionRetired(conversationID: UUID) -> Bool {
        state.retiredProjectionIDs?.contains(conversationID) == true
    }

    /// Called only after the host resolves and leases the unique durable agent
    /// binding. A stale context, retired chat or different prior claim fails
    /// closed; no history is imported and no prior claim is silently replaced.
    public func bindProjection(accountID: String, originID: UUID, agentID: UUID,
                               expectedContextID: UUID, conversationID: UUID,
                               commit: ConversationCommitGuard = { try $0() }) throws -> Context {
        guard let index = state.records.firstIndex(where: {
            $0.accountID == accountID && $0.originID == originID && $0.agentID == agentID
        }), state.records[index].context.conversationID == expectedContextID,
            !isProjectionRetired(conversationID: originID),
            !isProjectionRetired(conversationID: expectedContextID),
            !isProjectionRetired(conversationID: conversationID) else { throw CancellationError() }
        let current = state.records[index].context
        guard current.projectionConversationID == nil || current.projectionConversationID == conversationID else {
            throw CancellationError()
        }
        if current.projectionConversationID == conversationID { try commit {}; return current }
        var next = state
        next.records[index].context.projectionConversationID = conversationID
        try commit { try save(next) }
        return state.records[index].context
    }

    /// Persist before deleting a bound chat. Canonical mailbox/context history
    /// remains intact, but projection and recovery must not resurrect its UI.
    public func retireProjection(conversationID: UUID) throws {
        guard !isProjectionRetired(conversationID: conversationID) else { return }
        var next = state
        next.retiredProjectionIDs = (next.retiredProjectionIDs ?? []).union([conversationID])
        try save(next)
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
