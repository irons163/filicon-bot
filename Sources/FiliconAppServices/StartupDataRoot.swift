import Darwin
import Foundation

public enum StartupDataRootRoute: String, Codable, Sendable { case unchanged, legacy, canonical }

public enum StartupDataRootReason: String, Codable, Sendable {
    case unpackaged, lab, dataRootOverride, isolatedUserData
    case legacyUnsafe, liveLegacyHost, unknownLegacyWriter, idleLegacyWriter, busyLegacyWriter
    case canonicalConflict, migrationFailed
    case canonicalExisting, canonicalFresh, canonicalMarked, migrated, migratedByPeer
}

public struct StartupDataRootSettlement: Codable, Equatable, Sendable {
    public let route: StartupDataRootRoute
    public let reason: StartupDataRootReason
    public let root: URL?
    public let pid: Int32?

    public init(route: StartupDataRootRoute, reason: StartupDataRootReason, root: URL? = nil, pid: Int32? = nil) {
        self.route = route; self.reason = reason; self.root = root; self.pid = pid
    }
}

public enum StartupLegacyHostProbe: Sendable, Equatable { case absent, unknown, live }
public enum StartupLegacyWriterProbe: Sendable, Equatable {
    case absent, unknown
    case live(pid: Int32, inflightCount: Int)
}

public struct StartupDataRootOptions: Sendable {
    public let isPackaged: Bool
    public let isLabBuild: Bool
    public let hasDataRootOverride: Bool
    public let hasIsolatedUserData: Bool
    public let legacyRoot: URL
    public let canonicalRoot: URL

    public init(isPackaged: Bool, isLabBuild: Bool, hasDataRootOverride: Bool, hasIsolatedUserData: Bool, legacyRoot: URL, canonicalRoot: URL) {
        self.isPackaged = isPackaged; self.isLabBuild = isLabBuild
        self.hasDataRootOverride = hasDataRootOverride; self.hasIsolatedUserData = hasIsolatedUserData
        self.legacyRoot = legacyRoot; self.canonicalRoot = canonicalRoot
    }

    public static func macOS(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isPackaged: Bool,
        isLabBuild: Bool = false,
        hasDataRootOverride: Bool = false,
        hasIsolatedUserData: Bool = false
    ) -> Self {
        .init(
            isPackaged: isPackaged, isLabBuild: isLabBuild,
            hasDataRootOverride: hasDataRootOverride, hasIsolatedUserData: hasIsolatedUserData,
            legacyRoot: homeDirectory.appending(path: ".cursor/sand", directoryHint: .isDirectory),
            canonicalRoot: homeDirectory.appending(path: "Library/Application Support/Filicon", directoryHint: .isDirectory)
        )
    }
}

public struct StartupDataRootDependencies: Sendable {
    public var hostProbe: @Sendable (URL) -> StartupLegacyHostProbe
    public var writerProbe: @Sendable (URL) -> StartupLegacyWriterProbe
    public var rename: @Sendable (URL, URL) throws -> Void

    public init(
        hostProbe: @escaping @Sendable (URL) -> StartupLegacyHostProbe = StartupDataRootSettler.defaultHostProbe,
        writerProbe: @escaping @Sendable (URL) -> StartupLegacyWriterProbe = StartupDataRootSettler.defaultWriterProbe,
        rename: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) {
        self.hostProbe = hostProbe; self.writerProbe = writerProbe; self.rename = rename
    }
}

/// Resolves the one writable production root before any app-wide stores open.
/// Unsafe or ambiguous legacy state always remains on legacy (fail closed).
public enum StartupDataRootSettler {
    public static let markerFilename = ".filicon-data-root-v1"
    public static let writerDiscoveryFilename = "local-exec-daemon.json"
    public static let hostLockFilename = "host.lock"
    public static let signatureEntries: Set<String> = [markerFilename, writerDiscoveryFilename, hostLockFilename, "agents", "gateway.json", "host-secrets.json", "settings.json"]

