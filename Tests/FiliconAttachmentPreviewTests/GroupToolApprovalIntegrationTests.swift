import Foundation
import Testing
@testable import Filicon
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview
import FiliconLocalTools

private struct GroupApprovalProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "group-approval-test", displayName: "Group approval test", requiresAPIKey: false)
    let root: URL
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let arguments = try JSONEncoder().encode(["root": root.path, "path": "fixture.txt"])
                    let call = try NormalizedToolCall(id: "group-local-read", name: "local__read_file", argumentsJSON: arguments)
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    #expect(request.toolExchanges[0].results[0].wireText.contains("fixture-only"))
                    continuation.yield(.textDelta("Fixture read successfully."))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Group tool approval integration", .timeLimit(.minutes(1)))
@MainActor
struct GroupToolApprovalIntegrationTests {
    private func fixture() async throws -> (URL, AppModel, UUID) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-approval-\(UUID())")
        // SwiftPM test executables do not embed the app's XPC service. Use its
        // concrete host in-process, retaining permission-receipt verification.
        let generation = UUID(), key = LocalToolRuntime.randomSessionKey()
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let host = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true, authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json")), generation: generation, sessionKey: key, helper: host)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
        await model.registry.register(GroupApprovalProvider(root: root))
        let agent = try #require(await model.createAgent(name: "Tester", summary: "", instructions: "", providerID: "group-approval-test", modelID: "test"))
        #expect(await model.createGroup(name: "Approval fixture", summary: "", memberIDs: [agent.id]))
        await model.reloadWorkspaceData() // Installs the real reviewed local/MCP executors.
        try "fixture-only".write(to: root.appending(path: "fixture.txt"), atomically: true, encoding: .utf8)
        _ = try await model.localToolRuntime.workspaceStore.authorize(root)
        await model.setAutoReviewEnabled(true)
        let groupID = try #require(model.groups.first?.id)
        return (root, model, groupID)
    }

    private func pending(_ model: AppModel) async throws -> PendingApproval {
        for _ in 0..<600 {
            if let request = model.pendingAutoReviewApprovals.first { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No group approval appeared")
    }

    @Test func approveGroupReviewThenLocalPermissionRunsRealTool() async throws {
        let (root, model, groupID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let approval = try await pending(model)
        #expect(approval.action.context.conversationID == groupID)
        #expect(model.runningGroups.contains(groupID))
        #expect(!model.conversations.contains { $0.id == groupID })
        #expect(model.pendingToolApprovals.isEmpty)
        // Cross-group/replayed UI actions cannot grant authority.
        await model.resolveGroupApproval(approval, groupID: UUID(), approve: true)
        #expect(model.pendingAutoReviewApprovals.count == 1)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        for _ in 0..<600 {
            if !model.pendingToolApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let local = try #require(model.pendingToolApprovals.first)
        #expect(local.conversationID == groupID)
        model.resolveLocalToolApproval(id: local.id, allowed: true)
        await run.value
        #expect(model.errorMessage == nil)
        #expect(model.groupMessages[groupID]?.last?.text == "Fixture read successfully.")
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .succeeded)
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func denyingApprovalNeverReachesLocalPermissionOrExecutor() async throws {
        let (root, model, groupID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let approval = try await pending(model)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: false)
        await run.value
        #expect(model.pendingToolApprovals.isEmpty)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .failed)
    }

    @Test func stoppingPendingGroupApprovalCancelsItAndRejectsLateApproval() async throws {
        let (root, model, groupID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let approval = try await pending(model)
        await model.stopGroup(id: groupID)
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .cancelled)
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.errorMessage == nil)
    }

    @Test func stoppingLocalPermissionAndConcurrentSendAreFenced() async throws {
        let (root, model, groupID) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture") }
        let review = try await pending(model)
        await model.sendGroupMessage(groupID: groupID, text: "must not send twice")
        #expect(model.groupMessages[groupID]?.filter { $0.senderID == nil }.count == 1)
        await model.resolveGroupApproval(review, groupID: groupID, approve: true)
        for _ in 0..<600 {
            if !model.pendingToolApprovals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let local = try #require(model.pendingToolApprovals.first)
        await model.stopGroup(id: groupID)
        await run.value
        model.resolveLocalToolApproval(id: local.id, allowed: true)
        #expect(model.groupMessages[groupID]?.last?.toolActivities.first?.status == .cancelled)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        // A subsequent user turn may start normally, but needs a new approval.
        let next = Task { await model.sendGroupMessage(groupID: groupID, text: "read fixture again") }
        let nextReview = try await pending(model)
        #expect(nextReview.id != review.id)
        await model.stopGroup(id: groupID)
        await next.value
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func controlsAreLocalized(language: String) {
        for key in ["Tools & connections", "Awaiting approval or result", "Text reply · no tools used", "Text-only providers cannot use Filicon tools.", "Integrations are managed in MCP Servers and Plugins. Gmail installation cards are not supported in chat.", "No group member matches @{0}. Add the member or choose an existing name."] {
            let translated = FiliconLocalization.string(key, language: language)
            #expect(!translated.isEmpty)
            if language != "en" { #expect(translated != key) }
        }
    }
}
