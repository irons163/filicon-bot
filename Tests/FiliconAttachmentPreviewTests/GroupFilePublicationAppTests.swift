import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconLocalTools
import FiliconProviderKit
@testable import Filicon

private struct GroupFileAppProvider: AIProvider {
    let url: String
    let descriptor = ProviderDescriptor(id: "group-file-app", displayName: "Files fixture", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let call = try NormalizedToolCall(id: "publish-report", name: "SendMessage",
                        argumentsJSON: JSONSerialization.data(withJSONObject: ["type": "attachment", "url": url]))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    continuation.yield(.textDelta("PASS"))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("App group file publication", .timeLimit(.minutes(1)))
@MainActor struct GroupFilePublicationAppTests {
    @Test(arguments: ["approve", "deny", "stop", "account", "members", "source-changed"])
    func requiresApprovalAndKeepsReviewedBytes(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-file-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appending(path: "report.txt"), bytes = Data("Reviewed artifact".utf8)
        try bytes.write(to: source)
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await grants.authorize(workspace)
        let generation = UUID(), key = Data(repeating: 13, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
        await model.bootstrap()
        try await model.localToolPermissionPolicy.setChoice(.always, for: .readFile)
        await model.registry.register(GroupFileAppProvider(url: source.absoluteString))
        let senderValue = await model.createAgent(name: "Sender", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
        let sender = try #require(senderValue)
        #expect(await model.createGroup(name: "Files", summary: "", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        let send = Task { await model.sendGroupMessage(groupID: group.id, text: "Send report") }
        defer { send.cancel() }
        let deadline = ContinuousClock.now + .seconds(10)
        while model.pendingAutoReviewApprovals.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let approval = try #require(model.pendingAutoReviewApprovals.first, "\(model.errorMessage ?? "No publication approval")")
        expectNoDifference(approval.action.context.metadata["agentFilePublication"], "true")
        #expect(approval.action.context.metadata["agentMessage"]?.contains("report.txt") == true)
        #expect(model.groupMessages[group.id]?.allSatisfy { $0.files == nil } == true)
        if mode == "source-changed" { try Data("Changed source".utf8).write(to: source) }
        if mode == "stop" { await model.stopGroup(id: group.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: group.id, memberIDs: []) }
        await model.resolveGroupApproval(approval, groupID: group.id, approve: mode != "deny")
        await send.value
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let messages = await groups.messages(groupID: group.id)
        let publications = messages.filter { $0.files?.isEmpty == false }
        expectNoDifference(publications.count, ["approve", "source-changed"].contains(mode) ? 1 : 0)
        if let message = publications.first, let file = message.files?.first {
            let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
            let data = try await lifecycle.data(for: file, owner: .init(conversationID: group.id, messageID: message.id))
            expectNoDifference(data, bytes)
            let priorBanner = model.startupBanner
            let priorError = model.errorMessage
            await model.reconcileQuota()
            expectNoDifference(model.startupBanner, priorBanner)
            expectNoDifference(model.errorMessage, priorError)
        }
    }
}
