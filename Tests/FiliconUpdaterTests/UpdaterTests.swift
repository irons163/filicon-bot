import CryptoKit
import Foundation
import Testing
@testable import FiliconUpdater

private actor RecordingUpdateSleeper: UpdateSleeping {
    private var values: [Duration] = []

    func sleep(for duration: Duration) async throws {
        values.append(duration)
        if values.count >= 3 { throw CancellationError() }
    }

    func durations() -> [Duration] { values }
}

private actor RequirementCheckRecorder {
    private(set) var values: [(String, Bool)] = []
    func append(_ version: String, _ required: Bool) { values.append((version, required)) }
}

@Suite("macOS updater")
struct UpdaterTests {
    @Test func packagedUpdateConfigurationIsTheSafeDefaultWithoutUserSetup() throws {
        let key = Data((0..<32).map(UInt8.init)).base64EncodedString()
        let resolved = try #require(try UpdateConfigurationResolver.resolve(
            persistedFeedURL: nil,
            persistedPublicKeyBase64: nil,
            environment: [:],
            infoDictionary: [
                UpdateConfigurationResolver.feedURLInfoKey: "https://releases.filicon.invalid/stable.json",
                UpdateConfigurationResolver.publicKeyInfoKey: key,
            ]
        ))
        #expect(resolved.feedURL.absoluteString == "https://releases.filicon.invalid/stable.json")
        #expect(resolved.trustedEd25519PublicKey == Data((0..<32).map(UInt8.init)))
        #expect(resolved.requiresSignature)

        let environmentResolved = try #require(try UpdateConfigurationResolver.resolve(
            environment: [
                UpdateConfigurationResolver.feedURLEnvironmentKey: "https://build.filicon.invalid/nightly.json",
                UpdateConfigurationResolver.publicKeyEnvironmentKey: key,
            ],
            infoDictionary: [
                UpdateConfigurationResolver.feedURLInfoKey: "https://packaged.filicon.invalid/stable.json",
                UpdateConfigurationResolver.publicKeyInfoKey: key,
            ]
        ))
        #expect(environmentResolved.feedURL.host == "build.filicon.invalid")
        #expect(try UpdateConfigurationResolver.resolve(environment: [:], infoDictionary: [:]) == nil)
        #expect(throws: UpdateError.invalidPublicKey) {
            _ = try UpdateConfigurationResolver.resolve(
                environment: [:],
                infoDictionary: [UpdateConfigurationResolver.feedURLInfoKey: "https://updates.example/feed.json"]
            )
        }
    }

    @Test func backendRequirementRaisesScopedGatePersistsAndImmediatelyChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-update-requirement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendUpdatePolicyStore(fileURL: root.appending(path: "backend-policy.json"))
        let recorder = RequirementCheckRecorder()
        let coordinator = BackendUpdateRequirementCoordinator(store: store, installedVersion: "1.4.0") { version, required in
            await recorder.append(version, required)
        }

        let first = try await coordinator.ingest(scope: "gateway:production", minimumVersion: "1.5.0")
        #expect(first.highestMinimumVersion == "1.5.0")
        #expect(await recorder.values.count == 1)
        #expect(await recorder.values.first?.0 == "1.5.0")
        #expect(await recorder.values.first?.1 == true)

        _ = try await coordinator.ingest(scope: "gateway:production", minimumVersion: "1.3.0")
        #expect(await recorder.values.count == 1)
        let recovered = await BackendUpdatePolicyStore(fileURL: root.appending(path: "backend-policy.json")).snapshot()
        #expect(recovered.minimumVersionsByScope["gateway:production"] == "1.5.0")
        await #expect(throws: UpdateError.invalidVersion("not-semver")) {
            _ = try await coordinator.ingest(scope: "gateway:production", minimumVersion: "not-semver")
        }
    }

    @Test func recoveredScheduleStartsAtThirtySecondsAndUsesBoundedDeterministicHourlyJitter() async throws {
        let schedule = UpdateCheckSchedule()
        #expect(schedule.initialDelay == .seconds(30))
        #expect(schedule.nextPeriodicDelay(randomUnit: -1) == .seconds(60 * 60))
        #expect(schedule.nextPeriodicDelay(randomUnit: 0.5) == .seconds(60 * 60 + 150))
        #expect(schedule.nextPeriodicDelay(randomUnit: 2) == .seconds(65 * 60))

        let feedURL = URL(string: "https://updates.example/stable.json")!
        let payload = try JSONEncoder().encode(UpdateFeed(channel: .stable, releases: []))
        let service = UpdateService(feedLoader: { url in
            (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let sleeper = RecordingUpdateSleeper()
        let manager = UpdateManager(
            service: service,
            stagingRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            schedule: schedule,
            sleeper: sleeper,
            randomUnit: { 0.5 }
        )
        let configuration = try UpdateConfiguration(
            feedURL: feedURL, automaticallyChecks: true, requiresSignature: false
        )
        await manager.startPeriodicChecks(
            configuration: configuration,
            installed: .init(version: "1.0.0", build: 1),
            systemVersion: "14.0"
        )
        for _ in 0..<1_000 {
            if await sleeper.durations().count >= 3 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await manager.stopPeriodicChecks()
        #expect(await sleeper.durations() == [.seconds(30), .seconds(3_750), .seconds(3_750)])
    }

    @Test func safeIdlePolicyRequiresUserAwayHostIdleNoWorkAndNormalPower() {
        let safe = UpdateIdleSnapshot(
            hasActiveWork: false, sessionActive: true, screenLocked: true,
            screensaverActive: false, systemIdleSeconds: 301, lowPowerModeEnabled: false
        )
        #expect(UpdateIdleInstallPolicy.permitsInstall(snapshot: safe, optedIn: true, updateStaged: true))
        var value = safe
        value.hasActiveWork = true
        #expect(!UpdateIdleInstallPolicy.permitsInstall(snapshot: value, optedIn: true, updateStaged: true))
        value = safe; value.screenLocked = false
        #expect(!UpdateIdleInstallPolicy.permitsInstall(snapshot: value, optedIn: true, updateStaged: true))
        value = safe; value.lowPowerModeEnabled = true
        #expect(!UpdateIdleInstallPolicy.permitsInstall(snapshot: value, optedIn: true, updateStaged: true))
        value = safe; value.systemIdleSeconds = 299
        #expect(!UpdateIdleInstallPolicy.permitsInstall(snapshot: value, optedIn: true, updateStaged: true))
        #expect(!UpdateIdleInstallPolicy.permitsInstall(snapshot: safe, optedIn: false, updateStaged: true))
    }

    @Test func minimumRequiredVersionUsesSemanticVersioningAndFailsOpenForInvalidPolicy() {
        #expect(UpdateRequirementEvaluator.isBelowMinimum(installedVersion: "1.4.9", minimumRequiredVersion: "1.5.0"))
        #expect(!UpdateRequirementEvaluator.isBelowMinimum(installedVersion: "1.5.0", minimumRequiredVersion: "1.5.0"))
        #expect(!UpdateRequirementEvaluator.isBelowMinimum(installedVersion: "1.0.0", minimumRequiredVersion: "invalid"))
    }

    @Test func semanticVersionsAndBuildNumbersSelectNewestCompatibleRelease() throws {
        let artifact = UpdateArtifact(
            url: URL(string: "https://updates.example/Filicon.zip")!,
            format: .appZip,
            sha256: String(repeating: "0", count: 64),
            size: 1
        )
        let feed = UpdateFeed(channel: .nightly, releases: [
            .init(version: "2.0.0-beta.2", build: 20, publishedAt: .distantPast, minimumSystemVersion: "14.0", artifact: artifact),
            .init(version: "1.9.0", build: 21, publishedAt: .distantPast, minimumSystemVersion: "14.0", artifact: artifact),
            .init(version: "2.0.0", build: 22, publishedAt: .distantPast, minimumSystemVersion: "15.0", artifact: artifact),
        ])
        let selected = try UpdateSelector.newestUpdate(
            in: feed,
            channel: .nightly,
            installed: .init(version: "1.8.0", build: 10),
            systemVersion: "14.6"
        )
        #expect(selected?.version == "2.0.0-beta.2")
        #expect(try ReleaseVersion("1.0.0-beta.10") < ReleaseVersion("1.0.0"))
        #expect(throws: UpdateError.self) { _ = try ReleaseVersion("1..0") }
    }

    @Test func fetchRequiresHTTPSValidStatusSchemaAndMatchingChannel() async throws {
        let release = UpdateRelease(
            version: "1.1.0",
            build: 2,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            minimumSystemVersion: "14.0",
            artifact: .init(
                url: URL(string: "https://updates.example/Filicon.zip")!,
                format: .appZip,
                sha256: String(repeating: "a", count: 64),
                size: 42
            )
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(UpdateFeed(channel: .stable, releases: [release]))
        let feedURL = URL(string: "https://updates.example/stable.json")!
        let service = UpdateService(feedLoader: { url in
            (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let loaded = try await service.fetchFeed(from: feedURL, channel: .stable)
        #expect(loaded.releases == [release])
        await #expect(throws: UpdateError.self) {
            _ = try await service.fetchFeed(from: URL(string: "http://updates.example/stable.json")!, channel: .stable)
        }
        await #expect(throws: UpdateError.self) {
            _ = try await service.fetchFeed(from: feedURL, channel: .dogfood)
        }
    }

    @Test func signedArtifactIsVerifiedAndAtomicallyStaged() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-updater-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "download.zip")
        let payload = Data("verified update payload".utf8)
        try payload.write(to: source)
        let privateKey = Curve25519.Signing.PrivateKey()
        let signature = try privateKey.signature(for: payload).base64EncodedString()
        let artifactURL = URL(string: "https://updates.example/Filicon-1.2.0.zip")!
        let artifact = UpdateArtifact(
            url: artifactURL,
            format: .appZip,
            sha256: try ArtifactVerifier.sha256(file: source),
            size: Int64(payload.count),
            ed25519Signature: signature
        )
        let release = UpdateRelease(
            version: "1.2.0",
            build: 12,
            publishedAt: Date(timeIntervalSince1970: 2_000),
            minimumSystemVersion: "14.0",
            artifact: artifact
        )
        let service = UpdateService(artifactDownloader: { url in
            (source, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let staging = root.appending(path: "staging", directoryHint: .isDirectory)
        let staged = try await service.downloadAndStage(
            release,
            in: staging,
            signaturePolicy: .required(publicKey: privateKey.publicKey.rawRepresentation),
            now: Date(timeIntervalSince1970: 3_000)
        )
        let committed = staging.appending(path: "1.2.0-12", directoryHint: .isDirectory)
        #expect(staged.artifactPath == "Filicon-1.2.0.zip")
        #expect(FileManager.default.fileExists(atPath: committed.appending(path: staged.artifactPath).path))
        #expect(FileManager.default.fileExists(atPath: committed.appending(path: "staged-update.json").path))
        #expect((try FileManager.default.contentsOfDirectory(atPath: staging.path)).allSatisfy { !$0.hasPrefix(".pending-") })

        var tampered = artifact
        tampered.sha256 = String(repeating: "f", count: 64)
        #expect(throws: UpdateError.checksumMismatch) {
            try ArtifactVerifier.verify(file: source, artifact: tampered, signaturePolicy: .disabled)
        }
    }

    @Test func installPlanRejectsNonAppTargets() throws {
        _ = try UpdateInstallPlan(
            stagedArtifact: URL(fileURLWithPath: "/tmp/Filicon.zip"),
            expectedBundleIdentifier: "com.filicon.app",
            targetApplication: URL(fileURLWithPath: "/Applications/Filicon.app")
        )
        #expect(throws: UpdateError.self) {
            _ = try UpdateInstallPlan(
                stagedArtifact: URL(fileURLWithPath: "/tmp/Filicon.zip"),
                expectedBundleIdentifier: "com.filicon.app",
                targetApplication: URL(fileURLWithPath: "/tmp/not-an-app")
            )
        }
    }

    @Test func preparedInstallReplacesAtomicallyAndRollsBackOnPostMoveFailure() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appending(path: "Filicon.app", directoryHint: .isDirectory)
        let prepared = root.appending(path: "prepared/Filicon.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: target.appending(path: "marker"))
        try Data("new".utf8).write(to: prepared.appending(path: "marker"))
        let plan = try PreparedUpdateInstall(
            preparedApplication: prepared,
            targetApplication: target,
            expectedBundleIdentifier: "com.filicon.app",
            expectedVersion: "1.2.0",
            expectedBuild: 12,
            sourceProcessIdentifier: 0,
            relaunchAfterInstall: false
        )
        try PreparedUpdateApplier.apply(plan, verifier: { url, _, _, _ in
            guard FileManager.default.fileExists(atPath: url.appending(path: "marker").path) else {
                throw UpdateError.invalidApplicationBundle("missing fixture marker")
            }
        })
        #expect(try String(contentsOf: target.appending(path: "marker"), encoding: .utf8) == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.contains("backup-") })

        let preparedFailure = root.appending(path: "retry/Filicon.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: preparedFailure, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: preparedFailure.appending(path: "marker"))
        let failingPlan = try PreparedUpdateInstall(
            preparedApplication: preparedFailure,
            targetApplication: target,
            expectedBundleIdentifier: "com.filicon.app",
            expectedVersion: "1.3.0",
            expectedBuild: 13,
            sourceProcessIdentifier: 0,
            relaunchAfterInstall: false
        )
        #expect(throws: UpdateError.self) {
            try PreparedUpdateApplier.apply(failingPlan, verifier: { url, _, version, _ in
                let marker = try String(contentsOf: url.appending(path: "marker"), encoding: .utf8)
                if url.standardizedFileURL == target.standardizedFileURL, version != nil, marker == "bad" {
                    throw UpdateError.codeSignatureInvalid(-1)
                }
            })
        }
        #expect(try String(contentsOf: target.appending(path: "marker"), encoding: .utf8) == "new")
    }

    @Test func managerChecksChannelAndPublishesAvailableState() async throws {
        let artifact = UpdateArtifact(
            url: URL(string: "https://updates.example/Filicon.zip")!,
            format: .appZip,
            sha256: String(repeating: "a", count: 64),
            size: 10
        )
        let release = UpdateRelease(
            version: "1.1.0",
            build: 2,
            publishedAt: Date(timeIntervalSince1970: 1_000),
            minimumSystemVersion: "14.0",
            artifact: artifact
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(UpdateFeed(channel: .dogfood, releases: [release]))
        let service = UpdateService(feedLoader: { url in
            (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let manager = UpdateManager(service: service, stagingRoot: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let configuration = try UpdateConfiguration(
            channel: .dogfood,
            feedURL: URL(string: "https://updates.example/dogfood.json")!,
            automaticallyChecks: true,
            automaticallyDownloads: false,
            requiresSignature: false
        )
        let state = await manager.check(
            configuration: configuration,
            installed: .init(version: "1.0.0", build: 1),
            systemVersion: "14.6"
        )
        #expect(state == .available(release))
        #expect(await manager.snapshot() == .available(release))
    }
}
