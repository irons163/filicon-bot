import AppKit
import SwiftUI
import Foundation
import Testing
import CustomDump
@testable import Filicon
import FiliconAgents
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview

private struct WorkflowWritingProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "workflow-writing-fixture", displayName: "Workflow fixture", requiresAPIKey: false)
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

@Suite("Workflow writing app integration", .timeLimit(.minutes(1)))
@MainActor struct AgentWorkflowWriteAppTests {
    private func fixture() async throws -> (URL, AppModel, UUID, AgentProfile, AgentProfile) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-workflow-write-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let owner = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "OWNER_PRIVATE_PERSONA",
            providerID: "workflow-writing-fixture", modelID: "test"))
        let peer = try #require(await model.createAgent(name: "Peer", summary: "", instructions: "PEER_PRIVATE_PERSONA",
            providerID: "workflow-writing-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Review", summary: "", memberIDs: [owner.id]))
        await model.reloadWorkspaceData()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["update_state"], ask: [])
        return (root, model, try #require(model.groups.first?.id), owner, peer)
    }
    private func pending(_ model: AppModel) async throws -> PendingApproval {
        for _ in 0..<1_000 {
            if let value = model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["agentStateTarget"] == "workflow" }) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No workflow write approval appeared")
    }
    private func waitForMailbox(_ model: AppModel) async throws {
        for _ in 0..<1_000 {
            if model.runningAgentMessageScopes.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("Mailbox execution did not finish")
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "stale", "archive"], [false, true])
    func groupWriteShowsCompleteDefinitionAndRequiresFreshApproval(mode: String, updating: Bool) async throws {
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let oldBody = String(repeating: "Check keyboard access.\n", count: 120) + "OLD_BODY_END"
        let body = String(repeating: "Check text contrast.\n", count: 160) + "NEW_BODY_END"
        let old = AgentWorkflow(id: "review-layout", agentID: owner.id, name: "Layout", isEnabled: false, steps: [.prompt(oldBody)])
        if updating { #expect(await model.saveWorkflow(old)) }
        #expect(await model.saveWorkflow(.init(id: "peer-library", agentID: peer.id, name: "PEER_WORKFLOW", steps: [.prompt("PEER_BODY_PRIVATE")])) )
        if updating {
            await model.createAutomation(agentID: peer.id, name: "Layout routine", prompt: "Use [Layout](sand-workflow:review-layout)", schedule: "@daily")
        }
        let original = model.workflows
        let routines = model.automations
        var fields = ["target": "workflow", "action": "write", "name": "Accessible layout",
                      "description": "Use when checking visual accessibility.", "body": body]
        if updating { fields["id"] = old.id }
        let payload = try JSONEncoder().encode(fields)
        await model.registry.register(WorkflowWritingProvider { request, execute in
            let system = request.messages.filter { $0.role == .system }.map(\.text).joined()
            #expect(system.contains("workflow") && system.contains("8000 UTF-8 bytes"))
            #expect(!system.contains("PEER_WORKFLOW") && !system.contains("PEER_BODY_PRIVATE"))
            let result = try await execute(.init(id: "save-workflow", name: "update_state", argumentsJSON: payload))
            expectNoDifference(result.isError, mode != "approve")
            #expect(!result.content.map { String(describing: $0) }.joined().contains("PEER_"))
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Save your reusable procedure after review") }
        let approval = try await pending(model)
        let data = approval.action.context.metadata
        expectNoDifference(data["agentWorkflowBody"], body)
        expectNoDifference(data["previousAgentWorkflowBody"], updating ? oldBody : nil)
        expectNoDifference(data["agentWorkflowAction"], updating ? "update" : "create")
        expectNoDifference(data["agentWorkflowEnabled"], updating ? "false" : "true")
        expectNoDifference(data["agentWorkflowReferenceCount"], updating ? "1" : "0")
        if updating { #expect(data["agentWorkflowReferences"]?.contains("Layout routine") == true) }
        #expect(!data.values.joined().contains("PRIVATE_PERSONA"))
        expectNoDifference(model.workflows, original)
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "stale" { await model.setWorkflowEnabled(id: "peer-library", enabled: false) }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        let own = model.workflows.filter { $0.agentID == owner.id }
        if mode == "approve" {
            let saved = try #require(own.first)
            expectNoDifference(own.count, 1); expectNoDifference(saved.steps, [.prompt(body)])
            expectNoDifference(saved.name, "Accessible layout")
            expectNoDifference(saved.isEnabled, !updating)
            let referenced = WorkflowComposerReferences.referencedWorkflows(in: "[Use](sand-workflow:\(saved.id))", workflows: model.workflows)
            expectNoDifference(referenced, updating ? [] : [saved])
        } else { expectNoDifference(own, original.filter { $0.agentID == owner.id }) }
        expectNoDifference(model.automations, routines)
        #expect(model.workflowRuns.isEmpty && model.runningGroups.isEmpty && model.pendingAutoReviewApprovals.isEmpty)
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkflows()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let persisted = try decoder.decode([AgentWorkflow].self, from: encoder.encode(model.workflows))
        expectNoDifference(restored.workflows, persisted)
    }

    @Test func mailboxUsesRecipientIdentityNotSender() async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(WorkflowWritingProvider { _, execute in
            let result = try await execute(.init(id: "write", name: "update_state", argumentsJSON: Data(#"{"target":"workflow","action":"write","name":"Review","description":"Use when reviewing","body":"Check contrast"}"#.utf8)))
            #expect(!result.isError)
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Save your reusable procedure"))
        let approval = try await pending(model)
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        expectNoDifference(model.workflows.map(\.agentID), [recipient.id])
        #expect(model.workflowRuns.isEmpty)
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "stale", "archive"])
    func groupDeletionRequiresDestructiveApprovalAndPreservesReferences(mode: String) async throws {
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "Keep keyboard access.\n", count: 160) + "DELETE_BODY_END"
        let old = AgentWorkflow(id: "layout", agentID: owner.id, name: "Layout", steps: [.prompt(body)])
        #expect(await model.saveWorkflow(old))
        #expect(await model.saveWorkflow(.init(id: "peer-reference", agentID: peer.id, name: "Peer reference", steps: [.prompt("@Layout\nPEER_PRIVATE_BODY")])))
        await model.createAutomation(agentID: peer.id, name: "Daily layout", prompt: "[Use](sand-workflow:layout)", schedule: "@daily")
        let original = model.workflows, routines = model.automations
        await model.registry.register(WorkflowWritingProvider { _, execute in
            let result = try await execute(.init(id: "delete-workflow", name: "update_state",
                argumentsJSON: Data(#"{"target":"workflow","action":"delete","id":"layout"}"#.utf8)))
            expectNoDifference(result.isError, mode != "approve")
            let output = result.content.map { String(describing: $0) }.joined()
            let leakedLabels = ["PRIVATE", "Daily layout", "Peer reference"].filter { output.contains($0) }
            expectNoDifference(leakedLabels, [])
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Delete your reusable workflow after review") }
        let approval = try await pending(model), data = approval.action.context.metadata
        expectNoDifference(data["agentWorkflowAction"], "delete")
        expectNoDifference(data["previousAgentWorkflowBody"], body)
        expectNoDifference(data["agentWorkflowBody"], nil)
        expectNoDifference(data["agentWorkflowReferenceCount"], "2")
        #expect(data["agentWorkflowReferences"]?.contains("Peer reference") == true)
        #expect(data["agentWorkflowReferences"]?.contains("Daily layout") == true)
        #expect(approval.action.risks.contains(.destructive))
        #expect(!data.values.joined().contains("PRIVATE"))
        expectNoDifference(model.workflows, original)
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "stale" { await model.setWorkflowEnabled(id: "peer-reference", enabled: false) }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        expectNoDifference(model.workflows.filter { $0.agentID == owner.id }, mode == "approve" ? [] : original.filter { $0.agentID == owner.id })
        let survivingPeer = try #require(model.workflows.first { $0.id == "peer-reference" })
        expectNoDifference(survivingPeer.steps, [.prompt("@Layout\nPEER_PRIVATE_BODY")])
        expectNoDifference(model.automations, routines)
        #expect(model.runningGroups.isEmpty && model.pendingAutoReviewApprovals.isEmpty && model.workflowRuns.isEmpty)
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkflows()
        expectNoDifference(restored.workflows.map(\.id), model.workflows.map(\.id))
    }

    @Test func mailboxDeletionUsesRecipientOwnerAndPreservesSenderDefinition() async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await model.saveWorkflow(.init(id: "sender-layout", agentID: sender.id, name: "Sender", steps: [.prompt("Sender body")])) )
        #expect(await model.saveWorkflow(.init(id: "recipient-layout", agentID: recipient.id, name: "Recipient", steps: [.prompt("Recipient body")])) )
        await model.registry.register(WorkflowWritingProvider { _, execute in
            // Mailbox exposes the executor's typed error rather than the group's
            // error-result wrapper. Keep the provider alive to try its own ID next.
            do {
                _ = try await execute(.init(id: "delete-sender", name: "update_state",
                    argumentsJSON: Data(#"{"target":"workflow","action":"delete","id":"sender-layout"}"#.utf8)))
                Issue.record("Mailbox deletion unexpectedly accepted the sender's workflow")
            } catch {
                expectNoDifference(error as? AgentWorkflowDeletionError, .unavailable)
            }
            let result = try await execute(.init(id: "delete-recipient", name: "update_state",
                argumentsJSON: Data(#"{"target":"workflow","action":"delete","id":"recipient-layout"}"#.utf8)))
            #expect(!result.isError)
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Delete your procedure after approval"))
        let approval = try await pending(model)
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        expectNoDifference(approval.action.context.metadata["agentWorkflowID"], "recipient-layout")
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        expectNoDifference(model.workflows.map(\.id), ["sender-layout"])
    }

    @Test func fullApprovalRendersInSevenLanguagesAndBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for action in ["create", "update", "delete"] {
                for dark in [false, true] {
                    try FiliconLocalization.$languageOverride.withValue(language) {
                        let keys = ["Save reusable workflow", "Rewrite reusable workflow", "Current workflow", "Proposed workflow", "Full workflow body", "Known direct references", "Workflow enabled", "Workflow disabled", AgentWorkflowApprovalDetails.disclosure, AgentWorkflowApprovalDetails.referenceNotice,
                            AgentWorkflowWriteError.invalid.localizedDescription, AgentWorkflowWriteError.stale.localizedDescription, AgentWorkflowWriteError.unavailable.localizedDescription,
                            "Delete reusable workflow", AgentWorkflowApprovalDetails.deletionDisclosure, AgentWorkflowDeletionError.invalid.localizedDescription, AgentWorkflowDeletionError.unavailable.localizedDescription]
                        if language != "en" { for key in keys { #expect(FiliconLocalization.string(key) != key) } }
                        var metadata = ["agentWorkflowAction": action, "agentName": "Designer / 設計師", "agentWorkflowID": "agent-00000000-0000-0000-0000-000000000099",
                            "agentWorkflowName": "Accessible layout", "agentWorkflowDescription": "Use when checking keyboard access and contrast.", "agentWorkflowEnabled": "true",
                            "agentWorkflowBody": "Check focus order.\nVerify contrast with real text.\n保持鍵盤導覽可用。\nNEW_BODY_END",
                            "previousAgentWorkflowName": "Layout", "previousAgentWorkflowDescription": "Use when reviewing.", "previousAgentWorkflowEnabled": "true",
                            "previousAgentWorkflowBody": "Check layout.\nOLD_BODY_END", "agentWorkflowReferenceCount": "1",
                            "agentWorkflowReferences": "Layout routine (routine:00000000-0000-0000-0000-000000000001)"]
                        if action == "delete" {
                            for key in ["agentWorkflowName", "agentWorkflowDescription", "agentWorkflowEnabled", "agentWorkflowBody"] { metadata.removeValue(forKey: key) }
                        }
                        let host = NSHostingView(rootView: AgentWorkflowApprovalDetails(metadata: metadata).padding(20).frame(width: 420)
                            .background(FiliconTheme.input).environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        host.frame = .init(x: 0, y: 0, width: 420, height: 2_000)
                        host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.height > 400 && host.fittingSize.height < 2_000)
                        host.frame.size.height = host.fittingSize.height; host.layoutSubtreeIfNeeded()
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        if let output {
                            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "workflow-\(action)-\(language)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }
}
