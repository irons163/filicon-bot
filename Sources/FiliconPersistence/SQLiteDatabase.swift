import Foundation
import CSQLite

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase: @unchecked Sendable {
    private(set) var handle: OpaquePointer?
    let path: String

    init(url: URL, readOnly: Bool = false) throws {
        path = url.path
        if !readOnly { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE) | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(path, &pointer, flags, nil)
        handle = pointer
        guard code == SQLITE_OK else {
            let error = classify(code: code, message: pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed", operation: "open")
            if let pointer { sqlite3_close_v2(pointer) }
            handle = nil
            throw error
        }
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    func configure() throws {
        try execute("PRAGMA foreign_keys = ON", operation: "enable foreign keys")
        try execute("PRAGMA journal_mode = WAL", operation: "enable WAL")
        try execute("PRAGMA synchronous = NORMAL", operation: "configure synchronous mode")
        guard sqlite3_busy_timeout(handle, 2_000) == SQLITE_OK else { throw currentError(operation: "configure busy timeout") }
    }

    func configureReadOnly() throws {
        try execute("PRAGMA query_only = ON", operation: "configure read-only database")
        guard sqlite3_busy_timeout(handle, 2_000) == SQLITE_OK else { throw currentError(operation: "configure busy timeout") }
    }

    func execute(_ sql: String, operation: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        let message = errorPointer.map { String(cString: $0) } ?? currentMessage
        sqlite3_free(errorPointer)
        guard code == SQLITE_OK else { throw classify(code: code, message: message, operation: operation) }
    }

    func prepare(_ sql: String, operation: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw classify(code: code, message: currentMessage, operation: operation) }
        return SQLiteStatement(database: self, handle: statement, operation: operation)
    }

    func transaction<T>(_ operation: String, _ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", operation: "begin \(operation)")
        do {
            let value = try body()
            try execute("COMMIT", operation: "commit \(operation)")
            return value
        } catch {
            try? execute("ROLLBACK", operation: "rollback \(operation)")
            throw error
        }
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var currentMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed" }
    func currentError(operation: String) -> PersistenceError { classify(code: sqlite3_errcode(handle), message: currentMessage, operation: operation) }
}

final class SQLiteStatement {
    unowned let database: SQLiteDatabase
    let handle: OpaquePointer
    let operation: String
    init(database: SQLiteDatabase, handle: OpaquePointer, operation: String) { self.database = database; self.handle = handle; self.operation = operation }
    deinit { sqlite3_finalize(handle) }
    func bind(_ value: String, at index: Int32) throws { guard sqlite3_bind_text(handle, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else { throw database.currentError(operation: operation) } }
    func bind(_ value: Double, at index: Int32) throws { guard sqlite3_bind_double(handle, index, value) == SQLITE_OK else { throw database.currentError(operation: operation) } }
    func bind(_ value: Int, at index: Int32) throws { guard sqlite3_bind_int64(handle, index, sqlite3_int64(value)) == SQLITE_OK else { throw database.currentError(operation: operation) } }
    func step() throws -> Int32 {
        let code = sqlite3_step(handle)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw classify(code: code, message: database.currentMessage, operation: operation) }
        return code
    }
    func reset() { sqlite3_reset(handle); sqlite3_clear_bindings(handle) }
    func text(_ column: Int32) -> String { sqlite3_column_text(handle, column).map { String(cString: $0) } ?? "" }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
}

func classify(code: Int32, message: String, operation: String) -> PersistenceError {
    let primary = code & 0xFF
    if primary == SQLITE_BUSY || primary == SQLITE_LOCKED { return .busy(operation: operation) }
    if primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB { return .corrupt(operation: operation) }
    return .sqlite(code: code, message: message, operation: operation)
}
