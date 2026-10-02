import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
import FiliconDomain

@Suite("Routine direct binding consent") struct AutomationDirectBindingTests {
    private func fixture() throws -> (Automation, Conversation, AgentProfile, AutomationDirectSessionBinding) {
        let time = Date(timeIntervalSince1970: 1_000)
        let agent = AgentProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000061")!, name: "Fixture", instructions: "Persona")
        let routine = Automation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000062")!, agentID: agent.id,
            name: "Routine", prompt: "Task", trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), createdAt: time)
        var conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000063")!, title: "Fixture")
        conversation.agentBinding = .init(accountID: "local", agentID: agent.id)
        return (routine, conversation, agent, try .init(id: routine.id, automation: routine, accountID: "local",
            conversation: conversation, profile: agent, reviewedAt: time))
    }
    @Test(arguments: ["routine", "identity", "persona", "model", "reasoning", "account", "archived", "unbound"])
    func consentMatchesOnlyTheReviewedExecutionIdentity(change: String) throws {
        var (routine, conversation, agent, grant) = try fixture()
        #expect(grant.matches(automation: routine, accountID: "local", conversation: conversation, profile: agent))
        var account = "local"
        switch change {
        case "routine": routine.prompt = "Changed task"
        case "identity": conversation = .init(title: "Fixture")
        case "persona": agent.instructions = "New persona"
        case "model": conversation.modelID = "other"; agent.modelID = "other"
        case "reasoning": conversation.reasoningEffort = .high
        case "account": account = "other"
        case "archived": agent.archivedAt = Date(timeIntervalSince1970: 2_000)
        default: conversation.agentBinding = nil
        }
        #expect(!grant.matches(automation: routine, accountID: account, conversation: conversation, profile: agent))
    }
    @Test func runtimeActivityAndChatTitleDoNotRewriteConsent() throws {
        var (routine, conversation, agent, grant) = try fixture()
        agent.status = .running; agent.unreadCount = 20
        conversation.title = "Renamed"; conversation.messages.append(.init(role: .user, text: "New human message"))
        routine.nextRunAt = Date(timeIntervalSince1970: 3_600)
        #expect(grant.matches(automation: routine, accountID: "local", conversation: conversation, profile: agent))
    }
    @Test func durableCompareAndSaveRejectsStaleSheetsAndRevokedLeases() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-consent-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (routine, conversation, profile, grant) = try fixture()
        let url = root.appending(path: "consent.json"), scope = AgentWorkflowExecutionScope()
        let lease = try scope.capture(), store = try AutomationDirectSessionBindingStore(url: url)
        try await store.save(grant, replacing: nil, lease: lease)
        let replacement = try AutomationDirectSessionBinding(automation: routine, accountID: "local", conversation: conversation,
            profile: profile, memoryAccess: .savedFacts)
        await #expect(throws: AutomationDirectSessionError.reviewRequired) {
            try await store.save(replacement, replacing: nil, lease: lease)
        }
        scope.invalidate()
        await #expect(throws: CancellationError.self) {
            try await store.save(replacement, replacing: grant, lease: lease)
        }
        let reopened = try AutomationDirectSessionBindingStore(url: url)
        let values = await reopened.list()
        expectNoDifference(values, [grant])
        let permission = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        expectNoDifference(permission, 0o600)
    }
}
