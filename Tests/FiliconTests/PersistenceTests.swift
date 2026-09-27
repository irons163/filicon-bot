import Foundation
import Testing
import FiliconDomain
import FiliconPersistence
import FiliconAppServices
import CSQLite
import CustomDump

@Test func remoteAttachmentSQLiteMigrationAndPaging() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "remote.sqlite3")
    let reference = try RemoteAttachmentReference(url: "https://example.com/report?sig=a%2Bb", alt: "報表")
    var conversation = Conversation(messages: [.init(role: .assistant, text: "", remoteAttachment: reference)])
    let repository = try ConversationRepository(databaseURL: url)
    try await repository.save([conversation])
    let reopened = try ConversationRepository(databaseURL: url)
    let loaded = try await reopened.load()
    expectNoDifference(loaded.first?.messages.first?.remoteAttachment, reference)
    let page = try await reopened.messagePage(conversationID: conversation.id)
    expectNoDifference(page.items.first?.remoteAttachment, reference)
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    defer { sqlite3_close(database) }
    #expect(sqlite3_exec(database, "ALTER TABLE messages DROP COLUMN remote_attachment_json; UPDATE schema_version SET version=13", nil, nil, nil) == SQLITE_OK)
    let migrated = try ConversationRepository(databaseURL: url)
    let legacy = try await migrated.load()
    expectNoDifference(legacy.first?.messages.first?.remoteAttachment, nil)
    conversation.messages[0].remoteAttachment = reference
    try await migrated.save([conversation])
    let restored = try await migrated.load()
    expectNoDifference(restored.first?.messages.first?.remoteAttachment, reference)
    #expect(sqlite3_exec(database, "UPDATE messages SET remote_attachment_json='{\"url\":\"file:///private/report\"}'", nil, nil, nil) == SQLITE_OK)
    await #expect(throws: PersistenceError.self) { try await migrated.load() }
}

private func persistenceTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func sqliteRoundTripAndSchemaMigrationAreIdempotent() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let attachment = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "design.pdf", mimeType: "application/pdf", byteCount: 42, kind: .document)
    let conversation = Conversation(title: "Architecture", providerID: "openai", modelID: "gpt-test", reasoningEffort: .high, messages: [.init(role: .user, text: "hello", attachments: [attachment]), .init(role: .assistant, text: "world")])
    let first = try ConversationRepository(databaseURL: url)
    try await first.save([conversation])
    #expect(try await first.schemaVersion() == ConversationRepository.currentSchemaVersion)
    let second = try ConversationRepository(databaseURL: url)
    #expect(try await second.schemaVersion() == ConversationRepository.currentSchemaVersion)
    let loaded = try await second.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].id == conversation.id)
    #expect(loaded[0].messages.map(\.text) == ["hello", "world"])
    #expect(loaded[0].messages[0].attachments == [attachment])
    #expect(loaded[0].reasoningEffort == .high)
}

