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
    public enum AccessState: Equatable, Sendable {
        case missing
        case ready
        case needsRenewal
    }
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

    /// A stored path is not proof that its app-scoped grant is still usable.
    /// Revalidate on use: app signing changes can invalidate a persisted grant.
    /// Never fall back to resolving without security scope or mint a grant
    /// from the saved path; renewal requires a new explicit user selection.
    public func accessState(forExactRoot path: String) throws -> AccessState {
        guard authorization(forExactRoot: path) != nil else { return .missing }
        do {
            _ = try transportBookmark(forExactRoot: path)
            return .ready
        } catch LocalToolError.workspaceAuthorizationNeedsRenewal {
            return .needsRenewal
        }
    }

    /// Persistent app-scoped bookmarks belong to the app that created them,
    /// not its separately signed XPC service. Resolve here, then issue an
    /// ephemeral bookmark for transport while access is active. Never mint
    /// a capability from an unregistered model-supplied path.
    public func transportBookmark(forExactRoot path: String) throws -> Data {
        guard let authorization = authorization(forExactRoot: path) else {
            throw LocalToolError.permissionMismatch
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: authorization.bookmarkData,
                          options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            // Cocoa's error 259 misleadingly describes a file format error.
            // This failure concerns a saved grant, before any project I/O.
            throw LocalToolError.workspaceAuthorizationNeedsRenewal
        }
        guard !stale, url.standardizedFileURL.path == authorization.path else {
            throw LocalToolError.workspaceAuthorizationNeedsRenewal
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        // The main app is not sandboxed, so startAccessing may return false
        // even for an accessible URL. Bookmark creation must still succeed;
        // the sandboxed recipient requires an actual extension before use.
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(values).write(to: fileURL, options: [.atomic])
    }
}
