import Foundation
import FiliconDomain

public enum SubagentTurnOutcome: Sendable, Equatable {
    case completed(text: String, usage: Usage)
    case interrupted
}

public protocol SubagentRuntime: Sendable {
    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome
    func interrupt(reason: String) async
}

/// A typed runtime lets the workspace use one cancellation and persistence pipeline for
/// provider subagents, local shell jobs, and remote/cloud jobs without confusing their UI.
public protocol AgentAsyncTaskRuntime: SubagentRuntime {
    nonisolated var taskKind: AgentTaskKind { get }
}

/// Type-erased adapter used by platform layers to plug in a provider turn, a `Process`,
/// or a cloud execution API while retaining the same cooperative interruption contract.
public actor AgentAsyncTaskRuntimeAdapter: AgentAsyncTaskRuntime {
    public nonisolated let taskKind: AgentTaskKind
    private let operation: @Sendable (String, SubagentExecutionScope) async throws -> SubagentTurnOutcome
    private let interruption: @Sendable (String) async -> Void

    public init(
        taskKind: AgentTaskKind,
        operation: @escaping @Sendable (String, SubagentExecutionScope) async throws -> SubagentTurnOutcome,
        interruption: @escaping @Sendable (String) async -> Void
    ) {
        self.taskKind = taskKind
        self.operation = operation
        self.interruption = interruption
    }

    public func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        try await operation(prompt, scope)
    }

    public func interrupt(reason: String) async { await interruption(reason) }
}

