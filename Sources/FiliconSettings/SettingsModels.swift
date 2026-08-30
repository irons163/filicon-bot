import Foundation
import FiliconDomain

public let filiconSettingsSchemaVersion = 1

public enum ThemePreference: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark
}

public enum UnavailableModelFallbackPolicy: String, Codable, CaseIterable, Sendable {
    /// Keep the selected provider and use its advertised default model.
    case providerDefault
    /// Use the first provider/model in the currently available catalog.
    case firstAvailable
    /// Do not silently replace an unavailable selection.
    case none
}

public struct ProviderModelDefault: Codable, Equatable, Sendable {
    public var providerID: String
    public var modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    fileprivate var normalized: ProviderModelDefault? {
        let provider = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, !model.isEmpty else { return nil }
        return ProviderModelDefault(providerID: provider, modelID: model)
    }
}

public struct ProviderModelAvailability: Equatable, Sendable {
    public var providerID: String
    public var modelIDs: [String]
    public var defaultModelID: String?

    public init(providerID: String, modelIDs: [String], defaultModelID: String? = nil) {
        self.providerID = providerID
        self.modelIDs = modelIDs
        self.defaultModelID = defaultModelID
    }

    fileprivate var usableDefault: ProviderModelDefault? {
        let uniqueModels = modelIDs.uniquedNonempty
        guard !providerID.isEmpty else { return nil }
        let candidate = defaultModelID.flatMap { uniqueModels.contains($0) ? $0 : nil } ?? uniqueModels.first
        return candidate.map { ProviderModelDefault(providerID: providerID, modelID: $0) }
    }
}

public enum ModelSelectionResolution: Equatable, Sendable {
    case preferred(ProviderModelDefault)
    case fallback(ProviderModelDefault)
    case unavailable
}

public enum ModelSelectionResolver {
    public static func resolve(
        preferred: ProviderModelDefault?,
        policy: UnavailableModelFallbackPolicy,
        availability: [ProviderModelAvailability]
    ) -> ModelSelectionResolution {
        let preferred = preferred?.normalized
        if let preferred,
           let provider = availability.first(where: { $0.providerID == preferred.providerID }),
           provider.modelIDs.contains(preferred.modelID) {
            return .preferred(preferred)
        }
        switch policy {
        case .none:
            return .unavailable
        case .providerDefault:
            guard let preferred,
                  let provider = availability.first(where: { $0.providerID == preferred.providerID }),
                  let fallback = provider.usableDefault else { return .unavailable }
            return .fallback(fallback)
        case .firstAvailable:
            guard let fallback = availability.lazy.compactMap(\.usableDefault).first else { return .unavailable }
            return .fallback(fallback)
        }
    }
}

public typealias SettingsLocalToolPermission = LocalToolPermission

public struct UsageCounters: Codable, Equatable, Sendable {
    public var requests: Int64
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheWriteTokens: Int64
    /// Integer millionths of the account currency, avoiding floating-point drift.
    public var costMicros: Int64

    public init(
        requests: Int64 = 0,
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64 = 0,
        cacheWriteTokens: Int64 = 0,
        costMicros: Int64 = 0
    ) {
        self.requests = max(0, requests)
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.costMicros = max(0, costMicros)
    }

    private enum CodingKeys: String, CodingKey {
        case requests, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, costMicros
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = try c.decodeIfPresent(Int64.self, forKey: .requests) ?? 0
        inputTokens = try c.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int64.self, forKey: .cacheWriteTokens) ?? 0
        costMicros = try c.decodeIfPresent(Int64.self, forKey: .costMicros) ?? 0
    }

    fileprivate var normalized: UsageCounters {
        UsageCounters(requests: requests, inputTokens: inputTokens, outputTokens: outputTokens,
                      cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens,
                      costMicros: costMicros)
    }

    fileprivate mutating func add(_ increment: UsageCounters) {
        requests = requests.saturatingAdd(increment.requests)
        inputTokens = inputTokens.saturatingAdd(increment.inputTokens)
        outputTokens = outputTokens.saturatingAdd(increment.outputTokens)
        cacheReadTokens = cacheReadTokens.saturatingAdd(increment.cacheReadTokens)
        cacheWriteTokens = cacheWriteTokens.saturatingAdd(increment.cacheWriteTokens)
        costMicros = costMicros.saturatingAdd(increment.costMicros)
    }
}

public struct AccountUsageCounters: Codable, Equatable, Sendable {
    public var providers: [String: UsageCounters]

    public init(providers: [String: UsageCounters] = [:]) {
        self.providers = providers
    }

    private enum CodingKeys: String, CodingKey { case providers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providers = try c.decodeIfPresent([String: UsageCounters].self, forKey: .providers) ?? [:]
    }

    public var total: UsageCounters {
        providers.values.reduce(into: UsageCounters()) { $0.add($1.normalized) }
    }

    fileprivate var normalized: AccountUsageCounters {
        AccountUsageCounters(providers: Dictionary(uniqueKeysWithValues: providers.compactMap { key, value in
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : (key, value.normalized)
        }))
    }
}

