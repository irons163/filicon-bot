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

    private var githubFields: [String: Any] {
        ["type": "github", "repo": "Example/Project", "events": ["review-approved", "ci-failed"],
         "userAllowlist": ["@Alice", "review-bot[bot]"], "ciBranch": "main"]
    }

    private var slackFields: [String: Any] {
        ["type": "slack", "channel": "C123", "match": ["kind": "reaction", "emoji": ["eyes"], "bySelf": false]]
    }

    private var linearFields: [String: Any] {
        ["type": "linear", "event": ["case": "statusChanged", "statusIds": ["aaaaaaaa-0000-0000-0000-000000000001"]],
         "teamIds": ["bbbbbbbb-0000-0000-0000-000000000001"], "projectIds": ["cccccccc-0000-0000-0000-000000000001"]]
    }
    private var sentryFields: [String: Any] {
        ["type": "sentry", "event": ["case": "issueAny"], "projectIds": ["123", "007"]]
    }
    private func sentryTrigger() throws -> AutomationTrigger {
        .platform(.sentry(try .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: ["123", "007"])))
    }

    @Test(arguments: [true, false], ["single", "group"])
    func sentryCreateRequiresApprovalAndCanonicalReplay(enabled: Bool, form: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let sentry = try sentryTrigger()
        let expected: AutomationTrigger = form == "single" ? sentry : .anyOf([
            .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"), sentry])
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender.id, f.owner.id)
            expectNoDifference(change.automation.trigger, expected)
            expectNoDifference(change.automation.enabled, enabled)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        }, makeID: { id })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Sentry review", "prompt": "Review only",
            "trigger": form == "single" ? sentryFields : [sentryFields, ["type": "cron", "schedule": "@every 1h"]], "enabled": enabled]
        let result = try await tool.execute(writeCall(fields), context: f.context)
        var duplicate = sentryFields; duplicate["projectIds"] = ["007", "123", "007"]
        fields["trigger"] = form == "single" ? [duplicate, sentryFields] : [duplicate, ["type": "cron", "schedule": "@every 1h"], sentryFields]
        let replay = try await tool.execute(writeCall(fields), context: f.context)
        expectNoDifference(replay, result)
        #expect(result.content.contains { if case .text(let text) = $0 { text.contains("Sentry") && text.contains("no webhook") } else { false } })
        let saved = try #require(await f.automations.list().first { $0.id == id })
        expectNoDifference(saved.trigger, expected)
        expectNoDifference(saved.lastRunAt, nil)
        expectNoDifference(saved.nextRunAt, enabled && form == "group" ? Date(timeIntervalSince1970: 6_600) : nil)
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
    }

    @Test func sentryRejectsInvalidFieldsWithoutApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid Sentry proposal reached approval") })
        defer { session.close() }
        var invalid: [[String: Any]] = []
        for value: Any in [["Project"], ["*"], [" 123"], ["123\n"], ["１２３"], ["+123"], [""], ["1.5"], ["1e3"],
            [String(repeating: "1", count: 201)], [123], [true], [NSNull()], NSNull(), "123", Array(repeating: "123", count: 51)] {
            var raw = sentryFields; raw["projectIds"] = value; invalid.append(raw)
        }
        for (key, value): (String, Any) in [("event", ["case": "created"]), ("event", ["case": "issueAny", "statusIds": []]),
            ("event", ["case": NSNull()]), ("event", "issueCreated"), ("event", ["case": "issueDeleted"]),
            ("teamIds", []), ("secondaryIDs", []), ("agent_id", f.peer.id.uuidString)] {
            var raw = sentryFields; raw[key] = value; invalid.append(raw)
        }
        for key in ["type", "event"] { var raw = sentryFields; raw.removeValue(forKey: key); invalid.append(raw) }
        for raw in invalid {
            for trigger: Any in [raw, [slackFields, raw]] {
                await #expect(throws: (any Error).self) {
                    _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                        "target": "routine", "action": "create", "name": "No", "prompt": "No", "trigger": trigger]), context: f.context)
                }
            }
        }
        let after = await f.automations.list()
        expectNoDifference(after, [f.routine, f.peerRoutine])
    }

    @Test(arguments: ["issueCreated", "issueResolved", "issueAssigned", "issueArchived", "issueUnresolved", "issueAny"], [0, 50])
    func sentryAcceptsExactFilterBounds(eventCase: String, count: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        let ids = (0..<count).map { $0 == 0 ? "0" : String(repeating: "0", count: 198) + String(format: "%02d", $0) }
        let expected = AutomationTrigger.platform(.sentry(try .init(event: eventCase, allowedEvents: [eventCase], primaryIDs: Set(ids))))
        let tool = session.tools(for: f.owner.id)[2]
        _ = try await tool.execute(writeCall(["target": "routine", "action": "create", "name": "Bounded", "prompt": "Review",
            "trigger": ["type": "sentry", "event": ["case": eventCase], "projectIds": ids]]), context: f.context)
        let saved = try #require(await f.automations.list().first { $0.name == "Bounded" })
        expectNoDifference(saved.trigger, expected)
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let trigger = try #require(properties["trigger"] as? [String: Any])
        let variants = try #require(trigger["anyOf"] as? [[String: Any]])
        let sentry = try #require(variants.first {
            let fields = $0["properties"] as? [String: Any], type = fields?["type"] as? [String: Any]
            return type?["enum"] as? [String] == ["sentry"]
        })
        expectNoDifference(sentry["additionalProperties"] as? Bool, false)
        let fields = try #require(sentry["properties"] as? [String: Any])
        let projects = try #require(fields["projectIds"] as? [String: Any])
        expectNoDifference(projects["maxItems"] as? Int, 50)
        let item = try #require(projects["items"] as? [String: Any])
        expectNoDifference(item["pattern"] as? String, "^[0-9]+$")
    }

    @Test func sentryCoreRejectsBypassesAndLegacyConversions() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let invalid = try [
            CaseAutomationTrigger(event: "created", allowedEvents: ["created"]),
            .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: ["name"]),
            .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: Set((0...50).map(String.init))),
            .init(event: "issueAny", allowedEvents: ["issueAny"], secondaryIDs: ["123"]),
        ]
        for raw in invalid {
            for trigger: AutomationTrigger in [.platform(.sentry(raw)), .anyOf([f.routine.trigger, .platform(.sentry(raw))])] {
                let proposed = Automation(agentID: f.owner.id, name: "No", prompt: "No", trigger: trigger, enabled: false)
                await #expect(throws: (any Error).self) {
                    _ = try await f.automations.applyStateChange(.init(operation: .create, automation: proposed), lifetime: .init())
                }
            }
        }
        let legacy = try await f.automations.save(.init(agentID: f.owner.id, name: "Legacy", prompt: "Legacy", trigger: .platform(.sentry(invalid[0]))))
        var updated = legacy; updated.trigger = try sentryTrigger()
        await #expect(throws: (any Error).self) {
            _ = try await f.automations.applyStateChange(.init(operation: .update, automation: updated, previous: legacy), lifetime: .init())
        }
        let after = await f.automations.list()
        expectNoDifference(after, [f.routine, f.peerRoutine, legacy])
    }
    private func linearTrigger() throws -> AutomationTrigger {
        .platform(.linear(try .init(event: "statusChanged", allowedEvents: ["statusChanged"],
            primaryIDs: ["bbbbbbbb-0000-0000-0000-000000000001"], secondaryIDs: ["cccccccc-0000-0000-0000-000000000001"],
            statusIDs: ["aaaaaaaa-0000-0000-0000-000000000001"])))
    }

    @Test(arguments: [true, false], ["single", "group"])
    func linearCreateRequiresApprovalAndCanonicalReplay(enabled: Bool, form: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let linear = try linearTrigger()
        let expected: AutomationTrigger = form == "single" ? linear : .anyOf([
            .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"), linear])
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender.id, f.owner.id)
            expectNoDifference(change.automation.trigger, expected)
            expectNoDifference(change.automation.enabled, enabled)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        }, makeID: { id })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        let trigger: Any = form == "single" ? linearFields : [linearFields, ["type": "cron", "schedule": "@every 1h"]]
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Linear review", "prompt": "Review only",
            "trigger": trigger, "enabled": enabled]
        let result = try await tool.execute(writeCall(fields), context: f.context)
        var duplicate = linearFields
        duplicate["teamIds"] = ["BBBBBBBB-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000001"]
        fields["trigger"] = form == "single" ? [duplicate, linearFields] : [duplicate, ["type": "cron", "schedule": "@every 1h"], linearFields]
        let replay = try await tool.execute(writeCall(fields), context: f.context)
        expectNoDifference(replay, result)
        #expect(result.content.contains { if case .text(let text) = $0 { text.contains("Linear") && text.contains("no webhook") } else { false } })
        let saved = try #require(await f.automations.list().first { $0.id == id })
        expectNoDifference(saved.trigger, expected)
        expectNoDifference(saved.lastRunAt, nil)
        expectNoDifference(saved.nextRunAt, enabled && form == "group" ? Date(timeIntervalSince1970: 6_600) : nil)
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
        let runtime = try await #require(tool as? any ToolRuntimeContextProviding).runtimeContext(for: f.context)
        #expect(runtime.contains("statusIds") && runtime.contains("endOfCycle"))
    }

    @Test func linearRejectsInvalidFieldsWithoutApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid Linear proposal reached approval") })
        defer { session.close() }
        var invalid: [[String: Any]] = []
        for (key, value): (String, Any) in [("teamIds", ["Engineering"]), ("projectIds", ["*"]), ("teamIds", NSNull()),
            ("projectIds", [1]), ("teamIds", Array(repeating: "bbbbbbbb-0000-0000-0000-000000000001", count: 51)),
            ("statusIds", []), ("event", "statusChanged"), ("agent_id", f.peer.id.uuidString)] {
            var raw = linearFields; raw[key] = value; invalid.append(raw)
        }
        for event: [String: Any] in [["case": "endOfCycle"], ["case": "issue"], ["case": "statusChanged", "statusIds": ["Done"]],
            ["case": "issueCreated", "statusIds": []], ["case": "statusChanged", "cycleIds": []],
            ["case": "statusChanged", "statusIds": NSNull()], ["case": "statusChanged", "statusIds": [true]],
            ["case": "statusChanged", "statusIds": Array(repeating: "aaaaaaaa-0000-0000-0000-000000000001", count: 51)]] {
            var raw = linearFields; raw["event"] = event; invalid.append(raw)
        }
        for key in ["type", "event"] { var raw = linearFields; raw.removeValue(forKey: key); invalid.append(raw) }
        for (index, raw) in invalid.enumerated() {
            for trigger: Any in [raw, [slackFields, raw]] {
                await #expect(throws: (any Error).self) {
                    _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                        "target": "routine", "action": "create", "name": "No", "prompt": "No", "trigger": trigger],
                        id: .init(rawValue: "invalid-\(index)")), context: f.context)
                }
            }
        }
        let after = await f.automations.list()
        expectNoDifference(after, [f.routine, f.peerRoutine])
    }

    @Test(arguments: ["issueCreated", "statusChanged"], [0, 50])
    func linearAcceptsExactFilterBoundsAndAdvertisesStrictSchema(eventCase: String, count: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        let ids = (1...50).prefix(count).map { String(format: "aaaaaaaa-0000-0000-0000-%012d", $0) }
        let event: [String: Any] = eventCase == "issueCreated" ? ["case": eventCase] : ["case": eventCase, "statusIds": ids]
        let tool = session.tools(for: f.owner.id)[2]
        let expected = AutomationTrigger.platform(.linear(try .init(event: eventCase, allowedEvents: [eventCase],
            primaryIDs: Set(ids), secondaryIDs: Set(ids), statusIDs: eventCase == "statusChanged" ? Set(ids) : [])))
        _ = try await tool.execute(writeCall(["target": "routine", "action": "create", "name": "Bounded", "prompt": "Review",
            "trigger": ["type": "linear", "event": event, "teamIds": ids, "projectIds": ids]]), context: f.context)
        let saved = try #require(await f.automations.list().first { $0.name == "Bounded" })
        expectNoDifference(saved.trigger, expected)
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let trigger = try #require(properties["trigger"] as? [String: Any])
        let variants = try #require(trigger["anyOf"] as? [[String: Any]])
        let linear = try #require(variants.first { ($0["required"] as? [String]) == ["type", "event"] })
        expectNoDifference(linear["additionalProperties"] as? Bool, false)
        let fields = try #require(linear["properties"] as? [String: Any])
        let team = try #require(fields["teamIds"] as? [String: Any])
        expectNoDifference(team["maxItems"] as? Int, 50)
        let eventSchema = try #require(fields["event"] as? [String: Any])
        expectNoDifference((eventSchema["anyOf"] as? [Any])?.count, 2)
        #expect(!String(decoding: tool.descriptor.inputSchema, as: UTF8.self).contains("endOfCycle"))
    }

    @Test func linearUpdatesPreserveHistoryAndConvertOnlyAfterApproval() async throws {
        let initial = try linearTrigger()
        let f = try await fixture(trigger: initial); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        let session = f.session(authorize: { _, change, _, _ in
            let current = try #require(await f.automations.list().first { $0.id == f.routine.id })
            expectNoDifference(change.previous, current)
        })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        var expected = try #require(await f.automations.list().first { $0.id == f.routine.id })
        for kind in ["rename", "time", "linear", "group"] {
            var fields: [String: Any] = ["target": "routine", "action": "update", "id": f.routine.id.uuidString]
            if kind == "rename" { fields["name"] = "Renamed"; expected.name = "Renamed" }
            else if kind == "time" {
                fields["schedule"] = "@every 1h"
                expected.trigger = .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei")
                expected.nextRunAt = Date(timeIntervalSince1970: 6_600)
            } else if kind == "linear" { fields["trigger"] = linearFields; expected.trigger = initial; expected.nextRunAt = nil }
            else {
                fields["trigger"] = [slackFields, linearFields]
                expected.trigger = .anyOf([initial, .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))])
            }
            _ = try await tool.execute(writeCall(fields, id: .init(rawValue: kind)), context: f.context)
            expected.revision += 1
            let actual = await f.automations.list().first { $0.id == f.routine.id }
            expectNoDifference(actual, expected)
        }
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == f.routine.id }, finalHistory = await restored.history(automationID: f.routine.id)
        expectNoDifference(durable, try persisted(expected)); expectNoDifference(finalHistory, try persisted(history))
    }

    @Test func sentryUpdatesPreserveHistoryAndConvertOnlyAfterApproval() async throws {
        let initial = try sentryTrigger()
        let f = try await fixture(trigger: initial); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        let session = f.session(authorize: { _, change, _, _ in
            let current = try #require(await f.automations.list().first { $0.id == f.routine.id })
            expectNoDifference(change.previous, current)
        })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        var expected = try #require(await f.automations.list().first { $0.id == f.routine.id })
        for kind in ["rename", "time", "sentry", "group"] {
            var fields: [String: Any] = ["target": "routine", "action": "update", "id": f.routine.id.uuidString]
            if kind == "rename" { fields["name"] = "Renamed"; expected.name = "Renamed" }
            else if kind == "time" {
                fields["schedule"] = "@every 1h"
                expected.trigger = .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei")
                expected.nextRunAt = Date(timeIntervalSince1970: 6_600)
            } else if kind == "sentry" { fields["trigger"] = sentryFields; expected.trigger = initial; expected.nextRunAt = nil }
            else {
                fields["trigger"] = [slackFields, sentryFields]
                expected.trigger = .anyOf([initial, .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))])
            }
            _ = try await tool.execute(writeCall(fields, id: .init(rawValue: kind)), context: f.context)
            expected.revision += 1
            let actual = await f.automations.list().first { $0.id == f.routine.id }
            expectNoDifference(actual, expected)
        }
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == f.routine.id }, finalHistory = await restored.history(automationID: f.routine.id)
        expectNoDifference(durable, try persisted(expected)); expectNoDifference(finalHistory, try persisted(history))
    }

    private var groupFields: [String: Any] {
        ["type": "group", "listeners": [githubFields, slackFields]]
    }
    private func groupTrigger() throws -> AutomationTrigger {
        .anyOf([
            .platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
                ciBranch: "main", userAllowlist: ["alice", "review-bot[bot]"]))),
            .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))
        ])
    }

    private var mixedFields: [String: Any] {
        ["type": "group", "listeners": [["type": "cron", "schedule": "@every 1h"], githubFields, slackFields]]
    }
    private func mixedTrigger() throws -> AutomationTrigger {
        .anyOf([.cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"),
            .platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
                ciBranch: "main", userAllowlist: ["alice", "review-bot[bot]"]))),
            .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))])
    }

    @Test(arguments: [true, false]) func mixedCreatePinsEveryZoneAndStartsOnlyAfterApproval(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let members: [[String: Any]] = [["type": "cron", "schedule": " @every   1h "],
            ["type": "cron", "schedule": "TZ=UTC 0 9 * * *"], githubFields, slackFields]
        let expected: AutomationTrigger = .anyOf([
            .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"),
            .cron(expression: "TZ=UTC 0 9 * * *", timeZoneIdentifier: "GMT"),
            .platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
                ciBranch: "main", userAllowlist: ["alice", "review-bot[bot]"]))),
            .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))])
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender, f.owner); expectNoDifference(change.automation.trigger, expected)
            expectNoDifference(change.automation.nextRunAt, nil)
            let preview = try change.triggerJSON
            expectNoDifference(try JSONDecoder().decode(AutomationTrigger.self, from: Data(preview.utf8)), expected)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        }, commit: { change, lifetime in
            try await f.automations.applyStateChange(change, lifetime: lifetime, now: Date(timeIntervalSince1970: 10_000))
        }, makeID: { id })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Mixed", "prompt": "Review only",
            "trigger": ["type": "group", "listeners": members], "enabled": enabled]
        let result = try await tool.execute(writeCall(fields), context: f.context)
        fields["trigger"] = Array(members.reversed()) + [members[0]]
        let replay = try await tool.execute(writeCall(fields), context: f.context)
        expectNoDifference(replay, result)
        #expect(result.content.contains { if case .text(let text) = $0 { text.contains("reset @every intervals") && text.contains("OR, not AND") } else { false } })
        let saved = await f.automations.list().first { $0.id == id }
        expectNoDifference(saved, .init(id: id, agentID: f.owner.id, name: "Mixed", prompt: "Review only", trigger: expected,
            enabled: enabled, createdAt: Date(timeIntervalSince1970: 3_000), nextRunAt: enabled ? Date(timeIntervalSince1970: 13_600) : nil))
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
    }

    @Test(arguments: [1, 8]) func timeOnlyGroupsNormalizeBoundsAndSelectEarliest(count: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        let members = (1...count).map { ["type": "cron", "schedule": "@every \($0)h"] }
        _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
            "target": "routine", "action": "create", "name": "Timers", "prompt": "Inspect", "trigger": members]), context: f.context)
        let saved = try #require(await f.automations.list(agentID: f.owner.id).first { $0.name == "Timers" })
        let expected = (1...count).map { AutomationTrigger.cron(expression: "@every \($0)h", timeZoneIdentifier: "Asia/Taipei") }
        expectNoDifference(saved.trigger, count == 1 ? expected[0] : .anyOf(expected))
        expectNoDifference(saved.nextRunAt, Date(timeIntervalSince1970: 6_600))
    }

    @Test(arguments: ["single", "array", "group"]) func singleCronAndDuplicateFormsCollapse(form: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        let member = ["type": "cron", "schedule": " @every   1m "]
        let trigger: Any = form == "single" ? member : form == "array" ? [member, member] : ["type": "group", "listeners": [member]]
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Timer", "prompt": "Inspect", "trigger": trigger]
        let tool = session.tools(for: f.owner.id)[2]
        let result = try await tool.execute(writeCall(fields), context: f.context)
        fields["trigger"] = ["type": "cron", "schedule": "@every 1m"]
        let replay = try await tool.execute(writeCall(fields), context: f.context)
        expectNoDifference(replay, result)
        let saved = await f.automations.list(agentID: f.owner.id).first { $0.name == "Timer" }
        expectNoDifference(saved?.trigger, .cron(expression: "@every 1m", timeZoneIdentifier: "Asia/Taipei"))
        expectNoDifference(saved?.nextRunAt, Date(timeIntervalSince1970: 3_060))
    }

    @Test func mixedUpdatesKeepOmittedTriggerAndHistoryThenAllowExplicitConversion() async throws {
        let f = try await fixture(trigger: mixedTrigger()); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        var snapshot = try #require(await f.automations.list(agentID: f.owner.id).first)
        let session = f.session(authorize: { _, change, _, _ in #expect(change.previous != nil) })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        await expectDifference(snapshot) {
            _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": f.routine.id.uuidString,
                "name": "Renamed"], id: "rename"), context: f.context)
            snapshot = try #require(await f.automations.list(agentID: f.owner.id).first)
        } changes: { $0.name = "Renamed"; $0.revision = 2 }
        for kind in ["event", "mixed", "time"] {
            var fields: [String: Any] = ["target": "routine", "action": "update", "id": f.routine.id.uuidString]
            if kind == "time" { fields["schedule"] = "@every 2h" }
            else { fields["trigger"] = kind == "event" ? groupFields : mixedFields }
            _ = try await tool.execute(writeCall(fields, id: ToolCallID(rawValue: kind)), context: f.context)
            let value = try #require(await f.automations.list(agentID: f.owner.id).first)
            let expected = kind == "event" ? try groupTrigger() : kind == "mixed" ? try mixedTrigger() : .cron(expression: "@every 2h", timeZoneIdentifier: "Asia/Taipei")
            expectNoDifference(value.trigger, expected)
            expectNoDifference(value.nextRunAt, kind == "event" ? nil : Date(timeIntervalSince1970: kind == "mixed" ? 6_600 : 10_200))
            expectNoDifference(value.lastRunAt, Date(timeIntervalSince1970: 2_000))
        }
        let finalHistory = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(finalHistory, history)
    }

    @Test(arguments: ["@every 1m", "@every 366d", "CRON_TZ=UTC 0 9 * * *"])
    func mixedTimeMembersAcceptExactIntervalBoundsAndCronTZ(schedule: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
            "target": "routine", "action": "create", "name": "Boundary", "prompt": "Inspect",
            "trigger": [slackFields, ["type": "cron", "schedule": schedule]]]), context: f.context)
        let saved = try #require(await f.automations.list(agentID: f.owner.id).first { $0.name == "Boundary" })
        let zone = schedule.hasPrefix("CRON_TZ") ? "GMT" : "Asia/Taipei"
        guard case .anyOf(let members) = saved.trigger else { Issue.record("Expected mixed definition"); return }
        expectNoDifference(members.first, .cron(expression: schedule, timeZoneIdentifier: zone))
        expectNoDifference(saved.nextRunAt, try AutomationSchedule.nextRun(for: schedule,
            after: Date(timeIntervalSince1970: 3_000), defaultTimeZone: TimeZone(identifier: zone)))
    }

    @Test func mixedUpdatePreservesEventExecutionDuringApproval() async throws {
        let f = try await fixture(trigger: mixedTrigger()); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, change, _, _ in
            expectNoDifference(change.previous, f.routine)
            let event = AutomationEvent(connectorID: UUID(), kind: "slack", externalEventID: "approval-event",
                payloadJSON: Data(#"{"channel":"C123","reaction":"eyes"}"#.utf8), occurredAt: Date(timeIntervalSince1970: 3_250))
            let runs = await f.automations.fire(events: [event], executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 3_250))
            expectNoDifference(runs.count, 1)
        }, commit: { change, lifetime in
            try await f.automations.applyStateChange(change, lifetime: lifetime, now: Date(timeIntervalSince1970: 5_000))
        })
        defer { session.close() }
        _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
            "target": "routine", "action": "update", "id": f.routine.id.uuidString, "prompt": "New task"]), context: f.context)
        let saved = try #require(await f.automations.list(agentID: f.owner.id).first)
        expectNoDifference(saved.trigger, f.routine.trigger)
        expectNoDifference(saved.lastRunAt, Date(timeIntervalSince1970: 3_250))
        expectNoDifference(saved.nextRunAt, Date(timeIntervalSince1970: 6_850))
        expectNoDifference(saved.prompt, "New task")
        let restored = try AutomationService(storeURL: f.file)
        let history = await restored.history(automationID: f.routine.id), durable = await restored.list(agentID: f.owner.id).first
        expectNoDifference(history.count, 1); expectNoDifference(history.first?.trigger, .event)
        expectNoDifference(durable, saved)
    }

    @Test func malformedTimeMembersRejectTheWholeProposal() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid time condition reached approval") })
        defer { session.close() }
        var invalid: [[String: Any]] = [[:], ["type": "cron"], ["type": "cron", "schedule": NSNull()],
            ["type": "cron", "schedule": 123], ["type": "cron", "schedule": "@daily", "timeZoneIdentifier": "UTC"],
            ["type": "cron", "schedule": "@daily", "enabled": false], ["type": "cron", "schedule": "@daily", "prompt": "Hidden task"]]
        for schedule in ["", "  ", "bad cron", "@every 1s", "@every 367d", "TZ=Not/AZone 0 9 * * *", String(repeating: "x", count: 257)] {
            invalid.append(["type": "cron", "schedule": schedule])
        }
        for member in invalid {
            await #expect(throws: (any Error).self) {
                _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                    "target": "routine", "action": "create", "name": "No", "prompt": "Inspect",
                    "trigger": [slackFields, member], "enabled": false]), context: f.context)
            }
        }
        let before = await f.automations.list()
        expectNoDifference(before, [f.routine, f.peerRoutine])
    }

    @Test(arguments: [true, false]) func eventGroupNormalizesFormsWithoutLosingApprovalOrReplay(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let expected = try groupTrigger()
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender, f.owner)
            expectNoDifference(change.previous, nil)
            expectNoDifference(change.automation.trigger, expected)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        }, makeID: { id })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Event review", "prompt": "Review only",
            "trigger": groupFields, "enabled": enabled]
        let first = try await tool.execute(writeCall(fields), context: f.context)
        fields["trigger"] = [slackFields, githubFields, slackFields]
        let replay = try await tool.execute(writeCall(fields), context: f.context)
        expectNoDifference(replay, first)
        #expect(first.content.contains { if case .text(let text) = $0 { text.contains("OR, not AND") && text.contains("Slack") && text.contains("GitHub") } else { false } })
        let saved = try #require(await f.automations.list().first { $0.id == id })
        expectNoDifference(saved, .init(id: id, agentID: f.owner.id, name: "Event review", prompt: "Review only",
            trigger: expected, enabled: enabled, createdAt: Date(timeIntervalSince1970: 3_000)))
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
        fields["trigger"] = [githubFields]
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(writeCall(fields), context: f.context) }
        let runtime = try await #require(tool as? any ToolRuntimeContextProviding).runtimeContext(for: f.context)
        #expect(runtime.contains("flat OR group") && runtime.contains("event and manual runs also reset @every intervals"))
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let specification = try #require(properties["trigger"] as? [String: Any])
        let variants = try #require(specification["anyOf"] as? [[String: Any]])
        expectNoDifference(variants.count, 7)
        expectNoDifference(variants[5]["additionalProperties"] as? Bool, false)
        let group = try #require(variants[5]["properties"] as? [String: Any])
        let listeners = try #require(group["listeners"] as? [String: Any])
        expectNoDifference(listeners["maxItems"] as? Int, AutomationService.maximumListeners)
        expectNoDifference(listeners["minItems"] as? Int, 1)
        let items = try #require(listeners["items"] as? [String: Any])
        expectNoDifference((items["anyOf"] as? [Any])?.count, 5) // Cron/GitHub/Slack/Linear/Sentry only; no recursive or other platforms.
    }

    @Test(arguments: [1, 8]) func eventGroupsAcceptExactBounds(count: Int) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        let members = (0..<count).map { ["type": "slack", "channel": "C\($0)", "match": ["kind": "message"]] as [String: Any] }
        let triggers = try (0..<count).map { AutomationTrigger.platform(.slack(try .init(channel: "C\($0)", match: .message))) }
        _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
            "target": "routine", "action": "create", "name": "Bounds", "prompt": "Review",
            "trigger": ["type": "group", "listeners": members]]), context: f.context)
        let saved = await f.automations.list(agentID: f.owner.id).first { $0.name == "Bounds" }
        expectNoDifference(saved?.trigger, count == 1 ? triggers[0] : .anyOf(triggers))
    }

    @Test func eventGroupsRejectEveryInvalidMemberRatherThanBroadeningFilters() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid event group reached approval") })
        defer { session.close() }
        let invalidMembers: [Any] = [NSNull(), "slack", 1, [slackFields], groupFields,
            ["type": "cron", "schedule": "@every 1s"], ["type": "pagerDuty", "event": ["case": "triggered"]],
            ["type": "slack", "channel": "#name", "match": ["kind": "message"]],
            ["type": "slack", "channel": "*", "match": ["kind": "reaction", "bySelf": true]],
            ["type": "github", "repo": "example/project", "events": ["pr-opened", "unknown"]]]
        var proposals: [Any] = [[], Array(repeating: githubFields, count: 9),
            ["type": "group", "listeners": []], ["type": "group"], ["type": "group", "listeners": NSNull()],
            ["type": "group", "listeners": [githubFields], "enabled": true]]
        for member in invalidMembers {
            proposals.append([githubFields, member])
            proposals.append(["type": "group", "listeners": [member, slackFields]])
        }
        for proposal in proposals {
            await #expect(throws: (any Error).self) {
                _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                    "target": "routine", "action": "create", "name": "Do not save", "prompt": "Review", "trigger": proposal]), context: f.context)
            }
        }
        await #expect(throws: AutomationStateChangeError.invalidDefinition) {
            _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                "target": "routine", "action": "create", "name": "No", "prompt": "Review", "trigger": groupFields,
                "schedule": "@daily"]), context: f.context)
        }
        let values = await f.automations.list()
        expectNoDifference(values, [f.routine, f.peerRoutine])
    }

    @Test func eventGroupUpdatesConvertInBothDirectionsAndPreserveHistory() async throws {
        let initial = try groupTrigger()
        let f = try await fixture(trigger: initial); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        let session = f.session(authorize: { _, change, _, _ in #expect(change.previous != nil) })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        var expected = f.routine; expected.lastRunAt = Date(timeIntervalSince1970: 2_000)
        for kind in ["rename", "time", "github", "group"] {
            var fields: [String: Any] = ["target": "routine", "action": "update", "id": f.routine.id.uuidString, "name": kind]
            if kind == "time" {
                fields["schedule"] = "@every 1h"
                expected.trigger = .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei")
                expected.nextRunAt = Date(timeIntervalSince1970: 6_600)
            } else if kind != "rename" {
                fields["trigger"] = kind == "group" ? groupFields : githubFields
                if case .anyOf(let members) = initial { expected.trigger = kind == "group" ? initial : members[0] }
                expected.nextRunAt = nil
            }
            expected.name = kind; expected.revision += 1
            _ = try await tool.execute(writeCall(fields, id: ToolCallID(rawValue: kind)), context: f.context)
            let saved = await f.automations.list(agentID: f.owner.id).first
            expectNoDifference(saved, expected)
        }
        let finalHistory = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(finalHistory, history)
    }

    @Test func directStateChangesCannotBypassEventGroupMemberValidation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let valid = AutomationTrigger.platform(.slack(try .init(channel: "C123", match: .message)))
        let invalid: [AutomationTrigger] = [
            .anyOf([]), .anyOf([valid]), .anyOf([valid, valid]), .anyOf(Array(repeating: valid, count: 9)),
            .anyOf([valid, .anyOf([valid, valid])]), .anyOf([valid, .cron(expression: "@daily", timeZoneIdentifier: nil)]),
            .anyOf([valid, .event(.init(connectorID: UUID(), kind: "slack"))]),
            .anyOf([valid, .unknown(kind: "future", payloadJSON: Data("{}".utf8))]),
            .anyOf([valid, .platform(.slack(try .init(channel: "#name", match: .message)))])]
        for trigger in invalid {
            let value = Automation(agentID: f.owner.id, name: "No", prompt: "Review", trigger: trigger)
            await #expect(throws: (any Error).self) {
                _ = try await f.automations.applyStateChange(.init(operation: .create, automation: value), lifetime: .init())
            }
        }
        let values = await f.automations.list()
        expectNoDifference(values, [f.routine, f.peerRoutine])
    }

    @Test(arguments: ["message", "mention", "keyword", "reaction"], [true, false])
    func slackCreateRequiresFullApprovalAndDurableReceipt(kind: String, enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let match: SlackMatch = switch kind {
        case "mention": .mention
        case "keyword": .keyword("needs design")
        case "reaction": .reaction(emoji: ["eyes", "thumbsup"], bySelf: false)
        default: .message
        }
        let trigger = AutomationTrigger.platform(.slack(try .init(channel: "C123", match: match)))
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender, f.owner); expectNoDifference(change.previous, nil)
            expectNoDifference(change.automation.id, id); expectNoDifference(change.automation.trigger, trigger)
            expectNoDifference(change.automation.enabled, enabled)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        }, makeID: { id })
        defer { session.close() }
        var rawMatch: [String: Any] = ["kind": kind]
        if kind == "keyword" { rawMatch["keyword"] = " needs design " }
        if kind == "reaction" { rawMatch["emoji"] = [" :EYES: ", "thumbsup", "eyes"] }
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Slack review", "prompt": "Review only. Do not publish.",
            "trigger": ["type": "slack", "channel": " C123 ", "match": rawMatch]]
        if !enabled { fields["enabled"] = false } // Omission defaults to enabled.
        let request = try writeCall(fields), tool = session.tools(for: f.owner.id)[2]
        let result = try await tool.execute(request, context: f.context)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        let saved = try #require(await f.automations.list().first { $0.id == id })
        expectNoDifference(saved, .init(id: id, agentID: f.owner.id, name: "Slack review", prompt: "Review only. Do not publish.",
            trigger: trigger, enabled: enabled, createdAt: Date(timeIntervalSince1970: 3_000)))
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
        let runtime = try await #require(tool as? any ToolRuntimeContextProviding).runtimeContext(for: f.context)
        #expect(runtime.contains("bySelf true is unsupported") && runtime.contains("verified event ingress"))
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let specification = try #require(properties["trigger"] as? [String: Any])
        let variants = try #require(specification["anyOf"] as? [[String: Any]])
        let slack = try #require(variants.first { ($0["required"] as? [String])?.contains("channel") == true })
        expectNoDifference(slack["additionalProperties"] as? Bool, false)
        expectNoDifference(slack["required"] as? [String], ["type", "channel", "match"])
    }

    @Test(arguments: ["keyword-boundary", "emoji-boundary", "any-empty", "any-omitted"])
    func slackAcceptsExactBoundsAndExplicitAnyReaction(kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let channel: String, match: SlackMatch, raw: [String: Any]
        switch kind {
        case "keyword-boundary":
            channel = "C" + String(repeating: "1", count: 79)
            let keyword = String(repeating: "設", count: 120)
            match = .keyword(keyword); raw = ["kind": "keyword", "keyword": keyword]
        case "emoji-boundary":
            channel = "G123"
            let emoji = (0..<8).map { String(repeating: "x", count: 79) + String($0) }
            match = .reaction(emoji: emoji, bySelf: false); raw = ["kind": "reaction", "emoji": emoji, "bySelf": false]
        case "any-empty":
            channel = "D123"; match = .reaction(emoji: [], bySelf: false); raw = ["kind": "reaction", "emoji": []]
        default:
            channel = "*"; match = .reaction(emoji: [], bySelf: false); raw = ["kind": "reaction"]
        }
        let expected = AutomationTrigger.platform(.slack(try .init(channel: channel, match: match)))
        let session = f.session(authorize: { _, change, _, _ in expectNoDifference(change.automation.trigger, expected) })
        defer { session.close() }
        _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
            "target": "routine", "action": "create", "name": "Bounds", "prompt": "Review",
            "trigger": ["type": "slack", "channel": channel, "match": raw]]), context: f.context)
        let saved = await f.automations.list(agentID: f.owner.id).first { $0.name == "Bounds" }
        expectNoDifference(saved?.trigger, expected)
    }

    @Test func slackUpdatePreservesTaskHistoryAndSupportsApprovedConversions() async throws {
        let trigger = AutomationTrigger.platform(.slack(try .init(channel: "C123", match: .message)))
        let f = try await fixture(trigger: trigger); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, change, _, _ in
            #expect(change.previous != nil)
            if change.automation.name == "Renamed" { expectNoDifference(change.automation.trigger, trigger) }
        })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": f.routine.id.uuidString, "name": "Renamed"]), context: f.context)
        var expected = f.routine; expected.name = "Renamed"; expected.lastRunAt = Date(timeIntervalSince1970: 2_000); expected.revision += 1
        let renamed = await f.automations.list(agentID: f.owner.id).first
        expectNoDifference(renamed, expected)
        for kind in ["github", "time", "slack"] {
            var fields: [String: Any] = ["target": "routine", "action": "update", "id": f.routine.id.uuidString, "name": kind]
            if kind == "time" {
                fields["schedule"] = "@every 1h"
                expected.trigger = .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei")
                expected.nextRunAt = Date(timeIntervalSince1970: 6_600)
            } else {
                fields["trigger"] = kind == "github" ? githubFields : slackFields
                expected.trigger = kind == "github" ? .platform(.github(try .init(repo: "example/project",
                    events: ["review-approved", "ci-failed"], ciBranch: "main", userAllowlist: ["alice", "review-bot[bot]"])))
                    : .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))
                expected.nextRunAt = nil
            }
            expected.name = kind; expected.revision += 1
            _ = try await tool.execute(writeCall(fields, id: ToolCallID(rawValue: kind)), context: f.context)
            let actual = await f.automations.list(agentID: f.owner.id).first
            expectNoDifference(actual, expected)
        }
        let finalHistory = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(finalHistory, history)
    }

    @Test func slackRejectsMalformedOrBroadenedFiltersBeforeApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid Slack trigger reached approval") })
        defer { session.close() }
        var invalid: [[String: Any]] = []
        for (key, value): (String, Any) in [
            ("type", "unknown"), ("channel", ""), ("channel", "#design"), ("channel", "@alice"),
            ("channel", "design"), ("channel", "c123"), ("channel", "C123\nG456"), ("channel", "C" + String(repeating: "1", count: 80)),
            ("channel", 123), ("channel", NSNull()), ("match", NSNull()), ("match", "message"), ("repo", "example/private")
        ] {
            var raw = slackFields; raw[key] = value; invalid.append(raw)
        }
        let invalidMatches: [[String: Any]] = [
            [:], ["kind": "unknown"], ["kind": "message", "keyword": "ignored"], ["kind": "mention", "bySelf": true],
            ["kind": "keyword"], ["kind": "keyword", "keyword": ""], ["kind": "keyword", "keyword": " "],
            ["kind": "keyword", "keyword": "a\nb"], ["kind": "keyword", "keyword": String(repeating: "x", count: 121)],
            ["kind": "reaction", "bySelf": true], ["kind": "reaction", "bySelf": "false"], ["kind": "reaction", "bySelf": 0],
            ["kind": "reaction", "emoji": NSNull()], ["kind": "reaction", "emoji": "eyes"],
            ["kind": "reaction", "emoji": ["eyes", "not valid"]], ["kind": "reaction", "emoji": [""]],
            ["kind": "reaction", "emoji": ["eyes::unknown"]], ["kind": "reaction", "emoji": ["thumbsup::skin-tone-2"]],
            ["kind": "reaction", "emoji": Array(repeating: "eyes", count: 9)],
            ["kind": "reaction", "emoji": [String(repeating: "x", count: 81)]], ["kind": "reaction", "extra": false]
        ]
        for match in invalidMatches { var raw = slackFields; raw["match"] = match; invalid.append(raw) }
        for key in ["type", "channel", "match"] { var raw = slackFields; raw.removeValue(forKey: key); invalid.append(raw) }
        for raw in invalid {
            await #expect(throws: AutomationStateChangeError.self) {
                _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                    "target": "routine", "action": "create", "name": "Review", "prompt": "Review", "trigger": raw]), context: f.context)
            }
        }
        var mixed: [String: Any] = ["target": "routine", "action": "create", "name": "Review", "prompt": "Review",
            "trigger": slackFields, "schedule": "@daily"]
        await #expect(throws: AutomationStateChangeError.invalidDefinition) {
            _ = try await session.tools(for: f.owner.id)[2].execute(writeCall(mixed), context: f.context)
        }
        mixed.removeValue(forKey: "schedule"); mixed["trigger"] = [[slackFields]]
        await #expect(throws: AutomationStateChangeError.invalidDefinition) {
            _ = try await session.tools(for: f.owner.id)[2].execute(writeCall(mixed), context: f.context)
        }
        for id in [f.peerRoutine.id, UUID()] {
            await #expect(throws: AutomationStateChangeError.unavailable) {
                _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                    "target": "routine", "action": "update", "id": id.uuidString, "trigger": slackFields]), context: f.context)
            }
        }
        let unchanged = await f.automations.list()
        expectNoDifference(unchanged, [f.routine, f.peerRoutine])
    }

    @Test(arguments: [true, false]) func githubCreateRequiresFullApprovalAndDoesNotRun(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let trigger = AutomationTrigger.platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
            ciBranch: "main", userAllowlist: ["alice", "review-bot[bot]"])))
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender, f.owner); expectNoDifference(change.previous, nil)
            expectNoDifference(change.automation.id, id); expectNoDifference(change.automation.trigger, trigger)
            expectNoDifference(change.automation.prompt, "Review safely. Do not publish.")
            expectNoDifference(change.automation.enabled, enabled)
            let before = await f.automations.list()
            expectNoDifference(before, [f.routine, f.peerRoutine])
        }, makeID: { id })
        defer { session.close() }
        var raw = githubFields
        raw["repo"] = " Example/Project "; raw["events"] = ["review-approved", "ci-failed", "review-approved"]
        raw["userAllowlist"] = [" @Alice ", "review-bot[bot]", "ALICE"]
        let request = try writeCall(["target": "routine", "action": "create", "name": "GitHub review",
            "prompt": "Review safely. Do not publish.", "trigger": raw, "enabled": enabled])
        let tool = session.tools(for: f.owner.id)[2]
        let result = try await tool.execute(request, context: f.context)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(result, replay)
        let saved = try #require(await f.automations.list().first { $0.id == id })
        expectNoDifference(saved, .init(id: id, agentID: f.owner.id, name: "GitHub review", prompt: "Review safely. Do not publish.",
            trigger: trigger, enabled: enabled, createdAt: Date(timeIntervalSince1970: 3_000)))
        let restored = try AutomationService(storeURL: f.file)
        let durable = await restored.list().first { $0.id == id }, history = await restored.history(automationID: id)
        expectNoDifference(durable, saved); expectNoDifference(history, [])
        let runtime = try await #require(tool as? any ToolRuntimeContextProviding).runtimeContext(for: f.context)
        #expect(runtime.contains("not aggregate settled checks") && runtime.contains("existing authenticated ingress"))
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let combined = try #require(properties["trigger"] as? [String: Any])
        let variants = try #require(combined["anyOf"] as? [[String: Any]])
        expectNoDifference(variants.count, 7)
        let specification = try #require(variants.first { ($0["required"] as? [String])?.contains("repo") == true })
        expectNoDifference(specification["additionalProperties"] as? Bool, false)
        let fields = try #require(specification["properties"] as? [String: Any])
        let events = try #require(fields["events"] as? [String: Any])
        let items = try #require(events["items"] as? [String: Any])
        expectNoDifference(Set(try #require(items["enum"] as? [String])), GitHubAutomationTrigger.knownEvents)
    }

    @Test func githubUpdatePreservesOmittedFieldsAndCanConvertBackToTime() async throws {
        let trigger = AutomationTrigger.platform(.github(try .init(repo: "example/project", events: ["pr-opened"], userAllowlist: ["alice"])))
        let f = try await fixture(trigger: trigger); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, change, _, _ in
            #expect(change.previous != nil)
            if change.automation.name == "Renamed" { expectNoDifference(change.automation.trigger, trigger) }
        })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        _ = try await f.automations.runNow(id: f.routine.id, executor: RoutineExecutor(), now: Date(timeIntervalSince1970: 2_000))
        let history = await f.automations.history(automationID: f.routine.id)
        _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": f.routine.id.uuidString, "name": "Renamed"]), context: f.context)
        let first = try #require(await f.automations.list(agentID: f.owner.id).first)
        var expected = f.routine; expected.name = "Renamed"; expected.lastRunAt = Date(timeIntervalSince1970: 2_000); expected.revision += 1
        expectNoDifference(first, expected)
        _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": f.routine.id.uuidString,
            "name": "Time review", "schedule": "@every 1h"], id: "time"), context: f.context)
        expected.name = "Time review"; expected.trigger = .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei")
        expected.nextRunAt = Date(timeIntervalSince1970: 6_600); expected.revision += 1
        let timeRoutine = await f.automations.list(agentID: f.owner.id).first
        expectNoDifference(timeRoutine, expected)
        _ = try await tool.execute(writeCall(["target": "routine", "action": "update", "id": f.routine.id.uuidString,
            "trigger": githubFields], id: "github"), context: f.context)
        expected.trigger = .platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
            ciBranch: "main", userAllowlist: ["alice", "review-bot[bot]"])))
        expected.nextRunAt = nil; expected.revision += 1
        let githubRoutine = await f.automations.list(agentID: f.owner.id).first
        let finalHistory = await f.automations.history(automationID: f.routine.id)
        expectNoDifference(githubRoutine, expected); expectNoDifference(finalHistory, history)
    }

    @Test func githubRejectsMalformedOrSilentlyBroadenedTriggersBeforeApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid trigger reached approval") })
        defer { session.close() }
        let base: [String: Any] = ["target": "routine", "action": "create", "name": "Review", "prompt": "Review", "trigger": githubFields]
        var invalid: [[String: Any]] = []
        for (key, value): (String, Any) in [
            ("type", "slack"), ("type", "anyOf"), ("repo", "https://github.com/owner/repo"), ("repo", "*/repo"), ("repo", "owner/.."),
            ("repo", "owner/" + String(repeating: "a", count: 150)), ("events", []), ("events", ["unknown"]),
            ("events", ["pr-opened", "unknown"]), ("events", Array(repeating: "pr-opened", count: 15)),
            ("userAllowlist", [" "]), ("userAllowlist", ["*"]), ("userAllowlist", Array(repeating: "alice", count: 51)),
            ("userAllowlist", [String(repeating: "a", count: 81)]), ("userAllowlist", "alice"), ("ciBranch", ""),
            ("ciBranch", "*"), ("ciBranch", "refs//main"), ("ciBranch", "@"), ("ciBranch", "main.lock"), ("ciBranch", ".hidden"),
            ("ciBranch", "main..other"), ("ciBranch", "main."), ("ciBranch", "main\u{7f}"), ("ciBranch", "feature/.hidden"),
            ("ciBranch", String(repeating: "a", count: 201)), ("credentials", "never-accepted"), ("ciBranch", NSNull())
        ] {
            var trigger = githubFields; trigger[key] = value
            var fields = base; fields["trigger"] = trigger; invalid.append(fields)
        }
        for key in ["type", "repo", "events", "ciBranch"] {
            var trigger = githubFields; trigger.removeValue(forKey: key)
            var fields = base; fields["trigger"] = trigger; invalid.append(fields)
        }
        for value: Any in [NSNull(), [[githubFields]], "github"] { var fields = base; fields["trigger"] = value; invalid.append(fields) }
        var both = base; both["schedule"] = "@daily"; invalid.append(both)
        for fields in invalid {
            await #expect(throws: AutomationStateChangeError.self) {
                _ = try await session.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context)
            }
        }
        for id in [f.peerRoutine.id, UUID()] {
            await #expect(throws: AutomationStateChangeError.unavailable) {
                _ = try await session.tools(for: f.owner.id)[2].execute(writeCall([
                    "target": "routine", "action": "update", "id": id.uuidString, "trigger": githubFields]), context: f.context)
            }
        }
        let unchanged = await f.automations.list()
        expectNoDifference(unchanged, [f.routine, f.peerRoutine])
    }

    @Test(arguments: ["create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-sentry", "update-sentry"], [false, true])
    func eventWritesRecheckSpendGuardAfterApproval(scenario: String, initiallyPaused: Bool) async throws {
        let action = scenario.hasPrefix("create") ? "create" : "update"
        let eventFields = scenario.hasSuffix("sentry") ? sentryFields : scenario.hasSuffix("linear") ? linearFields : scenario.hasSuffix("github") ? githubFields : scenario.hasSuffix("group") ? groupFields : scenario.hasSuffix("mixed") ? mixedFields : slackFields
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if initiallyPaused { try await f.automations.answerSpendGuard(.pause, at: Date(timeIntervalSince1970: 2_000)) }
        let session = f.session(authorize: { _, _, _, _ in
            #expect(!initiallyPaused)
            try await f.automations.answerSpendGuard(.pause, at: Date(timeIntervalSince1970: 2_000))
        })
        defer { session.close() }
        var fields: [String: Any] = ["target": "routine", "action": action, "trigger": eventFields]
        if action == "create" { fields["name"] = "Review"; fields["prompt"] = "Review" }
        else { fields["id"] = f.routine.id.uuidString; fields["enabled"] = true }
        await #expect(throws: (any Error).self) {
            _ = try await session.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context)
        }
        let values = await f.automations.list()
        expectNoDifference(values.count, 2); #expect(values.allSatisfy { !$0.enabled })
        expectNoDifference(values.first?.trigger, f.routine.trigger)
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

    @Test(arguments: ["create", "update", "create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-sentry", "update-sentry"], ["deny", "archive", "save-failure", "stale"])
    func routineWritesFailClosed(scenario: String, mode: String) async throws {
        let action = scenario.hasPrefix("create") ? "create" : "update"
        let eventFields = scenario.hasSuffix("sentry") ? sentryFields : scenario.hasSuffix("linear") ? linearFields : scenario.hasSuffix("github") ? githubFields : scenario.hasSuffix("slack") ? slackFields : scenario.hasSuffix("group") ? groupFields : scenario.hasSuffix("mixed") ? mixedFields : nil
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
        var fields: [String: Any] = action == "create"
            ? ["target": "routine", "action": action, "name": "Review", "prompt": "Review", "schedule": "@daily"]
            : ["target": "routine", "action": action, "id": f.routine.id.uuidString, "prompt": "Revised"]
        if let eventFields { fields.removeValue(forKey: "schedule"); fields["trigger"] = eventFields }
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

    @Test(arguments: ["create", "update", "create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-sentry", "update-sentry"], [false, true])
    func routineWritesStopAcrossApprovalAndCommit(scenario: String, duringCommit: Bool) async throws {
        let action = scenario.hasPrefix("create") ? "create" : "update"
        let eventFields = scenario.hasSuffix("sentry") ? sentryFields : scenario.hasSuffix("linear") ? linearFields : scenario.hasSuffix("github") ? githubFields : scenario.hasSuffix("slack") ? slackFields : scenario.hasSuffix("group") ? groupFields : scenario.hasSuffix("mixed") ? mixedFields : nil
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = RoutineGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.automations.applyStateChange(change, lifetime: lifetime)
        })
        var fields: [String: Any] = action == "create"
            ? ["target": "routine", "action": action, "name": "Review", "prompt": "Review", "schedule": "@daily"]
            : ["target": "routine", "action": action, "id": f.routine.id.uuidString, "prompt": "Revised"]
        if let eventFields { fields.removeValue(forKey: "schedule"); fields["trigger"] = eventFields }
        let task = Task { try await session.tools(for: f.owner.id)[2].execute(writeCall(fields), context: f.context) }
        await gate.waitForEntry(); session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let values = await f.automations.list()
        expectNoDifference(values, [f.routine, f.peerRoutine])
    }

    @Test(arguments: ["time", "github", "slack", "group", "mixed", "linear", "sentry"]) func routineCreationBudgetReceiptAndCapacityAreBounded(kind: String) async throws {
        let eventFields = kind == "sentry" ? sentryFields : kind == "linear" ? linearFields : kind == "github" ? githubFields : kind == "slack" ? slackFields : kind == "group" ? groupFields : kind == "mixed" ? mixedFields : nil
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            _ = try await f.automations.applyStateChange(change, lifetime: lifetime)
            throw AutomationStateChangeError.invalid
        })
        let tool = session.tools(for: f.owner.id)[2]
        var fields: [String: Any] = ["target": "routine", "action": "create", "name": "Review", "prompt": "Review", "schedule": "@daily"]
        if let eventFields { fields.removeValue(forKey: "schedule"); fields["trigger"] = eventFields }
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

    @Test(arguments: ["create", "update", "create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-sentry", "update-sentry"]) func routineWritesRequireAnAuthorizerAndMatchingScope(scenario: String) async throws {
        let action = scenario.hasPrefix("create") ? "create" : "update"
        let eventFields = scenario.hasSuffix("sentry") ? sentryFields : scenario.hasSuffix("linear") ? linearFields : scenario.hasSuffix("github") ? githubFields : scenario.hasSuffix("slack") ? slackFields : scenario.hasSuffix("group") ? groupFields : scenario.hasSuffix("mixed") ? mixedFields : nil
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.context.conversationID, agents: f.agents,
            automations: f.automations, routineTimeZoneIdentifier: "Asia/Taipei")
        var fields: [String: Any] = action == "create"
            ? ["target": "routine", "action": action, "name": "Review", "prompt": "Review", "schedule": "@daily"]
            : ["target": "routine", "action": action, "id": f.routine.id.uuidString, "name": "Renamed"]
        if let eventFields { fields.removeValue(forKey: "schedule"); fields["trigger"] = eventFields }
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
