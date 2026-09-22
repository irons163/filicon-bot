import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private let questionJSON = #"{"prompt":"Choose a direction","helpText":"One choice","options":[{"label":"First","value":"@everyone build","style":"primary"},{"label":"Second","description":"Review first"}],"allowCustom":true}"#

private actor QuestionProbe {
    var questions: [AgentQuestion] = []
    func record(_ question: AgentQuestion) { questions.append(question) }
}

private actor QuestionResponder: GroupAgentResponder {
    let question: AgentQuestion
    let lifetime = AgentPublicationLifetime()
    var recipients: [UUID] = []
    init(_ question: AgentQuestion) { self.question = question }
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] { [] }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onPublication: @escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> [String] {
        recipients.append(agent.id)
        if history.contains(where: { $0.questionReplyTo != nil }) { return ["The answer was received."] }
        try await onPublication(.init(text: question.prompt, lifetime: lifetime,
            question: .init(question: question, accountID: "local", memberIDs: context.group.memberIDs)))
        return []
    }
}

@Suite("Agent choice questions", .timeLimit(.minutes(1)))
struct AgentQuestionTests {
    @Test func schemaValuesAndAnswers() throws {
        let question = try AgentQuestion.parse(Data(questionJSON.utf8))
        expectNoDifference(try question.reply(for: .option(0)), "@everyone build")
        expectNoDifference(try question.reply(for: .option(1)), "Second")
        expectNoDifference(try question.reply(for: .custom("  Custom\nanswer  ")), "Custom\nanswer")
        expectNoDifference(try question.reply(for: .dismissed), "Question dismissed without an answer.")
        #expect(throws: AgentQuestionError.invalid) { try question.reply(for: .option(-1)) }
        #expect(throws: AgentQuestionError.invalid) { try question.reply(for: .option(2)) }
        #expect(throws: AgentQuestionError.invalid) { try question.reply(for: .custom("  ")) }
        #expect(throws: AgentQuestionError.invalid) { try question.reply(for: .custom(String(repeating: "界", count: 667))) }
        let defaults = try AgentQuestion.parse(Data(#"{"prompt":"Ready?","options":[{"label":"Yes"}]}"#.utf8))
        #expect(defaults.allowCustom != true && defaults.dismissOnMoveOn != true)
        #expect(throws: AgentQuestionError.invalid) { try defaults.reply(for: .custom("Yes")) }
    }

    @Test(arguments: [
        #"{"prompt":"?","options":[]}"#,
        #"{"prompt":"?","options":[{"label":""}]}"#,
        #"{"prompt":"?","options":[{"label":"Yes"},{"label":"Yes"}]}"#,
        #"{"prompt":"?","options":[{"label":"A","value":"x"},{"label":"B","value":"x"}]}"#,
        #"{"prompt":"?","options":[{"label":"Yes","url":"https://example.com"}]}"#,
        #"{"prompt":"?","options":[{"label":"Yes","style":"secret"}]}"#,
        #"{"prompt":"?","options":[{"label":"Yes","value":null}]}"#,
        #"{"prompt":"?","options":[{"label":"Yes"}],"allowCustom":"true"}"#,
        #"{"prompt":"?","options":[{"label":"Yes"}],"dismissOnMoveOn":null}"#,
        #"{"prompt":"?","options":[{"label":"Yes"}],"password":true}"#,
        #"{"prompt":"\u0000","options":[{"label":"Yes"}]}"#
    ])
    func rejectsMalformedQuestions(json: String) {
        #expect(throws: (any Error).self) { try AgentQuestion.parse(Data(json.utf8)) }
    }

    @Test func enforcesChoiceAndByteBounds() throws {
        for count in [6, 7] {
            let options = (0..<count).map { ["label": "Choice \($0)"] }
            let data = try JSONSerialization.data(withJSONObject: ["prompt": "Choose", "options": options])
            if count == 6 { expectNoDifference(try AgentQuestion.parse(data).options.count, 6) }
            else { #expect(throws: AgentQuestionError.invalid) { try AgentQuestion.parse(data) } }
        }
        let oversize = try JSONSerialization.data(withJSONObject: ["prompt": String(repeating: "x", count: 1_001), "options": [["label": "Yes"]]])
        #expect(throws: AgentQuestionError.invalid) { try AgentQuestion.parse(oversize) }
    }

    @Test func publicationSuspendsAndReplayCannotRepublishOrContinue() async throws {
        let scope = UUID(), probe = QuestionProbe()
        let tool = AgentUserMessageTool(conversationID: scope, publishQuestion: { await probe.record($0) }) { _ in
            Issue.record("Text must not publish after a question")
        }
        _ = try JSONSerialization.jsonObject(with: tool.descriptor.inputSchema)
        let call = try NormalizedToolCall(id: "question", name: "SendMessage", argumentsJSON: Data("{\"type\":\"widget\",\"widget\":\(questionJSON)}".utf8))
        let context = ToolContext(conversationID: scope)
        for _ in 0..<2 {
            do { _ = try await tool.execute(call, context: context); Issue.record("Must suspend") }
            catch let pause as ToolTurnSuspension { expectNoDifference(pause.result.callID, call.id); #expect(!pause.result.isError) }
        }
        let questionCount = await probe.questions.count
        expectNoDifference(questionCount, 1)
        let text = try NormalizedToolCall(id: "text", name: "SendMessage", argumentsJSON: Data(#"{"text":"Continue"}"#.utf8))
        #expect(try await tool.execute(text, context: context).isError)
        let altered = try NormalizedToolCall(id: "question", name: "SendMessage", argumentsJSON: Data(#"{"type":"widget","widget":{"prompt":"Changed?","options":[{"label":"Yes"}]}}"#.utf8))
        #expect(try await tool.execute(altered, context: context).isError)
        await #expect(throws: AgentMessagingError.scopeMismatch) { try await tool.execute(call, context: .init(conversationID: UUID())) }
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) { try await tool.execute(call, context: context) }
    }

    @Test func unsupportedContextsAndStorageFailureCannotClaimQuestionSaved() async throws {
        struct Failed: Error {}
        let scope = UUID()
        let call = try NormalizedToolCall(id: "question", name: "SendMessage", argumentsJSON: Data("{\"type\":\"widget\",\"widget\":\(questionJSON)}".utf8))
        for tool in [AgentUserMessageTool(conversationID: scope) { _ in Issue.record("Must not publish") },
                     AgentUserMessageTool(conversationID: scope, publishQuestion: { _ in throw Failed() }) { _ in }] {
            #expect(try await tool.execute(call, context: .init(conversationID: scope)).isError)
            let published = await tool.publishedTexts
            expectNoDifference(published, [])
        }
    }

    @Test(arguments: ["text", "images", "senderID", "reply_to", "channel"])
    func questionCannotCarryHiddenTextImagesOrRouting(field: String) async throws {
        let scope = UUID(), probe = QuestionProbe()
        let tool = AgentUserMessageTool(conversationID: scope, publishQuestion: { await probe.record($0) }) { _ in Issue.record("No text") }
        var payload: [String: Any] = ["type": "widget", "widget": try JSONSerialization.jsonObject(with: Data(questionJSON.utf8))]
        payload[field] = field == "images" ? ["private.png"] : "hidden"
        let call = try NormalizedToolCall(id: "question", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: payload))
        #expect(try await tool.execute(call, context: .init(conversationID: scope)).isError)
        let questions = await probe.questions
        expectNoDifference(questions, [])
    }

    @Test func combinedImageAndQuestionSchemaIsValidButQuestionDoesNotPublishImages() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-question-schema-\(UUID())")
        let image = AttachmentMetadata(id: "fixture", filename: "fixture.png", mimeType: "image/png", byteCount: 1, kind: .image)
        let scope = UUID(), probe = QuestionProbe()
        let tool = AgentUserMessageTool(conversationID: scope, availableImages: [image], imageStore: AgentImageStore(rootURL: root),
            authorizeImages: { _, _, _, _ in Issue.record("Question must not request image approval") },
            publishQuestion: { await probe.record($0) }) { _, _ in Issue.record("No image publication") }
        let schema = try #require(try JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["images"] != nil && properties["widget"] != nil)
        let call = try NormalizedToolCall(id: "question", name: "SendMessage", argumentsJSON: Data("{\"type\":\"widget\",\"widget\":\(questionJSON)}".utf8))
        await #expect(throws: ToolTurnSuspension.self) { try await tool.execute(call, context: .init(conversationID: scope)) }
        let questions = await probe.questions
        expectNoDifference(questions.count, 1)
    }

    private func fixture(moveOn: Bool = false) async throws -> (URL, AgentService, GroupService, AgentGroup, QuestionResponder, RoomMessage) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-question-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let first = try await agents.create(name: "Engineer", summary: "", providerID: "fixture", modelID: "test")
        let second = try await agents.create(name: "Designer", summary: "", providerID: "fixture", modelID: "test")
        let service = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await service.create(name: "Team", summary: "", memberIDs: [first.id, second.id])
        let json = questionJSON.dropLast() + ",\"dismissOnMoveOn\":\(moveOn)}"
        let responder = QuestionResponder(try AgentQuestion.parse(Data(json.utf8)))
        _ = try await service.postUserMessage("Build together", groupID: group.id)
        let messages = try await service.run(groupID: group.id, responder: responder)
        let question = try #require(messages.first(where: { $0.question != nil }))
        let recipients = await responder.recipients
        expectNoDifference(recipients, [first.id])
        return (root, agents, service, group, responder, question)
    }

    @Test(arguments: [AgentQuestionAnswer.option(0), .custom("@Stranger please"), .dismissed])
    func durableQuestionReplyIsSingleUseAndOnlyWakesAsker(answer: AgentQuestionAnswer) async throws {
        let (root, agents, _, group, responder, question) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let reply = try await restored.answerQuestion(groupID: group.id, messageID: question.id, answer: answer,
            accountID: "local", lifetime: .init())
        expectNoDifference(reply.questionReplyTo, question.id)
        await #expect(throws: AgentQuestionError.unavailable) {
            try await restored.answerQuestion(groupID: group.id, messageID: question.id, answer: answer, accountID: "local", lifetime: .init())
        }
        _ = try await restored.run(groupID: group.id, responder: responder)
        let recipients = await responder.recipients
        expectNoDifference(recipients, [group.memberIDs[0], group.memberIDs[0]])
        let saved = await restored.messages(groupID: group.id)
        expectNoDifference(saved.first(where: { $0.id == question.id })?.question?.answer, answer)
        expectNoDifference(saved.filter { $0.questionReplyTo == question.id }.count, 1)
    }

    @Test(arguments: ["account", "members", "closed", "store"])
    func staleOrUncommittableAnswerDoesNotPost(mode: String) async throws {
        let (root, _, service, group, _, question) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        if mode == "members" { try await service.updateMembers(groupID: group.id, memberIDs: [group.memberIDs[1]]) }
        let before = await service.messages(groupID: group.id)
        if mode == "store" {
            let url = root.appending(path: "groups.json")
            try FileManager.default.moveItem(at: url, to: root.appending(path: "groups.backup"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let lifetime = AgentPublicationLifetime()
        if mode == "closed" { lifetime.close() }
        await #expect(throws: (any Error).self) {
            try await service.answerQuestion(groupID: group.id, messageID: question.id, answer: .option(0),
                accountID: mode == "account" ? "foreign" : "local", lifetime: lifetime)
        }
        let after = await service.messages(groupID: group.id)
        expectNoDifference(after, before)
    }

    @Test(arguments: [false, true])
    func moveOnIsOptInAndMembershipChangeAlwaysRetiresQuestion(moveOn: Bool) async throws {
        let (root, _, service, group, _, question) = try await fixture(moveOn: moveOn)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await service.postUserMessage("Another request", groupID: group.id)
        var saved = await service.messages(groupID: group.id)
        expectNoDifference(saved.first(where: { $0.id == question.id })?.question?.retired, moveOn)
        try await service.updateMembers(groupID: group.id, memberIDs: [group.memberIDs[0]])
        saved = await service.messages(groupID: group.id)
        expectNoDifference(saved.first(where: { $0.id == question.id })?.question?.retired, true)
    }
}
