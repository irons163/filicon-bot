import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor CloudReferenceProbe {
    var messages: [RoomMessage] = []
    var failNext = false
    func fail() { failNext = true }
    func save(_ message: RoomMessage) throws -> RoomMessage {
        if failNext { failNext = false; throw AgentPublicationError.invalid }
        messages.append(message)
        return message
    }
}

@Suite("Cursor agent references", .timeLimit(.minutes(1)))
struct CursorAgentReferenceTests {
    @Test(arguments: ["", " \n ", ".", "..", "a\nb", "a\u{0}b", "a\u{202E}b", String(repeating: "a", count: CursorAgentReference.maximumIDBytes + 1)])
    func invalidIDsCannotCreateOrDecodeLinks(id: String) throws {
        #expect(throws: (any Error).self) { try CursorAgentReference(bcID: id) }
        let data = try JSONEncoder().encode(["bcID": id])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(CursorAgentReference.self, from: data) }
    }

    @Test(arguments: ["bc-", " bc-a\n", "BC-a", "opaque", "bc-中文", "bc-a/b", "bc-a?x=1#x", "bc-%2e%2e", "https://elsewhere.example/a", "//elsewhere.example", "a\\b", "a b"])
    func opaqueIDsStayInOneEncodedPathSegment(id: String) throws {
        let reference = try CursorAgentReference(bcID: id)
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        expectNoDifference(reference.bcID, trimmed)
        let components = try #require(URLComponents(url: reference.url, resolvingAgainstBaseURL: false))
        expectNoDifference(components.scheme, "https")
        expectNoDifference(components.host, "cursor.com")
        expectNoDifference(components.user, nil)
        expectNoDifference(components.query, nil)
        expectNoDifference(components.fragment, nil)
        let parts = components.percentEncodedPath.split(separator: "/")
        expectNoDifference(parts.count, 2)
        expectNoDifference(parts.first, "agents")
        expectNoDifference(parts.last.flatMap { String($0).removingPercentEncoding }, trimmed)
        expectNoDifference(try JSONDecoder().decode(CursorAgentReference.self, from: JSONEncoder().encode(reference)), reference)
    }

    @Test func identifierBudgetIncludesCanonicalSummaryAndCountsUTF8() throws {
        let limit = CursorAgentReference.maximumIDBytes
        let largest = try CursorAgentReference(bcID: String(repeating: "a", count: limit))
        expectNoDifference(largest.summary.utf8.count, 8_000)
        #expect(throws: (any Error).self) { try CursorAgentReference(bcID: String(repeating: "界", count: limit / 3 + 1)) }
    }

    @Test func cardRoundTripAndLegacyMessages() throws {
        let reference = try CursorAgentReference(bcID: "bc-abc_123-XYZ")
        expectNoDifference(reference.url.absoluteString, "https://cursor.com/agents/bc-abc_123-XYZ")
        var message = RoomMessage(groupID: UUID(), senderID: UUID(), text: reference.summary)
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(message)), message)
        message.cursorAgent = reference
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(message)), message)
    }

    @Test func sharedBudgetReplayFailureAndSameTurnQuote() async throws {
        let scope = UUID(), owner = UUID(), probe = CloudReferenceProbe()
        let tool = AgentUserMessageTool(conversationID: scope, availableImages: [], imageStore: nil,
            publishCursorAgent: { reference, reply in
                var message = RoomMessage(groupID: scope, senderID: owner, text: reference.summary)
                message.cursorAgent = reference; message.replyToMessageID = reply; message.shortAddress = "t0s0"
                return try await probe.save(message)
            }, receiptSenderID: owner, publishReceipt: { text, images, reply in
                var message = RoomMessage(groupID: scope, senderID: owner, text: text, images: images)
                message.replyToMessageID = reply
                return try await probe.save(message)
            }, publish: { _, _ in Issue.record("Must use receipt transport") })
        let context = ToolContext(conversationID: scope)
        let first = try call("first", ["type": "cursor-agent", "bcId": " bc-test\n"])
        await probe.fail()
        #expect(try await tool.execute(first, context: context).isError)
        let receipt = try await tool.execute(first, context: context)
        #expect(!receipt.isError)
        let replay = try await tool.execute(first, context: context)
        expectNoDifference(replay, receipt)
        let normalizedReplay = try await tool.execute(call("first", ["type": "cursor-agent", "bcId": "bc-test"]), context: context)
        expectNoDifference(normalizedReplay, receipt)
        #expect(try await tool.execute(call("first", ["text": "Changed type"]), context: context).isError)
        #expect(try await tool.execute(call("changed", ["type": "cursor-agent", "bcId": "bc-test"]), context: context).isError)
        #expect(try await !tool.execute(call("second", ["text": "Details", "reply_to": "t0s0"]), context: context).isError)
        #expect(try await tool.execute(call("third", ["type": "cursor-agent", "bcId": "bc-other"]), context: context).isError)
        let messages = await probe.messages
        expectNoDifference(messages.count, 2)
        expectNoDifference(messages.last?.replyToMessageID, messages.first?.id)
        await tool.close()
        await #expect(throws: (any Error).self) { try await tool.execute(first, context: context) }
    }

    @Test(arguments: ["content", "text", "channel", "url", "images", "title", "secret", "widget"])
    func foreignFieldsAreRejected(field: String) async throws {
        let scope = UUID()
        let tool = AgentUserMessageTool(conversationID: scope, availableImages: [], imageStore: nil,
            publishCursorAgent: { _, _ in Issue.record("Must not publish"); throw AgentPublicationError.invalid },
            publish: { _, _ in Issue.record("Must not publish") })
        #expect(try await tool.execute(call("bad", ["type": "cursor-agent", "bcId": "bc-test", field: "unexpected"]),
            context: .init(conversationID: scope)).isError)
    }

    @Test func persistedMailboxCardIsCanonicalAndRejectsMixedContent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "cloud-reference-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await service.create(name: "Sender", instructions: "fixture")
        let owner = try await service.create(name: "Owner", instructions: "fixture")
        let file = root.appending(path: "mail.json"), origin = UUID()
        let messenger = try AgentMessenger(service: service, storeURL: file)
        let input = AgentMessage(senderID: sender.id, recipientID: owner.id, text: "Reference",
            delivery: .init(chainID: origin, originConversationID: origin))
        try await messenger.sendUserMessage(input, accountID: "fixture", lifetime: .init())
        try await messenger.updateDelivery(id: input.id, state: .running)
        let reference = try CursorAgentReference(bcID: "bc-existing")
        var publication = RoomMessage(groupID: origin, senderID: owner.id, text: "Fake remote status")
        publication.cursorAgent = reference
        await #expect(throws: (any Error).self) { try await messenger.publish(publication, replyingTo: input.id, lifetime: .init()) }
        publication.text = reference.summary
        publication.replyToMessageID = input.id
        let receipt = try await messenger.publish(publication, replyingTo: input.id, lifetime: .init())
        let bytes = try Data(contentsOf: file)
        let replay = try await messenger.publish(receipt, replyingTo: input.id, lifetime: .init())
        expectNoDifference(replay, receipt)
        expectNoDifference(try Data(contentsOf: file), bytes)
        let restarted = try AgentMessenger(service: service, storeURL: file)
        let history = await restarted.allMessages()
        expectNoDifference(history.first?.delivery?.publications?.first?.cursorAgent, reference)
        expectNoDifference(history.first?.delivery?.publications?.first?.replyToMessageID, input.id)
    }

    private func call(_ id: ToolCallID, _ fields: [String: String]) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(fields))
    }
}
