import CSQLite
import CustomDump
import FiliconDomain
import FiliconPersistence
import Foundation
import Testing

@Suite("Direct address persistence")
struct DirectAddressPersistenceTests {
    @Test func jsonPreservesAddressesAndLegacyAbsence() throws {
        let original = ChatMessage(role: .assistant, text: "Published", createdAt: Date(timeIntervalSince1970: 1000), shortAddress: "t12s3")
        let data = try JSONEncoder().encode(original)
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: data), original)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "shortAddress")
        let legacy = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        expectNoDifference(legacy.shortAddress, nil)
    }

    @Test func addressesSurvivePagingReopenAndUnrelatedEdits() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "direct-address-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "chat.sqlite3")
        var conversation = Conversation(messages: (0..<61).map {
            ChatMessage(role: .assistant, text: "Published \($0)", createdAt: Date(timeIntervalSince1970: Double(1000 + $0)), shortAddress: "t0s\($0)")
        })
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([conversation])
        conversation.messages[30].text = "Edited caption"
        try await repository.save([conversation])
        let reopened = try ConversationRepository(databaseURL: url)
        let loaded = try #require(try await reopened.load().first)
        expectNoDifference(loaded.messages, conversation.messages)
        var messages: [ChatMessage] = []
        var cursor: MessageCursor?
        repeat {
            let page = try await reopened.messagePage(conversationID: conversation.id, request: .init(before: cursor, limit: 17))
            messages.insert(contentsOf: page.items, at: 0)
            cursor = page.nextCursor
        } while cursor != nil
        expectNoDifference(messages, conversation.messages)
    }

    @Test func versionNineMigrationDoesNotInventAddresses() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "direct-address-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "chat.sqlite3")
        let original = Conversation(messages: [.init(role: .user, text: "Legacy", createdAt: Date(timeIntervalSince1970: 1000))])
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([original])
        var database: OpaquePointer?
        let opened = sqlite3_open(url.path, &database)
        defer { sqlite3_close_v2(database) }
        try #require(opened == SQLITE_OK)
        let changed = sqlite3_exec(database, "ALTER TABLE messages DROP COLUMN short_address; UPDATE schema_version SET version=9", nil, nil, nil)
        try #require(changed == SQLITE_OK)
        let migrated = try ConversationRepository(databaseURL: url)
        let version = try await migrated.schemaVersion()
        let migratedValues = try await migrated.load()
        expectNoDifference(version, 10)
        expectNoDifference(migratedValues.first?.messages, original.messages)
        let again = try ConversationRepository(databaseURL: url)
        let reopenedValues = try await again.load()
        expectNoDifference(reopenedValues.first?.messages, original.messages)
    }
}
