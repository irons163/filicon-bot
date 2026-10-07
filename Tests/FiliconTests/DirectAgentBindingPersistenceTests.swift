import CSQLite
import CustomDump
import FiliconDomain
import FiliconPersistence
import FiliconAppServices
import Foundation
import Testing

@Suite("Direct agent binding persistence", .timeLimit(.minutes(1)))
struct DirectAgentBindingPersistenceTests {
    private let agentID = UUID(uuidString: "10000000-0000-0000-0000-000000000042")!

    @Test(arguments: ["valid", "wrong-owner", "wrong-run", "human", "completed", "rebound", "deleted", "sql-failure"])
    func nativeCancellationOnlyRetiresItsExactUnfinishedRows(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-binding-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.sqlite3"), now = Date(timeIntervalSince1970: 1000)
        let repository = try ConversationRepository(databaseURL: file)
        let binding = DirectConversationAgentBinding(accountID: "account-a", agentID: agentID)
        let runID = UUID(uuidString: "10000000-0000-0000-0000-000000000061")!
        var chat = Conversation(title: "Latest canonical title", messages: [
            .init(role: .user, text: "Canonical human", createdAt: now),
            .init(id: runID, role: change == "human" ? .user : .assistant, text: "Retain existing body",
                createdAt: now.addingTimeInterval(1), deliveryStatus: change == "completed" ? .succeeded : .streaming,
                toolActivities: [.init(id: "pending-write", name: "local__write_file")]),
            .init(role: .assistant, text: "", createdAt: now.addingTimeInterval(2), transcriptCards: [
                .init(lifecycle: .waiting, payload: .autoReview(.init(reviewID: "own-review", title: "Actual review"))),
                .init(lifecycle: .waiting, payload: .autoReview(.init(reviewID: "other-review", title: "Unrelated review")))
            ]),
            .init(role: .user, text: "New unrelated canonical content", createdAt: now.addingTimeInterval(3))
        ], updatedAt: now.addingTimeInterval(4))
        chat.agentBinding = binding
        if change == "rebound" { chat.agentBinding = .init(accountID: "another-account", agentID: agentID) }
        try await repository.save([chat], activityAt: now.addingTimeInterval(5))
        if change == "deleted" { try await repository.delete(id: chat.id) }
        if change == "sql-failure" {
            var handle: OpaquePointer?
            try #require(sqlite3_open(file.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            try #require(sqlite3_exec(handle, "CREATE TRIGGER reject_cancel BEFORE INSERT ON messages WHEN NEW.role='assistant' BEGIN SELECT RAISE(ABORT,'isolated cancellation failure'); END", nil, nil, nil) == SQLITE_OK)
        }
        let before = try await repository.load(), readBefore = try await repository.unreadState(conversationID: chat.id)
        let owner = change == "wrong-owner" ? DirectConversationAgentBinding(accountID: "another-account", agentID: agentID) : binding
        let target = change == "wrong-run" ? UUID() : runID
        // Run/card identities are independently exact; do not supply another
        // run's approval IDs when testing a non-eligible message.
        let reviewIDs: Set<String> = ["valid", "sql-failure"].contains(change) ? ["own-review"] : []
        if change == "sql-failure" {
            await #expect(throws: (any Error).self) {
                _ = try await repository.retireActivityAcknowledgment(conversationID: chat.id, runID: target,
                    expectedBinding: owner, reviewIDs: reviewIDs)
            }
        } else {
            _ = try await repository.retireActivityAcknowledgment(conversationID: chat.id, runID: target,
                expectedBinding: owner, reviewIDs: reviewIDs)
        }
        let after = try await repository.load(), readAfter = try await repository.unreadState(conversationID: chat.id)
        if change == "valid" {
            var expected = try #require(before.first)
            expected.messages[1].deliveryStatus = .cancelled
            expected.messages[1].toolActivities[0].status = .failed
            expected.messages[1].toolActivities[0].result = "Cancelled"
            expected.messages[2].transcriptCards[0].lifecycle = .cancelled
            expectNoDifference(after, [expected])
            _ = try await repository.retireActivityAcknowledgment(conversationID: chat.id, runID: target,
                expectedBinding: owner, reviewIDs: reviewIDs)
            let replay = try await repository.load()
            expectNoDifference(replay, after)
        } else { expectNoDifference(after, before) }
        expectNoDifference(readAfter, readBefore)
    }

    @Test(arguments: ["valid", "closed", "rebind-cycle", "hide-cycle", "duplicate", "delete", "provider", "model",
        "reasoning", "new-hidden", "wrong-target", "wrong-expected", "close-at-commit", "reject-at-commit", "sql-failure"])
    func leasedUpsertsFenceTheFinalSQLWriteWithoutReenteringOwnerRevocation(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-binding-upsert-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.sqlite3"), now = Date(timeIntervalSince1970: 1000)
        let repository = try ConversationRepository(databaseURL: file)
        let binding = DirectConversationAgentBinding(accountID: "account-a", agentID: agentID)
        var original = Conversation(title: "Original leased chat", messages: [.init(role: .user, text: "Canonical human", createdAt: now)], updatedAt: now)
        original.agentBinding = binding
        try await repository.save([original], activityAt: now)
        let lease = try await repository.leaseUniqueBinding(accountID: binding.accountID, agentID: agentID, conversationID: original.id)
        defer { lease.close() }
        var proposed = original
        proposed.messages.append(.init(role: .assistant, text: "Scoped acknowledgment", createdAt: now.addingTimeInterval(2)))
        switch change {
        case "closed": lease.close()
        case "rebind-cycle":
            var other = original; other.agentBinding = nil
            try await repository.save([other], activityAt: now.addingTimeInterval(1))
            try await repository.save([original], activityAt: now.addingTimeInterval(2))
        case "hide-cycle":
            var hidden = original; hidden.hiddenAt = now
            try await repository.save([hidden], activityAt: now.addingTimeInterval(1))
            try await repository.save([original], activityAt: now.addingTimeInterval(2))
        case "duplicate":
            var duplicate = Conversation(updatedAt: now); duplicate.agentBinding = binding
            try await repository.save([original, duplicate], activityAt: now.addingTimeInterval(1))
        case "delete": try await repository.delete(id: original.id)
        case "provider": proposed.providerID = "different"
        case "model": proposed.modelID = "different"
        case "reasoning": proposed.reasoningEffort = .high
        case "new-hidden": proposed.hiddenAt = now
        case "wrong-target":
            proposed = Conversation(title: original.title, providerID: original.providerID, modelID: original.modelID,
                messages: proposed.messages, updatedAt: original.updatedAt)
            proposed.agentBinding = binding
        case "sql-failure":
            var handle: OpaquePointer?
            try #require(sqlite3_open(file.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            try #require(sqlite3_exec(handle, "CREATE TRIGGER reject_leased_ack BEFORE INSERT ON messages WHEN NEW.role='assistant' BEGIN SELECT RAISE(ABORT,'isolated leased upsert failure'); END", nil, nil, nil) == SQLITE_OK)
        default: break
        }
        let before = try await repository.load(), readBefore = try await repository.unreadState(conversationID: original.id)
        let expected = change == "wrong-expected" ? nil : binding
        let commit: ConversationCommitGuard = { operation in
            if change == "close-at-commit" { lease.close() }
            if change == "reject-at-commit" { throw CancellationError() }
            try operation()
        }
        if change == "valid" {
            try await repository.upsert(proposed, expectedBinding: expected, bindingLease: lease,
                activityAt: now.addingTimeInterval(3), commit: commit)
            let saved = try #require(try await repository.conversation(id: original.id))
            expectNoDifference(saved.messages, proposed.messages)
            #expect(lease.isActive)
            let unread = try await repository.unreadState(conversationID: original.id)
            expectNoDifference(unread?.unreadCount, (readBefore?.unreadCount ?? 0) + 1)
        } else {
            await #expect(throws: (any Error).self) {
                try await repository.upsert(proposed, expectedBinding: expected, bindingLease: lease,
                    activityAt: now.addingTimeInterval(3), commit: commit)
            }
            let after = try await repository.load(), readAfter = try await repository.unreadState(conversationID: original.id)
            expectNoDifference(after, before); expectNoDifference(readAfter, readBefore)
        }
    }

    @Test func pagedLeasedPublicationPreservesUnseenHistoryAndCannotWriteAfterRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-binding-paged-lease-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1000), store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let binding = DirectConversationAgentBinding(accountID: "account-a", agentID: agentID)
        var conversation = Conversation(messages: (0..<65).map {
            .init(role: .user, text: "Canonical history \($0)", createdAt: now.addingTimeInterval(Double($0)))
        }, updatedAt: now.addingTimeInterval(65))
        conversation.agentBinding = binding
        try await store.upsert(conversation, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        let lease = try await store.leaseUniqueBinding(accountID: binding.accountID, agentID: agentID, conversationID: conversation.id)
        defer { lease.close() }
        let page = try await store.messagePage(conversationID: conversation.id, limit: 3)
        var partial = conversation; partial.messages = page.items
        partial.messages.append(.init(role: .assistant, text: "Scoped paged acknowledgment", createdAt: now.addingTimeInterval(66)))
        try await store.upsert(partial, replacingLoadedMessageIDs: Set(page.items.map(\.id)), historyComplete: false,
            expectedBinding: binding, bindingLease: lease, activityAt: now.addingTimeInterval(67))
        let canonical = try #require(try await store.conversation(id: conversation.id))
        expectNoDifference(Array(canonical.messages.prefix(65)), conversation.messages)
        expectNoDifference(canonical.messages.last?.text, "Scoped paged acknowledgment")
        lease.close(); partial.messages[partial.messages.count - 1].text = "Must not overwrite"
        await #expect(throws: CancellationError.self) {
            try await store.upsert(partial, replacingLoadedMessageIDs: Set(partial.messages.map(\.id)), historyComplete: false,
                expectedBinding: binding, bindingLease: lease, activityAt: now.addingTimeInterval(68))
        }
        let retained = try await store.conversation(id: conversation.id)
        expectNoDifference(retained, canonical)
    }

    @Test func jsonRoundTripAndLegacyAbsence() throws {
        var conversation = Conversation(updatedAt: Date(timeIntervalSince1970: 1000))
        conversation.agentBinding = .init(accountID: "account-a", agentID: agentID)
        let data = try JSONEncoder().encode(conversation)
        expectNoDifference(try JSONDecoder().decode(Conversation.self, from: data), conversation)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "agentBinding")
        let legacy = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        expectNoDifference(legacy.agentBinding, nil)
    }

    @Test func metadataPagesAndPartialEditsRetainBinding() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-binding-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.json")
        var conversation = Conversation(messages: (0..<65).map {
            ChatMessage(role: .user, text: "Message \($0)", createdAt: Date(timeIntervalSince1970: Double(1000 + $0)))
        }, updatedAt: Date(timeIntervalSince1970: 2000))
        conversation.agentBinding = .init(accountID: "account-a", agentID: agentID)
        let store = ConversationStore(fileURL: file)
        try await store.upsert(conversation, replacingLoadedMessageIDs: [], historyComplete: true)
        var partial = conversation
        partial.messages = Array(conversation.messages.suffix(3))
        partial.title = "Renamed"
        try await store.upsert(partial, replacingLoadedMessageIDs: Set(partial.messages.map(\.id)), historyComplete: false)
        let reopened = ConversationStore(fileURL: file)
        let loaded = try #require(try await reopened.conversation(id: conversation.id))
        expectNoDifference(loaded.agentBinding, conversation.agentBinding)
        expectNoDifference(loaded.messages, conversation.messages)
        // Exercise SQLite metadata independently of the full-store cache.
        let repository = try ConversationRepository(databaseURL: root.appending(path: "metadata.sqlite3"))
        try await repository.save([loaded])
        let page = try await repository.conversationPage(.init(limit: 1))
        expectNoDifference(page.items.first?.agentBinding, conversation.agentBinding)
        partial.agentBinding = nil
        try await reopened.upsert(partial, replacingLoadedMessageIDs: Set(partial.messages.map(\.id)), historyComplete: false)
        let unbound = try await reopened.conversation(id: conversation.id)
        expectNoDifference(unbound?.agentBinding, nil)
        expectNoDifference(unbound?.messages, conversation.messages)
    }

    @Test func schemaElevenUpgradeDoesNotGuessAgentAndIsIdempotent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-binding-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite3")
        let conversation = Conversation(title: "Agent name is not identity", updatedAt: Date(timeIntervalSince1970: 1000))
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([conversation])
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close_v2(database) }
        try #require(sqlite3_exec(database, "ALTER TABLE conversations DROP COLUMN agent_binding_json; ALTER TABLE messages DROP COLUMN agent_message_source_json; ALTER TABLE messages DROP COLUMN image_gallery_layout_json; ALTER TABLE messages DROP COLUMN remote_images_json; ALTER TABLE messages DROP COLUMN remote_attachment_json; ALTER TABLE messages DROP COLUMN external_channel_source_json; UPDATE schema_version SET version=11", nil, nil, nil) == SQLITE_OK)
        for _ in 0..<2 {
            let upgraded = try ConversationRepository(databaseURL: url)
            let values = try await upgraded.load()
            let version = try await upgraded.schemaVersion()
            expectNoDifference(values, [conversation])
            expectNoDifference(version, ConversationRepository.currentSchemaVersion)
        }
    }
}