    public static func settle(_ options: StartupDataRootOptions, dependencies: StartupDataRootDependencies = .init()) -> StartupDataRootSettlement {
        if !options.isPackaged { return .init(route: .unchanged, reason: .unpackaged) }
        if options.isLabBuild { return .init(route: .unchanged, reason: .lab) }
        if options.hasDataRootOverride { return .init(route: .unchanged, reason: .dataRootOverride) }
        if options.hasIsolatedUserData { return .init(route: .unchanged, reason: .isolatedUserData) }

        switch inspect(options.legacyRoot) {
        case .absent: return settleWithoutLegacy(legacy: options.legacyRoot, canonical: options.canonicalRoot)
        case .unsafe: return .init(route: .legacy, reason: .legacyUnsafe, root: options.legacyRoot)
        case .directory: break
        }
        guard inspect(options.legacyRoot.deletingLastPathComponent()) == .directory else {
            return .init(route: .legacy, reason: .legacyUnsafe, root: options.legacyRoot)
        }
        switch dependencies.hostProbe(options.legacyRoot) {
        case .live: return .init(route: .legacy, reason: .liveLegacyHost, root: options.legacyRoot)
        case .unknown: return .init(route: .legacy, reason: .unknownLegacyWriter, root: options.legacyRoot)
        case .absent: break
        }
        switch dependencies.writerProbe(options.legacyRoot) {
        case .unknown: return .init(route: .legacy, reason: .unknownLegacyWriter, root: options.legacyRoot)
        case .live(let pid, 0): return .init(route: .legacy, reason: .idleLegacyWriter, root: options.legacyRoot, pid: pid)
        case .live: return .init(route: .legacy, reason: .busyLegacyWriter, root: options.legacyRoot)
        case .absent: break
        }

        guard ensureSafeParent(of: options.canonicalRoot) else {
            return .init(route: .legacy, reason: .canonicalConflict, root: options.legacyRoot)
        }

        let canonicalState = inspect(options.canonicalRoot)
        if canonicalState == .directory, hasMarker(options.canonicalRoot) {
            return mark(options.canonicalRoot)
                ? .init(route: .canonical, reason: .canonicalMarked, root: options.canonicalRoot)
                : .init(route: .legacy, reason: .canonicalConflict, root: options.legacyRoot)
        }
        if canonicalState == .unsafe { return .init(route: .legacy, reason: .canonicalConflict, root: options.legacyRoot) }
        if canonicalState == .directory, !removeIfEmpty(options.canonicalRoot) {
            return .init(route: .legacy, reason: .canonicalConflict, root: options.legacyRoot)
        }
        guard mark(options.legacyRoot) else { return .init(route: .legacy, reason: .migrationFailed, root: options.legacyRoot) }
        do {
            try dependencies.rename(options.legacyRoot, options.canonicalRoot)
            synchronizeDirectory(options.canonicalRoot.deletingLastPathComponent())
            synchronizeDirectory(options.legacyRoot.deletingLastPathComponent())
            return .init(route: .canonical, reason: .migrated, root: options.canonicalRoot)
        } catch {
            if inspect(options.legacyRoot) == .absent, inspect(options.canonicalRoot) == .directory, hasMarker(options.canonicalRoot) {
                return .init(route: .canonical, reason: .migratedByPeer, root: options.canonicalRoot)
            }
            return .init(route: .legacy, reason: .migrationFailed, root: options.legacyRoot)
        }
    }

    public static func resolveExisting(legacyRoot: URL, canonicalRoot: URL) -> URL {
        inspect(canonicalRoot) == .directory ? canonicalRoot : (inspect(legacyRoot) == .directory ? legacyRoot : canonicalRoot)
    }

