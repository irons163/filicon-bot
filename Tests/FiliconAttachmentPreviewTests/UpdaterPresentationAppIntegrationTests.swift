import Foundation
import Testing
import FiliconUpdater
import FiliconComputer
@testable import Filicon

@Suite("Updater app presentation")
struct UpdaterPresentationAppIntegrationTests {
    @Test func pillExposesDownloadInstallProgressAndRetryActions() throws {
        let release = fixtureRelease()
        let staged = StagedUpdate(release: release, artifactPath: "Filicon.zip", stagedAt: .now)

        #expect(UpdatePillPresentation.make(state: .available(release))?.action == .download)
        #expect(UpdatePillPresentation.make(state: .downloading(release))?.action == nil)
        #expect(UpdatePillPresentation.make(state: .staged(staged, directory: URL(fileURLWithPath: "/tmp/staged")))?.action == .install)
        let failed = try #require(UpdatePillPresentation.make(state: .failed("offline")))
        #expect(failed.action == .check)
        #expect(failed.isError)
    }

    @Test func requiredOverlayAlwaysOffersTheActionThatCanAdvanceCurrentState() {
        let release = fixtureRelease()
        let staged = StagedUpdate(release: release, artifactPath: "Filicon.zip", stagedAt: .now)
        #expect(RequiredUpdatePresentation.make(state: .idle).action == .check)
        #expect(RequiredUpdatePresentation.make(state: .available(release)).action == .download)
        #expect(RequiredUpdatePresentation.make(state: .staged(staged, directory: URL(fileURLWithPath: "/tmp/staged"))).action == .install)
        #expect(RequiredUpdatePresentation.make(state: .failed("offline")).actionLabel == "Retry")
    }

    @Test @MainActor func appModelPublishesMinimumVersionRequirement() {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "FiliconMinimumRequiredVersion")
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-update-policy-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            if let previous { defaults.set(previous, forKey: "FiliconMinimumRequiredVersion") }
            else { defaults.removeObject(forKey: "FiliconMinimumRequiredVersion") }
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        model.setMinimumRequiredVersionForPolicy("999.0.0")
        #expect(model.isUpdateRequired)
        model.setMinimumRequiredVersionForPolicy(nil)
        #expect(!model.isUpdateRequired)
    }

    @Test @MainActor func explicitInstallNeverStartsWhileAppHasActiveWork() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-update-busy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let release = fixtureRelease()
        let staged = StagedUpdate(release: release, artifactPath: "Filicon.zip", stagedAt: .now)
        model.updateState = .staged(staged, directory: root)
        model.running.insert(UUID())

        await model.installStagedUpdate()

        #expect(model.updateState == .staged(staged, directory: root))
        #expect(model.errorMessage?.contains("busy") == true)
    }

    @Test @MainActor func remoteLifecycleRequirementImmediatelyRaisesRuntimeGate() async {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: "FiliconMinimumRequiredVersion")
        defaults.removeObject(forKey: "FiliconMinimumRequiredVersion")
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-update-runtime-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            if let previous { defaults.set(previous, forKey: "FiliconMinimumRequiredVersion") }
            else { defaults.removeObject(forKey: "FiliconMinimumRequiredVersion") }
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        await model.applyRemoteComputerStatus(.init(state: .running, minimumAppVersion: "999.0.0"))

        #expect(model.minimumRequiredVersion == "999.0.0")
        #expect(model.isUpdateRequired)
        let persisted = await BackendUpdatePolicyStore(
            fileURL: root.appending(path: "updates/backend-requirements.json")
        ).snapshot()
        #expect(persisted.minimumVersionsByScope["remote-computer:lifecycle"] == "999.0.0")
    }

    private func fixtureRelease() -> UpdateRelease {
        .init(
            version: "2.0.0", build: 20, publishedAt: .now, minimumSystemVersion: "14.0",
            artifact: .init(
                url: URL(string: "https://updates.example/Filicon.zip")!, format: .appZip,
                sha256: String(repeating: "a", count: 64), size: 10
            )
        )
    }
}
