import CustomDump
import Foundation
import Testing
import FiliconAppServices
import FiliconChannels
@testable import FiliconAgents

@Suite("Durable mailbox credential requests", .timeLimit(.minutes(1)))
struct MailboxSecretRequestTests {
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let publicationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let responseID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let date = Date(timeIntervalSince1970: 1_000)
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let messenger: AgentMessenger
        let incoming: AgentMessage
        var file: URL { root.appending(path: "mail.json") }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-secret-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", instructions: "fixture", at: date)
        let owner = try await agents.create(name: "Owner", instructions: "fixture", at: date)
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "mail.json"))
        let incoming = AgentMessage(senderID: sender.id, recipientID: owner.id, text: "Connect", priority: .priority,
            createdAt: date, delivery: .init(chainID: scope, originConversationID: scope))
        try await messenger.send(incoming)
        try await messenger.updateDelivery(id: incoming.id, state: .running)
        return .init(root: root, agents: agents, messenger: messenger, incoming: incoming)
    }
    private func request() throws -> AgentSecretRequest {
        try .parse(Data(#"{"label":"Bot token","connector":"slack","field":"token"}"#.utf8))
    }
    private func publish(_ f: Fixture) async throws -> RoomMessage {
        try await f.messenger.publishSecretRequest(request(), replyingTo: f.incoming.id, accountID: "A",
            originID: scope, connectionID: connectionID, publicationID: publicationID, at: date, lifetime: .init())
    }
    private func resolve(_ f: Fixture, provided: Bool = true) async throws -> AgentMessage {
        try await f.messenger.resolveSecretRequest(replyingTo: f.incoming.id, publicationID: publicationID,
            provided: provided, accountID: "A", originID: scope, connectionID: connectionID,
            responseID: responseID, at: date, lifetime: .init())
    }

    @Test(arguments: [true, false]) func responseAndCardCommitTogether(provided: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let card = try await publish(f)
        expectNoDifference(card.secretRequest?.request, try request())
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let response = try await resolve(f, provided: provided)
        expectNoDifference(response.secretResponse?.provided, provided)
        expectNoDifference(response.text, response.secretResponse?.acknowledgement)
        expectNoDifference(response.delivery?.chainID, responseID)
        expectNoDifference(response.delivery?.state, .queued)
        expectNoDifference(response.priority, .normal)
        expectNoDifference(response.images, nil)
        expectNoDifference(response.questionResponse, nil)
        let saved = await f.messenger.allMessages()
        expectNoDifference(saved.count, 2)
        expectNoDifference(saved[0].delivery?.publications?[0].secretRequest?.state, provided ? .stored : .dismissed)
        expectNoDifference(saved[0].delivery?.publications?[0].secretRequest?.responseMessageID, responseID)
        let bytes = try Data(contentsOf: f.file)
        await #expect(throws: AgentSecretRequestError.unavailable) { _ = try await resolve(f, provided: provided) }
        await #expect(throws: AgentQuestionError.unavailable) { try await f.messenger.send(response) }
        expectNoDifference(try Data(contentsOf: f.file), bytes)
        let restarted = try AgentMessenger(service: f.agents, storeURL: f.file)
        let restored = await restarted.allMessages()
        expectNoDifference(restored.last?.delivery?.state, .cancelled)
        expectNoDifference(restored[0].delivery?.publications?[0].secretRequest?.state, provided ? .stored : .dismissed)
    }

    @Test(arguments: ["account", "scope", "connection", "publication", "running", "cancelled", "failed", "closed", "archived", "retired", "restart"])
    func staleResponsesNeverQueueWork(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        if mode != "running" {
            try await f.messenger.updateDelivery(id: f.incoming.id,
                state: mode == "failed" ? .failed : mode == "cancelled" ? .cancelled : .completed)
        }
        if mode == "archived" { try await f.agents.archive(id: f.incoming.recipientID, at: date) }
        if mode == "retired" {
            try await f.messenger.retireSecretRequests(accountID: "A", originID: scope, lifetime: .init())
        }
        let messenger = mode == "restart" ? try AgentMessenger(service: f.agents, storeURL: f.file) : f.messenger
        let before = await messenger.allMessages(), bytes = try Data(contentsOf: f.file)
        let lifetime = AgentPublicationLifetime()
        if mode == "closed" { lifetime.close() }
        await #expect(throws: (any Error).self) {
            _ = try await messenger.resolveSecretRequest(replyingTo: f.incoming.id,
                publicationID: mode == "publication" ? responseID : publicationID, provided: true,
                accountID: mode == "account" ? "B" : "A", originID: mode == "scope" ? responseID : scope,
                connectionID: mode == "connection" ? responseID : connectionID, lifetime: lifetime)
        }
        let after = await messenger.allMessages()
        expectNoDifference(after, before)
        expectNoDifference(try Data(contentsOf: f.file), bytes)
    }

    @Test func persistenceFailureDoesNotClaimProvidedOrEnqueue() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let before = await f.messenger.allMessages()
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await resolve(f) }
        let after = await f.messenger.allMessages()
        expectNoDifference(after, before)
        let restarted = try AgentMessenger(service: f.agents, storeURL: backup)
        let recovered = await restarted.allMessages()
        expectNoDifference(recovered.count, 1)
        expectNoDifference(recovered[0].delivery?.publications?[0].secretRequest?.state, .retired)
    }

    @Test func concurrentResolutionHasOneWinner() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let count = await withTaskGroup(of: Bool.self) { group in
            for provided in [true, false] {
                group.addTask { (try? await resolve(f, provided: provided)) != nil }
            }
            var count = 0
            for await result in group where result { count += 1 }
            return count
        }
        expectNoDifference(count, 1)
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.count, 2)
    }

    @Test(arguments: ["human", "peer", "other-account", "other-scope", "closed"])
    func moveOnIsScoped(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let next = AgentMessage(id: responseID, senderID: f.incoming.senderID, recipientID: f.incoming.recipientID,
            text: "Different task", createdAt: date, delivery: .init(chainID: responseID,
                originConversationID: mode == "other-scope" ? responseID : scope))
        let lifetime = AgentPublicationLifetime()
        if mode == "closed" {
            lifetime.close()
            await #expect(throws: CancellationError.self) {
                try await f.messenger.sendUserMessage(next, accountID: "A", lifetime: lifetime)
            }
        } else if mode == "peer" { try await f.messenger.send(next) }
        else { try await f.messenger.sendUserMessage(next, accountID: mode == "other-account" ? "B" : "A", lifetime: lifetime) }
        let saved = await f.messenger.allMessages()
        expectNoDifference(saved[0].delivery?.publications?[0].secretRequest?.state, mode == "human" ? .retired : .pending)
    }

    @Test(arguments: [0, 1, 2]) func publicationBudgetAndDedicatedEntry(priorCount: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for index in 0..<priorCount {
            try await f.messenger.publish(.init(groupID: scope, senderID: f.incoming.recipientID, text: "Step \(index)"),
                replyingTo: f.incoming.id, lifetime: .init())
        }
        if priorCount == 2 {
            await #expect(throws: AgentPublicationError.limit) { _ = try await publish(f) }
        } else {
            let card = try await publish(f)
            await #expect(throws: AgentPublicationError.invalid) {
                try await f.messenger.publish(card, replyingTo: f.incoming.id, lifetime: .init())
            }
            let replay = try await publish(f)
            expectNoDifference(replay, card)
            await #expect(throws: AgentQuestionError.unavailable) {
                _ = try await f.messenger.publishSecretRequest(request(), replyingTo: f.incoming.id,
                    accountID: "A", originID: scope, connectionID: connectionID,
                    publicationID: responseID, at: date, lifetime: .init())
            }
        }
    }

    @Test func metadataDecoderRejectsValuesAndLegacyMessagesDecode() throws {
        let request = try request()
        expectNoDifference(try JSONDecoder().decode(AgentSecretRequest.self, from: JSONEncoder().encode(request)), request)
        #expect(throws: AgentSecretRequestError.invalid) {
            _ = try JSONDecoder().decode(AgentSecretRequest.self,
                from: Data(#"{"label":"Token","connector":"slack","field":"token","value":"FAKE-NOT-A-KEY"}"#.utf8))
        }
        let message = RoomMessage(id: publicationID, groupID: scope, senderID: nil, text: "Legacy", createdAt: date)
        let restored = try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(message))
        expectNoDifference(restored, message)
        expectNoDifference(restored.secretRequest, nil)
    }

    @Test func storedSubmissionProvidesOnlyValueFreeDurableReceipt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await publish(f)
        try await f.messenger.updateDelivery(id: f.incoming.id, state: .completed)
        let channels = try ChannelService(storeURL: f.root.appending(path: "channels.json"))
        let connection = ChannelConnection(id: connectionID, connectorID: "slack", displayName: "Fixture",
            secretReference: "keychain://channels/\(connectionID)", agentID: f.incoming.recipientID,
            authKind: .botToken, accountID: "A")
        try await channels.saveConnection(connection)
        let destination = try AgentSecretRequestDestination.resolve(request(), accountID: "A",
            agentID: f.incoming.recipientID, conversationID: scope, connections: [connection])
        let submission = AgentSecretSubmission(id: publicationID, destination: destination)
        await #expect(throws: AgentSecretSubmissionError.unavailable) {
            _ = try await submission.recordMailboxReceipt(incomingMessageID: f.incoming.id,
                messenger: f.messenger, lifetime: .init())
        }
        _ = try await submission.submit(AgentSecretValue("FAKE-NOT-A-KEY"), accountID: "A",
            agentID: f.incoming.recipientID, conversationID: scope, channels: channels, write: { _, _ in })
        submission.close()
        let response = try await submission.recordMailboxReceipt(incomingMessageID: f.incoming.id,
            messenger: f.messenger, responseID: responseID, at: date, lifetime: .init())
        expectNoDifference(response.secretResponse?.provided, true)
        #expect(!String(decoding: try Data(contentsOf: f.file), as: UTF8.self).contains("FAKE-NOT-A-KEY"))
        #expect(response.text.contains("does not confirm remote authentication"))
        await #expect(throws: AgentSecretRequestError.unavailable) {
            _ = try await submission.recordMailboxReceipt(incomingMessageID: f.incoming.id,
                messenger: f.messenger, lifetime: .init())
        }
    }
}
