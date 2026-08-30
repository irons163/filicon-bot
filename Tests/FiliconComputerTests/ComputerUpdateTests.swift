import XCTest
@testable import FiliconComputer

final class ComputerUpdateTests: XCTestCase {
    func testBusyComputerRequiresExplicitUpdateAnyway() async {
        let backend = TestUpdateBackend()
        let confirmation = ComputerUpdateConfirmation(
            context: .init(agentID: "agent", updateAvailable: true, isComputerBusy: true),
            backend: backend
        )
        let blocked = await confirmation.confirm()
        XCTAssertEqual(blocked, .unavailable)
        let snapshot = await confirmation.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .blocked)
        let started = await confirmation.confirm(.updateAnyway)
        XCTAssertEqual(started, .started(operationID: "op-1"))
        let forces = await backend.forces()
        XCTAssertEqual(forces, [true])
    }

    func testStartedUntrackableBlocksAndRequiresRestart() async {
        let backend = TestUpdateBackend()
        await backend.configure(response: .startedUntrackable)
        let confirmation = ComputerUpdateConfirmation(
            context: .init(agentID: "agent", updateAvailable: true, isComputerBusy: false),
            backend: backend
        )
        let result = await confirmation.confirm()
        XCTAssertEqual(result, .blockedRequiresRestart)
        let snapshot = await confirmation.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .blocked)
        XCTAssertTrue(snapshot.requiresRestart)
    }

    func testCancelTransitionsPendingRequest() async {
        let clock = TestComputerClock()
        let backend = TestUpdateBackend(clock: clock)
        await backend.configure(delay: 10_000)
        let confirmation = ComputerUpdateConfirmation(
            context: .init(agentID: "agent", updateAvailable: true, isComputerBusy: false),
            backend: backend
        )
        let operation = Task { await confirmation.confirm() }
        while await clock.pendingSleeps() == 0 { await Task.yield() }
        let cancelled = await confirmation.cancel()
        XCTAssertEqual(cancelled, .cancelled)
        _ = await operation.value
        let snapshot = await confirmation.currentSnapshot()
        XCTAssertEqual(snapshot.phase, .cancelled)
    }
}
