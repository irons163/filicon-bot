import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

@Suite("Conversation final commit guards")
struct ConversationCommitGuardTests {
    private func fixture() async throws -> (URL, ConversationStore, Conversation, DirectConversationAgentBinding) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-commit-guard-\(UUID())")
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let binding = DirectConversationAgentBinding(accountID: "local",
            agentID: UUID(uuidString: "00000000-0000-0000-0000-000000000071")!)
        var conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000072")!,
            title: "Commit fixture", messages: [.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000073")!,
                role: .user, text: "Original", createdAt: Date(timeIntervalSince1970: 1_000))],
            updatedAt: Date(timeIntervalSince1970: 1_000))
        conversation.agentBinding = binding
        try await store.save([conversation])
        return (root, store, conversation, binding)
    }

    @Test(arguments: [false, true])
    func cancellationAtTheFinalWriteCannotCommitToCanonicalOrReplica(historyComplete: Bool) async throws {
        let (root, store, original, binding) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        var proposed = original
        proposed.messages[0].text = "Must not commit"
        await #expect(throws: CancellationError.self) {
            try await store.upsert(proposed, replacingLoadedMessageIDs: Set(original.messages.map(\.id)),
                historyComplete: historyComplete, expectedBinding: binding, commit: { write in
                    scope.invalidate()
                    try lease.commit(write)
                })
        }
        let canonical = try await store.conversation(id: original.id)
        expectNoDifference(canonical, original)
        let replica = try await store.subscribeTranscript(conversationID: original.id)
        expectNoDifference(replica.snapshot.messages, original.messages)
    }

    @Test(arguments: ["account", "agent", "provider", "model", "reasoning", "deleted"])
    func delayedWriteCannotResurrectDeletedOrReboundConversation(change: String) async throws {
        let (root, store, original, binding) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var current = original
        switch change {
        case "account": current.agentBinding = .init(accountID: "other", agentID: binding.agentID)
        case "agent": current.agentBinding = .init(accountID: "local", agentID: UUID())
        case "provider": current.providerID = "other"
        case "model": current.modelID = "other"
        case "reasoning": current.reasoningEffort = .high
        default: break
        }
        if change == "deleted" { try await store.delete(id: original.id) }
        else { try await store.upsert(current, replacingLoadedMessageIDs: [], historyComplete: true) }
        var delayed = original
        delayed.messages[0].text = "Stale background response"
        await #expect(throws: CancellationError.self) {
            try await store.upsert(delayed, replacingLoadedMessageIDs: Set(original.messages.map(\.id)),
                historyComplete: false, expectedBinding: binding)
        }
        let canonical = try await store.conversation(id: original.id)
        expectNoDifference(canonical, change == "deleted" ? nil : current)
    }
}
