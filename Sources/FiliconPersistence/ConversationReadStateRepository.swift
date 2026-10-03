import Foundation
import CSQLite
import FiliconDomain

extension ConversationRepository {
    public func unreadState(conversationID: UUID) throws -> ConversationUnreadState? {
        guard try unreadBinding(conversationID).exists else { return nil }
        return try requireUnreadState(conversationID)
    }

    public func unreadState(conversationID: UUID, expectedBinding: DirectConversationAgentBinding?) throws -> ConversationUnreadState? {
        try database.transaction("load owned conversation read state") {
            let owner = try unreadBinding(conversationID)
            guard owner.exists else { return nil }
            guard owner.binding == expectedBinding else { throw CancellationError() }
            return try requireUnreadState(conversationID)
        }
    }

    /// The exact binding (including an explicitly unbound chat) is rechecked
    /// inside the final transaction. A caller may additionally fence its UI life.
    @discardableResult
    public func updateReadState(conversationID: UUID, action: ConversationReadAction, at: Date,
                               expectedBinding: DirectConversationAgentBinding?,
                               commit: ConversationCommitGuard = { try $0() }) throws -> ConversationUnreadState {
        guard at.timeIntervalSince1970.isFinite else {
            throw PersistenceError.invalidData(table: "conversation_read_state", row: conversationID.uuidString, field: "timestamp")
        }
        var result: ConversationUnreadState?
        try commit {
            result = try database.transaction("update conversation read state") {
                let current = try unreadBinding(conversationID)
                guard current.exists, current.binding == expectedBinding else { throw CancellationError() }
                var state = try requireUnreadState(conversationID)
                switch action {
                case .viewed(let preserve): state.markViewed(at: at, preserveManualUnread: preserve)
                case .read: state.markRead(at: at)
                case .unread:
                    let message = try database.prepare("SELECT MAX(created_at) FROM messages WHERE conversation_id=?", operation: "resolve unread divider")
                    try message.bind(conversationID.uuidString, at: 1)
                    let newest = try message.step() == SQLITE_ROW ? Date(timeIntervalSince1970: message.double(0)) : nil
                    state.markUnread(at: at, newestMessageAt: newest)
                }
                try writeUnreadState(state, conversationID: conversationID)
                // SQLite stores Unix seconds while Foundation Date internally
                // uses a different epoch. Return the durable rounded value,
                // not a subtly different pre-serialization timestamp.
                return try requireUnreadState(conversationID)
            }
        }
        guard let result else { throw CancellationError() }
        return result
    }

    func unreadBinding(_ id: UUID) throws -> (exists: Bool, binding: DirectConversationAgentBinding?) {
        let row = try database.prepare("SELECT agent_binding_json FROM conversations WHERE id=?", operation: "resolve unread owner")
        try row.bind(id.uuidString, at: 1)
        guard try row.step() == SQLITE_ROW else { return (false, nil) }
        let binding = try JSONDecoder().decode(DirectConversationAgentBinding?.self, from: Data(row.text(0).utf8))
        return (true, binding)
    }

    func readUnreadState(_ id: UUID) throws -> ConversationUnreadState? {
        let row = try database.prepare("SELECT last_activity_at,last_viewed_at,manual_unread,unread_count FROM conversation_read_state WHERE conversation_id=?", operation: "load conversation read state")
        try row.bind(id.uuidString, at: 1)
        return try row.step() == SQLITE_ROW ? Self.decodeUnreadState(row, conversationID: id) : nil
    }

    func requireUnreadState(_ id: UUID) throws -> ConversationUnreadState {
        guard let state = try readUnreadState(id) else {
            throw PersistenceError.invalidData(table: "conversation_read_state", row: id.uuidString, field: "missing state")
        }
        return state
    }

    static func decodeUnreadState(_ row: SQLiteStatement, conversationID: UUID) throws -> ConversationUnreadState {
        guard row.double(0).isFinite, row.double(1).isFinite, [0, 1].contains(row.int(2)), row.int(3) >= 0 else {
            throw PersistenceError.invalidData(table: "conversation_read_state", row: conversationID.uuidString, field: "state")
        }
        return .init(lastActivityAt: Date(timeIntervalSince1970: row.double(0)),
            lastViewedAt: Date(timeIntervalSince1970: row.double(1)), isManuallyUnread: row.int(2) == 1, unreadCount: row.int(3))
    }

    func writeUnreadState(_ state: ConversationUnreadState, conversationID: UUID) throws {
        try Self.writeUnreadState(state, conversationID: conversationID, database: database)
    }

