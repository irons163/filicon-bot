import Foundation
import Dispatch
import Testing
import CustomDump
@testable import FiliconAgents

private actor WorkflowScopeGate {
    private var entered = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        entered = true
        let pending = observers; observers.removeAll()
        for observer in pending { observer.resume() }
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor WorkflowScopeExecutor: AgentWorkflowStepExecutor {
    let gate: WorkflowScopeGate
    let failure: AgentWorkflowError?
    var requests: [AgentWorkflowStepRequest] = []
    init(gate: WorkflowScopeGate, failure: AgentWorkflowError? = nil) { self.gate = gate; self.failure = failure }
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String {
        requests.append(request)
        if request.step == .prompt("BLOCK") { await gate.hold() }
        // Deliberately ignores cancellation. The runtime must discard its late result.
        if let failure { throw failure }
        return "LATE_OUTPUT"
    }
}

private actor WorkflowScopeAuthorizer: AgentWorkflowActionAuthorizing {
    let gate: WorkflowScopeGate
    init(gate: WorkflowScopeGate) { self.gate = gate }
    func authorize(_ request: AgentWorkflowActionRequest) async -> Bool { await gate.hold(); return true }
}

private actor WorkflowScopeActionHandler: AgentWorkflowActionHandling {
    var requests: [AgentWorkflowActionRequest] = []
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String { requests.append(request); return "performed" }
}

private struct WorkflowScopePrompt: AgentWorkflowPromptExecuting {
    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String { request.prompt }
}

private func workflowScopeWaitForSignal(_ signal: DispatchSemaphore, timeout: DispatchTime = .now() + .seconds(8)) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: signal.wait(timeout: timeout) == .success) }
    }
}

@Suite("Workflow execution scope", .timeLimit(.minutes(1)))
struct WorkflowExecutionScopeTests {
    @Test func invalidationAndSuspensionNeverRevalidateOldLeases() throws {
        let scope = AgentWorkflowExecutionScope()
        let original = try scope.capture()
        expectNoDifference(try scope.capture(), original)
        expectNoDifference(Set([original, try scope.capture()]).count, 1)
        scope.invalidate()
        expectNoDifference(original.isActive, false)
        #expect(throws: CancellationError.self) { try original.check() }
        let current = try scope.capture()
        try current.check()
        #expect(current != original)
        scope.suspend()
        expectNoDifference(current.isActive, false)
        #expect(throws: CancellationError.self) { try scope.capture() }
        #expect(throws: CancellationError.self) { try current.check() }
        scope.resume()
        expectNoDifference(original.isActive, false)
        expectNoDifference(current.isActive, false)
        #expect(throws: CancellationError.self) { try original.check() }
        #expect(throws: CancellationError.self) { try current.check() }
        try scope.capture().check()
        let independent = try AgentWorkflowExecutionScope().capture()
        #expect(independent != current)
    }

    @Test func cancelledObserverCannotRetireOrCommitAnIndependentCurrentLease() async throws {
        let account = AgentWorkflowExecutionScope(), human = AgentWorkflowExecutionScope(), gate = WorkflowScopeGate()
        let parent = try account.capture(), lease = try human.capture(inheriting: parent)
        let observer = Task {
            await gate.hold()
            var commits = 0
            let active = lease.isActive
            do { try lease.commit { commits += 1 } }
            catch is CancellationError { return (active, true, commits) }
            return (active, false, commits)
        }
        await gate.waitUntilEntered()
        observer.cancel()
        await gate.release()
        let observed = try await observer.value
        expectNoDifference(observed.0, true)
        expectNoDifference(observed.1, true)
        expectNoDifference(observed.2, 0)
        expectNoDifference(lease.isActive, true)
        try lease.check()
        account.suspend(); account.resume()
        expectNoDifference(lease.isActive, false)
        #expect(throws: CancellationError.self) { try lease.check() }
        let fresh = try human.capture(inheriting: account.capture())
        expectNoDifference(fresh.isActive, true)
        human.invalidate()
        expectNoDifference(fresh.isActive, false)
    }

