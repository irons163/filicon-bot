import Foundation

private struct PluginStoreState: Codable, Sendable {
    var schemaVersion = 1
    var plugins: [InstalledPlugin] = []
}

public actor PluginStore {
    public let fileURL: URL
    private var state: PluginStoreState?

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func list() throws -> [InstalledPlugin] {
        try load().plugins.sorted { $0.manifest.displayName.localizedCaseInsensitiveCompare($1.manifest.displayName) == .orderedAscending }
    }

    public func plugin(id: String) throws -> InstalledPlugin? { try load().plugins.first { $0.id == id } }

    @discardableResult
    public func upsert(_ plugin: InstalledPlugin) throws -> InstalledPlugin {
        try PluginSecurity.validate(plugin.manifest)
        guard plugin.id == plugin.manifest.id else { throw PluginError.invalidManifest("installed plugin id mismatch") }
        var value = try load()
        if let index = value.plugins.firstIndex(where: { $0.id == plugin.id }) { value.plugins[index] = plugin }
        else { value.plugins.append(plugin) }
        try persist(value)
        state = value
        return plugin
    }

    @discardableResult
    public func remove(id: String) throws -> InstalledPlugin? {
        var value = try load()
        let removed = value.plugins.first { $0.id == id }
        value.plugins.removeAll { $0.id == id }
        try persist(value)
        state = value
        return removed
    }

    @discardableResult
    public func setToolDisabled(pluginID: String, toolName: String, disabled: Bool) throws -> InstalledPlugin {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 256,
              !normalized.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginError.invalidManifest("invalid tool name")
        }
        var value = try load()
        guard let index = value.plugins.firstIndex(where: { $0.id == pluginID }) else { throw PluginError.pluginNotFound }
        if disabled { value.plugins[index].disabledToolNames.insert(normalized) }
        else { value.plugins[index].disabledToolNames.remove(normalized) }
        try persist(value)
        state = value
        return value.plugins[index]
    }

    private func load() throws -> PluginStoreState {
        if let state { return state }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = PluginStoreState(); state = empty; return empty
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decoded: PluginStoreState
        if let stateValue = try? decoder.decode(PluginStoreState.self, from: data) { decoded = stateValue }
        else { decoded = PluginStoreState(plugins: try decoder.decode([InstalledPlugin].self, from: data)) }
        guard decoded.schemaVersion == 1 else { throw PluginError.invalidManifest("unsupported installed plugin store") }
        guard Set(decoded.plugins.map(\.id)).count == decoded.plugins.count else { throw PluginError.invalidManifest("duplicate installed plugin") }
        for plugin in decoded.plugins { try PluginSecurity.validate(plugin.manifest) }
        state = decoded
        return decoded
    }

    private func persist(_ value: PluginStoreState) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public protocol PluginSecretStore: Sendable {
    func set(_ value: String, pluginID: String, name: String) async throws
    func value(pluginID: String, name: String) async throws -> String?
    func remove(pluginID: String, name: String) async throws
}

public actor InMemoryPluginSecretStore: PluginSecretStore {
    private var values: [String: String] = [:]
    public init() {}
    public func set(_ value: String, pluginID: String, name: String) { values["\(pluginID):\(name)"] = value }
    public func value(pluginID: String, name: String) -> String? { values["\(pluginID):\(name)"] }
    public func remove(pluginID: String, name: String) { values.removeValue(forKey: "\(pluginID):\(name)") }
}

public actor PluginSetupStore {
    private let fileURL: URL
    private let secrets: any PluginSecretStore

    public init(fileURL: URL, secrets: any PluginSecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    public func save(values: [String: String], for manifest: PluginManifest) async throws {
        var publicValues = try load()
        var stored: [String: String] = publicValues[manifest.id] ?? [:]
        for field in manifest.variables {
            let value = values[field.name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if field.required && value.isEmpty { throw PluginError.missingRequiredVariable(field.name) }
            switch field.kind {
            case .text:
                if value.isEmpty { stored.removeValue(forKey: field.name) } else { stored[field.name] = value }
            case .secret:
                if value.isEmpty { try await secrets.remove(pluginID: manifest.id, name: field.name) }
                else { try await secrets.set(value, pluginID: manifest.id, name: field.name) }
            }
        }
        publicValues[manifest.id] = stored
        try persist(publicValues)
    }

    public func resolvedValues(for manifest: PluginManifest) async throws -> [String: String] {
        let publicValues = try load()[manifest.id] ?? [:]
        var values = publicValues
        for field in manifest.variables where field.kind == .secret {
            if let value = try await secrets.value(pluginID: manifest.id, name: field.name) { values[field.name] = value }
        }
        for field in manifest.variables where field.required && (values[field.name]?.isEmpty != false) {
            throw PluginError.missingRequiredVariable(field.name)
        }
        return values
    }

    public func remove(pluginID: String, fields: [PluginVariableField]) async throws {
        var values = try load(); values.removeValue(forKey: pluginID); try persist(values)
        for field in fields where field.kind == .secret { try await secrets.remove(pluginID: pluginID, name: field.name) }
    }

    private func load() throws -> [String: [String: String]] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        return try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ value: [String: [String: String]]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
