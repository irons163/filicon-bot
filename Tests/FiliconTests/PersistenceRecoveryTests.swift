import CSQLite
import Darwin
import FiliconDomain
import FiliconPersistence
import Foundation
import Testing
import CustomDump

private func recoveryDirectory() throws -> URL {
    let value = FileManager.default.temporaryDirectory.appending(path: "persistence-recovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
    return value
}

private func executeRecoverySQL(_ url: URL, _ sql: String) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
        throw PersistenceError.corrupt(operation: "open fault fixture")
    }
    defer { sqlite3_close_v2(database) }
    var message: UnsafeMutablePointer<CChar>?
    let code = sqlite3_exec(database, sql, nil, nil, &message)
    let detail = message.map { String(cString: $0) } ?? "SQL fixture failed"
    sqlite3_free(message)
    guard code == SQLITE_OK else { throw PersistenceError.sqlite(code: code, message: detail, operation: "inject fault") }
}

private func seedRecoveryDatabase(_ url: URL) async throws -> Conversation {
    var conversation = Conversation(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, title: "Recovery fixture",
        messages: [
            .init(id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!, role: .user, text: "valid first", shortAddress: "t3u"),
            .init(id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!, role: .assistant, text: "bad second"),
        ]
    )
    conversation.messageAddressReservations = ["20000000-0000-0000-0000-000000000099": "t2s8"]
    conversation.messages[0].remoteAttachment = try RemoteAttachmentReference(url: "https://example.com/report?sig=a%2Bb", alt: "報表")
    conversation.agentBinding = .init(accountID: "recovery-account", agentID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!)
    let repository = try ConversationRepository(databaseURL: url)
    try await repository.save([conversation])
    return conversation
}

@Test func ftsOnlyDamageIsRebuiltWithoutQuarantiningAuthority() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let expected = try await seedRecoveryDatabase(url)
    try executeRecoverySQL(url, "DELETE FROM conversation_search")

    let reopened = try ConversationRepository(databaseURL: url)
    let report = try #require(reopened.initialRecoveryReport)
    #expect(report.kind == .searchIndexRebuilt)
    #expect(report.quarantineDirectory == nil)
    #expect(try await reopened.search("valid").map(\.id) == [expected.id])
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Recovery Quarantine").path))
}

@Test func malformedJSONRowIsRejectedWhileValidConversationIsSalvaged() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let expected = try await seedRecoveryDatabase(url)
    try executeRecoverySQL(url, "UPDATE messages SET attachments_json='{' WHERE id='20000000-0000-0000-0000-000000000002'")

    let reopened = try ConversationRepository(databaseURL: url)
    let report = try #require(reopened.initialRecoveryReport)
    #expect(report.kind == .salvaged)
    #expect(report.recoveredConversations == 1)
    #expect(report.recoveredMessages == 1)
    let recoveredValues = try await reopened.load()
    expectNoDifference(recoveredValues.first?.messages.first?.shortAddress, "t3u")
    expectNoDifference(recoveredValues.first?.messageAddressReservations, expected.messageAddressReservations)
    expectNoDifference(recoveredValues.first?.agentBinding, expected.agentBinding)
    expectNoDifference(recoveredValues.first?.messages.first?.remoteAttachment, expected.messages.first?.remoteAttachment)
    #expect(report.rejectedRows.contains { $0.table == "messages" && $0.rowIdentifier == "20000000-0000-0000-0000-000000000002" })
    let loaded = try await reopened.load()
    #expect(loaded.map(\.id) == [expected.id])
    #expect(loaded[0].messages.map(\.text) == ["valid first"])
    let quarantine = URL(fileURLWithPath: try #require(report.quarantineDirectory))
    #expect(FileManager.default.fileExists(atPath: quarantine.appending(path: "manifest.json").path))
    #expect(report.artifacts.contains { $0.filename == "chat.sqlite3" && $0.byteCount > 0 && $0.sha256.count == 64 })
}

@Test func truncatedDatabaseAndWALCompanionsArePreservedInPrivateQuarantine() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let original = Data("SQLite format 3\0truncated".utf8)
    let wal = Data("raw wal bytes".utf8), shm = Data("raw shm bytes".utf8)
    try original.write(to: url); try wal.write(to: URL(fileURLWithPath: url.path + "-wal")); try shm.write(to: URL(fileURLWithPath: url.path + "-shm"))

    let repository = try ConversationRepository(databaseURL: url)
    #expect(try await repository.load().isEmpty)
    let report = try #require(repository.initialRecoveryReport)
    let quarantine = URL(fileURLWithPath: try #require(report.quarantineDirectory))
    #expect(try Data(contentsOf: quarantine.appending(path: "chat.sqlite3")) == original)
    #expect(try Data(contentsOf: quarantine.appending(path: "chat.sqlite3-wal")) == wal)
    #expect(try Data(contentsOf: quarantine.appending(path: "chat.sqlite3-shm")) == shm)
    let permissions = try FileManager.default.attributesOfItem(atPath: quarantine.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o700)
}

