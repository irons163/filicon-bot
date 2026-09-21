import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private struct NeverRunWorkflow: AgentWorkflowStepExecutor {
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String {
        Issue.record("Saving a workflow must not execute it")
        return "unexpected"
    }
}

private actor WorkflowWriteGate {
    var waiter: CheckedContinuation<Void, Never>?
    var observer: CheckedContinuation<Void, Never>?
    var entered = false
    func hold() async { await withCheckedContinuation { waiter = $0; entered = true; observer?.resume(); observer = nil } }
    func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

private struct CapturedWorkflowExecutor: AgentWorkflowStepExecutor {
    let gate: WorkflowWriteGate
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String {
        await gate.hold()
        try Task.checkCancellation()
        if case .prompt(let body) = request.step { return body }
        throw AgentWorkflowError.notFound
    }
}

@Suite("Approved workflow writing", .timeLimit(.minutes(1)))
struct AgentWorkflowWriteTests {
    private let origin = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    private let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let workflows: WorkflowService
        let owner: AgentProfile
        let peer: AgentProfile
        var file: URL { root.appending(path: "workflows.json") }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-workflow-write-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Designer", instructions: "PRIVATE_OWNER", at: Date(timeIntervalSince1970: 1_000))
        let peer = try await agents.create(name: "Peer", instructions: "PRIVATE_PEER", at: Date(timeIntervalSince1970: 1_001))
        let workflows = try WorkflowService(store: AgentWorkflowStore(persistenceURL: root.appending(path: "workflows.json")),
            runtime: AgentWorkflowRuntime(executor: NeverRunWorkflow()))
        return .init(root: root, agents: agents, workflows: workflows, owner: owner, peer: peer)
    }
    private func session(_ f: Fixture, authorize: @escaping AgentManagementSession.WorkflowAuthorizer = { _, _, _, _ in },
                         commit: AgentManagementSession.WorkflowCommitter? = nil,
                         authorizeDelete: @escaping AgentManagementSession.WorkflowDeletionAuthorizer = { _, _, _, _ in throw AgentMessagingError.approvalRequired },
                         commitDelete: AgentManagementSession.WorkflowDeletionCommitter? = nil) -> AgentManagementSession {
        .init(originID: origin, agents: f.agents, makeID: { newID }, authorize: { _, _, _, _ in },
              now: { Date(timeIntervalSince1970: 3_000) }, workflows: f.workflows,
              authorizeWorkflow: authorize, commitWorkflow: commit,
              authorizeWorkflowDeletion: authorizeDelete, commitWorkflowDeletion: commitDelete)
    }
    private func call(_ extra: [String: Any] = [:], id: ToolCallID = "write") throws -> NormalizedToolCall {
        let fields: [String: Any] = ["target": "workflow", "action": "write", "name": "Review layout",
                                     "description": "Use this when reviewing layout.", "body": "Check contrast.\nDo not publish."]
        return try .init(id: id, name: "update_state", argumentsJSON: JSONSerialization.data(withJSONObject: fields.merging(extra) { _, new in new }))
    }

    @Test func createsOnlyAfterReviewAndDoesNotRun() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let s = session(f, authorize: { sender, change, _, _ in
            expectNoDifference(sender.id, f.owner.id)
            expectNoDifference(change.previous, nil)
            expectNoDifference(change.proposed.agentID, f.owner.id)
            expectNoDifference(change.proposed.steps, [.prompt("Check contrast.\nDo not publish.")])
            let values = await f.workflows.workflows()
            expectNoDifference(values, [])
        }); defer { s.close() }
        let context = ToolContext(conversationID: origin)
        let tool = s.tools(for: f.owner.id)[2]
        let result = try await tool.execute(call(), context: context)
        expectNoDifference(result.isError, false)
        let saved = try #require(await f.workflows.workflows().first)
        expectNoDifference(saved.id, "agent-\(newID.uuidString.lowercased())")
        expectNoDifference(saved.createdAt, Date(timeIntervalSince1970: 3_000))
        expectNoDifference(saved.trigger, .manual)
        expectNoDifference(saved.isEnabled, true)
        let runs = await f.workflows.runs()
        expectNoDifference(runs, [])
        let replay = try await tool.execute(call(), context: context)
        expectNoDifference(replay, result)
        let restored = try AgentWorkflowStore(persistenceURL: f.file)
        let restoredValues = await restored.list()
        expectNoDifference(restoredValues, [saved])
    }

    @Test func updatesWholePromptButPreservesOwnerTriggerDisabledStateAndCreationTime() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.workflows.create(.init(id: "layout", agentID: f.owner.id, name: "Old name", isEnabled: false, steps: [.prompt("Old body")]))
        let s = session(f, authorize: { _, change, _, _ in expectNoDifference(change.previous, before) }); defer { s.close() }
        _ = try await s.tools(for: f.owner.id)[2].execute(call(["id": before.id]), context: .init(conversationID: origin))
        var expected = before
        expected.name = "Review layout"; expected.description = "Use this when reviewing layout."
        expected.steps = [.prompt("Check contrast.\nDo not publish.")]; expected.updatedAt = Date(timeIntervalSince1970: 3_000)
        let saved = await f.workflows.workflow(id: before.id)
        let runs = await f.workflows.runs()
        expectNoDifference(saved, expected)
        expectNoDifference(runs, [])
    }

    @Test(arguments: ["peer", "unowned", "source", "managed", "schedule", "actions", "multi", "large"])
    func cannotRewriteUnsupportedWorkflows(kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var value = AgentWorkflow(id: "protected", agentID: f.owner.id, name: "Protected", steps: [.prompt("Keep")])
        switch kind {
        case "peer": value.agentID = f.peer.id
        case "unowned": value.agentID = nil
        case "source": value.sourceReference = "private-skill:protected"
        case "managed": value.id = "learn-from-demonstration"
        case "schedule": value.trigger = .schedule("@daily")
        case "actions": value.steps = [.action(name: "notify", payload: "Keep")]
        case "multi": value.steps.append(.prompt("Second"))
        default: value.steps = [.prompt(String(repeating: "界", count: 2_667))]
        }
        let before = try await f.workflows.create(value)
        let s = session(f, authorize: { _, _, _, _ in Issue.record("Unsupported write reached approval") }); defer { s.close() }
        await #expect(throws: AgentWorkflowWriteError.unavailable) {
            _ = try await s.tools(for: f.owner.id)[2].execute(call(["id": before.id]), context: .init(conversationID: origin))
        }
        let values = await f.workflows.workflows()
        expectNoDifference(values, [before])
    }

    @Test(arguments: ["name", "description", "body", "id", "action", "authority", "null", "type", "bytes"])
    func rejectsInvalidOrMixedArguments(kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let invalid: [String: Any]
        switch kind {
        case "name": invalid = ["name": String(repeating: "a", count: 81)]
        case "description": invalid = ["description": " "]
        case "body": invalid = ["body": "\n"]
        case "id": invalid = ["id": "../other"]
        case "action": invalid = ["action": "delete"]
        case "authority": invalid = ["enabled": true]
        case "null": invalid = ["id": NSNull()]
        case "type": invalid = ["body": ["command": "echo"]]
        default: invalid = ["body": String(repeating: "界", count: 2_667)]
        }
        let s = session(f, authorize: { _, _, _, _ in Issue.record("Invalid write reached approval") }); defer { s.close() }
        if kind == "action" {
            await #expect(throws: AgentWorkflowDeletionError.invalid) {
                _ = try await s.tools(for: f.owner.id)[2].execute(call(invalid), context: .init(conversationID: origin))
            }
        } else {
            await #expect(throws: AgentWorkflowWriteError.invalid) {
                _ = try await s.tools(for: f.owner.id)[2].execute(call(invalid), context: .init(conversationID: origin))
            }
        }
        let values = await f.workflows.workflows()
        expectNoDifference(values, [])
    }

    @Test(arguments: ["deny", "close", "archive", "stale", "disk"])
    func invalidationAndFailureNeverSave(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.workflows.create(.init(id: "existing", agentID: f.owner.id, name: "Old", steps: [.prompt("Keep")]))
        let gate = WorkflowWriteGate()
        let s = session(f, authorize: { _, _, _, _ in
            await gate.hold()
            if mode == "deny" { throw AgentMessagingError.approvalRequired }
        }); defer { s.close() }
        let run = Task { try await s.tools(for: f.owner.id)[2].execute(call(["id": before.id]), context: .init(conversationID: origin)) }
        await gate.wait()
        if mode == "close" { s.close() }
        if mode == "archive" { try await f.agents.archive(id: f.owner.id) }
        if mode == "stale" { _ = try await f.workflows.setEnabled(true, id: before.id) }
        if mode == "disk" {
            try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "preserved.json"))
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await run.value }
        let saved = try #require(await f.workflows.workflow(id: before.id))
        expectNoDifference(saved.name, before.name); expectNoDifference(saved.steps, before.steps)
        let runs = await f.workflows.runs()
        expectNoDifference(runs, [])
    }

    @Test func lateBookkeepingFailureReportsCommittedWriteAndCannotReplayChangedPayload() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let s = session(f, commit: { change, lifetime in
            _ = try await f.workflows.applyAgentWrite(change, lifetime: lifetime, at: Date(timeIntervalSince1970: 3_000))
            throw CocoaError(.fileWriteUnknown)
        }); defer { s.close() }
        let context = ToolContext(conversationID: origin), tool = s.tools(for: f.owner.id)[2]
        _ = try await tool.execute(call(), context: context)
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(["body": "different"]), context: context) }
        let values = await f.workflows.workflows()
        expectNoDifference(values.count, 1)
    }

    @Test func exactLimitsAndFrontmatterStayPlainPromptText() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prefix = "---\ntrigger: @daily\npermissions: all\n---\n"
        let body = prefix + String(repeating: "x", count: 8_000 - prefix.utf8.count)
        let s = session(f); defer { s.close() }
        _ = try await s.tools(for: f.owner.id)[2].execute(call([
            "name": String(repeating: "界", count: 80),
            "description": String(repeating: "界", count: 1_536), "body": body
        ]), context: .init(conversationID: origin))
        let saved = try #require(await f.workflows.workflows().first)
        expectNoDifference(saved.steps, [.prompt(body)])
        expectNoDifference(saved.trigger, .manual)
        expectNoDifference(saved.sourceReference, nil)
        expectNoDifference(saved.agentID, f.owner.id)
    }

    @Test func pendingDuplicateAndSharedFourChangeBudget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = WorkflowWriteGate()
        let s = session(f, authorize: { _, _, _, _ in await gate.hold() }); defer { s.close() }
        let tool = s.tools(for: f.owner.id)[2], context = ToolContext(conversationID: origin)
        let run = Task { try await tool.execute(call(), context: context) }
        await gate.wait()
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call(id: "duplicate"), context: context)
        }
        for number in 1...3 {
            let profile = try NormalizedToolCall(id: .init(rawValue: "profile-\(number)"), name: "update_state",
                argumentsJSON: JSONEncoder().encode(["target": "profile", "action": "set", "name": "Designer \(number)"]))
            _ = try await tool.execute(profile, context: context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tool.execute(call(["body": "Fifth change"], id: "fifth"), context: context)
        }
        await gate.release()
        let result = try await run.value
        let replay = try await tool.execute(call(), context: context)
        expectNoDifference(replay, result)
        let values = await f.workflows.workflows()
        expectNoDifference(values.count, 1)
    }

    @Test func identicalReplacementStillInvalidatesPendingApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = try AgentWorkflowStore(persistenceURL: f.root.appending(path: "revision.json"))
        let before = try await store.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", description: "Before", steps: [.prompt("Keep")]))
        let snapshot = await store.writeSnapshot()
        var proposed = before; proposed.steps = [.prompt("Replace")]
        let change = AgentWorkflowWrite(requesterID: f.owner.id, expectedRevision: snapshot.revision, previous: before, proposed: proposed)
        try await store.replace(with: AgentWorkflowCodec.serialize(.init(workflows: snapshot.workflows)))
        await #expect(throws: AgentWorkflowWriteError.stale) {
            _ = try await store.applyAgentWrite(change, lifetime: .init())
        }
        let values = await store.list()
        // JSON persistence normalizes date precision; the definition must remain intact.
        expectNoDifference(values.map(\.steps), [before.steps])
        expectNoDifference(values.map(\.name), [before.name])
    }

    private func deletion(_ workflowID: String = "layout", extra: [String: Any] = [:], id: ToolCallID = "delete") throws -> NormalizedToolCall {
        let fields: [String: Any] = ["target": "workflow", "action": "delete", "id": workflowID]
        return try .init(id: id, name: "update_state", argumentsJSON: JSONSerialization.data(withJSONObject: fields.merging(extra) { _, new in new }))
    }

    @Test func deletesExactOwnedDefinitionAfterApprovalAndReplaysReceipt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.workflows.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", isEnabled: false,
            steps: [.prompt(String(repeating: "x", count: 8_000))], createdAt: Date(timeIntervalSince1970: 1_000)))
        let peer = try await f.workflows.create(.init(id: "peer", agentID: f.peer.id, name: "Peer reference", steps: [.prompt("@Layout")], createdAt: Date(timeIntervalSince1970: 1_000)))
        let s = session(f, authorizeDelete: { sender, change, _, _ in
            expectNoDifference(sender.id, f.owner.id)
            expectNoDifference(change.workflow, before)
            let current = await f.workflows.workflow(id: before.id)
            expectNoDifference(current, before)
        }, commitDelete: { change, lifetime in
            try await f.workflows.applyAgentDeletion(change, lifetime: lifetime)
            // A later UI/account bookkeeping failure must not misreport a committed deletion.
            lifetime.close()
            throw CocoaError(.fileWriteUnknown)
        }); defer { s.close() }
        let tool = s.tools(for: f.owner.id)[2], context = ToolContext(conversationID: origin)
        let result = try await tool.execute(deletion(), context: context)
        expectNoDifference(result.isError, false)
        let replay = try await tool.execute(deletion(), context: context)
        expectNoDifference(replay, result)
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(deletion("peer"), context: context) }
        let values = await f.workflows.workflows(), runs = await f.workflows.runs()
        expectNoDifference(values, [peer]); expectNoDifference(runs, [])
        let restored = try AgentWorkflowStore(persistenceURL: f.file)
        let restoredValues = await restored.list()
        let persistedPeers = try AgentWorkflowCodec.parse(AgentWorkflowCodec.serialize(.init(workflows: [peer]))).workflows
        expectNoDifference(restoredValues, persistedPeers)
    }

    @Test(arguments: ["peer", "unowned", "source", "managed", "schedule", "actions", "multi", "large"])
    func cannotDeleteUnsupportedDefinitions(kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var value = AgentWorkflow(id: "layout", agentID: f.owner.id, name: "Protected", steps: [.prompt("Keep")])
        switch kind {
        case "peer": value.agentID = f.peer.id
        case "unowned": value.agentID = nil
        case "source": value.sourceReference = "private-skill:protected"
        case "managed": value.id = "learn-from-demonstration"
        case "schedule": value.trigger = .schedule("@daily")
        case "actions": value.steps = [.action(name: "notify", payload: "Keep")]
        case "multi": value.steps.append(.prompt("Second"))
        default: value.steps = [.prompt(String(repeating: "界", count: 2_667))]
        }
        let before = try await f.workflows.create(value)
        let s = session(f, authorizeDelete: { _, _, _, _ in Issue.record("Protected deletion reached approval") }); defer { s.close() }
        await #expect(throws: AgentWorkflowDeletionError.unavailable) {
            _ = try await s.tools(for: f.owner.id)[2].execute(deletion(before.id), context: .init(conversationID: origin))
        }
        let values = await f.workflows.workflows()
        expectNoDifference(values, [before])
    }

    @Test(arguments: ["id", "body", "authority", "null", "type", "bytes", "missing"])
    func deletionRejectsInvalidArguments(kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let extra: [String: Any]
        switch kind {
        case "id": extra = ["id": "../other"]
        case "body": extra = ["body": "replacement"]
        case "authority": extra = ["agent_id": f.peer.id.uuidString]
        case "null": extra = ["id": NSNull()]
        case "type": extra = ["id": 1]
        case "missing": extra = ["id": ""]
        default: extra = ["id": String(repeating: "a", count: 4_096)]
        }
        let s = session(f, authorizeDelete: { _, _, _, _ in Issue.record("Invalid deletion reached approval") }); defer { s.close() }
        await #expect(throws: AgentWorkflowDeletionError.invalid) {
            _ = try await s.tools(for: f.owner.id)[2].execute(deletion(extra: extra), context: .init(conversationID: origin))
        }
        let values = await f.workflows.workflows()
        expectNoDifference(values, [])
    }

    @Test(arguments: ["deny", "close", "archive", "stale", "aba", "disk"])
    func deletionInvalidationNeverRemovesDefinition(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.workflows.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", steps: [.prompt("Keep")], createdAt: Date(timeIntervalSince1970: 1_000)))
        let gate = WorkflowWriteGate()
        let s = session(f, authorizeDelete: { _, _, _, _ in
            await gate.hold()
            if mode == "deny" { throw AgentMessagingError.approvalRequired }
        }); defer { s.close() }
        let run = Task { try await s.tools(for: f.owner.id)[2].execute(deletion(), context: .init(conversationID: origin)) }
        await gate.wait()
        if mode == "close" { s.close() }
        if mode == "archive" { try await f.agents.archive(id: f.owner.id) }
        if mode == "stale" { _ = try await f.workflows.create(.init(id: "unrelated", name: "Other", steps: [.prompt("Keep")])) }
        if mode == "aba" { try await f.workflows.delete(id: before.id); _ = try await f.workflows.create(before) }
        if mode == "disk" {
            try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "preserved.json"))
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        let expected = await f.workflows.workflow(id: before.id)
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await run.value }
        let current = await f.workflows.workflow(id: before.id)
        expectNoDifference(current, expected)
    }

    @Test func deletionSharesBudgetAndRejectsPendingDuplicates() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.workflows.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", steps: [.prompt("Keep")]))
        let gate = WorkflowWriteGate()
        let s = session(f, authorizeDelete: { _, _, _, _ in await gate.hold() }); defer { s.close() }
        let tool = s.tools(for: f.owner.id)[2], context = ToolContext(conversationID: origin)
        let run = Task { try await tool.execute(deletion(), context: context) }
        await gate.wait()
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(deletion(id: "repeat"), context: context) }
        for number in 1...3 {
            let profile = try NormalizedToolCall(id: .init(rawValue: "profile-\(number)"), name: "update_state",
                argumentsJSON: JSONEncoder().encode(["target": "profile", "action": "set", "name": "Designer \(number)"]))
            _ = try await tool.execute(profile, context: context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) { _ = try await tool.execute(call(), context: context) }
        await gate.release(); _ = try await run.value
        let values = await f.workflows.workflows()
        expectNoDifference(values, [])
    }

    @Test(arguments: ["owner", "definition", "closed"])
    func storeRechecksDeletionAtAtomicCommit(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.workflows.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", steps: [.prompt("Keep")]))
        let snapshot = await f.workflows.writeSnapshot()
        var forged = before
        if mode == "definition" { forged.steps = [.prompt("Omitted from review")] }
        let change = AgentWorkflowDeletion(requesterID: mode == "owner" ? f.peer.id : f.owner.id, expectedRevision: snapshot.revision, workflow: forged)
        let lifetime = AgentWorkflowDeletionLifetime()
        if mode == "closed" { lifetime.close() }
        await #expect(throws: (any Error).self) { try await f.workflows.applyAgentDeletion(change, lifetime: lifetime) }
        expectNoDifference(lifetime.committed(change), false)
        let values = await f.workflows.workflows()
        expectNoDifference(values, [before])
    }

    @Test func deletingDefinitionKeepsCapturedRunAndDurableHistory() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = WorkflowWriteGate()
        let historyURL = f.root.appending(path: "history.json")
        let store = try AgentWorkflowStore(persistenceURL: f.file)
        let runtime = try AgentWorkflowRuntime(executor: CapturedWorkflowExecutor(gate: gate), historyURL: historyURL)
        let service = WorkflowService(store: store, runtime: runtime)
        let before = try await service.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", steps: [.prompt("Captured body")]))
        let run = Task { try await service.runNow(id: before.id) }
        await gate.wait()
        let snapshot = await service.writeSnapshot()
        try await service.applyAgentDeletion(.init(requesterID: f.owner.id, expectedRevision: snapshot.revision, workflow: before), lifetime: .init())
        let pendingStatuses = await service.runs().map(\.status)
        expectNoDifference(pendingStatuses, [.running])
        await gate.release()
        let result = try await run.value
        expectNoDifference(result.status, .succeeded)
        expectNoDifference(result.outputs, ["Captured body"])
        await #expect(throws: AgentWorkflowError.notFound) { _ = try await service.runNow(id: before.id) }
        let restored = try AgentWorkflowRuntime(executor: NeverRunWorkflow(), historyURL: historyURL)
        let restoredRuns = await restored.runs()
        expectNoDifference(restoredRuns.map(\.workflowID), [before.id])
        expectNoDifference(restoredRuns.map(\.status), [.succeeded])
    }

    @Test func identicalLibraryReplacementInvalidatesPendingDeletion() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let store = try AgentWorkflowStore(persistenceURL: f.file)
        let before = try await store.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", steps: [.prompt("Keep")]))
        let snapshot = await store.writeSnapshot()
        let change = AgentWorkflowDeletion(requesterID: f.owner.id, expectedRevision: snapshot.revision, workflow: before)
        try await store.replace(with: AgentWorkflowCodec.serialize(.init(workflows: snapshot.workflows)))
        let replacement = await store.list()
        await #expect(throws: AgentWorkflowWriteError.stale) {
            try await store.applyAgentDeletion(change, lifetime: .init())
        }
        let current = await store.list()
        expectNoDifference(current, replacement)
    }

    @Test func workflowDeleteRequiresItsOwnExplicitApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.workflows.create(.init(id: "layout", agentID: f.owner.id, name: "Layout", steps: [.prompt("Keep")]))
        // No deletion authorizer is supplied: a supported deletion must ask,
        // never inherit the profile or workflow-write allow handler.
        let s = session(f); defer { s.close() }
        let invocation = try NormalizedToolCall(id: "delete", name: "update_state",
            argumentsJSON: JSONEncoder().encode(["target": "workflow", "action": "delete", "id": before.id]))
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await s.tools(for: f.owner.id)[2].execute(invocation, context: .init(conversationID: origin))
        }
        let values = await f.workflows.workflows()
        expectNoDifference(values, [before])
    }
}
