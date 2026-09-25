import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
import FiliconProviderKit
@testable import Filicon

private final class DirectQuestionSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let point: StorageQuotaFaultPoint
    init(_ point: StorageQuotaFaultPoint) { self.point = point }
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if armed && point == self.point { armed = false; throw CocoaError(.fileWriteUnknown) }
    }
}

private struct DirectQuestionProvider: AIProvider {
    var dismissOnMoveOn = false
    let descriptor = ProviderDescriptor(id: "direct-question", displayName: "Question test", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let asking = request.messages.last(where: { $0.role == .user })?.text == "Ask"
                    let arguments: [String: Any] = asking
                        ? ["type": "widget", "reply_to": request.messages.last(where: { $0.role == .user })!.id.uuidString,
                           "widget": ["prompt": "Continue?", "options": [["label": "Yes", "value": "Proceed"]],
                                      "allowCustom": true, "dismissOnMoveOn": dismissOnMoveOn]]
                        : ["text": "Answer received"]
                    let call = try NormalizedToolCall(id: "publish", name: "SendMessage",
                        argumentsJSON: JSONSerialization.data(withJSONObject: arguments))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    #expect(request.messages.last(where: { $0.role == .user })?.text != "Ask", "A widget must suspend, not continue the model")
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Direct question lifecycle", .timeLimit(.minutes(1)))
@MainActor struct DirectQuestionAppTests {
    @Test(arguments: [StorageQuotaFaultPoint.afterTemporaryWriteBeforeRename, .afterReservationPersist, .afterCommitPersist])
    func failedAnswerSaveRestoresPendingQuestion(point: StorageQuotaFaultPoint) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-question-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = DirectQuestionSaveFault(point)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, quotaFaultInjector: { try fault.inject($0) })
        let id = try await prepare(model)
        let before = try await read(root, id)
        let message = try #require(before.messages.first(where: { $0.transcriptCards.contains { $0.directQuestion != nil } }))
        let card = try #require(message.transcriptCards.first(where: { $0.directQuestion != nil }))
        fault.arm()
        await model.directQuestionAnswered(conversationID: id, messageID: message.id, cardID: card.id, answer: .option(0))
        let failed = try await read(root, id)
        expectNoDifference(failed.messages, before.messages)
        #expect(!model.running.contains(id))
        await model.directQuestionAnswered(conversationID: id, messageID: message.id, cardID: card.id, answer: .option(0))
        try await finish(model, id)
        let retried = try await read(root, id)
        expectNoDifference(retried.messages.filter { $0.role == .user && $0.text == "Proceed" }.count, 1)
    }

    @Test(arguments: ["option", "custom", "dismiss", "invalid", "account"])
    func answersAreDurableAndScoped(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-question-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let id = try await prepare(model)
        let saved = try await read(root, id)
        let message = try #require(saved.messages.first(where: { $0.transcriptCards.contains { $0.directQuestion != nil } }))
        let card = try #require(message.transcriptCards.first(where: { $0.directQuestion != nil }))
        expectNoDifference(message.deliveryStatus, .succeeded)
        expectNoDifference(message.replyToMessageID, saved.messages.first(where: { $0.role == .user })?.id)
        #expect(card.directQuestion?.isPending == true)
        #expect(model.canAnswerDirectQuestion(conversationID: id, messageID: message.id, cardID: card.id))
        if mode == "account" { model.settings.accountScope = "other" }
        let permissionBefore = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        let answer: AgentQuestionAnswer = mode == "custom" ? .custom("My alternative") : mode == "dismiss" ? .dismissed : .option(mode == "invalid" ? 99 : 0)
        await model.directQuestionAnswered(conversationID: id, messageID: message.id, cardID: card.id, answer: answer)
        try await finish(model, id)
        let permissionAfter = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        expectNoDifference(permissionAfter, permissionBefore)
        let after = try await read(root, id)
        if mode == "invalid" || mode == "account" {
            expectNoDifference(after, saved)
        } else {
            let question = try #require(after.messages.first(where: { $0.id == message.id })?.transcriptCards.first?.directQuestion)
            expectNoDifference(question.answer, answer)
            let reply = try #require(after.messages.first(where: { $0.id == question.responseMessageID }))
            expectNoDifference(reply.text, try question.question.reply(for: answer))
            expectNoDifference(reply.role, .user)
            expectNoDifference(reply.replyToMessageID, message.id)
            expectNoDifference(after.messages.last?.text, "Answer received")
            await model.directQuestionAnswered(conversationID: id, messageID: message.id, cardID: card.id, answer: answer)
            let duplicate = try await read(root, id)
            expectNoDifference(duplicate, after)
        }
    }

    @Test(arguments: [false, true])
    func movingOnRetiresOnlyOptedInQuestions(retire: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-move-on-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let id = try await prepare(model, retire: retire)
        model.draft = "Something else"
        model.send()
        try await finish(model, id)
        let saved = try await read(root, id)
        let question = try #require(saved.messages.flatMap(\.transcriptCards).compactMap(\.directQuestion).first)
        expectNoDifference(question.retired, retire)
        expectNoDifference(question.isPending, !retire)
    }

    private func prepare(_ model: AppModel, retire: Bool = false) async throws -> UUID {
        await model.bootstrap()
        await model.registry.register(DirectQuestionProvider(dismissOnMoveOn: retire))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "direct-question"
        model.conversations[ci].modelID = "test"
        await model.refreshModels()
        model.draft = "Ask"
        model.send()
        try await finish(model, id)
        return id
    }
    private func finish(_ model: AppModel, _ id: UUID) async throws {
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
    }
    private func read(_ root: URL, _ id: UUID) async throws -> Conversation {
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        return try #require(try await store.conversation(id: id))
    }
}
