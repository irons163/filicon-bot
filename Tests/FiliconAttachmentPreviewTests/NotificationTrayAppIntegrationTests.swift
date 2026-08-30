import AppKit
import Foundation
import Testing
import FiliconAppServices
@testable import Filicon

@Suite("Notification tray app integration")
struct NotificationTrayAppIntegrationTests {
    @Test @MainActor func modelPublishesDedupesDismissesAndClearsActorTrays() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-notifications-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        await model.publishNotificationError("same failure")
        await model.publishNotificationError("same failure")
        await Self.settle()

        #expect(model.notificationTrays.count == 1)
        #expect(model.notificationTrays.first?.count == 2)
        if let id = model.notificationTrays.first?.id {
            await model.dismissNotification(id: id)
        }
        await Self.settle()
        #expect(model.notificationTrays.isEmpty)

        await model.publishNotificationError("one")
        await model.publishNotificationError("two")
        await model.clearNotifications()
        await Self.settle()
        #expect(model.notificationTrays.isEmpty)
    }

    @Test @MainActor func dashboardActionsUseOnlyExactLocalAllowlist() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-notification-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let allowed = try NotificationTrayAction.validatedDashboard(
            label: "Computer", action: "dashboard.computer"
        )
        let denied = try NotificationTrayAction.validatedDashboard(
            label: "Dispatch", action: "computer.retry",
            arguments: ["force": .bool(true)]
        )
        let unsafeURL = NotificationTrayAction.openURL(
            label: "Local file", url: URL(fileURLWithPath: "/etc/passwd")
        )

        #expect((await model.performNotificationAction(allowed)).succeeded)
        #expect(model.route == .computer)
        #expect(!(await model.performNotificationAction(denied)).succeeded)
        #expect(!(await model.performNotificationAction(unsafeURL)).succeeded)
    }

    @Test @MainActor func oversizedUnicodeNotificationIsTruncatedAtAValidUTF8Boundary() async {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-notification-unicode-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        await model.publishNotificationError(String(repeating: "🙂", count: 4_097))
        await Self.settle()

        let detail = model.notificationTrays.first?.detail ?? ""
        #expect(!detail.isEmpty)
        #expect(detail.utf8.count <= 16 * 1_024)
        #expect(!detail.contains("�"))
    }

    @MainActor private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