@Test func hiddenChatsRoundTripAndVersionThreeMigratesWithoutHidingExistingChats() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let roundTripURL = directory.appending(path: "hidden-round-trip.sqlite3")
    let hiddenAt = Date(timeIntervalSince1970: 1_725_000_000)
    let visible = Conversation(title: "Visible")
    let hidden = Conversation(title: "Hidden", hiddenAt: hiddenAt)
    let repository = try ConversationRepository(databaseURL: roundTripURL)
    try await repository.save([visible, hidden])
    let loaded = try await repository.load()
    #expect(loaded.first(where: { $0.id == visible.id })?.hiddenAt == nil)
    #expect(loaded.first(where: { $0.id == hidden.id })?.hiddenAt == hiddenAt)

    let legacyURL = directory.appending(path: "version-three.sqlite3")
    var database: OpaquePointer?
    #expect(sqlite3_open(legacyURL.path, &database) == SQLITE_OK)
    defer { if let database { sqlite3_close_v2(database) } }
    let versionThreeSchema = """
    PRAGMA foreign_keys = ON;
    CREATE TABLE schema_version(singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL);
    INSERT INTO schema_version(singleton,version) VALUES(1,3);
    CREATE TABLE conversations(id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, provider_id TEXT NOT NULL, model_id TEXT NOT NULL, updated_at REAL NOT NULL) STRICT;
    CREATE TABLE messages(id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('system','user','assistant','tool')), text TEXT NOT NULL, created_at REAL NOT NULL, attachments_json TEXT NOT NULL DEFAULT '[]', delivery_status TEXT NOT NULL DEFAULT 'succeeded' CHECK(delivery_status IN ('queued','streaming','succeeded','failed','cancelled')), delivery_error TEXT, reasoning_text TEXT NOT NULL DEFAULT '', tool_activities_json TEXT NOT NULL DEFAULT '[]', reply_to_message_id TEXT, reactions_json TEXT NOT NULL DEFAULT '[]', UNIQUE(conversation_id,ordinal)) STRICT;
    CREATE VIRTUAL TABLE conversation_search USING fts5(conversation_id UNINDEXED, content, tokenize='unicode61');
    INSERT INTO conversations(id,title,provider_id,model_id,updated_at) VALUES('00000000-0000-0000-0000-000000000001','Legacy visible','fake','fake-stream',1000);
    INSERT INTO messages(id,conversation_id,ordinal,role,text,created_at,attachments_json,delivery_status,delivery_error,reasoning_text,tool_activities_json,reply_to_message_id,reactions_json) VALUES('00000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000001',7,'user','Legacy message',1000,'[]','succeeded',NULL,'','[]',NULL,'[]');
    INSERT INTO conversation_search(conversation_id,content) VALUES('00000000-0000-0000-0000-000000000001','Legacy visible');
    """
    var errorMessage: UnsafeMutablePointer<CChar>?
    let schemaResult = sqlite3_exec(database, versionThreeSchema, nil, nil, &errorMessage)
    let schemaError = errorMessage.map { String(cString: $0) }
    sqlite3_free(errorMessage)
    #expect(schemaResult == SQLITE_OK, Comment(rawValue: schemaError ?? "Failed to create version 3 fixture"))
    if let database { sqlite3_close_v2(database) }
    database = nil

    let migrated = try ConversationRepository(databaseURL: legacyURL)
    #expect(try await migrated.schemaVersion() == ConversationRepository.currentSchemaVersion)
    let migratedValues = try await migrated.load()
    #expect(migratedValues.count == 1)
    #expect(migratedValues[0].title == "Legacy visible")
    #expect(migratedValues[0].hiddenAt == nil)
    #expect(migratedValues[0].messages.map(\.text) == ["Legacy message"])

    var migratedValue = migratedValues[0]
    migratedValue.messages.append(.init(role: .assistant, text: "After migration"))
    try await migrated.save([migratedValue])
    let newest = try await migrated.messagePage(conversationID: migratedValue.id, request: .init(limit: 1))
    #expect(newest.items.map(\.text) == ["After migration"])
    #expect(newest.nextCursor?.ordinal == 8)
}

@Test func fullTextSearchFindsTitlesAndMessages() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let alpha = Conversation(title: "Swift architecture", messages: [.init(role: .user, text: "actor isolation")])
    let beta = Conversation(title: "Dinner", messages: [.init(role: .user, text: "noodles")])
    try await repository.save([alpha, beta])
    #expect(try await repository.search("architect").map(\.id) == [alpha.id])
    #expect(try await repository.search("isolation").map(\.id) == [alpha.id])
    #expect(try await repository.search("missing").isEmpty)
}

@Test func repositoryCRUDMaintainsMessageOwnership() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    var value = Conversation(title: "Draft", messages: [.init(role: .user, text: "first")])
    try await repository.upsert(value)
    #expect(try await repository.conversation(id: value.id)?.messages.count == 1)
    value.title = "Updated"; value.messages.append(.init(role: .assistant, text: "second"))
    try await repository.upsert(value)
    #expect(try await repository.conversation(id: value.id)?.title == "Updated")
    #expect(try await repository.conversation(id: value.id)?.messages.map(\.text) == ["first", "second"])
    try await repository.delete(id: value.id)
    #expect(try await repository.conversation(id: value.id) == nil)
}