public enum UpdateTrack: String, Codable, CaseIterable, Sendable {
    case stable
    case nightly
    case dogfood
}

public struct UpdateTrackPolicy: Codable, Equatable, Sendable {
    /// Tracks compiled/enabled for this distribution. Stable is always available.
    public var enabledTracks: Set<UpdateTrack>
    public var userOverride: UpdateTrack?
    public var managedTrack: UpdateTrack?
    public var buildDefault: UpdateTrack?
    public var installWhenIdle: Bool

    public init(
        enabledTracks: Set<UpdateTrack> = [.stable, .dogfood],
        userOverride: UpdateTrack? = nil,
        managedTrack: UpdateTrack? = nil,
        buildDefault: UpdateTrack? = nil,
        installWhenIdle: Bool = false
    ) {
        self.enabledTracks = enabledTracks.union([.stable])
        self.userOverride = userOverride
        self.managedTrack = managedTrack
        self.buildDefault = buildDefault
        self.installWhenIdle = installWhenIdle
    }

    private enum CodingKeys: String, CodingKey {
        case enabledTracks, userOverride, managedTrack, buildDefault, installWhenIdle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabledTracks = try c.decodeIfPresent(Set<UpdateTrack>.self, forKey: .enabledTracks) ?? [.stable, .dogfood]
        enabledTracks.insert(.stable)
        userOverride = try c.decodeIfPresent(UpdateTrack.self, forKey: .userOverride)
        managedTrack = try c.decodeIfPresent(UpdateTrack.self, forKey: .managedTrack)
        buildDefault = try c.decodeIfPresent(UpdateTrack.self, forKey: .buildDefault)
        installWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .installWhenIdle) ?? false
    }

    public func coerce(_ track: UpdateTrack) -> UpdateTrack {
        enabledTracks.contains(track) ? track : .stable
    }

    public var effectiveTrack: UpdateTrack {
        coerce(managedTrack ?? userOverride ?? buildDefault ?? .stable)
    }

    public func acceptsManagedTrack(_ track: UpdateTrack) -> Bool {
        enabledTracks.contains(track)
    }

    fileprivate var normalized: UpdateTrackPolicy {
        var result = self
        result.enabledTracks.insert(.stable)
        result.userOverride = result.userOverride.map(result.coerce)
        result.managedTrack = result.managedTrack.flatMap { result.acceptsManagedTrack($0) ? $0 : nil }
        result.buildDefault = result.buildDefault.map(result.coerce)
        return result
    }
}

public struct SidebarState: Codable, Equatable, Sendable {
    public var isCollapsed: Bool
    public var width: Double
    public var pinnedAgentIDs: [String]
    public var collapsedSectionIDs: [String]

    public init(
        isCollapsed: Bool = false,
        width: Double = 280,
        pinnedAgentIDs: [String] = [],
        collapsedSectionIDs: [String] = []
    ) {
        self.isCollapsed = isCollapsed
        self.width = width
        self.pinnedAgentIDs = pinnedAgentIDs
        self.collapsedSectionIDs = collapsedSectionIDs
    }

    private enum CodingKeys: String, CodingKey {
        case isCollapsed, width, pinnedAgentIDs, collapsedSectionIDs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? 280
        pinnedAgentIDs = try c.decodeIfPresent([String].self, forKey: .pinnedAgentIDs) ?? []
        collapsedSectionIDs = try c.decodeIfPresent([String].self, forKey: .collapsedSectionIDs) ?? []
    }

    fileprivate var normalized: SidebarState {
        SidebarState(
            isCollapsed: isCollapsed,
            width: width.isFinite ? min(600, max(180, width)) : 280,
            pinnedAgentIDs: pinnedAgentIDs.uniquedNonempty,
            collapsedSectionIDs: collapsedSectionIDs.uniquedNonempty
        )
    }
}

public struct FiliconSettings: Codable, Equatable, Sendable {
    public var version: Int
    public var theme: ThemePreference
    public var timeZoneIdentifier: String?
    public var defaultModel: ProviderModelDefault?
    public var unavailableModelFallback: UnavailableModelFallbackPolicy
    public var localToolPermission: LocalToolPermission
    public var localToolPermissionCeiling: LocalToolPermission?
    /// Owner of account-scoped model and local-tool choices.
    public var accountScope: String?
    public var usageByAccount: [String: AccountUsageCounters]
    public var updatePolicy: UpdateTrackPolicy
    public var sidebar: SidebarState

    public init(
        version: Int = filiconSettingsSchemaVersion,
        theme: ThemePreference = .system,
        timeZoneIdentifier: String? = nil,
        defaultModel: ProviderModelDefault? = nil,
        unavailableModelFallback: UnavailableModelFallbackPolicy = .providerDefault,
        localToolPermission: LocalToolPermission = .ask,
        localToolPermissionCeiling: LocalToolPermission? = nil,
        accountScope: String? = nil,
        usageByAccount: [String: AccountUsageCounters] = [:],
        updatePolicy: UpdateTrackPolicy = UpdateTrackPolicy(),
        sidebar: SidebarState = SidebarState()
    ) {
        self.version = version
        self.theme = theme
        self.timeZoneIdentifier = timeZoneIdentifier
        self.defaultModel = defaultModel
        self.unavailableModelFallback = unavailableModelFallback
        self.localToolPermission = localToolPermission
        self.localToolPermissionCeiling = localToolPermissionCeiling
        self.accountScope = accountScope
        self.usageByAccount = usageByAccount
        self.updatePolicy = updatePolicy
        self.sidebar = sidebar
    }

