import CSQLite
import CustomDump
import FiliconDomain
import FiliconPersistence
import FiliconAppServices
import Foundation
import Testing

@Suite("Direct agent binding persistence")
struct DirectAgentBindingPersistenceTests {
    private let agentID = UUID(uuidString: "10000000-0000-0000-0000-000000000042")!

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
        try #require(sqlite3_exec(database, "ALTER TABLE conversations DROP COLUMN agent_binding_json; ALTER TABLE messages DROP COLUMN agent_message_source_json; ALTER TABLE messages DROP COLUMN remote_images_json; ALTER TABLE messages DROP COLUMN remote_attachment_json; UPDATE schema_version SET version=11", nil, nil, nil) == SQLITE_OK)
        for _ in 0..<2 {
            let upgraded = try ConversationRepository(databaseURL: url)
            let values = try await upgraded.load()
            let version = try await upgraded.schemaVersion()
            expectNoDifference(values, [conversation])
            expectNoDifference(version, ConversationRepository.currentSchemaVersion)
        }
    }
}
