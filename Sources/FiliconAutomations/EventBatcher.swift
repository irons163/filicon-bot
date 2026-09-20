import Foundation

public actor AutomationEventBatcher {
    public typealias Sink = @Sendable (_ automationID: UUID, _ events: [AutomationEvent]) async -> Void
    enum EnqueueResult: Sendable { case queued, duplicate, full }

    private let debounce: Duration
    private let sink: Sink
    private var pending: [UUID: [AutomationEvent]] = [:]
    private struct Timer {
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var timers: [UUID: Timer] = [:]
    private var inFlight: [UUID: Int] = [:]
    private var idleWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    public init(debounce: Duration = .milliseconds(750), sink: @escaping Sink) {
        self.debounce = debounce
        self.sink = sink
    }

    @discardableResult
    public func enqueue(_ event: AutomationEvent, automationID: UUID) -> Bool {
        enqueueResult(event, automationID: automationID) == .queued
    }

    func enqueueResult(_ event: AutomationEvent, automationID: UUID) -> EnqueueResult {
        var values = pending[automationID] ?? []
        guard !values.contains(where: {
            $0.connectorID == event.connectorID && $0.externalEventID == event.externalEventID
        }) else { return .duplicate }
        guard values.count < AutomationService.maximumQueuedEvents else { return .full }
        values.append(event)
        pending[automationID] = values
        timers[automationID]?.task.cancel()
        let delay = debounce
        let generation = UUID()
        let task = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.timerFired(automationID: automationID, generation: generation)
        }
        timers[automationID] = Timer(generation: generation, task: task)
        return .queued
    }

    public func flush(automationID: UUID) async {
        timers.removeValue(forKey: automationID)?.task.cancel()
        await drain(automationID: automationID)
    }

    /// Suspends until the debounce timer and every sink invocation for this queue finish.
    /// This is also useful to coordinate orderly shutdown without guessing at wall-clock delays.
    public func waitUntilIdle(automationID: UUID) async {
        guard !isIdle(automationID: automationID) else { return }
        await withCheckedContinuation { continuation in
            idleWaiters[automationID, default: []].append(continuation)
        }
    }

    private func timerFired(automationID: UUID, generation: UUID) async {
        guard timers[automationID]?.generation == generation else { return }
        // Do not cancel the current timer task. A cancelled task would carry its
        // cancellation state into the async sink and can turn a valid run into a
        // cancellation under load.
        timers.removeValue(forKey: automationID)
        await drain(automationID: automationID)
    }

    private func drain(automationID: UUID) async {
        let values = pending.removeValue(forKey: automationID) ?? []
        guard !values.isEmpty else {
            resumeIdleWaitersIfNeeded(automationID: automationID)
            return
        }
        inFlight[automationID, default: 0] += 1
        var start = 0
        while start < values.count {
            let end = min(start + AutomationService.maximumCoalescedEvents, values.count)
            await sink(automationID, Array(values[start..<end]))
            start = end
        }
        let remaining = (inFlight[automationID] ?? 1) - 1
        if remaining == 0 { inFlight.removeValue(forKey: automationID) }
        else { inFlight[automationID] = remaining }
        resumeIdleWaitersIfNeeded(automationID: automationID)
    }

    public func queuedCount(automationID: UUID) -> Int { pending[automationID]?.count ?? 0 }

    public func cancel(automationID: UUID) {
        timers.removeValue(forKey: automationID)?.task.cancel()
        pending.removeValue(forKey: automationID)
        resumeIdleWaitersIfNeeded(automationID: automationID)
    }

    private func isIdle(automationID: UUID) -> Bool {
        pending[automationID] == nil && timers[automationID] == nil && inFlight[automationID] == nil
    }

    private func resumeIdleWaitersIfNeeded(automationID: UUID) {
        guard isIdle(automationID: automationID) else { return }
        let waiters = idleWaiters.removeValue(forKey: automationID) ?? []
        waiters.forEach { $0.resume() }
    }
}
