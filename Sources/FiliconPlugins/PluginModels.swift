import Foundation

public let pluginManifestMaximumBytes: Int64 = 10 * 1_024 * 1_024
public let pluginArchiveMaximumBytes: Int64 = 100 * 1_024 * 1_024
public let pluginExpandedMaximumBytes: Int64 = 500 * 1_024 * 1_024
public let pluginExpandedMaximumFileCount = 50_000
public let pluginMaximumCompressionRatio = 100.0
public let pluginCatalogTTL: TimeInterval = 30

public enum PluginOwnership: String, Codable, Sendable, CaseIterable {
    case publicMarketplace
    case team
    case user
}

public enum PluginInstallPolicy: String, Codable, Sendable, CaseIterable {
    case allowed
    case required
    case denied
    case unknown

    public var permitsInstall: Bool { self == .allowed || self == .required }
    public var permitsRemoval: Bool { self == .allowed }
}

public enum PluginAuthorizationState: String, Codable, Hashable, Sendable {
    case notRequired
    case required
    case pending
    case authorized
    case failed
}

public struct PluginVariableField: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case text, secret }

    public var id: String { name }
    public var name: String
    public var displayName: String
    public var description: String
    public var kind: Kind
    public var required: Bool

    public init(name: String, displayName: String? = nil, description: String = "", kind: Kind = .text, required: Bool = false) {
        self.name = name
        self.displayName = displayName ?? name
        self.description = description
        self.kind = kind
        self.required = required
    }

    private enum CodingKeys: String, CodingKey { case name, displayName, description, kind, required }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        self.init(name: name,
                  displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
                  description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                  kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text,
                  required: try c.decodeIfPresent(Bool.self, forKey: .required) ?? false)
    }
}

public struct PluginConnector: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var configurationPath: String?

    public init(name: String, description: String = "", configurationPath: String? = nil) {
        self.name = name
        self.description = description
        self.configurationPath = configurationPath
    }

    private enum CodingKeys: String, CodingKey { case name, description, configurationPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                  configurationPath: try c.decodeIfPresent(String.self, forKey: .configurationPath))
    }
}

public struct PluginSkill: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var relativePath: String
    public var sourceURL: URL?

    public init(id: String, name: String, description: String = "", relativePath: String, sourceURL: URL? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.relativePath = relativePath
        self.sourceURL = sourceURL
    }

    private enum CodingKeys: String, CodingKey { case id, name, description, relativePath, sourceURL }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                  relativePath: try c.decode(String.self, forKey: .relativePath),
                  sourceURL: try c.decodeIfPresent(URL.self, forKey: .sourceURL))
    }
}

public struct PluginManifest: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var displayName: String
    public var version: String
    public var description: String
    public var homepage: URL?
    public var connectors: [PluginConnector]
    public var skills: [PluginSkill]
    public var variables: [PluginVariableField]

    public init(
        schemaVersion: Int = 1,
        id: String,
        name: String,
        displayName: String? = nil,
        version: String,
        description: String = "",
        homepage: URL? = nil,
        connectors: [PluginConnector] = [],
        skills: [PluginSkill] = [],
        variables: [PluginVariableField] = []
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.version = version
        self.description = description
        self.homepage = homepage
        self.connectors = connectors
        self.skills = skills
        self.variables = variables
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, name, displayName, version, description, homepage, connectors, skills, variables
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .name)
        self.init(
            schemaVersion: try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1,
            id: try c.decode(String.self, forKey: .id),
            name: name,
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName),
            version: try c.decode(String.self, forKey: .version),
            description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
            homepage: try c.decodeIfPresent(URL.self, forKey: .homepage),
            connectors: try c.decodeIfPresent([PluginConnector].self, forKey: .connectors) ?? [],
            skills: try c.decodeIfPresent([PluginSkill].self, forKey: .skills) ?? [],
            variables: try c.decodeIfPresent([PluginVariableField].self, forKey: .variables) ?? []
        )
    }
}

