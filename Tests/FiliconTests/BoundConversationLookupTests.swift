import CustomDump
import FiliconAppServices
import FiliconDomain
import FiliconPersistence
import Foundation
import Testing

@Suite("Exact sidebar conversation binding")
struct BoundConversationLookupTests {
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
