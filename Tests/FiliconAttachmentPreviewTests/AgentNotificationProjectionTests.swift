import XCTest
import FiliconAgents
import FiliconDomain
@testable import Filicon

final class AgentNotificationProjectionTests: XCTestCase {
    func testProjectionUsesLatestTerminalTaskAndHidesArchivedAgents() {
        let agentID = UUID()
        let profile = AgentProfile(
            id: agentID,
            name: "Scout",
            archivedAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 40),
            unreadCount: 3
        )
        let old = task(id: UUID(), agentID: agentID, status: .succeeded, startedAt: 10, result: "old")
        let latestID = UUID()
        let latest = task(id: latestID, agentID: agentID, status: .succeeded, startedAt: 20, result: "final result")

        let notifications = AgentNotificationProjection.notificationSnapshots(profiles: [profile], tasks: [latest, old])
        XCTAssertEqual(notifications.first?.lastMessageID, latestID.uuidString.lowercased())
        XCTAssertEqual(notifications.first?.lastMessagePreview, "final result")
        XCTAssertEqual(notifications.first?.isHidden, true)

        let dock = AgentNotificationProjection.dockSnapshots(profiles: [profile], tasks: [latest, old])
        XCTAssertEqual(dock.first?.unreadCount, 3)
        XCTAssertEqual(dock.first?.isHidden, true)
        // Dock freshness follows the profile update/task completion fence;
        // archival time is represented by isHidden and must not fabricate a
        // newer roster sequence.
        XCTAssertEqual(dock.first?.sequence, 40_000)
    }

    func testProjectionTreatsTaskAndProfileAwaitingInputAsActive() {
        let firstID = UUID(), secondID = UUID()
        let profiles = [
            AgentProfile(id: firstID, name: "One", status: .idle),
            AgentProfile(id: secondID, name: "Two", status: .awaitingInput),
        ]
        let pending = task(id: UUID(), agentID: firstID, status: .awaitingInput, startedAt: 10, result: nil)

        let values = AgentNotificationProjection.notificationSnapshots(profiles: profiles, tasks: [pending])
        XCTAssertEqual(values[0].isRunning, true)
        XCTAssertEqual(values[0].awaitingReason, "Task is waiting for your input.")
        XCTAssertNil(values[0].lastMessageID)
        XCTAssertEqual(values[1].isRunning, false)
        XCTAssertEqual(values[1].awaitingReason, "Waiting for your input.")
    }

    private func task(
        id: UUID,
        agentID: UUID,
        status: AgentRunStatus,
        startedAt: TimeInterval,
        result: String?
    ) -> AgentAsyncTask {
        AgentAsyncTask(record: SubagentRecord(
            id: id,
            parentRunID: UUID(),
            parentToolCallID: "call",
            agentID: agentID,
            title: "Task",
            status: status,
            depth: 0,
            startedAt: Date(timeIntervalSince1970: startedAt),
            finishedAt: status.isInFlight ? nil : Date(timeIntervalSince1970: startedAt + 1),
            result: result
        ))
    }
}
