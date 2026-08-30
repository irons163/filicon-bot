import Foundation

public struct WorkspaceAuthorization: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let displayName: String
    public let bookmarkData: Data

    public init(id: UUID = UUID(), path: String, displayName: String, bookmarkData: Data) {
        self.id = id
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.displayName = displayName
        self.bookmarkData = bookmarkData
    }
}

/// Persists only user-selected security-scoped bookmarks. A caller cannot add
/// an arbitrary path without supplying bookmark data created from an
/// NSOpenPanel result.
public actor WorkspaceAuthorizationStore {
    private let fileURL: URL
    private var values: [WorkspaceAuthorization]

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([WorkspaceAuthorization].self, from: data) {
            values = decoded
        } else {
            values = []
        }
    }

    @discardableResult
    public func authorize(_ url: URL) throws -> WorkspaceAuthorization {
        let standardized = url.standardizedFileURL
        let bookmark = try standardized.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return try registerBookmarkData(bookmark, url: standardized)
    }

    /// Also supports importing bookmark data supplied by another trusted UI
    /// layer while retaining exact-path authorization semantics.
    @discardableResult
    public func registerBookmarkData(_ bookmarkData: Data, url: URL) throws -> WorkspaceAuthorization {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw LocalToolError.pathEscape
        }
        let item = WorkspaceAuthorization(
            path: standardized.path,
            displayName: standardized.lastPathComponent,
            bookmarkData: bookmarkData
        )
        values.removeAll { $0.path == item.path }
        values.append(item)
        values.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        try persist()
        return item
    }

    public func remove(id: UUID) throws {
        values.removeAll { $0.id == id }
        try persist()
    }

    public func authorizations() -> [WorkspaceAuthorization] { values }

    public func authorization(forExactRoot path: String) -> WorkspaceAuthorization? {
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        return values.first { $0.path == canonical }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
    }
}
