import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAutomations
import FiliconAppServices
import FiliconDomain

@Suite("Automation group binding", .timeLimit(.minutes(1)))
struct AutomationGroupBindingTests {
    let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let peer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let base = Date(timeIntervalSince1970: 1_000)
    private func values() -> (Automation, AgentGroup) {
        (.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, agentID: owner,
            name: "Routine", prompt: "REVIEWED_TASK", trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), createdAt: base),
         .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Group", summary: "Goal", memberIDs: [owner, peer]))
    }

    @Test(arguments: ["prompt", "name", "trigger", "revision", "owner", "group", "members", "goal", "account", "rotation", "runtime"])
    func consentBindsExactAuthorityButNotRoutineRuntimeBookkeeping(change: String) throws {
        var (automation, group) = values()
        let binding = try AutomationGroupSessionBinding(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
            automation: automation, accountID: "local", group: group, reviewedAt: base)
        var account = "local"
        switch change {
        case "prompt": automation.prompt = "UNREVIEWED_TASK"
        case "name": automation.name = "Renamed"
        case "trigger": automation.trigger = .cron(expression: "@daily", timeZoneIdentifier: "UTC")
        case "revision": automation.revision += 1
        case "owner": automation = .init(id: automation.id, agentID: peer, name: automation.name,
            prompt: automation.prompt, trigger: automation.trigger, createdAt: automation.createdAt)
        case "group": group = .init(id: peer, name: group.name, summary: group.summary, memberIDs: group.memberIDs)
        case "members": group.memberIDs = [owner]
        case "goal": group.summary = "Unreviewed goal"
        case "account": account = "other"
        case "rotation": group.nextSpeakerOffset = 1
        default: automation.lastRunAt = base.addingTimeInterval(60); automation.nextRunAt = base.addingTimeInterval(120)
        }
        expectNoDifference(binding.matches(automation: automation, accountID: account, group: group), change == "rotation" || change == "runtime")
    }

    @Test func grantsAreSeparateFromDefinitionsPersistedAndRevocableWithCompareAndSave() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-consent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "bindings.json")
        let store = try AutomationGroupSessionBindingStore(url: url)
        let (automation, group) = values()
        let binding = try AutomationGroupSessionBinding(id: owner, automation: automation, accountID: "local", group: group, reviewedAt: base)
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        try await store.save(binding, replacing: nil, lease: lease)
        let reopened = try AutomationGroupSessionBindingStore(url: url)
        let saved = await reopened.list()
        expectNoDifference(saved, [binding])
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("REVIEWED_TASK"))
        let other = try AutomationGroupSessionBinding(id: peer, automation: automation, accountID: "local", group: group,
            memoryAccess: .savedFacts, reviewedAt: base)
        await #expect(throws: AutomationGroupSessionError.reviewRequired) {
            try await store.save(other, replacing: nil, lease: lease)
        }
        scope.invalidate()
        await #expect(throws: CancellationError.self) {
            try await store.save(other, replacing: binding, lease: lease)
        }
        let unchanged = await store.list()
        expectNoDifference(unchanged, [binding])
        try await store.revoke(binding, lease: scope.capture())
        let afterRevoke = try AutomationGroupSessionBindingStore(url: url)
        #expect(await afterRevoke.list().isEmpty)
    }

    @Test func failedConsentSaveDoesNotArmAnInMemoryGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-consent-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "bindings.json")
        let store = try AutomationGroupSessionBindingStore(url: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let (automation, group) = values()
        let binding = try AutomationGroupSessionBinding(automation: automation, accountID: "local", group: group, reviewedAt: base)
        await #expect(throws: (any Error).self) {
            try await store.save(binding, replacing: nil, lease: AgentWorkflowExecutionScope().capture())
        }
        #expect(await store.list().isEmpty)
    }

    @Test func disabledBackgroundMemoryRejectsTheUpdateStateBypass() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-memory-denial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let profile = try await agents.create(name: "Owner", at: base)
        try await agents.applyMemoryChange(.init(operation: .write,
            memory: .init(accountID: "local", agentID: profile.id, fact: "EXISTING_PRIVATE_FACT", createdAt: base)), lifetime: .init())
        let session = AgentManagementSession(originID: owner, agents: agents, allowsSavedMemory: false)
        let tools = session.tools(for: profile.id)
        #expect(!tools.contains { $0.descriptor.name == "SearchMemory" })
        let update = try #require(tools.first { $0.descriptor.name == "update_state" })
        let provider = try #require(update as? any ToolRuntimeContextProviding)
        let context = ToolContext(conversationID: owner, runID: peer)
        let text = try await provider.runtimeContext(for: context)
        #expect(!text.contains("EXISTING_PRIVATE_FACT"))
        let call = try NormalizedToolCall(id: "bypass", name: "update_state",
            argumentsJSON: Data(#"{"target":"memory","action":"write","fact":"MUST_NOT_SAVE"}"#.utf8))
        await #expect(throws: AgentMemoryError.unavailable) { try await update.execute(call, context: context) }
        let facts = await agents.memories(accountID: "local", agentID: profile.id)
        expectNoDifference(facts.map(\.fact), ["EXISTING_PRIVATE_FACT"])
    }

    @Test func groupConsentDoesNotIncludeAnOutsideDelegatedAgentsSavedFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-memory-audience-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let member = try await agents.create(name: "Member", at: base)
        let outside = try await agents.create(name: "Outside", at: base)
        try await agents.applyMemoryChange(.init(operation: .write,
            memory: .init(accountID: "local", agentID: outside.id, fact: "OUTSIDE_PRIVATE_FACT", createdAt: base)), lifetime: .init())
        let session = AgentManagementSession(originID: owner, agents: agents, allowsSavedMemory: true, savedMemoryAudience: [member.id])
        #expect(session.tools(for: member.id).contains { $0.descriptor.name == "SearchMemory" })
        let tools = session.tools(for: outside.id)
        #expect(!tools.contains { $0.descriptor.name == "SearchMemory" })
        let update = try #require(tools.first { $0.descriptor.name == "update_state" })
        let provider = try #require(update as? any ToolRuntimeContextProviding)
        let context = ToolContext(conversationID: owner, runID: peer)
        let text = try await provider.runtimeContext(for: context)
        #expect(!text.contains("OUTSIDE_PRIVATE_FACT"))
        await #expect(throws: AgentMemoryError.unavailable) {
            try await update.execute(.init(id: "bypass", name: "update_state",
                argumentsJSON: Data(#"{"target":"memory","action":"write","fact":"MUST_NOT_SAVE"}"#.utf8)), context: context)
        }
    }
}
