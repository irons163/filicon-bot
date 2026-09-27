import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutoReview
import FiliconDomain
import FiliconLocalTools
import FiliconProviderKit
@testable import Filicon

private struct GroupFileAppProvider: AIProvider {
    let url: String
    var destinationID: UUID? = nil
    let descriptor = ProviderDescriptor(id: "group-file-app", displayName: "Files fixture", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let name: ToolName
                    let arguments: [String: String]
                    if let destinationID, request.messages.first?.text.contains("Your name is Designer,") != true {
                        name = "SendToAgent"
                        arguments = ["recipientID": destinationID.uuidString, "message": "Publish the reviewed report"]
                    } else {
                        name = "SendMessage"
                        arguments = ["type": "attachment", "url": url]
                    }
                    let call = try NormalizedToolCall(id: "publish-report", name: name,
                        argumentsJSON: JSONSerialization.data(withJSONObject: arguments))
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
    @Test(arguments: ["approve", "deny", "stop", "destination-stop", "account", "members", "source-changed"], [false, true])
    func requiresApprovalAndKeepsReviewedBytes(mode: String, background: Bool) async throws {
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
        var destination = group
        if background {
            let designerValue = await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
            let designer = try #require(designerValue)
            #expect(await model.createGroup(name: "Destination", summary: "", memberIDs: [sender.id, designer.id]))
            destination = try #require(model.groups.first(where: { $0.name == "Destination" }))
            await model.registry.register(GroupFileAppProvider(url: source.absoluteString, destinationID: destination.id))
        }
        let send = Task { await model.sendGroupMessage(groupID: group.id, text: "Send report") }
        defer { send.cancel() }
        if background {
            let delegation = try await pending(model)
            expectNoDifference(delegation.action.context.metadata["tool"], "SendToAgent")
            await model.resolveGroupApproval(delegation, groupID: group.id, approve: true)
        }
        let approval = try await pending(model)
        expectNoDifference(approval.action.context.metadata["agentFilePublication"], "true")
        expectNoDifference(approval.action.context.conversationID, group.id)
        expectNoDifference(approval.action.context.metadata["agentGroupName"], destination.name)
        #expect(approval.action.context.metadata["agentMessage"]?.contains("report.txt") == true)
        #expect(model.groupMessages[group.id]?.allSatisfy { $0.files == nil } == true)
        if mode == "source-changed" { try Data("Changed source".utf8).write(to: source) }
        if mode == "stop" { await model.stopGroup(id: group.id) }
        if mode == "destination-stop" { await model.stopGroup(id: destination.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: destination.id, memberIDs: []) }
        await model.resolveGroupApproval(approval, groupID: group.id, approve: mode != "deny")
        await send.value
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let messages = await groups.messages(groupID: destination.id)
        let publications = messages.filter { $0.files?.isEmpty == false }
        expectNoDifference(publications.count, ["approve", "source-changed"].contains(mode) ? 1 : 0)
        if let message = publications.first, let file = message.files?.first {
            let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
            let data = try await lifecycle.data(for: file, owner: .init(conversationID: destination.id, messageID: message.id))
            expectNoDifference(data, bytes)
            let priorBanner = model.startupBanner
            let priorError = model.errorMessage
            await model.reconcileQuota()
            expectNoDifference(model.startupBanner, priorBanner)
            expectNoDifference(model.errorMessage, priorError)
        }
        if background {
            let sourceMessages = await groups.messages(groupID: group.id)
            #expect(sourceMessages.allSatisfy { $0.files?.isEmpty != false })
        }
    }

    private func pending(_ model: AppModel) async throws -> PendingApproval {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.pendingAutoReviewApprovals.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingAutoReviewApprovals.first, "\(model.errorMessage ?? "No publication approval")")
    }
}
