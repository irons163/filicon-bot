import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private let appQuestionJSON = #"{"type":"widget","widget":{"prompt":"Which direction should we take?","helpText":"Choose a direction before implementation.","options":[{"label":"Review first","value":"@everyone review the design","description":"Check the layout and accessibility before writing files.","style":"primary"},{"label":"Start over","description":"Discuss a new approach.","style":"danger"}],"allowCustom":true}}"#

private actor AppQuestionProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) { requests.append(request) }
}

private struct AppQuestionProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "question-fixture", displayName: "Questions", requiresAPIKey: false)
    let probe: AppQuestionProbe
    var swallowSuspension = false
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                do {
                    if request.messages.contains(where: { $0.role == .system && $0.text.contains("answers or dismisses your saved question") }) {
                        continuation.yield(.textDelta("The answer was received."))
                        continuation.yield(.completed(.stop)); continuation.finish()
                        return
                    }
                    let call = try NormalizedToolCall(id: "question", name: "SendMessage", argumentsJSON: Data(appQuestionJSON.utf8))
                    do { _ = try await executeTool(call); Issue.record("Must not continue past a saved question") }
                    catch {
                        guard swallowSuspension else { throw error }
                        let late = try NormalizedToolCall(id: "late", name: "SendMessage", argumentsJSON: Data(#"{"text":"This must never publish"}"#.utf8))
                        do { _ = try await executeTool(late); Issue.record("Must reject late callbacks") }
                        catch {}
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Group question app integration", .timeLimit(.minutes(1)))
@MainActor struct GroupQuestionAppTests {
    private func fixture(swallow: Bool = false) async throws -> (URL, AppModel, AgentGroup, AppQuestionProbe, RoomMessage) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-question-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let engineer = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "question-fixture", modelID: "test"))
        let designer = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "question-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Question team", summary: "", memberIDs: [engineer.id, designer.id]))
        let group = try #require(model.groups.first)
        let probe = AppQuestionProbe()
        await model.registry.register(AppQuestionProvider(probe: probe, swallowSuspension: swallow))
        await model.sendGroupMessage(groupID: group.id, text: "Discuss the design")
        #expect(model.errorMessage == nil)
        #expect(model.runningGroups.isEmpty && model.thinkingGroupMembers.isEmpty)
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
        let question = try #require(model.groupMessages[group.id]?.first(where: { $0.question != nil }))
        expectNoDifference(question.senderID, engineer.id)
        #expect(model.canAnswerGroupQuestion(question))
        let tools = model.groupMessages[group.id, default: []].flatMap(\.toolActivities)
        expectNoDifference(tools.map(\.status), [.succeeded])
        return (root, model, group, probe, question)
    }

    @Test(arguments: [AgentQuestionAnswer.option(0), .custom("@Stranger explore another idea"), .dismissed])
    func answersResumeAskerWithoutBroadcastAndCannotBeRepeated(answer: AgentQuestionAnswer) async throws {
        let (root, model, group, probe, question) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let permissionBefore = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        await model.groupQuestionAnswered(question, answer: answer)
        await model.groupQuestionAnswered(question, answer: answer)
        let requests = await probe.requests
        expectNoDifference(requests.count, 2)
        try #require(requests.count == 2)
        #expect(requests[1].messages.first?.text.contains(group.memberIDs[0].uuidString) == true)
        #expect(requests[1].messages.contains { $0.role == .system && $0.text.contains("not a tool approval") })
        expectNoDifference(requests[1].messages.last(where: { $0.role == .user })?.text, try question.question?.question.reply(for: answer))
        let messages = model.groupMessages[group.id, default: []]
        expectNoDifference(messages.filter { $0.questionReplyTo == question.id }.count, 1)
        expectNoDifference(messages.first(where: { $0.id == question.id })?.question?.answer, answer)
        #expect(!model.canAnswerGroupQuestion(question))
        #expect(model.runningGroups.isEmpty && model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.errorMessage == nil)
        let permissionAfter = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        expectNoDifference(permissionAfter, permissionBefore)
    }

    @Test func providerSwallowingSuspensionCannotPublishLateOutput() async throws {
        let (root, model, group, _, _) = try await fixture(swallow: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.groupMessages[group.id, default: []].allSatisfy { !$0.text.contains("must never publish") })
    }

    @Test func restartKeepsQuestionActionableAndConcurrentAnswersPostOnce() async throws {
        let (root, _, group, probe, question) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        await restored.registry.register(AppQuestionProvider(probe: probe))
        let restoredQuestion = try #require(restored.groupMessages[group.id]?.first(where: { $0.id == question.id }))
        #expect(restored.canAnswerGroupQuestion(restoredQuestion))
        async let first: Void = restored.groupQuestionAnswered(restoredQuestion, answer: .option(0))
        async let second: Void = restored.groupQuestionAnswered(restoredQuestion, answer: .option(1))
        _ = await (first, second)
        expectNoDifference(restored.groupMessages[group.id, default: []].filter { $0.questionReplyTo == question.id }.count, 1)
        let requests = await probe.requests
        expectNoDifference(requests.count, 2)
    }

    @Test(arguments: ["account", "members", "archive"])
    func staleQuestionCannotResume(mode: String) async throws {
        let (root, model, group, probe, question) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        if mode == "account" { model.settings.accountScope = "other" }
        if mode == "members" {
            await model.updateGroupMembers(groupID: group.id, memberIDs: [group.memberIDs[1]])
            await model.updateGroupMembers(groupID: group.id, memberIDs: group.memberIDs)
        }
        if mode == "archive" { await model.archiveAgent(id: group.memberIDs[0]) }
        #expect(!model.canAnswerGroupQuestion(question))
        await model.groupQuestionAnswered(question, answer: .option(0))
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
        #expect(model.groupMessages[group.id, default: []].allSatisfy { $0.questionReplyTo == nil })
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func questionCardsRenderInSevenLanguagesAndBothAppearances(language: String) async throws {
        let raw = try #require(try JSONSerialization.jsonObject(with: Data(appQuestionJSON.utf8)) as? [String: Any])
        let question = try AgentQuestion.parse(JSONSerialization.data(withJSONObject: try #require(raw["widget"])))
        let card = GroupQuestion(question: question, accountID: "local", memberIDs: [UUID()])
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for state in ["pending", "answered", "dismissed", "retired"] {
            var displayed = card
            if state == "answered" { displayed.answer = .option(0) }
            if state == "dismissed" { displayed.answer = .dismissed }
            if state == "retired" { displayed.retired = true }
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    if language != "en" {
                        for key in ["Waiting for your answer", "Your answer", "Send answer", "Answered", "Question unavailable",
                                    "Question dismissed without an answer.", "Answers do not approve tool access. Do not enter passwords or API keys."] {
                            #expect(FiliconLocalization.string(key) != key)
                        }
                    }
                    let host = NSHostingView(rootView: GroupQuestionCard(card: displayed, enabled: true, onAnswer: { _ in })
                        .padding(16).frame(width: 380).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    #expect(size.height > 100 && size.height < 780)
                    expectNoDifference(size.width, 380)
                    host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "question-\(language)-\(state)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