@Test func quarantineGenerationsNeverCollideOrOverwriteEarlierEvidence() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let firstBytes = Data("first invalid database".utf8); try firstBytes.write(to: url)
    let first = try ConversationRepository(databaseURL: url)
    let firstReport = try #require(first.initialRecoveryReport)
    let firstQuarantine = URL(fileURLWithPath: try #require(firstReport.quarantineDirectory))

    let secondBytes = Data("second invalid database".utf8); try secondBytes.write(to: url)
    let second = try ConversationRepository(databaseURL: url)
    let secondReport = try #require(second.initialRecoveryReport)
    let secondQuarantine = URL(fileURLWithPath: try #require(secondReport.quarantineDirectory))
    #expect(firstQuarantine != secondQuarantine)
    #expect(try Data(contentsOf: firstQuarantine.appending(path: "chat.sqlite3")) == firstBytes)
    #expect(try Data(contentsOf: secondQuarantine.appending(path: "chat.sqlite3")) == secondBytes)
}

@Test func untrustedSchemaFailsClosedWithoutReplacingBytes() throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    var database: OpaquePointer?
    #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
    #expect(sqlite3_exec(database, "CREATE TABLE conversations(id TEXT PRIMARY KEY, secret TEXT)", nil, nil, nil) == SQLITE_OK)
    sqlite3_close_v2(database)
    let original = try Data(contentsOf: url)
    #expect(throws: PersistenceError.self) { _ = try ConversationRepository(databaseURL: url) }
    #expect(try Data(contentsOf: url) == original)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "Recovery Quarantine").path))
}

@Test func symlinkDatabaseTargetIsRejectedWithoutTouchingTarget() throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let target = directory.appending(path: "target.bin"), link = directory.appending(path: "chat.sqlite3")
    let bytes = Data("do not touch".utf8); try bytes.write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: PersistenceError.self) { _ = try ConversationRepository(databaseURL: link) }
    #expect(try Data(contentsOf: target) == bytes)
}

@Test func interruptedRecoveryRestoresArchivedGenerationAndRetriesSafely() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let expected = try await seedRecoveryDatabase(url)
    let quarantine = directory.appending(path: "Recovery Quarantine/interrupted", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for suffix in ["", "-wal", "-shm"] {
        let companion = URL(fileURLWithPath: url.path + suffix)
        if FileManager.default.fileExists(atPath: companion.path) {
            try FileManager.default.copyItem(at: companion, to: quarantine.appending(path: "chat.sqlite3" + suffix))
            try FileManager.default.removeItem(at: companion)
        }
    }
    let staging = directory.appending(path: ".chat.sqlite3.recovered-interrupted")
    try Data("partial staging".utf8).write(to: staging)
    let marker = """
    {"generation":"30000000-0000-0000-0000-000000000001","quarantineDirectory":"\(quarantine.path)","databaseFilename":"chat.sqlite3","stagingPath":"\(staging.path)","phase":"archiving"}
    """
    let markerURL = directory.appending(path: ".chat.sqlite3.recovery.json")
    try Data(marker.utf8).write(to: markerURL)

    let recovered = try ConversationRepository(databaseURL: url)
    #expect(try await recovered.load().map(\.id) == [expected.id])
    #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    #expect(!FileManager.default.fileExists(atPath: staging.path))
    #expect(FileManager.default.fileExists(atPath: quarantine.appending(path: "chat.sqlite3").path))
}

@Test func peerRecoveryLockFailsBusyWithoutOverwritingThenRetries() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let expected = try await seedRecoveryDatabase(url)
    let lockURL = directory.appending(path: ".chat.sqlite3.recovery.lock")
    let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    #expect(descriptor >= 0)
    #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    let before = try Data(contentsOf: url)
    #expect(throws: PersistenceError.self) { _ = try ConversationRepository(databaseURL: url) }
    #expect(try Data(contentsOf: url) == before)
    flock(descriptor, LOCK_UN); Darwin.close(descriptor)

    let retried = try ConversationRepository(databaseURL: url)
    #expect(try await retried.load().map(\.id) == [expected.id])
    #expect(retried.initialRecoveryReport == nil)
}

@Test func manualIndexRebuildPreservesAuthorityAndReturnsUserReport() async throws {
    let directory = try recoveryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "chat.sqlite3")
    let expected = try await seedRecoveryDatabase(url)
    let repository = try ConversationRepository(databaseURL: url)
    let before = try await repository.load()
    let report = try await repository.rebuildSearchIndex()
    #expect(report.kind == .searchIndexRebuilt)
    #expect(report.recoveredConversations == 1)
    #expect(report.recoveredMessages == 2)
    #expect(try await repository.load() == before)
    #expect(try await repository.search("Recovery").map(\.id) == [expected.id])
}