@Test func failedSaveRollsBackWholeSnapshot() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let original = Conversation(title: "Original", messages: [.init(role: .user, text: "safe")])
    try await repository.save([original])
    let duplicateID = UUID()
    let invalid = Conversation(title: "Invalid", messages: [.init(id: duplicateID, role: .user, text: "one"), .init(id: duplicateID, role: .assistant, text: "two")])
    await #expect(throws: (any Error).self) { try await repository.save([invalid]) }
    let loaded = try await repository.load()
    #expect(loaded.map(\.id) == [original.id])
    #expect(loaded[0].messages.first?.text == "safe")
}

@Test func legacyJSONImportsOnceAndKeepsBackupAndMarker() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appending(path: "conversations.json")
    let expected = Conversation(title: "Legacy", messages: [.init(role: .user, text: "import me")])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
    try encoder.encode([expected]).write(to: legacy, options: .atomic)
    let store = ConversationStore(fileURL: legacy)
    #expect(try await store.load().map(\.id) == [expected.id])
    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: "conversations.json.migrated-backup").path))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: ".sqlite-migration-complete").path))
    #expect(try await store.load().count == 1)
}

@Test func invalidLegacyIsPreservedAndDoesNotCreateMarker() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appending(path: "conversations.json")
    let bytes = Data("not-json".utf8); try bytes.write(to: legacy)
    let store = ConversationStore(fileURL: legacy)
    await #expect(throws: PersistenceError.self) { _ = try await store.load() }
    #expect(try Data(contentsOf: legacy) == bytes)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: ".sqlite-migration-complete").path))
}

@Test func concurrentActorSavesRemainConsistent() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<20 {
            group.addTask {
                let value = Conversation(title: "Snapshot \(index)", messages: [.init(role: .user, text: "value \(index)")])
                try? await repository.save([value])
            }
        }
    }
    let loaded = try await repository.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].messages.count == 1)
}

@Test func notADatabaseIsQuarantinedWithoutLosingOriginalBytes() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let original = Data("this is not sqlite".utf8); try original.write(to: url)
    let repository = try ConversationRepository(databaseURL: url)
    #expect(try await repository.load().isEmpty)
    let report = try #require(repository.initialRecoveryReport)
    #expect(report.kind == .freshDatabase)
    let quarantine = try #require(report.quarantineDirectory).appending("/chat.sqlite3")
    #expect(try Data(contentsOf: URL(fileURLWithPath: quarantine)) == original)
}

@Test func lockedDatabaseReturnsTypedBusyError() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let repository = try ConversationRepository(databaseURL: url)
    var lock: OpaquePointer?
    #expect(sqlite3_open(url.path, &lock) == SQLITE_OK)
    defer { if let lock { sqlite3_exec(lock, "ROLLBACK", nil, nil, nil); sqlite3_close_v2(lock) } }
    #expect(sqlite3_exec(lock, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)
    do {
        try await repository.save([Conversation(title: "blocked")])
        Issue.record("Expected busy database error")
    } catch PersistenceError.busy {
        // Expected: the repository neither deletes nor recreates a locked database.
    }
}

@Test func conversationKeysetPaginationIsStableAcrossTiesMutationAndRestart() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
    func value(_ suffix: String) -> Conversation {
        Conversation(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")!,
            title: suffix,
            messages: [.init(role: .user, text: suffix)],
            updatedAt: timestamp
        )
    }
    let a = value("01"), b = value("02"), c = value("03"), d = value("04"), e = value("05")
    let repository = try ConversationRepository(databaseURL: url)
    try await repository.save([a, b, c, d, e])

    let fence = PaginationFence(rawValue: UUID(uuidString: "10000000-0000-0000-0000-000000000000")!)
    let first = try await repository.conversationPage(.init(fence: fence, limit: 2))
    #expect(first.fence == fence)
    #expect(first.items.map(\.id) == [e.id, d.id])
    #expect(first.items.allSatisfy { $0.messages.isEmpty })
    #expect(first.hasMore)
    let encodedCursor = try JSONEncoder().encode(first.nextCursor)
    let restartedCursor = try JSONDecoder().decode(ConversationCursor?.self, from: encodedCursor)

    let newer = Conversation(id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!, title: "new", updatedAt: timestamp.addingTimeInterval(10))
    // Remove an already-consumed row and insert ahead of the cursor. Neither
    // mutation can duplicate or skip a remaining row in this request chain.
    try await repository.save([a, b, c, e, newer])
    let restarted = try ConversationRepository(databaseURL: url)
    let second = try await restarted.conversationPage(.init(fence: fence, after: restartedCursor, limit: 2))
    #expect(second.items.map(\.id) == [c.id, b.id])
    #expect(second.hasMore)
    let third = try await restarted.conversationPage(.init(fence: fence, after: second.nextCursor, limit: 2))
    #expect(third.items.map(\.id) == [a.id])
    #expect(!third.hasMore)
    #expect(third.nextCursor == nil)
    #expect((first.items + second.items + third.items).map(\.id) == [e.id, d.id, c.id, b.id, a.id])
}

