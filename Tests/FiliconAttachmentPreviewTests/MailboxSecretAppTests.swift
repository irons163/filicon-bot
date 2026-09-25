import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconChannels
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor SecretAppProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) { requests.append(request) }
}

private final class SecretAppWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    func write(_ value: AgentSecretValue, _ reference: CredentialRef) {
        lock.withLock { writes += 1 }
    }
    var count: Int { lock.withLock { writes } }
}

private struct SecretAppProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "secret-fixture", displayName: "Secret fixture", requiresAPIKey: false)
    let probe: SecretAppProbe
    let replyTarget: @Sendable () async -> UUID?
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                do {
                    if request.messages.contains(where: { $0.role == .system && $0.text.contains("host-recorded human credential response") }) {
                        continuation.yield(.textDelta("Host response received; no remote login claimed."))
                        continuation.yield(.completed(.stop))
                        continuation.finish()
                        return
                    }
                    let target = try #require(await replyTarget())
                    let fields: [String: Any] = ["type": "secret-request", "reply_to": target.uuidString,
                        "secret": ["label": "Bot token", "connector": "slack", "field": "token"]]
                    let call = try NormalizedToolCall(id: "secret", name: "SendMessage", argumentsJSON:
                        JSONSerialization.data(withJSONObject: fields))
                    let result = try await executeTool(call)
                    Issue.record("Expected suspension, got \(result.isError)")
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor @Suite("Mailbox secure input app integration", .timeLimit(.minutes(1)))
struct MailboxSecretAppTests {
    @Test(arguments: ["provided", "dismissed", "receipt-failure", "account", "archived", "archived-sender", "stop"])
    func modelToCardToFreshHumanTurn(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-secret-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let date = Date(timeIntervalSince1970: 1_000)
        let sender = try await agents.create(name: "Sender", providerID: "secret-fixture", modelID: "test", at: date)
        let owner = try await agents.create(name: "Owner", providerID: "secret-fixture", modelID: "test", at: date)
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        try await channels.saveConnection(.init(id: connectionID, connectorID: "slack", displayName: "Fixture",
            secretReference: "keychain://channels/\(connectionID)", agentID: owner.id, authKind: .botToken, accountID: "remote", ownerAccountID: "local"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        #expect(await model.updateAgent(sender))
        let probe = SecretAppProbe()
        let writer = SecretAppWriter()
        model.secretCredentialWriter = writer.write
        await model.registry.register(SecretAppProvider(probe: probe, replyTarget: {
            await MainActor.run { model.agentMessages.first?.id }
        }))
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: owner.id, text: "Connect my configured bot"))
        try await waitForMailbox(model)
        let incoming = try #require(model.agentMessages.first)
        let publication = try #require(incoming.delivery?.publications?.first)
        expectNoDifference(publication.replyToMessageID, incoming.id)
        let card = try #require(model.mailboxSecretCards[publication.id])
        #expect(model.canUseMailboxSecret(incoming, publication: publication))
        let beforePermissions = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        let file = root.appending(path: "agent-messages.json")
        let backup = root.appending(path: "mail-backup.json")
        if mode == "receipt-failure" {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        card.draft = "FAKE-APP-SECRET"
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "archived" { await model.archiveAgent(id: owner.id) }
        if mode == "archived-sender" { await model.archiveAgent(id: sender.id) }
        if mode == "stop" { await model.stopAgentMessages(scopeID: try #require(incoming.delivery?.originConversationID)) }
        if mode == "dismissed" { await card.dismissButtonTapped() }
        else {
            await card.submitButtonTapped()
        }
        if mode == "receipt-failure" {
            expectNoDifference(card.status, .receiptFailed)
            expectNoDifference(card.draft, "")
            expectNoDifference(writer.count, 1)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
            await card.retryButtonTapped()
        }
        try await waitForMailbox(model)
        let shouldResume = ["provided", "dismissed", "receipt-failure"].contains(mode)
        expectNoDifference(card.draft, "")
        let requests = await probe.requests
        expectNoDifference(requests.count, shouldResume ? 2 : 1)
        expectNoDifference(writer.count, ["provided", "receipt-failure"].contains(mode) ? 1 : 0)
        expectNoDifference(model.agentMessages.count, shouldResume ? 2 : 1)
        let afterPermissions = await model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        expectNoDifference(afterPermissions, beforePermissions)
        for request in requests {
            #expect(request.messages.allSatisfy { !$0.text.contains("FAKE-APP-SECRET") })
        }
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("FAKE-APP-SECRET"))
        if shouldResume {
            expectNoDifference(model.agentMessages.last?.recipientID, owner.id)
            expectNoDifference(model.agentMessages.last?.delivery?.state, .completed)
            expectNoDifference(model.agentMessages.last?.secretResponse?.provided, mode != "dismissed")
            #expect(requests.last?.messages.contains { $0.role == .user && $0.text.contains(mode == "dismissed" ? "dismissed" : "securely provided") } == true)
        }
    }

    private func waitForMailbox(_ model: AppModel) async throws {
        for _ in 0..<600 where !model.runningAgentMessageScopes.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(model.runningAgentMessageScopes.isEmpty)
    }
}