public struct PluginCatalogEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var manifest: PluginManifest
    public var ownership: PluginOwnership
    public var policy: PluginInstallPolicy
    public var publisher: String?
    public var downloadURL: URL?
    public var iconURL: URL?
    public var marketplaceID: String?
    public var teamID: String?
    public var popularity: Int
    public var publishedByCurrentUser: Bool
    public var authorizationState: PluginAuthorizationState

    public init(
        id: String? = nil,
        manifest: PluginManifest,
        ownership: PluginOwnership = .publicMarketplace,
        policy: PluginInstallPolicy = .allowed,
        publisher: String? = nil,
        downloadURL: URL? = nil,
        iconURL: URL? = nil,
        marketplaceID: String? = nil,
        teamID: String? = nil,
        popularity: Int = 0,
        publishedByCurrentUser: Bool = false,
        authorizationState: PluginAuthorizationState = .notRequired
    ) {
        self.id = id ?? manifest.id
        self.manifest = manifest
        self.ownership = ownership
        self.policy = policy
        self.publisher = publisher
        self.downloadURL = downloadURL
        self.iconURL = iconURL
        self.marketplaceID = marketplaceID
        self.teamID = teamID
        self.popularity = max(0, popularity)
        self.publishedByCurrentUser = publishedByCurrentUser
        self.authorizationState = authorizationState
    }

    private enum CodingKeys: String, CodingKey {
        case id, manifest, ownership, policy, publisher, downloadURL, iconURL
        case marketplaceID, teamID, popularity, publishedByCurrentUser, authorizationState
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let manifest = try c.decode(PluginManifest.self, forKey: .manifest)
        self.init(
            id: try c.decodeIfPresent(String.self, forKey: .id),
            manifest: manifest,
            ownership: try c.decodeIfPresent(PluginOwnership.self, forKey: .ownership) ?? .publicMarketplace,
            policy: try c.decodeIfPresent(PluginInstallPolicy.self, forKey: .policy) ?? .allowed,
            publisher: try c.decodeIfPresent(String.self, forKey: .publisher),
            downloadURL: try c.decodeIfPresent(URL.self, forKey: .downloadURL),
            iconURL: try c.decodeIfPresent(URL.self, forKey: .iconURL),
            marketplaceID: try c.decodeIfPresent(String.self, forKey: .marketplaceID),
            teamID: try c.decodeIfPresent(String.self, forKey: .teamID),
            popularity: try c.decodeIfPresent(Int.self, forKey: .popularity) ?? 0,
            publishedByCurrentUser: try c.decodeIfPresent(Bool.self, forKey: .publishedByCurrentUser) ?? false,
            authorizationState: try c.decodeIfPresent(PluginAuthorizationState.self, forKey: .authorizationState) ?? .notRequired
        )
    }

    public var isManagedReadOnly: Bool { ownership == .team && policy != .allowed }
    public var requiresAuthentication: Bool {
        authorizationState == .required || authorizationState == .pending || authorizationState == .failed
    }
}

