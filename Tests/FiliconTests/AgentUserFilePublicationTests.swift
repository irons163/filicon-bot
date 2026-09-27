import CustomDump
import Foundation
import Testing
import FiliconAppServices
import FiliconAgents
import FiliconDomain

private actor UserFileProbe {
    var events: [String] = []
    func append(_ value: String) { events.append(value) }
}

@Suite("SendMessage host-bound file capability", .timeLimit(.minutes(1)))
struct AgentUserFilePublicationTests {
    @Test(arguments: [false, true])
    func resolvesHostSelectedAndExplicitReply(defaultReply: Bool) async throws {
        let origin = UUID(), sender = UUID(), probe = UserFileProbe()
        let prior = RoomMessage(groupID: origin, senderID: nil, text: "Human request")
        let transaction = AgentFilePublicationTransaction(conversationID: origin, senderID: sender, validateScope: {},
            prepare: { _, _, _ in try .init(bytes: Data([1]), filename: "result.dat") },
            authorize: { review, _, _ in expectNoDifference(review.replyTo, prior.id) },
            commit: { review, _, _ in
                await probe.append("save")
                expectNoDifference(review.replyTo, prior.id)
                return .init(messageID: UUID(), conversationID: origin, senderID: sender, replyTo: prior.id,
                    digest: review.file.digest, filename: review.file.filename, byteCount: review.file.bytes.count)
            })
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [prior], supportsQuestions: false,
            defaultReplyToMessageID: defaultReply ? prior.id : nil, filePublication: transaction,
            publishGroup: { _, _, _, _ in nil })
        let json = defaultReply ? #"{"type":"attachment","url":"file:///a"}"#
            : "{\"type\":\"attachment\",\"url\":\"file:///a\",\"reply_to\":\"\(prior.id.uuidString)\"}"
        let result = try await tool.execute(call("file", json), context: .init(conversationID: origin))
        #expect(!result.isError)
        let events = await probe.events
        expectNoDifference(events, ["save"])
    }

    private func call(_ id: ToolCallID, _ json: String) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: Data(json.utf8))
    }

    private func transaction(scope: UUID, destination: UUID, sender: UUID, probe: UserFileProbe,
                             deny: Bool = false) -> AgentFilePublicationTransaction {
        AgentFilePublicationTransaction(conversationID: scope, senderID: sender, destinationConversationID: destination,
            validateScope: {}, prepare: { url, _, _ in
                await probe.append("prepare")
                return try .init(bytes: Data(url.utf8), filename: "result.txt")
            }, authorize: { _, _, _ in
                await probe.append("review")
                if deny { throw CancellationError() }
            }, commit: { review, _, _ in
                await probe.append("save")
                expectNoDifference(review.conversationID, destination)
                return .init(messageID: UUID(), conversationID: destination, senderID: sender,
                    replyTo: review.replyTo, digest: review.file.digest, filename: review.file.filename,
                    byteCount: review.file.bytes.count)
            })
    }

    @Test func fileAndTextShareBudgetAndCallNamespace() async throws {
        let origin = UUID(), destination = UUID(), sender = UUID(), probe = UserFileProbe()
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [], supportsQuestions: false,
            replyGroupID: destination,
            filePublication: transaction(scope: origin, destination: destination, sender: sender, probe: probe),
            publishGroup: { _, _, _, _ in await probe.append("text"); return nil })
        let context = ToolContext(conversationID: origin)
        let file = try call("file", #"{"type":"attachment","url":"file:///workspace/report.txt"}"#)
        let first = try await tool.execute(file, context: context)
        #expect(!first.isError)
        let again = try await tool.execute(file, context: context)
        expectNoDifference(again, first)
        #expect(try await tool.execute(call("file", #"{"text":"Cannot repurpose"}"#), context: context).isError)
        #expect(try await tool.execute(call("file", #"{"type":"attachment","url":"file:///different"}"#), context: context).isError)
        #expect(try await tool.execute(call("repeat", #"{"type":"attachment","url":"file:///workspace/report.txt"}"#), context: context).isError)
        #expect(!(try await tool.execute(call("text", #"{"text":"Result delivered"}"#), context: context).isError))
        #expect(try await tool.execute(call("third", #"{"type":"attachment","url":"file:///new"}"#), context: context).isError)
        let events = await probe.events
        expectNoDifference(events, ["prepare", "review", "save", "prepare", "text"])
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["url"] != nil)
    }

    @Test(arguments: ["missing", "sender", "scope", "destination"])
    func missingOrMisboundCapabilityIsNotAdvertised(mode: String) async throws {
        let origin = UUID(), sender = UUID(), probe = UserFileProbe()
        let candidate = transaction(scope: mode == "scope" ? UUID() : origin,
            destination: mode == "destination" ? UUID() : origin,
            sender: mode == "sender" ? UUID() : sender, probe: probe)
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [], supportsQuestions: false,
            filePublication: mode == "missing" ? nil : candidate, publishGroup: { _, _, _, _ in nil })
        let result = try await tool.execute(call("file", #"{"type":"attachment","url":"file:///workspace/report.txt"}"#), context: .init(conversationID: origin))
        #expect(result.isError)
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["url"] == nil)
        let events = await probe.events
        expectNoDifference(events, [])
    }

    @Test func ambiguousOrUnsupportedFieldsNeverRead() async throws {
        let origin = UUID(), sender = UUID(), probe = UserFileProbe()
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [], supportsQuestions: false,
            filePublication: transaction(scope: origin, destination: origin, sender: sender, probe: probe),
            publishGroup: { _, _, _, _ in nil })
        for json in [
            #"{"type":"attachment","url":"https://example.com/file"}"#,
            #"{"type":"attachment","url":null}"#,
            #"{"type":"attachment","url":"file:///a","image_id":"private"}"#,
            #"{"type":"attachment","url":"file:///a","content":"mixed"}"#,
            #"{"type":"attachment","url":"file:///a","channel":"elsewhere"}"#,
            #"{"type":"attachment","url":"file:///a","alt":"unsupported"}"#,
            #"{"type":"attachment","url":"file:///a","reply_to":"invented"}"#,
            #"{"type":"text","content":"a","url":"file:///a"}"#
        ] {
            #expect(try await tool.execute(call("invalid", json), context: .init(conversationID: origin)).isError)
        }
        let events = await probe.events
        expectNoDifference(events, [])
    }

    @Test func denialDoesNotPublishAndCloseRevokesTransaction() async throws {
        let origin = UUID(), sender = UUID(), probe = UserFileProbe()
        let transaction = transaction(scope: origin, destination: origin, sender: sender, probe: probe, deny: true)
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [], supportsQuestions: false,
            filePublication: transaction, publishGroup: { _, _, _, _ in nil })
        let file = try call("file", #"{"type":"attachment","url":"file:///workspace/report.txt"}"#)
        let context = ToolContext(conversationID: origin)
        await #expect(throws: CancellationError.self) { _ = try await tool.execute(file, context: context) }
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
        await tool.close()
        await #expect(throws: AgentFilePublicationError.unavailable) {
            _ = try await transaction.publish(url: "file:///a", replyTo: nil, call: file, context: context)
        }
        let events = await probe.events
        expectNoDifference(events, ["prepare", "review"])
    }
}
