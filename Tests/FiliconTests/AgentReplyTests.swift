import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor ReplyProbe {
    var messages: [RoomMessage] = []
    func append(_ message: RoomMessage) { messages.append(message) }
}

private struct ReplyResponder: GroupAgentResponder {
    let run: @Sendable (@escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> Void
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] { [] }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onPublication: @escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> [String] {
        if history.contains(where: { $0.replyToMessageID != nil }) { return [] }
        try await run(onPublication)
        return []
    }
}

@Suite("Bounded group message replies", .timeLimit(.minutes(1)))
struct AgentReplyTests {
    private let groupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let sourceID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let date = Date(timeIntervalSince1970: 1_000)

    private func call(_ id: ToolCallID = "reply", text: String = "Here is the review", target: UUID) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": text, "reply_to": target.uuidString]))
    }

    @Test func boundedDirectoryRejectsForeignOldEmptyStatusAndAmbiguousTargets() async throws {
        let old = RoomMessage(id: sourceID, groupID: groupID, senderID: nil, text: "Too old", createdAt: date)
        let foreign = RoomMessage(groupID: UUID(), senderID: nil, text: "PRIVATE FOREIGN CONTENT", createdAt: date)
        let recent = (0..<40).map { RoomMessage(groupID: groupID, senderID: nil, text: "Recent \($0)", createdAt: date) }
        let tool = AgentUserMessageTool(conversationID: groupID, replyHistory: [old, foreign] + recent,
            publishReply: { _, _, _ in }) { _ in Issue.record("Must not fall back to an unthreaded message") }
        let directory = try await tool.runtimeContext(for: .init(conversationID: groupID))
        #expect(!directory.contains(old.id.uuidString) && !directory.contains("PRIVATE FOREIGN CONTENT"))
        #expect(directory.contains(try #require(recent.first).id.uuidString))
        for target in [old.id, foreign.id, UUID()] {
            #expect(try await tool.execute(call(target: target), context: .init(conversationID: groupID)).isError)
        }
        let empty = RoomMessage(groupID: groupID, senderID: nil, text: " \n", createdAt: date)
        let status = RoomMessage(groupID: groupID, senderID: UUID(), text: "Host error", createdAt: date, memberOutcome: .failed)
        let duplicate = RoomMessage(id: sourceID, groupID: groupID, senderID: nil, text: "Ambiguous", createdAt: date)
        let unavailable = AgentUserMessageTool(conversationID: groupID,
            replyHistory: [empty, status, old, duplicate], publishReply: { _, _, _ in Issue.record("Not eligible") }) { _ in }
        let schema = try #require(try JSONSerialization.jsonObject(with: unavailable.descriptor.inputSchema) as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?["reply_to"] == nil)
        for target in [empty.id, status.id, duplicate.id] {
            #expect(try await unavailable.execute(call(target: target), context: .init(conversationID: groupID)).isError)
        }
    }

    @Test func replyIdentityIsBoundedIdempotentAndCannotChangeOnReplay() async throws {
        let first = RoomMessage(id: sourceID, groupID: groupID, senderID: nil, text: "Review this", createdAt: date)
        let second = RoomMessage(groupID: groupID, senderID: nil, text: "And this", createdAt: date)
        let probe = ReplyProbe()
        let tool = AgentUserMessageTool(conversationID: groupID, replyHistory: [first, second], publishReply: { text, images, target in
            #expect(images.isEmpty)
            var message = RoomMessage(groupID: first.groupID, senderID: nil, text: text)
            message.replyToMessageID = target
            await probe.append(message)
        }) { _ in Issue.record("Must not publish through the unthreaded callback") }
        let context = ToolContext(conversationID: groupID)
        let result = try await tool.execute(call(target: first.id), context: context)
        #expect(!result.isError)
        let replay = try await tool.execute(call(target: first.id), context: context)
        expectNoDifference(replay, result)
        #expect(try await tool.execute(call(target: second.id), context: context).isError)
        #expect(try await tool.execute(call("duplicate", target: second.id), context: context).isError)
        #expect(!(try await tool.execute(call("second", text: "Another finding", target: second.id), context: context).isError))
        #expect(try await tool.execute(call("third", text: "Too many", target: first.id), context: context).isError)
        let saved = await probe.messages
        expectNoDifference(saved.map(\.replyToMessageID), [first.id, second.id])
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            try await tool.execute(call(target: first.id), context: .init(conversationID: UUID()))
        }
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) { try await tool.execute(call(target: first.id), context: context) }
    }

    @Test func malformedAndUnsupportedFieldsDoNotSilentlyBecomeOrdinaryMessages() async throws {
        let source = RoomMessage(id: sourceID, groupID: groupID, senderID: nil, text: "Question", createdAt: date)
        let tool = AgentUserMessageTool(conversationID: groupID, publishQuestion: { _ in Issue.record("No mixed widgets") },
            replyHistory: [source], publishReply: { _, _, _ in Issue.record("Invalid reply") }) { _ in Issue.record("No fallback") }
        var payloads: [[String: Any]] = [NSNull(), "", "t3u", 3, [sourceID.uuidString], "https://example.com"].map {
            ["text": "Reply", "reply_to": $0]
        }
        payloads += [
            ["text": "Reply", "reply_to": sourceID.uuidString, "channel": "slack:private"],
            ["text": "Reply", "reply_to": sourceID.uuidString, "senderID": UUID().uuidString],
            ["type": "widget", "reply_to": sourceID.uuidString, "widget": ["prompt": "Ready?", "options": [["label": "Yes"]]]]
        ]
        for payload in payloads {
            let call = try NormalizedToolCall(id: "invalid", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: payload))
            #expect(try await tool.execute(call, context: .init(conversationID: groupID)).isError)
        }
        let unsupported = AgentUserMessageTool(conversationID: groupID, replyHistory: [source]) { _ in Issue.record("No host capability") }
        #expect(try await unsupported.execute(call(target: source.id), context: .init(conversationID: groupID)).isError)
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
    }

    @Test func failedReplyDoesNotConsumeBudgetOrClaimSuccess() async throws {
        struct Failure: Error {}
        let source = RoomMessage(id: sourceID, groupID: groupID, senderID: nil, text: "Question", createdAt: date)
        let tool = AgentUserMessageTool(conversationID: groupID, replyHistory: [source],
            publishReply: { _, _, _ in throw Failure() }) { _ in Issue.record("No fallback") }
        for _ in 0..<3 { #expect(try await tool.execute(call(target: source.id), context: .init(conversationID: groupID)).isError) }
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
    }

    @Test(arguments: ["valid", "foreign", "unknown", "closed", "no-lifetime", "save-failure", "stop", "members"])
    func groupPublicationPersistsOrRejectsWithoutAnUnthreadedFallback(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let member = try await agents.create(name: "Designer", providerID: "fixture", modelID: "test")
        let file = root.appending(path: "groups.json")
        let groups = try GroupService(agents: agents, storeURL: file)
        let group = try await groups.create(name: "Team", memberIDs: [member.id])
        let foreign = try await groups.create(name: "Other", memberIDs: [member.id])
        let source = try await groups.postUserMessage("Review this", groupID: group.id)
        let other = try await groups.postUserMessage("Private context", groupID: foreign.id)
        let lifetime = AgentPublicationLifetime()
        let responder = ReplyResponder { publish in
            if mode == "closed" { lifetime.close() }
            if mode == "stop" { await groups.stop(groupID: group.id) }
            if mode == "members" { try await groups.updateMembers(groupID: group.id, memberIDs: []) }
            let backup = root.appending(path: "groups.backup")
            if mode == "save-failure" {
                try FileManager.default.moveItem(at: file, to: backup)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
            defer {
                if mode == "save-failure" {
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.moveItem(at: backup, to: file)
                }
            }
            try await publish(.init(text: "Here is the review", lifetime: mode == "no-lifetime" ? nil : lifetime,
                replyToMessageID: mode == "foreign" ? other.id : mode == "unknown" ? UUID() : source.id))
        }
        if ["valid", "stop", "members"].contains(mode) { _ = try await groups.run(groupID: group.id, responder: responder) }
        else { await #expect(throws: (any Error).self) { try await groups.run(groupID: group.id, responder: responder) } }
        let messages = await groups.messages(groupID: group.id)
        let published = messages.filter { $0.text == "Here is the review" }
        expectNoDifference(published.count, mode == "valid" ? 1 : 0)
        if mode == "valid" {
            expectNoDifference(published.first?.replyToMessageID, source.id)
            expectNoDifference(published.first?.questionReplyTo, nil)
        }
        let reopened = try GroupService(agents: agents, storeURL: file)
        let restored = await reopened.messages(groupID: group.id)
        expectNoDifference(restored.filter { $0.text == "Here is the review" }.map(\.replyToMessageID), published.map(\.replyToMessageID))
    }

    @Test func oldRoomMessageDecodesWithoutReplyAndReplyRoundTrips() throws {
        var message = RoomMessage(id: sourceID, groupID: groupID, senderID: nil, text: "Old message", createdAt: date)
        let old = try JSONEncoder().encode(message)
        #expect(!String(decoding: old, as: UTF8.self).contains("replyToMessageID"))
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: old), message)
        message.replyToMessageID = groupID
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(message)), message)
    }
}
