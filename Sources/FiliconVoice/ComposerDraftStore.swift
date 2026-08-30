import Foundation

public actor ComposerDraftStore {
    private let url: URL
    private let fileManager: FileManager
    private var loaded = false
    private var values: [String: String] = [:]

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Filicon", directoryHint: .isDirectory)
            .appending(path: "composer-drafts.json")
    }

    public func draft(for conversationID: UUID) throws -> String {
        try loadIfNeeded()
        return values[conversationID.uuidString] ?? ""
    }

    public func save(_ draft: String, for conversationID: UUID) throws {
        try loadIfNeeded()
        if draft.isEmpty { values.removeValue(forKey: conversationID.uuidString) }
        else { values[conversationID.uuidString] = draft }
        try persist()
    }

    public func remove(for conversationID: UUID) throws {
        try save("", for: conversationID)
    }

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        guard fileManager.fileExists(atPath: url.path) else { return }
        values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    private func persist() throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: url, options: .atomic)
    }
}
