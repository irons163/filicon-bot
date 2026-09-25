import CryptoKit
import CSQLite
import Darwin
import FiliconDomain
import Foundation

public enum PersistenceRecoveryKind: String, Codable, Hashable, Sendable {
    case healthy, searchIndexRebuilt, salvaged, freshDatabase, recoveryRequired
}

public struct PersistenceRejectedRow: Codable, Hashable, Sendable {
    public let table: String
    public let rowIdentifier: String
    public let reason: String
}

public struct PersistenceQuarantineArtifact: Codable, Hashable, Sendable {
    public let filename: String
    public let byteCount: Int
    public let sha256: String
}

public struct PersistenceRecoveryReport: Codable, Hashable, Sendable {
    public let generation: UUID
    public let kind: PersistenceRecoveryKind
    public let createdAt: Date
    public let quarantineDirectory: String?
    public let artifacts: [PersistenceQuarantineArtifact]
    public let recoveredConversations: Int
    public let recoveredMessages: Int
    public let rejectedRows: [PersistenceRejectedRow]
    public let summary: String
}

enum ConversationRecovery {
    private struct Marker: Codable {
        let generation: UUID
        let quarantineDirectory: String
        let databaseFilename: String
        let stagingPath: String
        var phase: String
    }

    private struct SalvageConversation {
        var value: Conversation
        var messages: [(ordinal: Int, value: ChatMessage)]
    }

