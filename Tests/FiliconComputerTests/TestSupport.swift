import Foundation
import XCTest
@testable import FiliconComputer

final class ComputerTestMilliseconds: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64
    init(_ value: Int64 = 0) { self.value = value }
    func now() -> Int64 { lock.withLock { value } }
    func advance(_ delta: Int64) { lock.withLock { value += delta } }
}

func XCTAssertThrowsComputerAsync(
    _ expression: () async throws -> Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
}

actor TestComputerClock: ComputerClock {
    private struct Waiter {
        let deadline: Int64
        let continuation: CheckedContinuation<Void, Error>
    }

    private var milliseconds: Int64
    private var waiters: [UUID: Waiter] = [:]

    init(milliseconds: Int64 = 0) { self.milliseconds = milliseconds }

    func nowMilliseconds() async -> Int64 { milliseconds }

    func sleep(milliseconds: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[id] = Waiter(deadline: self.milliseconds + max(0, milliseconds), continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func advance(by delta: Int64) {
        milliseconds += delta
        let ready = waiters.filter { $0.value.deadline <= milliseconds }
        for (id, waiter) in ready {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume()
        }
    }

    func pendingSleeps() -> Int { waiters.count }

    private func cancel(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
    }
}

actor TestSessionBackend: ComputerSessionBackend {
    var statusValue: ComputerBackendStatus = .off
    var ensureValue: ComputerBackendStatus = .off
    var delayMilliseconds: Int64 = 0
    let clock: TestComputerClock?

    init(clock: TestComputerClock? = nil) { self.clock = clock }

    func configure(status: ComputerBackendStatus? = nil, ensure: ComputerBackendStatus? = nil, delay: Int64? = nil) {
        if let status { statusValue = status }
        if let ensure { ensureValue = ensure }
        if let delay { delayMilliseconds = delay }
    }

    func status(for agentID: String) async throws -> ComputerBackendStatus {
        if delayMilliseconds > 0 { try await clock?.sleep(milliseconds: delayMilliseconds) }
        return statusValue
    }

    func ensure(for agentID: String) async throws -> ComputerBackendStatus {
        if delayMilliseconds > 0 { try await clock?.sleep(milliseconds: delayMilliseconds) }
        return ensureValue
    }
}

actor TestTeachBackend: TeachCaptureBackend {
    let clock: TestComputerClock?
    var delayMilliseconds: Int64 = 0
    var starts: [TeachCaptureRequest] = []
    var stops: [(TeachCaptureRequest, Bool)] = []
    var discards: [TeachCaptureRequest] = []
    var recoveries: [TeachRecoveryArtifact] = []
    var quarantined: [TeachRecoveryArtifact] = []

    init(clock: TestComputerClock? = nil) { self.clock = clock }

    func configure(delay: Int64? = nil, recoveries: [TeachRecoveryArtifact]? = nil) {
        if let delay { delayMilliseconds = delay }
        if let recoveries { self.recoveries = recoveries }
    }

    func start(_ request: TeachCaptureRequest) async throws {
        starts.append(request)
        if delayMilliseconds > 0 { try await clock?.sleep(milliseconds: delayMilliseconds) }
    }

    func stop(_ request: TeachCaptureRequest, save: Bool) async throws -> URL? {
        stops.append((request, save))
        if delayMilliseconds > 0 { try await clock?.sleep(milliseconds: delayMilliseconds) }
        return save ? request.outputURL : nil
    }

    func discard(_ request: TeachCaptureRequest) async throws { discards.append(request) }

    func recoverArtifacts(in sessionsDirectory: URL) async throws -> [TeachRecoveryArtifact] { recoveries }

    func quarantine(_ artifact: TeachRecoveryArtifact, into quarantineDirectory: URL) async throws {
        quarantined.append(artifact)
    }

    func counts() -> (starts: Int, stops: Int, discards: Int, quarantined: Int) {
        (starts.count, stops.count, discards.count, quarantined.count)
    }
}

actor TestUpdateBackend: ComputerUpdateBackend {
    let clock: TestComputerClock?
    var delayMilliseconds: Int64 = 0
    var response: ComputerUpdateBackendResponse = .started(operationID: "op-1")
    var forceValues: [Bool] = []

    init(clock: TestComputerClock? = nil) { self.clock = clock }

    func configure(response: ComputerUpdateBackendResponse? = nil, delay: Int64? = nil) {
        if let response { self.response = response }
        if let delay { delayMilliseconds = delay }
    }

    func startUpdate(agentID: String, force: Bool) async throws -> ComputerUpdateBackendResponse {
        forceValues.append(force)
        if delayMilliseconds > 0 { try await clock?.sleep(milliseconds: delayMilliseconds) }
        return response
    }

    func forces() -> [Bool] { forceValues }
}
