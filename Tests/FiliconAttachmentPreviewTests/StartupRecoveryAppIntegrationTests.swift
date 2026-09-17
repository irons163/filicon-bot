import Foundation
import Testing
@testable import Filicon
import FiliconAppServices
import FiliconDomain

private actor StartupOperationProbe {
    private(set) var calls = 0
    func run(failing: Bool = false) throws {
        calls += 1
        if failing { throw CocoaError(.fileWriteUnknown) }
    }
}

@Suite("Startup root, quota, and recovery app integration")
@MainActor
struct StartupRecoveryAppIntegrationTests {
    private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
        // macOS exposes /var as a symlink; use the package's build directory so
        // these fixtures genuinely satisfy the production no-symlink policy.
        let value = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appending(path: ".build/filicon-startup-tests", directoryHint: .isDirectory)
            .appending(path: "filicon-startup-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }

    @Test func explicitOverrideIsSettledBeforeModelStoresAndAllPathsShareIt() throws {
        let home = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
        let override = home.appending(path: "Explicit Root", directoryHint: .isDirectory)
        let context = try AppStartupContext.production(
            environment: ["FILICON_DATA_ROOT": override.path],
            bundleURL: home.appending(path: "Filicon.app"), homeDirectory: home
        )
        #expect(context.root == override.standardizedFileURL)
        #expect(context.settlement.reason == .dataRootOverride)
        let model = AppModel(startupContext: context, bootstrapImmediately: false)
        #expect(model.dataRoot == context.root)
        #expect(model.startupStorePaths.allSatisfy { $0.standardizedFileURL.path.hasPrefix(context.root.path + "/") })
        #expect(model.startupStorePaths.contains(context.root.appending(path: "conversations.json")))
        #expect(model.startupStorePaths.contains(context.root.appending(path: "quota")))
    }

    @Test func unsafeOverrideFallsBackWithObservableWarningWithoutCredentials() throws {
        let home = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
        let context = try AppStartupContext.production(
            environment: ["FILICON_DATA_ROOT": "relative/../secret?token=value"],
            bundleURL: home.appending(path: "Filicon.app"), homeDirectory: home
        )
        #expect(context.root.path.hasPrefix(home.path))
        #expect(context.warning?.contains("ignored") == true)
        #expect(!context.root.absoluteString.contains("token=value"))
    }

    @Test(arguments: ["Filicon.app", "DerivedData/Build/Products/Debug/Filicon"])
    func packagedAndXcodeLaunchesUseOnlyFiliconDirectory(bundlePath: String) throws {
        let home = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
        let foreign = home.appending(path: ".cursor/sand")
        let canonical = home.appending(path: "Library/Application Support/Filicon")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: canonical, withIntermediateDirectories: true)
        let oldData = Data("do not read or move this data".utf8)
        try oldData.write(to: foreign.appending(path: "settings.json"))
        // Even a live foreign host must not change which Filicon directory opens.
        try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: foreign.appending(path: "host.lock"))
        let existing = Data("existing Filicon data".utf8)
        try existing.write(to: canonical.appending(path: "conversations.sqlite3"))
        let context = try AppStartupContext.production(environment: [:], bundleURL: home.appending(path: bundlePath), homeDirectory: home)
        #expect(context.root.path == canonical.path)
        #expect(context.settlement.route == .canonical)
        #expect(context.warning == nil)
        #expect(try Data(contentsOf: canonical.appending(path: "conversations.sqlite3")) == existing)
        #expect(try Data(contentsOf: foreign.appending(path: "settings.json")) == oldData)
        #expect(!FileManager.default.fileExists(atPath: foreign.appending(path: StartupDataRootSettler.markerFilename).path))
        #expect(!FileManager.default.fileExists(atPath: canonical.appending(path: "settings.json").path))
    }

    @Test func freshStartupIgnoresForeignSymlink() throws {
        let home = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
        let foreign = home.appending(path: ".cursor")
        let target = home.appending(path: "OtherApp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: foreign, withDestinationURL: target)
        let context = try AppStartupContext.production(environment: [:], homeDirectory: home)
        #expect(context.settlement.reason == .canonicalFresh)
        #expect(context.root.path == home.appending(path: "Library/Application Support/Filicon").path)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test(arguments: ["root", "parent", "marker"])
    func unsafeCanonicalPathStopsBeforeConstructingStores(location: String) throws {
        let home = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: home) }
        let canonical = home.appending(path: "Library/Application Support/Filicon")
        let target = home.appending(path: "untouched")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link: URL
        if location == "root" { link = canonical }
        else if location == "parent" { link = canonical.deletingLastPathComponent() }
        else { link = canonical.appending(path: StartupDataRootSettler.markerFilename) }
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let launch = FiliconLaunchState {
            try AppStartupContext.production(environment: [:], homeDirectory: home)
        }
        #expect(launch.model == nil)
        #expect(launch.failure != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.appending(path: ".cursor").path))
    }

    @Test func quotaWriterReconcilesReservesCommitsAndRollsBackFailedWrite() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger.live(dataRoot: root)
        let writer = AppQuotaWriter(ledger: ledger)
        let probe = StartupOperationProbe()
        let initial = StorageQuotaRecord(scope: "state", key: "settings.json", byteCount: 4, generation: 1)
        let usage = try await writer.reconcile([initial])
        #expect(usage.committedBytes == 4)
        _ = try await writer.perform(scope: "state", key: "settings.json", data: Data(repeating: 1, count: 8)) {
            try await probe.run()
        }
        #expect(await ledger.record(scope: "state", key: "settings.json")?.byteCount == 8)
        await #expect(throws: (any Error).self) {
            _ = try await writer.perform(scope: "state", key: "failed.json", data: Data(repeating: 2, count: 7)) {
                try await probe.run(failing: true)
            }
        }
        #expect(await ledger.record(scope: "state", key: "failed.json") == nil)
        #expect(await ledger.usage().reservationCount == 0)
    }

    @Test func attachmentQuotaHookEnforcesRecordAndAppLimits() throws {
        let empty = AttachmentStorageUsage(activeBytes: 0, quarantinedBytes: 0, stagedBytes: 0, uniqueBlobCount: 0)
        #expect(throws: Never.self) { try AppModel.checkAttachmentQuota(usage: empty, requested: 8 * 1_024 * 1_024) }
        #expect(throws: StorageQuotaError.self) { try AppModel.checkAttachmentQuota(usage: empty, requested: 8 * 1_024 * 1_024 + 1) }
        let nearlyFull = AttachmentStorageUsage(activeBytes: 255 * 1_024 * 1_024, quarantinedBytes: 0, stagedBytes: 0, uniqueBlobCount: 1)
        #expect(throws: StorageQuotaError.self) { try AppModel.checkAttachmentQuota(usage: nearlyFull, requested: 2 * 1_024 * 1_024) }
    }

    @Test func persistenceRecoveryReportSurfacesAsBannerAndDiagnosticsAreBounded() async throws {
        let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = Data("not a database and must survive".utf8)
        try original.write(to: root.appending(path: "conversations.sqlite3"))
        let context = try AppStartupContext.isolated(root: root)
        let model = AppModel(startupContext: context, bootstrapImmediately: false)
        await model.refreshPersistenceRecoveryStatus()
        let report = try #require(model.persistenceRecoveryReport)
        #expect(report.kind == .freshDatabase)
        #expect(model.startupBanner == report.summary)
        let quarantine = URL(fileURLWithPath: try #require(report.quarantineDirectory)).appending(path: "conversations.sqlite3")
        #expect(try Data(contentsOf: quarantine) == original)
        #expect(model.rootDiagnostics(limit: 100).count <= 100)
        #expect(model.rootDiagnostics().count <= 4_096)
    }

    @Test func rootResilienceFencesStaleGenerationQueuesReloadAndSingleFlightsRetry() async throws {
        let resilience = WorkspaceRootResilience()
        let first = resilience.begin()
        resilience.invalidate()
        resilience.fail(CocoaError(.fileReadUnknown), ticket: first)
        #expect(resilience.connection.failureCount == 0)
        let accountTicket = resilience.begin(accountGeneration: 7)
        resilience.updateAccountGeneration(8)
        #expect(!resilience.succeed(ticket: accountTicket))
        resilience.queueReload()
        let current = resilience.begin(accountGeneration: 8)
        #expect(resilience.succeed(ticket: current))
        #expect(resilience.connection.phase == .connected)

        let probe = StartupOperationProbe()
        resilience.retry { _ in try? await probe.run() }
        resilience.retry { _ in try? await probe.run() }
        for _ in 0..<100 where await probe.calls == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await probe.calls == 1)
    }
}