@Test func messageKeysetPaginationPreservesChronologyAndStableOrdinals() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let repository = try ConversationRepository(databaseURL: url)
    func message(_ index: Int) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: "10000000-0000-0000-0000-0000000000\(String(format: "%02d", index))")!,
            role: index.isMultiple(of: 2) ? .user : .assistant,
            text: "m\(index)"
        )
    }
    var conversation = Conversation(
        title: "Long history",
        messages: (0..<7).map(message)
    )
    try await repository.save([conversation])

    let fence = PaginationFence()
    let first = try await repository.messagePage(conversationID: conversation.id, request: .init(fence: fence, limit: 3))
    #expect(first.items.map(\.text) == ["m4", "m5", "m6"])
    #expect(first.hasMore)
    #expect(first.fence == fence)

    // Delete the entire consumed tail, including the cursor boundary. The
    // appended row has an ID below the old boundary ID, so reusing ordinal 4
    // would incorrectly leak it into the next historical page. The persisted
    // ordinal high-water mark must instead keep it newer than the cursor.
    conversation.messages.removeAll { ["m4", "m5", "m6"].contains($0.text) }
    conversation.messages.append(.init(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        role: .user,
        text: "m7"
    ))
    try await repository.save([conversation])
    let cursorData = try JSONEncoder().encode(first.nextCursor)
    let cursorAfterRestart = try JSONDecoder().decode(MessageCursor?.self, from: cursorData)
    let restarted = try ConversationRepository(databaseURL: url)
    let second = try await restarted.messagePage(conversationID: conversation.id, request: .init(fence: fence, before: cursorAfterRestart, limit: 3))
    #expect(second.items.map(\.text) == ["m1", "m2", "m3"])
    #expect(second.hasMore)
    let third = try await restarted.messagePage(conversationID: conversation.id, request: .init(fence: fence, before: second.nextCursor, limit: 3))
    #expect(third.items.map(\.text) == ["m0"])
    #expect(!third.hasMore)
    #expect((third.items + second.items + first.items).map(\.text) == (0..<7).map { "m\($0)" })

    let refreshed = try await restarted.messagePage(conversationID: conversation.id, request: .init(limit: 2))
    #expect(refreshed.items.map(\.text) == ["m3", "m7"])
}

@Test func paginationClampsLimitsAndEmptyConversationReturnsTerminalPage() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let conversation = Conversation(title: "Empty")
    try await repository.save([conversation])
    let conversationPage = try await repository.conversationPage(.init(limit: 0))
    #expect(conversationPage.items.count == 1)
    let messagePage = try await repository.messagePage(conversationID: conversation.id, request: .init(limit: -20))
    #expect(messagePage.items.isEmpty)
    #expect(!messagePage.hasMore)
    #expect(messagePage.nextCursor == nil)
}

@Test func paginationClampsOversizedLimitsToFiveHundred() async throws {
    let directory = try persistenceTemporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let messages = (0..<501).map { ChatMessage(role: .user, text: "m\($0)") }
    let primary = Conversation(title: "Large", messages: messages)
    let others = (0..<500).map { Conversation(title: "c\($0)") }
    try await repository.save([primary] + others)

    let conversations = try await repository.conversationPage(.init(limit: .max))
    #expect(conversations.items.count == 500)
    #expect(conversations.hasMore)
    #expect(conversations.nextCursor != nil)

    let messagePage = try await repository.messagePage(conversationID: primary.id, request: .init(limit: .max))
    #expect(messagePage.items.count == 500)
    #expect(messagePage.hasMore)
    #expect(messagePage.nextCursor != nil)
}
