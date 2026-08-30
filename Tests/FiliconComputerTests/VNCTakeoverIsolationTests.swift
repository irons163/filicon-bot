import Foundation
import XCTest
@testable import FiliconComputer

private actor HandbackSpy {
    private var values: [(String, UInt64)] = []
    func record(_ id: String, _ generation: UInt64) { values.append((id, generation)) }
    func count() -> Int { values.count }
}

final class VNCTakeoverIsolationTests: XCTestCase {
    func testTakeoverHeartbeatPresenceHandbackAndReplay() async throws {
        let clock = ComputerTestMilliseconds(100)
        let handbacks = HandbackSpy()
        let controller = VNCTakeoverController(now: clock.now, handback: { await handbacks.record($0, $1) })
        await controller.reportUserPresence(false)
        let request = UUID()
        let lease = try await controller.requestTakeover(controllerID: "agent-a", deadlineMilliseconds: 1_000, requestID: request)
        XCTAssertEqual(lease.generation, 1)
        await XCTAssertThrowsComputerAsync { _ = try await controller.requestTakeover(controllerID: "agent-a", deadlineMilliseconds: 1_000, requestID: request) }
        await XCTAssertThrowsComputerAsync { _ = try await controller.requestTakeover(controllerID: "agent-b", deadlineMilliseconds: 1_000, requestID: UUID()) }
        let renewed = try await controller.heartbeat(controllerID: "agent-a", generation: lease.generation, deadlineMilliseconds: 2_000, requestID: UUID())
        XCTAssertEqual(renewed.deadlineMilliseconds, 2_000)

        await controller.reportUserPresence(true)
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.owner, VNCControlOwner.user); XCTAssertNil(snapshot.lease)
        let handbackCount = await handbacks.count()
        XCTAssertEqual(handbackCount, 1)
        await XCTAssertThrowsComputerAsync { _ = try await controller.requestTakeover(controllerID: "agent-a", deadlineMilliseconds: 3_000, requestID: UUID()) }
    }

    func testDeadlineAndCancelHandBackExactlyOnce() async throws {
        let clock = ComputerTestMilliseconds()
        let handbacks = HandbackSpy()
        let controller = VNCTakeoverController(now: clock.now, handback: { await handbacks.record($0, $1) })
        let lease = try await controller.requestTakeover(controllerID: "agent", deadlineMilliseconds: 500, requestID: UUID())
        clock.advance(500)
        await controller.tick(); await controller.tick()
        let firstCount = await handbacks.count()
        XCTAssertEqual(firstCount, 1)
        await controller.reportUserPresence(false)
        let next = try await controller.requestTakeover(controllerID: "agent", deadlineMilliseconds: 1_000, requestID: UUID())
        XCTAssertGreaterThan(next.generation, lease.generation)
        try await controller.cancel(controllerID: "agent", generation: next.generation, requestID: UUID())
        let secondCount = await handbacks.count()
        XCTAssertEqual(secondCount, 2)
    }

    func testConcurrentTakeoverAllowsOnlyOneController() async throws {
        let controller = VNCTakeoverController(now: { 0 }, handback: { _, _ in })
        let winners = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            for id in ["a", "b", "c", "d"] {
                group.addTask {
                    (try? await controller.requestTakeover(controllerID: id, deadlineMilliseconds: 1_000, requestID: UUID()))?.controllerID
                }
            }
            var result: [String] = []
            for await value in group { if let value { result.append(value) } }
            return result
        }
        XCTAssertEqual(winners.count, 1)
        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.lease?.controllerID, winners.first)
    }

    func testIsolationMessageNavigationTokenAndCrashPolicy() async throws {
        let clock = ComputerTestMilliseconds()
        let policy = try VNCIsolationPolicy(accountID: "account", computerID: "computer", allowedOrigin: "https://box.example", tokenOrigin: "https://box.example:443", allowedMethods: [.readClipboard], now: clock.now)
        let session = await policy.currentSession()
        let message = VNCContentMessage(method: VNCWebCapability.readClipboard.rawValue, requestID: UUID(), generation: session.generation, payload: ["trigger": VNCClipboardTrigger.explicitGesture.rawValue])
        let data = try JSONEncoder().encode(message)
        let validated = try await policy.validateMessage(data, frameURL: URL(string: "https://box.example/vnc.html")!, contentWorld: VNCIsolationPolicy.contentWorldName)
        XCTAssertEqual(validated, message)
        await XCTAssertThrowsComputerAsync {
            _ = try await policy.validateMessage(data, frameURL: URL(string: "https://box.example/vnc.html")!, contentWorld: VNCIsolationPolicy.contentWorldName)
        }
        await XCTAssertThrowsComputerAsync {
            _ = try await policy.validateMessage(try JSONEncoder().encode(VNCContentMessage(method: VNCWebCapability.writeClipboard.rawValue, requestID: UUID(), generation: session.generation)), frameURL: URL(string: "https://box.example/vnc.html")!, contentWorld: VNCIsolationPolicy.contentWorldName)
        }
        let allowed = await policy.navigation(to: URL(string: "https://box.example/vnc.html")!, isMainFrame: true)
        let denied = await policy.navigation(to: URL(string: "https://evil.example/vnc.html")!, isMainFrame: true)
        XCTAssertEqual(allowed, VNCNavigationDisposition.allow); XCTAssertEqual(denied, VNCNavigationDisposition.deny)
        let download = await policy.allowDownload(URL(string: "https://box.example/a")!)
        let window = await policy.allowNewWindow(URL(string: "https://box.example/a")!)
        XCTAssertFalse(download); XCTAssertFalse(window)
        let headers = try await policy.requestHeaders(for: URL(string: "https://box.example/assets/a.js")!, token: "token")
        XCTAssertEqual(headers["X-Filicon-VNC-Session"], "token")
        await XCTAssertThrowsComputerAsync { _ = try await policy.requestHeaders(for: URL(string: "https://evil.example/a")!, token: "token") }

        for expected in 2...4 {
            let result = try await policy.processDidCrash()
            XCTAssertEqual(result, .reload(generation: UInt64(expected)))
        }
        await XCTAssertThrowsComputerAsync { _ = try await policy.processDidCrash() }
        await policy.recoverAfterExplicitVisibility()
        let recovered = try await policy.processDidCrash()
        XCTAssertEqual(recovered, VNCProcessRecoveryDisposition.reload(generation: 6))
    }

    func testSessionIdentifiersAreNonpersistentAndScoped() async throws {
        let first = try VNCIsolationPolicy(accountID: "a", computerID: "c", allowedOrigin: "https://box.example", tokenOrigin: "https://box.example", now: { 0 })
        let second = try VNCIsolationPolicy(accountID: "a", computerID: "c", allowedOrigin: "https://box.example", tokenOrigin: "https://box.example", now: { 0 })
        let firstSession = await first.currentSession(); let secondSession = await second.currentSession()
        XCTAssertNotEqual(firstSession.identifier, secondSession.identifier)
        XCTAssertEqual(firstSession.contentWorld, VNCIsolationPolicy.contentWorldName)
    }
}
