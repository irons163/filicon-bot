import Foundation
import FiliconAgents

/// Serial, ephemeral maintenance owner. The runner must revalidate consent and
/// profile and use the supplied lifetime for its final store commit. Enqueue is
/// not permission to make a provider request. No user data is persisted here.
public actor AgentMemorySynthesisWorker {
    public typealias Runner = @Sendable (AgentMemorySynthesisQueue.Batch, AgentMemorySuggestionLifetime) async throws -> Void
    private let run: Runner
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private var queue = AgentMemorySynthesisQueue()
    private var ready: [AgentMemorySynthesisQueue.Batch] = []
    private var timer: Task<Void, Never>?
    private var timerGeneration = 0
    private var active: AgentMemorySynthesisQueue.Batch?
    private var lifetime: AgentMemorySuggestionLifetime?
    private var task: Task<Void, Never>?
    private var stopped = false
    private struct Source {
        let settings: AgentMemorySynthesisSettings
        // nil identifies the independent host temporal source, not a made-up turn.
        let evidenceID: String?
        let lifetime: AgentMemorySuggestionLifetime
        func matches(_ batch: AgentMemorySynthesisQueue.Batch) -> Bool {
            guard settings == batch.settings else { return false }
            if let evidenceID { return batch.entries.contains { $0.evidence.id == evidenceID } }
            return batch.temporalReview
        }
    }
    private var sources: [Source] = []
    public var isIdle: Bool { queue.count == 0 && ready.isEmpty && task == nil && timer == nil }

    public func pendingTemporalSettings() -> [AgentMemorySynthesisSettings] {
        discardRevokedSources()
        return queue.temporalSettings + (ready + (active.map { [$0] } ?? [])).filter(\.temporalReview).map(\.settings)
    }

    public init(run: @escaping Runner) {
        self.run = run
        self.now = { .now }
        self.sleep = { try await ContinuousClock().sleep(until: $0) }
    }

    init(now: @escaping @Sendable () -> ContinuousClock.Instant,
         sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void,
         run: @escaping Runner) {
        self.now = now; self.sleep = sleep; self.run = run
    }

    @discardableResult
    public func enqueue(settings: AgentMemorySynthesisSettings, entry: AgentMemorySynthesisQueue.Entry,
                        sourceLifetime: AgentMemorySuggestionLifetime? = nil) throws -> AgentMemorySynthesisQueue.Admission {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        try sourceLifetime?.check()
        discardRevokedSources()
        // Pending queue deduplication alone cannot see detached work.
        for batch in ready + (active.map { [$0] } ?? []) where batch.settings == settings {
            if let duplicate = batch.entries.first(where: { $0.evidence.id == entry.evidence.id }) {
                guard duplicate == entry else { throw AgentMemorySuggestionError.invalid }
                return .init(inserted: false, droppedAgents: 0, droppedEvidence: 0)
            }
        }
        let admission = try queue.enqueue(settings: settings, entry: entry, now: now())
        guard admission.inserted else { return admission }
        if let sourceLifetime { sources.append(.init(settings: settings, evidenceID: entry.evidence.id, lifetime: sourceLifetime)) }
        // A new consent revision must also invalidate detached/active old work.
        ready.removeAll { sameAgent($0.settings, settings) && $0.settings != settings }
        if let active, sameAgent(active.settings, settings), active.settings != settings { cancelActive() }
        pruneSources()
        armTimer()
        return admission
    }

    public func removeOrigin(_ originID: UUID) {
        queue.removeOrigin(originID)
        // A detached batch is an indivisible proposal/verification input. Drop
        // the entire mixed batch rather than commit evidence from a removed source.
        ready.removeAll { $0.entries.contains { $0.originID == originID } }
        if active?.entries.contains(where: { $0.originID == originID }) == true { cancelActive() }
        pruneSources()
        armTimer()
    }

    @discardableResult
    public func enqueueTemporal(settings: AgentMemorySynthesisSettings,
                                sourceLifetime: AgentMemorySuggestionLifetime) throws -> AgentMemorySynthesisQueue.Admission {
        guard !stopped else { throw CancellationError() }
        try sourceLifetime.check()
        discardRevokedSources()
        if (ready + (active.map { [$0] } ?? [])).contains(where: { $0.settings == settings && $0.temporalReview }) {
            return .init(inserted: false, droppedAgents: 0, droppedEvidence: 0)
        }
        let admission = try queue.enqueueTemporal(settings: settings, now: now())
        guard admission.inserted else { return admission }
        sources.append(.init(settings: settings, evidenceID: nil, lifetime: sourceLifetime))
        ready.removeAll { sameAgent($0.settings, settings) && $0.settings != settings }
        if let active, sameAgent(active.settings, settings), active.settings != settings { cancelActive() }
        pruneSources()
        armTimer()
        return admission
    }

    public func removeAgent(accountID: String, agentID: UUID) {
        queue.removeAgent(accountID: accountID, agentID: agentID)
        ready.removeAll { $0.settings.accountID == accountID && $0.settings.agentID == agentID }
        if active?.settings.accountID == accountID && active?.settings.agentID == agentID { cancelActive() }
        pruneSources()
        armTimer()
    }

    public func shutdown() {
        stopped = true
        queue.removeAll(); ready.removeAll()
        sources.removeAll()
        timerGeneration += 1; timer?.cancel(); timer = nil
        cancelActive()
    }

    private func sameAgent(_ lhs: AgentMemorySynthesisSettings, _ rhs: AgentMemorySynthesisSettings) -> Bool {
        lhs.accountID == rhs.accountID && lhs.agentID == rhs.agentID
    }

    private func cancelActive() {
        lifetime?.close()
        task?.cancel()
        // Do not release the serial slot until the runner actually unwinds.
    }

    private func armTimer() {
        timerGeneration += 1; timer?.cancel(); timer = nil
        guard !stopped, task == nil, ready.isEmpty, let deadline = queue.nextRun else { return }
        let generation = timerGeneration, sleep = self.sleep
        timer = Task { [weak self] in
            do {
                try await sleep(deadline)
                try Task.checkCancellation()
                await self?.timerFired(generation)
            } catch { /* Cancelled debounce timers must not drain newer evidence. */ }
        }
    }

    private func timerFired(_ generation: Int) {
        guard !stopped, generation == timerGeneration else { return }
        timer = nil
        discardRevokedSources()
        ready = queue.takeReady(now: now())
        startNext()
    }

    private func startNext() {
        guard !stopped, task == nil else { return }
        guard !ready.isEmpty else { armTimer(); return }
        let batch = ready.removeFirst(), run = self.run
        let token = AgentMemorySuggestionLifetime(parents: sources.filter { source in
            source.matches(batch)
        }.map(\.lifetime))
        active = batch; lifetime = token
        task = Task { [weak self] in
            do { try token.check(); try await run(batch, token) }
            catch is AgentMemorySynthesisSnapshotChanged {
                await self?.restoreStale(batch, token: token)
            }
            catch { /* Maintenance failure never invalidates a completed foreground reply. */ }
            token.close()
            await self?.finished()
        }
    }

    private func restoreStale(_ batch: AgentMemorySynthesisQueue.Batch, token: AgentMemorySuggestionLifetime) {
        guard !stopped, (try? token.check()) != nil else { return }
        // Reuse only evidence, never the stale proposal/verdict. The next runner
        // captures fresh state and revalidates consent before any provider call.
        try? queue.requeue(batch, now: now())
    }

    private func finished() {
        task = nil; active = nil; lifetime = nil
        pruneSources()
        startNext()
    }

    private func pruneSources() {
        let detached = ready + (active.map { [$0] } ?? [])
        sources.removeAll { source in
            let pending = source.evidenceID.map { queue.contains(settings: source.settings, evidenceID: $0) }
                ?? queue.containsTemporal(settings: source.settings)
            return !pending && !detached.contains(where: source.matches)
        }
    }

    private func discardRevokedSources() {
        for source in sources where (try? source.lifetime.check()) == nil {
            if let evidenceID = source.evidenceID {
                queue.removeEvidence(settings: source.settings, evidenceID: evidenceID)
            } else { queue.removeTemporal(settings: source.settings) }
            ready.removeAll(where: source.matches)
            if let active, source.matches(active) { cancelActive() }
        }
        pruneSources()
    }

    deinit { timer?.cancel(); lifetime?.close(); task?.cancel() }
}
