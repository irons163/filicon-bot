import Foundation

public protocol PluginArchiveExtractor: Sendable {
    func extract(archive: URL, to destination: URL) async throws -> PluginContentFacts
}

public struct SystemPluginArchiveExtractor: PluginArchiveExtractor {
    public init() {}

    public func extract(archive: URL, to destination: URL) async throws -> PluginContentFacts {
        let archiveValues = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard archiveValues.isRegularFile == true, archiveValues.isSymbolicLink != true else {
            throw PluginError.invalidManifest("archive must be a regular file")
        }
        let fileSize = Int64(archiveValues.fileSize ?? 0)
        guard fileSize <= pluginArchiveMaximumBytes else { throw PluginError.archiveTooLarge }
        let lower = archive.lastPathComponent.lowercased()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        if lower.hasSuffix(".zip") {
            let facts = try ZipCentralDirectoryInspector.inspect(archive)
            try PluginSecurity.validateContentFacts(facts)
            try await Self.run("/usr/bin/ditto", arguments: ["-x", "-k", "--noqtn", archive.path, destination.path])
        } else if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
            let entries = try await Self.tarEntries(archive)
            guard entries.fileCount <= pluginExpandedMaximumFileCount else { throw PluginError.tooManyFiles }
            try await Self.run("/usr/bin/tar", arguments: ["-xzf", archive.path, "-C", destination.path, "--no-same-owner", "--no-same-permissions"])
        } else {
            throw PluginError.invalidManifest("only .zip, .tar.gz, and .tgz plugin archives are supported")
        }
        var expanded = try PluginSecurity.inspectDirectory(destination)
        expanded.compressedBytes = fileSize
        try PluginSecurity.validateContentFacts(expanded)
        return expanded
    }

    private static func tarEntries(_ archive: URL) async throws -> (fileCount: Int, names: [String]) {
        let namesOutput = try await output("/usr/bin/tar", arguments: ["-tzf", archive.path])
        let verboseOutput = try await output("/usr/bin/tar", arguments: ["-tvzf", archive.path])
        let names = namesOutput.split(whereSeparator: \.isNewline).map(String.init)
        let verbose = verboseOutput.split(whereSeparator: \.isNewline).map(String.init)
        guard names.count == verbose.count else { throw PluginError.invalidManifest("archive index is inconsistent") }
        var fileCount = 0, seen = Set<String>()
        for (name, facts) in zip(names, verbose) {
            let path = name.hasSuffix("/") ? String(name.dropLast()) : name
            if !path.isEmpty {
                let safe = try PluginSecurity.safeRelativePath(path)
                guard seen.insert(safe.lowercased()).inserted else { throw PluginError.invalidManifest("duplicate archive path") }
            }
            guard let type = facts.first else { throw PluginError.invalidManifest("archive index is malformed") }
            if type == "l" || type == "h" { throw PluginError.symbolicLinkNotAllowed(name) }
            guard type == "-" || type == "d" else { throw PluginError.invalidManifest("special archive entries are not allowed") }
            if type == "-" { fileCount += 1 }
            if fileCount > pluginExpandedMaximumFileCount { throw PluginError.tooManyFiles }
        }
        return (fileCount, names)
    }

    private static func run(_ executable: String, arguments: [String]) async throws {
        _ = try await output(executable, arguments: arguments)
    }

    private static func output(_ executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            let output = Pipe(), error = Pipe()
            process.standardOutput = output; process.standardError = error
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errorData.prefix(4_096), as: UTF8.self)
                throw PluginError.invalidManifest("archive tool failed: \(message)")
            }
            guard outputData.count <= 32 * 1_024 * 1_024 else { throw PluginError.tooManyFiles }
            return String(decoding: outputData, as: UTF8.self)
        }.value
    }
}

