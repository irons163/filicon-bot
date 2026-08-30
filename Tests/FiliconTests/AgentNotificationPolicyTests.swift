import Foundation
import Testing
@testable import FiliconAppServices

@Suite("Agent notification policy")
struct AgentNotificationPolicyTests {
    @Test func onlyNotifiesMeaningfulDoneAndNeedsInputTransitions() {
        var policy = AgentNotificationDecider()
        let start = Date(timeIntervalSince1970: 1_000)
        policy.seedBaseline([snapshot(running: true, messageID: "old")])
        #expect(policy.decide(agent: snapshot(running: false, messageID: "old"), isWindowFocused: false, now: start).isEmpty)
        policy.observe(snapshot(running: true, messageID: "old"))
        let done = policy.decide(agent: snapshot(running: false, messageID: "new", preview: "Finished"), isWindowFocused: false, now: start)
        #expect(done.map(\.kind) == [.done])
        policy.observe(snapshot(running: false, awaiting: nil, messageID: "new"))
        let needsInput = policy.decide(agent: snapshot(running: false, awaiting: "Choose a branch", messageID: "new"), isWindowFocused: false, now: start)
        #expect(needsInput.map(\.kind) == [.needsInput])
    }

    @Test func focusPreferencesHiddenStateAndThrottleFailClosed() {
        var policy = AgentNotificationDecider()
        let start = Date(timeIntervalSince1970: 2_000)
        policy.seedBaseline([snapshot(running: true, messageID: "a")])
        #expect(policy.decide(agent: snapshot(running: false, messageID: "b"), isWindowFocused: true, now: start).isEmpty)
        policy.observe(snapshot(running: true, messageID: "b"))
        #expect(policy.decide(agent: snapshot(running: false, messageID: "c", enabled: false), isWindowFocused: false, now: start).isEmpty)
        policy.observe(snapshot(running: true, messageID: "c", hidden: true))
        #expect(policy.decide(agent: snapshot(running: false, messageID: "d", hidden: true), isWindowFocused: false, now: start).isEmpty)
        policy.observe(snapshot(running: false, awaiting: nil, messageID: "d"))
        #expect(policy.decide(agent: snapshot(running: false, awaiting: "first", messageID: "d"), isWindowFocused: false, now: start).count == 1)
        policy.observe(snapshot(running: false, awaiting: nil, messageID: "d"))
        #expect(policy.decide(agent: snapshot(running: false, awaiting: "again", messageID: "d"), isWindowFocused: false, now: start.addingTimeInterval(4)).isEmpty)
        policy.observe(snapshot(running: false, awaiting: nil, messageID: "d"))
        #expect(policy.decide(agent: snapshot(running: false, awaiting: "later", messageID: "d"), isWindowFocused: false, now: start.addingTimeInterval(5)).count == 1)
    }

    @Test func contentIsWhitespaceCollapsedAndBounded() {
        let long = String(repeating: "word \n", count: 40)
        let transition = AgentNotificationTransition(agentID: "a", agentName: "", kind: .done, lastMessagePreview: long)
        #expect(transition.content.title == "Your agent")
        #expect(transition.content.body.count == 140)
        #expect(transition.content.body.last == "…")
        #expect(!transition.content.body.contains("\n"))
    }

    @Test func dockBadgeUsesUnreadTotalsAndRejectsStaleRows() {
        var projector = DockBadgeProjector()
        #expect(projector.apply(roster: [
            .init(id: "a", hasUnread: true, unreadCount: 4, epoch: "one", sequence: 2),
            .init(id: "b", hasUnread: true, unreadCount: nil, epoch: "one", sequence: 2),
            .init(id: "hidden", hasUnread: true, unreadCount: 10, isHidden: true, epoch: "one", sequence: 2),
        ]) == 5)
        #expect(projector.upsert(.init(id: "a", hasUnread: false, epoch: "one", sequence: 1)) == 5)
        #expect(projector.upsert(.init(id: "a", hasUnread: false, epoch: "one", sequence: 3)) == 1)
        #expect(projector.apply(roster: []) == 1)
        #expect(projector.reset() == 0)
    }

    @Test func accountTransportFencesStaleWorkAcrossLogoutAndAccountChanges() {
        var transport = AccountNotificationTransport()
        #expect(!transport.isActive)
        #expect(transport.activate(scopeID: " account-a ") == .activated(scopeID: "account-a", revision: 1))
        #expect(transport.accepts(scopeID: "account-a", revision: 1))
        #expect(transport.activate(scopeID: "account-a") == .unchanged)

        #expect(transport.deactivate() == .deactivated(revision: 2))
        #expect(!transport.accepts(scopeID: "account-a", revision: 1))
        #expect(transport.deactivate() == .unchanged)

        #expect(transport.activate(scopeID: "account-b") == .activated(scopeID: "account-b", revision: 3))
        #expect(transport.accepts(scopeID: "account-b", revision: 3))
        #expect(transport.activate(scopeID: "   ") == .deactivated(revision: 4))
    }

    private func snapshot(
        running: Bool,
        awaiting: String? = nil,
        messageID: String?,
        preview: String? = nil,
        enabled: Bool = true,
        hidden: Bool = false
    ) -> AgentNotificationSnapshot {
        .init(id: "agent", name: "Builder", isRunning: running, awaitingReason: awaiting, notifyEnabled: enabled, isHidden: hidden, lastMessageID: messageID, lastMessagePreview: preview)
    }
}