    public var effectiveLocalToolPermission: LocalToolPermission {
        localToolPermission.constrained(by: localToolPermissionCeiling)
    }

    public mutating func setTimeZoneIdentifier(_ identifier: String?) throws {
        let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            timeZoneIdentifier = nil
            return
        }
        guard Self.isValidIANATimeZone(trimmed) else { throw SettingsValidationError.invalidTimeZone(trimmed) }
        timeZoneIdentifier = trimmed
    }

    public static func isValidIANATimeZone(_ identifier: String) -> Bool {
        TimeZone.knownTimeZoneIdentifiers.contains(identifier)
    }

    public mutating func recordUsage(accountID: String, providerID: String, increment: UsageCounters) {
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, !providerID.isEmpty else { return }
        var account = usageByAccount[accountID] ?? AccountUsageCounters()
        var provider = account.providers[providerID] ?? UsageCounters()
        provider.add(increment.normalized)
        account.providers[providerID] = provider
        usageByAccount[accountID] = account
    }

    public mutating func resetUsage(accountID: String) {
        usageByAccount.removeValue(forKey: accountID)
    }

    public mutating func resetAllUsage() {
        usageByAccount.removeAll()
    }

    /// Associates preferences with an account. The first association preserves existing choices;
    /// moving to a different account clears choices that must not cross account boundaries.
    public mutating func scopeToAccount(_ identifier: String) {
        let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else {
            clearAccountScope()
            return
        }
        if let accountScope, accountScope != identifier {
            resetAccountScopedPreferences()
        }
        accountScope = identifier
    }

    public mutating func clearAccountScope() {
        accountScope = nil
        resetAccountScopedPreferences()
    }

    private mutating func resetAccountScopedPreferences() {
        defaultModel = nil
        localToolPermission = .ask
        localToolPermissionCeiling = nil
    }

    public func normalized() -> FiliconSettings {
        var result = self
        result.version = filiconSettingsSchemaVersion
        if let timeZoneIdentifier, Self.isValidIANATimeZone(timeZoneIdentifier) {
            result.timeZoneIdentifier = timeZoneIdentifier
        } else {
            result.timeZoneIdentifier = nil
        }
        result.defaultModel = defaultModel?.normalized
        result.localToolPermission = localToolPermission.constrained(by: localToolPermissionCeiling)
        result.accountScope = accountScope?.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.accountScope?.isEmpty == true { result.accountScope = nil }
        result.usageByAccount = Dictionary(uniqueKeysWithValues: usageByAccount.compactMap { key, value in
            let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : (key, value.normalized)
        })
        result.updatePolicy = updatePolicy.normalized
        result.sidebar = sidebar.normalized
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case version, theme, timeZoneIdentifier, defaultModel, unavailableModelFallback
        case localToolPermission, localToolPermissionCeiling, accountScope, usageByAccount, updatePolicy, sidebar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? filiconSettingsSchemaVersion
        theme = try c.decodeIfPresent(ThemePreference.self, forKey: .theme) ?? .system
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        defaultModel = try c.decodeIfPresent(ProviderModelDefault.self, forKey: .defaultModel)
        unavailableModelFallback = try c.decodeIfPresent(UnavailableModelFallbackPolicy.self, forKey: .unavailableModelFallback) ?? .providerDefault
        localToolPermission = try c.decodeIfPresent(LocalToolPermission.self, forKey: .localToolPermission) ?? .ask
        localToolPermissionCeiling = try c.decodeIfPresent(LocalToolPermission.self, forKey: .localToolPermissionCeiling)
        accountScope = try c.decodeIfPresent(String.self, forKey: .accountScope)
        usageByAccount = try c.decodeIfPresent([String: AccountUsageCounters].self, forKey: .usageByAccount) ?? [:]
        updatePolicy = try c.decodeIfPresent(UpdateTrackPolicy.self, forKey: .updatePolicy) ?? UpdateTrackPolicy()
        sidebar = try c.decodeIfPresent(SidebarState.self, forKey: .sidebar) ?? SidebarState()
    }
}

public enum SettingsValidationError: Error, Equatable, LocalizedError {
    case invalidTimeZone(String)
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidTimeZone(identifier): "Unknown IANA time zone: \(identifier)"
        case let .unsupportedVersion(version): "Unsupported settings version: \(version)"
        }
    }
}

private extension Array where Element == String {
    var uniquedNonempty: [String] {
        var seen = Set<String>()
        return compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (result, overflow) = addingReportingOverflow(Swift.max(0, other))
        return overflow ? .max : result
    }
}
