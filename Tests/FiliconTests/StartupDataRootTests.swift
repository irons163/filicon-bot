import Darwin
import Foundation
import Testing
import FiliconAppServices

@Suite("Canonical startup data root")
struct StartupDataRootTests {
    @Test func bypassRoutesAreDeterministicAndDoNotTouchDisk() throws {
        let sandbox = sandboxURL()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let legacy = sandbox.appending(path: "legacy")
        let canonical = sandbox.appending(path: "canonical")
        let cases: [(StartupDataRootOptions, StartupDataRootReason)] = [
            (.init(isPackaged: false, isLabBuild: false, hasDataRootOverride: false, hasIsolatedUserData: false, legacyRoot: legacy, canonicalRoot: canonical), .unpackaged),
            (.init(isPackaged: true, isLabBuild: true, hasDataRootOverride: false, hasIsolatedUserData: false, legacyRoot: legacy, canonicalRoot: canonical), .lab),
            (.init(isPackaged: true, isLabBuild: false, hasDataRootOverride: true, hasIsolatedUserData: false, legacyRoot: legacy, canonicalRoot: canonical), .dataRootOverride),
            (.init(isPackaged: true, isLabBuild: false, hasDataRootOverride: false, hasIsolatedUserData: true, legacyRoot: legacy, canonicalRoot: canonical), .isolatedUserData),
        ]
        for (options, reason) in cases {
            #expect(StartupDataRootSettler.settle(options) == .init(route: .unchanged, reason: reason))
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.path))
    }

    @Test func freshCanonicalRootAndMarkerHavePrivateModes() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let options = options(sandbox)
        let result = StartupDataRootSettler.settle(options)
        #expect(result == .init(route: .canonical, reason: .canonicalFresh, root: options.canonicalRoot))
        #expect(mode(options.canonicalRoot) == 0o700)
        #expect(mode(options.canonicalRoot.appending(path: StartupDataRootSettler.markerFilename)) == 0o600)
    }

    @Test func existingCanonicalSignatureIsMarkedWithoutLegacy() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let value = options(sandbox)
        try FileManager.default.createDirectory(at: value.canonicalRoot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: value.canonicalRoot.appending(path: "settings.json"))
        let result = StartupDataRootSettler.settle(value)
        #expect(result == .init(route: .canonical, reason: .canonicalExisting, root: value.canonicalRoot))
        #expect(mode(value.canonicalRoot) == 0o700)
        #expect(mode(value.canonicalRoot.appending(path: StartupDataRootSettler.markerFilename)) == 0o600)
    }

    @Test func unsafeLegacyAndCanonicalSymlinksFailClosed() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let target = sandbox.appending(path: "target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let value = options(sandbox)
        try FileManager.default.createDirectory(at: value.legacyRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: value.legacyRoot, withDestinationURL: target)
        #expect(StartupDataRootSettler.settle(value).reason == .legacyUnsafe)
        try FileManager.default.removeItem(at: value.legacyRoot)
        try FileManager.default.createDirectory(at: value.legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: value.canonicalRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: value.canonicalRoot, withDestinationURL: target)
        #expect(StartupDataRootSettler.settle(value).reason == .canonicalConflict)
    }

    @Test func liveAndUnknownLegacyProbesPreserveLegacy() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let value = options(sandbox)
        try FileManager.default.createDirectory(at: value.legacyRoot, withIntermediateDirectories: true)
        let host = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .live }, writerProbe: { _ in .absent }))
        #expect(host == .init(route: .legacy, reason: .liveLegacyHost, root: value.legacyRoot))
        let unknown = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .unknown }, writerProbe: { _ in .absent }))
        #expect(unknown.reason == .unknownLegacyWriter)
        let unknownWriter = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .absent }, writerProbe: { _ in .unknown }))
        #expect(unknownWriter.reason == .unknownLegacyWriter)
        let idle = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .absent }, writerProbe: { _ in .live(pid: 42, inflightCount: 0) }))
        #expect(idle == .init(route: .legacy, reason: .idleLegacyWriter, root: value.legacyRoot, pid: 42))
        let busy = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .absent }, writerProbe: { _ in .live(pid: 43, inflightCount: 2) }))
        #expect(busy.reason == .busyLegacyWriter)
    }

    @Test func canonicalOccupancyConflictsButMarkedCanonicalWins() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let value = options(sandbox)
        try FileManager.default.createDirectory(at: value.legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: value.canonicalRoot, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: value.canonicalRoot.appending(path: "other.data"))
        #expect(StartupDataRootSettler.settle(value, dependencies: absentProbes).reason == .canonicalConflict)
        try Data("{}\n".utf8).write(to: value.canonicalRoot.appending(path: StartupDataRootSettler.markerFilename))
        #expect(StartupDataRootSettler.settle(value, dependencies: absentProbes).reason == .canonicalMarked)
    }

    @Test func renameMigrationFailureAndPeerRecoveryAreDistinguished() throws {
        let first = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: first) }
        var value = options(first)
        try FileManager.default.createDirectory(at: value.legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: value.canonicalRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: value.legacyRoot.appending(path: "settings.json"))
        #expect(StartupDataRootSettler.settle(value, dependencies: absentProbes).reason == .migrated)
        #expect(FileManager.default.fileExists(atPath: value.canonicalRoot.appending(path: "settings.json").path))

        let second = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: second) }
        value = options(second)
        try FileManager.default.createDirectory(at: value.legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: value.canonicalRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let failed = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .absent }, writerProbe: { _ in .absent }, rename: { _, _ in throw CocoaError(.fileWriteUnknown) }))
        #expect(failed.reason == .migrationFailed)

        let third = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: third) }
        value = options(third)
        try FileManager.default.createDirectory(at: value.legacyRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: value.canonicalRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        let peer = StartupDataRootSettler.settle(value, dependencies: .init(hostProbe: { _ in .absent }, writerProbe: { _ in .absent }, rename: { old, new in
            try FileManager.default.moveItem(at: old, to: new)
            throw CocoaError(.fileWriteUnknown)
        }))
        #expect(peer.reason == .migratedByPeer)
    }

    private var absentProbes: StartupDataRootDependencies {
        .init(hostProbe: { _ in .absent }, writerProbe: { _ in .absent })
    }

    private func options(_ root: URL) -> StartupDataRootOptions {
        .init(isPackaged: true, isLabBuild: false, hasDataRootOverride: false, hasIsolatedUserData: false,
              legacyRoot: root.appending(path: "old/legacy"), canonicalRoot: root.appending(path: "new/canonical"))
    }

    private func sandboxURL() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString) }
    private func makeSandbox() throws -> URL {
        let value = sandboxURL(); try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true); return value
    }
    private func mode(_ url: URL) -> mode_t {
        var info = stat(); guard lstat(url.path, &info) == 0 else { return 0 }; return info.st_mode & 0o777
    }
}