private enum ZipCentralDirectoryInspector {
    static func inspect(_ url: URL) throws -> PluginContentFacts {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= 22 else { throw PluginError.invalidManifest("ZIP archive is truncated") }
        let start = max(0, data.count - 65_557)
        var eocd: Int?
        if data.count >= 4 {
            for offset in stride(from: data.count - 4, through: start, by: -1) where u32(data, offset) == 0x0605_4b50 {
                eocd = offset; break
            }
        }
        guard let eocd else { throw PluginError.invalidManifest("ZIP central directory is missing") }
        let entryCount = Int(u16(data, eocd + 10))
        let centralSize = Int(u32(data, eocd + 12))
        let centralOffset = Int(u32(data, eocd + 16))
        guard entryCount != 0xffff, centralSize != Int(UInt32.max), centralOffset != Int(UInt32.max),
              entryCount <= pluginExpandedMaximumFileCount,
              centralOffset >= 0, centralSize >= 0, centralOffset + centralSize <= data.count else {
            throw PluginError.tooManyFiles
        }
        var offset = centralOffset, files = 0, seen = Set<String>()
        var compressed: Int64 = 0, expanded: Int64 = 0
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count, u32(data, offset) == 0x0201_4b50 else {
                throw PluginError.invalidManifest("ZIP central directory is malformed")
            }
            let flags = u16(data, offset + 8)
            guard flags & 0x1 == 0 else { throw PluginError.invalidManifest("encrypted plugins are not supported") }
            let compressedSize = u32(data, offset + 20), expandedSize = u32(data, offset + 24)
            guard compressedSize != UInt32.max, expandedSize != UInt32.max else {
                throw PluginError.invalidManifest("ZIP64 plugins are not supported")
            }
            let nameLength = Int(u16(data, offset + 28)), extraLength = Int(u16(data, offset + 30)), commentLength = Int(u16(data, offset + 32))
            let end = offset + 46 + nameLength + extraLength + commentLength
            guard nameLength > 0, end <= data.count,
                  let name = String(data: data[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8) else {
                throw PluginError.invalidManifest("ZIP filename is invalid")
            }
            let path = name.hasSuffix("/") ? String(name.dropLast()) : name
            if !path.isEmpty {
                let safe = try PluginSecurity.safeRelativePath(path)
                guard seen.insert(safe.lowercased()).inserted else { throw PluginError.invalidManifest("duplicate archive path") }
            }
            let mode = u32(data, offset + 38) >> 16
            if mode & 0o170000 == 0o120000 { throw PluginError.symbolicLinkNotAllowed(name) }
            let kind = mode & 0o170000
            guard kind == 0 || kind == 0o040000 || kind == 0o100000 else {
                throw PluginError.invalidManifest("special archive entries are not allowed")
            }
            if !name.hasSuffix("/") {
                files += 1
                compressed += Int64(compressedSize)
                expanded += Int64(expandedSize)
            }
            offset = end
        }
        let facts = PluginContentFacts(fileCount: files, expandedBytes: expanded, compressedBytes: max(1, compressed))
        try PluginSecurity.validateContentFacts(facts)
        return facts
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return .max }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return .max }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}

public enum PluginInstallSource: Sendable {
    case directory(URL)
    case archive(URL)
}

public struct PluginConnectorConfiguration: Sendable, Equatable {
    public var pluginID: String
    public var connector: PluginConnector
    public var data: Data
}

