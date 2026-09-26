import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
@testable import FiliconAppServices

@Suite("Memory synthesis background worker")
struct AgentMemorySynthesisWorkerTests {
    private let agent = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let origin = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func settings(revision: Int = 3) -> AgentMemorySynthesisSettings {
        var value = AgentMemorySynthesisSettings(accountID: "local", agentID: agent)
        value.enabled = true
        value.revision = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", revision))!
        return value
    }
    private func entry(_ n: Int) -> AgentMemorySynthesisQueue.Entry {
        .init(originID: origin, evidence: .init(id: "turn-\(n)", occurredAt: Date(timeIntervalSince1970: 100),
                                              user: "Preference \(n)", assistant: "Understood"))
    }
    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Controlled worker did not reach the expected state")
        throw CancellationError()
    }

    @Test(arguments: ["pure", "mixed", "remove-origin", "revoke-temporal", "revoke-pure", "revoke-active", "snapshot"])
    func temporalBatchesHaveIndependentRevocableSources(mode: String) async throws {
        let clock = WorkerTime(), timers = WorkerTimers(), probe = WorkerProbe()
        let source = AgentMemorySuggestionLifetime()
        let worker = AgentMemorySynthesisWorker(now: { clock.now }, sleep: { try await timers.wait($0) }) { batch, token in
            try await probe.run(batch, lifetime: token)
            if mode == "snapshot", await probe.started.count == 1 { throw AgentMemorySynthesisSnapshotChanged() }
        }
        try await worker.enqueueTemporal(settings: settings(), sourceLifetime: source)
        try await eventually { await timers.count == 1 }
        let duplicate = try await worker.enqueueTemporal(settings: settings(), sourceLifetime: source)
        expectNoDifference(duplicate.inserted, false)
        let mixed = ["mixed", "remove-origin", "revoke-temporal"].contains(mode)
        if mixed {
            try await worker.enqueue(settings: settings(), entry: entry(1))
            try await eventually { await timers.count == 2 }
        }
        if mode == "remove-origin" { await worker.removeOrigin(origin) }
        if mode == "revoke-temporal" || mode == "revoke-pure" { source.close() }
        // Wait for the final debounce task to register before firing all gates.
        let expectedTimers = mixed ? (mode == "remove-origin" ? 3 : 2) : 1
        try await eventually { await timers.count >= expectedTimers }
        clock.advance(15); await timers.fireAll()
        if mode == "revoke-pure" {
            try await eventually { await worker.isIdle }
            let started = await probe.started
            expectNoDifference(started, [])
            await worker.shutdown()
            return
        }
        try await eventually { await probe.started.count == 1 }
        let flags = await probe.temporal
        expectNoDifference(flags, [mode != "revoke-temporal"])
        let batches = await probe.started
        expectNoDifference(batches, [mixed && mode != "remove-origin" ? ["turn-1"] : []])
        if mode == "revoke-active" { source.close() }
        if mode != "revoke-temporal" && mode != "revoke-active" {
            let activeDuplicate = try await worker.enqueueTemporal(settings: settings(), sourceLifetime: source)
            expectNoDifference(activeDuplicate.inserted, false)
        }
        await probe.release()
        if mode == "snapshot" {
            try await eventually { await timers.count == 2 }
            clock.advance(15); await timers.fireAll()
            try await eventually { await probe.started.count == 2 }
            let restored = await probe.temporal
            expectNoDifference(restored, [true, true])
            await probe.release()
        }
        try await eventually { await worker.isIdle }
        let commits = await probe.committed.count
        expectNoDifference(commits, mode == "revoke-active" ? 0 : mode == "snapshot" ? 2 : 1)
        await worker.shutdown()
        await #expect(throws: CancellationError.self) {
            try await worker.enqueueTemporal(settings: settings(), sourceLifetime: .init())
        }
    }

    @Test func debounceSerializesAndKeepsNewEvidenceForNextBatch() async throws {
        let clock = WorkerTime(), timers = WorkerTimers(), probe = WorkerProbe()
        let worker = AgentMemorySynthesisWorker(now: { clock.now }, sleep: { try await timers.wait($0) },
                                                run: { try await probe.run($0, lifetime: $1) })
        try await worker.enqueue(settings: settings(), entry: entry(1))
        try await eventually { await timers.count == 1 }
        clock.advance(10)
        try await worker.enqueue(settings: settings(), entry: entry(2))
        try await eventually { await timers.count == 2 }
        // Even an obsolete timer completing after replacement cannot start work.
        clock.advance(5); await timers.fireAll()
        let beforeReady = await probe.started
        expectNoDifference(beforeReady, [])
        // The replacement timer was deliberately woken early; the owner re-arms it.
        try await eventually { await timers.count >= 3 }
        clock.advance(10); await timers.fireAll()
        try await eventually { await probe.started.count == 1 }
        let first = await probe.started
        expectNoDifference(first, [["turn-1", "turn-2"]])
        let duplicate = try await worker.enqueue(settings: settings(), entry: entry(1))
        expectNoDifference(duplicate.inserted, false)
        try await worker.enqueue(settings: settings(), entry: entry(3))
        clock.advance(15)
        let whileActive = await probe.started.count
        expectNoDifference(whileActive, 1)
        await probe.release()
        try await eventually { await timers.count >= 4 }
        await timers.fireAll()
        try await eventually { await probe.started.count == 2 }
        let both = await probe.started, maximum = await probe.maximumActive
        expectNoDifference(both, [["turn-1", "turn-2"], ["turn-3"]])
        expectNoDifference(maximum, 1)
        await probe.release()
        try await eventually { await probe.committed.count == 2 }
        await worker.shutdown()
    }

    @Test(arguments: ["snapshot", "consent", "cancelled"])
    func onlySnapshotChangesRestoreEvidence(mode: String) async throws {
        let clock = WorkerTime(), timers = WorkerTimers(), probe = WorkerProbe()
        let source = AgentMemorySuggestionLifetime()
        let worker = AgentMemorySynthesisWorker(now: { clock.now }, sleep: { try await timers.wait($0) }) { batch, lifetime in
            try await probe.run(batch, lifetime: lifetime)
            if await probe.started.count == 1 {
                if mode == "consent" { throw AgentMemorySuggestionError.stale }
                throw AgentMemorySynthesisSnapshotChanged()
            }
        }
        try await worker.enqueue(settings: settings(), entry: entry(1), sourceLifetime: source)
        try await eventually { await timers.count == 1 }
        clock.advance(15); await timers.fireAll()
        try await eventually { await probe.started.count == 1 }
        if mode == "cancelled" { source.close() }
        await probe.release()
        if mode == "snapshot" {
            try await eventually { await timers.count == 2 }
            clock.advance(15); await timers.fireAll()
            try await eventually { await probe.started.count == 2 }
            let batches = await probe.started
            expectNoDifference(batches, [["turn-1"], ["turn-1"]])
            await probe.release()
        }
        try await eventually { await worker.isIdle }
        let count = await probe.started.count
        expectNoDifference(count, mode == "snapshot" ? 2 : 1)
        await worker.shutdown()
    }

    @Test(arguments: ["origin", "agent", "revision", "shutdown"])
    func cancellationFencesActiveBatch(mode: String) async throws {
        let clock = WorkerTime(), timers = WorkerTimers(), probe = WorkerProbe()
        let worker = AgentMemorySynthesisWorker(now: { clock.now }, sleep: { try await timers.wait($0) },
                                                run: { try await probe.run($0, lifetime: $1) })
        try await worker.enqueue(settings: settings(), entry: entry(1))
        try await eventually { await timers.count == 1 }
        clock.advance(15); await timers.fireAll()
        try await eventually { await probe.started.count == 1 }
        switch mode {
        case "origin": await worker.removeOrigin(origin)
        case "agent": await worker.removeAgent(accountID: "local", agentID: agent)
        case "revision": try await worker.enqueue(settings: settings(revision: 4), entry: entry(2))
        default: await worker.shutdown()
        }
        await probe.release()
        try await eventually { await probe.active == 0 }
        let cancelled = await probe.committed
        expectNoDifference(cancelled, [])
        let revoked = await probe.revoked
        expectNoDifference(revoked, [true])
        if mode == "revision" {
            try await eventually { await timers.count == 2 }
            clock.advance(15); await timers.fireAll()
            try await eventually { await probe.started.count == 2 }
            await probe.release()
            try await eventually { await probe.committed.count == 1 }
            let recovered = await probe.committed
            expectNoDifference(recovered, [["turn-2"]])
        }
        await worker.shutdown()
        await #expect(throws: CancellationError.self) {
            try await worker.enqueue(settings: settings(), entry: entry(3))
        }
    }
}

