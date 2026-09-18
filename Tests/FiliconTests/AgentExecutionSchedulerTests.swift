import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private actor ExecutionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiters.isEmpty }
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ExecutionLog {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private struct ScheduledProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "scheduled-test", displayName: "Scheduled test", requiresAPIKey: false, supportsToolCalling: false)
    let log: ExecutionLog
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await log.append("provider")
                continuation.yield(.textDelta("done")); continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct SlowCleanupTool: ToolExecutor {
    let descriptor = ToolDescriptor(name: "slow-cleanup")
    let gate: ExecutionGate
    let log: ExecutionLog
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await gate.wait()
        await log.append("tool cleanup finished")
        return .init(callID: call.id, content: [.text("done")])
    }
}

private actor LateToolCallback {
    private var callback: (@Sendable (NormalizedToolCall) async throws -> NormalizedToolResult)?
    func save(_ callback: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) { self.callback = callback }
    func invoke() async throws {
        _ = try await callback?(.init(id: "late-call", name: "slow-cleanup", argumentsJSON: Data("{}".utf8)))
    }
}

private struct CleanupProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "cleanup-test", displayName: "Cleanup test", requiresAPIKey: false)
    let log: ExecutionLog
    var late: LateToolCallback?
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let late { await late.save(executeTool) }
                    else if request.messages.last?.text == "first" {
                        _ = try await executeTool(.init(id: "slow", name: "slow-cleanup", argumentsJSON: Data("{}".utf8)))
                    } else { await log.append("next provider") }
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { reason in
                task.cancel()
                if case .cancelled = reason { Task { await log.append("transport cancelled") } }
            }
        }
    }
}

