import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
import FiliconDomain

private actor RoutineGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        await withCheckedContinuation { waiter = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

private struct RoutineExecutor: AutomationExecutor {
    var run: @Sendable (Automation) async -> Void = { _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await run(automation)
        return .init(detail: "fixture completed")
    }
}

@Suite("Approved own-routine changes", .timeLimit(.minutes(1)))
struct AgentRoutineChangeTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let automations: AutomationService
        let owner: AgentProfile
        let peer: AgentProfile
        let routine: Automation
        let peerRoutine: Automation
        let context: ToolContext
        var file: URL { root.appending(path: "automations.json") }
        func session(authorize: @escaping AgentManagementSession.RoutineAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.RoutineCommitter? = nil) -> AgentManagementSession {
            .init(originID: context.conversationID, agents: agents, authorize: { _, _, _, _ in },
                  now: { Date(timeIntervalSince1970: 3_000) }, authorizeMemory: { _, _, _, _ in },
                  authorizeAvatar: { _, _, _, _ in }, automations: automations,
                  authorizeRoutine: authorize, commitRoutine: commit)
        }
    }
    private func fixture(enabled: Bool = true, trigger: AutomationTrigger? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-routine-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Designer", instructions: "PRIVATE_PERSONA", at: Date(timeIntervalSince1970: 1_000))
        let peer = try await agents.create(name: "Engineer", instructions: "PRIVATE_PEER", at: Date(timeIntervalSince1970: 1_001))
        let automations = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let routine = try await automations.save(.init(agentID: owner.id, name: "Review layouts", prompt: "Review accessible contrast. Do not publish.",
            trigger: trigger ?? .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"), enabled: enabled,
            createdAt: Date(timeIntervalSince1970: 1_000)))
        let peerRoutine = try await automations.save(.init(agentID: peer.id, name: "PRIVATE_PEER_ROUTINE", prompt: "PRIVATE_PEER_PROMPT",
            trigger: .cron(expression: "@daily", timeZoneIdentifier: "UTC"), createdAt: Date(timeIntervalSince1970: 1_001)))
        return .init(root: root, agents: agents, automations: automations, owner: owner, peer: peer, routine: routine, peerRoutine: peerRoutine,
                     context: .init(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!))
    }
    private func call(_ f: Fixture, action: String = "pause", id: ToolCallID = "routine", routineID: UUID? = nil) throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: JSONEncoder().encode([
            "target": "routine", "action": action, "id": (routineID ?? f.routine.id).uuidString]))
    }

    @Test(arguments: [true, false])
    func explicitPreviewThenTogglePreservesDefinitionAndRestart(enabled: Bool) async throws {
        let f = try await fixture(enabled: enabled); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { sender, change, _, context in
            expectNoDifference(sender, f.owner); expectNoDifference(change.automation, f.routine)
            expectNoDifference(change.operation, enabled ? .pause : .resume)
            expectNoDifference(context.conversationID, f.context.conversationID)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        })
        let tool = session.tools(for: f.owner.id)[2], request = try call(f, action: enabled ? "pause" : "resume")
        let contextual = try #require(tool as? any ToolRuntimeContextProviding)
        let runtime = try await contextual.runtimeContext(for: f.context)
        #expect(runtime.contains(f.routine.id.uuidString) && runtime.contains(f.routine.name))
        #expect(!runtime.contains("PRIVATE_") && !runtime.contains(f.peerRoutine.id.uuidString) && !runtime.contains(f.routine.prompt))
        let result = try await tool.execute(request, context: f.context)
        #expect(!result.isError)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        var expected = f.routine
        expected.enabled = !enabled; expected.revision += 1
        expected.nextRunAt = enabled ? nil : Date(timeIntervalSince1970: 6_600)
        let after = await f.automations.list()
        expectNoDifference(after, [expected, f.peerRoutine])
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list(), runs = await restored.history(automationID: f.routine.id)
        expectNoDifference(durable, after); expectNoDifference(runs, [])
        let profiles = await f.agents.list()
        expectNoDifference(profiles, [f.owner, f.peer])
        session.close()
    }

    @Test func invalidFieldsScopeOwnerAndDefaultDenial() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.context.conversationID, agents: f.agents, automations: f.automations)
        let tool = session.tools(for: f.owner.id)[2]
        await #expect(throws: AgentMessagingError.approvalRequired) { _ = try await tool.execute(call(f), context: f.context) }
        for target in [f.peerRoutine.id, UUID()] {
            await #expect(throws: AutomationStateChangeError.unavailable) { _ = try await tool.execute(call(f, routineID: target), context: f.context) }
        }
        for action in ["create", "update", "delete", "set", "PAUSE", ""] {
            await #expect(throws: AutomationStateChangeError.invalid) { _ = try await tool.execute(call(f, action: action), context: f.context) }
        }
        for field in ["agent_id", "accountID", "name", "prompt", "schedule", "trigger", "enabled", "scope", "pet_id", "fact"] {
            let data = try JSONEncoder().encode(["target": "routine", "action": "pause", "id": f.routine.id.uuidString, field: "unexpected"])
            await #expect(throws: AutomationStateChangeError.invalid) {
                _ = try await tool.execute(.init(id: "bad", name: "update_state", argumentsJSON: data), context: f.context)
            }
        }
        for json in [#"{"target":"routine","action":"pause"}"#, #"{"target":"routine","action":"pause","id":true}"#,
                     #"{"target":"routine","action":"pause","id":null}"#, #"{"target":"routine","action":"pause","id":"path"}"#] {
            await #expect(throws: AutomationStateChangeError.invalid) {
                _ = try await tool.execute(.init(id: "bad", name: "update_state", argumentsJSON: Data(json.utf8)), context: f.context)
            }
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(call(f), context: .init(conversationID: UUID())) }
        let unchanged = await f.automations.list()
        expectNoDifference(unchanged, [f.routine, f.peerRoutine])
        session.close()
    }

    @Test(arguments: ["edit", "delete", "archive", "save-failure", "history"])
    func rechecksDefinitionAndPreservesLatestHistory(mutation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in
            switch mutation {
            case "edit":
                var edited = f.routine; edited.prompt = "New task"
                _ = try await f.automations.save(edited, now: Date(timeIntervalSince1970: 2_000))
            case "delete": try await f.automations.delete(id: f.routine.id)
            case "archive": try await f.agents.archive(id: f.owner.id)
            case "save-failure":
                try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
                try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
            default: _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
            }
        })
        let tool = session.tools(for: f.owner.id)[2]
        if mutation == "history" {
            _ = try await tool.execute(call(f), context: f.context)
            let saved = try #require(await f.automations.list(agentID: f.owner.id).first)
            var expected = f.routine; expected.enabled = false; expected.revision += 1
            expected.nextRunAt = nil; expected.lastRunAt = Date(timeIntervalSince1970: 2_000)
            expectNoDifference(saved, expected)
            let history = await f.automations.history(automationID: f.routine.id)
            expectNoDifference(history.count, 1); expectNoDifference(history.first?.status, .ok)
        } else {
            await #expect(throws: (any Error).self) { _ = try await tool.execute(call(f), context: f.context) }
            let saved = await f.automations.list(agentID: f.owner.id).first
            if mutation == "edit" { expectNoDifference(saved?.prompt, "New task"); expectNoDifference(saved?.enabled, true) }
            else if mutation == "delete" { #expect(saved == nil) }
            else { expectNoDifference(saved, f.routine) }
            if mutation == "save-failure" {
                try FileManager.default.removeItem(at: f.file)
                try FileManager.default.moveItem(at: f.root.appending(path: "backup.json"), to: f.file)
                let restored = try AutomationService(storeURL: f.file)
                let durable = await restored.list(agentID: f.owner.id).first
                expectNoDifference(durable, f.routine)
            }
        }
        session.close()
    }

    @Test(arguments: [false, true]) func stopRevokesApprovalAndDelayedCommit(duringCommit: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = RoutineGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.automations.applyStateChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let work = Task { try await tool.execute(call(f), context: f.context) }
        await gate.waitForEntry(); session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        let saved = await f.automations.list()
        expectNoDifference(saved, [f.routine, f.peerRoutine])
    }

    @Test func budgetReplayAndCommittedReceipt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            _ = try await f.automations.applyStateChange(change, lifetime: lifetime)
            throw AutomationStateChangeError.invalid
        })
        let tool = session.tools(for: f.owner.id)[2], request = try call(f)
        let result = try await tool.execute(request, context: f.context)
        #expect(!result.isError)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(f, action: "resume"), context: f.context) }
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(f, id: "again"), context: f.context) }
        for (id, fields) in [("memory", ["target": "memory", "action": "write", "fact": "Use contrast"]),
                             ("avatar", ["target": "avatar", "action": "clear"]),
                             ("profile", ["target": "profile", "action": "set", "name": "Visual designer"])] {
            _ = try await tool.execute(.init(id: ToolCallID(rawValue: id), name: "update_state", argumentsJSON: JSONEncoder().encode(fields)), context: f.context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) { _ = try await tool.execute(call(f, action: "resume", id: "fifth"), context: f.context) }
        let saved = await f.automations.list(agentID: f.owner.id).first
        expectNoDifference(saved?.enabled, false); expectNoDifference(saved?.revision, f.routine.revision + 1)
        session.close()
    }

    @Test(arguments: ["guard", "unknown", "nested-unknown"])
    func cannotBypassSpendProtectionOrUnsupportedTrigger(kind: String) async throws {
        let unknown = AutomationTrigger.unknown(kind: "future", payloadJSON: Data("{}".utf8))
        let trigger: AutomationTrigger? = kind == "unknown" ? unknown : kind == "nested-unknown" ? .anyOf([.cron(expression: "@daily", timeZoneIdentifier: "UTC"), unknown]) : nil
        let f = try await fixture(enabled: false, trigger: trigger); defer { try? FileManager.default.removeItem(at: f.root) }
        if kind == "guard" {
            try await f.automations.setEnabled(id: f.routine.id, enabled: true)
            try await f.automations.answerSpendGuard(.pause)
        }
        let before = await f.automations.list(), guardBefore = await f.automations.spendGuardState()
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Protected resume must not offer approval") })
        await #expect(throws: AutomationStateChangeError.protected) {
            _ = try await session.tools(for: f.owner.id)[2].execute(call(f, action: "resume"), context: f.context)
        }
        let after = await f.automations.list(), guardAfter = await f.automations.spendGuardState()
        expectNoDifference(after, before); expectNoDifference(guardAfter, guardBefore)
        session.close()
    }

    @Test(arguments: [false, true]) func pauseInvalidatesPendingBatchSnapshot(events: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let connector = UUID(), gate = RoutineGate()
        if events {
            for var item in [f.routine, f.peerRoutine] {
                item.trigger = .event(.init(connectorID: connector, kind: "fixture"))
                _ = try await f.automations.save(item)
            }
        }
        let executor = RoutineExecutor { routine in
            if routine.id == f.routine.id { await gate.hold() }
            else { Issue.record("A paused future task must not start from a stale batch snapshot") }
        }
        let task = Task {
            if events {
                return await f.automations.fire(events: [.init(connectorID: connector, kind: "fixture", externalEventID: "event-1", payloadJSON: Data("{}".utf8))], executor: executor)
            }
            return await f.automations.fireDue(at: Date(timeIntervalSince1970: 100_000), executor: executor)
        }
        await gate.waitForEntry()
        let second = try #require(await f.automations.list(agentID: f.peer.id).first)
        _ = try await f.automations.applyStateChange(.init(operation: .pause, automation: second), lifetime: .init())
        await gate.release()
        let fired = await task.value
        expectNoDifference(fired.count, 1); expectNoDifference(fired.first?.automationID, f.routine.id)
        let history = await f.automations.history(automationID: f.peerRoutine.id)
        expectNoDifference(history, [])
    }
}
