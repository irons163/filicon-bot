import CSQLite
import CustomDump
import FiliconDomain
import FiliconPersistence
import FiliconAppServices
import Foundation
import Testing

@Suite("Peer message attribution persistence")
struct AgentMessageSourcePersistenceTests {
    private func source(_ kind: AgentMessageSource.Kind = .incoming) throws -> AgentMessageSource {
        try .init(accountID: "fixture-account", originConversationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                  deliveryID: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                  senderAgentID: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                  recipientAgentID: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!, kind: kind)
    }
    private func sql(_ url: URL, _ query: String) throws {
        var database: OpaquePointer?
        try #require(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close_v2(database) }
        try #require(sqlite3_exec(database, query, nil, nil, nil) == SQLITE_OK)
    }

    @Test(arguments: [AgentMessageSource.Kind.incoming, .publication])
    func jsonRetainsAttribution(kind: AgentMessageSource.Kind) throws {
        let provenance = try source(kind)
        let original = ChatMessage(role: .assistant, text: "Peer text", createdAt: Date(timeIntervalSince1970: 1000), agentMessageSource: provenance)
        let data = try JSONEncoder().encode(original)
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: data), original)
        expectNoDifference(provenance.authorAgentID, kind == .incoming ? provenance.senderAgentID : provenance.recipientAgentID)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "agentMessageSource")
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object)).agentMessageSource, nil)
    }

    @Test(arguments: ["empty-account", "self-send", "unknown-kind", "missing-delivery", "user-role"])
    func invalidJSONNeverBecomesUnattributedText(fault: String) throws {
        let message = ChatMessage(role: .assistant, text: "Not a human instruction", agentMessageSource: try source())
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        var metadata = try #require(object["agentMessageSource"] as? [String: Any])
        switch fault {
        case "empty-account": metadata["accountID"] = "  "
        case "self-send": metadata["recipientAgentID"] = metadata["senderAgentID"]
        case "unknown-kind": metadata["kind"] = "human"
        case "missing-delivery": metadata.removeValue(forKey: "deliveryID")
        default: object["role"] = "user"
        }
        object["agentMessageSource"] = metadata
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ChatMessage.self, from: data) }
    }

    @Test func sqlitePagingAndReopenRetainSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite3")
        let provenance = try source()
        let conversation = Conversation(messages: (0..<31).map {
            ChatMessage(role: .assistant, text: "Peer \($0)", createdAt: Date(timeIntervalSince1970: Double(1000 + $0)), agentMessageSource: provenance)
        }, updatedAt: Date(timeIntervalSince1970: 2000))
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([conversation])
        let reopened = try ConversationRepository(databaseURL: url)
        let loaded = try await reopened.load()
        expectNoDifference(loaded, [conversation])
        var messages: [ChatMessage] = []
        var cursor: MessageCursor?
        repeat {
            let page = try await reopened.messagePage(conversationID: conversation.id, request: .init(before: cursor, limit: 7))
            messages.insert(contentsOf: page.items, at: 0)
            cursor = page.nextCursor
        } while cursor != nil
        expectNoDifference(messages, conversation.messages)
    }

    @Test func schemaTwelveUpgradeDoesNotInventSource() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-source-upgrade-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite3")
        let conversation = Conversation(messages: [.init(role: .assistant, text: "Old text", createdAt: Date(timeIntervalSince1970: 1000))], updatedAt: Date(timeIntervalSince1970: 2000))
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([conversation])
        try sql(url, "ALTER TABLE messages DROP COLUMN agent_message_source_json; UPDATE schema_version SET version=12")
        for _ in 0..<2 {
            let upgraded = try ConversationRepository(databaseURL: url)
            let loaded = try await upgraded.load()
            let version = try await upgraded.schemaVersion()
            expectNoDifference(loaded, [conversation])
            expectNoDifference(version, ConversationRepository.currentSchemaVersion)
        }
    }

    @Test(arguments: ["malformed-source", "wrong-role", "other-column"])
    func salvagePreservesValidSourceAndRejectsDamagedRow(fault: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-source-salvage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "chat.sqlite3")
        let good = ChatMessage(role: .assistant, text: "Valid peer", createdAt: Date(timeIntervalSince1970: 1000), agentMessageSource: try source())
        let bad = ChatMessage(role: .assistant, text: "Damaged peer", createdAt: Date(timeIntervalSince1970: 1001), agentMessageSource: try source(.publication))
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([Conversation(messages: [good, bad])])
        let change = fault == "malformed-source" ? "agent_message_source_json='{'" : fault == "wrong-role" ? "role='user'" : "attachments_json='{'"
        try sql(url, "UPDATE messages SET \(change) WHERE id='\(bad.id.uuidString)'")
        let recovered = try ConversationRepository(databaseURL: url)
        expectNoDifference(recovered.initialRecoveryReport?.kind, .salvaged)
        let loaded = try await recovered.load()
        expectNoDifference(loaded.first?.messages, [good])
        #expect(recovered.initialRecoveryReport?.rejectedRows.contains { $0.rowIdentifier == bad.id.uuidString } == true)
    }

    @Test func savingHumanRoleWithPeerSourceRollsBack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-source-save-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = try ConversationRepository(databaseURL: root.appending(path: "chat.sqlite3"))
        let original = Conversation(messages: [.init(role: .user, text: "Human", createdAt: Date(timeIntervalSince1970: 1000))], updatedAt: Date(timeIntervalSince1970: 2000))
        try await repository.save([original])
        var invalid = original
        invalid.messages[0].agentMessageSource = try source()
        await #expect(throws: PersistenceError.self) { try await repository.save([invalid]) }
        let loaded = try await repository.load()
        expectNoDifference(loaded, [original])
    }

    @Test func partialHistoryEditsRetainUnloadedPeerSources() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-source-partial-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.json")
        let source = try source()
        let original = Conversation(messages: (0..<31).map {
            ChatMessage(role: .assistant, text: "Peer \($0)", createdAt: Date(timeIntervalSince1970: Double(1000 + $0)), agentMessageSource: source)
        }, updatedAt: Date(timeIntervalSince1970: 2000))
        let store = ConversationStore(fileURL: file)
        try await store.upsert(original, replacingLoadedMessageIDs: [], historyComplete: true)
        var partial = original
        partial.messages = Array(original.messages.suffix(3))
        partial.title = "Renamed"
        try await store.upsert(partial, replacingLoadedMessageIDs: Set(partial.messages.map(\.id)), historyComplete: false)
        let reopened = ConversationStore(fileURL: file)
        let loaded = try await reopened.conversation(id: original.id)
        expectNoDifference(loaded?.messages, original.messages)
        expectNoDifference(loaded?.title, "Renamed")
    }
}
