import Foundation

public actor AgentMessenger {
    private let service: AgentService
    private let storeURL: URL
    private var state: AgentPersistentState

    public init(service: AgentService, storeURL: URL) throws {
        self.service = service; self.storeURL = storeURL
        var loaded: AgentPersistentState
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            loaded = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: storeURL))
        } else { loaded = .init() }
        // An old acknowledgement is not permission to rerun work after restart.
        var recovered = false
        for index in loaded.messages.indices where loaded.messages[index].delivery?.state == .queued || loaded.messages[index].delivery?.state == .running {
            loaded.messages[index].delivery?.state = .cancelled
            recovered = true
        }
        if recovered { try Self.save(loaded, to: storeURL) }
        state = loaded
    }

    public func send(_ message: AgentMessage) async throws {
        guard message.questionResponse == nil else { throw AgentQuestionError.unavailable }
        guard message.senderID != message.recipientID else { throw AgentServiceError.selfMessage }
        guard message.text.count <= 8_000 else { throw AgentServiceError.messageTooLong }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentServiceError.invalidName }
        guard let sender = await service.profile(id: message.senderID), sender.archivedAt == nil else { throw AgentServiceError.unknownAgent(message.senderID) }
        guard let recipient = await service.profile(id: message.recipientID), recipient.archivedAt == nil else { throw AgentServiceError.unknownAgent(message.recipientID) }
        try Task.checkCancellation()
        guard !state.messages.contains(where: { $0.id == message.id }) else { throw AgentServiceError.duplicateMessage(message.id) }
        state.messages.append(message)
        do { try persist() } catch { state.messages.removeLast(); throw error }
    }

    public func dequeue(recipientID: UUID, at: Date = Date()) throws -> AgentMessage? {
        let candidates = state.messages.indices.filter { state.messages[$0].recipientID == recipientID && state.messages[$0].deliveredAt == nil }
        guard let index = candidates.sorted(by: {
            let lhs = state.messages[$0], rhs = state.messages[$1]
            if lhs.priority != rhs.priority { return lhs.priority == .priority }
            return lhs.createdAt < rhs.createdAt
        }).first else { return nil }
        let previous = state.messages[index]
        state.messages[index].deliveredAt = at
        let value = state.messages[index]
        do { try persist() } catch { state.messages[index] = previous; throw error }
        return value
    }

    public func allMessages() -> [AgentMessage] { state.messages }

    /// The mailbox is the canonical publication receipt. Its identity, author,
    /// image capability and atomic persistence are checked in the same actor turn.
    public func publish(_ publication: RoomMessage, replyingTo id: UUID, lifetime: AgentPublicationLifetime) throws {
        guard publication.question == nil else { throw AgentPublicationError.invalid }
        try publishValidated(publication, replyingTo: id, lifetime: lifetime)
    }

    /// The host supplies account/scope; the model supplies only question content.
    /// A saved question ends publication for this delivery. It is not permission
    /// to execute another turn or grant any tool access.
    public func publishQuestion(_ question: AgentQuestion, replyingTo id: UUID, accountID: String,
                                originID: UUID, publicationID: UUID = UUID(), at: Date = Date(),
                                lifetime: AgentPublicationLifetime) throws -> RoomMessage {
        try question.validate()
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              let incoming = state.messages.first(where: { $0.id == id }),
              incoming.delivery?.originConversationID == originID else { throw AgentQuestionError.unavailable }
        var publication = RoomMessage(id: publicationID, groupID: originID, senderID: incoming.recipientID,
                                      text: question.prompt, createdAt: at)
        publication.question = GroupQuestion(question: question, accountID: accountID,
                                            memberIDs: [incoming.senderID, incoming.recipientID])
        try publishValidated(publication, replyingTo: id, lifetime: lifetime)
        return publication
    }

    /// Resolving a question and queuing its response are one durable write.
    /// Caller must drain the returned message explicitly in a fresh user turn;
    /// restarting never automatically executes this queued response.
    public func answerQuestion(replyingTo id: UUID, publicationID: UUID, answer: AgentQuestionAnswer,
                               accountID: String, originID: UUID, responseID: UUID = UUID(),
                               at: Date = Date(), lifetime: AgentPublicationLifetime) async throws -> AgentMessage {
        guard let before = state.messages.first(where: { $0.id == id }) else { throw AgentQuestionError.unavailable }
        let active = await service.list()
        guard active.contains(where: { $0.id == before.senderID }),
              active.contains(where: { $0.id == before.recipientID }) else {
            throw AgentQuestionError.unavailable
        }
        var result: AgentMessage?
        try lifetime.commit {
            guard let index = state.messages.firstIndex(where: { $0.id == id }), state.messages[index] == before,
                  let delivery = before.delivery, delivery.state == .completed, delivery.originConversationID == originID,
                  let questionIndex = delivery.publications?.firstIndex(where: { $0.id == publicationID }),
                  let publication = delivery.publications?[questionIndex],
                  publication.groupID == originID, publication.senderID == before.recipientID,
                  var pending = publication.question, pending.isPending, pending.accountID == accountID,
                  pending.memberIDs == [before.senderID, before.recipientID],
                  !state.messages.contains(where: { $0.id == responseID }) else { throw AgentQuestionError.unavailable }
            let text = try pending.question.reply(for: answer)
            var response = AgentMessage(id: responseID, senderID: before.senderID, recipientID: before.recipientID,
                text: text, createdAt: at, delivery: .init(chainID: responseID, originConversationID: originID))
            response.questionResponse = .init(incomingMessageID: id, publicationID: publicationID,
                question: pending.question, answer: answer, accountID: accountID)
            pending.answer = answer
            pending.responseMessageID = responseID
            var next = state
            next.messages[index].delivery?.publications?[questionIndex].question = pending
            next.messages.append(response)
            try Self.save(next, to: storeURL)
            state = next
            result = response
        }
        guard let result else { throw AgentQuestionError.unavailable }
        return result
    }

    private func publishValidated(_ publication: RoomMessage, replyingTo id: UUID, lifetime: AgentPublicationLifetime) throws {
        try lifetime.commit {
            guard let index = state.messages.firstIndex(where: { $0.id == id }),
                  let delivery = state.messages[index].delivery,
                  delivery.state == .running,
                  publication.groupID == delivery.originConversationID,
                  publication.senderID == state.messages[index].recipientID,
                  (!publication.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(publication.images ?? []).isEmpty),
                  publication.text.count <= 8_000, publication.toolActivities.isEmpty,
                  publication.memberOutcome == nil, publication.replyToMessageID == nil,
                  publication.shortAddress == nil else { throw AgentPublicationError.invalid }
            let images = publication.images ?? []
            guard images.count <= 4, Set(images.map(\.id)).count == images.count,
                  images.allSatisfy({ image in state.messages[index].images?.contains(where: { image.isAnnotation(of: $0) }) == true }) else {
                throw AgentPublicationError.invalid
            }
            let prior = delivery.publications ?? []
            if let existing = prior.first(where: { $0.id == publication.id }) {
                guard existing == publication else { throw AgentPublicationError.invalid }
                return
            }
            guard !prior.contains(where: { $0.question != nil }) else { throw AgentQuestionError.unavailable }
            guard prior.count < 2 else { throw AgentPublicationError.limit }
            var next = state
            next.messages[index].delivery?.publications = prior + [publication]
            next.messages[index].delivery?.response = String((prior + [publication]).map(\.text).joined(separator: "\n\n").prefix(8_000))
            try Self.save(next, to: storeURL)
            state = next
        }
    }

    public func updateDelivery(id: UUID, state deliveryState: AgentMessageDelivery.State, response: String? = nil) throws {
        guard let index = state.messages.firstIndex(where: { $0.id == id }), state.messages[index].delivery != nil else { return }
        let previous = state.messages[index]
        // Terminal results cannot be resurrected by a late provider event.
        guard previous.delivery?.state == .queued || previous.delivery?.state == .running else { return }
        state.messages[index].delivery?.state = deliveryState
        // A state-only transition (especially Stop) must not erase a report
        // already published through SendMessage.
        if let publications = previous.delivery?.publications, !publications.isEmpty {
            state.messages[index].delivery?.response = String(publications.map(\.text).joined(separator: "\n\n").prefix(8_000))
        } else if let response { state.messages[index].delivery?.response = String(response.prefix(8_000)) }
        do { try persist() } catch { state.messages[index] = previous; throw error }
    }

    private func persist() throws {
        try Self.save(state, to: storeURL)
    }

    private static func save(_ state: AgentPersistentState, to storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: storeURL, options: .atomic)
    }
}

public enum AgentPublicationError: String, LocalizedError, Sendable {
    case invalid = "This publication is not valid for the active incoming agent message."
    case limit = "At most two messages may be published per agent turn."
    public var errorDescription: String? { rawValue }
}

/// Revoked synchronously by Stop/account change, before any actor hop.
public final class AgentPublicationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    public init() {}
    public func close() { lock.withLock { active = false } }
    func commit(_ operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
        }
    }
}
