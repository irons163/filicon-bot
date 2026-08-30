import Foundation
import FiliconDomain
import CSQLite

public enum AttachmentIndexState: String, Sendable {
    case active
    case quarantinePending = "quarantine_pending"
    case quarantined
}

public struct AttachmentIndexBlob: Sendable, Equatable {
    public let id: String
    public let byteCount: Int64
    public let state: AttachmentIndexState
    public let quarantineAt: Date?
}

public struct AttachmentIndexUpload: Sendable, Equatable {
    public let token: UUID
    public let metadata: AttachmentMetadata
    public let stagedAt: Date
}

public struct AttachmentIndexReference: Sendable, Equatable, Hashable {
    public let blobID: String
    public let owner: AttachmentReferenceOwner

    public init(blobID: String, owner: AttachmentReferenceOwner) {
        self.blobID = blobID
        self.owner = owner
    }
}

/// A small SQLite authority for attachment reachability. File movement is
/// performed by AttachmentStore; transition states make every movement
/// replayable after a process or power failure.
public actor AttachmentReferenceRepository {
    private let database: SQLiteDatabase

    public init(databaseURL: URL) throws {
        database = try SQLiteDatabase(url: databaseURL)
        try database.configure()
        try database.execute("PRAGMA synchronous = FULL", operation: "configure attachment durability")
        try database.execute("CREATE TABLE IF NOT EXISTS attachment_blobs(id TEXT PRIMARY KEY NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count >= 0), state TEXT NOT NULL CHECK(state IN ('active','quarantine_pending','quarantined')), quarantine_at REAL) STRICT", operation: "create attachment blobs")
        try database.execute("CREATE TABLE IF NOT EXISTS attachment_uploads(token TEXT PRIMARY KEY NOT NULL, blob_id TEXT NOT NULL, filename TEXT NOT NULL, mime_type TEXT NOT NULL, byte_count INTEGER NOT NULL CHECK(byte_count >= 0), kind TEXT NOT NULL, created_at REAL NOT NULL, staged_at REAL NOT NULL) STRICT", operation: "create attachment uploads")
        try database.execute("CREATE TABLE IF NOT EXISTS attachment_references(blob_id TEXT NOT NULL REFERENCES attachment_blobs(id) ON DELETE CASCADE, conversation_id TEXT NOT NULL, message_id TEXT NOT NULL, created_at REAL NOT NULL, PRIMARY KEY(blob_id,conversation_id,message_id)) STRICT", operation: "create attachment references")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_attachment_reference_owner ON attachment_references(conversation_id,message_id)", operation: "index attachment owners")
        try database.execute("CREATE INDEX IF NOT EXISTS idx_attachment_blob_state ON attachment_blobs(state,quarantine_at)", operation: "index attachment states")
    }

    public func registerUpload(_ upload: StagedAttachment, stagedAt: Date) throws {
        let statement = try database.prepare("INSERT INTO attachment_uploads(token,blob_id,filename,mime_type,byte_count,kind,created_at,staged_at) VALUES(?,?,?,?,?,?,?,?)", operation: "register attachment upload")
        try statement.bind(upload.id.uuidString, at: 1)
        try statement.bind(upload.metadata.id, at: 2)
        try statement.bind(upload.metadata.filename, at: 3)
        try statement.bind(upload.metadata.mimeType, at: 4)
        try statement.bind(Int(upload.metadata.byteCount), at: 5)
        try statement.bind(upload.metadata.kind.rawValue, at: 6)
        try statement.bind(upload.metadata.createdAt.timeIntervalSince1970, at: 7)
        try statement.bind(stagedAt.timeIntervalSince1970, at: 8)
        _ = try statement.step()
    }

    public func upload(token: UUID) throws -> AttachmentIndexUpload? {
        let s = try database.prepare("SELECT blob_id,filename,mime_type,byte_count,kind,created_at,staged_at FROM attachment_uploads WHERE token=?", operation: "load attachment upload")
        try s.bind(token.uuidString, at: 1)
        guard try s.step() == SQLITE_ROW, let kind = AttachmentKind(rawValue: s.text(4)) else { return nil }
        return AttachmentIndexUpload(token: token, metadata: .init(id: s.text(0), filename: s.text(1), mimeType: s.text(2), byteCount: Int64(s.int(3)), kind: kind, createdAt: Date(timeIntervalSince1970: s.double(5))), stagedAt: Date(timeIntervalSince1970: s.double(6)))
    }

    public func uploads() throws -> [AttachmentIndexUpload] {
        let s = try database.prepare("SELECT token,blob_id,filename,mime_type,byte_count,kind,created_at,staged_at FROM attachment_uploads ORDER BY token", operation: "list attachment uploads")
        var result: [AttachmentIndexUpload] = []
        while try s.step() == SQLITE_ROW {
            guard let token = UUID(uuidString: s.text(0)), let kind = AttachmentKind(rawValue: s.text(5)) else { continue }
            result.append(.init(token: token, metadata: .init(id: s.text(1), filename: s.text(2), mimeType: s.text(3), byteCount: Int64(s.int(4)), kind: kind, createdAt: Date(timeIntervalSince1970: s.double(6))), stagedAt: Date(timeIntervalSince1970: s.double(7))))
        }
        return result
    }

    /// Removes a staged token and durably records the intent to quarantine its
    /// blob if no other upload or message still reaches it.
    @discardableResult
    public func abortUpload(token: UUID, now: Date) throws -> AttachmentMetadata? {
        try database.transaction("abort attachment upload") {
            guard let upload = try uploadSync(token: token) else { return nil }
            let s = try database.prepare("DELETE FROM attachment_uploads WHERE token=?", operation: "abort attachment upload")
            try s.bind(token.uuidString, at: 1); _ = try s.step()
            if try referenceCountSync(blobID: upload.metadata.id) == 0 && uploadCountSync(blobID: upload.metadata.id) == 0 {
                try upsertBlob(upload.metadata, state: .quarantinePending, quarantineAt: now)
            }
            return upload.metadata
        }
    }

    public func commitUpload(token: UUID, owner: AttachmentReferenceOwner, now: Date) throws -> AttachmentMetadata {
        try database.transaction("commit attachment upload") {
            guard let upload = try uploadSync(token: token) else { throw PersistenceError.corrupt(operation: "missing attachment upload") }
            if let existing = try blobSync(id: upload.metadata.id), existing.byteCount != upload.metadata.byteCount {
                throw PersistenceError.corrupt(operation: "attachment digest has conflicting size")
            }
            try upsertBlob(upload.metadata, state: .active, quarantineAt: nil)
            try insertReference(blobID: upload.metadata.id, owner: owner, now: now)
            let remove = try database.prepare("DELETE FROM attachment_uploads WHERE token=?", operation: "finish attachment upload")
            try remove.bind(token.uuidString, at: 1); _ = try remove.step()
            return upload.metadata
        }
    }

    public func addReference(metadata: AttachmentMetadata, owner: AttachmentReferenceOwner, now: Date) throws {
        try database.transaction("add attachment reference") {
            if let existing = try blobSync(id: metadata.id), existing.byteCount != metadata.byteCount {
                throw PersistenceError.corrupt(operation: "attachment digest has conflicting size")
            }
            try upsertBlob(metadata, state: .active, quarantineAt: nil)
            try insertReference(blobID: metadata.id, owner: owner, now: now)
        }
    }

    /// Returns true when the blob became unreachable and needs a file move.
    public func removeReference(blobID: String, owner: AttachmentReferenceOwner, now: Date) throws -> Bool {
        try database.transaction("remove attachment reference") {
            let remove = try database.prepare("DELETE FROM attachment_references WHERE blob_id=? AND conversation_id=? AND message_id=?", operation: "remove attachment reference")
            try remove.bind(blobID, at: 1); try remove.bind(owner.conversationID.uuidString, at: 2); try remove.bind(owner.messageID.uuidString, at: 3); _ = try remove.step()
            let count = try referenceCountSync(blobID: blobID)
            let uploadCount = try uploadCountSync(blobID: blobID)
            if count == 0 && uploadCount == 0 {
                let mark = try database.prepare("UPDATE attachment_blobs SET state='quarantine_pending',quarantine_at=? WHERE id=?", operation: "mark attachment quarantine pending")
                try mark.bind(now.timeIntervalSince1970, at: 1); try mark.bind(blobID, at: 2); _ = try mark.step()
            }
            return count == 0 && uploadCount == 0
        }
    }

    public func isReferenced(blobID: String, owner: AttachmentReferenceOwner) throws -> Bool {
        let s = try database.prepare("SELECT 1 FROM attachment_references WHERE blob_id=? AND conversation_id=? AND message_id=?", operation: "authorize attachment read")
        try s.bind(blobID, at: 1); try s.bind(owner.conversationID.uuidString, at: 2); try s.bind(owner.messageID.uuidString, at: 3)
        return try s.step() == SQLITE_ROW
    }

    public func references(owner: AttachmentReferenceOwner) throws -> [AttachmentIndexReference] {
        let s = try database.prepare("SELECT blob_id FROM attachment_references WHERE conversation_id=? AND message_id=? ORDER BY blob_id", operation: "list message attachment references")
        try s.bind(owner.conversationID.uuidString, at: 1); try s.bind(owner.messageID.uuidString, at: 2)
        var result: [AttachmentIndexReference] = []
        while try s.step() == SQLITE_ROW { result.append(.init(blobID: s.text(0), owner: owner)) }
        return result
    }

    /// Removes every attachment owned by a message in one transaction and
    /// returns blobs which became unreachable and need their file quarantined.
    public func removeReferences(owner: AttachmentReferenceOwner, now: Date) throws -> [String] {
        try database.transaction("remove message attachment references") {
            let ids = try referencesSync(conversationID: owner.conversationID.uuidString, messageID: owner.messageID.uuidString)
            let remove = try database.prepare("DELETE FROM attachment_references WHERE conversation_id=? AND message_id=?", operation: "remove message attachment references")
            try remove.bind(owner.conversationID.uuidString, at: 1); try remove.bind(owner.messageID.uuidString, at: 2); _ = try remove.step()
            return try markUnreachablePending(ids: ids, now: now)
        }
    }

    /// Conversation deletion hook for callers which delete transcript rows in
    /// bulk. Blob ids are returned for replayable file movement.
    public func removeReferences(conversationID: UUID, now: Date) throws -> [String] {
        try database.transaction("remove conversation attachment references") {
            let ids = try referencesSync(conversationID: conversationID.uuidString, messageID: nil)
            let remove = try database.prepare("DELETE FROM attachment_references WHERE conversation_id=?", operation: "remove conversation attachment references")
            try remove.bind(conversationID.uuidString, at: 1); _ = try remove.step()
            return try markUnreachablePending(ids: ids, now: now)
        }
    }

    public func referenceCount(blobID: String) throws -> Int { try referenceCountSync(blobID: blobID) }

    public func blob(id: String) throws -> AttachmentIndexBlob? {
        let s = try database.prepare("SELECT byte_count,state,quarantine_at FROM attachment_blobs WHERE id=?", operation: "load attachment blob")
        try s.bind(id, at: 1)
        guard try s.step() == SQLITE_ROW, let state = AttachmentIndexState(rawValue: s.text(1)) else { return nil }
        let timestamp = s.double(2)
        return .init(id: id, byteCount: Int64(s.int(0)), state: state, quarantineAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil)
    }

    public func blobs() throws -> [AttachmentIndexBlob] {
        let s = try database.prepare("SELECT id,byte_count,state,quarantine_at FROM attachment_blobs ORDER BY id", operation: "list attachment blobs")
        var result: [AttachmentIndexBlob] = []
        while try s.step() == SQLITE_ROW {
            guard let state = AttachmentIndexState(rawValue: s.text(2)) else { continue }
            let timestamp = s.double(3)
            result.append(.init(id: s.text(0), byteCount: Int64(s.int(1)), state: state, quarantineAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil))
        }
        return result
    }

    public func markQuarantined(id: String, at date: Date) throws {
        let s = try database.prepare("UPDATE attachment_blobs SET state='quarantined',quarantine_at=? WHERE id=?", operation: "finish attachment quarantine")
        try s.bind(date.timeIntervalSince1970, at: 1); try s.bind(id, at: 2); _ = try s.step()
    }

    public func markActive(id: String) throws {
        let s = try database.prepare("UPDATE attachment_blobs SET state='active',quarantine_at=NULL WHERE id=?", operation: "restore attachment")
        try s.bind(id, at: 1); _ = try s.step()
    }

    public func recordUnindexedBlob(id: String, byteCount: Int64, at date: Date) throws {
        let s = try database.prepare("INSERT INTO attachment_blobs(id,byte_count,state,quarantine_at) VALUES(?,?,'quarantined',?) ON CONFLICT(id) DO UPDATE SET byte_count=excluded.byte_count,state='quarantined',quarantine_at=excluded.quarantine_at", operation: "record unindexed attachment")
        try s.bind(id, at: 1); try s.bind(Int(byteCount), at: 2); try s.bind(date.timeIntervalSince1970, at: 3); _ = try s.step()
    }

    public func deleteBlobRecord(id: String) throws {
        let s = try database.prepare("DELETE FROM attachment_blobs WHERE id=? AND NOT EXISTS(SELECT 1 FROM attachment_references WHERE blob_id=?) AND NOT EXISTS(SELECT 1 FROM attachment_uploads WHERE blob_id=?)", operation: "delete unreachable attachment blob record")
        try s.bind(id, at: 1); try s.bind(id, at: 2); try s.bind(id, at: 3); _ = try s.step()
    }

    public func usage() throws -> AttachmentStorageUsage {
        let s = try database.prepare("""
        SELECT
          COALESCE((SELECT SUM(byte_count) FROM attachment_blobs WHERE state='active'),0),
          COALESCE((SELECT SUM(byte_count) FROM attachment_blobs WHERE state!='active'),0),
          COALESCE((SELECT SUM(byte_count) FROM (SELECT blob_id,MAX(byte_count) AS byte_count FROM attachment_uploads u WHERE NOT EXISTS(SELECT 1 FROM attachment_blobs b WHERE b.id=u.blob_id) GROUP BY blob_id)),0),
          (SELECT COUNT(*) FROM (SELECT id FROM attachment_blobs UNION SELECT blob_id FROM attachment_uploads))
        """, operation: "calculate attachment storage usage")
        guard try s.step() == SQLITE_ROW else { return .init(activeBytes: 0, quarantinedBytes: 0, stagedBytes: 0, uniqueBlobCount: 0) }
        return .init(activeBytes: Int64(s.int(0)), quarantinedBytes: Int64(s.int(1)), stagedBytes: Int64(s.int(2)), uniqueBlobCount: s.int(3))
    }

    private func uploadSync(token: UUID) throws -> AttachmentIndexUpload? {
        let s = try database.prepare("SELECT blob_id,filename,mime_type,byte_count,kind,created_at,staged_at FROM attachment_uploads WHERE token=?", operation: "load attachment upload")
        try s.bind(token.uuidString, at: 1)
        guard try s.step() == SQLITE_ROW, let kind = AttachmentKind(rawValue: s.text(4)) else { return nil }
        return .init(token: token, metadata: .init(id: s.text(0), filename: s.text(1), mimeType: s.text(2), byteCount: Int64(s.int(3)), kind: kind, createdAt: Date(timeIntervalSince1970: s.double(5))), stagedAt: Date(timeIntervalSince1970: s.double(6)))
    }

    private func blobSync(id: String) throws -> AttachmentIndexBlob? {
        let s = try database.prepare("SELECT byte_count,state,quarantine_at FROM attachment_blobs WHERE id=?", operation: "load attachment blob")
        try s.bind(id, at: 1)
        guard try s.step() == SQLITE_ROW, let state = AttachmentIndexState(rawValue: s.text(1)) else { return nil }
        let timestamp = s.double(2)
        return .init(id: id, byteCount: Int64(s.int(0)), state: state, quarantineAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil)
    }

    private func upsertBlob(_ metadata: AttachmentMetadata, state: AttachmentIndexState, quarantineAt: Date?) throws {
        let s = try database.prepare("INSERT INTO attachment_blobs(id,byte_count,state,quarantine_at) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET byte_count=excluded.byte_count,state=excluded.state,quarantine_at=excluded.quarantine_at", operation: "upsert attachment blob")
        try s.bind(metadata.id, at: 1); try s.bind(Int(metadata.byteCount), at: 2); try s.bind(state.rawValue, at: 3); try s.bind(quarantineAt?.timeIntervalSince1970 ?? 0, at: 4); _ = try s.step()
    }

    private func insertReference(blobID: String, owner: AttachmentReferenceOwner, now: Date) throws {
        let s = try database.prepare("INSERT OR IGNORE INTO attachment_references(blob_id,conversation_id,message_id,created_at) VALUES(?,?,?,?)", operation: "insert attachment reference")
        try s.bind(blobID, at: 1); try s.bind(owner.conversationID.uuidString, at: 2); try s.bind(owner.messageID.uuidString, at: 3); try s.bind(now.timeIntervalSince1970, at: 4); _ = try s.step()
    }

    private func referenceCountSync(blobID: String) throws -> Int {
        let s = try database.prepare("SELECT COUNT(*) FROM attachment_references WHERE blob_id=?", operation: "count attachment references")
        try s.bind(blobID, at: 1); return try s.step() == SQLITE_ROW ? s.int(0) : 0
    }


    private func uploadCountSync(blobID: String) throws -> Int {
        let s = try database.prepare("SELECT COUNT(*) FROM attachment_uploads WHERE blob_id=?", operation: "count attachment uploads")
        try s.bind(blobID, at: 1); return try s.step() == SQLITE_ROW ? s.int(0) : 0
    }

    private func referencesSync(conversationID: String, messageID: String?) throws -> [String] {
        let sql = messageID == nil
            ? "SELECT DISTINCT blob_id FROM attachment_references WHERE conversation_id=? ORDER BY blob_id"
            : "SELECT DISTINCT blob_id FROM attachment_references WHERE conversation_id=? AND message_id=? ORDER BY blob_id"
        let s = try database.prepare(sql, operation: "list attachment references")
        try s.bind(conversationID, at: 1)
        if let messageID { try s.bind(messageID, at: 2) }
        var ids: [String] = []
        while try s.step() == SQLITE_ROW { ids.append(s.text(0)) }
        return ids
    }

    private func markUnreachablePending(ids: [String], now: Date) throws -> [String] {
        var unreachable: [String] = []
        for id in ids where try referenceCountSync(blobID: id) == 0 && uploadCountSync(blobID: id) == 0 {
            let mark = try database.prepare("UPDATE attachment_blobs SET state='quarantine_pending',quarantine_at=? WHERE id=?", operation: "mark attachment quarantine pending")
            try mark.bind(now.timeIntervalSince1970, at: 1); try mark.bind(id, at: 2); _ = try mark.step()
            unreachable.append(id)
        }
        return unreachable
    }
}
