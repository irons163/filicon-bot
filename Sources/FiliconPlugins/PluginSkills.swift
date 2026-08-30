import Foundation

public struct IndexedPluginSkill: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pluginID: String
    public var pluginName: String
    public var pluginVersion: String
    public var name: String
    public var description: String
    public var filePath: String
    public var installPath: String
    public var relativePath: String
    public var publishedByCurrentUser: Bool
    public var marketplaceTeamID: String?

    public init(
        id: String,
        pluginID: String,
        pluginName: String,
        pluginVersion: String,
        name: String,
        description: String,
        filePath: String,
        installPath: String,
        relativePath: String,
        publishedByCurrentUser: Bool = false,
        marketplaceTeamID: String? = nil
    ) {
        self.id = id; self.pluginID = pluginID; self.pluginName = pluginName; self.pluginVersion = pluginVersion
        self.name = name; self.description = description; self.filePath = filePath; self.installPath = installPath
        self.relativePath = relativePath; self.publishedByCurrentUser = publishedByCurrentUser
        self.marketplaceTeamID = marketplaceTeamID
    }

    private enum CodingKeys: String, CodingKey {
        case id, pluginID, pluginName, pluginVersion, name, description, filePath, installPath, relativePath
        case publishedByCurrentUser, marketplaceTeamID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id),
                  pluginID: try c.decode(String.self, forKey: .pluginID),
                  pluginName: try c.decode(String.self, forKey: .pluginName),
                  pluginVersion: try c.decode(String.self, forKey: .pluginVersion),
                  name: try c.decode(String.self, forKey: .name),
                  description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                  filePath: try c.decode(String.self, forKey: .filePath),
                  installPath: try c.decode(String.self, forKey: .installPath),
                  relativePath: try c.decode(String.self, forKey: .relativePath),
                  publishedByCurrentUser: try c.decodeIfPresent(Bool.self, forKey: .publishedByCurrentUser) ?? false,
                  marketplaceTeamID: try c.decodeIfPresent(String.self, forKey: .marketplaceTeamID))
    }
}

public struct PluginSkillIndex: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var skills: [IndexedPluginSkill]
    public init(fetchedAt: Date = .now, skills: [IndexedPluginSkill]) { self.fetchedAt = fetchedAt; self.skills = skills }
    private enum CodingKeys: String, CodingKey { case fetchedAt, skills }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decodeIfPresent(Double.self, forKey: .fetchedAt)
        fetchedAt = raw.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1_000 : $0) } ?? .distantPast
        skills = try c.decodeIfPresent([IndexedPluginSkill].self, forKey: .skills) ?? []
    }
}

private struct ResolvedPluginSkillPaths {
    let file: URL
    let directory: URL
}

/// Resolves both forms accepted by plugin manifests:
///
/// * a path to the skill file itself; and
/// * a path to a skill directory containing `SKILL.md`.
///
/// The returned file path is always a regular, non-symlink file.  Keeping this
/// invariant in the index means callers can use the file path as the stable
/// record location, while the directory path remains available for publishing.
private func resolvePluginSkillPaths(at candidate: URL) -> ResolvedPluginSkillPaths? {
    let standardized = candidate.standardizedFileURL
    guard let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]),
          values.isSymbolicLink != true else { return nil }

    if values.isDirectory == true {
        let file = standardized.appending(path: "SKILL.md").standardizedFileURL
        guard let fileValues = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              fileValues.isRegularFile == true,
              fileValues.isSymbolicLink != true else { return nil }
        return ResolvedPluginSkillPaths(file: file, directory: standardized)
    }

    guard values.isRegularFile == true else { return nil }
    return ResolvedPluginSkillPaths(file: standardized, directory: standardized.deletingLastPathComponent())
}

