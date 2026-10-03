import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
import FiliconDomain
import FiliconProviderKit
import FiliconLocalTools
@testable import Filicon

private actor WorkflowDirectProbe {
    var plain: [InferenceRequest] = []
    var shared: [InferenceRequest] = []
    var finished = 0
    func plainRequest(_ request: InferenceRequest) { plain.append(request) }
    func sharedRequest(_ request: InferenceRequest) -> Int {
        shared.append(request)
        return shared.filter { $0.conversationID == request.conversationID }.count
    }
    func finish() { finished += 1 }
}
private actor WorkflowDirectGate {
    var started = false
    var open = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { value in
            if open { value.resume() } else { continuation = value }
        }
    }
    func release() { open = true; continuation?.resume(); continuation = nil }
}
private struct WorkflowDirectProvider: InteractiveToolProvider {
    var supportsTools = true
    var descriptor: ProviderDescriptor {
        .init(id: "workflow-direct-fixture", displayName: "Workflow fixture", requiresAPIKey: false, supportsToolCalling: supportsTools)
    }
    let probe: WorkflowDirectProbe
    var gate: WorkflowDirectGate? = nil
    var question = false
    var silent = false
    var writeRoot: URL? = nil
    var peerID: UUID? = nil
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.plainRequest(request)
                continuation.yield(.textDelta("LEGACY_WORKFLOW"))
                continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let index = await probe.sharedRequest(request)
                    await gate?.wait() // Deliberately ignores cancellation: host gates must reject late effects.
                    let owner = request.messages.first?.text.contains("WORKFLOW_PERSONA") == true
                    if owner, index == 1, let peerID {
                        _ = try await executeTool(.init(id: "workflow-peer", name: "SendToAgent",
                            argumentsJSON: JSONEncoder().encode(["recipientID": peerID.uuidString, "message": "Review only this explicitly delivered fixture task."])))
                    }
                    if let writeRoot {
                        _ = try await executeTool(.init(id: ToolCallID(rawValue: "workflow-write-\(index)"), name: "local__write_file",
                            argumentsJSON: JSONEncoder().encode(["root": writeRoot.path, "path": "workflow-created.txt", "content": "APPROVED_WORKFLOW_WRITE"])))
                    }
                    if question, request.messages.contains(where: { $0.role == .system && $0.text.contains("host-bound background workflow wake") }) {
                        _ = try await executeTool(.init(id: "workflow-question", name: "SendMessage",
                            argumentsJSON: Data(#"{"type":"widget","widget":{"prompt":"Choose the next step","options":[{"label":"Inspect only","value":"Inspect only"}]}}"#.utf8)))
                        Issue.record("A workflow question must suspend this turn")
                    } else if !silent {
                        _ = try await executeTool(.init(id: ToolCallID(rawValue: "workflow-publication-\(index)"), name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(["text": owner ? "WORKFLOW_PUBLISHED_\(index)" : "WORKFLOW_PEER_RESULT"])))
                    }
                    continuation.yield(.usage(.init(inputTokens: 8, outputTokens: 3)))
                    continuation.yield(.textDelta("PRIVATE_WORKFLOW_DRAFT"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
                await probe.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Workflow direct sessions", .timeLimit(.minutes(1)))
@MainActor struct WorkflowDirectSessionTests {
    private let base = Date(timeIntervalSince1970: 1_000)
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
    private func fixture(trigger: AgentWorkflowTrigger = .manual, twoSteps: Bool = false, reference: Bool = false,
                         question: Bool = false, silent: Bool = false, gate: WorkflowDirectGate? = nil,
                         write: Bool = false, peer: Bool = false) async throws -> (URL, AppModel, AgentWorkflow, UUID, WorkflowDirectProbe) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-workflow-direct-\(UUID())")
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        let agent = try await service.create(name: "Workflow owner", instructions: "WORKFLOW_PERSONA",
            providerID: "workflow-direct-fixture", modelID: "fixture", at: base)
        try await service.applyMemoryChange(.init(operation: .write, memory: .init(accountID: "local", agentID: agent.id,
            fact: "WORKFLOW_PRIVATE_FACT", createdAt: base)), lifetime: .init())
        if peer {
            let profile = try await service.create(name: "Workflow peer", instructions: "WORKFLOW_PEER_PERSONA",
                providerID: agent.providerID, modelID: agent.modelID, at: base.addingTimeInterval(1))
            try await service.applyMemoryChange(.init(operation: .write, memory: .init(accountID: "local", agentID: profile.id,
                fact: "WORKFLOW_PEER_PRIVATE_FACT", createdAt: base)), lifetime: .init())
        }
        let recipes = try AgentWorkflowStore(persistenceURL: root.appending(path: "workflows.json"))
        if reference { _ = try await recipes.create(.init(id: "referenced", name: "Reviewed reference", steps: [.prompt("REVIEWED_REFERENCE_BODY")])) }
        let first = reference ? "WORKFLOW_TASK_0 sand-workflow:referenced" : "WORKFLOW_TASK_0"
        let saved = try await recipes.create(.init(id: "primary", agentID: agent.id, name: "Reviewed workflow",
            isEnabled: false, trigger: trigger, steps: [.prompt(first)] + (twoSteps ? [.prompt("WORKFLOW_TASK_1")] : [])))
        var conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000093")!, title: "Reviewed workflow conversation",
            providerID: agent.providerID, modelID: agent.modelID, messages: [.init(role: .user, text: "WORKFLOW_REVIEWED_HISTORY", createdAt: base)], updatedAt: base)
        conversation.agentBinding = .init(accountID: "local", agentID: agent.id)
        let unrelated = Conversation(title: "Other", messages: [.init(role: .user, text: "WORKFLOW_UNRELATED_SECRET", createdAt: base)])
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save([conversation, unrelated])
        let model: AppModel
        if write {
            let generation = UUID(), key = LocalToolRuntime.randomSessionKey(), authenticator = LocalSessionAuthenticator(sessionKey: key)
            let host = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
                authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
            let runtime = LocalToolRuntime(workspaceStore: WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json")),
                generation: generation, sessionKey: key, helper: host)
            model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
            _ = try await runtime.workspaceStore.authorize(root)
            try await model.localToolPermissionPolicy.setChoice(.ask, for: .writeFile)
        } else { model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false) }
        let probe = WorkflowDirectProbe()
        await model.registry.register(WorkflowDirectProvider(probe: probe, gate: gate, question: question, silent: silent, writeRoot: write ? root : nil))
        await model.bootstrap()
        model.setWorkflowRuntimeActive(false)
        await model.setAutomationRuntimeActive(false)
        await model.setWorkflowEnabled(id: saved.id, enabled: true)
        let workflow = try #require(model.workflows.first { $0.id == saved.id })
        try await model.loadAllMessages(for: conversation.id)
        model.selectRoute(.conversation(conversation.id))
        return (root, model, workflow, conversation.id, probe)
    }
    private func approve(_ model: AppModel, workflow: AgentWorkflow, id: UUID, memory: Bool = false) async throws {
        let edit = try #require(model.beginWorkflowDirectSessionEdit(workflow))
        try #require(await model.saveWorkflowDirectSession(edit, conversationID: id, memoryAccess: memory ? .savedFacts : .none))
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Workflow did not reach the expected boundary")
        throw WorkflowDirectSessionError.unavailable
    }
    @Test(arguments: [false, true])
    func everyStepUsesReviewedHistoryToolsAndIndependentMemory(memory: Bool) async throws {
        let (root, model, workflow, id, probe) = try await fixture(twoSteps: true, reference: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id, memory: memory)
        await model.runWorkflowNow(id: workflow.id)
        let run = try #require(model.workflowRuns.first { $0.workflowID == workflow.id })
        expectNoDifference(run.status, .succeeded)
        expectNoDifference(run.outputs, ["WORKFLOW_PUBLISHED_1", "WORKFLOW_PUBLISHED_2"])
        let requests = await probe.shared, plain = await probe.plain
        expectNoDifference(requests.count, 2); expectNoDifference(plain.count, 0)
        for request in requests {
            expectNoDifference(request.conversationID, id)
            let text = request.messages.map(\.text).joined(separator: "\n")
            #expect(text.contains("WORKFLOW_REVIEWED_HISTORY"))
            #expect(!text.contains("WORKFLOW_UNRELATED_SECRET") && !text.contains("PRIVATE_WORKFLOW_DRAFT"))
            expectNoDifference(text.contains("WORKFLOW_PRIVATE_FACT"), memory)
        }
        #expect(requests[0].messages.map(\.text).joined().contains("REVIEWED_REFERENCE_BODY"))
        #expect(requests[1].messages.last?.text.contains("WORKFLOW_PUBLISHED_1") == true)
        let durable = try #require(try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: id))
        #expect(durable.messages.contains { $0.id == run.id && $0.text == "WORKFLOW_PUBLISHED_1" })
        #expect(!durable.messages.contains { $0.role == .user && $0.text.contains("WORKFLOW_TASK") })
        #expect(!durable.messages.contains { $0.text.contains("PRIVATE_WORKFLOW_DRAFT") })
        #expect(!model.isConversationWorking(id))
    }
    @Test(arguments: ["event", "schedule", "replay"])
    func allOtherEntryPointsUseSameReviewedSession(entry: String) async throws {
        let trigger: AgentWorkflowTrigger = entry == "event" ? .event("connector:\(connector.uuidString.lowercased()):fixture") : .schedule("@hourly")
        let (root, model, workflow, id, probe) = try await fixture(trigger: trigger)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id)
        if entry == "event" {
            await model.dispatchWorkflowAuthenticatedEvent(.init(connectorID: connector, kind: "fixture", externalEventID: "fixture-1", payloadJSON: Data("{}".utf8), occurredAt: base))
        } else if entry == "schedule" {
            let due = try #require(model.workflowNextRuns["@hourly"])
            await model.runWorkflowScheduleTick(now: due)
        } else {
            await model.runWorkflowNow(id: workflow.id)
            let original = try #require(model.workflowRuns.first)
            await model.replayWorkflowRun(id: original.id)
            #expect(model.workflowRuns.contains { $0.origin == .replay(original.id) && $0.status == .succeeded })
        }
        let requests = await probe.shared, plain = await probe.plain
        expectNoDifference(requests.count, entry == "replay" ? 2 : 1); expectNoDifference(plain.count, 0)
        #expect(model.workflowRuns.allSatisfy { $0.status == .succeeded })
        #expect(requests.allSatisfy { $0.conversationID == id })
    }
    @Test func unreviewedWorkflowDoesNotReadConversationAndRevocationRestoresTextOnly() async throws {
        let (root, model, workflow, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.runWorkflowNow(id: workflow.id)
        try await approve(model, workflow: workflow, id: id)
        await model.revokeWorkflowDirectSession(try #require(model.workflowDirectBindings.first))
        await model.runWorkflowNow(id: workflow.id)
        let plain = await probe.plain, shared = await probe.shared
        expectNoDifference(shared.count, 0); expectNoDifference(plain.count, 2)
        #expect(plain.allSatisfy { !$0.messages.map(\.text).joined().contains("WORKFLOW_REVIEWED_HISTORY") })
        expectNoDifference(model.conversations.first { $0.id == id }?.messages.map(\.text), ["WORKFLOW_REVIEWED_HISTORY"])
    }
    @Test(arguments: ["definition", "reference", "account", "persona", "binding", "busy", "provider"])
    func staleOrBusyGrantNeverFallsBack(change: String) async throws {
        let (root, model, workflow, id, probe) = try await fixture(reference: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id)
        switch change {
        case "definition": await model.setWorkflowEnabled(id: workflow.id, enabled: false)
        case "reference":
            var reference = try #require(model.workflows.first { $0.id == "referenced" })
            reference.steps = [.prompt("UNREVIEWED_REFERENCE")]; #expect(await model.saveWorkflow(reference, replacingID: reference.id))
        case "account": model.settings.accountScope = "other"
        case "persona":
            var profile = try #require(model.agents.first { $0.id == workflow.agentID })
            profile.instructions = "UNREVIEWED_PERSONA"; #expect(await model.updateAgent(profile))
        case "binding":
            let index = try #require(model.conversations.firstIndex { $0.id == id })
            model.conversations[index].agentBinding = .init(accountID: "other", agentID: try #require(workflow.agentID))
        case "busy": model.running.insert(id)
        default: await model.registry.register(WorkflowDirectProvider(supportsTools: false, probe: probe))
        }
        await model.runWorkflowNow(id: workflow.id)
        expectNoDifference(model.workflowRuns.first?.status, .failed)
        let plain = await probe.plain, shared = await probe.shared
        expectNoDifference(plain.count, 0); expectNoDifference(shared.count, 0)
    }
    @Test func changingAReferenceWhileReviewIsOpenCannotSaveConsent() async throws {
        let (root, model, workflow, id, _) = try await fixture(reference: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try #require(model.beginWorkflowDirectSessionEdit(workflow))
        var reference = try #require(model.workflows.first { $0.id == "referenced" })
        reference.steps = [.prompt("CHANGED_AFTER_REVIEW")]; #expect(await model.saveWorkflow(reference, replacingID: reference.id))
        #expect(await model.saveWorkflowDirectSession(edit, conversationID: id, memoryAccess: .savedFacts) == false)
        #expect(model.workflowDirectBindings.isEmpty)
    }
    @Test(arguments: ["reasoning", "provider", "binding"])
    func queuedProjectionRestoreCannotHideAStaleReview(change: String) async throws {
        let (root, model, workflow, id, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try #require(model.beginWorkflowDirectSessionEdit(workflow))
        let index = try #require(model.conversations.firstIndex { $0.id == id })
        let originalProjection = model.conversations
        switch change {
        case "reasoning": model.conversations[index].reasoningEffort = .high
        case "provider": model.conversations[index].providerID = "other-fixture"
        default: model.conversations[index].agentBinding = .init(accountID: "other", agentID: try #require(workflow.agentID))
        }
        let restore = Task { @MainActor in model.conversations = originalProjection }
        #expect(await model.saveWorkflowDirectSession(edit, conversationID: id, memoryAccess: .savedFacts) == false)
        await restore.value
        expectNoDifference(model.workflowDirectBindings, [])
        let stored = try await WorkflowDirectSessionBindingStore(url: root.appending(path: "workflow-direct-sessions.json")).list()
        expectNoDifference(stored, [])
    }
    @Test func anotherAccountCannotReplaceOrRevokeTheReviewedSession() async throws {
        let (root, model, workflow, id, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id)
        let original = try #require(model.workflowDirectBindings.first)
        model.settings.accountScope = "other"
        let edit = try #require(model.beginWorkflowDirectSessionEdit(workflow))
        #expect(await model.saveWorkflowDirectSession(edit, conversationID: id, memoryAccess: .savedFacts) == false)
        expectNoDifference(model.workflowError, WorkflowDirectSessionError.anotherAccount.rawValue)
        await model.revokeWorkflowDirectSession(original)
        let persisted = try await WorkflowDirectSessionBindingStore(url: root.appending(path: "workflow-direct-sessions.json")).list()
        expectNoDifference(persisted, [original])
    }
    @Test func questionStopsLaterStepsAndHumanReplyIsNotAnotherWorkflowWake() async throws {
        let (root, model, workflow, id, probe) = try await fixture(twoSteps: true, question: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id)
        await model.runWorkflowNow(id: workflow.id)
        expectNoDifference(model.workflowRuns.first?.status, .waitingForReply)
        let row = try #require(model.conversations.first { $0.id == id }?.messages.first { $0.transcriptCards.contains { $0.directQuestion?.isPending == true } })
        let card = try #require(row.transcriptCards.first { $0.directQuestion?.isPending == true })
        await model.runWorkflowNow(id: workflow.id)
        expectNoDifference(model.workflowRuns.first?.status, .failed)
        let before = await probe.shared.count
        expectNoDifference(before, 1)
        await model.directQuestionAnswered(conversationID: id, messageID: row.id, cardID: card.id, answer: .option(0))
        try await eventually { !model.isConversationWorking(id) }
        let requests = await probe.shared
        expectNoDifference(requests.count, 2)
        #expect(!requests.last!.messages.contains { $0.role == .system && $0.text.contains("host-bound background workflow wake") })
        #expect(!requests.last!.messages.last!.text.contains("WORKFLOW_TASK_1"))
        #expect(model.workflowRuns.contains { $0.status == .waitingForReply })
    }
    @Test(arguments: ["stop", "account", "definition", "reference", "revoke", "delete"])
    func lateProviderCannotPublishOrExecuteNextStep(change: String) async throws {
        let gate = WorkflowDirectGate()
        let (root, model, workflow, id, probe) = try await fixture(twoSteps: true, reference: true, gate: gate)
        defer { try? FileManager.default.removeItem(at: root) }
        defer { Task { await gate.release() } }
        try await approve(model, workflow: workflow, id: id)
        let work = Task { await model.runWorkflowNow(id: workflow.id) }
        defer { work.cancel() }
        try await eventually { await gate.started }
        switch change {
        case "stop": model.cancel()
        case "account": await model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "definition": await model.setWorkflowEnabled(id: workflow.id, enabled: false)
        case "reference":
            var reference = try #require(model.workflows.first { $0.id == "referenced" })
            reference.steps = [.prompt("NEW_REFERENCE")]; #expect(await model.saveWorkflow(reference, replacingID: reference.id))
        case "revoke": await model.revokeWorkflowDirectSession(try #require(model.workflowDirectBindings.first))
        default: model.deleteConversation(id: id)
        }
        await gate.release(); await work.value
        try await eventually { await probe.finished == 1 }
        let history = await model.workflowService?.runs(workflowID: workflow.id)
        expectNoDifference(history?.first?.status, .cancelled)
        let count = await probe.shared.count
        expectNoDifference(count, 1)
        #expect(!model.conversations.flatMap(\.messages).contains { $0.text.hasPrefix("WORKFLOW_PUBLISHED_") })
        #expect(!model.isConversationWorking(id))
        if change == "delete" {
            let saved = try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: id)
            expectNoDifference(saved, nil)
        }
    }
    @Test(arguments: [false, true])
    func localWriteNeedsBothExistingApprovalsAndRealRunIdentity(allow: Bool) async throws {
        let (root, model, workflow, id, _) = try await fixture(write: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id)
        await model.setAutoReviewEnabled(true)
        let work = Task { await model.runWorkflowNow(id: workflow.id) }
        defer { work.cancel() }
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty }
        let review = try #require(model.pendingAutoReviewApprovals.first)
        let run = try #require(await model.workflowService?.runs(workflowID: workflow.id).first)
        expectNoDifference(review.fence.runID, run.id)
        expectNoDifference(review.action.context.conversationID, id)
        let target = root.appending(path: "workflow-created.txt")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        model.handleTranscriptCardIntent(.approveReview(reviewID: review.id))
        try await eventually { !model.pendingToolApprovals.isEmpty }
        let permission = try #require(model.pendingToolApprovals.first)
        expectNoDifference(permission.conversationID, id)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        model.resolveLocalToolApproval(id: permission.id, allowed: allow)
        await work.value
        expectNoDifference(model.workflowRuns.first?.status, .succeeded)
        expectNoDifference(FileManager.default.fileExists(atPath: target.path), allow)
        if allow { expectNoDifference(try String(contentsOf: target, encoding: .utf8), "APPROVED_WORKFLOW_WRITE") }
        expectNoDifference(model.conversations.first { $0.id == id }?.messages.flatMap(\.toolActivities).first { $0.name == "local__write_file" }?.status, allow ? .succeeded : .failed)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.pendingToolApprovals.isEmpty)
    }
    @Test(arguments: [false, true])
    func peerNeedsApprovalAndCannotBorrowWorkflowMemoryConsent(allow: Bool) async throws {
        let (root, model, workflow, id, probe) = try await fixture(peer: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try #require(model.agents.first { $0.name == "Workflow peer" })
        await model.registry.register(WorkflowDirectProvider(probe: probe, peerID: peer.id))
        try await approve(model, workflow: workflow, id: id, memory: true)
        await model.setAutoReviewEnabled(true)
        let work = Task { await model.runWorkflowNow(id: workflow.id) }
        defer { work.cancel() }
        try await eventually { model.pendingAutoReviewApprovals.contains { $0.action.context.metadata["tool"] == "SendToAgent" } }
        let pending = try #require(model.pendingAutoReviewApprovals.first { $0.action.context.metadata["tool"] == "SendToAgent" })
        expectNoDifference(pending.action.target, .recipient(identifier: peer.id.uuidString))
        model.handleTranscriptCardIntent(allow ? .approveReview(reviewID: pending.id) : .rejectReview(reviewID: pending.id))
        await work.value
        expectNoDifference(model.workflowRuns.first?.status, .succeeded)
        let requests = await probe.shared.filter { $0.messages.first?.text.contains("WORKFLOW_PEER_PERSONA") == true }
        expectNoDifference(requests.count, allow ? 1 : 0)
        #expect(requests.allSatisfy { !$0.messages.map(\.text).joined().contains("WORKFLOW_PEER_PRIVATE_FACT") })
    }
    @Test func silenceAndTypedActionsNeverClaimUnperformedEffects() async throws {
        let (root, model, workflow, id, _) = try await fixture(silent: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, workflow: workflow, id: id)
        await model.runWorkflowNow(id: workflow.id)
        expectNoDifference(model.workflowRuns.first?.status, .succeeded)
        expectNoDifference(model.workflowRuns.first?.outputs, [""])
        var changed = workflow; changed.steps += [.action(name: "notify", payload: "UNAUTHORIZED_NOTIFICATION")]
        #expect(await model.saveWorkflow(changed, replacingID: changed.id))
        try await approve(model, workflow: try #require(model.workflows.first { $0.id == workflow.id }), id: id)
        await model.runWorkflowNow(id: workflow.id)
        expectNoDifference(model.workflowRuns.first?.status, .failed)
        #expect(model.workflowRuns.first?.failure?.contains("was not authorized") == true)
        #expect(!model.conversations.flatMap(\.messages).contains { $0.text.contains("UNAUTHORIZED_NOTIFICATION") })
    }
}
