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

private final class GroupFileQuotaFault: @unchecked Sendable {
    private let lock = NSLock()
    private let groupsURL: URL
    private var mode: String?
    private var triggered = false
    init(groupsURL: URL) { self.groupsURL = groupsURL }
    func arm(_ mode: String) { lock.lock(); defer { lock.unlock() }; self.mode = mode }
    var didTrigger: Bool { lock.lock(); defer { lock.unlock() }; return triggered }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard let mode else { return }
        if mode == "quota-reserve" {
            guard point == .afterReservationPersist else { return }
        } else {
            guard point == .afterCommitPersist else { return }
            if mode == "quota-message" {
                let state = try JSONSerialization.jsonObject(with: Data(contentsOf: groupsURL)) as? [String: Any]
                let messages = state?["roomMessages"] as? [[String: Any]] ?? []
                guard messages.contains(where: { ($0["files"] as? [Any])?.isEmpty == false }) else { return }
            }
        }
        self.mode = nil
        triggered = true
        throw CocoaError(.fileWriteUnknown)
    }
}

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
    @Test(arguments: ["approve", "deny", "stop", "destination-stop", "account", "members", "source-changed", "quota-reserve", "quota-blob", "quota-message"], ["foreground", "group", "direct", "mailbox"])
    func requiresApprovalAndKeepsReviewedBytes(mode: String, route: String) async throws {
        let background = route != "foreground"
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
        let fault = GroupFileQuotaFault(groupsURL: root.appending(path: "groups.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            quotaFaultInjector: { try fault.inject($0) })
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
        var originID: UUID
        if route == "direct" {
            let conversationID = await model.addConversation(agentID: sender.id)
            originID = try #require(conversationID)
            await model.refreshModels()
        } else { originID = group.id }
        var mailboxSenderID: UUID?
        if route == "mailbox" {
            let caller = await model.createAgent(name: "Caller", summary: "", instructions: "", providerID: "group-file-app", modelID: "test")
            mailboxSenderID = try #require(caller).id
        }
        let send = Task {
            if let mailboxSenderID {
                let sent = await model.sendAgentMessage(senderID: mailboxSenderID, recipientID: sender.id, text: "Send report")
                #expect(sent)
            } else if route == "direct" {
                model.draft = "Send report"
                model.send()
            } else { await model.sendGroupMessage(groupID: group.id, text: "Send report") }
        }
        defer { send.cancel() }
        var delegationID: String?
        if background {
            let delegation = try await pending(model)
            delegationID = delegation.id
            if route == "mailbox" { originID = delegation.action.context.conversationID }
            expectNoDifference(delegation.action.context.metadata["tool"], "SendToAgent")
            if route == "direct" {
                model.handleTranscriptCardIntent(.approveReview(reviewID: delegation.id))
            } else { await model.resolveGroupApproval(delegation, groupID: originID, approve: true) }
        }
        let approval = try await pending(model, excluding: delegationID)
        expectNoDifference(approval.action.context.metadata["agentFilePublication"], "true")
        expectNoDifference(approval.action.context.conversationID, originID)
        expectNoDifference(approval.action.context.metadata["agentGroupName"], destination.name)
        #expect(approval.action.context.metadata["agentMessage"]?.contains("report.txt") == true)
        #expect(model.groupMessages[group.id]?.allSatisfy { $0.files == nil } == true)
        if mode == "source-changed" { try Data("Changed source".utf8).write(to: source) }
        if mode == "stop" {
            if route == "direct" { model.cancel() }
            else if route == "mailbox" { await model.stopAgentMessages(scopeID: originID) }
            else { await model.stopGroup(id: originID) }
        }
        if mode == "destination-stop" { await model.stopGroup(id: destination.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: destination.id, memberIDs: []) }
        if mode.hasPrefix("quota-") { fault.arm(mode) }
        await model.resolveGroupApproval(approval, groupID: originID, approve: mode != "deny")
        await send.value
        let deadline = ContinuousClock.now + .seconds(10)
        while model.isConversationWorking(originID) || model.runningGroups.contains(destination.id) || model.runningAgentMessageScopes.contains(originID), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isConversationWorking(originID))
        #expect(!model.runningGroups.contains(destination.id))
        #expect(!model.runningAgentMessageScopes.contains(originID))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        if mode.hasPrefix("quota-") { #expect(fault.didTrigger) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let messages = await groups.messages(groupID: destination.id)
        let publications = messages.filter { $0.files?.isEmpty == false }
        expectNoDifference(publications.count, ["approve", "source-changed", "quota-message"].contains(mode) ? 1 : 0)
        if let message = publications.first, let file = message.files?.first {
            let activity = try #require(messages.flatMap(\.toolActivities).first(where: { $0.name == "SendMessage" }))
            expectNoDifference(activity.status, .succeeded)
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

    private func pending(_ model: AppModel, excluding priorID: String? = nil) async throws -> PendingApproval {
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.pendingAutoReviewApprovals.contains(where: { $0.id != priorID }) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingAutoReviewApprovals.first(where: { $0.id != priorID }), "\(model.errorMessage ?? "No publication approval")")
    }
}
