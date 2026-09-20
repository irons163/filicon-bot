import Darwin
import Foundation
import Testing
import CustomDump
@testable import FiliconLocalTools

@Suite("Process output completion", .serialized, .timeLimit(.minutes(1)))
struct ProcessOutputTests {
    private let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private var scope: LocalRequestScope {
        .init(generation: generation, agentID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
              runID: runID, toolCallID: "output", expiresAt: .distantFuture)
    }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-output-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func finished(_ supervisor: LocalProcessSupervisor, _ id: UUID) async throws -> LocalProcessSnapshot {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let value = try await supervisor.read(sessionID: id, offset: 0, generation: generation)
            if !value.isRunning { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw LocalToolError.timedOut
    }

    @Test(arguments: [false, true])
    func exitCannotPublishCompletionBeforePendingOutput(stderr: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let release = OutputSignal(), exited = OutputSignal()
        let supervisor = LocalProcessSupervisor(beforeOutputDelivery: {
            await release.wait()
        }, onProcessExit: { await exited.signal() })
        let expected = Data("最後一批 output\n".utf8)
        let command = LocalCommand(executable: "/bin/sh",
            arguments: ["-c", "printf '最後一批 output\\n'\(stderr ? " >&2" : ""); exit 7"], workingDirectoryRoot: root.path)
        let start = try await supervisor.start(command, scope: scope)
        await exited.wait()
        let pending = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
        // waitpid has completed, but the actor has not accepted the last bytes.
        expectNoDifference(pending.isRunning, true)
        expectNoDifference(pending.exitStatus, nil)
        await release.signal()
        let terminal = try await finished(supervisor, start.sessionID)
        expectNoDifference(terminal.output, expected)
        expectNoDifference(terminal.nextOffset, expected.count)
        expectNoDifference(terminal.exitStatus, 7)
        expectNoDifference(terminal.terminationError, nil)
        let again = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
        expectNoDifference(again, terminal)
        await #expect(throws: LocalToolError.processExited) {
            try await supervisor.sendInput(sessionID: start.sessionID, data: Data([1]), closeAfterWrite: false, generation: generation)
        }
    }

