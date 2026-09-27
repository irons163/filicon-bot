import CustomDump
import FiliconAppServices
import FiliconAgents
import FiliconDomain
import FiliconPersistence
import Foundation
import Testing

@Suite("Exact sidebar conversation binding")
struct BoundConversationLookupTests {
    @Test(arguments: ["rename", "messages", "delete", "rebind", "duplicate", "closed", "wrong-target", "legacy-hide"])
    func leaseFencesAtomicSettingsSave(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-binding-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let agent = try await agents.create(name: "Designer", at: Date(timeIntervalSince1970: 100))
        var chat = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Before", updatedAt: Date(timeIntervalSince1970: 100))
        chat.agentBinding = .init(accountID: "local", agentID: agent.id)
        try await store.upsert(chat, replacingLoadedMessageIDs: [], historyComplete: true)
        let lease = try await store.leaseUniqueBinding(accountID: "local", agentID: agent.id, conversationID: chat.id)
        defer { lease.close() }
        let visibility = AgentSidebarVisibility(accountID: mode == "wrong-target" ? "other" : "local",
            agentID: agent.id, conversationID: chat.id, hidden: true)
        let change = AgentSettingsChange(agentID: agent.id, notifyOnUpdates: false, previousValue: true,
            previousRevision: nil, visibility: .init(proposed: visibility, previous: nil))
        switch mode {
        case "delete": try await store.delete(id: chat.id)
        case "closed": lease.close()
        case "duplicate":
            var duplicate = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, title: "Duplicate")
            duplicate.agentBinding = chat.agentBinding
            try await store.upsert(duplicate, replacingLoadedMessageIDs: [], historyComplete: true)
        case "rebind", "rename", "messages", "legacy-hide":
            if mode == "rebind" { chat.agentBinding = .init(accountID: "other", agentID: agent.id) }
            if mode == "rename" { chat.title = "After" }
            if mode == "messages" { chat.messages = [.init(role: .user, text: "New message")] }
            if mode == "legacy-hide" { chat.hiddenAt = Date(timeIntervalSince1970: 200) }
            try await store.upsert(chat, replacingLoadedMessageIDs: [], historyComplete: true)
        default: break
        }
        let succeeds = mode == "rename" || mode == "messages"
        let lifetime = AgentSettingsChangeLifetime()
        if succeeds {
            _ = try await agents.applyBoundSettingsChange(change, lifetime: lifetime, bindingLease: lease)
        } else if mode == "wrong-target" {
            await #expect(throws: AgentSettingsChangeError.invalid) {
                _ = try await agents.applyBoundSettingsChange(change, lifetime: lifetime, bindingLease: lease)
            }
            expectNoDifference(lifetime.committedProfile(for: change), nil)
        } else {
            await #expect(throws: CancellationError.self) {
                _ = try await agents.applyBoundSettingsChange(change, lifetime: lifetime, bindingLease: lease)
            }
            expectNoDifference(lifetime.committedProfile(for: change), nil)
        }
        let reopened = try AgentService(storeURL: root.appending(path: "agents.json"))
        let saved = await reopened.sidebarVisibility(accountID: visibility.accountID, agentID: agent.id, conversationID: chat.id)
        expectNoDifference(saved, succeeds ? visibility : nil)
        let profile = await reopened.profile(id: agent.id)
        expectNoDifference(profile?.notifyOnAgentUpdates, !succeeds)
    }

    @Test func resolvesAllPagesAndRejectsAmbiguousHiddenHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-bound-lookup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let otherAgentID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let missing = try await store.uniqueBoundConversation(accountID: "local", agentID: agentID)
        expectNoDifference(missing, nil)
        for index in 1...55 {
            var value = Conversation(id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index))!,
                title: "Designer", updatedAt: Date(timeIntervalSince1970: Double(index + 100)))
            if index == 1 { value.agentBinding = .init(accountID: "other", agentID: agentID) }
            if index == 2 { value.agentBinding = .init(accountID: "local", agentID: otherAgentID) }
            try await store.upsert(value, replacingLoadedMessageIDs: [], historyComplete: true)
        }
        let stillMissing = try await store.uniqueBoundConversation(accountID: "local", agentID: agentID)
        expectNoDifference(stillMissing, nil)
        var target = Conversation(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            title: "Renamed", updatedAt: Date(timeIntervalSince1970: 1), hiddenAt: Date(timeIntervalSince1970: 1))
        target.agentBinding = .init(accountID: "local", agentID: agentID)
        target.messages = [.init(role: .user, text: "History must not be loaded or lost")]
        try await store.upsert(target, replacingLoadedMessageIDs: [], historyComplete: true)
        let firstPage = try await store.conversationPage()
        #expect(!firstPage.items.contains(where: { $0.id == target.id }))
        let resolved = try await store.uniqueBoundConversation(accountID: "local", agentID: agentID)
        var metadata = target; metadata.messages = []
        expectNoDifference(resolved, metadata)
        let reopened = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let durable = try await reopened.uniqueBoundConversation(accountID: "local", agentID: agentID)
        expectNoDifference(durable, metadata)
        var duplicate = Conversation(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            title: "Different title", updatedAt: Date(timeIntervalSince1970: 2))
        duplicate.agentBinding = target.agentBinding
        try await store.upsert(duplicate, replacingLoadedMessageIDs: [], historyComplete: true)
        await #expect(throws: BoundConversationLookupError.ambiguous) {
            _ = try await store.uniqueBoundConversation(accountID: "local", agentID: agentID)
        }
        await #expect(throws: BoundConversationLookupError.ambiguous) {
            _ = try await store.leaseUniqueBinding(accountID: "local", agentID: agentID, conversationID: target.id)
        }
        // A fresh query must see a changed binding; no title or cached result fallback.
        duplicate.agentBinding = .init(accountID: "other", agentID: agentID)
        try await store.upsert(duplicate, replacingLoadedMessageIDs: [], historyComplete: true)
        let afterRebind = try await store.uniqueBoundConversation(accountID: "local", agentID: agentID)
        expectNoDifference(afterRebind, metadata)
        try await store.delete(id: target.id)
        let deleted = try await store.uniqueBoundConversation(accountID: "local", agentID: agentID)
        expectNoDifference(deleted, nil)
        await #expect(throws: BoundConversationLookupError.invalidAccount) {
            _ = try await store.uniqueBoundConversation(accountID: " \n", agentID: agentID)
        }
    }
}
