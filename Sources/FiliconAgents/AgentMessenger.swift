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
        for index in loaded.messages.indices {
            guard var publications = loaded.messages[index].delivery?.publications else { continue }
            for item in publications.indices where publications[item].secretRequest?.isPending == true {
                publications[item].secretRequest?.state = .retired
                recovered = true
            }
            loaded.messages[index].delivery?.publications = publications
        }
        let addressed = MailboxMessageAddressing.assignMissing(in: &loaded)
        if recovered || addressed { try Self.save(loaded, to: storeURL) }
        state = loaded
    }

    public func send(_ message: AgentMessage) async throws {
        try await sendValidated(message, movingOnAccount: nil, lifetime: .init())
    }

    /// Only a new human message retires dismiss-on-move-on questions. Peer sends
    /// never do. Retirement and enqueue share one atomic write and stop fence.
    public func sendUserMessage(_ message: AgentMessage, accountID: String,
                                lifetime: AgentPublicationLifetime) async throws {
        guard !accountID.isEmpty, message.delivery?.originConversationID != nil else {
            throw AgentQuestionError.unavailable
        }
        try await sendValidated(message, movingOnAccount: accountID, lifetime: lifetime)
    }

    private func sendValidated(_ message: AgentMessage, movingOnAccount: String?,
                               lifetime: AgentPublicationLifetime) async throws {
        guard message.questionResponse == nil, message.secretResponse == nil else { throw AgentQuestionError.unavailable }
        guard message.senderID != message.recipientID else { throw AgentServiceError.selfMessage }
        guard message.text.count <= 8_000 else { throw AgentServiceError.messageTooLong }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentServiceError.invalidName }
        guard let sender = await service.profile(id: message.senderID), sender.archivedAt == nil else { throw AgentServiceError.unknownAgent(message.senderID) }
        guard let recipient = await service.profile(id: message.recipientID), recipient.archivedAt == nil else { throw AgentServiceError.unknownAgent(message.recipientID) }
        try Task.checkCancellation()
        guard !containsMessageID(message.id) else { throw AgentServiceError.duplicateMessage(message.id) }
        try lifetime.commit {
            var next = state
            if let movingOnAccount {
                for index in next.messages.indices where next.messages[index].delivery?.originConversationID == message.delivery?.originConversationID {
                    guard var publications = next.messages[index].delivery?.publications else { continue }
                    for item in publications.indices {
                        if let secret = publications[item].secretRequest, secret.isPending,
                           secret.accountID == movingOnAccount {
                            publications[item].secretRequest?.state = .retired
                        }
                        if let question = publications[item].question, question.isPending,
                           question.accountID == movingOnAccount, question.question.dismissOnMoveOn == true {
                            publications[item].question?.retired = true
                        }
                    }
                    next.messages[index].delivery?.publications = publications
                }
            }
            next.messages.append(message)
            if movingOnAccount != nil { next.mailboxHumanInputs.insert(message.id) }
            MailboxMessageAddressing.assignMissing(in: &next)
            try Self.save(next, to: storeURL)
            state = next
        }
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

    /// Messages and navigation metadata are captured in the same actor turn.
    public func navigationSnapshot() -> (messages: [AgentMessage], references: MailboxMessageReferences) {
        (state.messages, .init(history: state.messages, addresses: state.mailboxAddresses,
                               humanInputs: state.mailboxHumanInputs))
    }

    /// The mailbox is the canonical publication receipt. Its identity, author,
    /// image capability and atomic persistence are checked in the same actor turn.
    @discardableResult
    public func publish(_ publication: RoomMessage, replyingTo id: UUID, lifetime: AgentPublicationLifetime) throws -> RoomMessage {
        guard publication.question == nil, publication.secretRequest == nil else { throw AgentPublicationError.invalid }
        try publishValidated(publication, replyingTo: id, lifetime: lifetime)
        return addressedReceipt(publication)
    }

    /// The host supplies account/scope; the model supplies only question content.
    /// A saved question ends publication for this delivery. It is not permission
    /// to execute another turn or grant any tool access.
    public func publishQuestion(_ question: AgentQuestion, replyingTo id: UUID, accountID: String,
                                originID: UUID, publicationID: UUID = UUID(), at: Date = Date(),
                                replyToMessageID: UUID? = nil,
                                lifetime: AgentPublicationLifetime) throws -> RoomMessage {
        try question.validate()
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              let incoming = state.messages.first(where: { $0.id == id }),
              incoming.delivery?.originConversationID == originID else { throw AgentQuestionError.unavailable }
        var publication = RoomMessage(id: publicationID, groupID: originID, senderID: incoming.recipientID,
                                      text: question.prompt, createdAt: at)
        publication.question = GroupQuestion(question: question, accountID: accountID,
                                            memberIDs: [incoming.senderID, incoming.recipientID])
        publication.replyToMessageID = replyToMessageID
        try publishValidated(publication, replyingTo: id, lifetime: lifetime)
        return addressedReceipt(publication)
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
                  !containsMessageID(responseID) else { throw AgentQuestionError.unavailable }
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
            MailboxMessageAddressing.assignMissing(in: &next)
            try Self.save(next, to: storeURL)
            state = next
            result = response
        }
        guard let result else { throw AgentQuestionError.unavailable }
        return result
    }

    public func publishSecretRequest(_ request: AgentSecretRequest, replyingTo id: UUID, accountID: String,
                                     originID: UUID, connectionID: UUID, publicationID: UUID = UUID(),
                                     at: Date = Date(), replyToMessageID: UUID? = nil,
                                     lifetime: AgentPublicationLifetime) throws -> RoomMessage {
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              let incoming = state.messages.first(where: { $0.id == id }),
              incoming.delivery?.originConversationID == originID else { throw AgentSecretRequestError.unavailable }
        var publication = RoomMessage(id: publicationID, groupID: originID, senderID: incoming.recipientID,
            text: "Requested a credential securely: \(request.label)", createdAt: at)
        publication.secretRequest = .init(request: request, accountID: accountID,
            memberIDs: [incoming.senderID, incoming.recipientID], connectionID: connectionID)
        publication.replyToMessageID = replyToMessageID
        try publishValidated(publication, replyingTo: id, lifetime: lifetime)
        return addressedReceipt(publication)
    }

    public func resolveSecretRequest(replyingTo id: UUID, publicationID: UUID, provided: Bool,
                                     accountID: String, originID: UUID, connectionID: UUID,
                                     responseID: UUID = UUID(), at: Date = Date(),
                                     lifetime: AgentPublicationLifetime) async throws -> AgentMessage {
        guard let before = state.messages.first(where: { $0.id == id }) else { throw AgentSecretRequestError.unavailable }
        let active = await service.list()
        guard active.contains(where: { $0.id == before.senderID }),
              active.contains(where: { $0.id == before.recipientID }) else { throw AgentSecretRequestError.unavailable }
        var result: AgentMessage?
        try lifetime.commit {
            guard let index = state.messages.firstIndex(where: { $0.id == id }), state.messages[index] == before,
                  let delivery = before.delivery, delivery.state == .completed, delivery.originConversationID == originID,
                  let item = delivery.publications?.firstIndex(where: { $0.id == publicationID }),
                  let publication = delivery.publications?[item],
                  publication.groupID == originID, publication.senderID == before.recipientID,
                  var pending = publication.secretRequest, pending.isPending, pending.accountID == accountID,
                  pending.connectionID == connectionID, pending.memberIDs == [before.senderID, before.recipientID],
                  !containsMessageID(responseID) else { throw AgentSecretRequestError.unavailable }
            let provenance = MailboxSecretResponse(incomingMessageID: id, publicationID: publicationID,
                accountID: accountID, provided: provided)
            var response = AgentMessage(id: responseID, senderID: before.senderID, recipientID: before.recipientID,
                text: provenance.acknowledgement, createdAt: at,
                delivery: .init(chainID: responseID, originConversationID: originID))
            response.secretResponse = provenance
            pending.state = provided ? .stored : .dismissed
            pending.responseMessageID = responseID
            var next = state
            next.messages[index].delivery?.publications?[item].secretRequest = pending
            next.messages.append(response)
            MailboxMessageAddressing.assignMissing(in: &next)
            try Self.save(next, to: storeURL)
            state = next
            result = response
        }
        guard let result else { throw AgentSecretRequestError.unavailable }
        return result
    }

    public func retireSecretRequests(accountID: String, originID: UUID, lifetime: AgentPublicationLifetime) throws {
        try lifetime.commit {
            var next = state
            for index in next.messages.indices where next.messages[index].delivery?.originConversationID == originID {
                guard var publications = next.messages[index].delivery?.publications else { continue }
                for item in publications.indices where publications[item].secretRequest?.accountID == accountID
                    && publications[item].secretRequest?.isPending == true {
                    publications[item].secretRequest?.state = .retired
                }
                next.messages[index].delivery?.publications = publications
            }
            guard next.messages != state.messages else { return }
            try Self.save(next, to: storeURL)
            state = next
        }
    }

    /// Resolves a saved quote without the model directory's 40-message limit.
    /// Never resolves a future publication, another mailbox, or an ambiguous ID.
    public nonisolated static func replySource(for publication: RoomMessage, replyingTo id: UUID,
                                              messages: [AgentMessage]) -> RoomMessage? {
        guard let target = publication.replyToMessageID, target != publication.id,
              messages.filter({ $0.id == id }).count == 1,
              let index = messages.firstIndex(where: { $0.id == id }),
              let scope = messages[index].delivery?.originConversationID,
              publication.groupID == scope, publication.senderID == messages[index].recipientID,
              let publications = messages[index].delivery?.publications,
              publications.filter({ $0.id == publication.id }).count == 1,
              let position = publications.firstIndex(of: publication) else { return nil }
        let inbound = messages[index]
        let candidates = messages[...index].filter {
            $0.senderID == inbound.senderID && $0.recipientID == inbound.recipientID
                && $0.delivery?.originConversationID == scope
        }.flatMap { item -> [RoomMessage] in
            let input = RoomMessage(id: item.id, groupID: scope, senderID: item.senderID,
                text: item.text, createdAt: item.createdAt, images: item.images ?? [])
            let saved = item.id == id ? Array(publications.prefix(position)) : item.delivery?.publications ?? []
            return [input] + saved.filter { $0.groupID == scope && $0.senderID == inbound.recipientID && $0.memberOutcome == nil }
        }.filter { $0.id == target }
        guard candidates.count == 1 else { return nil }
        return candidates.first
    }

    public func replyDirectory(replyingTo id: UUID) throws -> [RoomMessage] {
        guard state.messages.filter({ $0.id == id }).count == 1,
              let index = state.messages.firstIndex(where: { $0.id == id }),
              let scope = state.messages[index].delivery?.originConversationID else {
            throw AgentPublicationError.invalid
        }
        let inbound = state.messages[index]
        let candidates = state.messages[...index].filter {
            $0.senderID == inbound.senderID && $0.recipientID == inbound.recipientID
                && $0.delivery?.originConversationID == scope
        }.flatMap { item -> [RoomMessage] in
            let input = RoomMessage(id: item.id, groupID: scope, senderID: MailboxMessageAddressing.isHuman(item, in: state) ? nil : item.senderID,
                text: item.text, createdAt: item.createdAt, images: item.images ?? [])
            let publications = (item.delivery?.publications ?? []).filter {
                $0.groupID == scope && $0.senderID == inbound.recipientID && $0.memberOutcome == nil
            }
            return ([input] + publications).map(addressedReceipt)
        }
        let counts = Dictionary(grouping: candidates, by: \.id).mapValues(\.count)
        let addressCounts = Dictionary(grouping: candidates.compactMap(\.shortAddress), by: { $0 }).mapValues(\.count)
        return Array(candidates.filter {
            counts[$0.id] == 1 && (!$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !($0.images ?? []).isEmpty)
        }.map { message in
            var target = message
            if let address = target.shortAddress,
               addressCounts[address] != 1 || !GroupMessageAddressing.isValid(address, for: target) {
                target.shortAddress = nil
            }
            return target
        }.suffix(40))
    }

    private func publishValidated(_ publication: RoomMessage, replyingTo id: UUID, lifetime: AgentPublicationLifetime) throws {
        guard publication.shortAddress == nil || publication.shortAddress == state.mailboxAddresses[publication.id] else {
            throw AgentPublicationError.invalid
        }
        var publication = publication
        publication.shortAddress = nil
        try lifetime.commit {
            guard let index = state.messages.firstIndex(where: { $0.id == id }),
                  let delivery = state.messages[index].delivery,
                  delivery.state == .running,
                  publication.groupID == delivery.originConversationID,
                  publication.senderID == state.messages[index].recipientID,
                  (!publication.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(publication.images ?? []).isEmpty),
                  publication.text.count <= 8_000, publication.toolActivities.isEmpty,
                  publication.memberOutcome == nil,
                  publication.shortAddress == nil else { throw AgentPublicationError.invalid }
            let prior = delivery.publications ?? []
            if let reference = publication.cursorAgent {
                guard publication.text == reference.summary, (publication.images ?? []).isEmpty,
                      publication.question == nil, publication.secretRequest == nil,
                      publication.questionReplyTo == nil else { throw AgentPublicationError.invalid }
            }
            // A saved receipt remains replayable after its target leaves the bounded directory.
            if let existing = prior.first(where: { $0.id == publication.id }) {
                guard existing == publication else { throw AgentPublicationError.invalid }
                return
            }
            guard !containsMessageID(publication.id) else { throw AgentPublicationError.invalid }
            if let target = publication.replyToMessageID {
                guard target != publication.id,
                      try replyDirectory(replyingTo: id).contains(where: { $0.id == target }) else {
                    throw AgentPublicationError.invalid
                }
            }
            let images = publication.images ?? []
            guard images.count <= 4, Set(images.map(\.id)).count == images.count,
                  images.allSatisfy({ image in state.messages[index].images?.contains(where: { image.isAnnotation(of: $0) }) == true }) else {
                throw AgentPublicationError.invalid
            }
            guard !prior.contains(where: { $0.question != nil || $0.secretRequest != nil }) else { throw AgentQuestionError.unavailable }
            guard prior.count < 2 else { throw AgentPublicationError.limit }
            var next = state
            next.messages[index].delivery?.publications = prior + [publication]
            next.messages[index].delivery?.response = String((prior + [publication]).map(\.text).joined(separator: "\n\n").prefix(8_000))
            MailboxMessageAddressing.assignMissing(in: &next)
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
        if deliveryState == .cancelled || deliveryState == .failed {
            if var publications = state.messages[index].delivery?.publications {
                for item in publications.indices where publications[item].secretRequest?.isPending == true {
                    publications[item].secretRequest?.state = .retired
                }
                state.messages[index].delivery?.publications = publications
            }
        }
        // A state-only transition (especially Stop) must not erase a report
        // already published through SendMessage.
        if let publications = previous.delivery?.publications, !publications.isEmpty {
            state.messages[index].delivery?.response = String(publications.map(\.text).joined(separator: "\n\n").prefix(8_000))
        } else if let response { state.messages[index].delivery?.response = String(response.prefix(8_000)) }
        do { try persist() } catch { state.messages[index] = previous; throw error }
    }

    /// The durable address index is metadata, not model-owned publication content.
    private func addressedReceipt(_ publication: RoomMessage) -> RoomMessage {
        var receipt = publication
        receipt.shortAddress = state.mailboxAddresses[publication.id]
        return receipt
    }

    /// Inbound messages and visible publications share the same identity space.
    /// All fresh insertion paths must reject a collision in either collection.
    private func containsMessageID(_ id: UUID) -> Bool {
        state.messages.contains {
            $0.id == id || ($0.delivery?.publications ?? []).contains { $0.id == id }
        }
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
