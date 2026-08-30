import Foundation

public actor SettingsStore {
    public typealias Clock = @Sendable () -> Date

    public let fileURL: URL
    private let fileManager: FileManager
    private let clock: Clock
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default, clock: @escaping Clock = Date.init) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.clock = clock
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> FiliconSettings {
        guard fileManager.fileExists(atPath: fileURL.path) else { return FiliconSettings() }
        let loaded: FiliconSettings
        do {
            let data = try Data(contentsOf: fileURL)
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let version = raw?["version"] as? Int ?? 0
            switch version {
            case filiconSettingsSchemaVersion:
                loaded = try decoder.decode(FiliconSettings.self, from: data)
            case 0:
                loaded = try migrateLegacyV0(data)
            default:
                throw SettingsValidationError.unsupportedVersion(version)
            }
        } catch {
            quarantineMalformedFile()
            return FiliconSettings()
        }
        let normalized = loaded.normalized()
        if normalized != loaded { try? save(normalized) }
        return normalized
    }

    public func save(_ settings: FiliconSettings) throws {
        let normalized = settings.normalized()
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(normalized)
        let temporaryURL = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporaryURL, options: .withoutOverwriting)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: fileURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    @discardableResult
    public func update(_ transform: @Sendable (inout FiliconSettings) throws -> Void) throws -> FiliconSettings {
        var settings = try load()
        try transform(&settings)
        let normalized = settings.normalized()
        try save(normalized)
        return normalized
    }

    private func quarantineMalformedFile() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        let milliseconds = Int64((clock().timeIntervalSince1970 * 1_000).rounded(.down))
        let base = fileURL.appendingPathExtension("corrupt-\(milliseconds)")
        var destination = base
        var suffix = 1
        while fileManager.fileExists(atPath: destination.path) {
            destination = URL(fileURLWithPath: base.path + "-\(suffix)")
            suffix += 1
        }
        try? fileManager.moveItem(at: fileURL, to: destination)
    }

    private func migrateLegacyV0(_ data: Data) throws -> FiliconSettings {
        let legacy = try decoder.decode(LegacySettingsV0.self, from: data)
        var settings = FiliconSettings(
            theme: legacy.theme ?? .system,
            defaultModel: legacy.defaultProviderID.flatMap { provider in
                legacy.defaultModelID.map { ProviderModelDefault(providerID: provider, modelID: $0) }
            },
            unavailableModelFallback: legacy.unavailableModelFallback ?? .providerDefault,
            localToolPermission: legacy.localToolPermission ?? .ask,
            localToolPermissionCeiling: legacy.localToolPermissionCeiling,
            accountScope: legacy.accountScope,
            updatePolicy: UpdateTrackPolicy(
                userOverride: legacy.updateTrack,
                installWhenIdle: legacy.autoUpdateWhenIdleOptIn ?? false
            ),
            sidebar: SidebarState(
                isCollapsed: legacy.sidebarCollapsed ?? false,
                width: legacy.sidebarWidth ?? 280,
                pinnedAgentIDs: legacy.pinnedAgentIDs ?? []
            )
        )
        if let timeZone = legacy.timeZoneIdentifier, FiliconSettings.isValidIANATimeZone(timeZone) {
            try settings.setTimeZoneIdentifier(timeZone)
        }
        return settings
    }
}

private struct LegacySettingsV0: Decodable {
    var theme: ThemePreference?
    var timeZoneIdentifier: String?
    var defaultProviderID: String?
    var defaultModelID: String?
    var unavailableModelFallback: UnavailableModelFallbackPolicy?
    var localToolPermission: SettingsLocalToolPermission?
    var localToolPermissionCeiling: SettingsLocalToolPermission?
    var accountScope: String?
    var updateTrack: UpdateTrack?
    var autoUpdateWhenIdleOptIn: Bool?
    var sidebarCollapsed: Bool?
    var sidebarWidth: Double?
    var pinnedAgentIDs: [String]?
}