@Suite("Agent execution lanes", .timeLimit(.minutes(1)))
struct AgentExecutionSchedulerTests {
    private let agentID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate())
    }

    @Test func sameAgentIsFIFOWhileOtherAgentsCanRun() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let first = Task { try await scheduler.withExclusiveAccess(agentID: agentID) {
            await log.append("first start"); await gate.wait(); await log.append("first end")
        } }
        try await waitUntil { await gate.isWaiting }
        let second = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("second") } }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        let third = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("third") } }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 2 }
        try await scheduler.withExclusiveAccess(agentID: otherID) { await log.append("independent") }
        let before = await log.values
        expectNoDifference(before, ["first start", "independent"])
        await gate.open()
        try await first.value; try await second.value; try await third.value
        let after = await log.values
        expectNoDifference(after, ["first start", "independent", "first end", "second", "third"])
    }

    @Test func cancellingQueuedWorkDoesNotCancelTheActiveOwner() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let first = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await gate.wait() } }
        try await waitUntil { await gate.isWaiting }
        let cancelled = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("must not run") } }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let state = await scheduler.snapshot(agentID: agentID)
        #expect(state.isActive)
        expectNoDifference(state.queuedCount, 0)
        await gate.open(); try await first.value
        try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("next") }
        let entries = await log.values
        expectNoDifference(entries, ["next"])
    }

    @Test func cancellationDoesNotUnlockAnOperationThatIsStillUnwinding() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let first = Task { try await scheduler.withExclusiveAccess(agentID: agentID) {
            await gate.wait() // Deliberately ignores cancellation until released.
            await log.append("cleanup finished")
        } }
        try await waitUntil { await gate.isWaiting }
        first.cancel()
        let second = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("next") } }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        let blocked = await log.values
        expectNoDifference(blocked, [])
        await gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await second.value
        let entries = await log.values
        expectNoDifference(entries, ["cleanup finished", "next"])
    }

    @Test func failuresReleaseTheLaneAndCancelAllNeverRevivesQueuedWork() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        await #expect(throws: ProviderError.invalidResponse) {
            try await scheduler.withExclusiveAccess(agentID: agentID) { throw ProviderError.invalidResponse }
        }
        let first = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await gate.wait() } }
        try await waitUntil { await gate.isWaiting }
        let queued = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("stale account") } }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        await scheduler.cancelAll()
        await #expect(throws: CancellationError.self) { try await queued.value }
        let next = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("new account") } }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        await gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await next.value
        let entries = await log.values
        expectNoDifference(entries, ["new account"])
    }

    @Test func alreadyCancelledCallerNeverEnqueues() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let task = Task {
            await gate.wait()
            try await scheduler.withExclusiveAccess(agentID: agentID) { await log.append("must not run") }
        }
        try await waitUntil { await gate.isWaiting }
        task.cancel(); await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        let entries = await log.values
        expectNoDifference(entries, [])
    }

    @Test func turnTimeoutStartsAfterAcquiringTheAgentLane() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let registry = ProviderRegistry()
        await registry.register(ScheduledProvider(log: log))
        let coordinator = TurnCoordinator(registry: registry, agentScheduler: scheduler)
        let owner = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await gate.wait() } }
        try await waitUntil { await gate.isWaiting }
        let turn = Task {
            try await coordinator.send(request: .init(conversationID: otherID, modelID: "test", messages: []),
                providerID: "scheduled-test", agentID: agentID, executionTimeout: .milliseconds(200),
                onStart: { await log.append("started") }) { _ in }
        }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        try await Task.sleep(for: .milliseconds(300))
        let before = await log.values
        expectNoDifference(before, [])
        await gate.open(); try await owner.value; try await turn.value
        let after = await log.values
        expectNoDifference(after, ["started", "provider"])
    }

    @Test func coordinatorCancelsOnlyItsOwnWaitingConversation() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let registry = ProviderRegistry()
        await registry.register(ScheduledProvider(log: log))
        let coordinator = TurnCoordinator(registry: registry, agentScheduler: scheduler)
        let owner = Task { try await scheduler.withExclusiveAccess(agentID: agentID) { await gate.wait() } }
        try await waitUntil { await gate.isWaiting }
        let cancelled = Task {
            try await coordinator.send(request: .init(conversationID: agentID, modelID: "test", messages: []),
                                       providerID: "scheduled-test", agentID: agentID) { _ in }
        }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        let survivor = Task {
            try await coordinator.send(request: .init(conversationID: otherID, modelID: "test", messages: []),
                                       providerID: "scheduled-test", agentID: agentID) { _ in }
        }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 2 }
        await coordinator.cancel(conversationID: agentID)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        await gate.open(); try await owner.value; try await survivor.value
        let entries = await log.values
        expectNoDifference(entries, ["provider"])
    }

    @Test func cancelledToolLoopHoldsAgentLaneUntilHostToolCleanupFinishes() async throws {
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let registry = ProviderRegistry()
        await registry.register(CleanupProvider(log: log))
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog([SlowCleanupTool(gate: gate, log: log)]), agentScheduler: scheduler)
        let first = Task {
            try await coordinator.send(request: .init(conversationID: agentID, modelID: "test", messages: [.init(role: .user, text: "first")]),
                                       providerID: "cleanup-test", agentID: agentID) { _ in }
        }
        try await waitUntil { await gate.isWaiting }
        let next = Task {
            try await coordinator.send(request: .init(conversationID: otherID, modelID: "test", messages: [.init(role: .user, text: "next")]),
                                       providerID: "cleanup-test", agentID: agentID) { _ in }
        }
        try await waitUntil { await scheduler.snapshot(agentID: agentID).queuedCount == 1 }
        await coordinator.cancel(conversationID: agentID)
        try await waitUntil { await log.values.contains("transport cancelled") }
        let blocked = await scheduler.snapshot(agentID: agentID)
        expectNoDifference(blocked.queuedCount, 1)
        await gate.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await next.value
        let entries = await log.values
        expectNoDifference(entries.filter { $0 != "transport cancelled" }, ["tool cleanup finished", "next provider"])
    }

    @Test func providerCannotExecuteToolsAfterItsTurnHasFinished() async throws {
        let registry = ProviderRegistry(), log = ExecutionLog(), gate = ExecutionGate(), late = LateToolCallback()
        await registry.register(CleanupProvider(log: log, late: late))
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog([SlowCleanupTool(gate: gate, log: log)]))
        try await coordinator.send(request: .init(conversationID: agentID, modelID: "test", messages: []),
                                   providerID: "cleanup-test", agentID: agentID) { _ in }
        await #expect(throws: CancellationError.self) { try await late.invoke() }
        let waiting = await gate.isWaiting
        #expect(!waiting)
    }

    @Test(arguments: [false, true]) func queuedSubagentCanBeSteeredOrCancelledBeforeItStarts(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-scheduler-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let profile = try await agents.create(name: "Worker")
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let service = SubagentService(agents: agents, scheduler: scheduler)
        let owner = Task { try await scheduler.withExclusiveAccess(agentID: profile.id) { await gate.wait() } }
        try await waitUntil { await gate.isWaiting }
        let runtime = AgentAsyncTaskRuntimeAdapter(taskKind: .subagent, operation: { prompt, _ in
            await log.append(prompt)
            return .completed(text: "done", usage: .init())
        }, interruption: { _ in await log.append("interrupt") })
        let id = try await service.launch(.init(agentID: profile.id, title: "Fixture", prompt: "original", parentToolCallID: "test", depth: 0),
                                          parentRunID: agentID, parentScope: .init(), runtime: runtime)
        try await waitUntil { await scheduler.snapshot(agentID: profile.id).queuedCount == 1 }
        let queued = await service.status(id)
        expectNoDifference(queued?.status, .queued)
        if cancel { await service.cancel(id) }
        else {
            try await service.steer(id, message: "updated task")
            let entries = await log.values
            expectNoDifference(entries, []) // No interrupt of an unrelated lane owner.
        }
        await gate.open(); try await owner.value; await service.drain()
        let result = await service.status(id), entries = await log.values
        expectNoDifference(result?.status, cancel ? .cancelled : .succeeded)
        if cancel { expectNoDifference(entries, []) }
        else {
            expectNoDifference(entries.count, 1)
            #expect(entries.first?.contains("original") == true)
            #expect(entries.first?.contains("updated task") == true)
        }
    }

    @Test(arguments: [false, true]) func cancelAllInterruptsOnlyTheExecutingSubagentAndRejectsQueuedWork(runtimeThrowsOnStop: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-scheduler-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let profile = try await agents.create(name: "Worker")
        let scheduler = AgentExecutionScheduler(), gate = ExecutionGate(), log = ExecutionLog()
        let service = SubagentService(agents: agents, scheduler: scheduler)
        let runtime = AgentAsyncTaskRuntimeAdapter(taskKind: .subagent, operation: { prompt, _ in
            await log.append(prompt); await gate.wait()
            if runtimeThrowsOnStop { throw ProviderError.transport("Shell exited after interruption") }
            return .interrupted
        }, interruption: { _ in await log.append("interrupt"); await gate.open() })
        let first = try await service.launch(.init(agentID: profile.id, title: "First", prompt: "first", parentToolCallID: "first", depth: 0),
                                             parentRunID: agentID, parentScope: .init(), runtime: runtime)
        try await waitUntil { await gate.isWaiting }
        let queued = try await service.launch(.init(agentID: profile.id, title: "Queued", prompt: "must not start", parentToolCallID: "queued", depth: 0),
                                              parentRunID: agentID, parentScope: .init(), runtime: runtime)
        try await waitUntil { await scheduler.snapshot(agentID: profile.id).queuedCount == 1 }
        // Account transitions cancel the lane and actively interrupt runtimes
        // that require their own stop hook (for example a shell process).
        await scheduler.cancelAll(); await service.cancelAll(); await service.drain()
        let firstState = await service.status(first), queuedState = await service.status(queued)
        let entries = await log.values
        expectNoDifference(firstState?.status, .cancelled)
        expectNoDifference(queuedState?.status, .cancelled)
        expectNoDifference(entries, ["first", "interrupt"])
    }
}
