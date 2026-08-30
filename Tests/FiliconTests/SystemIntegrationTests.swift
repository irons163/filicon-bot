import Foundation
import Testing
import FiliconAppServices

@Suite("macOS integration contracts")
struct SystemIntegrationTests {
    @Test func conversationDeepLinkRoundTrips() throws {
        let id = UUID()
        let link = FiliconDeepLink.conversation(id)
        #expect(FiliconDeepLink(url: link.url) == link)
        #expect(link.url.absoluteString == "filicon://conversation/\(id.uuidString)")
    }

    @Test func agentDeepLinkRoundTrips() {
        let id = UUID()
        let link = FiliconDeepLink.agent(id)
        #expect(FiliconDeepLink(url: link.url) == link)
        #expect(link.url.absoluteString == "filicon://agent/\(id.uuidString)")
        #expect(FiliconDeepLink(url: URL(string: "filicon://agent/not-a-uuid")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://agent/\(id)?extra=true")!) == nil)
    }

    @Test func rejectsForeignAndMalformedDeepLinks() {
        #expect(FiliconDeepLink(url: URL(string: "https://conversation/\(UUID())")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://conversation/not-a-uuid")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://settings/\(UUID())")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://conversation/\(UUID())?extra=true")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://user@conversation/\(UUID())")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://conversation/../\(UUID())")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://app/v1/open#fragment")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://app/v1/plugin/add?id=1&id=2")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://app/v1/plugin/add?id=%2e%2e")!) == nil)
        #expect(FiliconDeepLink(url: URL(string: "filicon://shared-room/join?token=short")!) == nil)
    }

    @Test func supportedDeepLinksRoundTripCanonically() {
        let token = String(repeating: "A", count: 43)
        let links: [FiliconDeepLink] = [
            .sharedRoomJoin(token: token),
            .pluginAdd(id: "123456789"),
            .open,
            .infoDeepLinks,
        ]
        for link in links {
            #expect(FiliconDeepLink(url: link.url) == link)
        }
        #expect(FiliconDeepLink.sharedRoomJoin(token: token).url.absoluteString == "filicon://shared-room/join?token=\(token)")
        #expect(FiliconDeepLink.pluginAdd(id: "123456789").url.absoluteString == "filicon://app/v1/plugin/add?id=123456789")
    }

    @Test func deepLinksQueueUntilReadyAndDeduplicate() {
        let first = FiliconDeepLink.open.url
        let second = FiliconDeepLink.infoDeepLinks.url
        var coordinator = DeepLinkCoordinator()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(coordinator.handle(first, at: start) == .queued)
        #expect(coordinator.handle(first, at: start.addingTimeInterval(1)) == .duplicate)
        #expect(coordinator.handle(second, at: start.addingTimeInterval(1)) == .queued)
        #expect(coordinator.markReady() == [.open, .infoDeepLinks])
        #expect(coordinator.handle(first, at: start.addingTimeInterval(3)) == .dispatch(.open))
    }

    @Test func deepLinkPendingQueueIsBounded() {
        var coordinator = DeepLinkCoordinator()
        let start = Date(timeIntervalSince1970: 2_000)
        for value in 1...DeepLinkCoordinator.pendingLimit {
            let id = String(value)
            #expect(coordinator.handle(FiliconDeepLink.pluginAdd(id: id).url, at: start) == .queued)
        }
        #expect(coordinator.handle(FiliconDeepLink.pluginAdd(id: "999").url, at: start) == .queueFull)
    }

    @Test func notificationThrottleIsScopedAndResettable() {
        var throttle = NotificationThrottle(minimumInterval: 30)
        let now = Date(timeIntervalSince1970: 1_000)
        let firstA = throttle.shouldDeliver(key: "a", at: now)
        let throttledA = throttle.shouldDeliver(key: "a", at: now.addingTimeInterval(29))
        let firstB = throttle.shouldDeliver(key: "b", at: now.addingTimeInterval(1))
        let resumedA = throttle.shouldDeliver(key: "a", at: now.addingTimeInterval(30))
        #expect(firstA)
        #expect(!throttledA)
        #expect(firstB)
        #expect(resumedA)
        throttle.reset(key: "a")
        let resetA = throttle.shouldDeliver(key: "a", at: now.addingTimeInterval(31))
        #expect(resetA)
    }
}
