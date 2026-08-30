import Foundation
import Testing
@testable import FiliconAppServices

@Suite("In-app notification center")
struct InAppNotificationCenterTests {
    @Test func deduplicatesByKeyAndPreservesIdentity() async throws {
        let fixedID = UUID()
        let center = InAppNotificationCenter(makeID: { fixedID }, now: { Date(timeIntervalSince1970: 1_000) })
        let first = try await center.pushError(.init(agentID: "agent-a", title: "Failure", detail: "first", dedupeKey: "sync"))
        let second = try await center.pushError(.init(agentID: "other-agent", title: "Retry failed", detail: "second", dedupeKey: "sync"))
        #expect(first.id == second.id)
        #expect(second.agentID == "agent-a")
        #expect(second.count == 2)
        #expect(await center.list() == [second])
    }

    @Test func enforcesTwentyTrayCapAndEmitsDrop() async throws {
        let center = InAppNotificationCenter()
        let stream = await center.events()
        for index in 0...InAppNotificationCenter.maximumTrays {
            _ = try await center.pushError(.init(title: "Failure \(index)", detail: "detail"))
        }
        let trays = await center.list()
        #expect(trays.count == InAppNotificationCenter.maximumTrays)
        #expect(trays.first?.title == "Failure 1")

        var iterator = stream.makeAsyncIterator()
        var pushed = 0
        var dismissed = 0
        for _ in 0..<(InAppNotificationCenter.maximumTrays + 2) {
            switch await iterator.next() {
            case .pushed: pushed += 1
            case .dismissed: dismissed += 1
            default: break
            }
        }
        #expect(pushed == InAppNotificationCenter.maximumTrays + 1)
        #expect(dismissed == 1)
    }

    @Test func dismissClearAndAgentClearHaveExactEvents() async throws {
        let center = InAppNotificationCenter()
        let stream = await center.events()
        let first = try await center.pushError(.init(agentID: "a", title: "A", detail: ""))
        _ = try await center.pushError(.init(agentID: "b", title: "B", detail: ""))
        await center.clear(agentID: "a")
        #expect(!(await center.dismiss(id: first.id)))
        await center.clearAll()
        #expect(await center.list().isEmpty)

        var iterator = stream.makeAsyncIterator()
        var values: [NotificationTrayEvent] = []
        for _ in 0..<4 {
            if let value = await iterator.next() { values.append(value) }
        }
        #expect(values.count == 4)
        #expect(values[2] == .dismissed(first.id))
        #expect(values[3] == .cleared)
    }

    @Test func validatesActionsAndBounds() async throws {
        let center = InAppNotificationCenter()
        let safe = try NotificationTrayAction.openURL(label: "Help", rawURL: "https://example.com/help")
        _ = try await center.pushError(.init(title: "Failure", detail: "detail", actions: [safe]))
        #expect(throws: NotificationTrayError.unsafeURL) {
            try NotificationTrayAction.openURL(label: "Open", rawURL: "file:///etc/passwd")
        }
        #expect(throws: NotificationTrayError.unsafeURL) {
            try NotificationTrayAction.openURL(label: "Open", rawURL: "https://user:secret@example.com")
        }
        await #expect(throws: NotificationTrayError.boundsExceeded) {
            try await center.pushError(.init(title: "Failure", detail: "", actions: [safe, safe, safe, safe]))
        }
        await #expect(throws: NotificationTrayError.invalidTitle) {
            try await center.pushError(.init(title: "   ", detail: ""))
        }
    }

    @Test func dashboardArgumentsRoundTripWithoutTypeCoercion() throws {
        let action = try NotificationTrayAction.validatedDashboard(
            label: "Retry",
            action: "computer.retry",
            arguments: ["force": .bool(true), "attempt": .number(2), "nested": .object(["value": .null])],
            successMessage: "Retry started"
        )
        let encoded = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(NotificationTrayAction.self, from: encoded) == action)
    }
}