public actor PluginInstaller {
    public let pluginsRoot: URL
    private let store: PluginStore
    private let setupStore: PluginSetupStore
    private let extractor: any PluginArchiveExtractor
    private let fileManager: FileManager

    public init(
        pluginsRoot: URL,
        store: PluginStore,
        setupStore: PluginSetupStore,
        extractor: any PluginArchiveExtractor = SystemPluginArchiveExtractor(),
        fileManager: FileManager = .default
    ) {
        self.pluginsRoot = pluginsRoot
        self.store = store
        self.setupStore = setupStore
        self.extractor = extractor
        self.fileManager = fileManager
    }

    public func inspect(_ source: PluginInstallSource) async throws -> PluginManifest {
        switch source {
        case .directory(let url):
            _ = try PluginSecurity.inspectDirectory(url)
            return try PluginSecurity.decodeManifest(at: url.appending(path: "plugin.json"))
        case .archive(let url):
            try fileManager.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
            let transaction = pluginsRoot.appending(path: ".inspect-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: transaction) }
            let localArchive = transaction.appending(path: url.lastPathComponent)
            try fileManager.copyItem(at: url, to: localArchive)
            let extracted = transaction.appending(path: "extracted", directoryHint: .isDirectory)
            _ = try await extractor.extract(archive: localArchive, to: extracted)
            let candidate = try pluginRoot(in: extracted)
            return try PluginSecurity.decodeManifest(at: candidate.appending(path: "plugin.json"))
        }
    }

    public func install(
        entry: PluginCatalogEntry,
        from source: PluginInstallSource,
        setupValues: [String: String] = [:]
    ) async throws -> InstalledPlugin {
        guard entry.policy.permitsInstall else { throw PluginError.installDenied }
        guard !entry.requiresAuthentication else { throw PluginError.authenticationRequired }
        try PluginSecurity.validate(entry.manifest)
        try fileManager.createDirectory(at: pluginsRoot, withIntermediateDirectories: true)
        let transaction = pluginsRoot.appending(path: ".staging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: transaction) }

        let candidate: URL
        switch source {
        case .directory(let url):
            _ = try PluginSecurity.inspectDirectory(url)
            candidate = transaction.appending(path: "plugin", directoryHint: .isDirectory)
            try fileManager.copyItem(at: url, to: candidate)
        case .archive(let url):
            let localArchive = transaction.appending(path: url.lastPathComponent)
            try fileManager.copyItem(at: url, to: localArchive)
            let extracted = transaction.appending(path: "extracted", directoryHint: .isDirectory)
            _ = try await extractor.extract(archive: localArchive, to: extracted)
            candidate = try pluginRoot(in: extracted)
        }
        _ = try PluginSecurity.inspectDirectory(candidate)
        let manifest = try PluginSecurity.decodeManifest(at: candidate.appending(path: "plugin.json"))
        guard manifest.id == entry.id, manifest.id == entry.manifest.id else { throw PluginError.invalidManifest("catalog and artifact identifiers do not match") }
        guard manifest.version == entry.manifest.version else { throw PluginError.invalidManifest("catalog and artifact versions do not match") }
        try await setupStore.save(values: setupValues, for: manifest)

        let destination = pluginsRoot.appending(path: manifest.id, directoryHint: .isDirectory)
        let backup = transaction.appending(path: "previous", directoryHint: .isDirectory)
        let hadPrevious = fileManager.fileExists(atPath: destination.path)
        if hadPrevious { try fileManager.moveItem(at: destination, to: backup) }
        do {
            try fileManager.moveItem(at: candidate, to: destination)
            let installed = InstalledPlugin(
                manifest: manifest,
                installPath: destination.path,
                ownership: entry.ownership,
                policy: entry.policy,
                disabledToolNames: (try await store.plugin(id: manifest.id))?.disabledToolNames ?? []
            )
            _ = try await store.upsert(installed)
            return installed
        } catch {
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
            if hadPrevious, fileManager.fileExists(atPath: backup.path) { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
    }

    @discardableResult
    public func uninstall(pluginID: String) async throws -> URL {
        guard let plugin = try await store.plugin(id: pluginID) else { throw PluginError.pluginNotFound }
        guard plugin.policy.permitsRemoval else { throw PluginError.removalDenied }
        let source = URL(fileURLWithPath: plugin.installPath)
        let recoveryRoot = pluginsRoot.appending(path: ".Removed", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        let destination = recoveryRoot.appending(path: "\(pluginID)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)", directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: source.path) { try fileManager.moveItem(at: source, to: destination) }
        do {
            _ = try await store.remove(id: pluginID)
            try await setupStore.remove(pluginID: pluginID, fields: plugin.manifest.variables)
            return destination
        } catch {
            if fileManager.fileExists(atPath: destination.path) { try? fileManager.moveItem(at: destination, to: source) }
            _ = try? await store.upsert(plugin)
            throw error
        }
    }

    public func connectorConfigurations() async throws -> [PluginConnectorConfiguration] {
        var values: [PluginConnectorConfiguration] = []
        for plugin in try await store.list() {
            let root = URL(fileURLWithPath: plugin.installPath).resolvingSymlinksInPath().standardizedFileURL
            for connector in plugin.manifest.connectors {
                guard let path = connector.configurationPath else { continue }
                let relative = try PluginSecurity.safeRelativePath(path)
                let url = root.appending(path: relative).resolvingSymlinksInPath().standardizedFileURL
                guard url.path.hasPrefix(root.path + "/") else { throw PluginError.unsafePath(path) }
                let facts = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard facts.isRegularFile == true, facts.isSymbolicLink != true,
                      Int64(facts.fileSize ?? 0) <= pluginManifestMaximumBytes else { throw PluginError.manifestTooLarge }
                values.append(.init(pluginID: plugin.id, connector: connector, data: try Data(contentsOf: url)))
            }
        }
        return values
    }

    private func pluginRoot(in extracted: URL) throws -> URL {
        if fileManager.fileExists(atPath: extracted.appending(path: "plugin.json").path) { return extracted }
        let children = try fileManager.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let candidates = children.filter { fileManager.fileExists(atPath: $0.appending(path: "plugin.json").path) }
        guard candidates.count == 1 else { throw PluginError.invalidManifest("archive must contain exactly one plugin root") }
        return candidates[0]
    }
}
