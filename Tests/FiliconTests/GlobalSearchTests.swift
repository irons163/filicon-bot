import CSQLite
import FiliconAppServices
import FiliconDomain
import FiliconPersistence
import Foundation
import Testing

private func globalSearchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "global-search-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func globalSearchSQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
        throw PersistenceError.corrupt(operation: "open global search test database")
    }
    defer { sqlite3_close_v2(database) }
    var error: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(database, sql, nil, nil, &error)
    let detail = error.map { String(cString: $0) } ?? "SQL test fixture failed"
    sqlite3_free(error)
    guard code == SQLITE_OK else { throw PersistenceError.sqlite(code: code, message: detail, operation: "mutate global search test index") }
}

@Test func globalMessageSearchMapsCanonicalIDsFiltersHiddenAndBoundsTermsAndBodies() async throws {
    let directory = try globalSearchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let messageID = UUID(), timestamp = Date(timeIntervalSince1970: 1_800_000_001)
    let body = "one two three four five six seven eight " + String(repeating: "x", count: 20_000) + " ninth-tail"
    let visible = Conversation(messages: [.init(id: messageID, role: .assistant, text: body, createdAt: timestamp)])
    let hidden = Conversation(messages: [.init(role: .user, text: "one two three four five six seven eight hidden")], hiddenAt: Date())
    try await repository.save([visible, hidden])

    let hits = try await repository.searchMessages("one two three four five six seven eight ignored-ninth")
    #expect(hits.count == 1)
    #expect(hits[0].conversationID == visible.id) // recovered agentId mapping
    #expect(hits[0].messageID == messageID)       // recovered entryId mapping
    #expect(hits[0].role == .assistant)
    #expect(hits[0].timestamp == timestamp)
    #expect(hits[0].snippet.count <= 242)
    #expect(try await repository.searchMessages("ninth-tail").isEmpty)
    #expect(try await repository.searchMessages("hidden", includeHidden: true).map(\.conversationID) == [hidden.id])
    #expect(try await repository.searchMessages("hidden").isEmpty)
}

@Test func globalMessageSearchEnforcesPerConversationAndGlobalCaps() async throws {
    let directory = try globalSearchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let conversations = (0..<12).map { conversationIndex in
        Conversation(messages: (0..<7).map { messageIndex in
            .init(role: .user, text: "sharedterm c\(conversationIndex) m\(messageIndex)", createdAt: Date(timeIntervalSince1970: Double(10_000 + conversationIndex * 10 + messageIndex)))
        })
    }
    try await repository.save(conversations)
    let hits = try await repository.searchMessages("sharedterm")
    #expect(hits.count == GlobalSearchLimits.maximumResults)
    let grouped = Dictionary(grouping: hits, by: \.conversationID)
    #expect(grouped.values.allSatisfy { $0.count <= GlobalSearchLimits.maximumPerConversation })
}

@Test func mediaSearchSupportsRecencyEmptyQueryMetadataTermsAndHiddenFiltering() async throws {
    let directory = try globalSearchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let repository = try ConversationRepository(databaseURL: directory.appending(path: "chat.sqlite3"))
    let old = AttachmentMetadata(id: "old", filename: "diagram.png", mimeType: "image/png", byteCount: 1, kind: .image, createdAt: Date(timeIntervalSince1970: 10))
    let recent = AttachmentMetadata(id: "recent", filename: "report.pdf", mimeType: "application/pdf", byteCount: 1, kind: .document, createdAt: Date(timeIntervalSince1970: 30))
    let hiddenAttachment = AttachmentMetadata(id: "hidden", filename: "secret.mov", mimeType: "video/quicktime", byteCount: 1, kind: .video, createdAt: Date(timeIntervalSince1970: 40))
    let visible = Conversation(messages: [.init(role: .user, text: "files", attachments: [old, recent])])
    let hidden = Conversation(messages: [.init(role: .user, text: "hidden", attachments: [hiddenAttachment])], hiddenAt: Date())
    try await repository.save([visible, hidden])

    #expect(try await repository.searchMedia("").map(\.attachmentID) == ["recent", "old"])
    #expect(try await repository.searchMedia("application pdf").map(\.attachmentID) == ["recent"])
    #expect(try await repository.searchMedia("image").map(\.attachmentID) == ["old"])
    #expect(try await repository.searchMedia("secret").isEmpty)
    #expect(try await repository.searchMedia("secret", includeHidden: true).map(\.attachmentID) == ["hidden"])
    #expect(try await repository.searchMedia("report").first?.width == nil)
}

@Test func appServiceFallsBackToCanonicalRowsMergesLiveInputsAndMediaFailsClosed() async throws {
    let directory = try globalSearchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let legacy = directory.appending(path: "conversations.json"), databaseURL = directory.appending(path: "conversations.sqlite3")
    let persistedID = UUID(), conversation = Conversation(messages: [.init(id: persistedID, role: .user, text: "fallback needle", createdAt: Date(timeIntervalSince1970: 20))])
    let store = ConversationStore(fileURL: legacy)
    try await store.save([conversation])
    try globalSearchSQL(databaseURL, "DROP TABLE message_search; DROP TABLE media_search; DROP TABLE media_search_fts")

    let liveID = UUID()
    let hits = try await store.searchGlobalMessages("needle", latestLiveInputs: [
        .init(conversationID: conversation.id, messageID: liveID, role: .assistant, timestamp: Date(timeIntervalSince1970: 30), body: "live needle"),
        .init(conversationID: conversation.id, messageID: persistedID, role: .user, timestamp: Date(timeIntervalSince1970: 25), body: "newest needle replacement"),
    ])
    #expect(hits.map(\.messageID) == [liveID, persistedID])
    #expect(hits[1].snippet.contains("replacement"))
    #expect(try await store.searchGlobalMedia("").isEmpty)
}

@Test func derivedGlobalIndexMismatchIsRebuiltAndAtomicSaveRollbackKeepsOldHits() async throws {
    let directory = try globalSearchDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    var repository: ConversationRepository? = try ConversationRepository(databaseURL: url)
    let conversation = Conversation(messages: [.init(role: .user, text: "durable needle")])
    try await repository?.save([conversation])
    let duplicate = UUID()
    let invalid = Conversation(messages: [.init(id: duplicate, role: .user, text: "bad"), .init(id: duplicate, role: .assistant, text: "bad")])
    await #expect(throws: (any Error).self) { try await repository?.save([invalid]) }
    #expect(try await repository?.searchMessages("durable").map(\.conversationID) == [conversation.id])

    repository = nil
    try globalSearchSQL(url, "DELETE FROM message_search")
    let reopened = try ConversationRepository(databaseURL: url)
    #expect(reopened.initialRecoveryReport?.kind == .searchIndexRebuilt)
    #expect(try await reopened.globalSearchReadiness() == .ready)
    #expect(try await reopened.searchMessages("durable").map(\.conversationID) == [conversation.id])
}