    public static func defaultHostProbe(_ root: URL) -> StartupLegacyHostProbe {
        let file = root.appending(path: hostLockFilename)
        guard inspectRegularFile(file) != .unsafe else { return .unknown }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return errno == ENOENT || inspect(file) == .absent ? .absent : .unknown }
        guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return .unknown }
        return processIsAlive(pid) ? .live : .absent
    }

    public static func defaultWriterProbe(_ root: URL) -> StartupLegacyWriterProbe {
        struct Discovery: Decodable { let pid: Int32; let startedAt: Double; let inflightCount: Int? }
        let file = root.appending(path: writerDiscoveryFilename)
        guard inspectRegularFile(file) != .unsafe else { return .unknown }
        guard let data = try? Data(contentsOf: file) else { return inspect(file) == .absent ? .absent : .unknown }
        guard let value = try? JSONDecoder().decode(Discovery.self, from: data), value.pid > 0,
              value.startedAt.isFinite, (value.inflightCount ?? 0) >= 0 else { return .unknown }
        return processIsAlive(value.pid) ? .live(pid: value.pid, inflightCount: value.inflightCount ?? 0) : .absent
    }

    private enum DirectoryState { case absent, directory, unsafe }
    private static func inspect(_ url: URL) -> DirectoryState {
        var info = stat()
        if lstat(url.path, &info) != 0 { return errno == ENOENT ? .absent : .unsafe }
        return (info.st_mode & S_IFMT) == S_IFDIR ? .directory : .unsafe
    }

    private static func hasMarker(_ root: URL) -> Bool {
        var info = stat()
        guard lstat(root.appending(path: markerFilename).path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func inspectRegularFile(_ url: URL) -> DirectoryState {
        var info = stat()
        if lstat(url.path, &info) != 0 { return errno == ENOENT ? .absent : .unsafe }
        return (info.st_mode & S_IFMT) == S_IFREG ? .directory : .unsafe
    }

    private static func mark(_ root: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard inspect(root) == .directory else { return false }
            guard chmod(root.path, 0o700) == 0 else { return false }
            let marker = root.appending(path: markerFilename).path
            let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if descriptor < 0 { return errno == EEXIST && hasMarker(root) && chmod(marker, 0o600) == 0 }
            defer { close(descriptor) }
            let bytes = Array("{\"version\":1}\n".utf8)
            var offset = 0
            let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
                while offset < buffer.count {
                    let wrote = Darwin.write(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
                    if wrote <= 0 { return false }
                    offset += wrote
                }
                return true
            }
            guard wroteAll, fsync(descriptor) == 0, fchmod(descriptor, 0o600) == 0 else { return false }
            synchronizeDirectory(root)
            return true
        } catch { return false }
    }

    private static func settleWithoutLegacy(legacy: URL, canonical: URL) -> StartupDataRootSettlement {
        guard ensureSafeParent(of: canonical) else {
            return .init(route: .legacy, reason: .canonicalConflict, root: legacy)
        }
        switch inspect(canonical) {
        case .directory:
            if !hasMarker(canonical) {
                let existing = occupancy(canonical)
                guard existing != .foreign, existing != .unreadable, mark(canonical) else {
                    return .init(route: .legacy, reason: .canonicalConflict, root: legacy)
                }
            } else if !mark(canonical) {
                return .init(route: .legacy, reason: .canonicalConflict, root: legacy)
            }
            return .init(route: .canonical, reason: .canonicalExisting, root: canonical)
        case .absent:
            return mark(canonical)
                ? .init(route: .canonical, reason: .canonicalFresh, root: canonical)
                : .init(route: .legacy, reason: .migrationFailed, root: legacy)
        case .unsafe: return .init(route: .legacy, reason: .canonicalConflict, root: legacy)
        }
    }

    private enum Occupancy { case empty, filicon, foreign, unreadable }
    private static func occupancy(_ root: URL) -> Occupancy {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return .unreadable }
        if entries.isEmpty { return .empty }
        return entries.contains(where: signatureEntries.contains) ? .filicon : .foreign
    }

    private static func removeIfEmpty(_ root: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path), entries.isEmpty else { return false }
        do { try FileManager.default.removeItem(at: root); return true } catch { return false }
    }

    private static func ensureSafeParent(of url: URL) -> Bool {
        let parent = url.deletingLastPathComponent()
        if inspect(parent) == .absent {
            do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return false }
        }
        return inspect(parent) == .directory
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func synchronizeDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        if descriptor >= 0 { _ = fsync(descriptor); close(descriptor) }
    }
}
