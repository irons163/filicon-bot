import Foundation

public struct PrivateSkillRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var directoryPath: String
    public var updatedAt: Date

    public init(id: String, name: String, description: String = "", directoryPath: String, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.description = description
        self.directoryPath = directoryPath
        self.updatedAt = updatedAt
    }
}

public struct PrivateSkillDocument: Equatable, Sendable {
    public var record: PrivateSkillRecord
    public var body: String
    public init(record: PrivateSkillRecord, body: String) { self.record = record; self.body = body }
}

public enum PrivateSkillImportSource: Sendable {
    case directory(URL)
    case archive(URL)
}

public actor PrivateSkillLibrary {
    public let root: URL
    private let extractor: any PluginArchiveExtractor
    private let fileManager: FileManager

    public init(root: URL, extractor: any PluginArchiveExtractor = SystemPluginArchiveExtractor(), fileManager: FileManager = .default) {
        self.root = root
        self.extractor = extractor
        self.fileManager = fileManager
    }

    public func list() throws -> [PrivateSkillRecord] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .compactMap { directory in
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true,
                      (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      fileManager.fileExists(atPath: directory.appending(path: "SKILL.md").path) else { return nil }
                return PrivateSkillRecord(id: directory.lastPathComponent, name: directory.lastPathComponent, directoryPath: directory.path)
            }
            .sorted { $0.id < $1.id }
    }

    public func read(id: String) throws -> PrivateSkillDocument {
        let destination = try directory(id: id)
        let file = destination.appending(path: "SKILL.md")
        let facts = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true else { throw PluginError.pluginNotFound }
        guard Int64(facts.fileSize ?? 0) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
        let source = try String(contentsOf: file, encoding: .utf8)
        let parsed = Self.parse(source)
        return .init(
            record: .init(id: id, name: parsed.name ?? id, description: parsed.description ?? "", directoryPath: destination.path),
            body: parsed.body
        )
    }

    @discardableResult
    public func create(id: String, name: String, description: String, body: String) throws -> PrivateSkillRecord {
        try PluginSecurity.validateIdentifier(id)
        let destination = root.appending(path: id, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PluginError.invalidManifest("skill already exists") }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try writeSkill(name: name, description: description, body: body, to: destination)
            return .init(id: id, name: name, description: description, directoryPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    @discardableResult
    public func update(id: String, name: String, description: String, body: String) throws -> PrivateSkillRecord {
        let destination = try directory(id: id)
        guard fileManager.fileExists(atPath: destination.appending(path: "SKILL.md").path) else { throw PluginError.pluginNotFound }
        try writeSkill(name: name, description: description, body: body, to: destination)
        return .init(id: id, name: name, description: description, directoryPath: destination.path)
    }

    public func remove(id: String) throws {
        let destination = try directory(id: id)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
    }

    public func publishingDirectory(id: String) throws -> URL {
        let value = try directory(id: id)
        guard fileManager.fileExists(atPath: value.appending(path: "SKILL.md").path) else { throw PluginError.pluginNotFound }
        _ = try PluginSecurity.inspectDirectory(value)
        return value
    }

    @discardableResult
    public func restorePublishedSkill(id: String, from source: URL) throws -> URL {
        try PluginSecurity.validateIdentifier(id)
        _ = try PluginSecurity.inspectDirectory(source)
        let skillFile = source.appending(path: "SKILL.md")
        let facts = try skillFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true else { throw PluginError.invalidManifest("SKILL.md is required") }
        guard Int64(facts.fileSize ?? 0) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
        let destination = try directory(id: id)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PluginError.invalidManifest("a private skill with this id already exists") }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    @discardableResult
    public func importSkill(id: String, from source: PrivateSkillImportSource) async throws -> PrivateSkillRecord {
        try PluginSecurity.validateIdentifier(id)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let transaction = root.appending(path: ".import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: transaction) }

        let candidate: URL
        switch source {
        case .directory(let sourceURL):
            _ = try PluginSecurity.inspectDirectory(sourceURL)
            candidate = sourceURL
        case .archive(let archive):
            let local = transaction.appending(path: archive.lastPathComponent)
            try fileManager.copyItem(at: archive, to: local)
            let extracted = transaction.appending(path: "extracted", directoryHint: .isDirectory)
            _ = try await extractor.extract(archive: local, to: extracted)
            candidate = try skillRoot(in: extracted)
        }
        _ = try PluginSecurity.inspectDirectory(candidate)
        let skillFile = candidate.appending(path: "SKILL.md")
        let facts = try skillFile.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true else { throw PluginError.invalidManifest("SKILL.md is required") }
        guard Int64(facts.fileSize ?? 0) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
        let destination = try directory(id: id)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PluginError.invalidManifest("skill already exists") }
        try fileManager.copyItem(at: candidate, to: destination)
        return .init(id: id, name: id, directoryPath: destination.path)
    }

    /// Exports a safe directory copy. The caller can subsequently archive this
    /// copy; no shell or git command is constructed from user-controlled text.
    @discardableResult
    public func exportSkill(id: String, to parent: URL) throws -> URL {
        let source = try directory(id: id)
        _ = try PluginSecurity.inspectDirectory(source)
        guard fileManager.fileExists(atPath: source.appending(path: "SKILL.md").path) else { throw PluginError.pluginNotFound }
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let destination = parent.appending(path: id, directoryHint: .isDirectory)
        guard !fileManager.fileExists(atPath: destination.path) else { throw PluginError.invalidManifest("export destination already exists") }
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }

    private func directory(id: String) throws -> URL {
        try PluginSecurity.validateIdentifier(id)
        return root.appending(path: id, directoryHint: .isDirectory)
    }

    private func skillRoot(in extracted: URL) throws -> URL {
        if fileManager.fileExists(atPath: extracted.appending(path: "SKILL.md").path) { return extracted }
        let children = try fileManager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let candidates = children.filter { fileManager.fileExists(atPath: $0.appending(path: "SKILL.md").path) }
        guard candidates.count == 1 else { throw PluginError.invalidManifest("archive must contain exactly one skill root") }
        return candidates[0]
    }

    private func writeSkill(name: String, description: String, body: String, to directory: URL) throws {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw PluginError.invalidManifest("skill name is required") }
        let content = "---\nname: \(Self.yaml(cleanName))\ndescription: \(Self.yaml(description))\n---\n\n\(body)\n"
        guard Int64(content.utf8.count) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
        try Data(content.utf8).write(to: directory.appending(path: "SKILL.md"), options: .atomic)
    }

    private static func yaml(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func parse(_ source: String) -> (name: String?, description: String?, body: String) {
        guard source.hasPrefix("---\n"),
              let end = source.range(of: "\n---\n", range: source.index(source.startIndex, offsetBy: 4)..<source.endIndex) else {
            return (nil, nil, source)
        }
        let header = source[source.index(source.startIndex, offsetBy: 4)..<end.lowerBound]
        var values: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard ["name", "description"].contains(key) else { continue }
            if let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
                values[key] = decoded
            } else {
                values[key] = raw
            }
        }
        var body = String(source[end.upperBound...])
        while body.first == "\n" { body.removeFirst() }
        if body.last == "\n" { body.removeLast() }
        return (values["name"], values["description"], body)
    }
}

