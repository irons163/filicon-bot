import CustomDump
import Foundation
import Testing
@testable import FiliconAgents

@Suite("Atomic mailbox question lifecycle", .timeLimit(.minutes(1)))
struct MailboxQuestionTests {
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let publicationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let responseID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let date = Date(timeIntervalSince1970: 1_000)
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let messenger: AgentMessenger
        let incoming: AgentMessage
        var file: URL { root.appending(path: "mail.json") }
    }
    private func fixture(direct: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-question-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", instructions: "fixture", at: date)
        let asker = try await agents.create(name: "Asker", instructions: "fixture", at: date)
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "mail.json"))
        let incoming = AgentMessage(senderID: sender.id, recipientID: asker.id, text: "Review", createdAt: date,
                                    delivery: .init(chainID: scope, originConversationID: scope,
                                        directOriginBinding: direct ? .init(accountID: "account-A", agentID: sender.id) : nil))
        try await messenger.send(incoming)
        try await messenger.updateDelivery(id: incoming.id, state: .running, at: date)
        return .init(root: root, agents: agents, messenger: messenger, incoming: incoming)
    }
    private func question() throws -> AgentQuestion {
        try .parse(Data(#"{"prompt":"Which layout?","options":[{"label":"Compact","value":"Use compact"},{"label":"Spacious"}],"allowCustom":true}"#.utf8))
    }
    private func publish(_ f: Fixture) async throws -> RoomMessage {
        try await f.messenger.publishQuestion(question(), replyingTo: f.incoming.id, accountID: "account-A",
            originID: scope, publicationID: publicationID, at: date, lifetime: .init())
    }

    @Test(arguments: ["matching", "missing", "other-agent", "other-account", "legacy-injection"])
    func directAnswerRetainsOnlyMatchingHostOrigin(mode: String) async throws {
        let f = try await fixture(direct: mode != "legacy-injection")
        defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed, at: date)
        var binding = f.incoming.delivery?.directOriginBinding
        switch mode {
        case "missing": binding = nil
        case "other-agent": binding = .init(accountID: "account-A", agentID: f.incoming.recipientID)
        case "other-account": binding = .init(accountID: "account-B", agentID: f.incoming.senderID)
        case "legacy-injection": binding = .init(accountID: "account-A", agentID: f.incoming.senderID)
        default: break
        }
        let bytes = try Data(contentsOf: f.file)
        if mode == "matching" {
            let response = try await f.messenger.answerQuestion(replyingTo: f.incoming.id,
                publicationID: publicationID, answer: .option(0), accountID: "account-A", originID: scope,
                responseID: responseID, directOriginBinding: binding, at: date, lifetime: .init())
            expectNoDifference(response.delivery?.directOriginBinding, binding)
            expectNoDifference(response.questionResponse?.answer, .option(0))
            let restarted = try AgentMessenger(service: f.agents, storeURL: f.file)
            let restored = await restarted.allMessages().last
            expectNoDifference(restored?.delivery?.directOriginBinding, binding)
            expectNoDifference(restored?.delivery?.state, .cancelled)
        } else {
            await #expect(throws: AgentQuestionError.unavailable) {
                _ = try await f.messenger.answerQuestion(replyingTo: f.incoming.id,
                    publicationID: publicationID, answer: .option(0), accountID: "account-A", originID: scope,
                    responseID: responseID, directOriginBinding: binding, at: date, lifetime: .init())
            }
            expectNoDifference(try Data(contentsOf: f.file), bytes)
        }
    }

    @Test(arguments: ["input", "missing", "self", "foreignScope"])
    func questionReplyValidatesTargetBeforeSuspending(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let foreign = AgentMessage(id: responseID, senderID: f.incoming.senderID,
            recipientID: f.incoming.recipientID, text: "Other scope", createdAt: date,
            delivery: .init(chainID: responseID, originConversationID: responseID))
        if mode == "foreignScope" { try await f.messenger.send(foreign) }
        let target = mode == "input" ? f.incoming.id : mode == "self" ? publicationID : responseID
        let before = await f.messenger.allMessages()
        if mode == "input" {
            let saved = try await f.messenger.publishQuestion(question(), replyingTo: f.incoming.id,
                accountID: "account-A", originID: scope, publicationID: publicationID, at: date,
                replyToMessageID: target, lifetime: .init())
            expectNoDifference(saved.replyToMessageID, target)
            expectNoDifference(saved.question?.isPending, true)
            await #expect(throws: AgentQuestionError.unavailable) {
                try await f.messenger.publish(RoomMessage(groupID: scope, senderID: f.incoming.recipientID,
                    text: "Must wait", createdAt: date), replyingTo: f.incoming.id, lifetime: .init())
            }
        } else {
            await #expect(throws: AgentPublicationError.invalid) {
                _ = try await f.messenger.publishQuestion(question(), replyingTo: f.incoming.id,
                    accountID: "account-A", originID: scope, publicationID: publicationID, at: date,
                    replyToMessageID: target, lifetime: .init())
            }
            let after = await f.messenger.allMessages()
            expectNoDifference(after, before)
        }
    }

    @Test(arguments: [AgentQuestionAnswer.option(0), .custom("  More contrast  "), .dismissed])
    func answerPersistsExactlyOnceAndRestartNeverRunsIt(answer: AgentQuestionAnswer) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let published = try await publish(f)
        expectNoDifference(published.question?.memberIDs, [f.incoming.senderID, f.incoming.recipientID])
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.file)
        let response = try await reopened.answerQuestion(replyingTo: f.incoming.id, publicationID: publicationID,
            answer: answer, accountID: "account-A", originID: scope, responseID: responseID, at: date, lifetime: .init())
        expectNoDifference(response.text, try question().reply(for: answer))
        expectNoDifference(response.recipientID, f.incoming.recipientID)
        expectNoDifference(response.senderID, f.incoming.senderID)
        expectNoDifference(response.delivery?.originConversationID, scope)
        expectNoDifference(response.delivery?.state, .queued)
        expectNoDifference(response.questionResponse?.answer, answer)
        expectNoDifference(response.questionResponse?.incomingMessageID, f.incoming.id)
        await #expect(throws: AgentQuestionError.unavailable) { try await reopened.send(response) }
        let saved = await reopened.allMessages()
        expectNoDifference(saved.count, 2)
        expectNoDifference(saved.first?.delivery?.publications?.first?.question?.answer, answer)
        expectNoDifference(saved.first?.delivery?.publications?.first?.question?.responseMessageID, responseID)
        let bytes = try Data(contentsOf: f.file)
        await #expect(throws: AgentQuestionError.unavailable) {
            _ = try await reopened.answerQuestion(replyingTo: f.incoming.id, publicationID: publicationID,
                answer: answer, accountID: "account-A", originID: scope, lifetime: .init())
        }
        expectNoDifference(try Data(contentsOf: f.file), bytes)
        let restarted = try AgentMessenger(service: f.agents, storeURL: f.file)
        let restored = await restarted.allMessages()
        expectNoDifference(restored.last?.delivery?.state, .cancelled)
        expectNoDifference(restored.last?.questionResponse, response.questionResponse)
    }

    @Test(arguments: ["account", "scope", "publication", "running", "cancelled", "failed", "closed", "invalid-answer", "archived", "response-input", "response-publication"])
    func unavailableAnswerNeverChangesMailbox(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        if mode != "running" {
            try await f.messenger.updateDelivery(id: f.incoming.id,
                state: mode == "cancelled" ? .cancelled : mode == "failed" ? .failed : .completed)
        }
        if mode == "archived" { try await f.agents.archive(id: f.incoming.recipientID, at: date) }
        let lifetime = AgentPublicationLifetime()
        if mode == "closed" { lifetime.close() }
        let before = await f.messenger.allMessages(), bytes = try Data(contentsOf: f.file)
        await #expect(throws: (any Error).self) {
            _ = try await f.messenger.answerQuestion(replyingTo: f.incoming.id,
                publicationID: mode == "publication" ? responseID : publicationID,
                answer: mode == "invalid-answer" ? .option(9) : .option(0),
                accountID: mode == "account" ? "account-B" : "account-A",
                originID: mode == "scope" ? responseID : scope,
                responseID: mode == "response-input" ? f.incoming.id : mode == "response-publication" ? publicationID : responseID,
                lifetime: lifetime)
        }
        let after = await f.messenger.allMessages()
        expectNoDifference(after, before)
        expectNoDifference(try Data(contentsOf: f.file), bytes)
    }

    @Test func questionEndsPublicationAndCannotEnterThroughOrdinarySend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var forged = RoomMessage(groupID: scope, senderID: f.incoming.recipientID, text: "Which layout?", createdAt: date)
        forged.question = GroupQuestion(question: try question(), accountID: "account-A", memberIDs: [])
        await #expect(throws: AgentPublicationError.invalid) {
            try await f.messenger.publish(forged, replyingTo: f.incoming.id, lifetime: .init())
        }
        _ = try await publish(f)
        let afterQuestion = await f.messenger.allMessages()
        await #expect(throws: AgentQuestionError.unavailable) {
            try await f.messenger.publish(.init(groupID: scope, senderID: f.incoming.recipientID, text: "Unrequested continuation"),
                                          replyingTo: f.incoming.id, lifetime: .init())
        }
        let after = await f.messenger.allMessages()
        expectNoDifference(after, afterQuestion)
    }

    @Test func failedAnswerWriteLeavesQuestionPendingAndNoResponseQueued() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let before = await f.messenger.allMessages()
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            _ = try await f.messenger.answerQuestion(replyingTo: f.incoming.id, publicationID: publicationID,
                answer: .option(0), accountID: "account-A", originID: scope, lifetime: .init())
        }
        let after = await f.messenger.allMessages()
        expectNoDifference(after, before)
        let restored = try AgentMessenger(service: f.agents, storeURL: backup)
        let persisted = await restored.allMessages()
        expectNoDifference(persisted, before)
    }

    @Test func concurrentAnswersQueueOnlyOneFreshTurn() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let accepted = await withTaskGroup(of: Bool.self) { tasks in
            for index in 0..<2 {
                tasks.addTask {
                    do {
                        _ = try await f.messenger.answerQuestion(replyingTo: f.incoming.id, publicationID: publicationID,
                            answer: .option(index), accountID: "account-A", originID: scope, lifetime: .init())
                        return true
                    } catch { return false }
                }
            }
            var results: [Bool] = []
            for await result in tasks { results.append(result) }
            return results.filter { $0 }.count
        }
        expectNoDifference(accepted, 1)
        let saved = await f.messenger.allMessages()
        expectNoDifference(saved.count, 2)
        expectNoDifference(saved.first?.delivery?.publications?.first?.question?.responseMessageID, saved.last?.id)
    }

    @Test(arguments: [0, 1, 2])
    func questionsShareTheExistingTwoPublicationBudget(priorCount: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        // Older persisted messages omit provenance and continue decoding.
        let legacy = try JSONEncoder().encode(f.incoming)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: legacy)
        expectNoDifference(decoded.questionResponse, nil)
        for index in 0..<priorCount {
            try await f.messenger.publish(.init(groupID: scope, senderID: f.incoming.recipientID, text: "Progress \(index)"),
                                          replyingTo: f.incoming.id, lifetime: .init())
        }
        if priorCount == 2 {
            let before = await f.messenger.allMessages()
            await #expect(throws: AgentPublicationError.limit) { _ = try await publish(f) }
            let after = await f.messenger.allMessages()
            expectNoDifference(after, before)
        } else {
            _ = try await publish(f)
            let saved = await f.messenger.allMessages()
            expectNoDifference(saved.first?.delivery?.publications?.count, priorCount + 1)
            await #expect(throws: AgentQuestionError.unavailable) {
                _ = try await f.messenger.publishQuestion(question(), replyingTo: f.incoming.id, accountID: "account-A",
                    originID: scope, lifetime: .init())
            }
        }
    }

    @Test(arguments: ["account", "scope", "closed", "completed"])
    func invalidQuestionPublicationDoesNotWrite(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if mode == "completed" { try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed) }
        let lifetime = AgentPublicationLifetime()
        if mode == "closed" { lifetime.close() }
        let before = await f.messenger.allMessages(), bytes = try Data(contentsOf: f.file)
        await #expect(throws: (any Error).self) {
            _ = try await f.messenger.publishQuestion(question(), replyingTo: f.incoming.id,
                accountID: mode == "account" ? "" : "account-A", originID: mode == "scope" ? responseID : scope,
                lifetime: lifetime)
        }
        let after = await f.messenger.allMessages()
        expectNoDifference(after, before)
        expectNoDifference(try Data(contentsOf: f.file), bytes)
    }

    @Test(arguments: ["human", "peer", "other-account", "other-scope", "closed", "save-failure"])
    func moveOnRetirementIsScopedAndAtomic(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let moving = try AgentQuestion.parse(Data(#"{"prompt":"Continue?","options":[{"label":"Yes"}],"dismissOnMoveOn":true}"#.utf8))
        _ = try await f.messenger.publishQuestion(moving, replyingTo: f.incoming.id, accountID: "account-A",
            originID: scope, publicationID: publicationID, at: date, lifetime: .init())
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let before = await f.messenger.allMessages()
        let newer = AgentMessage(senderID: f.incoming.senderID, recipientID: f.incoming.recipientID,
            text: "Another task", createdAt: date, delivery: .init(chainID: responseID,
                originConversationID: mode == "other-scope" ? responseID : scope))
        let lifetime = AgentPublicationLifetime()
        if mode == "closed" { lifetime.close() }
        if mode == "save-failure" {
            try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        if mode == "closed" || mode == "save-failure" {
            await #expect(throws: (any Error).self) {
                try await f.messenger.sendUserMessage(newer, accountID: "account-A", lifetime: lifetime)
            }
            let after = await f.messenger.allMessages()
            expectNoDifference(after, before)
        } else {
            if mode == "peer" { try await f.messenger.send(newer) }
            else { try await f.messenger.sendUserMessage(newer,
                accountID: mode == "other-account" ? "account-B" : "account-A", lifetime: lifetime) }
            var expected = before
            if mode == "human" { expected[0].delivery?.publications?[0].question?.retired = true }
            expected.append(newer)
            let after = await f.messenger.allMessages()
            expectNoDifference(after, expected)
        }
    }
}
