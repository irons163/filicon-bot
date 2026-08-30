import Foundation
import XCTest
@testable import FiliconComputer

final class ComputerSessionTests: XCTestCase {
    func testProjectsAllBackendStates() async {
        let backend = TestSessionBackend()
        let controller = ComputerSessionController(backend: backend)

        await controller.ingest(.off)
        var snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .off)
        await controller.ingest(.hibernated)
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .sleeping)
        await controller.ingest(.running(vncURL: nil))
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .local)
        let url = URL(string: "https://box.example/vnc.html")!
        await controller.ingest(.running(vncURL: url))
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .running)
        await controller.ingest(.pulling(percent: 144))
        let pulling = await controller.currentSnapshot()
        XCTAssertEqual(pulling.phase, .pulling)
        XCTAssertEqual(pulling.pullPercent, 100)
    }

    func testEnsureUsesStartingThenResolvedState() async {
        let backend = TestSessionBackend()
        await backend.configure(ensure: .running(vncURL: nil))
        let controller = ComputerSessionController(backend: backend)
        let result = await controller.ensure(agentID: "a")
        XCTAssertEqual(result.phase, .local)
        XCTAssertEqual(result.readState, .known)
    }

    func testStatusTimesOutAtInjectedDeadline() async {
        let clock = TestComputerClock()
        let backend = TestSessionBackend(clock: clock)
        await backend.configure(delay: 100_000)
        let controller = ComputerSessionController(backend: backend, clock: clock)
        let operation = Task { await controller.refresh(agentID: "a") }
        while await clock.pendingSleeps() < 2 { await Task.yield() }
        await clock.advance(by: 15_000)
        let result = await operation.value
        XCTAssertEqual(result.readState, .unavailable)
        XCTAssertNotNil(result.lastError)
    }

    func testFourthCrashWithinWindowTripsBreakerAndVisibilityRecovers() async {
        let clock = TestComputerClock()
        let backend = TestSessionBackend()
        let controller = ComputerSessionController(backend: backend, clock: clock)
        await controller.ingest(.running(vncURL: URL(string: "https://box.example/vnc.html")))
        for _ in 0..<3 { await controller.noteRendererCrash() }
        var snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .running)
        await controller.noteRendererCrash()
        snapshot = await controller.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .crashedOut)
        await controller.viewerBecameVisible()
        let recovered = await controller.currentSnapshot()
        XCTAssertEqual(recovered.phase, .running)
        XCTAssertEqual(recovered.crashCount, 0)
    }

    func testCrashWindowExpiresOldCrashes() async {
        let clock = TestComputerClock()
        let controller = ComputerSessionController(backend: TestSessionBackend(), clock: clock)
        for _ in 0..<3 { await controller.noteRendererCrash() }
        await clock.advance(by: 60_000)
        await controller.noteRendererCrash()
        let result = await controller.currentSnapshot()
        XCTAssertNotEqual(result.phase, .crashedOut)
        XCTAssertEqual(result.crashCount, 1)
    }
}