public actor PluginSkillIndexService {
    private let pluginStore: PluginStore
    private let cacheURL: URL
    private var current: PluginSkillIndex?

    public init(pluginStore: PluginStore, cacheURL: URL) {
        self.pluginStore = pluginStore
        self.cacheURL = cacheURL
    }

    public func snapshot() throws -> PluginSkillIndex? {
        if let current { return current }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(PluginSkillIndex.self, from: Data(contentsOf: cacheURL))
        current = value
        return value
    }

    @discardableResult
    public func sync(
        ownership: [String: (publishedByCurrentUser: Bool, marketplaceTeamID: String?)] = [:],
        now: Date = .now
    ) async throws -> PluginSkillIndex {
        var records: [IndexedPluginSkill] = []
        for plugin in try await pluginStore.list() {
            let root = URL(fileURLWithPath: plugin.installPath).resolvingSymlinksInPath().standardizedFileURL
            for skill in plugin.manifest.skills {
                let relative = try PluginSecurity.safeRelativePath(skill.relativePath)
                let candidate = root.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
                guard candidate.path.hasPrefix(root.path + "/"),
                      let paths = resolvePluginSkillPaths(at: candidate) else { continue }
                let owner = ownership[plugin.id]
                records.append(.init(
                    id: skill.id,
                    pluginID: plugin.id,
                    pluginName: plugin.manifest.name,
                    pluginVersion: plugin.manifest.version,
                    name: skill.name,
                    description: skill.description,
                    filePath: paths.file.path,
                    installPath: plugin.installPath,
                    relativePath: relative,
                    publishedByCurrentUser: owner?.publishedByCurrentUser ?? false,
                    marketplaceTeamID: owner?.marketplaceTeamID
                ))
            }
        }
        records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let value = PluginSkillIndex(fetchedAt: now, skills: records)
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(value).write(to: cacheURL, options: .atomic)
        current = value
        return value
    }
}

public struct SkillPublishTarget: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable { case team, privateMarketplace }
    public var id: String
    public var name: String
    public var kind: Kind
    public var authorizationState: PluginAuthorizationState
    public init(id: String, name: String, kind: Kind = .team, authorizationState: PluginAuthorizationState = .authorized) {
        self.id = id; self.name = name; self.kind = kind; self.authorizationState = authorizationState
    }

    private enum CodingKeys: String, CodingKey { case id, name, kind, authorizationState }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            kind: try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .team,
            authorizationState: try c.decodeIfPresent(PluginAuthorizationState.self, forKey: .authorizationState) ?? .authorized
        )
    }
}

public struct PublishedSkillReceipt: Codable, Hashable, Sendable {
    public var pluginID: String
    public var version: String
    public init(pluginID: String, version: String) { self.pluginID = pluginID; self.version = version }
}

public protocol SkillPublishingBackend: Sendable {
    var requiresLocalInstallationConfirmation: Bool { get }
    func listTargets() async throws -> [SkillPublishTarget]
    func publish(skillDirectory: URL, name: String, description: String, targetID: String, existingPluginID: String?) async throws -> PublishedSkillReceipt
    func unpublish(pluginID: String, targetID: String) async throws
}

public extension SkillPublishingBackend {
    var requiresLocalInstallationConfirmation: Bool { true }
}

public enum SkillPublishError: Error, LocalizedError, Equatable {
    case skillNotFound
    case descriptionRequired
    case targetRequired
    case notOwnedByCurrentUser
    case notTeamPublished
    case publishNotConfirmed
    case authenticationRequired
    case invalidTarget

    public var errorDescription: String? {
        switch self {
        case .skillNotFound: "That skill no longer exists."
        case .descriptionRequired: "Add a description before publishing the skill."
        case .targetRequired: "Choose a team before publishing the skill."
        case .notOwnedByCurrentUser: "That published skill belongs to another publisher."
        case .notTeamPublished: "That skill is not published to a team marketplace."
        case .publishNotConfirmed: "Publishing completed, but the installed plugin could not be confirmed."
        case .authenticationRequired: "Sign in and authorize this marketplace before publishing."
        case .invalidTarget: "The selected publish target is no longer available."
        }
    }
}

public enum SkillPublicationPhase: String, Codable, Hashable, Sendable {
    case publishing
    case published
    case resyncing
    case unpublishing
    case failed
}

public struct SkillPublicationState: Codable, Hashable, Sendable, Identifiable {
    public var id: String { skillID }
    public var skillID: String
    public var pluginID: String?
    public var targetID: String
    public var version: String?
    public var phase: SkillPublicationPhase
    public var errorMessage: String?
    public var updatedAt: Date

