import Foundation

public protocol AutomationClock: Sendable {
    func now() async -> Date
    func sleep(until deadline: Date) async throws
}

public struct SystemAutomationClock: AutomationClock {
    public init() {}
    public func now() async -> Date { Date() }
    public func sleep(until deadline: Date) async throws {
        let interval = max(0, deadline.timeIntervalSinceNow)
        try await Task.sleep(for: .seconds(interval))
    }
}

public enum AutomationSchedulerState: String, Sendable {
    case stopped
    case running
    case suspended
}

public actor AutomationScheduler {
    public static let reconciliationInterval: TimeInterval = 15

    private let service: AutomationService
    private let executor: any AutomationExecutor
    private let clock: any AutomationClock
    private var task: Task<Void, Never>?
    private var state: AutomationSchedulerState = .stopped

    public init(service: AutomationService, executor: any AutomationExecutor, clock: any AutomationClock = SystemAutomationClock()) {
        self.service = service
        self.executor = executor
        self.clock = clock
    }

    deinit { task?.cancel() }

    public func status() -> AutomationSchedulerState { state }

    public func start() {
        guard task == nil else {
            if state == .suspended { state = .running }
            return
        }
        state = .running
        task = Task { [weak self] in await self?.loop() }
    }

    public func stop() {
        task?.cancel()
        task = nil
        state = .stopped
    }

    public func suspend() { state = .suspended }
    public func resume() {
        if task == nil { start() }
        else { state = .running }
    }

    @discardableResult
    public func runOnce(at explicitNow: Date? = nil) async -> [AutomationRun] {
        let now: Date
        if let explicitNow { now = explicitNow }
        else { now = await clock.now() }
        // Reconcile owner-scoped cards before firing, never after a new run.
        do { try await service.evaluateSpendGuards(at: now) }
        catch { return [] }
        return await service.fireDue(at: now, executor: executor)
    }

    private func loop() async {
        while !Task.isCancelled {
            if state == .suspended {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
                continue
            }
            let now = await clock.now()
            _ = await runOnce(at: now)
            let nextScheduled = await service.nextScheduledRunAt()
            let reconcileAt = now.addingTimeInterval(Self.reconciliationInterval)
            let deadline = nextScheduled.map { min($0, reconcileAt) } ?? reconcileAt
            do { try await clock.sleep(until: max(deadline, now.addingTimeInterval(0.05))) }
            catch { break }
        }
        if state != .stopped { state = .stopped }
        task = nil
    }
}

public actor AutomationTriggerHub {
    private static let queueIdentifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let batcher: AutomationEventBatcher

    public init(
        service: AutomationService,
        executor: any AutomationExecutor,
        debounce: Duration = .milliseconds(750)
    ) {
        batcher = AutomationEventBatcher(debounce: debounce) { _, events in
            _ = await service.fire(events: events, executor: executor)
        }
    }

    @discardableResult
    public func ingest(_ event: AutomationEvent) async -> Bool {
        // A re-signed delivery already waiting in this connector's queue is admitted,
        // not a capacity failure. Keep the batcher's public "newly queued" contract.
        await batcher.enqueueResult(event, automationID: Self.queueIdentifier) != .full
    }

    public func queuedCount() async -> Int {
        await batcher.queuedCount(automationID: Self.queueIdentifier)
    }

    public func waitUntilIdle() async {
        await batcher.waitUntilIdle(automationID: Self.queueIdentifier)
    }

    public func cancel() async { await batcher.cancel(automationID: Self.queueIdentifier) }
}
