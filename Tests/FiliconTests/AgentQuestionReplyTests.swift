import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor QuotedQuestionProbe {
    struct Publication: Equatable, Sendable { let question: AgentQuestion; let target: UUID }
    var publications: [Publication] = []
    var attempts = 0
    func publish(_ question: AgentQuestion, to target: UUID, failFirst: Bool = false) throws {
        attempts += 1
        if failFirst && attempts == 1 { throw GroupReplyError.unavailable }
        publications.append(.init(question: question, target: target))
    }
}

@Suite("Quoted choice questions", .timeLimit(.minutes(1)))
struct AgentQuestionReplyTests {
    private let groupID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let targetID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let question = try! AgentQuestion.parse(Data(#"{"prompt":"Review this proposal?","options":[{"label":"Review","value":"@everyone review"},{"label":"Decline"}]}"#.utf8))

    private func call(target: Any, extra: [String: Any] = [:]) throws -> NormalizedToolCall {
        var payload: [String: Any] = ["type": "widget", "widget": try JSONSerialization.jsonObject(with: JSONEncoder().encode(question)), "reply_to": target]
        payload.merge(extra) { _, new in new }
        return try .init(id: "ask", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: payload))
    }

    private var original: RoomMessage {
        .init(id: targetID, groupID: groupID, senderID: nil, text: "A proposal", createdAt: Date(timeIntervalSince1970: 1_000))
    }

    @Test func exactReplaySuspendsWithoutRepublishingAndCannotChangeTarget() async throws {
        let second = RoomMessage(id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!, groupID: groupID, senderID: nil, text: "Another proposal")
        let probe = QuotedQuestionProbe()
        let tool = AgentUserMessageTool(conversationID: groupID,
            publishQuestion: { _ in Issue.record("No unquoted fallback") },
            publishQuestionReply: { try await probe.publish($0, to: $1) },
            replyHistory: [original, second]) { _ in Issue.record("No text fallback") }
        let context = ToolContext(conversationID: groupID)
        let runtime = try await tool.runtimeContext(for: context)
        #expect(runtime.contains("Only choice widgets"))
        #expect(tool.descriptor.description?.contains("Only choice widgets") == true)
        let request = try call(target: targetID.uuidString)
        for _ in 0..<2 {
            do { _ = try await tool.execute(request, context: context); Issue.record("Must suspend") }
            catch let suspension as ToolTurnSuspension { #expect(!suspension.result.isError) }
        }
        let publications = await probe.publications
        expectNoDifference(publications, [.init(question: question, target: targetID)])
        #expect(try await tool.execute(call(target: second.id.uuidString), context: context).isError)
        let unquoted = try NormalizedToolCall(id: "ask", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: [
            "type": "widget", "widget": try JSONSerialization.jsonObject(with: JSONEncoder().encode(question))]))
        #expect(try await tool.execute(unquoted, context: context).isError)
        let text = try NormalizedToolCall(id: "later", name: "SendMessage", argumentsJSON: Data(#"{"text":"Must not continue"}"#.utf8))
        #expect(try await tool.execute(text, context: context).isError)
        await #expect(throws: AgentMessagingError.scopeMismatch) { try await tool.execute(request, context: .init(conversationID: targetID)) }
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) { try await tool.execute(request, context: context) }
    }

    @Test func malformedForeignAndMixedPayloadsFailBeforeEitherPublisher() async throws {
        let foreign = RoomMessage(groupID: targetID, senderID: nil, text: "Other group")
        let empty = RoomMessage(groupID: groupID, senderID: nil, text: "\n")
        let status = RoomMessage(groupID: groupID, senderID: nil, text: "Status", memberOutcome: .failed)
        let tool = AgentUserMessageTool(conversationID: groupID,
            publishQuestion: { _ in Issue.record("Invalid question must not fall back") },
            publishQuestionReply: { _, _ in Issue.record("Invalid question must not publish") },
            replyHistory: [original, foreign, empty, status]) { _ in Issue.record("No text") }
        for target: Any in [NSNull(), "", "t3u", 3, [targetID.uuidString], foreign.id.uuidString, empty.id.uuidString, status.id.uuidString, groupID.uuidString] {
            #expect(try await tool.execute(call(target: target), context: .init(conversationID: groupID)).isError)
        }
        for extra: [String: Any] in [["text": "Hidden"], ["images": ["private.png"]], ["channel": "slack:private"], ["senderID": targetID.uuidString]] {
            #expect(try await tool.execute(call(target: targetID.uuidString, extra: extra), context: .init(conversationID: groupID)).isError)
        }
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
    }

    @Test func hostMustExplicitlySupplyQuestionAndQuoteCapabilities() async throws {
        let quoted: AgentUserMessageTool.QuestionReplyPublisher = { _, _ in Issue.record("No quote capability") }
        let ordinary: AgentUserMessageTool.QuestionPublisher = { _ in Issue.record("No fallback") }
        let text: AgentUserMessageTool.ReplyPublisher = { _, _, _ in Issue.record("No text quote") }
        let tools = [
            AgentUserMessageTool(conversationID: groupID, publishQuestion: ordinary, replyHistory: [original], publishReply: text) { _ in },
            AgentUserMessageTool(conversationID: groupID, publishQuestionReply: quoted, replyHistory: [original]) { _ in },
            AgentUserMessageTool(conversationID: groupID, publishQuestion: ordinary, publishQuestionReply: quoted) { _ in }
        ]
        for tool in tools { #expect(try await tool.execute(call(target: targetID.uuidString), context: .init(conversationID: groupID)).isError) }
    }

    @Test func failedSaveDoesNotSuspendAndExactRequestCanRetry() async throws {
        let probe = QuotedQuestionProbe()
        let tool = AgentUserMessageTool(conversationID: groupID,
            publishQuestion: { _ in Issue.record("No fallback") },
            publishQuestionReply: { try await probe.publish($0, to: $1, failFirst: true) }, replyHistory: [original]) { _ in }
        let context = ToolContext(conversationID: groupID)
        let request = try call(target: targetID.uuidString)
        #expect(try await tool.execute(request, context: context).isError)
        let before = await probe.publications
        expectNoDifference(before, [])
        let texts = await tool.publishedTexts
        expectNoDifference(texts, [])
        await #expect(throws: ToolTurnSuspension.self) { try await tool.execute(request, context: context) }
        let after = await probe.publications
        expectNoDifference(after, [.init(question: question, target: targetID)])
    }

    @Test func quotedQuestionWithIncomingImagesNeverLoadsOrPublishesThem() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-quoted-question-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = AttachmentMetadata(id: "unreadable-fixture", filename: "private.png", mimeType: "image/png", byteCount: 1, kind: .image)
        let probe = QuotedQuestionProbe()
        let tool = AgentUserMessageTool(conversationID: groupID, availableImages: [image], imageStore: AgentImageStore(rootURL: root),
            authorizeImages: { _, _, _, _ in Issue.record("Question must not request image publication") },
            publishQuestion: { _ in Issue.record("No fallback") },
            publishQuestionReply: { try await probe.publish($0, to: $1) }, replyHistory: [original]) { _, _ in Issue.record("No images") }
        await #expect(throws: ToolTurnSuspension.self) { try await tool.execute(call(target: targetID.uuidString), context: .init(conversationID: groupID)) }
        let saved = await probe.publications
        expectNoDifference(saved, [.init(question: question, target: targetID)])
    }
}
