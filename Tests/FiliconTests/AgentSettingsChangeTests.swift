import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

@Suite("Approved own-agent notification settings", .timeLimit(.minutes(1)))
struct AgentSettingsChangeTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let owner: AgentProfile
        let peer: AgentProfile
        let context: ToolContext
        var file: URL { root.appending(path: "agents.json") }
        func session(authorize: @escaping AgentManagementSession.SettingsAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.SettingsCommitter? = nil) -> AgentManagementSession {
            .init(originID: context.conversationID, agents: agents, authorize: { _, _, _, _ in },
                  now: { Date(timeIntervalSince1970: 2_000) }, authorizeSettings: authorize, commitSettings: commit)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-settings-test-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Designer", instructions: "PRIVATE_PERSONA", at: Date(timeIntervalSince1970: 1_000))
        let peer = try await agents.create(name: "Engineer", at: Date(timeIntervalSince1970: 1_001))
        return .init(root: root, agents: agents, owner: owner, peer: peer,
            context: .init(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!))
    }
    private func call(_ json: String = #"{"target":"settings","action":"set","notify_on_updates":false}"#,
                      id: ToolCallID = "settings") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: Data(json.utf8))
    }

    @Test func settingsRequireExplicitApprovalByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-settings-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Designer")
        let context = ToolContext(conversationID: UUID())
        let session = AgentManagementSession(originID: context.conversationID, agents: agents)
        let call = try NormalizedToolCall(id: "settings", name: "update_state",
            argumentsJSON: Data(#"{"target":"settings","action":"set","notify_on_updates":false}"#.utf8))
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await session.tools(for: owner.id)[2].execute(call, context: context)
        }
        let unchanged = await agents.profile(id: owner.id)
        expectNoDifference(unchanged, owner)
    }

    @Test func approvalPersistsOnlyOwnPreferenceAndReplayIsIdempotent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { sender, change, _, context in
            expectNoDifference(sender, f.owner)
            expectNoDifference(change, .init(agentID: f.owner.id, notifyOnUpdates: false, previousValue: true, previousRevision: nil))
            expectNoDifference(context.conversationID, f.context.conversationID)
            let before = await f.agents.profile(id: sender.id)
            expectNoDifference(before, f.owner)
            var renamed = sender; renamed.name = "New name"; renamed.instructions = "NEW_PRIVATE"; renamed.modelID = "new-model"
            try await f.agents.update(renamed)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let result = try await tool.execute(call(), context: f.context)
        let saved = try #require(await f.agents.profile(id: f.owner.id))
        #expect(!result.isError)
        expectNoDifference(saved.notifyOnAgentUpdates, false)
        #expect(saved.notificationSettingsRevision != nil)
        expectNoDifference(saved.name, "New name"); expectNoDifference(saved.instructions, "NEW_PRIVATE")
        expectNoDifference(saved.modelID, "new-model")
        expectNoDifference(saved.updatedAt, Date(timeIntervalSince1970: 2_000))
        let replay = try await tool.execute(call(), context: f.context)
        expectNoDifference(replay, result)
        let afterReplay = await f.agents.profile(id: f.owner.id)
        expectNoDifference(afterReplay, saved)
        let restored = try AgentService(storeURL: f.file)
        let durable = await restored.profile(id: f.owner.id), peer = await restored.profile(id: f.peer.id)
        expectNoDifference(durable, saved); expectNoDifference(peer, f.peer)
        let contextProvider = try #require(tool as? any ToolRuntimeContextProviding)
        let instructions = try await contextProvider.runtimeContext(for: f.context)
        #expect(instructions.contains("Own notify_on_updates: false"))
        #expect(instructions.contains("hidden_from_sidebar"))
        let leaked = ["PRIVATE_PERSONA", "NEW_PRIVATE", f.root.path].filter { instructions.contains($0) }
        expectNoDifference(leaked, [])
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call(#"{"target":"settings","action":"set","notify_on_updates":true}"#), context: f.context)
        }
        session.close()
    }

    @Test func strictBooleanAndUnsupportedFieldsFailClosed() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Malformed proposal reached approval") })
        let tool = session.tools(for: f.owner.id)[2]
        for value in ["0", "1", "1.0", "null", #""true""#, "[]", "{}"] {
            await #expect(throws: AgentSettingsChangeError.invalid) {
                _ = try await tool.execute(call("{\"target\":\"settings\",\"action\":\"set\",\"notify_on_updates\":\(value)}"), context: f.context)
            }
        }
        for json in [#"{"target":"settings","action":"set"}"#, #"{"target":"settings","action":"clear","notify_on_updates":false}"#,
                     #"{"target":"settings","action":"set","hidden_from_sidebar":true}"#,
                     #"{"target":"settings","action":"set","notify_on_updates":false,"hidden_from_sidebar":false}"#,
                     #"{"target":"settings","action":"set","notify_on_updates":false,"agent_id":"peer"}"#,
                     #"{"target":"settings","action":"set","notify_on_updates":false,"permissions":"all"}"#] {
            await #expect(throws: AgentSettingsChangeError.invalid) { _ = try await tool.execute(call(json), context: f.context) }
        }
        await #expect(throws: AgentSettingsChangeError.invalid) {
            _ = try await tool.execute(call(String(repeating: " ", count: 4_097) + #"{"target":"settings","action":"set","notify_on_updates":false}"#), context: f.context)
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(call(), context: .init(conversationID: UUID()))
        }
        await #expect(throws: AgentProfileChangeError.unavailable) {
            _ = try await session.tools(for: UUID())[2].execute(call(), context: f.context)
        }
        let profiles = await f.agents.list()
        expectNoDifference(profiles, [f.owner, f.peer])
    }

    @Test(arguments: ["stale", "aba", "archive", "disk"])
    func commitRechecksFreshnessAndRollsBackOnWriteFailure(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in
            if mode == "archive" { try await f.agents.archive(id: f.owner.id); return }
            if mode == "disk" {
                try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
                try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
                return
            }
            var changed = f.owner; changed.notifyOnAgentUpdates = false
            try await f.agents.update(changed)
            if mode == "aba" {
                changed = try #require(await f.agents.profile(id: f.owner.id)); changed.notifyOnAgentUpdates = true
                try await f.agents.update(changed)
            }
        })
        await #expect(throws: (any Error).self) { _ = try await session.tools(for: f.owner.id)[2].execute(call(), context: f.context) }
        let saved = try #require(await f.agents.profile(id: f.owner.id))
        expectNoDifference(saved.notifyOnAgentUpdates, mode != "stale")
        if mode == "disk" {
            expectNoDifference(saved, f.owner)
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.moveItem(at: f.root.appending(path: "backup.json"), to: f.file)
            let restored = try AgentService(storeURL: f.file)
            let durable = await restored.profile(id: f.owner.id)
            expectNoDifference(durable, f.owner)
        }
    }

    @Test(arguments: [false, true]) func stopRevokesPendingApprovalAndDelayedCommit(duringCommit: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = SettingsGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.agents.applySettingsChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let task = Task { try await tool.execute(call(), context: f.context) }
        await gate.waitForEntry()
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(), context: f.context) }
        session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let saved = await f.agents.profile(id: f.owner.id)
        expectNoDifference(saved, f.owner)
    }

    @Test func durableReceiptAndSharedBudgetSurviveLateBookkeepingFailure() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            _ = try await f.agents.applySettingsChange(change, lifetime: lifetime)
            throw CancellationError()
        })
        let tool = session.tools(for: f.owner.id)[2]
        let result = try await tool.execute(call(), context: f.context)
        #expect(!result.isError)
        for i in 1...3 {
            _ = try await tool.execute(call("{\"target\":\"profile\",\"action\":\"set\",\"name\":\"Name \(i)\"}", id: .init(rawValue: "profile-\(i)")), context: f.context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tool.execute(call(#"{"target":"settings","action":"set","notify_on_updates":true}"#, id: "fifth"), context: f.context)
        }
        let replay = try await tool.execute(call(), context: f.context)
        expectNoDifference(replay, result)
    }

    @Test func migrationNoOpAndStaleEditorDoNotResetPreference() async throws {
        let json = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy"}"#
        let legacy = try JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
        expectNoDifference(legacy.notifyOnAgentUpdates, true); #expect(legacy.notificationSettingsRevision == nil)
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let noOp = AgentSettingsChange(agentID: f.owner.id, notifyOnUpdates: true, previousValue: true, previousRevision: nil)
        let unchanged = try await f.agents.applySettingsChange(noOp, lifetime: .init())
        expectNoDifference(unchanged, f.owner)
        let muted = try await f.agents.applySettingsChange(.init(agentID: f.owner.id, notifyOnUpdates: false,
            previousValue: true, previousRevision: nil), lifetime: .init())
        var oldEditor = f.owner; oldEditor.name = "Stale editor"
        await #expect(throws: AgentSettingsChangeError.stale) { try await f.agents.update(oldEditor) }
        let saved = await f.agents.profile(id: f.owner.id)
        expectNoDifference(saved, muted)
        var freshEditor = muted; freshEditor.notifyOnAgentUpdates = true
        try await f.agents.update(freshEditor)
        let unmuted = try #require(await f.agents.profile(id: f.owner.id))
        expectNoDifference(unmuted.notifyOnAgentUpdates, true)
        #expect(unmuted.notificationSettingsRevision != muted.notificationSettingsRevision)
    }
}

private actor SettingsGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        await withCheckedContinuation { waiter = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}
