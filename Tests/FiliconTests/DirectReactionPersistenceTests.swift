import CSQLite
import CustomDump
import FiliconDomain
import FiliconPersistence
import FiliconAppServices
import Foundation
import Testing

private func directReactionID(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, value))
}

@Suite("Canonical direct model reaction foundation", .timeLimit(.minutes(1)))
struct DirectReactionPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let binding = DirectConversationAgentBinding(accountID: "fixture", agentID: directReactionID(1))

    private func chat() -> Conversation {
        var value = Conversation(id: directReactionID(2), title: "Actual bound chat", providerID: "fixture", modelID: "test",
            messages: [.init(id: directReactionID(3), role: .user, text: "Canonical human input", createdAt: now,
                reactions: [.init(emoji: "❤️", actorID: "local-user")]),
                .init(id: directReactionID(4), role: .assistant, text: "Existing answer", createdAt: now.addingTimeInterval(1))], updatedAt: now)
        value.agentBinding = binding
        DirectMessageAddressing.assignMissing(in: &value)
        return value
    }

    private func foreign() -> Conversation {
        var value = Conversation(id: directReactionID(5), title: "Unrelated private chat", messages: [
            .init(id: directReactionID(6), role: .user, text: "PRIVATE_FOREIGN", createdAt: now)], updatedAt: now.addingTimeInterval(2))
        value.agentBinding = .init(accountID: "other", agentID: directReactionID(7))
        DirectMessageAddressing.assignMissing(in: &value)
        return value
    }

    @Test func actualToolReceiptReplayDoesNotToggleDurableReactionTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reaction-tool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        try await repository.save([chat(), foreign()], activityAt: now)
        let before = try await repository.load()
        let original = try #require(before.first { $0.id == chat().id }), target = original.messages[0]
        let address = try #require(target.shortAddress)
        let lease = try await repository.leaseUniqueBinding(accountID: binding.accountID,
            agentID: binding.agentID, conversationID: original.id)
        defer { lease.close() }
        let context = ToolContext(conversationID: original.id, runID: directReactionID(9))
        let tool = AgentMessageReactionTool(context: context,
            directory: DirectReactionDirectory(conversation: original, historyComplete: true), validate: {
                try lease.withValidBinding {}
            }, react: { id, emoji in
                guard id == target.id else { throw CancellationError() }
                return try await repository.toggleModelReaction(expectedMessage: target, emoji: emoji,
                    bindingLease: lease, commit: { try $0() }).applied
            })
        let firstCall = try NormalizedToolCall(id: "native-tap", name: "ReactToMessage",
            argumentsJSON: try JSONEncoder().encode(["message_address": address, "emoji": "👍"]))
        let first = try await tool.execute(firstCall, context: context)
        let repeated = try await tool.execute(firstCall, context: context)
        expectNoDifference(repeated, first)
        expectNoDifference(first, .init(callID: "native-tap", content: [.text("Added 👍 on \(address).")]))
        var expected = before
        let index = try #require(expected.firstIndex { $0.id == original.id })
        expected[index].messages[0].reactions.append(.init(emoji: "👍", actorID: "agent:\(binding.agentID.uuidString)"))
        let after = try await repository.load()
        expectNoDifference(after, expected)
        lease.close()
        await #expect(throws: CancellationError.self) { try await tool.execute(firstCall, context: context) }
        let revoked = try await repository.load()
        expectNoDifference(revoked, expected)
    }

    @Test(arguments: ["valid", "partial", "assistant", "tool", "wrong-role-address", "duplicate-id",
        "duplicate-address", "reservation-mismatch", "deleted-reservation", "host-card", "tool-activity", "reasoning", "queued", "empty"])
    func onlyFullCanonicalUniqueHumanAddressesEnterTheDirectory(boundary: String) throws {
        var value = chat()
        let original = value
        switch boundary {
        case "assistant": value.messages[0].role = .assistant
        case "tool": value.messages[0].role = .tool
        case "wrong-role-address": value.messages[0].shortAddress = "t0s1"
        case "duplicate-id": value.messages.append(value.messages[0])
        case "duplicate-address": value.messages[1].shortAddress = value.messages[0].shortAddress
        case "reservation-mismatch": value.messageAddressReservations[value.messages[0].id.uuidString] = "t7u"
        case "deleted-reservation": value.messageAddressReservations[directReactionID(8).uuidString] = value.messages[0].shortAddress
        case "host-card": value.messages[0].transcriptCards = [.init(lifecycle: .waiting, payload: .autoReview(.init(reviewID: "host", title: "Host activity")))]
        case "tool-activity": value.messages[0].toolActivities = [.init(id: "host", name: "tool")]
        case "reasoning": value.messages[0].reasoningText = "PRIVATE_REASONING"
        case "queued": value.messages[0].deliveryStatus = .queued
        case "empty": value.messages[0].text = " "
        default: break
        }
        let before = value
        let directory = DirectReactionDirectory(conversation: value, historyComplete: boundary != "partial")
        if boundary == "valid" {
            struct Entry: Decodable, Equatable { let message_address: String; let sender: String; let excerpt: String }
            let data = try JSONEncoder().encode(directory.entries)
            expectNoDifference(try JSONDecoder().decode([Entry].self, from: data), [
                Entry(message_address: "t0u", sender: "user", excerpt: original.messages[0].text)])
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            expectNoDifference(Set(try #require(object.first).keys), ["message_address", "sender", "excerpt"])
            expectNoDifference(directory.messageID(for: "t0u", in: value.id), value.messages[0].id)
            expectNoDifference(directory.messageID(for: "t0u", in: foreign().id), nil)
            expectNoDifference(directory.messageID(for: value.messages[0].id.uuidString, in: value.id), nil)
            expectNoDifference(directory.messageID(for: "t0s0", in: value.id), nil)
        } else { expectNoDifference(directory.entries, []) }
        expectNoDifference(value, before)
    }

    @Test(arguments: [false, true])
    func collisionsAndDeletedAliasesOutsideFortyRowsStillRejectTheRecentTarget(reservation: Bool) {
        var value = chat()
        let target = value.messages[0]
        value.messages = (20..<65).map {
            .init(id: directReactionID(UInt8($0)), role: .user, text: "Old human \($0)", createdAt: now)
        } + [target]
        DirectMessageAddressing.assignMissing(in: &value)
        if reservation { value.messageAddressReservations[directReactionID(9).uuidString] = target.shortAddress }
        else { value.messages[0].shortAddress = target.shortAddress }
        let before = value
        let directory = DirectReactionDirectory(conversation: value, historyComplete: true)
        expectNoDifference(directory.messageID(for: "t0u", in: value.id), nil)
        #expect(!directory.contains(value.messages[0].id))
        expectNoDifference(value, before)
    }

    @Test(arguments: ["👍", "❤️", "👍🏽", "👨‍👩‍👧‍👦", "🇹🇼", "1️⃣"])
    func nativeMutationTogglesOnlyTheActualBoundActorAndPreservesAllOtherDurableFields(emoji: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reaction-native-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.sqlite3")
        let repository = try ConversationRepository(databaseURL: file)
        try await repository.save([chat(), foreign()], activityAt: now)
        let before = try await repository.load(), readBefore = try await repository.unreadState(conversationID: chat().id)
        let searchBefore = try await repository.searchMessages("human")
        let lease = try await repository.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: chat().id)
        defer { lease.close() }
        let original = try #require(before.first { $0.id == chat().id })
        let target = original.messages[0]
        let result = try await repository.toggleModelReaction(expectedMessage: target, emoji: emoji, bindingLease: lease, commit: { try $0() })
        var updated = target
        updated.reactions.append(.init(emoji: emoji, actorID: "agent:\(binding.agentID.uuidString)"))
        expectNoDifference(result, .init(message: updated, applied: true))
        var expected = before
        let index = try #require(expected.firstIndex { $0.id == original.id })
        expected[index].messages[0] = updated
        let after = try await repository.load(), readAfter = try await repository.unreadState(conversationID: original.id)
        let searchAfter = try await repository.searchMessages("human")
        expectNoDifference(after, expected); expectNoDifference(readAfter, readBefore); expectNoDifference(searchAfter, searchBefore)
        let reopened = try ConversationRepository(databaseURL: file), restored = try await reopened.load()
        expectNoDifference(restored, expected)
        let removed = try await repository.toggleModelReaction(expectedMessage: target, emoji: emoji, bindingLease: lease, commit: { try $0() })
        expectNoDifference(removed, .init(message: target, applied: false))
        let takenBack = try await repository.load()
        expectNoDifference(takenBack, before)
    }

    @Test(arguments: ["closed", "synthetic-lease", "rebound-restored", "hidden-restored", "duplicate-owner", "deleted",
        "foreign-target", "assistant-target", "changed-target", "message-deleted", "aged-out", "reservation-changed",
        "duplicate-address", "close-at-commit", "deny-at-commit", "no-commit", "sql-failure"])
    func revokedOwnerWrongTargetAndFailedSQLHaveNoSuccessReceiptOrMutation(boundary: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reaction-fence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.sqlite3"), repository = try ConversationRepository(databaseURL: file)
        let original = chat(), other = foreign()
        try await repository.save([original, other], activityAt: now)
        let nativeLease = try await repository.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: original.id)
        defer { nativeLease.close() }
        let lease = boundary == "synthetic-lease" ? ConversationBindingLease(conversationID: original.id, binding: binding) : nativeLease
        defer { lease.close() }
        var target = original.messages[0]
        switch boundary {
        case "closed": lease.close()
        case "rebound-restored", "hidden-restored":
            var changed = original
            if boundary == "rebound-restored" { changed.agentBinding = nil } else { changed.hiddenAt = now }
            try await repository.save([changed, other], activityAt: now)
            try await repository.save([original, other], activityAt: now)
        case "duplicate-owner":
            var duplicate = Conversation(id: directReactionID(8), updatedAt: now); duplicate.agentBinding = binding
            try await repository.save([original, other, duplicate], activityAt: now)
        case "deleted": try await repository.delete(id: original.id)
        case "foreign-target": target = other.messages[0]
        case "assistant-target": target = original.messages[1]
        case "changed-target":
            var changed = original; changed.messages[0].text = "Changed canonical human"
            try await repository.save([changed, other], activityAt: now)
        case "message-deleted", "aged-out", "reservation-changed", "duplicate-address":
            var changed = original
            switch boundary {
            case "message-deleted": changed.messages.removeFirst()
            case "aged-out":
                changed.messages += (20..<61).map {
                    .init(id: directReactionID(UInt8($0)), role: .user, text: "Later human \($0)",
                        createdAt: now.addingTimeInterval(Double($0)))
                }
                DirectMessageAddressing.assignMissing(in: &changed)
            case "reservation-changed": changed.messageAddressReservations[target.id.uuidString] = "t7u"
            default: changed.messages[1].shortAddress = target.shortAddress
            }
            try await repository.save([changed, other], activityAt: now)
        case "sql-failure":
            var handle: OpaquePointer?
            try #require(sqlite3_open(file.path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            try #require(sqlite3_exec(handle, "CREATE TRIGGER reject_reaction BEFORE UPDATE OF reactions_json ON messages BEGIN SELECT RAISE(ABORT,'owned reaction failure'); END", nil, nil, nil) == SQLITE_OK)
        default: break
        }
        let before = try await repository.load(), readBefore = try await repository.unreadState(conversationID: original.id)
        let commit: ConversationCommitGuard = { operation in
            if boundary == "close-at-commit" { lease.close() }
            if boundary == "deny-at-commit" { throw CancellationError() }
            if boundary != "no-commit" { try operation() }
        }
        if boundary == "sql-failure" {
            await #expect(throws: PersistenceError.self) { _ = try await repository.toggleModelReaction(expectedMessage: target, emoji: "👍", bindingLease: lease, commit: commit) }
        } else {
            await #expect(throws: CancellationError.self) { _ = try await repository.toggleModelReaction(expectedMessage: target, emoji: "👍", bindingLease: lease, commit: commit) }
        }
        let after = try await repository.load(), readAfter = try await repository.unreadState(conversationID: original.id)
        expectNoDifference(after, before); expectNoDifference(readAfter, readBefore)
    }

    @Test(arguments: ["", " ", "hello", "1", "👍👍", String(repeating: "👍", count: 9)])
    func invalidEmojiNeverWrites(emoji: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reaction-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        let original = chat()
        try await repository.save([original], activityAt: now)
        let before = try await repository.load()
        let lease = try await repository.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: original.id)
        defer { lease.close() }
        await #expect(throws: CancellationError.self) {
            _ = try await repository.toggleModelReaction(expectedMessage: original.messages[0], emoji: emoji, bindingLease: lease, commit: { try $0() })
        }
        let after = try await repository.load()
        expectNoDifference(after, before)
    }

    @Test(arguments: [false, true], ["added", "removed", "human-add", "human-remove", "forged", "rebound"])
    func staleFullAndPagedSavesCannotEraseResurrectOrForgeNativeModelReactions(historyComplete: Bool, mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reaction-stale-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let original = chat(), other = foreign()
        try await store.save([original, other], activityAt: now)
        let lease = try await store.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: original.id)
        defer { lease.close() }
        let added = try await store.toggleModelReaction(expectedMessage: original.messages[0], emoji: "👍", bindingLease: lease, commit: { try $0() })
        let nativeReaction = try #require(added.message.reactions.last)
        var stale = original
        switch mode {
        case "removed":
            stale.messages[0] = added.message
            _ = try await store.toggleModelReaction(expectedMessage: original.messages[0], emoji: "👍", bindingLease: lease, commit: { try $0() })
        case "human-add": stale.messages[0].reactions.append(.init(emoji: "🔥", actorID: "local-user"))
        case "human-remove": stale.messages[0].reactions = []
        case "forged":
            stale.messages[0].reactions += [nativeReaction, nativeReaction,
                .init(emoji: "😈", actorID: "agent:\(binding.agentID.uuidString)"),
                .init(emoji: "🎉", actorID: "agent:\(directReactionID(8).uuidString)")]
        case "rebound":
            var changed = try #require(try await store.conversation(id: original.id))
            changed.agentBinding = .init(accountID: binding.accountID, agentID: directReactionID(8))
            try await store.upsert(changed, replacingLoadedMessageIDs: Set(changed.messages.map(\.id)), historyComplete: true, activityAt: now)
            stale.agentBinding = changed.agentBinding
        default: break
        }
        var expected = try await store.load()
        let index = try #require(expected.firstIndex { $0.id == original.id })
        let readBefore = try await store.unreadState(conversationID: original.id)
        if mode == "human-add" { expected[index].messages[0].reactions.insert(.init(emoji: "🔥", actorID: "local-user"), at: 1) }
        if mode == "human-remove" { expected[index].messages[0].reactions.removeAll { $0.actorID == "local-user" } }
        if !historyComplete { stale.messages = [stale.messages[0]] }
        try await store.upsert(stale, replacingLoadedMessageIDs: Set(stale.messages.map(\.id)), historyComplete: historyComplete, activityAt: now)
        let saved = try await store.load(), readAfter = try await store.unreadState(conversationID: original.id)
        expectNoDifference(saved, expected); expectNoDifference(readAfter, readBefore)
        let subscription = try await store.subscribeTranscript(conversationID: original.id)
        expectNoDifference(subscription.snapshot.messages, expected[index].messages)
        let reopened = ConversationStore(fileURL: root.appending(path: "conversations.json")), restored = try await reopened.load()
        expectNoDifference(restored, expected)
    }

    @Test(arguments: [false, true])
    func storeReturnsDurableReceiptBeforeAnyReplicaReadAndReconcilesOnCanonicalReload(blockReplica: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reaction-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let original = chat(), other = foreign()
        try await store.save([original, other], activityAt: now)
        let before = try await store.load()
        let lease = try await store.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: original.id)
        defer { lease.close() }
        let replicas = root.appending(path: "conversation-replicas"), moved = root.appending(path: "owned-replicas-backup")
        if blockReplica {
            try FileManager.default.moveItem(at: replicas, to: moved)
            try Data("Owned replica failure fixture".utf8).write(to: replicas)
            let unreadable = ConversationStore(fileURL: root.appending(path: "conversations.json"))
            await #expect(throws: TranscriptHubError.self) { _ = try await unreadable.load() }
        }
        let result = try await store.toggleModelReaction(expectedMessage: original.messages[0], emoji: "👍", bindingLease: lease, commit: { try $0() })
        var expected = before
        let index = try #require(expected.firstIndex { $0.id == original.id })
        expected[index].messages[0] = result.message
        let canonical = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3")), durable = try await canonical.load()
        expectNoDifference(durable, expected)
        if blockReplica {
            try FileManager.default.removeItem(at: replicas)
            try FileManager.default.moveItem(at: moved, to: replicas)
        }
        let reopened = ConversationStore(fileURL: root.appending(path: "conversations.json")), saved = try await reopened.load()
        expectNoDifference(result.applied, true); expectNoDifference(saved, expected)
        let subscription = try await reopened.subscribeTranscript(conversationID: original.id)
        expectNoDifference(subscription.snapshot.messages, expected[index].messages)
    }
}