    /// Runs inside the same save transaction as the canonical message rows.
    func recordSavedConversationActivity(_ value: Conversation, previousBinding: DirectConversationAgentBinding?,
                                         existed: Bool, previousMessageIDs: Set<UUID>, at: Date,
                                         historicalImport: Bool) throws {
        let rebound = existed && previousBinding != value.agentBinding
        // Only migration, explicit owner replacement or a new chat may seed an
        // empty state. An ordinary content save cannot repair unknown authority.
        if existed && !rebound { _ = try requireUnreadState(value.id) }
        if rebound {
            for table in ["conversation_read_state", "conversation_activity_receipts"] {
                let clear = try database.prepare("DELETE FROM \(table) WHERE conversation_id=?", operation: "reset rebound unread owner")
                try clear.bind(value.id.uuidString, at: 1); _ = try clear.step()
            }
        }
        let seed = try database.prepare("INSERT OR IGNORE INTO conversation_read_state(conversation_id) VALUES(?)", operation: "initialize conversation unread")
        try seed.bind(value.id.uuidString, at: 1); _ = try seed.step()
        let insert = try database.prepare("INSERT OR IGNORE INTO conversation_activity_receipts(conversation_id,message_id,activity_at) VALUES(?,?,?)", operation: "record conversation activity receipt")
        // Retain IDs even after message deletion. A snapshot restore is not a
        // newly published event. Rebinding cannot transfer the old owner's rows.
        let historicalIDs = historicalImport
            ? Set(value.messages.filter { $0.raisesConversationActivity(conversationID: value.id, binding: value.agentBinding) }.map(\.id))
            : (rebound ? previousMessageIDs : [])
        for id in historicalIDs {
            try insert.bind(value.id.uuidString, at: 1); try insert.bind(id.uuidString, at: 2)
            try insert.bind(at.timeIntervalSince1970, at: 3); _ = try insert.step(); insert.reset()
        }
        var count = 0
        for message in value.messages where message.raisesConversationActivity(conversationID: value.id, binding: value.agentBinding) {
            try insert.bind(value.id.uuidString, at: 1); try insert.bind(message.id.uuidString, at: 2)
            try insert.bind(at.timeIntervalSince1970, at: 3); _ = try insert.step()
            if database.changes == 1 { count += 1 }
            insert.reset()
        }
        guard count > 0 else { return }
        var state = try requireUnreadState(value.id)
        if state.markActivity(at: at, count: count) { try writeUnreadState(state, conversationID: value.id) }
    }

    static func writeUnreadState(_ state: ConversationUnreadState, conversationID: UUID, database: SQLiteDatabase) throws {
        let row = try database.prepare("INSERT INTO conversation_read_state(conversation_id,last_activity_at,last_viewed_at,manual_unread,unread_count) VALUES(?,?,?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET last_activity_at=excluded.last_activity_at,last_viewed_at=excluded.last_viewed_at,manual_unread=excluded.manual_unread,unread_count=excluded.unread_count", operation: "save conversation read state")
        try row.bind(conversationID.uuidString, at: 1); try row.bind(state.lastActivityAt.timeIntervalSince1970, at: 2)
        try row.bind(state.lastViewedAt.timeIntervalSince1970, at: 3); try row.bind(state.isManuallyUnread ? 1 : 0, at: 4)
        try row.bind(state.unreadCount, at: 5); _ = try row.step()
    }

    /// Only used by trusted migration/import/recovery: historical rows are not
    /// new arrivals. Receipts are tombstones, not foreign keys to message rows.
    static func seedUnreadHistory(_ database: SQLiteDatabase) throws {
        try database.execute("INSERT OR IGNORE INTO conversation_read_state(conversation_id) SELECT id FROM conversations", operation: "seed unread history state")
        let messages = try database.prepare("SELECT id,role,text,created_at,attachments_json,delivery_status,delivery_error,reasoning_text,tool_activities_json,reply_to_message_id,reactions_json,transcript_cards_json,short_address,agent_message_source_json,remote_attachment_json,remote_images_json,image_gallery_layout_json,conversation_id FROM messages", operation: "seed unread history receipts")
        let bindingRow = try database.prepare("SELECT agent_binding_json FROM conversations WHERE id=?", operation: "resolve historical unread owner")
        let insert = try database.prepare("INSERT OR IGNORE INTO conversation_activity_receipts(conversation_id,message_id,activity_at) VALUES(?,?,?)", operation: "seed historical unread receipt")
        while try messages.step() == SQLITE_ROW {
            let message = try decodeMessage(messages), rawID = messages.text(17)
            guard let conversationID = UUID(uuidString: rawID) else {
                throw PersistenceError.invalidData(table: "messages", row: message.id.uuidString, field: "conversation_id")
            }
            try bindingRow.bind(rawID, at: 1)
            guard try bindingRow.step() == SQLITE_ROW else { bindingRow.reset(); continue }
            let binding = try JSONDecoder().decode(DirectConversationAgentBinding?.self, from: Data(bindingRow.text(0).utf8))
            bindingRow.reset()
            guard message.raisesConversationActivity(conversationID: conversationID, binding: binding) else { continue }
            try insert.bind(rawID, at: 1); try insert.bind(message.id.uuidString, at: 2)
            try insert.bind(message.createdAt.timeIntervalSince1970, at: 3); _ = try insert.step(); insert.reset()
        }
    }
}