public struct InstalledPlugin: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var manifest: PluginManifest
    public var installPath: String
    public var ownership: PluginOwnership
    public var policy: PluginInstallPolicy
    public var disabledToolNames: Set<String>
    public var installedAt: Date

    public init(
        manifest: PluginManifest,
        installPath: String,
        ownership: PluginOwnership,
        policy: PluginInstallPolicy,
        disabledToolNames: Set<String> = [],
        installedAt: Date = .now
    ) {
        id = manifest.id
        self.manifest = manifest
        self.installPath = installPath
        self.ownership = ownership
        self.policy = policy
        self.disabledToolNames = disabledToolNames
        self.installedAt = installedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, manifest, installPath, ownership, policy, disabledToolNames, installedAt
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let manifest = try c.decode(PluginManifest.self, forKey: .manifest)
        self.init(
            manifest: manifest,
            installPath: try c.decode(String.self, forKey: .installPath),
            ownership: try c.decodeIfPresent(PluginOwnership.self, forKey: .ownership) ?? .user,
            policy: try c.decodeIfPresent(PluginInstallPolicy.self, forKey: .policy) ?? .allowed,
            disabledToolNames: try c.decodeIfPresent(Set<String>.self, forKey: .disabledToolNames) ?? [],
            installedAt: Self.compatibleDate(try c.decodeIfPresent(Double.self, forKey: .installedAt)) ?? .distantPast
        )
        if let encodedID = try c.decodeIfPresent(String.self, forKey: .id), encodedID != manifest.id {
            throw PluginError.invalidManifest("installed plugin id does not match its manifest")
        }
    }

    private static func compatibleDate(_ value: Double?) -> Date? {
        guard let value else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
}

public enum PluginBrowserTab: String, Sendable { case marketplace, yours }
public enum PluginTypeFilter: String, Sendable { case all, connectors, skills }

public struct PluginCatalogFilter: Sendable {
    public var tab: PluginBrowserTab
    public var type: PluginTypeFilter
    public var ownership: PluginOwnership?
    public var query: String

    public init(tab: PluginBrowserTab = .marketplace, type: PluginTypeFilter = .all, ownership: PluginOwnership? = nil, query: String = "") {
        self.tab = tab
        self.type = type
        self.ownership = ownership
        self.query = query
    }
}

public enum PluginError: Error, LocalizedError, Equatable {
    case invalidIdentifier(String)
    case unsupportedManifestVersion(Int)
    case manifestTooLarge
    case invalidManifest(String)
    case archiveTooLarge
    case extractedContentTooLarge
    case tooManyFiles
    case suspiciousCompressionRatio
    case unsafePath(String)
    case symbolicLinkNotAllowed(String)
    case installDenied
    case removalDenied
    case pluginNotFound
    case missingRequiredVariable(String)
    case malformedCatalog
    case authenticationRequired

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value): "Invalid plugin identifier: \(value)"
        case .unsupportedManifestVersion(let value): "Unsupported plugin manifest version: \(value)"
        case .manifestTooLarge: "The plugin manifest exceeds 10 MB."
        case .invalidManifest(let message): "Invalid plugin manifest: \(message)"
        case .archiveTooLarge: "The plugin archive exceeds 100 MB."
        case .extractedContentTooLarge: "The plugin expands beyond 500 MB."
        case .tooManyFiles: "The plugin contains more than 50,000 files."
        case .suspiciousCompressionRatio: "The plugin archive has a suspicious compression ratio."
        case .unsafePath(let path): "The plugin contains an unsafe path: \(path)"
        case .symbolicLinkNotAllowed(let path): "The plugin contains a symbolic link: \(path)"
        case .installDenied: "Team policy does not allow this plugin to be installed."
        case .removalDenied: "Team policy requires this plugin or its policy is unknown."
        case .pluginNotFound: "The plugin is not installed."
        case .missingRequiredVariable(let name): "A required setup value is missing: \(name)"
        case .malformedCatalog: "The plugin catalog is malformed."
        case .authenticationRequired: "Authentication is required for this plugin marketplace."
        }
    }
}

public extension PluginCatalogEntry {
    func matches(_ filter: PluginCatalogFilter, installedIDs: Set<String>) -> Bool {
        if filter.tab == .yours && !installedIDs.contains(id) { return false }
        if filter.type == .connectors && manifest.connectors.isEmpty { return false }
        if filter.type == .skills && manifest.skills.isEmpty { return false }
        if let ownership = filter.ownership, self.ownership != ownership { return false }
        let needle = filter.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return [manifest.displayName, manifest.name, manifest.description, publisher ?? ""]
            .joined(separator: " ").lowercased().contains(needle)
    }
}
