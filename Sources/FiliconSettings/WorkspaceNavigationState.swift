import Foundation

public enum WorkspaceNavigationDestination: Codable, Hashable, Sendable {
    case conversation(UUID)
    case search
    case agents
    case groups
    case automations
    case channels
    case mcp
    case computer
    case plugins
    case hiddenChats
    case sharedRooms
    case account
}

public struct WorkspaceNavigationHistory: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumEntries = 64

    public private(set) var version: Int
    public private(set) var entries: [WorkspaceNavigationDestination]
    public private(set) var index: Int

    public init(
        entries: [WorkspaceNavigationDestination] = [.search],
        index: Int = 0
    ) {
        version = Self.schemaVersion
        let bounded = Array((entries.isEmpty ? [.search] : entries).suffix(Self.maximumEntries))
        self.entries = bounded
        self.index = min(max(0, index - max(0, entries.count - bounded.count)), bounded.count - 1)
    }

    public var current: WorkspaceNavigationDestination { entries[index] }
    public var canGoBack: Bool { index > 0 }
    public var canGoForward: Bool { index + 1 < entries.count }

    public mutating func navigate(to destination: WorkspaceNavigationDestination) {
        if current == destination { return }
        if canGoForward { entries.removeSubrange((index + 1)... ) }
        entries.append(destination)
        if entries.count > Self.maximumEntries {
            entries.removeFirst(entries.count - Self.maximumEntries)
        }
        index = entries.count - 1
    }

    @discardableResult
    public mutating func goBack() -> WorkspaceNavigationDestination? {
        guard canGoBack else { return nil }
        index -= 1
        return current
    }

    @discardableResult
    public mutating func goForward() -> WorkspaceNavigationDestination? {
        guard canGoForward else { return nil }
        index += 1
        return current
    }

    /// Removes stale conversation routes after canonical SQLite metadata is
    /// loaded. Invalid destinations become Search; adjacent duplicates are
    /// collapsed while preserving the current logical position.
    public mutating func reconcile(validConversationIDs: Set<UUID>) {
        let mapped = entries.map { destination -> WorkspaceNavigationDestination in
            guard case .conversation(let id) = destination,
                  !validConversationIDs.contains(id) else { return destination }
            return .search
        }
        var collapsed: [WorkspaceNavigationDestination] = []
        var mappedIndex = 0
        for (offset, destination) in mapped.enumerated() {
            if collapsed.last != destination { collapsed.append(destination) }
            if offset <= index { mappedIndex = collapsed.count - 1 }
        }
        entries = collapsed.isEmpty ? [.search] : collapsed
        index = min(max(0, mappedIndex), entries.count - 1)
    }

    fileprivate func validated() throws -> Self {
        guard version == Self.schemaVersion,
              !entries.isEmpty,
              entries.count <= Self.maximumEntries,
              entries.indices.contains(index) else {
            throw WorkspaceNavigationError.invalidState
        }
        return self
    }
}

public enum WorkspaceNavigationError: Error, Equatable, Sendable {
    case invalidState
    case unsafePersistencePath
    case fileTooLarge
}

public actor WorkspaceNavigationStore {
    public static let maximumFileBytes = 64 * 1_024

    public let fileURL: URL
    private let fileManager: FileManager
    private let clock: @Sendable () -> Date

    public init(
        fileURL: URL,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.clock = clock
    }

    public func load() -> WorkspaceNavigationHistory {
        guard fileManager.fileExists(atPath: fileURL.path) else { return .init() }
        do {
            try requireSafeFileIfPresent()
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) <= Self.maximumFileBytes else {
                throw WorkspaceNavigationError.fileTooLarge
            }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumFileBytes else { throw WorkspaceNavigationError.fileTooLarge }
            return try JSONDecoder().decode(WorkspaceNavigationHistory.self, from: data).validated()
        } catch {
            quarantineMalformedFile()
            return .init()
        }
    }

    public func save(_ history: WorkspaceNavigationHistory) throws {
        let safe = try history.validated()
        let directory = fileURL.deletingLastPathComponent()
        try requireSafeDirectoryPath(directory, allowMissingLeaf: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireSafeDirectoryPath(directory, allowMissingLeaf: false)
        try requireSafeFileIfPresent()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(safe)
        data.append(0x0A)
        guard data.count <= Self.maximumFileBytes else { throw WorkspaceNavigationError.fileTooLarge }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        try requireSafeFileIfPresent()
    }

    private func requireSafeFileIfPresent() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw WorkspaceNavigationError.unsafePersistencePath
        }
    }

    private func requireSafeDirectoryPath(_ directory: URL, allowMissingLeaf: Bool) throws {
        var current = directory.standardizedFileURL
        var chain: [URL] = []
        while current.path != "/" {
            chain.append(current)
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        for component in chain.reversed() {
            guard fileManager.fileExists(atPath: component.path) else {
                if allowMissingLeaf { continue }
                throw WorkspaceNavigationError.unsafePersistencePath
            }
            let values = try component.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            let compatibility = ["/etc", "/tmp", "/var"].contains(component.path)
            guard compatibility && values.isSymbolicLink == true
                    || values.isSymbolicLink != true && values.isDirectory == true else {
                throw WorkspaceNavigationError.unsafePersistencePath
            }
        }
    }

    private func quarantineMalformedFile() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        // Never follow or move a symlink supplied at the destination.
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return }
        let timestamp = Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down))
        let base = fileURL.appendingPathExtension("corrupt-\(timestamp)")
        var destination = base
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: base.path + "-\(suffix)")
            suffix += 1
        }
        try? fileManager.moveItem(at: fileURL, to: destination)
    }
}
