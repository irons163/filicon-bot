import Foundation

public struct PluginContentFacts: Equatable, Sendable {
    public var fileCount: Int
    public var expandedBytes: Int64
    public var compressedBytes: Int64?

    public init(fileCount: Int, expandedBytes: Int64, compressedBytes: Int64? = nil) {
        self.fileCount = fileCount
        self.expandedBytes = expandedBytes
        self.compressedBytes = compressedBytes
    }
}

public enum PluginSecurity {
    public static func validateIdentifier(_ value: String) throws {
        let expression = try NSRegularExpression(pattern: "^[a-z0-9]+(?:-[a-z0-9]+)*$")
        let range = NSRange(value.startIndex..., in: value)
        guard expression.firstMatch(in: value, range: range)?.range == range else {
            throw PluginError.invalidIdentifier(value)
        }
    }

    public static func decodeManifest(at url: URL) throws -> PluginManifest {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PluginError.invalidManifest("plugin.json is not a regular file") }
        guard Int64(values.fileSize ?? 0) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch { throw PluginError.invalidManifest(error.localizedDescription) }
        try validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: PluginManifest) throws {
        guard manifest.schemaVersion == 1 else { throw PluginError.unsupportedManifestVersion(manifest.schemaVersion) }
        try validateIdentifier(manifest.id)
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidManifest("name is required")
        }
        guard !manifest.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginError.invalidManifest("version is required")
        }
        guard manifest.name.count <= 256, manifest.displayName.count <= 256,
              manifest.version.count <= 256, manifest.description.count <= 16_384 else {
            throw PluginError.invalidManifest("manifest text field is too large")
        }
        if let homepage = manifest.homepage {
            guard homepage.scheme?.lowercased() == "https", homepage.host != nil,
                  homepage.user == nil, homepage.password == nil else { throw PluginError.invalidManifest("homepage must be HTTPS") }
        }
        var skillIDs = Set<String>()
        for skill in manifest.skills {
            try validateIdentifier(skill.id)
            guard skillIDs.insert(skill.id).inserted else { throw PluginError.invalidManifest("duplicate skill id \(skill.id)") }
            _ = try safeRelativePath(skill.relativePath)
        }
        let variableNames = manifest.variables.map(\.name)
        guard Set(variableNames).count == variableNames.count else { throw PluginError.invalidManifest("duplicate setup field") }
        for variable in manifest.variables {
            guard variable.name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]{0,127}$", options: .regularExpression) != nil else {
                throw PluginError.invalidManifest("invalid setup field name")
            }
        }
        for connector in manifest.connectors {
            guard !connector.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, connector.name.count <= 256 else {
                throw PluginError.invalidManifest("invalid connector name")
            }
            if let configurationPath = connector.configurationPath { _ = try safeRelativePath(configurationPath) }
        }
    }

    public static func safeRelativePath(_ value: String) throws -> String {
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.hasPrefix("~"),
              !normalized.contains("\0"),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw PluginError.unsafePath(value) }
        return normalized
    }

    public static func inspectDirectory(_ root: URL, fileManager: FileManager = .default) throws -> PluginContentFacts {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw PluginError.invalidManifest("plugin root must be a directory") }
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { throw PluginError.invalidManifest("plugin directory cannot be read") }
        var count = 0
        var size: Int64 = 0
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL.path
            guard standardized == rootPath || standardized.hasPrefix(rootPath + "/") else { throw PluginError.unsafePath(url.path) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values.isSymbolicLink == true { throw PluginError.symbolicLinkNotAllowed(url.path) }
            if values.isRegularFile == true {
                count += 1
                size += Int64(values.fileSize ?? 0)
                if count > pluginExpandedMaximumFileCount { throw PluginError.tooManyFiles }
                if size > pluginExpandedMaximumBytes { throw PluginError.extractedContentTooLarge }
            } else {
                let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                guard directory else { throw PluginError.invalidManifest("special files are not allowed") }
            }
        }
        return PluginContentFacts(fileCount: count, expandedBytes: size)
    }

    public static func validateContentFacts(_ facts: PluginContentFacts) throws {
        guard facts.fileCount <= pluginExpandedMaximumFileCount else { throw PluginError.tooManyFiles }
        guard facts.expandedBytes <= pluginExpandedMaximumBytes else { throw PluginError.extractedContentTooLarge }
        if let compressedBytes = facts.compressedBytes {
            guard compressedBytes <= pluginArchiveMaximumBytes else { throw PluginError.archiveTooLarge }
            if compressedBytes > 0 && Double(facts.expandedBytes) / Double(compressedBytes) > pluginMaximumCompressionRatio {
                throw PluginError.suspiciousCompressionRatio
            }
        }
    }
}
