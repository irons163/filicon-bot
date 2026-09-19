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
                     commit: AgentManagementSession.RoutineCommitter? = nil,
                     makeID: @escaping @Sendable () -> UUID = { UUID() }) -> AgentManagementSession {
            .init(originID: context.conversationID, agents: agents, makeID: makeID, authorize: { _, _, _, _ in },
                  now: { Date(timeIntervalSince1970: 3_000) }, authorizeMemory: { _, _, _, _ in },
                  authorizeAvatar: { _, _, _, _ in }, automations: automations,
                  authorizeRoutine: authorize, commitRoutine: commit, routineTimeZoneIdentifier: "Asia/Taipei")
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
    private func persisted<Value: Codable>(_ value: Value) throws -> Value {
        // The store round-trips Dates through Unix milliseconds. Compare the
        // complete persisted value, including dates at that representation.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Value.self, from: encoder.encode(value))
    }
    private func writeCall(_ fields: [String: Any], id: ToolCallID = "write") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: JSONSerialization.data(withJSONObject: fields))
    }

    @Test(arguments: [true, false]) func createUsesHostIdentityTimeZoneAndApprovalTime(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let prompt = String(repeating: "檢查版面，不發布。", count: 1_000)
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender, f.owner); expectNoDifference(change.operation, .create)
            expectNoDifference(change.previous, nil); expectNoDifference(change.automation.id, id)
            expectNoDifference(change.automation.prompt, prompt)
            expectNoDifference(change.automation.trigger, .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"))
            let values = await f.automations.list()
            expectNoDifference(values, [f.routine, f.peerRoutine])
        }, commit: { change, lifetime in
            try await f.automations.applyStateChange(change, lifetime: lifetime, now: Date(timeIntervalSince1970: 10_000))
        }, makeID: { id })
        let tool = session.tools(for: f.owner.id)[2]
        let call = try writeCall(["target": "routine", "action": "create", "name": " Daily review ", "prompt": prompt,
                                  "schedule": " @every   1h ", "enabled": enabled])
        #expect(call.argumentsJSON.count > 16_000)
        let result = try await tool.execute(call, context: f.context)
        let replay = try await tool.execute(call, context: f.context)
        expectNoDifference(replay, result)
        let saved = try #require(await f.automations.list().first { $0.id == id })
        expectNoDifference(saved, .init(id: id, agentID: f.owner.id, name: "Daily review", prompt: prompt,
            trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"), enabled: enabled,
            createdAt: Date(timeIntervalSince1970: 3_000), nextRunAt: enabled ? Date(timeIntervalSince1970: 13_600) : nil))
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
        session.close()
    }

    @Test(arguments: ["name", "prompt", "schedule", "enabled"])
    func updateMergesOnlySpecifiedDefinitionAndKeepsCurrentHistory(field: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, change, _, _ in
            expectNoDifference(change.previous, f.routine)
            _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        })
        var fields: [String: Any] = ["target": "routine", "action": "update", "id": f.routine.id.uuidString]
        switch field {
        case "name": fields[field] = "Renamed"
        case "prompt": fields[field] = "New full task"
        case "schedule": fields[field] = "TZ=UTC @hourly"
        default: fields[field] = false
        }
        _ = try await session.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context)
        var expected = f.routine; expected.lastRunAt = Date(timeIntervalSince1970: 2_000)
        expected.nextRunAt = Date(timeIntervalSince1970: 5_600); expected.revision += 1
        switch field {
        case "name": expected.name = "Renamed"
        case "prompt": expected.prompt = "New full task"
        case "schedule": expected.trigger = .cron(expression: "TZ=UTC @hourly", timeZoneIdentifier: "GMT"); expected.nextRunAt = Date(timeIntervalSince1970: 3_600)
        default: expected.enabled = false; expected.nextRunAt = nil
        }
        let saved = await f.automations.list(agentID: f.owner.id).first
        expectNoDifference(saved, expected)
        let history = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(history.count, 1); expectNoDifference(history.first?.status, .ok)
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list(agentID: f.owner.id).first
        expectNoDifference(durable, expected)
        session.close()
    }

    @Test func routineWriteRejectsInvalidArgumentsWithoutApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid proposals must not reach approval") })
        let tool = session.tools(for: f.owner.id)[2]
        let valid: [String: Any] = ["target": "routine", "action": "create", "name": "Review", "prompt": "Review", "schedule": "@daily"]
        var invalid: [[String: Any]] = []
        for key in ["name", "prompt", "schedule"] { var fields = valid; fields.removeValue(forKey: key); invalid.append(fields) }
        for (key, value): (String, Any) in [("id", f.routine.id.uuidString), ("enabled", 1), ("enabled", "true"),
            ("enabled", NSNull()), ("name", " "), ("prompt", String(repeating: "x", count: 32_001)),
            ("name", String(repeating: "x", count: 81)), ("schedule", String(repeating: "x", count: 257)),
            ("agent_id", f.peer.id.uuidString), ("trigger", ["type": "cron"]), ("scope", "user")] {
            var fields = valid; fields[key] = value; invalid.append(fields)
        }
        invalid.append(["target": "routine", "action": "update", "id": f.routine.id.uuidString])
        invalid.append(["target": "routine", "action": "update", "name": "No id"])
        for fields in invalid {
            await #expect(throws: AutomationStateChangeError.invalidDefinition) {
                _ = try await tool.execute(writeCall(fields), context: f.context)
            }
        }
        for schedule in ["@every 1s", "@every 367d", "@every " + String(repeating: "9", count: 200) + "d"] {
            var fields = valid; fields["schedule"] = schedule
            await #expect(throws: AutomationStateChangeError.unsupportedSchedule) { _ = try await tool.execute(writeCall(fields), context: f.context) }
        }
        for schedule in ["broken", "TZ=Not/AZone @daily"] {
            var fields = valid; fields["schedule"] = schedule
            await #expect(throws: ScheduleError.self) { _ = try await tool.execute(writeCall(fields), context: f.context) }
        }
        for id in [f.peerRoutine.id, UUID()] {
            await #expect(throws: AutomationStateChangeError.unavailable) {
                _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": id.uuidString, "name": "No"]), context: f.context)
            }
        }
        let values = await f.automations.list()
        expectNoDifference(values, [f.routine, f.peerRoutine])
        session.close()
    }

    @Test(arguments: ["create", "update"], ["deny", "archive", "save-failure", "stale"])
    func routineWritesFailClosed(action: String, mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, change, _, _ in
            switch mode {
            case "deny": throw AgentMessagingError.approvalRequired
            case "archive": try await f.agents.archive(id: f.owner.id)
            case "save-failure":
                try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
                try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
            default:
                // Create ID collision or update revision change during approval.
                var other = change.automation; other.prompt = "Intervening task"
                _ = try await f.automations.save(other)
            }
        })
        let fields: [String: Any] = action == "create"
            ? ["target": "routine", "action": action, "name": "Review", "prompt": "Review", "schedule": "@daily"]
            : ["target": "routine", "action": action, "id": f.routine.id.uuidString, "prompt": "Revised"]
        await #expect(throws: (any Error).self) { _ = try await session.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context) }
        let values = await f.automations.list()
        if mode == "stale" { #expect(values.contains { $0.prompt == "Intervening task" }) }
        else { expectNoDifference(values, [f.routine, f.peerRoutine]) }
        if mode == "save-failure" {
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.moveItem(at: f.root.appending(path: "backup.json"), to: f.file)
            let restored = try AutomationService(storeURL: f.file)
            let durable = await restored.list()
            expectNoDifference(durable, [f.routine, f.peerRoutine])
        }
        session.close()
    }

    @Test(arguments: ["create", "update"], [false, true])
    func routineWritesStopAcrossApprovalAndCommit(action: String, duringCommit: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = RoutineGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.automations.applyStateChange(change, lifetime: lifetime)
        })
        let fields: [String: Any] = action == "create"
            ? ["target": "routine", "action": action, "name": "Review", "prompt": "Review", "schedule": "@daily"]
            : ["target": "routine", "action": action, "id": f.routine.id.uuidString, "prompt": "Revised"]
        let task = Task { try await session.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context) }
        await gate.waitForEntry(); session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let values = await f.automations.list()
        expectNoDifference(values, [f.routine, f.peerRoutine])
    }

    @Test func routineCreationBudgetReceiptAndCapacityAreBounded() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            _ = try await f.automations.applyStateChange(change, lifetime: lifetime)
            throw AutomationStateChangeError.invalid
        })
        let tool = session.tools(for: f.owner.id)[2]
        let fields: [String: Any] = ["target": "routine", "action": "create", "name": "Review", "prompt": "Review", "schedule": "@daily"]
        let request = try writeCall(fields), result = try await tool.execute(request, context: f.context)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(writeCall(fields, id: "duplicate"), context: f.context) }
        for (id, values) in [("m", ["target": "memory", "action": "write", "fact": "Use contrast"]),
                             ("a", ["target": "avatar", "action": "clear"]), ("p", ["target": "profile", "action": "set", "name": "Designer2"])] {
            _ = try await tool.execute(writeCall(values, id: ToolCallID(rawValue: id)), context: f.context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) { _ = try await tool.execute(call(f), context: f.context) }
        let ownerTasks = await f.automations.list(agentID: f.owner.id)
        expectNoDifference(ownerTasks.count, 2)
        session.close()
        for index in 2..<AutomationService.maximumDefinitionsPerAgent {
            _ = try await f.automations.save(.init(agentID: f.owner.id, name: "Fixture \(index)", prompt: "Review", trigger: f.routine.trigger))
        }
        let full = f.session(authorize: { _, _, _, _ in Issue.record("Capacity must be checked before approval") })
        await #expect(throws: AutomationServiceError.maximumDefinitions(50)) { _ = try await full.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context) }
        full.close()
    }

    @Test(arguments: ["create", "update"]) func routineWritesRequireAnAuthorizerAndMatchingScope(action: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.context.conversationID, agents: f.agents,
            automations: f.automations, routineTimeZoneIdentifier: "Asia/Taipei")
        let fields: [String: Any] = action == "create"
            ? ["target": "routine", "action": action, "name": "Review", "prompt": "Review", "schedule": "@daily"]
            : ["target": "routine", "action": action, "id": f.routine.id.uuidString, "name": "Renamed"]
        let tool = session.tools(for: f.owner.id)[2]
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await tool.execute(writeCall(fields), context: f.context)
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(writeCall(fields), context: .init(conversationID: UUID()))
        }
        let values = await f.automations.list()
        expectNoDifference(values, [f.routine, f.peerRoutine])
        session.close()
    }

    @Test func updateWhileRunningKeepsOldExecutionAndNewDefinition() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = RoutineGate()
        let oldRun = Task {
            try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor { automation in
                expectNoDifference(automation.prompt, f.routine.prompt)
                await gate.hold()
            }, now: Date(timeIntervalSince1970: 2_000))
        }
        await gate.waitForEntry()
        let session = f.session()
        do {
            _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                "target": "routine", "action": "update", "id": f.routine.id.uuidString,
                "prompt": "New future task", "schedule": "@every 2h"]), context: f.context)
        } catch { await gate.release(); _ = try? await oldRun.value; throw error }
        let beforeCompletion = await f.automations.list(agentID: f.owner.id)
        await gate.release()
        let finished = try await oldRun.value
        expectNoDifference(finished.status, .ok)
        let afterCompletion = await f.automations.list(agentID: f.owner.id)
        expectNoDifference(afterCompletion, beforeCompletion)
        let saved = try #require(afterCompletion.first)
        expectNoDifference(saved.prompt, "New future task")
        expectNoDifference(saved.nextRunAt, Date(timeIntervalSince1970: 10_200))
        let futureRun = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor { automation in
            expectNoDifference(automation.prompt, "New future task")
            expectNoDifference(automation.revision, f.routine.revision + 1)
        }, now: Date(timeIntervalSince1970: 10_200))
        expectNoDifference(futureRun.status, .ok)
        let restored = try AutomationService(storeURL: f.file)
        let history = await restored.history(automationID: f.routine.id)
        expectNoDifference(history, try persisted([futureRun, finished]))
        session.close()
    }

    @Test func routineWritesCannotBypassSpendProtectionOrConvertEventTriggers() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.automations.answerSpendGuard(.pause, at: Date(timeIntervalSince1970: 2_000))
        let session = f.session()
        let tool = session.tools(for: f.owner.id)[2]
        await #expect(throws: AutomationStateChangeError.protectedDefinition) {
            _ = try await tool.execute(writeCall(["target": "routine", "action": "create", "name": "Bypass", "prompt": "Review", "schedule": "@daily"]), context: f.context)
        }
        await #expect(throws: AutomationStateChangeError.protectedDefinition) {
            _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": f.routine.id.uuidString, "enabled": true]), context: f.context)
        }
        _ = try await tool.execute(writeCall(["target": "routine", "action": "create", "name": "Disabled draft", "prompt": "Review", "schedule": "@daily", "enabled": false]), context: f.context)
        let guardState = await f.automations.spendGuardState(), values = await f.automations.list()
        expectNoDifference(guardState.guardPausedAutomationIDs, [f.routine.id, f.peerRoutine.id])
        #expect(values.allSatisfy { !$0.enabled })
        let event = try await f.automations.save(.init(agentID: f.owner.id, name: "Event", prompt: "Review",
            trigger: .event(.init(connectorID: UUID(), kind: "fixture")), enabled: false))
        await #expect(throws: AutomationStateChangeError.unsupportedSchedule) {
            _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": event.id.uuidString, "schedule": "@daily"], id: "event"), context: f.context)
        }
        session.close()
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

    @Test(arguments: [true, false]) func deletionRetainsHistoryAndCannotBeResumed(enabled: Bool) async throws {
        let f = try await fixture(enabled: enabled); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        let wakes = await f.automations.pendingWakes()
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender.id, f.owner.id); expectNoDifference(change.operation, .delete)
            expectNoDifference(change.automation.prompt, f.routine.prompt)
            expectNoDifference(change.automation.lastRunAt, Date(timeIntervalSince1970: 2_000))
            #expect(await f.automations.list(agentID: sender.id).contains { $0.id == f.routine.id })
        })
        let tool = session.tools(for: f.owner.id)[2]
        let result = try await tool.execute(call(f, action: "delete"), context: f.context)
        #expect(result.content.contains { if case .text(let text) = $0 { return text.contains("Deleted routine") && text.contains("no undo") }; return false })
        let remaining = await f.automations.list(), keptHistory = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(remaining, [f.peerRoutine]); expectNoDifference(keptHistory, history)
        let keptWakes = await f.automations.pendingWakes()
        expectNoDifference(keptWakes, wakes)
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list(), durableHistory = await restored.history(automationID: f.routine.id)
        expectNoDifference(durable, remaining); expectNoDifference(durableHistory, try persisted(history))
        await #expect(throws: AutomationStateChangeError.unavailable) {
            _ = try await tool.execute(call(f, action: "resume", id: "resume-deleted"), context: f.context)
        }
        await #expect(throws: AutomationServiceError.unknownAutomation(f.routine.id)) {
            _ = try await restored.runNow(id: f.routine.id, executor: RoutineExecutor())
        }
        let freshSession = f.session()
        await #expect(throws: AutomationStateChangeError.unavailable) {
            _ = try await freshSession.tools(for: f.owner.id)[2].execute(call(f, action: "delete"), context: f.context)
        }
        session.close(); freshSession.close()
    }

    @Test(arguments: ["guard", "unknown", "nested-unknown"])
    func deleteProtectedRoutineDoesNotResumeOtherTasks(kind: String) async throws {
        let unknown = AutomationTrigger.unknown(kind: "future", payloadJSON: Data("{}".utf8))
        let trigger: AutomationTrigger? = kind == "unknown" ? unknown : kind == "nested-unknown"
            ? .anyOf([.cron(expression: "@daily", timeZoneIdentifier: "UTC"), unknown]) : nil
        let f = try await fixture(trigger: trigger); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.automations.answerSpendGuard(.pause, at: Date(timeIntervalSince1970: 2_000))
        let before = await f.automations.list(agentID: f.peer.id)
        var expectedGuard = await f.automations.spendGuardState()
        expectedGuard.guardPausedAutomationIDs.remove(f.routine.id)
        let session = f.session()
        _ = try await session.tools(for: f.owner.id)[2].execute(call(f, action: "delete"), context: f.context)
        let remaining = await f.automations.list(), guardAfter = await f.automations.spendGuardState()
        expectNoDifference(remaining, before); expectNoDifference(guardAfter, expectedGuard)
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list(), durableGuard = await restored.spendGuardState()
        expectNoDifference(durable, before); expectNoDifference(durableGuard, try persisted(expectedGuard))
        try await restored.answerSpendGuard(.resume, at: Date(timeIntervalSince1970: 3_000))
        let revived = await restored.list(agentID: f.owner.id)
        expectNoDifference(revived, [])
        session.close()
    }

    @Test func deleteWhileRunningKeepsCompletionWithoutRecreatingDefinition() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = RoutineGate()
        let run = Task {
            try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor { _ in await gate.hold() },
                                           now: Date(timeIntervalSince1970: 2_000))
        }
        await gate.waitForEntry()
        let session = f.session()
        do { _ = try await session.tools(for: f.owner.id)[2].execute(call(f, action: "delete"), context: f.context) }
        catch { await gate.release(); _ = try? await run.value; throw error }
        let beforeCompletion = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(beforeCompletion.first?.status, .running)
        await gate.release()
        let finished = try await run.value
        expectNoDifference(finished.status, .ok)
        let restored = try AutomationService(storeURL: f.file)
        let definitions = await restored.list(), history = await restored.history(automationID: f.routine.id)
        expectNoDifference(definitions, [f.peerRoutine]); expectNoDifference(history, try persisted([finished]))
        let wakes = await restored.pendingWakes(agentID: f.owner.id)
        expectNoDifference(wakes.first?.runID, finished.id); expectNoDifference(wakes.first?.status, .ok)
        session.close()
    }

    @Test(arguments: ["pause", "delete"]) func invalidFieldsScopeOwnerAndDefaultDenial(action: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.context.conversationID, agents: f.agents, automations: f.automations)
        let tool = session.tools(for: f.owner.id)[2]
        await #expect(throws: AgentMessagingError.approvalRequired) { _ = try await tool.execute(call(f, action: action), context: f.context) }
        for target in [f.peerRoutine.id, UUID()] {
            await #expect(throws: AutomationStateChangeError.unavailable) { _ = try await tool.execute(call(f, action: action, routineID: target), context: f.context) }
        }
        for action in ["set", "PAUSE", "DELETE", ""] {
            await #expect(throws: AutomationStateChangeError.invalid) { _ = try await tool.execute(call(f, action: action), context: f.context) }
        }
        for field in ["agent_id", "accountID", "name", "prompt", "schedule", "trigger", "enabled", "scope", "pet_id", "fact"] {
            let data = try JSONEncoder().encode(["target": "routine", "action": action, "id": f.routine.id.uuidString, field: "unexpected"])
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
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(call(f, action: action), context: .init(conversationID: UUID())) }
        let unchanged = await f.automations.list()
        expectNoDifference(unchanged, [f.routine, f.peerRoutine])
        session.close()
    }

    @Test(arguments: ["edit", "delete", "replace", "archive", "save-failure", "history"], ["pause", "delete"])
    func rechecksDefinitionAndPreservesLatestHistory(mutation: String, action: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in
            switch mutation {
            case "edit":
                var edited = f.routine; edited.prompt = "New task"
                _ = try await f.automations.save(edited, now: Date(timeIntervalSince1970: 2_000))
            case "delete": try await f.automations.delete(id: f.routine.id)
            case "replace":
                try await f.automations.delete(id: f.routine.id)
                _ = try await f.automations.save(.init(id: f.routine.id, agentID: f.owner.id,
                    name: f.routine.name, prompt: f.routine.prompt, trigger: f.routine.trigger,
                    createdAt: Date(timeIntervalSince1970: 2_000)))
            case "archive": try await f.agents.archive(id: f.owner.id)
            case "save-failure":
                try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
                try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
            default: _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
            }
        })
        let tool = session.tools(for: f.owner.id)[2]
        if mutation == "history" {
            _ = try await tool.execute(call(f, action: action), context: f.context)
            let saved = await f.automations.list(agentID: f.owner.id).first
            var expected = f.routine; expected.enabled = false; expected.revision += 1
            expected.nextRunAt = nil; expected.lastRunAt = Date(timeIntervalSince1970: 2_000)
            expectNoDifference(saved, action == "delete" ? nil : expected)
            let history = await f.automations.history(automationID: f.routine.id)
            expectNoDifference(history.count, 1); expectNoDifference(history.first?.status, .ok)
        } else {
            await #expect(throws: (any Error).self) { _ = try await tool.execute(call(f, action: action), context: f.context) }
            let saved = await f.automations.list(agentID: f.owner.id).first
            if mutation == "edit" { expectNoDifference(saved?.prompt, "New task"); expectNoDifference(saved?.enabled, true) }
            else if mutation == "delete" { #expect(saved == nil) }
            else if mutation == "replace" { expectNoDifference(saved?.createdAt, Date(timeIntervalSince1970: 2_000)) }
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

    @Test(arguments: [false, true], ["pause", "delete"]) func stopRevokesApprovalAndDelayedCommit(duringCommit: Bool, action: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = RoutineGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.automations.applyStateChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let work = Task { try await tool.execute(call(f, action: action), context: f.context) }
        await gate.waitForEntry(); session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        let saved = await f.automations.list()
        expectNoDifference(saved, [f.routine, f.peerRoutine])
    }

    @Test(arguments: ["pause", "delete"]) func budgetReplayAndCommittedReceipt(action: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            _ = try await f.automations.applyStateChange(change, lifetime: lifetime)
            throw AutomationStateChangeError.invalid
        })
        let tool = session.tools(for: f.owner.id)[2], request = try call(f, action: action)
        let result = try await tool.execute(request, context: f.context)
        #expect(!result.isError)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(f, action: "resume"), context: f.context) }
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(f, action: action, id: "again"), context: f.context) }
        for (id, fields) in [("memory", ["target": "memory", "action": "write", "fact": "Use contrast"]),
                             ("avatar", ["target": "avatar", "action": "clear"]),
                             ("profile", ["target": "profile", "action": "set", "name": "Visual designer"])] {
            _ = try await tool.execute(.init(id: ToolCallID(rawValue: id), name: "update_state", argumentsJSON: JSONEncoder().encode(fields)), context: f.context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) { _ = try await tool.execute(call(f, action: "resume", id: "fifth"), context: f.context) }
        let saved = await f.automations.list(agentID: f.owner.id).first
        expectNoDifference(saved?.enabled, action == "delete" ? nil : false)
        expectNoDifference(saved?.revision, action == "delete" ? nil : f.routine.revision + 1)
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

    @Test(arguments: [false, true], [AutomationStateChange.Operation.pause, .delete])
    func stateChangeInvalidatesPendingBatchSnapshot(events: Bool, operation: AutomationStateChange.Operation) async throws {
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
            else { Issue.record("A paused/deleted future task must not start from a stale batch snapshot") }
        }
        let task = Task {
            if events {
                return await f.automations.fire(events: [.init(connectorID: connector, kind: "fixture", externalEventID: "event-1", payloadJSON: Data("{}".utf8))], executor: executor)
            }
            return await f.automations.fireDue(at: Date(timeIntervalSince1970: 100_000), executor: executor)
        }
        await gate.waitForEntry()
        let second = try #require(await f.automations.list(agentID: f.peer.id).first)
        _ = try await f.automations.applyStateChange(.init(operation: operation, automation: second), lifetime: .init())
        await gate.release()
        let fired = await task.value
        expectNoDifference(fired.count, 1); expectNoDifference(fired.first?.automationID, f.routine.id)
        let history = await f.automations.history(automationID: f.peerRoutine.id)
        expectNoDifference(history, [])
    }
}
