import Foundation
import XCTest
@testable import Filicon

@MainActor
final class SkillPublishingAppIntegrationTests: XCTestCase {
    func testUnconfiguredPublishingFailsClosedAndInvalidEndpointIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSkillPublishingApp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        UserDefaults.standard.removeObject(forKey: "FiliconSkillPublishingEndpoint")
        defer { UserDefaults.standard.removeObject(forKey: "FiliconSkillPublishingEndpoint") }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        _ = try await model.privateSkillLibrary.create(id: "review", name: "Review", description: "Reviews", body: "Review")
        await model.publishPrivateSkill(id: "review", targetID: "team")
        XCTAssertEqual(model.errorMessage, l10n("Configure a publishing backend before changing a team marketplace."))
        let configured = await model.configureSkillPublishing(endpoint: "http://market.example", bearerToken: "secret")
        XCTAssertFalse(configured)
        XCTAssertTrue(model.skillPublishingEndpoint.isEmpty)
        XCTAssertTrue(model.skillPublishTargets.isEmpty)
    }
}
