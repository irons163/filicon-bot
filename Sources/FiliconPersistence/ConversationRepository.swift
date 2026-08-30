import Foundation
import FiliconDomain
import CSQLite

public actor ConversationRepository {
    public static let currentSchemaVersion = 9
    private let database: SQLiteDatabase
    public nonisolated let initialRecoveryReport: PersistenceRecoveryReport?

    public init(databaseURL: URL) throws {
        initialRecoveryReport = try ConversationRecovery.prepare(databaseURL: databaseURL)
        database = try SQLiteDatabase(url: databaseURL)
        try database.configure()
        try Self.migrate(database)
        try Self.reconcileGlobalSearchIndexes(database)
        try ConversationRecovery.verifyIntegrity(database)
    }

    public func schemaVersion() throws -> Int {
        let statement = try database.prepare("SELECT version FROM schema_version WHERE singleton = 1", operation: "read schema version")
        return try statement.step() == SQLITE_ROW ? statement.int(0) : 0
    }

    public func load() throws -> [Conversation] {
        let conversations = try database.prepare("SELECT id, title, provider_id, model_id, updated_at, hidden_at, reasoning_effort FROM conversations ORDER BY updated_at DESC, id DESC", operation: "load conversations")
        let messages = try database.prepare("SELECT id, role, text, created_at, attachments_json, delivery_status, delivery_error, reasoning_text, tool_activities_json, reply_to_message_id, reactions_json, transcript_cards_json FROM messages WHERE conversation_id = ? ORDER BY ordinal", operation: "load messages")
        var result: [Conversation] = []
        while try conversations.step() == SQLITE_ROW {
            var conversation = try Self.decodeConversationMetadata(conversations)
            let id = conversation.id
            try messages.bind(id.uuidString, at: 1)
            var rows: [ChatMessage] = []
            while try messages.step() == SQLITE_ROW {
                rows.append(try Self.decodeMessage(messages))
            }
            messages.reset()
            conversation.messages = rows
            result.append(conversation)
        }
        return result
    }

    /// Loads one stable keyset page of conversation metadata. The canonical
    /// `load()` API remains the full snapshot API, including every message.
    public func conversationPage(_ request: ConversationPageRequest = ConversationPageRequest()) throws -> ConversationPage {
        let limit = Self.normalizedLimit(request.limit)
        let sql: String
        if request.after == nil {
            sql = "SELECT id, title, provider_id, model_id, updated_at, hidden_at, reasoning_effort FROM conversations ORDER BY updated_at DESC, id DESC LIMIT ?"
        } else {
            sql = "SELECT id, title, provider_id, model_id, updated_at, hidden_at, reasoning_effort FROM conversations WHERE updated_at < ? OR (updated_at = ? AND id < ?) ORDER BY updated_at DESC, id DESC LIMIT ?"
        }
        let statement = try database.prepare(sql, operation: "page conversations")
        if let cursor = request.after {
            let timestamp = cursor.updatedAt.timeIntervalSince1970
            try statement.bind(timestamp, at: 1)
            try statement.bind(timestamp, at: 2)
            try statement.bind(cursor.id.uuidString, at: 3)
            try statement.bind(limit + 1, at: 4)
        } else {
            try statement.bind(limit + 1, at: 1)
        }

        var values: [Conversation] = []
        while try statement.step() == SQLITE_ROW {
            values.append(try Self.decodeConversationMetadata(statement))
        }
        let hasMore = values.count > limit
        if hasMore { values.removeLast() }
        let nextCursor = hasMore ? values.last.map { ConversationCursor(updatedAt: $0.updatedAt, id: $0.id) } : nil
        return ConversationPage(fence: request.fence, items: values, nextCursor: nextCursor, hasMore: hasMore)
    }

    /// Loads messages backwards from the newest row using `(ordinal, id)` as
    /// the keyset while returning each individual page in chronological order.
    public func messagePage(conversationID: UUID, request: MessagePageRequest = MessagePageRequest()) throws -> MessagePage {
        let limit = Self.normalizedLimit(request.limit)
        let sql: String
        if request.before == nil {
            sql = "SELECT id, role, text, created_at, attachments_json, delivery_status, delivery_error, reasoning_text, tool_activities_json, reply_to_message_id, reactions_json, transcript_cards_json, ordinal FROM messages WHERE conversation_id = ? ORDER BY ordinal DESC, id DESC LIMIT ?"
        } else {
            sql = "SELECT id, role, text, created_at, attachments_json, delivery_status, delivery_error, reasoning_text, tool_activities_json, reply_to_message_id, reactions_json, transcript_cards_json, ordinal FROM messages WHERE conversation_id = ? AND (ordinal < ? OR (ordinal = ? AND id < ?)) ORDER BY ordinal DESC, id DESC LIMIT ?"
        }
        let statement = try database.prepare(sql, operation: "page messages")
        try statement.bind(conversationID.uuidString, at: 1)
        if let cursor = request.before {
            try statement.bind(cursor.ordinal, at: 2)
            try statement.bind(cursor.ordinal, at: 3)
            try statement.bind(cursor.id.uuidString, at: 4)
            try statement.bind(limit + 1, at: 5)
        } else {
            try statement.bind(limit + 1, at: 2)
        }

        var rows: [(ordinal: Int, message: ChatMessage)] = []
        while try statement.step() == SQLITE_ROW {
            rows.append((statement.int(12), try Self.decodeMessage(statement)))
        }
        let hasMore = rows.count > limit
        if hasMore { rows.removeLast() }
        let nextCursor = hasMore ? rows.last.map { MessageCursor(ordinal: $0.ordinal, id: $0.message.id) } : nil
        return MessagePage(fence: request.fence, items: rows.reversed().map(\.message), nextCursor: nextCursor, hasMore: hasMore)
    }

    public func conversation(id: UUID) throws -> Conversation? {
        try load().first { $0.id == id }
    }

    public func upsert(_ conversation: Conversation) throws {
        var values = try load()
        if let index = values.firstIndex(where: { $0.id == conversation.id }) { values[index] = conversation }
        else { values.append(conversation) }
        try save(values)
    }

    public func delete(id: UUID) throws {
        try save(load().filter { $0.id != id })
    }

    public func save(_ values: [Conversation]) throws {
        try database.transaction("save conversations") {
            let keep = Set(values.map { $0.id.uuidString })
            let existing = try database.prepare("SELECT id FROM conversations", operation: "list conversations for pruning")
            var remove: [String] = []
            while try existing.step() == SQLITE_ROW { let id = existing.text(0); if !keep.contains(id) { remove.append(id) } }
            let delete = try database.prepare("DELETE FROM conversations WHERE id = ?", operation: "delete conversation")
            for id in remove { try delete.bind(id, at: 1); _ = try delete.step(); delete.reset() }

            let upsert = try database.prepare("INSERT INTO conversations(id,title,provider_id,model_id,updated_at,hidden_at,reasoning_effort) VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,provider_id=excluded.provider_id,model_id=excluded.model_id,updated_at=excluded.updated_at,hidden_at=excluded.hidden_at,reasoning_effort=excluded.reasoning_effort", operation: "upsert conversation")
            let loadNextOrdinal = try database.prepare("SELECT next_message_ordinal FROM conversations WHERE id = ?", operation: "load next message ordinal")
            let storeNextOrdinal = try database.prepare("UPDATE conversations SET next_message_ordinal = ? WHERE id = ?", operation: "store next message ordinal")
            let existingOrdinals = try database.prepare("SELECT id, ordinal FROM messages WHERE conversation_id = ? ORDER BY ordinal", operation: "load stable message ordinals")
            let clearMessages = try database.prepare("DELETE FROM messages WHERE conversation_id = ?", operation: "replace messages")
            let insertMessage = try database.prepare("INSERT INTO messages(id,conversation_id,ordinal,role,text,created_at,attachments_json,delivery_status,delivery_error,reasoning_text,tool_activities_json,reply_to_message_id,reactions_json,transcript_cards_json) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)", operation: "insert message")
            let clearSearch = try database.prepare("DELETE FROM conversation_search WHERE conversation_id = ?", operation: "replace search document")
            let insertSearch = try database.prepare("INSERT INTO conversation_search(conversation_id,content) VALUES(?,?)", operation: "index conversation")
            let clearMessageSearch = try database.prepare("DELETE FROM message_search WHERE conversation_id = ?", operation: "replace message search documents")
            let insertMessageSearch = try database.prepare("INSERT INTO message_search(conversation_id,message_id,role,timestamp,body) VALUES(?,?,?,?,?)", operation: "index message")
            let clearMediaSearch = try database.prepare("DELETE FROM media_search WHERE conversation_id = ?", operation: "replace media search documents")
            let insertMediaSearch = try database.prepare("INSERT INTO media_search(conversation_id,message_id,attachment_id,name,mime_type,kind,timestamp,width,height) VALUES(?,?,?,?,?,?,?,?,?)", operation: "index attachment")
            let clearMediaFTS = try database.prepare("DELETE FROM media_search_fts WHERE conversation_id = ?", operation: "replace media full-text documents")
            let insertMediaFTS = try database.prepare("INSERT INTO media_search_fts(conversation_id,message_id,attachment_id,content) VALUES(?,?,?,?)", operation: "full-text index attachment")
            try database.execute("UPDATE global_search_state SET ready = 0 WHERE singleton = 1", operation: "mark global search update in progress")
            for conversation in values {
                try upsert.bind(conversation.id.uuidString, at: 1); try upsert.bind(conversation.title, at: 2); try upsert.bind(conversation.providerID.rawValue, at: 3); try upsert.bind(conversation.modelID.rawValue, at: 4); try upsert.bind(conversation.updatedAt.timeIntervalSince1970, at: 5); try upsert.bind(conversation.hiddenAt?.timeIntervalSince1970 ?? 0, at: 6); try upsert.bind(conversation.reasoningEffort.rawValue, at: 7); _ = try upsert.step(); upsert.reset()
                try loadNextOrdinal.bind(conversation.id.uuidString, at: 1)
                guard try loadNextOrdinal.step() == SQLITE_ROW else {
                    throw PersistenceError.corrupt(operation: "load next message ordinal")
                }
                var nextOrdinal = loadNextOrdinal.int(0)
                loadNextOrdinal.reset()
                try existingOrdinals.bind(conversation.id.uuidString, at: 1)
                var ordinalByMessageID: [UUID: Int] = [:]
                while try existingOrdinals.step() == SQLITE_ROW {
                    if let messageID = UUID(uuidString: existingOrdinals.text(0)) {
                        let ordinal = existingOrdinals.int(1)
                        ordinalByMessageID[messageID] = ordinal
                        nextOrdinal = max(nextOrdinal, ordinal + 1)
                    }
                }
                existingOrdinals.reset()
                try clearMessages.bind(conversation.id.uuidString, at: 1); _ = try clearMessages.step(); clearMessages.reset()
                try clearMessageSearch.bind(conversation.id.uuidString, at: 1); _ = try clearMessageSearch.step(); clearMessageSearch.reset()
                try clearMediaSearch.bind(conversation.id.uuidString, at: 1); _ = try clearMediaSearch.step(); clearMediaSearch.reset()
                try clearMediaFTS.bind(conversation.id.uuidString, at: 1); _ = try clearMediaFTS.step(); clearMediaFTS.reset()
                for message in conversation.messages {
                    let ordinal: Int
                    if let stableOrdinal = ordinalByMessageID[message.id] {
                        ordinal = stableOrdinal
                    } else {
                        ordinal = nextOrdinal
                        nextOrdinal += 1
                    }
                    let attachments = try JSONEncoder().encode(message.attachments)
                    let activities = try JSONEncoder().encode(message.toolActivities)
                    let reactions = try JSONEncoder().encode(message.reactions)
                    let transcriptCards = try JSONEncoder().encode(message.transcriptCards)
                    try insertMessage.bind(message.id.uuidString, at: 1); try insertMessage.bind(conversation.id.uuidString, at: 2); try insertMessage.bind(ordinal, at: 3); try insertMessage.bind(message.role.rawValue, at: 4); try insertMessage.bind(message.text, at: 5); try insertMessage.bind(message.createdAt.timeIntervalSince1970, at: 6); try insertMessage.bind(String(decoding: attachments, as: UTF8.self), at: 7); try insertMessage.bind(message.deliveryStatus.rawValue, at: 8); try insertMessage.bind(message.deliveryError ?? "", at: 9); try insertMessage.bind(message.reasoningText, at: 10); try insertMessage.bind(String(decoding: activities, as: UTF8.self), at: 11); try insertMessage.bind(message.replyToMessageID?.uuidString ?? "", at: 12); try insertMessage.bind(String(decoding: reactions, as: UTF8.self), at: 13); try insertMessage.bind(String(decoding: transcriptCards, as: UTF8.self), at: 14); _ = try insertMessage.step(); insertMessage.reset()
                    try insertMessageSearch.bind(conversation.id.uuidString, at: 1); try insertMessageSearch.bind(message.id.uuidString, at: 2); try insertMessageSearch.bind(message.role.rawValue, at: 3); try insertMessageSearch.bind(message.createdAt.timeIntervalSince1970, at: 4); try insertMessageSearch.bind(GlobalSearchQuery.boundedBody(message.text), at: 5); _ = try insertMessageSearch.step(); insertMessageSearch.reset()
                    var indexedAttachmentIDs: Set<String> = []
                    for attachment in message.attachments where indexedAttachmentIDs.insert(attachment.id).inserted {
                        try insertMediaSearch.bind(conversation.id.uuidString, at: 1); try insertMediaSearch.bind(message.id.uuidString, at: 2); try insertMediaSearch.bind(attachment.id, at: 3); try insertMediaSearch.bind(attachment.filename, at: 4); try insertMediaSearch.bind(attachment.mimeType, at: 5); try insertMediaSearch.bind(attachment.kind.rawValue, at: 6); try insertMediaSearch.bind(attachment.createdAt.timeIntervalSince1970, at: 7); try insertMediaSearch.bind(0, at: 8); try insertMediaSearch.bind(0, at: 9); _ = try insertMediaSearch.step(); insertMediaSearch.reset()
                        try insertMediaFTS.bind(conversation.id.uuidString, at: 1); try insertMediaFTS.bind(message.id.uuidString, at: 2); try insertMediaFTS.bind(attachment.id, at: 3); try insertMediaFTS.bind(attachment.filename + " " + attachment.mimeType + " " + attachment.kind.rawValue, at: 4); _ = try insertMediaFTS.step(); insertMediaFTS.reset()
                    }
                }
                try storeNextOrdinal.bind(nextOrdinal, at: 1); try storeNextOrdinal.bind(conversation.id.uuidString, at: 2); _ = try storeNextOrdinal.step(); storeNextOrdinal.reset()
                try clearSearch.bind(conversation.id.uuidString, at: 1); _ = try clearSearch.step(); clearSearch.reset()
                try insertSearch.bind(conversation.id.uuidString, at: 1); try insertSearch.bind(([conversation.title] + conversation.messages.map(\.text)).joined(separator: "\n"), at: 2); _ = try insertSearch.step(); insertSearch.reset()
            }
            try database.execute("DELETE FROM message_search WHERE conversation_id NOT IN (SELECT id FROM conversations)", operation: "prune message search documents")
            try database.execute("DELETE FROM media_search WHERE conversation_id NOT IN (SELECT id FROM conversations)", operation: "prune media search documents")
            try database.execute("DELETE FROM media_search_fts WHERE conversation_id NOT IN (SELECT id FROM conversations)", operation: "prune media full-text documents")
            try database.execute("UPDATE global_search_state SET ready = 1, generation = generation + 1 WHERE singleton = 1", operation: "publish global search update")
        }
    }

    public func globalSearchReadiness() throws -> GlobalSearchIndexReadiness {
        let statement = try database.prepare("SELECT ready FROM global_search_state WHERE singleton = 1", operation: "read global search readiness")
        guard try statement.step() == SQLITE_ROW else { return .notReady }
        return statement.int(0) == 1 ? .ready : .notReady
    }

    public func searchMessages(_ query: String, includeHidden: Bool = false) throws -> [GlobalMessageSearchHit] {
        guard try globalSearchReadiness() == .ready else { throw PersistenceError.recoveryRequired("global message index is not ready") }
        let match = GlobalSearchQuery.fts(query)
        guard !match.isEmpty else { return [] }
        let hiddenClause = includeHidden ? "" : "AND c.hidden_at = 0"
        let sql = """
        WITH matched AS (
          SELECT ms.conversation_id, ms.message_id, ms.role, ms.timestamp, ms.body,
                 bm25(message_search) AS score
          FROM message_search ms JOIN conversations c ON c.id = ms.conversation_id
          WHERE message_search MATCH ? \(hiddenClause)
        ), capped AS (
          SELECT *, ROW_NUMBER() OVER (PARTITION BY conversation_id ORDER BY score ASC, timestamp DESC, message_id DESC) AS conversation_rank
          FROM matched
        )
        SELECT conversation_id,message_id,role,timestamp,body FROM capped
        WHERE conversation_rank <= ?
        ORDER BY score ASC,timestamp DESC,message_id DESC LIMIT ?
        """
        let statement = try database.prepare(sql, operation: "global message search")
        try statement.bind(match, at: 1)
        try statement.bind(GlobalSearchLimits.maximumPerConversation, at: 2)
        try statement.bind(GlobalSearchLimits.maximumResults, at: 3)
        let terms = GlobalSearchQuery.terms(query)
        var result: [GlobalMessageSearchHit] = []
        while try statement.step() == SQLITE_ROW {
            guard let conversationID = UUID(uuidString: statement.text(0)),
                  let messageID = UUID(uuidString: statement.text(1)),
                  let role = MessageRole(rawValue: statement.text(2)) else {
                throw PersistenceError.corrupt(operation: "decode global message search hit")
            }
            result.append(.init(conversationID: conversationID, messageID: messageID, role: role, timestamp: Date(timeIntervalSince1970: statement.double(3)), snippet: GlobalSearchQuery.snippet(body: statement.text(4), terms: terms)))
        }
        return result
    }

    /// Bounded scan of authoritative rows used only when the derived FTS index
    /// is missing, not ready, corrupt, or rejects a query.
    public func linearMessageSearch(_ query: String, includeHidden: Bool = false) throws -> [GlobalMessageSearchHit] {
        let terms = GlobalSearchQuery.terms(query).map { $0.lowercased() }
        guard !terms.isEmpty else { return [] }
        let hiddenClause = includeHidden ? "" : "AND c.hidden_at = 0"
        let statement = try database.prepare("SELECT m.conversation_id,m.id,m.role,m.created_at,m.text FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.conversation_id IN (SELECT id FROM conversations ORDER BY updated_at DESC,id DESC LIMIT ?) \(hiddenClause) ORDER BY m.created_at DESC,m.id DESC LIMIT ?", operation: "bounded linear message search")
        try statement.bind(GlobalSearchLimits.maximumFallbackConversations, at: 1)
        try statement.bind(GlobalSearchLimits.maximumFallbackMessages, at: 2)
        var perConversation: [UUID: Int] = [:]
        var result: [GlobalMessageSearchHit] = []
        while try statement.step() == SQLITE_ROW, result.count < GlobalSearchLimits.maximumResults {
            guard let conversationID = UUID(uuidString: statement.text(0)), let messageID = UUID(uuidString: statement.text(1)), let role = MessageRole(rawValue: statement.text(2)) else { continue }
            guard perConversation[conversationID, default: 0] < GlobalSearchLimits.maximumPerConversation else { continue }
            let body = GlobalSearchQuery.boundedBody(statement.text(4))
            let lower = body.lowercased()
            guard terms.allSatisfy({ lower.contains($0) }) else { continue }
            perConversation[conversationID, default: 0] += 1
            result.append(.init(conversationID: conversationID, messageID: messageID, role: role, timestamp: Date(timeIntervalSince1970: statement.double(3)), snippet: GlobalSearchQuery.snippet(body: body, terms: terms)))
        }
        return result
    }

    public func searchMedia(_ query: String, includeHidden: Bool = false) throws -> [GlobalMediaSearchHit] {
        guard try globalSearchReadiness() == .ready else { throw PersistenceError.recoveryRequired("global media index is not ready") }
        let terms = GlobalSearchQuery.terms(query)
        let hiddenClause = includeHidden ? "" : "AND c.hidden_at = 0"
        let from: String
        let predicate: String
        if terms.isEmpty {
            from = "media_search ms JOIN conversations c ON c.id=ms.conversation_id"
            predicate = "1=1"
        } else {
            from = "media_search_fts mf JOIN media_search ms ON ms.conversation_id=mf.conversation_id AND ms.message_id=mf.message_id AND ms.attachment_id=mf.attachment_id JOIN conversations c ON c.id=ms.conversation_id"
            predicate = "media_search_fts MATCH ?"
        }
        let sql = """
        WITH matched AS (
          SELECT ms.conversation_id,ms.message_id,ms.attachment_id,ms.name,ms.mime_type,ms.kind,ms.timestamp,ms.width,ms.height
          FROM \(from) WHERE \(predicate) \(hiddenClause)
        ), capped AS (
          SELECT *,ROW_NUMBER() OVER (PARTITION BY conversation_id ORDER BY timestamp DESC,message_id DESC,attachment_id ASC) AS conversation_rank FROM matched
        )
        SELECT conversation_id,message_id,attachment_id,name,mime_type,kind,timestamp,width,height FROM capped
        WHERE conversation_rank <= ? ORDER BY timestamp DESC,message_id DESC,attachment_id ASC LIMIT ?
        """
        let statement = try database.prepare(sql, operation: "global media search")
        var binding: Int32 = 1
        if !terms.isEmpty { try statement.bind(GlobalSearchQuery.fts(query), at: binding); binding += 1 }
        try statement.bind(GlobalSearchLimits.maximumPerConversation, at: binding); binding += 1
        try statement.bind(GlobalSearchLimits.maximumResults, at: binding)
        var result: [GlobalMediaSearchHit] = []
        while try statement.step() == SQLITE_ROW {
            guard let conversationID = UUID(uuidString: statement.text(0)), let messageID = UUID(uuidString: statement.text(1)), let kind = AttachmentKind(rawValue: statement.text(5)) else { throw PersistenceError.corrupt(operation: "decode global media search hit") }
            let width = statement.int(7), height = statement.int(8)
            result.append(.init(conversationID: conversationID, messageID: messageID, attachmentID: statement.text(2), name: statement.text(3), mimeType: statement.text(4), kind: kind, timestamp: Date(timeIntervalSince1970: statement.double(6)), width: width > 0 ? width : nil, height: height > 0 ? height : nil))
        }
        return result
    }

    public func search(_ query: String, limit: Int = 50) throws -> [Conversation] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
        guard !terms.isEmpty else { return try load() }
        let statement = try database.prepare("SELECT conversation_id FROM conversation_search WHERE conversation_search MATCH ? ORDER BY rank LIMIT ?", operation: "search conversations")
        try statement.bind(terms, at: 1); try statement.bind(max(1, limit), at: 2)
        var ids: [String] = []
        while try statement.step() == SQLITE_ROW { ids.append(statement.text(0)) }
        let byID = Dictionary(uniqueKeysWithValues: try load().map { ($0.id.uuidString, $0) })
        return ids.compactMap { byID[$0] }
    }

    public func rebuildSearchIndex() throws -> PersistenceRecoveryReport {
        try ConversationRecovery.manualRebuild(database: database)
    }

    static func migrate(_ database: SQLiteDatabase) throws {
        do {
            try database.execute("CREATE TABLE IF NOT EXISTS schema_version(singleton INTEGER PRIMARY KEY CHECK(singleton=1), version INTEGER NOT NULL)", operation: "create schema version")
            try database.execute("INSERT OR IGNORE INTO schema_version(singleton,version) VALUES(1,0)", operation: "seed schema version")
            let version = try schemaVersionSync(database)
            guard version <= Self.currentSchemaVersion else { throw PersistenceError.migration(version: version, message: "database is newer than this app") }
            if version < 1 {
                try database.transaction("migration 1") {
                    try database.execute("CREATE TABLE conversations(id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, provider_id TEXT NOT NULL, model_id TEXT NOT NULL, updated_at REAL NOT NULL) STRICT", operation: "migration 1 conversations")
                    try database.execute("CREATE TABLE messages(id TEXT PRIMARY KEY NOT NULL, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE, ordinal INTEGER NOT NULL, role TEXT NOT NULL CHECK(role IN ('system','user','assistant','tool')), text TEXT NOT NULL, created_at REAL NOT NULL, UNIQUE(conversation_id,ordinal)) STRICT", operation: "migration 1 messages")
                    try database.execute("CREATE INDEX idx_conversations_updated_at ON conversations(updated_at DESC)", operation: "migration 1 conversation index")
                    try database.execute("CREATE INDEX idx_messages_conversation_ordinal ON messages(conversation_id,ordinal)", operation: "migration 1 message index")
                    try database.execute("CREATE VIRTUAL TABLE conversation_search USING fts5(conversation_id UNINDEXED, content, tokenize='unicode61')", operation: "migration 1 search index")
                    try database.execute("UPDATE schema_version SET version=1 WHERE singleton=1", operation: "finish migration 1")
                }
            }
            if version < 2 {
                try database.transaction("migration 2") {
                    try database.execute("ALTER TABLE messages ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]'", operation: "migration 2 attachment metadata")
                    try database.execute("UPDATE schema_version SET version=2 WHERE singleton=1", operation: "finish migration 2")
                }
            }
            if version < 3 {
                try database.transaction("migration 3") {
                    try database.execute("ALTER TABLE messages ADD COLUMN delivery_status TEXT NOT NULL DEFAULT 'succeeded' CHECK(delivery_status IN ('queued','streaming','succeeded','failed','cancelled'))", operation: "migration 3 delivery status")
                    try database.execute("ALTER TABLE messages ADD COLUMN delivery_error TEXT", operation: "migration 3 delivery error")
                    try database.execute("ALTER TABLE messages ADD COLUMN reasoning_text TEXT NOT NULL DEFAULT ''", operation: "migration 3 reasoning")
                    try database.execute("ALTER TABLE messages ADD COLUMN tool_activities_json TEXT NOT NULL DEFAULT '[]'", operation: "migration 3 tool activity")
                    try database.execute("ALTER TABLE messages ADD COLUMN reply_to_message_id TEXT", operation: "migration 3 reply reference")
                    try database.execute("ALTER TABLE messages ADD COLUMN reactions_json TEXT NOT NULL DEFAULT '[]'", operation: "migration 3 reactions")
                    try database.execute("UPDATE schema_version SET version=3 WHERE singleton=1", operation: "finish migration 3")
                }
            }
            if version < 4 {
                try database.transaction("migration 4") {
                    try database.execute("ALTER TABLE conversations ADD COLUMN hidden_at REAL NOT NULL DEFAULT 0", operation: "migration 4 hidden chats")
                    try database.execute("CREATE INDEX idx_conversations_hidden_at ON conversations(hidden_at, updated_at DESC)", operation: "migration 4 hidden chat index")
                    try database.execute("UPDATE schema_version SET version=4 WHERE singleton=1", operation: "finish migration 4")
                }
            }
            if version < 5 {
                try database.transaction("migration 5") {
                    try database.execute("CREATE INDEX idx_conversations_page ON conversations(updated_at DESC, id DESC)", operation: "migration 5 conversation page index")
                    try database.execute("UPDATE schema_version SET version=5 WHERE singleton=1", operation: "finish migration 5")
                }
            }
            if version < 6 {
                try database.transaction("migration 6") {
                    try database.execute("ALTER TABLE conversations ADD COLUMN next_message_ordinal INTEGER NOT NULL DEFAULT 0", operation: "migration 6 message ordinal high-water mark")
                    try database.execute("UPDATE conversations SET next_message_ordinal = COALESCE((SELECT MAX(ordinal) + 1 FROM messages WHERE messages.conversation_id = conversations.id), 0)", operation: "migration 6 initialize message ordinals")
                    try database.execute("CREATE INDEX idx_messages_page ON messages(conversation_id, ordinal DESC, id DESC)", operation: "migration 6 message page index")
                    try database.execute("UPDATE schema_version SET version=6 WHERE singleton=1", operation: "finish migration 6")
                }
            }
            if version < 7 {
                try database.transaction("migration 7") {
                    try database.execute("ALTER TABLE messages ADD COLUMN transcript_cards_json TEXT NOT NULL DEFAULT '[]'", operation: "migration 7 transcript cards")
                    try database.execute("UPDATE schema_version SET version=7 WHERE singleton=1", operation: "finish migration 7")
                }
            }
            if version < 8 {
                try database.transaction("migration 8") {
                    try database.execute("ALTER TABLE conversations ADD COLUMN reasoning_effort TEXT NOT NULL DEFAULT 'disabled' CHECK(reasoning_effort IN ('disabled','minimal','low','medium','high','xhigh'))", operation: "migration 8 conversation reasoning effort")
                    try database.execute("UPDATE schema_version SET version=8 WHERE singleton=1", operation: "finish migration 8")
                }
            }
            if version < 9 {
                try database.transaction("migration 9") {
                    try database.execute("CREATE VIRTUAL TABLE message_search USING fts5(conversation_id UNINDEXED,message_id UNINDEXED,role UNINDEXED,timestamp UNINDEXED,body,tokenize='unicode61')", operation: "migration 9 message search")
                    try database.execute("CREATE TABLE media_search(conversation_id TEXT NOT NULL,message_id TEXT NOT NULL,attachment_id TEXT NOT NULL,name TEXT NOT NULL,mime_type TEXT NOT NULL,kind TEXT NOT NULL,timestamp REAL NOT NULL,width INTEGER NOT NULL DEFAULT 0,height INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(conversation_id,message_id,attachment_id)) STRICT", operation: "migration 9 media search")
                    try database.execute("CREATE VIRTUAL TABLE media_search_fts USING fts5(conversation_id UNINDEXED,message_id UNINDEXED,attachment_id UNINDEXED,content,tokenize='unicode61')", operation: "migration 9 media full-text search")
                    try database.execute("CREATE INDEX idx_media_search_recency ON media_search(timestamp DESC,message_id DESC)", operation: "migration 9 media recency")
                    try database.execute("CREATE TABLE global_search_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),ready INTEGER NOT NULL CHECK(ready IN (0,1)),generation INTEGER NOT NULL) STRICT", operation: "migration 9 global search state")
                    try database.execute("INSERT INTO global_search_state(singleton,ready,generation) VALUES(1,0,0)", operation: "migration 9 seed global search state")
                    try database.execute("UPDATE schema_version SET version=9 WHERE singleton=1", operation: "finish migration 9")
                }
            }
        } catch let error as PersistenceError { throw error }
        catch { throw PersistenceError.migration(version: 1, message: error.localizedDescription) }
    }

    static func reconcileGlobalSearchIndexes(_ database: SQLiteDatabase) throws {
        let canonicalMessages = try count(database, sql: "SELECT COUNT(*) FROM messages", operation: "count canonical messages")
        let indexedMessages = (try? count(database, sql: "SELECT COUNT(*) FROM message_search", operation: "count indexed messages")) ?? -1
        let canonicalMedia = try countAttachmentRows(database)
        let indexedMedia = (try? count(database, sql: "SELECT COUNT(*) FROM media_search", operation: "count indexed media")) ?? -1
        let indexedMediaFTS = (try? count(database, sql: "SELECT COUNT(*) FROM media_search_fts", operation: "count full-text indexed media")) ?? -1
        let readiness = (try? count(database, sql: "SELECT ready FROM global_search_state WHERE singleton=1", operation: "read index readiness")) ?? 0
        guard readiness == 1, canonicalMessages == indexedMessages, canonicalMedia == indexedMedia, canonicalMedia == indexedMediaFTS else {
            try ConversationRecovery.rebuildIndexes(database)
            return
        }
    }

    private static func count(_ database: SQLiteDatabase, sql: String, operation: String) throws -> Int {
        let statement = try database.prepare(sql, operation: operation)
        return try statement.step() == SQLITE_ROW ? statement.int(0) : 0
    }

    private static func countAttachmentRows(_ database: SQLiteDatabase) throws -> Int {
        let statement = try database.prepare("SELECT attachments_json FROM messages", operation: "count canonical attachments")
        var count = 0
        while try statement.step() == SQLITE_ROW {
            let attachments: [AttachmentMetadata] = try decodeJSON(statement.text(0), table: "messages", row: "search-reconcile", field: "attachments_json")
            count += Set(attachments.map(\.id)).count
        }
        return count
    }

    private static func schemaVersionSync(_ database: SQLiteDatabase) throws -> Int {
        let statement = try database.prepare("SELECT version FROM schema_version WHERE singleton=1", operation: "read schema version")
        return try statement.step() == SQLITE_ROW ? statement.int(0) : 0
    }

    private static func normalizedLimit(_ requested: Int) -> Int {
        min(max(requested, 1), 500)
    }

    static func decodeConversationMetadata(_ statement: SQLiteStatement) throws -> Conversation {
        guard let id = UUID(uuidString: statement.text(0)) else {
            throw PersistenceError.corrupt(operation: "decode conversation id")
        }
        let updatedAt = statement.double(4), hiddenAt = statement.double(5)
        guard updatedAt.isFinite, hiddenAt.isFinite else { throw PersistenceError.invalidData(table: "conversations", row: id.uuidString, field: "timestamp") }
        guard let reasoningEffort = ReasoningEffort(rawValue: statement.text(6)) else {
            throw PersistenceError.invalidData(table: "conversations", row: id.uuidString, field: "reasoning_effort")
        }
        return Conversation(
            id: id,
            title: statement.text(1),
            providerID: ProviderID(rawValue: statement.text(2)),
            modelID: ModelID(rawValue: statement.text(3)),
            reasoningEffort: reasoningEffort,
            messages: [],
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            hiddenAt: hiddenAt > 0 ? Date(timeIntervalSince1970: hiddenAt) : nil
        )
    }

    static func decodeMessage(_ statement: SQLiteStatement) throws -> ChatMessage {
        let rawID = statement.text(0)
        guard let id = UUID(uuidString: rawID) else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "id") }
        guard let role = MessageRole(rawValue: statement.text(1)) else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "role") }
        let attachments: [AttachmentMetadata] = try decodeJSON(statement.text(4), table: "messages", row: rawID, field: "attachments_json")
        guard let delivery = MessageDeliveryStatus(rawValue: statement.text(5)) else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "delivery_status") }
        let activities: [ToolActivity] = try decodeJSON(statement.text(8), table: "messages", row: rawID, field: "tool_activities_json")
        let rawReplyID = statement.text(9)
        let replyID: UUID?
        if rawReplyID.isEmpty { replyID = nil }
        else if let value = UUID(uuidString: rawReplyID) { replyID = value }
        else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "reply_to_message_id") }
        let reactions: [ChatReaction] = try decodeJSON(statement.text(10), table: "messages", row: rawID, field: "reactions_json")
        let transcriptCards: [TranscriptCard] = try decodeJSON(statement.text(11), table: "messages", row: rawID, field: "transcript_cards_json")
        let createdAt = statement.double(3)
        guard createdAt.isFinite else { throw PersistenceError.invalidData(table: "messages", row: rawID, field: "created_at") }
        return ChatMessage(
            id: id,
            role: role,
            text: statement.text(2),
            createdAt: Date(timeIntervalSince1970: createdAt),
            attachments: attachments,
            deliveryStatus: delivery,
            deliveryError: statement.text(6).isEmpty ? nil : statement.text(6),
            reasoningText: statement.text(7),
            toolActivities: activities,
            transcriptCards: transcriptCards,
            replyToMessageID: replyID,
            reactions: reactions
        )
    }

    private static func decodeJSON<T: Decodable>(_ value: String, table: String, row: String, field: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(value.utf8)) }
        catch { throw PersistenceError.invalidData(table: table, row: row, field: field) }
    }
}
