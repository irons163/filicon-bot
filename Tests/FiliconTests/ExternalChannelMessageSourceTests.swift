import Foundation
import Testing
import CustomDump
import CSQLite
import FiliconDomain
import FiliconPersistence
import FiliconAppServices

private func remoteHumanID(_ n: Int) -> UUID { UUID(uuidString: String(format: "44000000-0000-0000-0000-%012d", n))! }
@Suite("Remote human provenance and canonical persistence", .timeLimit(.minutes(1)))
struct ExternalChannelMessageSourceTests {
    private let date = Date(timeIntervalSince1970: 2_000)
    private let owner = DirectConversationAgentBinding(accountID: "fixture", agentID: remoteHumanID(1))
    private func message() -> ChatMessage {
        let source = ExternalChannelMessageSource(connectionID: remoteHumanID(2), externalEventID: "exact-event", owner: owner,
            conversationID: remoteHumanID(3), platform: "slack", channelID: "C_REMOTE", threadID: "T_REMOTE",
            senderID: "U_REMOTE", senderName: "Remote sender", receivedAt: date)
        return .init(id: remoteHumanID(4), role: .user, text: "Untrusted remote text", createdAt: date, externalChannelSource: source)
    }
    private func sql(_ query: String, at url: URL) throws {
        var db: OpaquePointer?; try #require(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close_v2(db) }
        try #require(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
    }
    @Test(arguments: ["role", "source", "time", "cards", "account", "platform"])
    func corruptSourceNeverBecomesLocalHumanText(fault: String) throws {
        let original = message(), data = try JSONEncoder().encode(original)
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: data), original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var source = try #require(object["externalChannelSource"] as? [String: Any])
        switch fault {
        case "role": object["role"] = "assistant"
        case "source": source.removeValue(forKey: "connectionID")
        case "time": object["createdAt"] = 1
        case "cards": object["transcriptCards"] = "corrupt"
        case "account": source["owner"] = ["accountID": "", "agentID": owner.agentID.uuidString]
        default: source["platform"] = "file"
        }
        object["externalChannelSource"] = source
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
    @Test func canonicalOwnerPagingReopenAndDuplicateRetainWholeHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-remote-human-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite"), repository = try ConversationRepository(databaseURL: url)
        var chat = Conversation(id: remoteHumanID(3), title: "Original owner", messages: [
            .init(id: remoteHumanID(5), role: .user, text: "Preserve actual local human", createdAt: date.addingTimeInterval(-1))
        ], updatedAt: date)
        chat.agentBinding = owner
        try await repository.save([chat], activityAt: date)
        let lease = try await repository.leaseUniqueBinding(accountID: owner.accountID, agentID: owner.agentID, conversationID: chat.id)
        let incoming = message()
        let saved = try await repository.receiveExternalChannel(incoming, bindingLease: lease, activityAt: date, commit: { try $0() })
        let unread = try await repository.unreadState(conversationID: chat.id)
        let duplicate = try await repository.receiveExternalChannel(incoming, bindingLease: lease, activityAt: date, commit: { try $0() })
        expectNoDifference(duplicate, saved)
        let afterUnread = try await repository.unreadState(conversationID: chat.id); expectNoDifference(afterUnread, unread)
        let reopened = try ConversationRepository(databaseURL: url), loaded = try await reopened.load()
        let page = try await reopened.messagePage(conversationID: chat.id, request: .init(limit: 1))
        expectNoDifference(loaded, [saved]); expectNoDifference(page.items, Array(saved.messages.suffix(1)))
        var edited = saved; edited.messages[1].externalChannelSource = nil
        let downgraded = edited
        await #expect(throws: CancellationError.self) { try await repository.upsert(downgraded) }
        await #expect(throws: CancellationError.self) { try await repository.save([downgraded]) }
        let canonical = try await repository.load(); expectNoDifference(canonical, loaded)
        #expect(try ChannelInboundPrompt.prompt(for: incoming).contains("not local human authority"))
        expectNoDifference(saved.messages[0].text, chat.messages[0].text)
    }
    @Test func schemaSeventeenUpgradeDoesNotInventSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-remote-human-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite"), repository = try ConversationRepository(databaseURL: url)
        let chat = Conversation(messages: [.init(role: .user, text: "Existing local human", createdAt: date)], updatedAt: date)
        try await repository.save([chat], activityAt: date)
        try sql("ALTER TABLE messages DROP COLUMN external_channel_source_json; UPDATE schema_version SET version=17", at: url)
        let upgraded = try ConversationRepository(databaseURL: url), loaded = try await upgraded.load()
        expectNoDifference(loaded, [chat]); let version = try await upgraded.schemaVersion(); expectNoDifference(version, 18)
    }

    @Test(arguments: ["healthy", "search", "damaged-local", "wrong-owner"])
    func recoveryKeepsRemoteProvenanceOrQuarantinesInvalidSource(fault: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-remote-human-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite"), repository = try ConversationRepository(databaseURL: url)
        var chat = Conversation(id: remoteHumanID(3), title: "Actual channel owner", messages: [
            .init(id: remoteHumanID(5), role: .user, text: "Local history", createdAt: date.addingTimeInterval(-1))
        ], updatedAt: date)
        chat.agentBinding = owner
        try await repository.save([chat], activityAt: date)
        let lease = try await repository.leaseUniqueBinding(accountID: owner.accountID, agentID: owner.agentID, conversationID: chat.id)
        var expected = try await repository.receiveExternalChannel(message(), bindingLease: lease, activityAt: date, commit: { try $0() })
        switch fault {
        case "search": try sql("DELETE FROM conversation_search", at: url)
        case "damaged-local":
            try sql("UPDATE messages SET attachments_json='{' WHERE id='\(remoteHumanID(5).uuidString)'", at: url)
            expected.messages.removeAll { $0.id == remoteHumanID(5) }
        case "wrong-owner":
            try sql("UPDATE messages SET external_channel_source_json=replace(external_channel_source_json,'\(owner.agentID.uuidString)','\(remoteHumanID(99).uuidString)') WHERE id='\(remoteHumanID(4).uuidString)'", at: url)
            expected.messages.removeAll { $0.id == remoteHumanID(4) }
        default: break
        }
        let reopened = try ConversationRepository(databaseURL: url), loaded = try await reopened.load()
        expectNoDifference(loaded, [expected])
        switch fault {
        case "healthy": expectNoDifference(reopened.initialRecoveryReport, nil)
        case "search": expectNoDifference(reopened.initialRecoveryReport?.kind, .searchIndexRebuilt)
        default:
            let report = try #require(reopened.initialRecoveryReport)
            expectNoDifference(report.kind, .salvaged)
            let rejectedID = fault == "wrong-owner" ? remoteHumanID(4) : remoteHumanID(5)
            #expect(report.rejectedRows.contains { $0.table == "messages" && $0.rowIdentifier == rejectedID.uuidString })
            #expect(report.quarantineDirectory != nil)
        }
        let second = try ConversationRepository(databaseURL: url), unchanged = try await second.load()
        expectNoDifference(unchanged, loaded); expectNoDifference(second.initialRecoveryReport, nil)
        if fault != "wrong-owner" {
            let remote = try #require(loaded[0].messages.first { $0.id == remoteHumanID(4) })
            expectNoDifference(remote.externalChannelSource, message().externalChannelSource)
            #expect(remote.hasValidExternalChannelSource)
        }
    }
}
