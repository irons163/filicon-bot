import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private struct UserThreadResponder: GroupAgentResponder {
    let explicit: Bool
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] { [] }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        guard context.round == 0 else { return [] }
        try await onTools([.init(id: "read", name: "fixture", status: .succeeded)])
        if explicit {
            _ = try await onSavedPublication(.init(text: "Thread result", lifetime: AgentPublicationLifetime()))
            return []
        }
        return ["Thread result"]
    }
}

private actor UserReplyPublications {
    var messages: [RoomMessage] = []
    func publish(_ value: RoomMessage) -> RoomMessage { messages.append(value); return value }
}

@Suite("Human group replies and turn thread scope", .timeLimit(.minutes(1)))
struct GroupUserReplyTests {
    private func fixture() async throws -> (URL, AgentService, GroupService, AgentGroup) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-user-thread-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let member = try await agents.create(name: "Designer", providerID: "fixture", modelID: "test")
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Team", memberIDs: [member.id])
        return (root, agents, groups, group)
    }

    @Test(arguments: [false, true], [false, true])
    func repliesAndMemberOutputsStayInThreadUntilANewOrdinaryRequest(explicit: Bool, imageOnly: Bool) async throws {
        let (root, agents, groups, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await groups.postUserMessage("Review the layout", groupID: group.id)
        let images: [AttachmentMetadata] = imageOnly ? [.init(id: "unloaded-image", filename: "layout.png", mimeType: "image/png", byteCount: 1, kind: .image)] : []
        let reply = try await groups.postUserMessage(imageOnly ? "" : "Use this layout", groupID: group.id, images: images, replyToMessageID: original.id)
        let produced = try await groups.run(groupID: group.id, responder: UserThreadResponder(explicit: explicit))
        expectNoDifference(produced.map(\.replyToMessageID), [reply.id])
        #expect(produced.allSatisfy { $0.images == nil && $0.questionReplyTo == nil })
        let history = await groups.messages(groupID: group.id)
        expectNoDifference(history.first { $0.id == original.id }, original)
        let projection = GroupThreadProjection(history: history, groupID: group.id)
        expectNoDifference(projection.defaultReplyTargetID, reply.id)
        expectNoDifference(projection.root(containing: try #require(produced.first).id), original.id)
        expectNoDifference(projection.replies(to: original.id).map(\.message.id), [reply.id, try #require(produced.first).id])
        let restored = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let reloaded = await restored.messages(groupID: group.id)
        expectNoDifference(reloaded.map(\.replyToMessageID), history.map(\.replyToMessageID))
        _ = try await restored.postUserMessage("New topic", groupID: group.id)
        let next = try await restored.run(groupID: group.id, responder: UserThreadResponder(explicit: explicit))
        expectNoDifference(next.map(\.replyToMessageID), [nil])
        let latest = await restored.messages(groupID: group.id)
        #expect(GroupThreadProjection(history: latest, groupID: group.id).defaultReplyTargetID == nil)
    }

    @Test func invalidForeignAndStaleMembershipRepliesNeverFallBackToAnOrdinarySend() async throws {
        let (root, _, groups, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await groups.postUserMessage("Original", groupID: group.id)
        let other = try await groups.create(name: "Other", memberIDs: group.memberIDs)
        let foreign = try await groups.postUserMessage("Private", groupID: other.id)
        let before = await groups.messages(groupID: group.id)
        for id in [foreign.id, UUID()] {
            await #expect(throws: GroupReplyError.unavailable) {
                try await groups.postUserMessage("Never sent", groupID: group.id, replyToMessageID: id)
            }
        }
        await #expect(throws: CancellationError.self) {
            try await groups.postUserMessage("Never sent", groupID: group.id, expectedMemberIDs: [], replyToMessageID: original.id)
        }
        let after = await groups.messages(groupID: group.id)
        expectNoDifference(after, before)
    }

    @Test func failedUserReplySaveRestoresTheEntireHistory() async throws {
        let (root, _, groups, group) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try await groups.postUserMessage("Original", groupID: group.id)
        let before = await groups.messages(groupID: group.id)
        let file = root.appending(path: "groups.json"), backup = root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await groups.postUserMessage("Not saved", groupID: group.id, replyToMessageID: original.id)
        }
        let after = await groups.messages(groupID: group.id)
        expectNoDifference(after, before)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let saved = try await groups.postUserMessage("Saved", groupID: group.id, replyToMessageID: original.id)
        expectNoDifference(saved.shortAddress, "t1u")
    }

    @Test(arguments: [false, true], [false, true])
    func hostDefaultIsAppliedBeforeReceiptAndReplayButExplicitTargetWins(question: Bool, imageOnly: Bool) async throws {
        let group = UUID(), sender = UUID()
        let root = RoomMessage(groupID: group, senderID: nil, text: "Original")
        var draft = RoomMessage(groupID: group, senderID: nil, text: imageOnly ? "" : "Reply",
            images: imageOnly ? [.init(id: "unread-image", filename: "reply.png", mimeType: "image/png", byteCount: 1, kind: .image)] : [])
        draft.replyToMessageID = root.id
        let human = draft
        let probe = UserReplyPublications()
        let tool = AgentUserMessageTool(conversationID: group, senderID: sender, replyHistory: [root, human],
            supportsQuestions: true, defaultReplyToMessageID: human.id) { text, images, target, card in
            var saved = RoomMessage(groupID: group, senderID: sender, text: text, images: images)
            saved.replyToMessageID = target
            saved.question = card.map { .init(question: $0, accountID: "local", memberIDs: [sender]) }
            return await probe.publish(saved)
        }
        let context = ToolContext(conversationID: group)
        let invalid = try NormalizedToolCall(id: "bad-explicit", name: "SendMessage", argumentsJSON: Data(#"{"text":"Must not use the default","reply_to":null}"#.utf8))
        #expect(try await tool.execute(invalid, context: context).isError)
        let runtime = try await tool.runtimeContext(for: context)
        #expect(runtime.contains("automatically replies to the current human message \(human.id)"))
        let call = try NormalizedToolCall(id: "auto", name: "SendMessage", argumentsJSON: Data((question
            ? #"{"type":"widget","widget":{"prompt":"Continue?","options":[{"label":"Yes"}]}}"#
            : #"{"text":"Result"}"#).utf8))
        var receipt: NormalizedToolResult?
        do { receipt = try await tool.execute(call, context: context); #expect(!question) }
        catch let suspension as ToolTurnSuspension { receipt = suspension.result; #expect(question) }
        let result = try #require(receipt)
        #expect(!result.isError)
        #expect(result.content.contains { if case .text(let value) = $0 { value.contains("Saved message receipt:") } else { false } })
        if question {
            await #expect(throws: ToolTurnSuspension.self) { try await tool.execute(call, context: context) }
        } else {
            let replay = try await tool.execute(call, context: context)
            expectNoDifference(replay, result)
            let explicit = try NormalizedToolCall(id: "explicit", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text":"Different branch", "reply_to":root.id.uuidString]))
            #expect(try await !tool.execute(explicit, context: context).isError)
        }
        let saved = await probe.messages
        expectNoDifference(saved.map(\.replyToMessageID), question ? [human.id] : [human.id, root.id])
    }

    @Test func unavailableHostDefaultCannotSilentlyPublishUnthreaded() async throws {
        let group = UUID()
        let tool = AgentUserMessageTool(conversationID: group, senderID: UUID(), replyHistory: [],
            supportsQuestions: true, defaultReplyToMessageID: UUID()) { _, _, _, _ in
            Issue.record("Invalid thread cannot publish"); return nil
        }
        for raw in [#"{"text":"Result"}"#, #"{"type":"widget","widget":{"prompt":"Continue?","options":[{"label":"Yes"}]}}"#] {
            let result = try await tool.execute(.init(id: "bad", name: "SendMessage", argumentsJSON: Data(raw.utf8)), context: .init(conversationID: group))
            #expect(result.isError)
        }
        let saved = await tool.publishedTexts
        expectNoDifference(saved, [])
    }
}
