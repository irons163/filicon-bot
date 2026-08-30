import Foundation
import XCTest
@testable import FiliconComputer

final class TeachRecordingTests: XCTestCase {
    func testRequiresPrivateForkMonitor() async throws {
        let controller = makeController(backend: TestTeachBackend())
        do {
            _ = try await controller.start(agentID: "agent", monitor: .primary)
            XCTFail("Expected private monitor rejection")
        } catch let error as TeachRecordingError {
            XCTAssertEqual(error, .privateMonitorRequired)
        }
    }

    func testStartsStopsAndSavesRecording() async throws {
        let backend = TestTeachBackend()
        let controller = makeController(backend: backend)
        let started = try await controller.start(agentID: "agent", monitor: .privateFork(index: 1))
        XCTAssertEqual(started.phase, .recording)
        XCTAssertEqual(started.agentID, "agent")
        let stopped = try await controller.stop(agentID: "agent", save: true)
        XCTAssertEqual(stopped.phase, .idle)
        XCTAssertNotNil(stopped.savedVideoURL)
        let counts = await backend.counts()
        XCTAssertEqual(counts.starts, 1)
        XCTAssertEqual(counts.stops, 1)
    }

    func testTenMinuteCapStopsAndSaves() async throws {
        let clock = TestComputerClock()
        let backend = TestTeachBackend(clock: clock)
        let controller = makeController(backend: backend, clock: clock)
        _ = try await controller.start(agentID: "agent", monitor: .privateFork(index: 1))
        let statuses = await controller.statuses()
        var statusIterator = statuses.makeAsyncIterator()
        while await clock.pendingSleeps() == 0 { await Task.yield() }
        await clock.advance(by: TeachRecordingController.maximumDurationMilliseconds)

        while let status = await statusIterator.next() {
            if status.phase == .idle { break }
        }

        let counts = await backend.counts()
        XCTAssertEqual(counts.stops, 1)
    }

    func testRecoveryQuarantinesIncompleteSessions() async throws {
        let backend = TestTeachBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let complete = TeachRecoveryArtifact(
            sessionID: UUID(),
            sessionDirectory: root.appending(path: "complete"),
            videoURL: root.appending(path: "complete/demo.mp4"),
            isComplete: true
        )
        let incomplete = TeachRecoveryArtifact(
            sessionID: UUID(),
            sessionDirectory: root.appending(path: "partial"),
            videoURL: nil,
            isComplete: false
        )
        await backend.configure(recoveries: [complete, incomplete])
        let controller = TeachRecordingController(backend: backend, sessionsDirectory: root)
        let recovered = try await controller.recover()
        XCTAssertEqual(recovered, [complete])
        let counts = await backend.counts()
        XCTAssertEqual(counts.quarantined, 1)
    }

    private func makeController(backend: TestTeachBackend, clock: TestComputerClock = TestComputerClock()) -> TeachRecordingController {
        TeachRecordingController(
            backend: backend,
            sessionsDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            clock: clock
        )
    }
}
