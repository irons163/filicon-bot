import Foundation
import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconLocalTools
@testable import Filicon

private struct BackgroundAgentProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "background-fixture", displayName: "Background fixture", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor BackgroundProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) { requests.append(request) }
}

@Suite("Agent background execution", .timeLimit(.minutes(1)))
@MainActor struct AgentBackgroundExecutionTests {
    private func fixture() async throws -> (URL, AppModel, AgentProfile, AgentProfile) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-background-\(UUID())")
        let generation = UUID(), key = LocalToolRuntime.randomSessionKey()
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let host = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true, authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json")), generation: generation, sessionKey: key, helper: host)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
        let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "SENDER_PRIVATE_PERSONA", providerID: "background-fixture", modelID: "test"))
        let recipient = try #require(await model.createAgent(name: "Recipient", summary: "", instructions: "RECIPIENT_PRIVATE_PERSONA", providerID: "background-fixture", modelID: "test"))
        await model.reloadWorkspaceData()
        return (root, model, sender, recipient)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(predicate(), "Background operation did not reach its expected state")
    }

    @Test func manualSendWakesPeerAndReplyWakesSenderWithoutSelectingEitherChat() async throws {
        let (root, model, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = BackgroundProbe()
        await model.registry.register(BackgroundAgentProvider { request, execute in
            await probe.record(request)
            if request.messages[0].text.contains("You are Recipient,") {
                #expect(!request.messages.map(\.text).joined().contains("SENDER_PRIVATE_PERSONA"))
                let args = try JSONEncoder().encode(["recipientID": sender.id.uuidString, "message": "Concrete review result"])
                let reply = try await execute(.init(id: "reply", name: "SendToAgent", argumentsJSON: args))
                #expect(!reply.isError)
                return "Review finished"
            }
            #expect(!request.messages.map(\.text).joined().contains("RECIPIENT_PRIVATE_PERSONA"))
            let report = try await execute(.init(id: "report", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": "Review incorporated"])))
            #expect(!report.isError)
            return "INTERNAL_FINAL_MUST_NOT_DUPLICATE"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Review this layout"))
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
        let wakeCount = await probe.requests.count
        expectNoDifference(wakeCount, 2)
        expectNoDifference(model.agentMessages.count, 2)
        expectNoDifference(Set(model.agentMessages.compactMap { $0.delivery?.state }), [.completed])
        #expect(model.agentMessages.contains { $0.delivery?.response == "Review incorporated" })
        #expect(model.agentMessages.allSatisfy { $0.delivery?.response?.contains("INTERNAL_FINAL") != true })
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func laterManualRequestRestoresSamePrivateContextAfterAppModelRecreation() async throws {
        let (root, first, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = BackgroundProbe()
        let provider = BackgroundAgentProvider { request, _ in
            await probe.record(request)
            return "PERSISTED_REVIEW_RESULT"
        }
        await first.registry.register(provider)
        #expect(await first.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "First task"))
        try await waitUntil { first.runningAgentMessageScopes.isEmpty }
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        await reopened.registry.register(provider)
        // Loading history alone must not rerun old tasks.
        let previousWakeCount = await probe.requests.count
        expectNoDifference(previousWakeCount, 1)
        #expect(await reopened.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Continue that review"))
        try await waitUntil { reopened.runningAgentMessageScopes.isEmpty }
        let requests = await probe.requests
        expectNoDifference(requests.count, 2)
        expectNoDifference(requests[0].conversationID, requests[1].conversationID)
        #expect(requests[1].messages.dropLast().contains { $0.text.contains("PERSISTED_REVIEW_RESULT") })
        #expect(requests[1].messages.last?.text.contains("Continue that review") == true)
    }

    @Test(arguments: [false, true]) func publishedMailboxProgressSurvivesFailureOrStop(stop: Bool) async throws {
        let (root, model, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(BackgroundAgentProvider { _, execute in
            let result = try await execute(.init(id: "progress", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": "Completed the first review step"])))
            #expect(!result.isError)
            if stop { try await Task.sleep(for: .seconds(5)) }
            throw ProviderError.invalidResponse
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Review the layout"))
        if stop {
            try await waitUntil { model.agentMessages.first?.delivery?.response == "Completed the first review step" }
            let scope = try #require(model.runningAgentMessageScopes.first)
            await model.stopAgentMessages(scopeID: scope)
        }
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
        expectNoDifference(model.agentMessages.first?.delivery?.state, stop ? .cancelled : .failed)
        expectNoDifference(model.agentMessages.first?.delivery?.response, "Completed the first review step")
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.agentMessages.first?.delivery?.response, "Completed the first review step")
    }

    @Test(arguments: [false, true]) func stopOrAccountChangeWhileDelegationAwaitsApprovalRejectsLateApproval(accountChange: Bool) async throws {
        let (root, model, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try #require(await model.createAgent(name: "Other", summary: "", instructions: "", providerID: "background-fixture", modelID: "test"))
        let probe = BackgroundProbe()
        await model.registry.register(BackgroundAgentProvider { request, execute in
            await probe.record(request)
            _ = try await execute(.init(id: "forward", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(["recipientID": other.id.uuidString, "message": "Review something else"])))
            return "Should not complete"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Review"))
        try await waitUntil { !model.pendingAutoReviewApprovals.isEmpty }
        let pending = try #require(model.pendingAutoReviewApprovals.first)
        let scope = pending.action.context.conversationID
        // Another click cannot start an overlapping chain in this mailbox.
        #expect(!(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Duplicate click")))
        if accountChange { await model.cancelAutoReviewApprovals(nextAccountID: "new-test-account") }
        else { await model.stopAgentMessages(scopeID: scope) }
        await model.resolveGroupApproval(pending, groupID: scope, approve: true)
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
        let wakeCount = await probe.requests.count
        expectNoDifference(wakeCount, 1)
        expectNoDifference(model.agentMessages.count, 1)
        expectNoDifference(model.agentMessages.first?.delivery?.state, .cancelled)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test(arguments: [false, true]) func manualWakeFileWriteStillRequiresBothHostApprovals(allow: Bool) async throws {
        let (root, model, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await model.localToolRuntime.workspaceStore.authorize(root)
        try await model.localToolPermissionPolicy.setChoice(.ask, for: .writeFile)
        await model.setAutoReviewEnabled(true)
        await model.registry.register(BackgroundAgentProvider { _, execute in
            let args = try JSONEncoder().encode(["root": root.path, "path": "result.txt", "content": "approved result"])
            let result = try await execute(.init(id: "write", name: "local__write_file", argumentsJSON: args))
            return result.isError ? "No write" : "Written"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Write result.txt"))
        try await waitUntil { !model.pendingAutoReviewApprovals.isEmpty }
        let approval = try #require(model.pendingAutoReviewApprovals.first)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "result.txt").path))
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitUntil { !model.pendingToolApprovals.isEmpty }
        let local = try #require(model.pendingToolApprovals.first)
        expectNoDifference(local.conversationID, approval.action.context.conversationID)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "result.txt").path))
        model.resolveLocalToolApproval(id: local.id, allowed: allow)
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
        expectNoDifference(FileManager.default.fileExists(atPath: root.appending(path: "result.txt").path), allow)
        expectNoDifference(model.agentMessages.first?.delivery?.response, allow ? "Written" : "No write")
    }

    @Test func groupSendMessagePublishesBeforeProviderFinishesWithoutFinalDuplicate() async throws {
        let (root, model, sender, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await model.createGroup(name: "Test room", summary: "", memberIDs: [sender.id]))
        let groupID = try #require(model.groups.first?.id)
        await model.registry.register(BackgroundAgentProvider { _, execute in
            let result = try await execute(.init(id: "publish", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": "Visible progress"])))
            #expect(!result.isError)
            try await Task.sleep(for: .seconds(5))
            return "SHOULD_NOT_APPEAR"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Report progress") }
        try await waitUntil { model.groupMessages[groupID]?.contains { $0.text == "Visible progress" } == true }
        #expect(model.runningGroups.contains(groupID))
        await model.stopGroup(id: groupID)
        await run.value
        expectNoDifference(model.groupMessages[groupID]?.filter { $0.text == "Visible progress" }.count, 1)
        #expect(model.groupMessages[groupID]?.contains { $0.text == "SHOULD_NOT_APPEAR" } == false)
    }

    @Test func groupSendMessageRespectsTwoMessageBudgetAndSuppressesFinalEcho() async throws {
        let (root, model, sender, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await model.createGroup(name: "Test room", summary: "", memberIDs: [sender.id]))
        let groupID = try #require(model.groups.first?.id)
        await model.registry.register(BackgroundAgentProvider { _, execute in
            for index in 1...3 {
                let result = try await execute(.init(id: ToolCallID(rawValue: "publish-\(index)"), name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": "Report \(index)"])))
                expectNoDifference(result.isError, index == 3)
            }
            return "Report 2"
        })
        await model.sendGroupMessage(groupID: groupID, text: "Report progress")
        let replies = model.groupMessages[groupID, default: []].filter { $0.senderID != nil && !$0.text.isEmpty }
        expectNoDifference(replies.map(\.text), ["Report 1", "Report 2"])
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.groupMessages[groupID, default: []].filter { !$0.text.isEmpty }.map(\.text), ["Report progress", "Report 1", "Report 2"])
    }

    @Test func manualFolderSelectionCanBeCancelledInMessagePage() async throws {
        let (root, model, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(BackgroundAgentProvider { _, execute in
            let result = try await execute(.init(id: "folders", name: "local__workspace_folders", argumentsJSON: Data("{}".utf8)))
            #expect(result.wireText.contains("cancel") || result.wireText.contains("declin"))
            return "Folder selection cancelled"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Inspect a project"))
        try await waitUntil { !model.pendingWorkspaceFolders.isEmpty }
        let request = try #require(model.pendingWorkspaceFolders.first)
        #expect(model.runningAgentMessageScopes.contains(request.conversationID))
        model.workspaceFolders.decline(request)
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
        #expect(model.pendingWorkspaceFolders.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
    }

    @Test func messagePageRendersPendingApprovalInAllSupportedLanguages() async throws {
        let (root, model, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let third = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "background-fixture", modelID: "test"))
        await model.registry.register(BackgroundAgentProvider { _, execute in
            _ = try await execute(.init(id: "delegate", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(["recipientID": third.id.uuidString, "message": "Review button contrast and spacing."])))
            return "Finished"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Review the layout"))
        try await waitUntil { !model.pendingAutoReviewApprovals.isEmpty }
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
                let host = NSHostingView(rootView: AgentMessagingView().environmentObject(model)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 980, height: 780)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(!png.isEmpty)
                if let output { try png.write(to: output.appending(path: "agent-mailbox-\(language).png")) }
            }
        }
        for scope in model.runningAgentMessageScopes { await model.stopAgentMessages(scopeID: scope) }
        try await waitUntil { model.runningAgentMessageScopes.isEmpty }
    }
}