public struct PluginTeamRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String { pluginID }
    public var pluginID: String
    public var teamID: String
    public var policy: PluginInstallPolicy
    public init(pluginID: String, teamID: String, policy: PluginInstallPolicy) {
        self.pluginID = pluginID; self.teamID = teamID; self.policy = policy
    }
}

/// Private backends are represented by this protocol. Production hosts may
/// supply an authenticated implementation; this package does not assume that a
/// proprietary service exists or silently mutate a team.
public protocol PluginTeamPolicyClient: Sendable {
    func fetchAuthorizedRules() async throws -> [PluginTeamRule]
}

public actor PluginManagedPolicyService {
    private let client: (any PluginTeamPolicyClient)?
    public init(authorizedClient: (any PluginTeamPolicyClient)? = nil) { self.client = authorizedClient }

    public func rules() async throws -> [PluginTeamRule] {
        guard let client else { return [] }
        let values = try await client.fetchAuthorizedRules()
        for rule in values {
            try PluginSecurity.validateIdentifier(rule.pluginID)
            let team = rule.teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !team.isEmpty, team.count <= 256,
                  !team.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw PluginError.invalidManifest("invalid team policy identifier")
            }
        }
        return values
    }

    public func effectivePolicy(pluginID: String, catalogPolicy: PluginInstallPolicy) async throws -> PluginInstallPolicy {
        let matches = try await rules().filter { $0.pluginID == pluginID }
        if matches.contains(where: { $0.policy == .denied }) { return .denied }
        if matches.contains(where: { $0.policy == .required }) { return .required }
        if matches.contains(where: { $0.policy == .unknown }) { return .unknown }
        return catalogPolicy
    }
}
