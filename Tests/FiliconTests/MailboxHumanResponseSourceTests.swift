import CustomDump
import Foundation
import Testing
@testable import FiliconAgents

@Suite("Read-only human mailbox response provenance", .timeLimit(.minutes(1)))
struct MailboxHumanResponseSourceTests {
    private let origin = UUID(uuidString: "3A000000-0000-0000-0000-000000000001")!
    private let publicationID = UUID(uuidString: "3A000000-0000-0000-0000-000000000002")!
    private let responseID = UUID(uuidString: "3A000000-0000-0000-0000-000000000003")!
    private let otherID = UUID(uuidString: "3A000000-0000-0000-0000-000000000004")!
    private let date = Date(timeIntervalSince1970: 1_700)

    private func question() throws -> AgentQuestion {
        try .parse(Data(#"{"prompt":"Choose direction","options":[{"label":"Proceed","value":"EXACT_TASK_DIRECTION"}],"allowCustom":true}"#.utf8))
    }
    private func secret() throws -> AgentSecretRequest {
        try .parse(Data(#"{"label":"Peer token","connector":"slack","field":"token"}"#.utf8))
    }
    private func delivery(_ current: AgentMessageDelivery, scope: UUID? = nil,
                          binding: DirectConversationAgentBinding? = nil) -> AgentMessageDelivery {
        var value = AgentMessageDelivery(chainID: current.chainID, originConversationID: scope ?? current.originConversationID,
            state: current.state, response: current.response, directOriginBinding: binding)
        value.startedAt = current.startedAt; value.publications = current.publications; value.finalPublication = current.finalPublication
        return value
    }

    @Test(arguments: [false, true], ["valid", "broken-root", "broken-answer", "duplicate-root", "cycle"])
    func laterQuestionRequiresTheWholeHumanResponseChain(direct: Bool, mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-source-chain-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", instructions: "fixture", at: date)
        let peer = try await agents.create(name: "Peer", instructions: "fixture", at: date)
        let url = root.appending(path: "mail.json"), mailbox = try AgentMessenger(service: agents, storeURL: url)
        let binding: DirectConversationAgentBinding? = direct ? .init(accountID: "local", agentID: sender.id) : nil
        let original = AgentMessage(senderID: sender.id, recipientID: peer.id, text: "EXACT_ORIGINAL_TASK", createdAt: date,
            delivery: .init(chainID: origin, originConversationID: origin, directOriginBinding: binding))
        try await mailbox.send(original)
        let secondResponseID = UUID(uuidString: "3A000000-0000-0000-0000-000000000005")!
        var expectedCard: RoomMessage?
        for (incomingID, cardID, answerID) in [(original.id, publicationID, responseID), (responseID, otherID, secondResponseID)] {
            try await mailbox.updateDelivery(id: incomingID, state: .running, at: date)
            var card = try await mailbox.publishQuestion(question(), replyingTo: incomingID, accountID: "local", originID: origin,
                publicationID: cardID, at: date, lifetime: .init())
            try await mailbox.updateDelivery(id: incomingID, state: .completed, at: date)
            _ = try await mailbox.answerQuestion(replyingTo: incomingID, publicationID: cardID, answer: .option(0),
                accountID: "local", originID: origin, responseID: answerID, directOriginBinding: binding, at: date, lifetime: .init())
            card.question?.answer = .option(0); card.question?.responseMessageID = answerID
            expectedCard = card
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var altered = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: url))
        if mode == "broken-root" { altered.messages[0].delivery?.state = .failed }
        if mode == "duplicate-root" { altered.messages.append(altered.messages[0]) }
        if mode == "broken-answer" {
            let before = altered.messages[1]
            var broken = AgentMessage(id: before.id, senderID: before.senderID, recipientID: before.recipientID,
                text: "UNLINKED_PRIOR_ANSWER", createdAt: before.createdAt, delivery: before.delivery)
            broken.questionResponse = before.questionResponse
            altered.messages[1] = broken
        }
        if mode == "cycle" {
            // Both links are otherwise exact and valid. The last human response
            // asks the prior response, which in turn asks the last one.
            let cycleCardID = UUID(uuidString: "3A000000-0000-0000-0000-000000000006")!
            var card = RoomMessage(id: cycleCardID, groupID: origin, senderID: peer.id, text: try question().prompt, createdAt: date)
            var saved = GroupQuestion(question: try question(), accountID: "local", memberIDs: [sender.id, peer.id])
            saved.answer = .option(0); saved.responseMessageID = responseID
            card.question = saved
            altered.messages[2].delivery?.state = .completed
            altered.messages[2].delivery?.publications = [card]
            altered.messages[1].questionResponse = .init(incomingMessageID: secondResponseID, publicationID: cycleCardID,
                question: try question(), answer: .option(0), accountID: "local")
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(altered).write(to: url, options: .atomic)
        let reopened = try AgentMessenger(service: agents, storeURL: url)
        let bytes = try Data(contentsOf: url), before = await reopened.allMessages()
        let source = try await reopened.humanResponseSource(responseID: secondResponseID, accountID: "local",
            originID: origin, directOriginBinding: binding)
        let expected: AgentPeerTranscriptEntry? = mode == "valid" ? .init(source: try AgentMessageSource(accountID: "local",
            originConversationID: origin, deliveryID: responseID, senderAgentID: sender.id, recipientAgentID: peer.id, kind: .publication),
            message: try #require(expectedCard)) : nil
        expectNoDifference(source, expected)
        let after = await reopened.allMessages()
        expectNoDifference(after, before); expectNoDifference(try Data(contentsOf: url), bytes)
    }

    @Test(arguments: [("question", false), ("question", true), ("secret", false), ("secret", true)],
          ["valid", "read-account", "read-origin", "read-binding", "response-body", "response-account", "response-parent",
           "response-publication", "response-scope", "response-binding", "missing-parent", "duplicate-response",
           "duplicate-publication", "card-backlink", "card-retired", "card-body", "card-members", "original-state",
           "both-kinds", "response-priority", "response-author"])
    func onlyExactLinkedCardIsAReadOnlyAnchor(scenario: (String, Bool), mode: String) async throws {
        let (input, direct) = scenario
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", instructions: "fixture", at: date)
        let peer = try await agents.create(name: "Peer", instructions: "fixture", at: date)
        let url = root.appending(path: "mail.json"), mailbox = try AgentMessenger(service: agents, storeURL: url)
        let binding: DirectConversationAgentBinding? = direct ? .init(accountID: "local", agentID: sender.id) : nil
        let incoming = AgentMessage(senderID: sender.id, recipientID: peer.id, text: "EXACT_ORIGINAL_TASK", priority: .priority,
            createdAt: date, delivery: .init(chainID: origin, originConversationID: origin, directOriginBinding: binding))
        try await mailbox.send(incoming)
        try await mailbox.updateDelivery(id: incoming.id, state: .running, at: date)
        var expectedCard: RoomMessage
        if input == "question" {
            expectedCard = try await mailbox.publishQuestion(question(), replyingTo: incoming.id, accountID: "local",
                originID: origin, publicationID: publicationID, at: date, lifetime: .init())
            try await mailbox.updateDelivery(id: incoming.id, state: .completed, at: date)
            _ = try await mailbox.answerQuestion(replyingTo: incoming.id, publicationID: publicationID, answer: .option(0),
                accountID: "local", originID: origin, responseID: responseID, directOriginBinding: binding, at: date, lifetime: .init())
            expectedCard.question?.answer = .option(0); expectedCard.question?.responseMessageID = responseID
        } else {
            expectedCard = try await mailbox.publishSecretRequest(secret(), replyingTo: incoming.id, accountID: "local",
                originID: origin, connectionID: otherID, publicationID: publicationID, at: date, lifetime: .init())
            try await mailbox.updateDelivery(id: incoming.id, state: .completed, at: date)
            _ = try await mailbox.resolveSecretRequest(replyingTo: incoming.id, publicationID: publicationID, provided: true,
                accountID: "local", originID: origin, connectionID: otherID, responseID: responseID,
                directOriginBinding: binding, at: date, lifetime: .init())
            expectedCard.secretRequest?.state = .stored; expectedCard.secretRequest?.responseMessageID = responseID
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var altered = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: url))
        var response = altered.messages[1]
        if mode == "response-body" || mode == "response-priority" || mode == "response-author" {
            var replacement = AgentMessage(id: response.id,
                senderID: mode == "response-author" ? otherID : response.senderID, recipientID: response.recipientID,
                text: mode == "response-body" ? "UNRELATED_HUMAN_INPUT" : response.text,
                priority: mode == "response-priority" ? .priority : response.priority, createdAt: response.createdAt,
                deliveredAt: response.deliveredAt, delivery: response.delivery)
            replacement.questionResponse = response.questionResponse; replacement.secretResponse = response.secretResponse
            response = replacement
        }
        if ["response-account", "response-parent", "response-publication"].contains(mode) {
            let parent = mode == "response-parent" ? otherID : incoming.id
            let card = mode == "response-publication" ? otherID : publicationID
            let account = mode == "response-account" ? "foreign" : "local"
            if input == "question" {
                response.questionResponse = .init(incomingMessageID: parent, publicationID: card,
                    question: try question(), answer: .option(0), accountID: account)
            } else {
                response.secretResponse = .init(incomingMessageID: parent, publicationID: card, accountID: account, provided: true)
            }
        }
        if mode == "response-scope" || mode == "response-binding" {
            response.delivery = delivery(try #require(response.delivery), scope: mode == "response-scope" ? otherID : origin,
                binding: mode == "response-binding" ? .init(accountID: "foreign", agentID: sender.id) : binding)
        }
        if mode == "both-kinds" {
            if input == "question" {
                response.secretResponse = .init(incomingMessageID: incoming.id, publicationID: publicationID, accountID: "local", provided: true)
            } else {
                response.questionResponse = .init(incomingMessageID: incoming.id, publicationID: publicationID,
                    question: try question(), answer: .option(0), accountID: "local")
            }
        }
        altered.messages[1] = response
        var card = try #require(altered.messages[0].delivery?.publications?.first)
        if mode == "card-body" { card.text = "UNRELATED_CARD" }
        if mode == "card-retired" { card.question?.retired = true; card.secretRequest?.state = .retired }
        if mode == "card-backlink" { card.question?.responseMessageID = otherID; card.secretRequest?.responseMessageID = otherID }
        if mode == "card-members" {
            if let question = card.question {
                var replacement = GroupQuestion(question: question.question, accountID: question.accountID, memberIDs: [peer.id, sender.id])
                replacement.answer = question.answer; replacement.responseMessageID = question.responseMessageID
                card.question = replacement
            }
            if let secret = card.secretRequest {
                var replacement = MailboxSecretRequest(request: secret.request, accountID: secret.accountID,
                    memberIDs: [peer.id, sender.id], connectionID: secret.connectionID)
                replacement.state = secret.state; replacement.responseMessageID = secret.responseMessageID
                card.secretRequest = replacement
            }
        }
        altered.messages[0].delivery?.publications = mode == "duplicate-publication" ? [card, card] : [card]
        if mode == "original-state" { altered.messages[0].delivery?.state = .failed }
        if mode == "duplicate-response" { altered.messages.append(response) }
        if mode == "missing-parent" { altered.messages.removeFirst() }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(altered).write(to: url, options: .atomic)
        let reopened = try AgentMessenger(service: agents, storeURL: url)
        let bytes = try Data(contentsOf: url), before = await reopened.allMessages()
        let actual = try await reopened.humanResponseSource(responseID: responseID,
            accountID: mode == "read-account" ? "foreign" : "local", originID: mode == "read-origin" ? otherID : origin,
            directOriginBinding: mode == "read-binding" ? (direct ? nil : .init(accountID: "local", agentID: sender.id)) : binding)
        let expected: AgentPeerTranscriptEntry? = mode == "valid" ? .init(source: try AgentMessageSource(accountID: "local",
            originConversationID: origin, deliveryID: incoming.id, senderAgentID: sender.id, recipientAgentID: peer.id, kind: .publication),
            message: expectedCard) : nil
        expectNoDifference(actual, expected)
        let after = await reopened.allMessages()
        expectNoDifference(after, before); expectNoDifference(try Data(contentsOf: url), bytes)
    }
}