public actor SubagentService {
    public static let maximumDepth = 3
    public static let maximumConcurrent = 4
    public static let maximumConcurrentPerParent = 2
    public static let maximumPromptCharacters = 32_000
    public static let maximumSteerCharacters = 8_000

    private let agents: AgentService
    private let scheduler: AgentExecutionScheduler
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var runtimes: [UUID: any SubagentRuntime] = [:]
    private var pendingSteers: [UUID: String] = [:]
    private var cancelling: Set<UUID> = []
    private var executing: Set<UUID> = []
    private var parentScopes: [UUID: SubagentExecutionScope] = [:]
    private var cancellationGeneration: UInt64 = 0

    public init(agents: AgentService, scheduler: AgentExecutionScheduler = AgentExecutionScheduler()) {
        self.agents = agents; self.scheduler = scheduler
    }

    @discardableResult
    public func launch(
        _ spec: SubagentSpec,
        parentRunID: UUID,
        parentScope: SubagentExecutionScope,
        runtime: any SubagentRuntime
    ) async throws -> UUID {
        let generation = cancellationGeneration
        try Task.checkCancellation()
        let prompt = spec.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = spec.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.count <= Self.maximumPromptCharacters,
              !title.isEmpty, !spec.parentToolCallID.isEmpty,
              spec.maximumTokens.map({ $0 > 0 }) ?? true else {
            throw AgentServiceError.invalidSubagent
        }
        guard spec.depth >= 0, spec.depth <= Self.maximumDepth else {
            throw AgentServiceError.depthLimit
        }
        guard !spec.ancestorAgentIDs.contains(spec.agentID) else {
            throw AgentServiceError.cycleDetected
        }
        guard parentScope.contains(spec.scope) else {
            throw AgentServiceError.scopeEscalation
        }
        if let typedRuntime = runtime as? any AgentAsyncTaskRuntime,
           typedRuntime.taskKind != spec.taskKind {
            throw AgentServiceError.invalidSubagent
        }
        guard await agents.profile(id: spec.agentID)?.archivedAt == nil else {
            throw AgentServiceError.unknownAgent(spec.agentID)
        }
        guard tasks.count < Self.maximumConcurrent else {
            throw AgentServiceError.concurrencyLimit
        }
        let parentCount = await agents.subagents(parentRunID: parentRunID).filter {
            $0.status == .queued || $0.status == .running || $0.status == .awaitingInput
        }.count
        guard parentCount < Self.maximumConcurrentPerParent else {
            throw AgentServiceError.concurrencyLimit
        }

        let record = SubagentRecord(
            parentRunID: parentRunID,
            parentToolCallID: spec.parentToolCallID,
            agentID: spec.agentID,
            title: String(title.prefix(160)),
            depth: spec.depth,
            taskKind: spec.taskKind,
            parentAgentID: spec.parentAgentID
        )
        guard generation == cancellationGeneration else { throw CancellationError() }
        try await agents.registerSubagent(record)
        guard generation == cancellationGeneration, !Task.isCancelled else {
            try? await agents.settleSubagent(id: record.id, status: .cancelled,
                                            result: "Stopped before execution.", usage: .init())
            throw CancellationError()
        }
        runtimes[record.id] = runtime
        parentScopes[record.id] = parentScope
        tasks[record.id] = Task { [weak self] in
            await self?.execute(id: record.id, spec: spec, runtime: runtime)
        }
        return record.id
    }

    public func status(_ id: UUID) async -> SubagentRecord? {
        await agents.subagent(id: id)
    }

    public func list(parentRunID: UUID? = nil) async -> [SubagentRecord] {
        await agents.subagents(parentRunID: parentRunID)
    }

    public func steer(_ id: UUID, message: String) async throws {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= Self.maximumSteerCharacters else {
            throw AgentServiceError.invalidSubagent
        }
        guard let runtime = runtimes[id], tasks[id] != nil, !cancelling.contains(id) else {
            throw AgentServiceError.subagentNotRunning(id)
        }
        pendingSteers[id] = message
        try await agents.updateSubagent(id: id, status: .awaitingInput)
        if executing.contains(id) { await runtime.interrupt(reason: "Steering message from the parent agent.") }
    }

    public func cancel(_ id: UUID) async {
        guard let runtime = runtimes[id], let task = tasks[id] else { return }
        cancelling.insert(id)
        pendingSteers[id] = nil
        task.cancel()
        if executing.contains(id) { await runtime.interrupt(reason: "Stopped by the parent agent.") }
    }

    public func cancelAll() async {
        cancellationGeneration &+= 1
        for id in Array(tasks.keys) { await cancel(id) }
    }

    public func cancel(parentRunID: UUID) async {
        let ids = await agents.subagents(parentRunID: parentRunID)
            .filter { $0.status == .queued || $0.status == .running || $0.status == .awaitingInput }
            .map(\.id)
        for id in ids { await cancel(id) }
    }

    public func drain() async {
        let running = Array(tasks.values)
        for task in running { await task.value }
    }

    private func execute(id: UUID, spec: SubagentSpec, runtime: any SubagentRuntime) async {
        var prompt = spec.prompt
        var cumulativeUsage = Usage()
        while true {
            if cancelling.contains(id) || Task.isCancelled {
                await finish(id: id, status: .cancelled, result: "Stopped by the parent agent.", usage: cumulativeUsage)
                return
            }
            do {
                let nextPrompt = prompt
                let outcome = try await scheduler.withExclusiveAccess(agentID: spec.agentID) {
                    let effectivePrompt = try await self.beginExecution(id: id, prompt: nextPrompt)
                    return try await runtime.run(prompt: effectivePrompt, scope: spec.scope)
                }
                executing.remove(id)
                if cancelling.contains(id) || Task.isCancelled {
                    await finish(id: id, status: .cancelled, result: "Stopped by the parent agent.", usage: cumulativeUsage)
                    return
                }
                if case .completed(_, let usage) = outcome {
                    cumulativeUsage.inputTokens += usage.inputTokens
                    cumulativeUsage.outputTokens += usage.outputTokens
                    if let maximum = spec.maximumTokens,
                       cumulativeUsage.inputTokens + cumulativeUsage.outputTokens > maximum {
                        await finish(id: id, status: .failed, result: AgentServiceError.tokenBudgetExceeded.localizedDescription, usage: cumulativeUsage)
                        return
                    }
                }
                // Interruption is cooperative: the transport may already have
                // completed. Accepted steering still needs a turn, but cannot
                // bypass cancellation or the cumulative token budget above.
                if let steer = pendingSteers.removeValue(forKey: id) {
                    prompt = "A parent agent sent this steering message. Preserve prior context and continue:\n\n\(steer)"
                    try await agents.updateSubagent(id: id, status: .queued)
                    continue
                }
                switch outcome {
                case .interrupted:
                    await finish(id: id, status: .interrupted, result: "The subagent was interrupted before it finished.", usage: cumulativeUsage)
                case .completed(let text, _):
                    let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await finish(id: id, status: .succeeded, result: result.isEmpty ? "(the task finished without producing any text output)" : result, usage: cumulativeUsage)
                }
                return
            } catch is CancellationError {
                await finish(id: id, status: .cancelled, result: "Stopped by the parent agent.", usage: cumulativeUsage)
                return
            } catch {
                if cancelling.contains(id) || Task.isCancelled {
                    await finish(id: id, status: .cancelled, result: "Stopped by the parent agent.", usage: cumulativeUsage)
                } else {
                    await finish(id: id, status: .failed, result: error.localizedDescription, usage: cumulativeUsage)
                }
                return
            }
        }
    }

    private func beginExecution(id: UUID, prompt: String) async throws -> String {
        try Task.checkCancellation()
        guard !cancelling.contains(id) else { throw CancellationError() }
        executing.insert(id)
        try await agents.updateSubagent(id: id, status: .running)
        try Task.checkCancellation()
        if let steer = pendingSteers.removeValue(forKey: id) {
            return "\(prompt)\n\nThe parent updated this queued task before execution:\n\(steer)"
        }
        return prompt
    }

    private func finish(id: UUID, status: AgentRunStatus, result: String, usage: Usage) async {
        try? await agents.settleSubagent(id: id, status: status, result: result, usage: usage)
        tasks[id] = nil
        runtimes[id] = nil
        pendingSteers[id] = nil
        cancelling.remove(id)
        executing.remove(id)
        parentScopes[id] = nil
    }
}
