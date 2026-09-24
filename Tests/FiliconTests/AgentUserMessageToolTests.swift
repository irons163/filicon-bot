import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain

private actor PublishedMessages {
    var texts: [String] = []
    func append(_ text: String) { texts.append(text) }
}

@Suite("SendMessage publication boundaries")
struct AgentUserMessageToolTests {
    @Test func referenceTextAndLegacyShorthandShareReceiptsAndBudget() async throws {
        let origin = UUID(), output = PublishedMessages()
        let tool = AgentUserMessageTool(conversationID: origin) { await output.append($0) }
        let context = ToolContext(conversationID: origin)
        func reference(_ id: ToolCallID, _ text: String) throws -> NormalizedToolCall {
            try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(["type": "text", "content": text]))
        }
        let first = try await tool.execute(reference("one", "  Progress\n"), context: context)
        #expect(!first.isError)
        let replay = try await tool.execute(call("one", "Progress"), context: context)
        expectNoDifference(replay, first)
        #expect(try await tool.execute(reference("one", "Changed"), context: context).isError)
        #expect(try await tool.execute(reference("repeat", "Progress"), context: context).isError)
        #expect(!(try await tool.execute(call("two", "Result"), context: context).isError))
        #expect(try await tool.execute(reference("three", "Overflow"), context: context).isError)
        let saved = await output.texts
        expectNoDifference(saved, ["Progress", "Result"])
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) {
            _ = try await tool.execute(reference("late", "Late"), context: context)
        }
    }

    @Test func referenceTextRejectsAmbiguityAndUnavailableCapabilities() async throws {
        let origin = UUID(), output = PublishedMessages()
        let tool = AgentUserMessageTool(conversationID: origin) { await output.append($0) }
        for payload in [
            #"{"type":"text","content":"A","text":"A"}"#,
            #"{"type":"text","text":"A"}"#, #"{"content":"A"}"#,
            #"{"type":null,"content":"A"}"#, #"{"type":"other","content":"A"}"#,
            #"{"type":"text","content":null}"#, #"{"type":"text","content":1}"#,
            #"{"type":"text","content":"   "}"#,
            #"{"type":"text","content":"A","channel":"private"}"#,
            #"{"type":"text","content":"A","images":[]}"#,
            #"{"type":"text","content":"A","reply_to":"t0u"}"#,
            #"{"type":"widget","content":"A"}"#,
            #"{"type":"text","content":"A","widget":{}}"#,
            #"{"type":"text","content":"A","image_id":"private"}"#
        ] {
            let result = try await tool.execute(.init(id: "bad", name: "SendMessage", argumentsJSON: Data(payload.utf8)),
                                                context: .init(conversationID: origin))
            #expect(result.isError)
        }
        let tooLong = try NormalizedToolCall(id: "long", name: "SendMessage",
            argumentsJSON: JSONEncoder().encode(["type": "text", "content": String(repeating: "a", count: 8_001)]))
        #expect(try await tool.execute(tooLong, context: .init(conversationID: origin)).isError)
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(call("scope", "A"), context: .init(conversationID: UUID()))
        }
        let saved = await output.texts
        expectNoDifference(saved, [])
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        expectNoDifference((properties["type"] as? [String: Any])?["enum"] as? [String], ["text"])
        #expect(properties["content"] != nil)
        expectNoDifference((schema["anyOf"] as? [Any])?.count, 2)
    }

    private func call(_ id: ToolCallID, _ text: String) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": text]))
    }

    @Test func boundedPublicationIdempotencyScopeAndClose() async throws {
        let origin = UUID(), output = PublishedMessages()
        let tool = AgentUserMessageTool(conversationID: origin) { await output.append($0) }
        let context = ToolContext(conversationID: origin)
        let first = try await tool.execute(call("one", "Progress"), context: context)
        let replay = try await tool.execute(call("one", "Progress"), context: context)
        expectNoDifference(first, replay)
        #expect(try await tool.execute(call("one", "Altered payload"), context: context).isError)
        #expect(try await tool.execute(call("duplicate", "Progress"), context: context).isError)
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(call("foreign", "Not allowed"), context: .init(conversationID: UUID()))
        }
        #expect(!(try await tool.execute(call("two", "Result"), context: context).isError))
        #expect(try await tool.execute(call("three", "Over limit"), context: context).isError)
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) {
            _ = try await tool.execute(call("late", "Late"), context: context)
        }
        let texts = await output.texts
        expectNoDifference(texts, ["Progress", "Result"])
    }

    @Test func failedPublicationCannotReturnSuccess() async throws {
        struct StoreFailure: Error {}
        let origin = UUID()
        let tool = AgentUserMessageTool(conversationID: origin) { _ in throw StoreFailure() }
        let result = try await tool.execute(call("save", "Report"), context: .init(conversationID: origin))
        #expect(result.isError)
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
    }

    @Test func unsupportedImageAndIdentityFieldsNeverSilentlyPublishText() async throws {
        let origin = UUID(), output = PublishedMessages()
        let tool = AgentUserMessageTool(conversationID: origin) { await output.append($0) }
        for payload in [#"{"text":"Hello","images":["private.png"]}"#, #"{"text":"Hello","images":[]}"#,
                        #"{"text":"Hello","senderID":"someone"}"#, #"{"text":"Hello","recipientID":"someone"}"#] {
            let result = try await tool.execute(.init(id: "unsupported", name: "SendMessage", argumentsJSON: Data(payload.utf8)), context: .init(conversationID: origin))
            #expect(result.isError)
        }
        let texts = await output.texts; expectNoDifference(texts, [])
    }
}
