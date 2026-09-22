import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor ReceiptProbe {
    var messages: [RoomMessage] = []
    var attempts = 0
    func append(_ message: RoomMessage, failFirst: Bool = false) throws -> RoomMessage {
        attempts += 1
        if failFirst && attempts == 1 { throw GroupReplyError.unavailable }
        messages.append(message)
        return message
    }
}

private struct ReceiptResponder: GroupAgentResponder {
    let run: @Sendable (@escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> Void
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] { [] }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        guard context.round == 0 else { return [] }
        try await run(onSavedPublication)
        return []
    }
}

@Suite("Durable group publication receipts", .timeLimit(.minutes(1)))
struct AgentPublicationReceiptTests {
    private let groupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let senderID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let messageID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let secondID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let date = Date(timeIntervalSince1970: 1_000)

    private func call(_ id: ToolCallID, text: String, target: String? = nil) throws -> NormalizedToolCall {
        var fields = ["text": text]
        fields["reply_to"] = target
        return try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(fields))
    }

    private func text(_ result: NormalizedToolResult) -> String {
        result.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
    }

    @Test func savedIdentityExpandsEmptyDirectoryWithoutChangingBudgetOrReplay() async throws {
        let probe = ReceiptProbe()
        let tool = AgentUserMessageTool(conversationID: groupID, senderID: senderID, replyHistory: [], supportsQuestions: false) { text, images, reply, _ in
            var message = RoomMessage(id: reply == nil ? messageID : secondID, groupID: groupID, senderID: senderID,
                                      text: text, createdAt: date, images: images)
            message.shortAddress = reply == nil ? "t0s0" : "t0s1"
            message.replyToMessageID = reply
            return try await probe.append(message)
        }
        let context = ToolContext(conversationID: groupID)
        let schema = try #require(try JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?["reply_to"] != nil)
        #expect(try await tool.execute(call("guess", text: "Too soon", target: "t0s0"), context: context).isError)
        let firstCall = try call("first", text: "Progress")
        let first = try await tool.execute(firstCall, context: context)
        #expect(!first.isError && text(first).contains(messageID.uuidString) && text(first).contains("t0s0"))
        let firstReplay = try await tool.execute(firstCall, context: context)
        expectNoDifference(firstReplay, first)
        let directory = try await tool.runtimeContext(for: context)
        #expect(directory.contains(messageID.uuidString) && directory.contains("Progress"))
        let reply = try await tool.execute(call("second", text: "More detail", target: "t0s0"), context: context)
        #expect(!reply.isError && text(reply).contains(secondID.uuidString))
        let replyReplay = try await tool.execute(call("second", text: "More detail", target: messageID.uuidString), context: context)
        expectNoDifference(replyReplay, reply)
        #expect(try await tool.execute(call("second", text: "More detail", target: "t0s1"), context: context).isError)
        #expect(try await tool.execute(call("third", text: "Too many", target: "t0s1"), context: context).isError)
        let messages = await probe.messages, attempts = await probe.attempts
        expectNoDifference(messages.map(\.replyToMessageID), [nil, messageID])
        expectNoDifference(attempts, 2)
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) { try await tool.execute(firstCall, context: context) }
    }

    @Test func failedSaveDoesNotCreateReceiptOrConsumePublicationBudget() async throws {
        let probe = ReceiptProbe()
        let tool = AgentUserMessageTool(conversationID: groupID, senderID: senderID, replyHistory: [], supportsQuestions: false) { text, _, _, _ in
            var message = RoomMessage(id: messageID, groupID: groupID, senderID: senderID, text: text, createdAt: date)
            message.shortAddress = "t0s0"
            return try await probe.append(message, failFirst: true)
        }
        let context = ToolContext(conversationID: groupID)
        let request = try call("save", text: "Progress")
        let failed = try await tool.execute(request, context: context)
        #expect(failed.isError && !text(failed).contains(messageID.uuidString))
        #expect(try await !tool.runtimeContext(for: context).contains(messageID.uuidString))
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
        let retried = try await tool.execute(request, context: context)
        #expect(!retried.isError && text(retried).contains("t0s0"))
        let attempts = await probe.attempts, messages = await probe.messages
        expectNoDifference(attempts, 2)
        expectNoDifference(messages.count, 1)
    }

    @Test(arguments: ["foreign", "author", "text", "target", "status", "duplicate", "nil"])
    func invalidHostReceiptDoesNotInventAnAddressOrRetryASuccessfulPublication(mode: String) async throws {
        var prior = RoomMessage(id: messageID, groupID: groupID, senderID: senderID, text: "Older", createdAt: date)
        prior.shortAddress = "t0s0"
        let tool = AgentUserMessageTool(conversationID: groupID, senderID: senderID,
            replyHistory: mode == "duplicate" ? [prior] : [], supportsQuestions: false) { text, _, _, _ in
            if mode == "nil" { return nil }
            var message = RoomMessage(id: messageID, groupID: mode == "foreign" ? secondID : groupID,
                senderID: mode == "author" ? secondID : senderID, text: mode == "text" ? "Unrelated" : text, createdAt: date)
            message.shortAddress = "t1s0"
            if mode == "status" { message.memberOutcome = .failed }
            if mode == "target" { message.replyToMessageID = secondID }
            return message
        }
        let context = ToolContext(conversationID: groupID)
        let request = try call("save", text: "Progress")
        let result = try await tool.execute(request, context: context)
        #expect(!result.isError && !text(result).contains("Saved message receipt:"))
        let replay = try await tool.execute(request, context: context), published = await tool.publishedTexts
        expectNoDifference(replay, result)
        expectNoDifference(published, ["Progress"])
        #expect(try await !tool.runtimeContext(for: context).contains("t1s0"))
        #expect(try await tool.execute(call("bad", text: "Follow-up", target: "t1s0"), context: context).isError)
    }

    @Test(arguments: ["collision", "malformed", "missing"])
    func invalidAliasUsesOnlyPersistedUUIDAndChecksFullHistory(mode: String) async throws {
        var old = RoomMessage(id: secondID, groupID: groupID, senderID: senderID, text: "Outside directory", createdAt: date)
        old.shortAddress = "t0s0"
        let hidden = (0..<40).map { RoomMessage(groupID: groupID, senderID: nil, text: "Later \($0)", createdAt: date) }
        let tool = AgentUserMessageTool(conversationID: groupID, senderID: senderID, replyHistory: [old] + hidden, supportsQuestions: false) { text, _, reply, _ in
            var message = RoomMessage(id: messageID, groupID: groupID, senderID: senderID, text: text, createdAt: date)
            message.shortAddress = mode == "collision" ? "t0s0" : mode == "malformed" ? "t00s0" : nil
            message.replyToMessageID = reply
            return message
        }
        let context = ToolContext(conversationID: groupID)
        let result = try await tool.execute(call("save", text: "Progress"), context: context)
        #expect(!result.isError && text(result).contains(messageID.uuidString))
        #expect(!text(result).contains("\"shortAddress\":"))
        #expect(try await tool.execute(call("bad", text: "Follow-up", target: "t0s0"), context: context).isError)
        #expect(try await !tool.execute(call("reply", text: "Follow-up", target: messageID.uuidString), context: context).isError)
    }

    @Test func cancellationAfterSaveRemembersReceiptWithoutPublishingAgain() async throws {
        let probe = ReceiptProbe()
        let (saved, signal) = AsyncStream<Void>.makeStream()
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); release.finish() }
        let tool = AgentUserMessageTool(conversationID: groupID, senderID: senderID, replyHistory: [], supportsQuestions: false) { text, _, _, _ in
            var message = RoomMessage(id: messageID, groupID: groupID, senderID: senderID, text: text, createdAt: date)
            message.shortAddress = "t0s0"
            _ = try await probe.append(message)
            signal.yield(()); signal.finish()
            for await _ in blocked { break }
            return message
        }
        let context = ToolContext(conversationID: groupID), request = try call("save", text: "Progress")
        let sending = Task { try await tool.execute(request, context: context) }
        defer { sending.cancel() }
        var iterator = saved.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        sending.cancel()
        await #expect(throws: CancellationError.self) { try await sending.value }
        let result = try await tool.execute(request, context: context)
        #expect(!result.isError && text(result).contains(messageID.uuidString))
        let attempts = await probe.attempts
        expectNoDifference(attempts, 1)
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) { try await tool.execute(request, context: context) }
    }

    @Test func questionReceiptPreservesSuspensionAndReferencesNewlyPublishedText() async throws {
        let probe = ReceiptProbe()
        let tool = AgentUserMessageTool(conversationID: groupID, senderID: senderID, replyHistory: [], supportsQuestions: true) { text, _, reply, question in
            var message = RoomMessage(id: question == nil ? messageID : secondID, groupID: groupID, senderID: senderID, text: text, createdAt: date)
            message.shortAddress = question == nil ? "t0s0" : "t0s1"
            message.replyToMessageID = reply
            message.question = question.map { GroupQuestion(question: $0, accountID: "local", memberIDs: [senderID]) }
            return try await probe.append(message)
        }
        let context = ToolContext(conversationID: groupID)
        _ = try await tool.execute(call("save", text: "Proposal"), context: context)
        let ask = try NormalizedToolCall(id: "ask", name: "SendMessage", argumentsJSON: Data(#"{"type":"widget","widget":{"prompt":"Review this?","options":[{"label":"Yes"}]},"reply_to":"t0s0"}"#.utf8))
        var first: NormalizedToolResult?
        for _ in 0..<2 {
            do { _ = try await tool.execute(ask, context: context); Issue.record("Question must suspend") }
            catch let suspension as ToolTurnSuspension {
                #expect(text(suspension.result).contains(secondID.uuidString))
                #expect(text(suspension.result).contains("does not resume"))
                if let first { expectNoDifference(suspension.result, first) }
                first = suspension.result
            }
        }
        let messages = await probe.messages
        expectNoDifference(messages.map(\.replyToMessageID), [nil, messageID])
        #expect(try await tool.execute(call("late", text: "Keep working", target: "t0s1"), context: context).isError)
        let attempts = await probe.attempts
        expectNoDifference(attempts, 2)
    }

    @Test(arguments: ["saved", "closed", "stop", "members", "save-failure"])
    func groupServiceOnlyReceiptsDurableAuthorizedRows(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-receipt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let member = try await agents.create(name: "Engineer", providerID: "fixture", modelID: "test")
        let file = root.appending(path: "groups.json")
        let groups = try GroupService(agents: agents, storeURL: file)
        let group = try await groups.create(name: "Team", memberIDs: [member.id])
        _ = try await groups.postUserMessage("Review", groupID: group.id)
        let lifetime = AgentPublicationLifetime()
        let probe = ReceiptProbe()
        let responder = ReceiptResponder { publish in
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
            let receipt = try #require(try await publish(.init(text: "Saved result", lifetime: lifetime)))
            _ = try await probe.append(receipt)
            // The receipt is compared against a separately reopened store,
            // not merely the live actor's in-memory state.
            let reopened = try GroupService(agents: agents, storeURL: file)
            let durable = await reopened.messages(groupID: group.id)
            // JSON milliseconds round-trip Date's floating-point precision.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let expected = try decoder.decode(RoomMessage.self, from: encoder.encode(receipt))
            expectNoDifference(durable.first { $0.id == receipt.id }, expected)
            expectNoDifference(receipt.shortAddress, "t0s0")
        }
        if ["saved", "stop", "members"].contains(mode) { _ = try await groups.run(groupID: group.id, responder: responder) }
        else { await #expect(throws: (any Error).self) { try await groups.run(groupID: group.id, responder: responder) } }
        let receipts = await probe.messages, messages = await groups.messages(groupID: group.id)
        expectNoDifference(receipts.count, mode == "saved" ? 1 : 0)
        expectNoDifference(messages.filter { $0.text == "Saved result" }.count, mode == "saved" ? 1 : 0)
    }
}