    public init(skillID: String, pluginID: String? = nil, targetID: String, version: String? = nil, phase: SkillPublicationPhase, errorMessage: String? = nil, updatedAt: Date = .now) {
        self.skillID = skillID; self.pluginID = pluginID; self.targetID = targetID; self.version = version
        self.phase = phase; self.errorMessage = errorMessage.map { String($0.prefix(1_000)) }; self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case skillID, pluginID, targetID, version, phase, errorMessage, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawUpdatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt)
        self.init(skillID: try c.decode(String.self, forKey: .skillID),
                  pluginID: try c.decodeIfPresent(String.self, forKey: .pluginID),
                  targetID: try c.decode(String.self, forKey: .targetID),
                  version: try c.decodeIfPresent(String.self, forKey: .version),
                  phase: try c.decode(SkillPublicationPhase.self, forKey: .phase),
                  errorMessage: try c.decodeIfPresent(String.self, forKey: .errorMessage),
                  updatedAt: rawUpdatedAt.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1_000 : $0) } ?? .distantPast)
    }
}

public actor SkillPublicationStore {
    private let fileURL: URL
    private var values: [String: SkillPublicationState]?
    public init(fileURL: URL) { self.fileURL = fileURL }

    public func list() throws -> [SkillPublicationState] { try load().values.sorted { $0.updatedAt > $1.updatedAt } }
    public func state(skillID: String) throws -> SkillPublicationState? { try load()[skillID] }
    public func set(_ state: SkillPublicationState) throws {
        var all = try load(); all[state.skillID] = state; try persist(all); values = all
    }
    public func remove(skillID: String) throws {
        var all = try load(); all.removeValue(forKey: skillID); try persist(all); values = all
    }
    private func load() throws -> [String: SkillPublicationState] {
        if let values { return values }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { values = [:]; return [:] }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        if let legacy = try? decoder.decode([SkillPublicationState].self, from: data) {
            let mapped = Dictionary(uniqueKeysWithValues: legacy.map { ($0.skillID, $0) }); values = mapped; return mapped
        }
        let state = try decoder.decode(State.self, from: data)
        guard state.schemaVersion == 1 else { throw PluginError.invalidManifest("unsupported publication state store") }
        values = state.values; return state.values
    }
    private func persist(_ values: [String: SkillPublicationState]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(State(values: values)).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
    private struct State: Codable { var schemaVersion = 1; var values: [String: SkillPublicationState] }
}

public protocol SkillPublishLibrary: Actor {
    func publishingDirectory(id: String) throws -> URL
    func remove(id: String) throws
    func restorePublishedSkill(id: String, from source: URL) throws -> URL
}

extension PrivateSkillLibrary: SkillPublishLibrary {}

public actor LocalSkillLibrary: SkillPublishLibrary {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func directory(id: String) throws -> URL {
        try PluginSecurity.validateIdentifier(id)
        return root.appending(path: id, directoryHint: .isDirectory)
    }

    public func publishingDirectory(id: String) throws -> URL { try directory(id: id) }

    public func create(id: String, name: String, description: String, body: String) throws -> URL {
        let directory = try directory(id: id)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw PluginError.invalidManifest("skill already exists") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { throw PluginError.invalidManifest("skill name is required") }
            let frontmatter = "---\nname: \(Self.yaml(cleanName))\ndescription: \(Self.yaml(description))\n---\n\n\(body)\n"
            guard Int64(frontmatter.utf8.count) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
            try Data(frontmatter.utf8).write(to: directory.appending(path: "SKILL.md"), options: .atomic)
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    public func remove(id: String) throws {
        let value = try directory(id: id)
        if FileManager.default.fileExists(atPath: value.path) { try FileManager.default.removeItem(at: value) }
    }

    public func restorePublishedSkill(id: String, from source: URL) throws -> URL {
        let destination = try directory(id: id)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw PluginError.invalidManifest("a private skill with this id already exists") }
        _ = try PluginSecurity.inspectDirectory(source)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private static func yaml(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}

public actor SkillPublishService {
    private let backend: any SkillPublishingBackend
    private let index: PluginSkillIndexService
    private let library: any SkillPublishLibrary
    private let publicationStore: SkillPublicationStore?

    public init(backend: any SkillPublishingBackend, index: PluginSkillIndexService, library: any SkillPublishLibrary, publicationStore: SkillPublicationStore? = nil) {
        self.backend = backend; self.index = index; self.library = library; self.publicationStore = publicationStore
    }

    public func listTargets() async throws -> [SkillPublishTarget] { try await backend.listTargets() }

    public func publish(localSkillID: String, name: String, description: String, targetID: String) async throws -> PublishedSkillReceipt {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillPublishError.descriptionRequired }
        guard !targetID.isEmpty else { throw SkillPublishError.targetRequired }
        let target = try await requireTarget(targetID)
        guard target.authorizationState == .authorized || target.authorizationState == .notRequired else { throw SkillPublishError.authenticationRequired }
        let directory = try await library.publishingDirectory(id: localSkillID)
        guard FileManager.default.fileExists(atPath: directory.appending(path: "SKILL.md").path) else { throw SkillPublishError.skillNotFound }
        try await publicationStore?.set(.init(skillID: localSkillID, targetID: targetID, phase: .publishing))
        var remoteReceipt: PublishedSkillReceipt?
        do {
            let receipt = try await backend.publish(skillDirectory: directory, name: name, description: description, targetID: targetID, existingPluginID: nil)
            remoteReceipt = receipt
            if backend.requiresLocalInstallationConfirmation {
                let refreshed = try await index.sync(ownership: [receipt.pluginID: (true, targetID)])
                guard refreshed.skills.contains(where: { $0.pluginID == receipt.pluginID && $0.pluginVersion == receipt.version }) else {
                    throw SkillPublishError.publishNotConfirmed
                }
                try await library.remove(id: localSkillID)
            }
            try await publicationStore?.set(.init(skillID: localSkillID, pluginID: receipt.pluginID, targetID: targetID, version: receipt.version, phase: .published))
            return receipt
        } catch {
            try? await publicationStore?.set(.init(skillID: localSkillID, pluginID: remoteReceipt?.pluginID, targetID: targetID, version: remoteReceipt?.version, phase: .failed, errorMessage: error.localizedDescription))
            throw error
        }
    }

    public func resyncPublication(localSkillID: String, name: String, description: String) async throws -> PublishedSkillReceipt {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SkillPublishError.descriptionRequired }
        guard let publicationStore, let state = try await publicationStore.state(skillID: localSkillID),
              let pluginID = state.pluginID else { throw SkillPublishError.skillNotFound }
        let target = try await requireTarget(state.targetID)
        guard target.authorizationState == .authorized || target.authorizationState == .notRequired else { throw SkillPublishError.authenticationRequired }
        let directory = try await library.publishingDirectory(id: localSkillID)
        try await publicationStore.set(.init(skillID: localSkillID, pluginID: pluginID, targetID: state.targetID, version: state.version, phase: .resyncing))
        do {
            let receipt = try await backend.publish(skillDirectory: directory, name: name, description: description, targetID: state.targetID, existingPluginID: pluginID)
            guard receipt.pluginID == pluginID else { throw SkillPublishError.publishNotConfirmed }
            try await publicationStore.set(.init(skillID: localSkillID, pluginID: pluginID, targetID: state.targetID, version: receipt.version, phase: .published))
            return receipt
        } catch {
            try? await publicationStore.set(.init(skillID: localSkillID, pluginID: pluginID, targetID: state.targetID, version: state.version, phase: .failed, errorMessage: error.localizedDescription))
            throw error
        }
    }

    public func unpublishPublication(localSkillID: String) async throws {
        guard let publicationStore, let state = try await publicationStore.state(skillID: localSkillID),
              let pluginID = state.pluginID else { throw SkillPublishError.skillNotFound }
        let target = try await requireTarget(state.targetID)
        guard target.authorizationState == .authorized || target.authorizationState == .notRequired else { throw SkillPublishError.authenticationRequired }
        try await publicationStore.set(.init(skillID: localSkillID, pluginID: pluginID, targetID: state.targetID, version: state.version, phase: .unpublishing))
        do {
            try await backend.unpublish(pluginID: pluginID, targetID: state.targetID)
            try await publicationStore.remove(skillID: localSkillID)
        } catch {
            try? await publicationStore.set(.init(skillID: localSkillID, pluginID: pluginID, targetID: state.targetID, version: state.version, phase: .failed, errorMessage: error.localizedDescription))
            throw error
        }
    }

    public func resync(skillID: String) async throws -> PublishedSkillReceipt {
        let record = try await requireOwned(skillID)
        guard let target = record.marketplaceTeamID else { throw SkillPublishError.notTeamPublished }
        let directory = try skillDirectory(for: record)
        let publishTarget = try await requireTarget(target)
        guard publishTarget.authorizationState == .authorized || publishTarget.authorizationState == .notRequired else { throw SkillPublishError.authenticationRequired }
        try await publicationStore?.set(.init(skillID: skillID, pluginID: record.pluginID, targetID: target, version: record.pluginVersion, phase: .resyncing))
        do {
            let receipt = try await backend.publish(
                skillDirectory: directory,
                name: record.name,
                description: record.description,
                targetID: target,
                existingPluginID: record.pluginID
            )
            guard receipt.pluginID == record.pluginID else { throw SkillPublishError.publishNotConfirmed }
            _ = try await index.sync(ownership: [record.pluginID: (true, target)])
            try await publicationStore?.set(.init(skillID: skillID, pluginID: receipt.pluginID, targetID: target, version: receipt.version, phase: .published))
            return receipt
        } catch {
            try? await publicationStore?.set(.init(skillID: skillID, pluginID: record.pluginID, targetID: target, version: record.pluginVersion, phase: .failed, errorMessage: error.localizedDescription))
            throw error
        }
    }

    public func unpublish(skillID: String) async throws -> String {
        let record = try await requireOwned(skillID)
        guard let target = record.marketplaceTeamID else { throw SkillPublishError.notTeamPublished }
        let destinationID = record.id
        let sourceDirectory = try skillDirectory(for: record)
        let publishTarget = try await requireTarget(target)
        guard publishTarget.authorizationState == .authorized || publishTarget.authorizationState == .notRequired else { throw SkillPublishError.authenticationRequired }
        let destination = try await library.restorePublishedSkill(id: destinationID, from: sourceDirectory)
        var unpublished = false
        do {
            try await publicationStore?.set(.init(skillID: skillID, pluginID: record.pluginID, targetID: target, version: record.pluginVersion, phase: .unpublishing))
            try await backend.unpublish(pluginID: record.pluginID, targetID: target)
            unpublished = true
            _ = try await index.sync()
            try await publicationStore?.remove(skillID: skillID)
            return destinationID
        } catch {
            // If the backend succeeded, retain the restored private copy even
            // when local re-indexing fails. Otherwise the only recovered copy
            // would be deleted after the remote publication is already gone.
            if !unpublished { try? FileManager.default.removeItem(at: destination) }
            try? await publicationStore?.set(.init(skillID: skillID, pluginID: record.pluginID, targetID: target, version: record.pluginVersion, phase: .failed, errorMessage: error.localizedDescription))
            throw error
        }
    }

    /// Converts interrupted mutations from a previous process into explicit
    /// failed states. No remote mutation is guessed or replayed on launch.
    public func recoverInterruptedOperations() async throws -> [SkillPublicationState] {
        guard let publicationStore else { return [] }
        let interrupted = try await publicationStore.list().filter { [.publishing, .resyncing, .unpublishing].contains($0.phase) }
        for var state in interrupted {
            state.phase = .failed
            state.errorMessage = "The previous publishing operation was interrupted. Refresh the marketplace before retrying."
            state.updatedAt = .now
            try await publicationStore.set(state)
        }
        return try await publicationStore.list()
    }

    private func requireOwned(_ skillID: String) async throws -> IndexedPluginSkill {
        let matches = try await index.snapshot()?.skills.filter { $0.id == skillID } ?? []
        guard matches.count == 1, let record = matches.first else { throw SkillPublishError.skillNotFound }
        guard record.publishedByCurrentUser else { throw SkillPublishError.notOwnedByCurrentUser }
        return record
    }

    private func skillDirectory(for record: IndexedPluginSkill) throws -> URL {
        guard let paths = resolvePluginSkillPaths(at: URL(fileURLWithPath: record.filePath)) else {
            throw SkillPublishError.skillNotFound
        }
        return paths.directory
    }

    private func requireTarget(_ targetID: String) async throws -> SkillPublishTarget {
        guard let target = try await backend.listTargets().first(where: { $0.id == targetID }) else { throw SkillPublishError.invalidTarget }
        return target
    }
}