    @Test func largeOutputPreservesBothPipesAndIncrementalOffsets() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = LocalProcessSupervisor()
        let script = "head -c 524288 /dev/zero | tr '\\000' A; head -c 262144 /dev/zero | tr '\\000' B >&2; exit 9"
        let start = try await supervisor.start(.init(executable: "/bin/sh", arguments: ["-c", script], workingDirectoryRoot: root.path), scope: scope)
        var collected = start.output, offset = start.nextOffset
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let next = try await supervisor.read(sessionID: start.sessionID, offset: offset, generation: generation)
            collected += next.output; offset = next.nextOffset
            if !next.isRunning { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let terminal = try await finished(supervisor, start.sessionID)
        expectNoDifference(collected, terminal.output)
        expectNoDifference(offset, 786_432)
        expectNoDifference(collected.filter { $0 == 65 }.count, 524_288)
        expectNoDifference(collected.filter { $0 == 66 }.count, 262_144)
        expectNoDifference(terminal.exitStatus, 9)
        expectNoDifference(terminal.truncated, false)
        expectNoDifference(terminal.terminationError, nil)
        let tail = try await supervisor.read(sessionID: start.sessionID, offset: offset, generation: generation)
        expectNoDifference(tail.output, Data()); expectNoDifference(tail.nextOffset, offset)
        await #expect(throws: LocalToolError.invalidRequest("invalid output offset")) {
            _ = try await supervisor.read(sessionID: start.sessionID, offset: offset + 1, generation: generation)
        }
        await #expect(throws: LocalToolError.staleGeneration) {
            _ = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: UUID())
        }
        try await supervisor.terminate(sessionID: start.sessionID, generation: generation)
        let after = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
        expectNoDifference(after, terminal)
    }

    @Test func emptyOutputAndEarlyClosedPipesDoNotLoseExitOrTimeout() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = LocalProcessSupervisor()
        let empty = try await supervisor.start(.init(executable: "/usr/bin/true", workingDirectoryRoot: root.path), scope: scope)
        let done = try await finished(supervisor, empty.sessionID)
        expectNoDifference(done.output, Data()); expectNoDifference(done.exitStatus, 0)
        expectNoDifference(done.terminationError, nil)
        let closed = try await supervisor.start(.init(executable: "/bin/sh", arguments: ["-c", "exec 1>&- 2>&-; exec sleep 30"],
            workingDirectoryRoot: root.path, timeoutMilliseconds: 50), scope: scope)
        let timedOut = try await finished(supervisor, closed.sessionID)
        expectNoDifference(timedOut.output, Data()); expectNoDifference(timedOut.terminationError, .timedOut)
        #expect(try #require(timedOut.exitStatus) < 0)
    }

    @Test(arguments: [false, true])
    func inheritedOpenPipeHasBoundedDrainAndCanBeCancelled(cancel: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        // Only this test's recorded, still-sleeping child is cleaned up.
        defer {
            if let text = try? String(contentsOf: root.appending(path: "child.pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 { _ = kill(pid, SIGTERM) }
        }
        let exited = OutputSignal()
        let supervisor = LocalProcessSupervisor(onProcessExit: { await exited.signal() })
        let command = LocalCommand(executable: "/bin/sh",
            arguments: ["-c", "printf tail; sleep 30 & echo $! > child.pid; exit 0"], workingDirectoryRoot: root.path)
        let start = try await supervisor.start(command, scope: scope)
        await exited.wait()
        let draining = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
        expectNoDifference(draining.isRunning, true); expectNoDifference(draining.exitStatus, nil)
        if cancel {
            // Wait for real output, not a guessed delay, before requesting Stop.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < deadline {
                let value = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
                if value.output == Data("tail".utf8) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            await supervisor.cancel(runID: UUID(), generation: generation)
            await supervisor.cancel(runID: runID, generation: UUID())
            let unchanged = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
            expectNoDifference(unchanged.isRunning, true)
            await supervisor.cancel(runID: runID, generation: generation)
        }
        let done = try await finished(supervisor, start.sessionID)
        expectNoDifference(done.output, Data("tail".utf8))
        expectNoDifference(done.exitStatus, 0)
        expectNoDifference(done.terminationError, cancel ? LocalProcessSupervisor.stoppedOutput : LocalProcessSupervisor.incompleteOutput)
        let repeatRead = try await supervisor.read(sessionID: start.sessionID, offset: 0, generation: generation)
        expectNoDifference(repeatRead, done)
    }

    @Test func stoppingReaderCannotOvertakeItsInflightChunk() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw LocalToolError.ioFailure("test pipe") }
        let fd = descriptors[0], writer = descriptors[1]
        defer { Darwin.close(writer) }
        #expect(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
        let entered = OutputSignal(), release = OutputSignal(), ended = OutputSignal()
        let probe = OutputProbe()
        let reader = LocalProcessOutputReader(fd: fd) { event in
            if case .bytes = event { await entered.signal(); await release.wait() }
            await probe.record(event)
            if case .closed = event { await ended.signal() }
        }
        let bytes = Array("acknowledge before closing".utf8)
        #expect(bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress, $0.count) } == bytes.count)
        await entered.wait()
        reader.stop(error: LocalProcessSupervisor.stoppedOutput)
        let pending = await probe.snapshot
        expectNoDifference(pending, .init())
        await release.signal(); await ended.wait()
        let done = await probe.snapshot
        expectNoDifference(done, .init(bytes: Data(bytes), ends: 1, error: LocalProcessSupervisor.stoppedOutput))
        reader.stop() // Idempotent cancellation; no duplicate terminal event.
    }

    @Test(arguments: Array(0..<25))
    func immediateExitsAlwaysReturnCompleteStableOutput(iteration: Int) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = LocalProcessSupervisor()
        let text = "iteration-\(iteration)"
        let start = try await supervisor.start(.init(executable: "/bin/echo", arguments: [text], workingDirectoryRoot: root.path), scope: scope)
        let terminal = try await finished(supervisor, start.sessionID)
        expectNoDifference(terminal.output, Data((text + "\n").utf8))
        expectNoDifference(terminal.exitStatus, 0)
        expectNoDifference(terminal.terminationError, nil)
    }

    @Test func concurrentSessionsKeepTheirOwnBytesAndExitStatus() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let supervisor = LocalProcessSupervisor()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    let value = "session-\(index)"
                    let start = try await supervisor.start(.init(executable: "/bin/echo", arguments: [value], workingDirectoryRoot: root.path), scope: scope)
                    let done = try await finished(supervisor, start.sessionID)
                    expectNoDifference(done.output, Data((value + "\n").utf8))
                    expectNoDifference(done.exitStatus, 0)
                    expectNoDifference(done.terminationError, nil)
                }
            }
            try await group.waitForAll()
        }
    }
}

private actor OutputProbe {
    struct Snapshot: Equatable { var bytes = Data(); var ends = 0; var error: LocalToolError? }
    private(set) var snapshot = Snapshot()
    func record(_ event: LocalProcessOutputReader.Event) {
        switch event {
        case .bytes(let bytes): snapshot.bytes.append(bytes)
        case .closed(let error): snapshot.ends += 1; snapshot.error = error
        }
    }
}

private actor OutputSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { signalled = true; let ready = waiters; waiters.removeAll(); ready.forEach { $0.resume() } }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
