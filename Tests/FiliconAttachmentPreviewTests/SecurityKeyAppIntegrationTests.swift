import Foundation
import XCTest
@testable import Filicon
import FiliconSecurityKey

@MainActor
final class SecurityKeyAppIntegrationTests: XCTestCase {
    func testSettingsTogglePersistsAndUnconfiguredBackendFailsClosed() async {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "FiliconSecurityKeyEnabled")
        defaults.set(false, forKey: "FiliconSecurityKeyEnabled")
        defer {
            if let previous { defaults.set(previous, forKey: "FiliconSecurityKeyEnabled") }
            else { defaults.removeObject(forKey: "FiliconSecurityKeyEnabled") }
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSecurityKeyApp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        XCTAssertFalse(model.securityKeyEnabled)

        await model.setSecurityKeyEnabled(true)
        if model.securityKeySupported {
            XCTAssertTrue(model.securityKeyEnabled)
            XCTAssertEqual(defaults.object(forKey: "FiliconSecurityKeyEnabled") as? Bool, true)
            guard case .failed(let message) = model.securityKeyStatus else {
                return XCTFail("An unconfigured security-key backend must fail closed")
            }
            XCTAssertTrue(message.contains("Keychain bearer credential"))
        } else {
            XCTAssertFalse(model.securityKeyEnabled)
            guard case .failed = model.securityKeyStatus else { return XCTFail("Unsupported platforms must fail closed") }
        }

        await model.setSecurityKeyEnabled(false)
        XCTAssertEqual(model.securityKeyStatus, .disabled)
    }

    func testConsentPresenterRequiresExplicitOneTimeResolutionAndCarriesOriginAndRPID() async {
        let presenter = AppSecurityKeyConsentPresenter()
        let consent = SecurityKeyConsent(
            requestID: "consent-1", origin: "https://login.example.com", rpID: "example.com", generation: 7
        )
        let decision = Task { await presenter.requestConsent(consent) }
        for _ in 0..<100 where presenter.pending == nil { await Task.yield() }
        XCTAssertEqual(presenter.pending?.consent.origin, consent.origin)
        XCTAssertEqual(presenter.pending?.consent.rpID, consent.rpID)
        presenter.resolve(approved: true)
        let approved = await decision.value
        XCTAssertTrue(approved)
        XCTAssertNil(presenter.pending)
    }
}