    @Test func overlappingTransitionsStaySuspendedUntilBothFinish() throws {
        let scope = AgentWorkflowExecutionScope()
        let original = try scope.capture()
        scope.suspend(); scope.suspend()
        scope.resume()
        #expect(throws: CancellationError.self) { try scope.capture() }
        scope.resume()
        try scope.capture().check()
        #expect(throws: CancellationError.self) { try original.check() }
    }

    @Test func finalSynchronousCommitAndRevocationHaveADefinedOrder() async throws {
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempting = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        let committing = Task.detached {
            try lease.commit {
                entered.signal()
                guard release.wait(timeout: .now() + .seconds(8)) == .success else { throw AgentWorkflowError.deadlineExceeded }
                return "COMMITTED_BEFORE_REVOCATION"
            }
        }
        defer { release.signal(); committing.cancel() }
        try #require(await workflowScopeWaitForSignal(entered))
        let revoking = Task.detached { attempting.signal(); scope.invalidate(); finished.signal() }
        try #require(await workflowScopeWaitForSignal(attempting))
        #expect(!(await workflowScopeWaitForSignal(finished, timeout: .now() + .milliseconds(25))))
        release.signal()
        let output = try await committing.value
        await revoking.value
        expectNoDifference(output, "COMMITTED_BEFORE_REVOCATION")
        #expect(throws: CancellationError.self) { try lease.commit { "MUST_NOT_COMMIT" } }
    }

    @Test func inheritedScopesAreDeduplicatedAndAllFenceTheCommit() throws {
        let first = AgentWorkflowExecutionScope(), second = AgentWorkflowExecutionScope()
        let parent = try first.capture()
        let child = try second.capture(inheriting: parent)
        let duplicate = try first.capture(inheriting: child)
        var commits = 0
        try duplicate.commit { commits += 1 }
        second.invalidate()
        #expect(throws: CancellationError.self) { try duplicate.commit { commits += 1 } }
        expectNoDifference(commits, 1)
        #expect(throws: CancellationError.self) { try first.capture(inheriting: duplicate) }
        try parent.check()
    }

