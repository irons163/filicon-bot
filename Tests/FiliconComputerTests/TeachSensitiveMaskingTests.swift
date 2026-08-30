import Foundation
import XCTest
@testable import FiliconComputer

private actor WindowInventoryStub: TeachWindowInventory {
    var result: Result<[TeachWindowDescriptor], Error>
    init(_ windows: [TeachWindowDescriptor]) { result = .success(windows) }
    func windows() async throws -> [TeachWindowDescriptor] { try result.get() }
    func set(_ windows: [TeachWindowDescriptor]) { result = .success(windows) }
    func fail() { result = .failure(CocoaError(.fileReadUnknown)) }
}
private actor FilterUpdaterSpy: TeachSensitiveFilterUpdater {
    var updates: [Set<UInt32>] = []; var shouldFail = false
    func updateExcludedWindowIDs(_ ids: Set<UInt32>) async throws { if shouldFail { throw CocoaError(.fileWriteUnknown) }; updates.append(ids) }
    func configureFailure(_ value: Bool) { shouldFail = value }
    func values() -> [Set<UInt32>] { updates }
}
private actor BlackoutSpy: TeachCaptureBlackout {
    var values: [Bool] = []
    func setBlackout(_ enabled: Bool) { values.append(enabled) }
    func recorded() -> [Bool] { values }
}

final class TeachSensitiveMaskingTests: XCTestCase {
    func testDefaultClassifierMasksFiliconConsentAuthPasswordAndSecureText() {
        let classifier = DefaultSensitiveWindowClassifier(ownBundleIdentifier: "app.filicon")
        XCTAssertEqual(classifier.classify(window(1, bundle: "app.filicon", title: "Main", secure: false)), .sensitive)
        XCTAssertEqual(classifier.classify(window(2, bundle: "com.apple.SecurityAgent", title: "Authorization", secure: nil)), .sensitive)
        XCTAssertEqual(classifier.classify(window(3, bundle: "com.1password.1password", title: "Vault", secure: false)), .sensitive)
        XCTAssertEqual(classifier.classify(window(4, bundle: "com.example.editor", title: "Password", secure: true)), .sensitive)
        XCTAssertEqual(classifier.classify(window(5, bundle: "com.example.editor", title: "Notes", secure: false)), .safe)
        XCTAssertEqual(classifier.classify(window(6, bundle: nil, title: nil, secure: nil)), .unknown)
    }

    func testDynamicInventoryUpdatesExclusionsAndStatusMetadata() async throws {
        let inventory = WindowInventoryStub([
            window(1, bundle: "app.filicon", title: "Filicon", secure: false),
            window(2, bundle: "com.example.editor", title: "Document", secure: false),
        ])
        let updater = FilterUpdaterSpy(); let blackout = BlackoutSpy()
        let controller = TeachSensitiveMaskingController(inventory: inventory, classifier: DefaultSensitiveWindowClassifier(ownBundleIdentifier: "app.filicon"), updater: updater, blackout: blackout)
        let first = try await controller.refresh()
        XCTAssertEqual(first.maskedCount, 1); XCTAssertFalse(first.isPaused); XCTAssertEqual(first.excludedWindowIDs, [1])
        XCTAssertTrue(first.policy.failClosed); XCTAssertTrue(first.policy.dynamicallyUpdated)

        await inventory.set([window(3, bundle: "com.apple.SecurityAgent", title: "Consent", secure: nil)])
        let second = try await controller.refresh()
        XCTAssertEqual(second.excludedWindowIDs, [3])
        let updates = await updater.values()
        XCTAssertEqual(updates, [[1], [3]])
    }

    func testUnknownWindowBlackoutsAndNeverRecordsBare() async throws {
        let inventory = WindowInventoryStub([window(9, bundle: nil, title: nil, secure: nil)])
        let updater = FilterUpdaterSpy(); let blackout = BlackoutSpy()
        let controller = TeachSensitiveMaskingController(inventory: inventory, classifier: DefaultSensitiveWindowClassifier(), updater: updater, blackout: blackout)
        let status = try await controller.refresh()
        XCTAssertTrue(status.isPaused); XCTAssertEqual(status.pausedCount, 1); XCTAssertEqual(status.excludedWindowIDs, [9])
        let blackouts = await blackout.recorded()
        XCTAssertEqual(blackouts, [true, true])
    }

    func testInventoryAndFilterFailureRemainBlackoutFailClosed() async throws {
        let inventory = WindowInventoryStub([window(1, bundle: "app.filicon", title: "Self", secure: false)])
        let updater = FilterUpdaterSpy(); let blackout = BlackoutSpy()
        let controller = TeachSensitiveMaskingController(inventory: inventory, classifier: DefaultSensitiveWindowClassifier(), updater: updater, blackout: blackout)
        await updater.configureFailure(true)
        await XCTAssertThrowsComputerAsync { _ = try await controller.refresh() }
        let failedStatus = await controller.currentStatus()
        XCTAssertTrue(failedStatus.isPaused)
        await inventory.fail()
        await XCTAssertThrowsComputerAsync { _ = try await controller.refresh() }
        let blackouts = await blackout.recorded()
        XCTAssertTrue(blackouts.allSatisfy { $0 })
    }

    func testTeachStatusCarriesMaskCountsAndPolicy() async throws {
        let backend = TestTeachBackend()
        let controller = TeachRecordingController(backend: backend, sessionsDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let policy = TeachMaskingPolicyMetadata(classifier: "test")
        await controller.reportMaskingStatus(.init(maskedCount: 4, pausedCount: 2, isPaused: true, excludedWindowIDs: [1, 2, 3, 4], policy: policy))
        let status = await controller.currentStatus()
        XCTAssertEqual(status.maskedWindowCount, 4); XCTAssertEqual(status.pausedSensitiveWindowCount, 2); XCTAssertEqual(status.maskingPolicy, policy)
    }

    private func window(_ id: UInt32, bundle: String?, title: String?, secure: Bool?) -> TeachWindowDescriptor {
        .init(windowID: id, ownerName: bundle, ownerBundleIdentifier: bundle, title: title, isOnScreen: true, secureTextKnown: secure)
    }
}