private final class WorkerTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ seconds: Int) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
}

private actor WorkerTimers {
    private(set) var count = 0
    private var continuations: [AsyncStream<Void>.Continuation] = []
    func wait(_ deadline: ContinuousClock.Instant) async throws {
        let pair = AsyncStream<Void>.makeStream()
        count += 1; continuations.append(pair.continuation)
        for await _ in pair.stream { break }
        try Task.checkCancellation()
    }
    func fireAll() {
        for continuation in continuations { continuation.yield(()); continuation.finish() }
        continuations.removeAll()
    }
}

private actor WorkerProbe {
    private(set) var temporal: [Bool] = []
    private(set) var started: [[String]] = []
    private(set) var committed: [[String]] = []
    private(set) var active = 0
    private(set) var maximumActive = 0
    private(set) var revoked: [Bool] = []
    private var continuation: AsyncStream<Void>.Continuation?
    func run(_ batch: AgentMemorySynthesisQueue.Batch, lifetime: AgentMemorySuggestionLifetime) async throws {
        let ids = batch.entries.map(\.evidence.id)
        let pair = AsyncStream<Void>.makeStream()
        continuation = pair.continuation
        started.append(ids); temporal.append(batch.temporalReview); active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        for await _ in pair.stream { break }
        // Check from an uncancelled task, proving lifetime revocation itself
        // protects a late callback, not merely the runner's cancelled Task flag.
        let isRevoked = await Task.detached { () -> Bool in
            do { try lifetime.check(); return false } catch { return true }
        }.value
        revoked.append(isRevoked)
        try lifetime.check()
        committed.append(ids)
    }
    func release() { continuation?.yield(()); continuation?.finish(); continuation = nil }
}