    @Test(arguments: ["manual", "event", "schedule", "replay"], ["shared", "independent"])
    func cancelAllDiscardsLateResultsAndStopsFollowingStepsAndBatchMembers(route: String, upstream: String) async throws {
        let scope = AgentWorkflowExecutionScope(), gate = WorkflowScopeGate()
        let upstreamScope = upstream == "shared" ? scope : AgentWorkflowExecutionScope()
        let lease = try upstreamScope.capture()
        let executor = WorkflowScopeExecutor(gate: gate)
        let runtime = AgentWorkflowRuntime(executor: executor, executionScope: scope)
        let trigger: AgentWorkflowTrigger = route == "schedule" ? .schedule("0 9 * * *") : .event("push")
        let date = Date(timeIntervalSince1970: 1_000)
        let workflow = AgentWorkflow(id: "first", name: "First", trigger: trigger,
            steps: [.prompt("BLOCK"), .prompt("MUST_NOT_RUN")], createdAt: date, updatedAt: date)
        let second = AgentWorkflow(id: "second", name: "Second", trigger: trigger,
            steps: [.prompt("BATCH_MUST_NOT_RUN")], createdAt: date, updatedAt: date)
        var replayID: UUID?
        if route == "replay" {
            var baseline = workflow; baseline.steps = [.prompt("BASELINE")]
            replayID = await runtime.runManual(baseline).id
        }
        let replaySource = replayID
        let run = Task<[AgentWorkflowRun], Error> {
            switch route {
            case "event": return await runtime.fire(event: "push", workflows: [workflow, second], executionLease: lease)
            case "schedule": return await runtime.fire(schedule: "0 9 * * *", workflows: [workflow, second], executionLease: lease)
            case "replay": return [try await runtime.replay(runID: try #require(replaySource), workflow: workflow, executionLease: lease)]
            default: return [await runtime.runManual(workflow, executionLease: lease)]
            }
        }
        await gate.waitUntilEntered()
        scope.suspend()
        await runtime.cancelAll()
        scope.resume()
        if upstream == "independent" { try lease.check() }
        await gate.release()
        let cancelled = try #require(try await run.value.first)
        expectNoDifference(cancelled.status, .cancelled)
        expectNoDifference(cancelled.outputs, [])
        expectNoDifference(cancelled.failure, AgentWorkflowError.cancelled.localizedDescription)
        let requests = await executor.requests
        expectNoDifference(requests.map(\.step), route == "replay" ? [.prompt("BASELINE"), .prompt("BLOCK")] : [.prompt("BLOCK")])
        #expect(requests.allSatisfy { $0.executionLease != nil })
        let secondRuns = await runtime.runs(workflowID: "second")
        expectNoDifference(secondRuns, [])
        var fresh = workflow; fresh.steps = [.prompt("FRESH")]
        let completed = await runtime.runManual(fresh)
        expectNoDifference(completed.status, .succeeded)
        expectNoDifference(completed.outputs, ["LATE_OUTPUT"])
        let history = await runtime.runs()
        expectNoDifference(history.first { $0.id == cancelled.id }?.status, .cancelled)
    }

    @Test(arguments: [AgentWorkflowError.notFound, .deadlineExceeded])
    func revocationTakesPrecedenceOverALateExecutorFailure(failure: AgentWorkflowError) async throws {
        let scope = AgentWorkflowExecutionScope(), gate = WorkflowScopeGate()
        let executor = WorkflowScopeExecutor(gate: gate, failure: failure)
        let runtime = AgentWorkflowRuntime(executor: executor, executionScope: scope)
        let workflow = AgentWorkflow(id: "late-failure", name: "Late failure", steps: [.prompt("BLOCK"), .prompt("MUST_NOT_RUN")],
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        let run = Task { await runtime.runManual(workflow) }
        await gate.waitUntilEntered()
        // Isolate revocation from Task cancellation: the executor's own error arrives first.
        scope.invalidate()
        await gate.release()
        let result = await run.value
        expectNoDifference(result.status, .cancelled)
        expectNoDifference(result.outputs, [])
        expectNoDifference(result.failure, AgentWorkflowError.cancelled.localizedDescription)
        let requests = await executor.requests
        expectNoDifference(requests.map(\.step), [.prompt("BLOCK")])
    }

    @Test func staleDispatchCannotCancelAnAlreadyRunningFreshWorkflow() async throws {
        let scope = AgentWorkflowExecutionScope(), gate = WorkflowScopeGate()
        let executor = WorkflowScopeExecutor(gate: gate)
        let runtime = AgentWorkflowRuntime(executor: executor, executionScope: scope)
        let old = try scope.capture()
        scope.suspend(); scope.resume()
        let workflow = AgentWorkflow(id: "same", name: "Same", steps: [.prompt("BLOCK")],
            createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        let fresh = Task { await runtime.runManual(workflow) }
        await gate.waitUntilEntered()
        let rejected = await runtime.runManual(workflow, executionLease: old)
        expectNoDifference(rejected.status, .cancelled)
        let requests = await executor.requests
        expectNoDifference(requests.count, 1)
        await gate.release()
        let result = await fresh.value
        expectNoDifference(result.status, .succeeded)
    }

    @Test func aLateActionApprovalCannotCrossTheRevokedScope() async throws {
        let scope = AgentWorkflowExecutionScope(), gate = WorkflowScopeGate()
        let handler = WorkflowScopeActionHandler()
        let executor = AuthorizedAgentWorkflowExecutor(promptExecutor: WorkflowScopePrompt(),
            actionAuthorizer: WorkflowScopeAuthorizer(gate: gate), actionHandler: handler)
        let request = AgentWorkflowStepRequest(workflowID: "notify", runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            generation: 1, stepIndex: 0, step: .action(name: "notify", payload: "OLD_ACCOUNT_NOTIFICATION"),
            referencedWorkflows: [], priorOutputs: [], executionLease: try scope.capture())
        let run = Task { try await executor.execute(request) }
        await gate.waitUntilEntered()
        scope.suspend(); scope.resume()
        await gate.release()
        await #expect(throws: CancellationError.self) { try await run.value }
        let handled = await handler.requests
        expectNoDifference(handled, [])
    }
}
