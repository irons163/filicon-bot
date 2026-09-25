import Foundation
import Testing
import CustomDump
import CSQLite
import FiliconAgents
import FiliconChannels
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor DirectSecretProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) { requests.append(request) }
}

private final class DirectSecretWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    func write(_ value: AgentSecretValue, _ reference: CredentialRef) { lock.withLock { writes += 1 } }
    var count: Int { lock.withLock { writes } }
}

private struct DirectSecretProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "direct-secret", displayName: "Fixture", requiresAPIKey: false)
    let probe: DirectSecretProbe
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { (continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation) in
            let task = Task {
                await probe.record(request)
                do {
                    if request.toolExchanges.isEmpty {
                        let user = try #require(request.messages.last(where: { $0.role == .user }))
                        let fields: [String: Any] = user.text == "Ask"
                            ? ["type": "secret-request", "reply_to": user.id.uuidString,
                               "secret": ["label": "Bot token", "connector": "slack", "field": "token"]]
                            : ["text": "Response received"]
                        let call = try NormalizedToolCall(id: "publish", name: "SendMessage",
                            argumentsJSON: JSONSerialization.data(withJSONObject: fields))
                        continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                        continuation.yield(.toolCallCompleted(call))
                        continuation.yield(.completed(.toolUse))
                    } else { continuation.yield(.completed(.stop)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor @Suite("Direct secure credential lifecycle", .timeLimit(.minutes(1)))
struct DirectSecretAppTests {
    @Test(arguments: ["provided", "dismissed", "receipt-failure", "dismissal-failure", "account", "archive", "stop", "new-human", "delete", "disabled", "unbound", "restart", "foreign-binding"])
    func requestInputReceiptAndResume(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-secret-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner", providerID: "direct-secret", modelID: "test",
            at: Date(timeIntervalSince1970: 1000))
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let connectionID = UUID()
        try await channels.saveConnection(.init(id: connectionID, connectorID: "slack", displayName: "Fixture",
            secretReference: "keychain://channels/\(connectionID)", agentID: owner.id,
            authKind: .botToken, accountID: "remote", ownerAccountID: "local"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let probe = DirectSecretProbe(), writer = DirectSecretWriter()
        model.secretCredentialWriter = writer.write
        await model.registry.register(DirectSecretProvider(probe: probe))
        await model.bootstrap()
        let id = try #require(await model.addConversation(agentID: owner.id))
        if mode == "unbound", let ci = model.conversations.firstIndex(where: { $0.id == id }) {
            model.conversations[ci].agentBinding = nil
        }
        model.draft = "Ask"
        model.send()
        try await wait(model)
        let conversation = try #require(model.conversations.first(where: { $0.id == id }))
        if mode == "unbound" {
            expectNoDifference(model.directSecretCards.count, 0)
            #expect(conversation.messages.flatMap(\.transcriptCards).allSatisfy { $0.directSecretRequest == nil })
            expectNoDifference(writer.count, 0)
            return
        }
        let message = try #require(conversation.messages.first(where: { $0.transcriptCards.contains { $0.directSecretRequest != nil } }))
        let savedCard = try #require(message.transcriptCards.first(where: { $0.directSecretRequest != nil }))
        let card = try #require(model.directSecretCard(conversationID: id, messageID: message.id, cardID: savedCard.id))
        model.running.insert(id)
        #expect(model.directSecretCard(conversationID: id, messageID: message.id, cardID: savedCard.id) === card)
        model.running.remove(id)
        if mode == "restart" {
            let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            await reopened.bootstrap()
            try await reopened.loadAllMessages(for: id)
            expectNoDifference(reopened.directSecretCards.count, 0)
            #expect(reopened.directSecretCard(conversationID: id, messageID: message.id, cardID: savedCard.id) == nil)
            let persisted = try #require(reopened.conversations.first(where: { $0.id == id })?.messages
                .flatMap(\.transcriptCards).first(where: { $0.id == savedCard.id }))
            expectNoDifference(persisted.rendererLifecycle, .retired)
            expectNoDifference(writer.count, 0)
            return
        }
        expectNoDifference(message.replyToMessageID, conversation.messages.first(where: { $0.role == .user })?.id)
        let permissions = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        if mode == "receipt-failure" || mode == "dismissal-failure" {
            #expect(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
            #expect(sqlite3_exec(database, "CREATE TRIGGER reject_secret_receipt BEFORE UPDATE ON conversations BEGIN SELECT RAISE(ABORT, 'fixture'); END", nil, nil, nil) == SQLITE_OK)
        }
        card.draft = "FAKE-DIRECT-ONLY-SECRET"
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        if mode == "stop" { model.cancel() }
        if mode == "delete" { model.deleteConversation(id: id) }
        if mode == "disabled" { await model.setChannelConnectionEnabled(id: connectionID, enabled: false) }
        if mode == "foreign-binding", let ci = model.conversations.firstIndex(where: { $0.id == id }) {
            model.conversations[ci].agentBinding = .init(accountID: "other", agentID: owner.id)
        }
        if mode == "new-human" { model.draft = "Move on"; model.send(); try await wait(model) }
        if mode == "dismissed" || mode == "dismissal-failure" { await card.dismissButtonTapped() }
        else { await card.submitButtonTapped() }
        if mode == "receipt-failure" || mode == "dismissal-failure" {
            expectNoDifference(card.status, mode == "receipt-failure" ? .receiptFailed : .dismissalReceiptFailed)
            expectNoDifference(writer.count, mode == "receipt-failure" ? 1 : 0)
            #expect(sqlite3_exec(database, "DROP TRIGGER reject_secret_receipt", nil, nil, nil) == SQLITE_OK)
            await card.retryButtonTapped()
        }
        try await wait(model)
        let resumed = ["provided", "dismissed", "receipt-failure", "dismissal-failure"].contains(mode)
        expectNoDifference(writer.count, ["provided", "receipt-failure"].contains(mode) ? 1 : 0)
        expectNoDifference(card.draft, "")
        let requests = await probe.requests
        #expect(requests.allSatisfy { request in request.messages.allSatisfy { !$0.text.contains("FAKE-DIRECT-ONLY-SECRET") } })
        let responses = model.conversations.first(where: { $0.id == id })?.messages.filter {
            $0.role == .user && ($0.text.contains("securely provided") || $0.text.contains("dismissed the credential"))
        } ?? []
        expectNoDifference(responses.count, resumed ? 1 : 0)
        let afterPermissions = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        expectNoDifference(afterPermissions, permissions)
        if resumed {
            #expect(requests.contains { $0.messages.contains { $0.id == responses.first?.id } })
            let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
            let persisted = try #require(try await store.conversation(id: id))
            let restored = try #require(persisted.messages.flatMap(\.transcriptCards).first(where: { $0.id == savedCard.id }))
            expectNoDifference(restored.directSecretRequest?.state, ["dismissed", "dismissal-failure"].contains(mode) ? .dismissed : .stored)
            expectNoDifference(restored.directSecretRequest?.responseMessageID, responses.first?.id)
            #expect(!String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self).contains("FAKE-DIRECT-ONLY-SECRET"))
            expectNoDifference(model.directSecretCards.count, 0)
        }
    }

    private func wait(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !model.running.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(model.running.isEmpty)
    }
}
