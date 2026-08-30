import Foundation

public actor MCPConfigurationStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [MCPServerConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([MCPServerConfig].self, from: Data(contentsOf: url))
        try MCPServerConfig.validateUnique(values)
        return values
    }

    public func save(_ values: [MCPServerConfig]) throws {
        try MCPServerConfig.validateUnique(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(values).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    @discardableResult
    public func upsert(_ value: MCPServerConfig) throws -> [MCPServerConfig] {
        var values = try load()
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
        values.sort { $0.identifier < $1.identifier }
        try save(values)
        return values
    }

    @discardableResult
    public func remove(id: UUID) throws -> [MCPServerConfig] {
        var values = try load()
        values.removeAll { $0.id == id }
        try save(values)
        return values
    }
}
