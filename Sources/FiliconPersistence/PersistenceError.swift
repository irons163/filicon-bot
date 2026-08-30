import Foundation

public enum PersistenceError: LocalizedError, Sendable, Equatable {
    case busy(operation: String)
    case corrupt(operation: String)
    case sqlite(code: Int32, message: String, operation: String)
    case invalidLegacy(String)
    case migration(version: Int, message: String)
    case invalidData(table: String, row: String, field: String)
    case recoveryRequired(String)
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .busy(let operation): "The conversation database is busy during \(operation)."
        case .corrupt(let operation): "The conversation database is corrupt during \(operation); no data was deleted."
        case .sqlite(let code, let message, let operation): "SQLite \(code) during \(operation): \(message)"
        case .invalidLegacy(let message): "Legacy conversation import failed: \(message)"
        case .migration(let version, let message): "Database migration \(version) failed: \(message)"
        case .invalidData(let table, let row, let field): "Invalid persisted data in \(table) row \(row), field \(field)."
        case .recoveryRequired(let message): "Conversation recovery requires attention: \(message)"
        case .unsafePath(let path): "Unsafe persistence path: \(path)"
        }
    }
}