    private final class RecoveryLock {
        private let descriptor: Int32
        init(url: URL) throws {
            try rejectSymlink(url)
            descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw PersistenceError.unsafePath(url.path) }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else { Darwin.close(descriptor); throw PersistenceError.unsafePath(url.path) }
            var acquired = false
            for _ in 0..<40 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { acquired = true; break }
                if errno != EWOULDBLOCK { break }
                usleep(50_000)
            }
            guard acquired else { Darwin.close(descriptor); throw PersistenceError.busy(operation: "coordinate recovery") }
        }
        deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    }

    static func prepare(databaseURL rawURL: URL) throws -> PersistenceRecoveryReport? {
        let databaseURL = try validatedDatabaseURL(rawURL)
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appending(path: ".\(databaseURL.lastPathComponent).recovery.lock")
        let markerURL = directory.appending(path: ".\(databaseURL.lastPathComponent).recovery.json")
        let lock = try RecoveryLock(url: lockURL)
        _ = lock
        try resumeInterruptedIfNeeded(databaseURL: databaseURL, markerURL: markerURL)
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        try rejectSymlink(databaseURL)
        let rawSnapshot = try snapshotCompanions(databaseURL)
        defer { try? FileManager.default.removeItem(at: rawSnapshot) }

        let header = (try? Data(contentsOf: databaseURL, options: .mappedIfSafe).prefix(16)) ?? Data()
        let sqliteHeader = Data("SQLite format 3\0".utf8)
        if header != sqliteHeader {
            try ensureDatabaseSnapshot(databaseURL, in: rawSnapshot)
            return try quarantineAndSalvage(databaseURL: databaseURL, markerURL: markerURL, rawSnapshot: rawSnapshot, sourceSchemaTrusted: false)
        }

        let inspection: Inspection
        do { inspection = try inspect(databaseURL) }
        catch let error as PersistenceError {
            switch error {
            case .recoveryRequired: throw error
            default:
                try ensureDatabaseSnapshot(databaseURL, in: rawSnapshot)
                return try quarantineAndSalvage(databaseURL: databaseURL, markerURL: markerURL, rawSnapshot: rawSnapshot, sourceSchemaTrusted: false)
            }
        }
        if inspection.authorityHealthy {
            if inspection.integrityHealthy && inspection.searchHealthy { return nil }
            try ensureDatabaseSnapshot(databaseURL, in: rawSnapshot)
            do {
                let database = try SQLiteDatabase(url: databaseURL)
                try database.configure()
                try rebuildIndexes(database)
                guard try check(database, pragma: "integrity_check") else { throw PersistenceError.corrupt(operation: "verify rebuilt indexes") }
                return PersistenceRecoveryReport(
                    generation: UUID(), kind: .searchIndexRebuilt, createdAt: Date(), quarantineDirectory: nil,
                    artifacts: [], recoveredConversations: inspection.conversationCount,
                    recoveredMessages: inspection.messageCount, rejectedRows: [],
                    summary: "The conversation search index was rebuilt; conversation data was unchanged."
                )
            } catch {
                return try quarantineAndSalvage(databaseURL: databaseURL, markerURL: markerURL, rawSnapshot: rawSnapshot, sourceSchemaTrusted: true)
            }
        }
        try ensureDatabaseSnapshot(databaseURL, in: rawSnapshot)
        return try quarantineAndSalvage(databaseURL: databaseURL, markerURL: markerURL, rawSnapshot: rawSnapshot, sourceSchemaTrusted: true)
    }

    static func rebuildIndexes(_ database: SQLiteDatabase) throws {
        try database.transaction("rebuild conversation indexes") {
            try database.execute("DROP TABLE IF EXISTS conversation_search", operation: "drop search index")
            try database.execute("DROP TABLE IF EXISTS message_search", operation: "drop message search index")
            try database.execute("DROP TABLE IF EXISTS media_search", operation: "drop media search index")
            try database.execute("DROP TABLE IF EXISTS media_search_fts", operation: "drop media full-text search index")
            try database.execute("DROP TABLE IF EXISTS global_search_state", operation: "drop global search state")
            try database.execute("DROP INDEX IF EXISTS idx_conversations_updated_at", operation: "drop conversation index")
            try database.execute("DROP INDEX IF EXISTS idx_conversations_hidden_at", operation: "drop hidden index")
            try database.execute("DROP INDEX IF EXISTS idx_conversations_page", operation: "drop conversation page index")
            try database.execute("DROP INDEX IF EXISTS idx_messages_conversation_ordinal", operation: "drop message index")
            try database.execute("DROP INDEX IF EXISTS idx_messages_page", operation: "drop message page index")
            try database.execute("CREATE INDEX idx_conversations_updated_at ON conversations(updated_at DESC)", operation: "recreate conversation index")
            try database.execute("CREATE INDEX idx_conversations_hidden_at ON conversations(hidden_at, updated_at DESC)", operation: "recreate hidden index")
            try database.execute("CREATE INDEX idx_conversations_page ON conversations(updated_at DESC, id DESC)", operation: "recreate conversation page index")
            try database.execute("CREATE INDEX idx_messages_conversation_ordinal ON messages(conversation_id,ordinal)", operation: "recreate message index")
            try database.execute("CREATE INDEX idx_messages_page ON messages(conversation_id, ordinal DESC, id DESC)", operation: "recreate message page index")
            try database.execute("CREATE VIRTUAL TABLE conversation_search USING fts5(conversation_id UNINDEXED, content, tokenize='unicode61')", operation: "recreate search index")
            try database.execute("INSERT INTO conversation_search(conversation_id,content) SELECT c.id, c.title || CASE WHEN EXISTS(SELECT 1 FROM messages m WHERE m.conversation_id=c.id) THEN char(10) || (SELECT group_concat(text, char(10)) FROM (SELECT text FROM messages m WHERE m.conversation_id=c.id ORDER BY ordinal)) ELSE '' END FROM conversations c", operation: "repopulate search index")
            try database.execute("CREATE VIRTUAL TABLE message_search USING fts5(conversation_id UNINDEXED,message_id UNINDEXED,role UNINDEXED,timestamp UNINDEXED,body,tokenize='unicode61')", operation: "recreate message search index")
            try database.execute("CREATE TABLE media_search(conversation_id TEXT NOT NULL,message_id TEXT NOT NULL,attachment_id TEXT NOT NULL,name TEXT NOT NULL,mime_type TEXT NOT NULL,kind TEXT NOT NULL,timestamp REAL NOT NULL,width INTEGER NOT NULL DEFAULT 0,height INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(conversation_id,message_id,attachment_id)) STRICT", operation: "recreate media search index")
            try database.execute("CREATE VIRTUAL TABLE media_search_fts USING fts5(conversation_id UNINDEXED,message_id UNINDEXED,attachment_id UNINDEXED,content,tokenize='unicode61')", operation: "recreate media full-text search index")
            let messages = try database.prepare("SELECT conversation_id,id,role,created_at,text,attachments_json FROM messages ORDER BY conversation_id,ordinal", operation: "load messages for search rebuild")
            let insertMessage = try database.prepare("INSERT INTO message_search(conversation_id,message_id,role,timestamp,body) VALUES(?,?,?,?,?)", operation: "repopulate message search index")
            let insertMedia = try database.prepare("INSERT INTO media_search(conversation_id,message_id,attachment_id,name,mime_type,kind,timestamp,width,height) VALUES(?,?,?,?,?,?,?,?,?)", operation: "repopulate media search index")
            let insertMediaFTS = try database.prepare("INSERT INTO media_search_fts(conversation_id,message_id,attachment_id,content) VALUES(?,?,?,?)", operation: "repopulate media full-text search index")
            while try messages.step() == SQLITE_ROW {
                let conversationID = messages.text(0), messageID = messages.text(1), timestamp = messages.double(3)
                try insertMessage.bind(conversationID, at: 1); try insertMessage.bind(messageID, at: 2); try insertMessage.bind(messages.text(2), at: 3); try insertMessage.bind(timestamp, at: 4); try insertMessage.bind(GlobalSearchQuery.boundedBody(messages.text(4)), at: 5); _ = try insertMessage.step(); insertMessage.reset()
                let attachments = try JSONDecoder().decode([AttachmentMetadata].self, from: Data(messages.text(5).utf8))
                var indexedAttachmentIDs: Set<String> = []
                for attachment in attachments where indexedAttachmentIDs.insert(attachment.id).inserted {
                    try insertMedia.bind(conversationID, at: 1); try insertMedia.bind(messageID, at: 2); try insertMedia.bind(attachment.id, at: 3); try insertMedia.bind(attachment.filename, at: 4); try insertMedia.bind(attachment.mimeType, at: 5); try insertMedia.bind(attachment.kind.rawValue, at: 6); try insertMedia.bind(attachment.createdAt.timeIntervalSince1970, at: 7); try insertMedia.bind(0, at: 8); try insertMedia.bind(0, at: 9); _ = try insertMedia.step(); insertMedia.reset()
                    try insertMediaFTS.bind(conversationID, at: 1); try insertMediaFTS.bind(messageID, at: 2); try insertMediaFTS.bind(attachment.id, at: 3); try insertMediaFTS.bind(attachment.filename + " " + attachment.mimeType + " " + attachment.kind.rawValue, at: 4); _ = try insertMediaFTS.step(); insertMediaFTS.reset()
                }
            }
            try database.execute("CREATE INDEX idx_media_search_recency ON media_search(timestamp DESC,message_id DESC)", operation: "recreate media recency index")
            try database.execute("CREATE TABLE global_search_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),ready INTEGER NOT NULL CHECK(ready IN (0,1)),generation INTEGER NOT NULL) STRICT", operation: "recreate global search state")
            try database.execute("INSERT INTO global_search_state(singleton,ready,generation) VALUES(1,1,1)", operation: "publish rebuilt global search indexes")
        }
    }

    static func manualRebuild(database: SQLiteDatabase) throws -> PersistenceRecoveryReport {
        try rebuildIndexes(database)
        guard try check(database, pragma: "integrity_check") else { throw PersistenceError.corrupt(operation: "verify manual index rebuild") }
        let counts = try rowCounts(database)
        return .init(generation: UUID(), kind: .searchIndexRebuilt, createdAt: Date(), quarantineDirectory: nil, artifacts: [], recoveredConversations: counts.0, recoveredMessages: counts.1, rejectedRows: [], summary: "Conversation search indexes were rebuilt and verified.")
    }

    static func verifyIntegrity(_ database: SQLiteDatabase) throws {
        guard try check(database, pragma: "quick_check"), try check(database, pragma: "integrity_check") else {
            throw PersistenceError.corrupt(operation: "verify database after open")
        }
    }

    private struct Inspection {
        let authorityHealthy: Bool
        let integrityHealthy: Bool
        let searchHealthy: Bool
        let conversationCount: Int
        let messageCount: Int
    }

    private static func inspect(_ url: URL) throws -> Inspection {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        try database.configureReadOnly()
        let version: Int
        do {
            let statement = try database.prepare("SELECT version FROM schema_version WHERE singleton=1", operation: "inspect schema authority")
            guard try statement.step() == SQLITE_ROW else { throw PersistenceError.recoveryRequired("schema authority is missing") }
            version = statement.int(0)
        } catch let error as PersistenceError {
            if try userTableCount(database) == 0 { return .init(authorityHealthy: true, integrityHealthy: true, searchHealthy: false, conversationCount: 0, messageCount: 0) }
            if case .corrupt = error { throw error }
            throw PersistenceError.recoveryRequired("schema authority cannot be verified")
        }
        guard version <= ConversationRepository.currentSchemaVersion else {
            throw PersistenceError.recoveryRequired("database schema \(version) is newer than supported schema \(ConversationRepository.currentSchemaVersion)")
        }
        if version < ConversationRepository.currentSchemaVersion {
            guard try check(database, pragma: "quick_check"), try check(database, pragma: "integrity_check") else {
                throw PersistenceError.recoveryRequired("a damaged legacy schema cannot be salvaged without guessing its authority")
            }
            return .init(authorityHealthy: true, integrityHealthy: true, searchHealthy: true, conversationCount: 0, messageCount: 0)
        }
        try validateCurrentSchema(database)
        let scan = scanRows(database, tolerateInvalidRows: true)
        let counts = (scan.values.count, scan.values.reduce(0) { $0 + $1.messages.count })
        let authorityHealthy = scan.rejected.isEmpty && scan.completed
        let searchHealthy = authorityHealthy && (try? validateSearch(database, expected: scan.values)) == true && (try? validateGlobalSearch(database, expected: scan.values)) == true
        return .init(authorityHealthy: authorityHealthy, integrityHealthy: (try? check(database, pragma: "integrity_check")) == true, searchHealthy: searchHealthy, conversationCount: counts.0, messageCount: counts.1)
    }

    private static func quarantineAndSalvage(databaseURL: URL, markerURL: URL, rawSnapshot: URL, sourceSchemaTrusted: Bool) throws -> PersistenceRecoveryReport {
        let generation = UUID()
        let directory = databaseURL.deletingLastPathComponent()
        let quarantineRoot = directory.appending(path: "Recovery Quarantine", directoryHint: .isDirectory)
        try rejectSymlink(quarantineRoot)
        if !FileManager.default.fileExists(atPath: quarantineRoot.path) {
            try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: quarantineRoot.path)
        let quarantine = quarantineRoot.appending(path: generation.uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staging = directory.appending(path: ".\(databaseURL.lastPathComponent).recovered-\(generation.uuidString.lowercased())")
        let marker = Marker(generation: generation, quarantineDirectory: quarantine.path, databaseFilename: databaseURL.lastPathComponent, stagingPath: staging.path, phase: "archiving")
        try write(marker, to: markerURL)

        var artifacts: [PersistenceQuarantineArtifact] = []
        for liveSource in companionURLs(databaseURL) {
            let source = rawSnapshot.appending(path: liveSource.lastPathComponent)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = quarantine.appending(path: liveSource.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: destination)
            let bytes = try Data(contentsOf: destination)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            artifacts.append(.init(filename: destination.lastPathComponent, byteCount: bytes.count, sha256: digest))
        }
        guard !artifacts.isEmpty else { throw PersistenceError.recoveryRequired("no database bytes could be quarantined") }

        var rejected: [PersistenceRejectedRow] = []
        var recovered: [SalvageConversation] = []
        if sourceSchemaTrusted || (try? validateSalvageSchema(databaseURL)) == true {
            do {
                let source = try SQLiteDatabase(url: databaseURL, readOnly: true)
                try source.configureReadOnly()
                let scan = scanRows(source, tolerateInvalidRows: true)
                recovered = scan.values
                rejected = scan.rejected
                if !scan.completed { rejected.append(.init(table: "database", rowIdentifier: "scan", reason: "SQLite stopped before every row could be read")) }
            } catch {
                rejected.append(.init(table: "database", rowIdentifier: "open", reason: bounded(error.localizedDescription)))
            }
        } else {
            rejected.append(.init(table: "database", rowIdentifier: "schema", reason: "Schema authority was unavailable; row salvage was not attempted"))
        }

        try writeRecovered(recovered, to: staging)
        var stagedMarker = marker; stagedMarker.phase = "staged"; try write(stagedMarker, to: markerURL)
        for source in companionURLs(databaseURL) where FileManager.default.fileExists(atPath: source.path) { try FileManager.default.removeItem(at: source) }
        for companion in companionURLs(staging).dropFirst() where FileManager.default.fileExists(atPath: companion.path) { try FileManager.default.removeItem(at: companion) }
        try FileManager.default.moveItem(at: staging, to: databaseURL)
        var switchedMarker = marker; switchedMarker.phase = "switched"; try write(switchedMarker, to: markerURL)

        let report = PersistenceRecoveryReport(
            generation: generation, kind: recovered.isEmpty ? .freshDatabase : .salvaged, createdAt: Date(),
            quarantineDirectory: quarantine.path, artifacts: artifacts,
            recoveredConversations: recovered.count, recoveredMessages: recovered.reduce(0) { $0 + $1.messages.count },
            rejectedRows: rejected,
            summary: recovered.isEmpty
                ? "The damaged database was preserved in quarantine. No trustworthy rows could be recovered, so a new empty database was created."
                : "The damaged database was preserved in quarantine and valid conversation rows were recovered."
        )
        try write(report, to: quarantine.appending(path: "manifest.json"))
        try FileManager.default.removeItem(at: markerURL)
        return report
    }

    private static func validateSalvageSchema(_ url: URL) throws -> Bool {
        let database = try SQLiteDatabase(url: url, readOnly: true)
        try database.configureReadOnly()
        try validateCurrentSchema(database)
        return true
    }

    private static func scanRows(_ database: SQLiteDatabase, tolerateInvalidRows: Bool) -> (values: [SalvageConversation], rejected: [PersistenceRejectedRow], completed: Bool) {
        var rejected: [PersistenceRejectedRow] = []
        var values: [UUID: SalvageConversation] = [:]
        var completed = true
        do {
            let rows = try database.prepare("SELECT id,title,provider_id,model_id,updated_at,hidden_at,reasoning_effort,message_addresses_json FROM conversations ORDER BY rowid", operation: "scan conversations for recovery")
            while true {
                let code: Int32
                do { code = try rows.step() } catch { rejected.append(.init(table: "conversations", rowIdentifier: "scan", reason: bounded(error.localizedDescription))); completed = false; break }
                if code == SQLITE_DONE { break }
                let rawID = rows.text(0)
                do {
                    let conversation = try ConversationRepository.decodeConversationMetadata(rows)
                    values[conversation.id] = .init(value: conversation, messages: [])
                } catch {
                    rejected.append(.init(table: "conversations", rowIdentifier: bounded(rawID), reason: bounded(error.localizedDescription)))
                    if !tolerateInvalidRows { completed = false; break }
                }
            }
        } catch { rejected.append(.init(table: "conversations", rowIdentifier: "query", reason: bounded(error.localizedDescription))); completed = false }
        do {
            let rows = try database.prepare("SELECT id,role,text,created_at,attachments_json,delivery_status,delivery_error,reasoning_text,tool_activities_json,reply_to_message_id,reactions_json,transcript_cards_json,short_address,conversation_id,ordinal FROM messages ORDER BY rowid", operation: "scan messages for recovery")
            var seenMessageIDs: Set<UUID> = []
            while true {
                let code: Int32
                do { code = try rows.step() } catch { rejected.append(.init(table: "messages", rowIdentifier: "scan", reason: bounded(error.localizedDescription))); completed = false; break }
                if code == SQLITE_DONE { break }
                let rawID = rows.text(0), rawConversationID = rows.text(13), ordinal = rows.int(14)
                do {
                    guard let conversationID = UUID(uuidString: rawConversationID), values[conversationID] != nil else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "conversation_id") }
                    guard ordinal >= 0 else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "ordinal") }
                    let message = try ConversationRepository.decodeMessage(rows)
                    guard seenMessageIDs.insert(message.id).inserted else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "id") }
                    values[conversationID]?.messages.append((ordinal, message))
                } catch {
                    rejected.append(.init(table: "messages", rowIdentifier: bounded(rawID), reason: bounded(error.localizedDescription)))
                    if !tolerateInvalidRows { completed = false; break }
                }
            }
        } catch { rejected.append(.init(table: "messages", rowIdentifier: "query", reason: bounded(error.localizedDescription))); completed = false }
        let ordered = values.values.map { item -> SalvageConversation in
            var item = item
            item.messages.sort { $0.ordinal == $1.ordinal ? $0.value.id.uuidString < $1.value.id.uuidString : $0.ordinal < $1.ordinal }
            item.value.messages = item.messages.map(\.value)
            return item
        }.sorted { $0.value.updatedAt > $1.value.updatedAt }
        return (ordered, rejected, completed)
    }

    private static func writeRecovered(_ values: [SalvageConversation], to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PersistenceError.unsafePath(url.path) }
        let database = try SQLiteDatabase(url: url)
        try database.configure()
        try ConversationRepository.migrate(database)
        try database.transaction("write recovered conversations") {
            let conversation = try database.prepare("INSERT INTO conversations(id,title,provider_id,model_id,updated_at,hidden_at,next_message_ordinal,reasoning_effort,message_addresses_json) VALUES(?,?,?,?,?,?,?,?,?)", operation: "recover conversation")
            let message = try database.prepare("INSERT INTO messages(id,conversation_id,ordinal,role,text,created_at,attachments_json,delivery_status,delivery_error,reasoning_text,tool_activities_json,reply_to_message_id,reactions_json,transcript_cards_json,short_address) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", operation: "recover message")
            let search = try database.prepare("INSERT INTO conversation_search(conversation_id,content) VALUES(?,?)", operation: "recover search")
            for item in values {
                let value = item.value
                let nextOrdinal = (item.messages.map(\.ordinal).max() ?? -1) + 1
                try conversation.bind(value.id.uuidString, at: 1); try conversation.bind(value.title, at: 2); try conversation.bind(value.providerID.rawValue, at: 3); try conversation.bind(value.modelID.rawValue, at: 4); try conversation.bind(value.updatedAt.timeIntervalSince1970, at: 5); try conversation.bind(value.hiddenAt?.timeIntervalSince1970 ?? 0, at: 6); try conversation.bind(nextOrdinal, at: 7); try conversation.bind(value.reasoningEffort.rawValue, at: 8); try conversation.bind(String(decoding: JSONEncoder().encode(value.messageAddressReservations), as: UTF8.self), at: 9); _ = try conversation.step(); conversation.reset()
                for row in item.messages {
                    let value = row.value
                    let attachments = try JSONEncoder().encode(value.attachments), activities = try JSONEncoder().encode(value.toolActivities), reactions = try JSONEncoder().encode(value.reactions), cards = try JSONEncoder().encode(value.transcriptCards)
                    try message.bind(value.id.uuidString, at: 1); try message.bind(item.value.id.uuidString, at: 2); try message.bind(row.ordinal, at: 3); try message.bind(value.role.rawValue, at: 4); try message.bind(value.text, at: 5); try message.bind(value.createdAt.timeIntervalSince1970, at: 6); try message.bind(String(decoding: attachments, as: UTF8.self), at: 7); try message.bind(value.deliveryStatus.rawValue, at: 8); try message.bind(value.deliveryError ?? "", at: 9); try message.bind(value.reasoningText, at: 10); try message.bind(String(decoding: activities, as: UTF8.self), at: 11); try message.bind(value.replyToMessageID?.uuidString ?? "", at: 12); try message.bind(String(decoding: reactions, as: UTF8.self), at: 13); try message.bind(String(decoding: cards, as: UTF8.self), at: 14); try message.bind(value.shortAddress ?? "", at: 15); _ = try message.step(); message.reset()
                }
                try search.bind(value.id.uuidString, at: 1); try search.bind(([value.title] + value.messages.map(\.text)).joined(separator: "\n"), at: 2); _ = try search.step(); search.reset()
            }
        }
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)", operation: "checkpoint recovered database")
        guard try check(database, pragma: "integrity_check") else { throw PersistenceError.corrupt(operation: "verify recovered database") }
    }

    private static func validateCurrentSchema(_ database: SQLiteDatabase) throws {
        let expected: [String: [String]] = [
            "conversations": ["id", "title", "provider_id", "model_id", "updated_at", "hidden_at", "next_message_ordinal", "reasoning_effort", "message_addresses_json"],
            "messages": ["id", "conversation_id", "ordinal", "role", "text", "created_at", "attachments_json", "delivery_status", "delivery_error", "reasoning_text", "tool_activities_json", "reply_to_message_id", "reactions_json", "transcript_cards_json", "short_address"],
        ]
        for (table, columns) in expected {
            let statement = try database.prepare("PRAGMA table_info(\(table))", operation: "validate \(table) schema")
            var actual: [String] = []
            while try statement.step() == SQLITE_ROW { actual.append(statement.text(1)) }
            guard actual == columns else { throw PersistenceError.recoveryRequired("\(table) schema does not match the trusted schema") }
        }
    }

    private static func validateSearch(_ database: SQLiteDatabase, expected: [SalvageConversation]) throws -> Bool {
        let statement = try database.prepare("SELECT conversation_id,content FROM conversation_search ORDER BY conversation_id", operation: "validate search index")
        var actual: [String: String] = [:]
        while try statement.step() == SQLITE_ROW {
            let id = statement.text(0)
            guard actual[id] == nil else { return false }
            actual[id] = statement.text(1)
        }
        let wanted = Dictionary(uniqueKeysWithValues: expected.map { ($0.value.id.uuidString, ([$0.value.title] + $0.value.messages.map(\.text)).joined(separator: "\n")) })
        return actual == wanted
    }

    private static func validateGlobalSearch(_ database: SQLiteDatabase, expected: [SalvageConversation]) throws -> Bool {
        let state = try database.prepare("SELECT ready FROM global_search_state WHERE singleton=1", operation: "validate global search readiness")
        guard try state.step() == SQLITE_ROW, state.int(0) == 1 else { return false }
        let messages = try database.prepare("SELECT conversation_id,message_id,role,timestamp,body FROM message_search ORDER BY conversation_id,message_id", operation: "validate message search")
        var actualMessages: [String: String] = [:]
        while try messages.step() == SQLITE_ROW {
            let key = messages.text(0) + "/" + messages.text(1)
            guard actualMessages[key] == nil else { return false }
            actualMessages[key] = messages.text(2) + "|" + String(messages.double(3)) + "|" + messages.text(4)
        }
        var wantedMessages: [String: String] = [:]
        var wantedMedia: Set<String> = []
        for item in expected {
            for message in item.value.messages {
                wantedMessages[item.value.id.uuidString + "/" + message.id.uuidString] = message.role.rawValue + "|" + String(message.createdAt.timeIntervalSince1970) + "|" + GlobalSearchQuery.boundedBody(message.text)
                for attachment in message.attachments { wantedMedia.insert(item.value.id.uuidString + "/" + message.id.uuidString + "/" + attachment.id) }
            }
        }
        guard actualMessages == wantedMessages else { return false }
        let media = try database.prepare("SELECT conversation_id,message_id,attachment_id FROM media_search", operation: "validate media search")
        var actualMedia: Set<String> = []
        while try media.step() == SQLITE_ROW { actualMedia.insert(media.text(0) + "/" + media.text(1) + "/" + media.text(2)) }
        guard actualMedia == wantedMedia else { return false }
        let mediaFTS = try database.prepare("SELECT conversation_id,message_id,attachment_id FROM media_search_fts", operation: "validate media full-text search")
        var actualMediaFTS: Set<String> = []
        while try mediaFTS.step() == SQLITE_ROW { actualMediaFTS.insert(mediaFTS.text(0) + "/" + mediaFTS.text(1) + "/" + mediaFTS.text(2)) }
        return actualMediaFTS == wantedMedia
    }

    private static func rowCounts(_ database: SQLiteDatabase) throws -> (Int, Int) {
        func count(_ table: String) throws -> Int {
            let statement = try database.prepare("SELECT count(*) FROM \(table)", operation: "count \(table)")
            return try statement.step() == SQLITE_ROW ? statement.int(0) : 0
        }
        return (try count("conversations"), try count("messages"))
    }

    private static func userTableCount(_ database: SQLiteDatabase) throws -> Int {
        let statement = try database.prepare("SELECT count(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'", operation: "inspect user tables")
        return try statement.step() == SQLITE_ROW ? statement.int(0) : 0
    }

    private static func check(_ database: SQLiteDatabase, pragma: String) throws -> Bool {
        let statement = try database.prepare("PRAGMA \(pragma)", operation: pragma)
        var sawRow = false
        while try statement.step() == SQLITE_ROW { sawRow = true; if statement.text(0).lowercased() != "ok" { return false } }
        return sawRow
    }

    private static func resumeInterruptedIfNeeded(databaseURL: URL, markerURL: URL) throws {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        try rejectSymlink(markerURL)
        let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))
        let directory = databaseURL.deletingLastPathComponent().standardizedFileURL
        let quarantine = URL(fileURLWithPath: marker.quarantineDirectory, isDirectory: true).standardizedFileURL
        let quarantineRoot = directory.appending(path: "Recovery Quarantine", directoryHint: .isDirectory).standardizedFileURL
        guard quarantine.path.hasPrefix(quarantineRoot.path + "/"), marker.databaseFilename == databaseURL.lastPathComponent else { throw PersistenceError.unsafePath(markerURL.path) }
        if !FileManager.default.fileExists(atPath: databaseURL.path) {
            let archived = quarantine.appending(path: marker.databaseFilename)
            guard FileManager.default.fileExists(atPath: archived.path) else { throw PersistenceError.recoveryRequired("an interrupted recovery has no source database") }
            try FileManager.default.copyItem(at: archived, to: databaseURL)
            for suffix in ["-wal", "-shm"] {
                let source = quarantine.appending(path: marker.databaseFilename + suffix)
                let destination = URL(fileURLWithPath: databaseURL.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.copyItem(at: source, to: destination) }
            }
        }
        let staging = URL(fileURLWithPath: marker.stagingPath).standardizedFileURL
        if staging.deletingLastPathComponent() == directory, FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        try FileManager.default.removeItem(at: markerURL)
    }

    private static func validatedDatabaseURL(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw PersistenceError.unsafePath(url.absoluteString) }
        let standardized = url.standardizedFileURL
        guard url.path == standardized.path, !standardized.lastPathComponent.isEmpty, standardized.lastPathComponent != ".", standardized.lastPathComponent != ".." else { throw PersistenceError.unsafePath(url.path) }
        try rejectSymlink(standardized.deletingLastPathComponent())
        return standardized
    }

    private static func rejectSymlink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { throw PersistenceError.unsafePath(url.path) }
    }

    private static func companionURLs(_ databaseURL: URL) -> [URL] {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal"), URL(fileURLWithPath: databaseURL.path + "-shm")]
    }

    private static func snapshotCompanions(_ databaseURL: URL) throws -> URL {
        let directory = databaseURL.deletingLastPathComponent()
        let snapshot = directory.appending(path: ".\(databaseURL.lastPathComponent).raw-snapshot-\(UUID().uuidString.lowercased())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            for source in companionURLs(databaseURL).dropFirst() where FileManager.default.fileExists(atPath: source.path) {
                try rejectSymlink(source)
                try FileManager.default.copyItem(at: source, to: snapshot.appending(path: source.lastPathComponent))
            }
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }

    private static func ensureDatabaseSnapshot(_ databaseURL: URL, in snapshot: URL) throws {
        let destination = snapshot.appending(path: databaseURL.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try rejectSymlink(databaseURL)
        try FileManager.default.copyItem(at: databaseURL, to: destination)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static func bounded(_ value: String) -> String { String(value.prefix(1_000)) }
}
