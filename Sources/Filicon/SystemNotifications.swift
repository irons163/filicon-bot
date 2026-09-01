import AppKit
import Foundation
import UserNotifications
import FiliconAppServices

extension Notification.Name {
    static let filiconOpenDeepLink = Notification.Name("FiliconOpenDeepLink")
}

@MainActor
final class FiliconApplicationDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run Filicon` launches the executable without an enclosing
        // `.app` bundle. UserNotifications requires an app bundle proxy, so
        // keep the development executable usable while retaining notifications
        // for packaged macOS builds.
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["deepLink"] as? String,
              let url = URL(string: raw),
              FiliconDeepLink(url: url) != nil else { return }
        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .filiconOpenDeepLink, object: url)
        }
    }
}

@MainActor
final class SystemNotificationService: ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var unreadCount = 0
    private var throttle = NotificationThrottle(minimumInterval: 30)
    private var agentDecider = AgentNotificationDecider()
    private var dockBadgeProjector = DockBadgeProjector()
    private var agentBadgeCount = 0
    private var accountTransport = AccountNotificationTransport()

    var notificationTransportIsActive: Bool { accountTransport.isActive }

    @discardableResult
    func activateNotificationTransport(scopeID: String) -> Bool {
        let transition = accountTransport.activate(scopeID: scopeID)
        guard transition != .unchanged else { return false }
        resetProjectedState()
        removeDeliveredNotifications()
        return true
    }

    @discardableResult
    func deactivateNotificationTransport() -> Bool {
        let transition = accountTransport.deactivate()
        guard transition != .unchanged else { return false }
        resetProjectedState()
        removeDeliveredNotifications()
        return true
    }

    func refreshAuthorization() async {
        guard Self.canUseUserNotifications else { return }
        authorizationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws {
        guard Self.canUseUserNotifications else { return }
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refreshAuthorization()
    }

    func deliverCompletion(conversationID: UUID, title: String, preview: String) async {
        guard accountTransport.isActive else { return }
        guard !NSApplication.shared.isActive else { return }
        guard Self.canUseUserNotifications else { return }
        guard throttle.shouldDeliver(key: conversationID.uuidString) else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? "Filicon" : title
        content.body = String(preview.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        content.sound = .default
        content.userInfo = ["deepLink": FiliconDeepLink.conversation(conversationID).url.absoluteString]
        try? await UNUserNotificationCenter.current().add(.init(
            identifier: "conversation-\(conversationID.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
        unreadCount += 1
        refreshDockBadge()
    }

    func seedAgentNotificationBaseline(_ snapshots: [AgentNotificationSnapshot]) {
        guard accountTransport.isActive else { return }
        agentDecider.seedBaseline(snapshots)
    }

    func handleAgentRoster(_ snapshots: [AgentNotificationSnapshot]) async {
        guard accountTransport.isActive else { return }
        let transitions = agentDecider.decide(
            agents: snapshots,
            isWindowFocused: NSApplication.shared.isActive
        )
        await deliverAgentTransitions(transitions)
    }

    func handleAgentSnapshot(_ snapshot: AgentNotificationSnapshot) async {
        guard accountTransport.isActive else { return }
        let transitions = agentDecider.decide(
            agent: snapshot,
            isWindowFocused: NSApplication.shared.isActive
        )
        await deliverAgentTransitions(transitions)
    }

    func updateAgentDockBadge(_ snapshots: [DockBadgeAgentSnapshot]) {
        guard accountTransport.isActive else {
            agentBadgeCount = 0
            refreshDockBadge()
            return
        }
        agentBadgeCount = dockBadgeProjector.apply(roster: snapshots)
        refreshDockBadge()
    }

    func forgetAgent(_ id: UUID) {
        let agentID = id.uuidString.lowercased()
        agentDecider.forget(agentID: agentID)
        agentBadgeCount = dockBadgeProjector.forget(id: agentID)
        refreshDockBadge()
    }

    func resetAgentState() {
        resetProjectedState()
    }

    func markAllViewed() {
        unreadCount = 0
        throttle.reset()
        refreshDockBadge()
    }

    private func deliverAgentTransitions(_ transitions: [AgentNotificationTransition]) async {
        guard accountTransport.isActive else { return }
        guard !transitions.isEmpty else { return }
        guard Self.canUseUserNotifications else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for transition in transitions {
            guard let id = UUID(uuidString: transition.agentID) else { continue }
            let value = transition.content
            let content = UNMutableNotificationContent()
            content.title = value.title
            content.body = value.body
            content.userInfo = ["deepLink": FiliconDeepLink.agent(id).url.absoluteString]
            if transition.kind == .needsInput {
                content.sound = .default
                content.interruptionLevel = .timeSensitive
            }
            try? await UNUserNotificationCenter.current().add(.init(
                identifier: "agent-\(transition.agentID)-\(transition.kind.rawValue)-\(UUID().uuidString)",
                content: content,
                trigger: nil
            ))
        }
    }

    private func refreshDockBadge() {
        let total = unreadCount + agentBadgeCount
        NSApplication.shared.dockTile.badgeLabel = total == 0 ? nil : String(total)
    }

    private func resetProjectedState() {
        agentDecider.reset()
        agentBadgeCount = dockBadgeProjector.reset()
        unreadCount = 0
        throttle.reset()
        refreshDockBadge()
    }

    private func removeDeliveredNotifications() {
        guard Self.canUseUserNotifications else { return }
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private static var canUseUserNotifications: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}
