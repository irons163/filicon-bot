import Foundation

public struct AgentWorkflowStepRequest: Hashable, Sendable {
    public var workflowID: String
    public var agentID: UUID?
    public var runID: UUID
    public var generation: UInt64
    public var stepIndex: Int
    public var step: AgentWorkflowStep
    public var referencedWorkflows: [AgentWorkflow]
    public var priorOutputs: [String]
    public var executionLease: AgentWorkflowExecutionScope.Lease?
    public var workflow: AgentWorkflow?
    public var origin: AgentWorkflowRunOrigin
    public init(workflowID: String, agentID: UUID? = nil, runID: UUID, generation: UInt64, stepIndex: Int,
                step: AgentWorkflowStep, referencedWorkflows: [AgentWorkflow], priorOutputs: [String],
                executionLease: AgentWorkflowExecutionScope.Lease? = nil,
                workflow: AgentWorkflow? = nil, origin: AgentWorkflowRunOrigin = .manual) {
        self.workflowID = workflowID; self.agentID = agentID; self.runID = runID; self.generation = generation; self.stepIndex = stepIndex
        self.step = step; self.referencedWorkflows = referencedWorkflows; self.priorOutputs = priorOutputs
        self.executionLease = executionLease
        self.workflow = workflow; self.origin = origin
    }
}

/// The core never executes a command. Hosts explicitly map prompt/action steps to their own policy-enforcing executor.
public protocol AgentWorkflowStepExecutor: Sendable {
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String
}

public enum AgentWorkflowRunOrigin: Hashable, Codable, Sendable {
    case manual
    case trigger(String)
    case replay(UUID)
}

public enum AgentWorkflowRunStatus: String, Codable, Hashable, Sendable {
    case running, succeeded, failed, cancelled, deadlineExceeded, waitingForReply
    public var isTerminal: Bool { self != .running }
}

/// A shared runner has durably published a question. Stop the pipeline; do not
/// execute later steps or imply task completion while waiting for a human.
public struct AgentWorkflowPromptSuspension: Error, Sendable {
    public let output: String
    public init(output: String) { self.output = output }
}

private struct AgentWorkflowPipelineSuspension: Error {
    let outputs: [String]
}

public struct AgentWorkflowRun: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var workflowID: String
    public var generation: UInt64
    public var origin: AgentWorkflowRunOrigin
    public var status: AgentWorkflowRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var outputs: [String]
    public var failure: String?
    public init(id: UUID = UUID(), workflowID: String, generation: UInt64, origin: AgentWorkflowRunOrigin,
                status: AgentWorkflowRunStatus = .running, startedAt: Date = .now, finishedAt: Date? = nil,
                outputs: [String] = [], failure: String? = nil) {
        self.id = id; self.workflowID = workflowID; self.generation = generation; self.origin = origin; self.status = status
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.outputs = outputs; self.failure = failure
    }
}

public enum AgentWorkflowReferenceResolver {
    public static func resolve(in workflow: AgentWorkflow, library: [AgentWorkflow]) throws -> [AgentWorkflow] {
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id.lowercased(), $0) })
        var result: [AgentWorkflow] = [], seen = Set<String>(), visiting = Set([workflow.id.lowercased()])
        try visit(workflow, byID: byID, depth: 0, seen: &seen, visiting: &visiting, result: &result)
        return result
    }

    private static func visit(_ workflow: AgentWorkflow, byID: [String: AgentWorkflow], depth: Int,
                              seen: inout Set<String>, visiting: inout Set<String>, result: inout [AgentWorkflow]) throws {
        guard depth < AgentWorkflowLimits.maximumReferenceDepth else { throw AgentWorkflowError.boundsExceeded("reference depth") }
        for id in mentionedIDs(in: workflow, library: Array(byID.values)) {
            let lower = id.lowercased(); guard let referenced = byID[lower], referenced.isEnabled else { throw AgentWorkflowError.referenceNotFound(id) }
            guard !visiting.contains(lower) else { throw AgentWorkflowError.referenceCycle }
            if seen.insert(lower).inserted {
                guard seen.count <= AgentWorkflowLimits.maximumReferences else { throw AgentWorkflowError.boundsExceeded("references") }
                visiting.insert(lower); try visit(referenced, byID: byID, depth: depth + 1, seen: &seen, visiting: &visiting, result: &result); visiting.remove(lower)
                result.append(referenced)
            }
        }
    }

    public static func mentionedIDs(in workflow: AgentWorkflow, library: [AgentWorkflow]) -> [String] {
        let prompt = workflow.steps.compactMap { if case .prompt(let text) = $0 { text } else { nil } }.joined(separator: "\n").lowercased()
        var found = Set<String>()
        let expression = try? NSRegularExpression(pattern: #"sand-workflow:([a-z0-9]+(?:-[a-z0-9]+)*)"#, options: [.caseInsensitive])
        let range = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
        expression?.enumerateMatches(in: prompt, range: range) { match, _, _ in
            if let match, let value = Range(match.range(at: 1), in: prompt) { found.insert(String(prompt[value])) }
        }
        let candidates = library.flatMap { workflow -> [(String, String)] in
            let name = workflow.name.lowercased(); return [(workflow.id.lowercased(), workflow.id), (name, workflow.id), (name.replacingOccurrences(of: " ", with: ""), workflow.id)]
        }.sorted { $0.0.count > $1.0.count }
        for (handle, id) in candidates where !handle.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: handle)
            if prompt.range(of: "(?<![a-z0-9])@\(escaped)(?![a-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil { found.insert(id.lowercased()) }
        }
        return library.filter { found.contains($0.id.lowercased()) }.map(\.id)
    }
}

public actor AgentWorkflowRuntime {
    private let executor: any AgentWorkflowStepExecutor
    private let defaultDeadline: TimeInterval
    private var generations: [String: UInt64] = [:]
    private var active: [String: (runID: UUID, task: Task<[String], Error>)] = [:]
    private var history: [AgentWorkflowRun] = []
    private var replayed = Set<UUID>()
    private let historyPersistence: AgentWorkflowRunPersistence?
    private let executionScope: AgentWorkflowExecutionScope

    public init(executor: any AgentWorkflowStepExecutor, defaultDeadline: TimeInterval = 15 * 60,
                executionScope: AgentWorkflowExecutionScope = .init()) {
        self.executor = executor
        self.defaultDeadline = max(0.05, min(defaultDeadline, 24 * 60 * 60))
        self.historyPersistence = nil
        self.executionScope = executionScope
    }

    /// Restores bounded history and marks runs interrupted by a previous process exit as failed.
    public init(executor: any AgentWorkflowStepExecutor, defaultDeadline: TimeInterval = 15 * 60,
                historyURL: URL, fileManager: FileManager = .default,
                executionScope: AgentWorkflowExecutionScope = .init()) throws {
        self.executor = executor
        self.defaultDeadline = max(0.05, min(defaultDeadline, 24 * 60 * 60))
        let persistence = AgentWorkflowRunPersistence(url: historyURL, fileManager: fileManager)
        var restored = try persistence.load()
        var recovered = false
        for index in restored.indices where restored[index].status == .running {
            restored[index].status = .failed
            restored[index].finishedAt = .now
            restored[index].failure = "Interrupted by app restart."
            recovered = true
        }
        self.history = restored
        self.replayed = Set(restored.compactMap {
            if case .replay(let source) = $0.origin { source } else { nil }
        })
        self.generations = Dictionary(grouping: restored, by: \AgentWorkflowRun.workflowID)
            .mapValues { $0.map(\.generation).max() ?? 0 }
        self.historyPersistence = persistence
        self.executionScope = executionScope
        if recovered { try persistence.save(restored) }
    }

    public func runs(workflowID: String? = nil) -> [AgentWorkflowRun] {
        history.filter { workflowID == nil || $0.workflowID == workflowID }.sorted { $0.startedAt > $1.startedAt }
    }

    public func runManual(_ workflow: AgentWorkflow, library: [AgentWorkflow] = [], deadline: TimeInterval? = nil,
                          executionLease: AgentWorkflowExecutionScope.Lease? = nil) async -> AgentWorkflowRun {
        await run(workflow, origin: .manual, library: library, deadline: deadline, executionLease: executionLease)
    }

    public func fire(event: String, workflows: [AgentWorkflow], deadline: TimeInterval? = nil,
                     executionLease: AgentWorkflowExecutionScope.Lease? = nil) async -> [AgentWorkflowRun] {
        guard let lease = try? executionScope.capture(inheriting: executionLease) else { return [] }
        var records: [AgentWorkflowRun] = []
        for workflow in workflows where workflow.isEnabled {
            guard case .event(let expected) = workflow.trigger, expected == event else { continue }
            guard (try? lease.check()) != nil else { break }
            records.append(await run(workflow, origin: .trigger(event), library: workflows, deadline: deadline, executionLease: lease))
        }
        return records
    }

    /// Scheduler integration point: the host decides when a normalized schedule is due.
    public func fire(schedule: String, workflows: [AgentWorkflow], deadline: TimeInterval? = nil,
                     executionLease: AgentWorkflowExecutionScope.Lease? = nil) async -> [AgentWorkflowRun] {
        guard let lease = try? executionScope.capture(inheriting: executionLease) else { return [] }
        var records: [AgentWorkflowRun] = []
        for workflow in workflows where workflow.isEnabled {
            guard case .schedule(let expected) = workflow.trigger, expected == schedule else { continue }
            guard (try? lease.check()) != nil else { break }
            records.append(await run(workflow, origin: .trigger("schedule:\(schedule)"), library: workflows, deadline: deadline,
                                     requireTriggerMatch: false, executionLease: lease))
        }
        return records
    }

    public func replay(runID: UUID, workflow: AgentWorkflow, library: [AgentWorkflow] = [], deadline: TimeInterval? = nil,
                       executionLease: AgentWorkflowExecutionScope.Lease? = nil) async throws -> AgentWorkflowRun {
        let lease = try executionScope.capture(inheriting: executionLease)
        try lease.check()
        guard let previous = history.first(where: { $0.id == runID }), previous.workflowID == workflow.id,
              previous.status.isTerminal, replayed.insert(runID).inserted else { throw AgentWorkflowError.replayRejected }
        return await run(workflow, origin: .replay(runID), library: library, deadline: deadline, executionLease: lease)
    }

    public func cancel(workflowID: String) {
        active[workflowID]?.task.cancel()
    }

    public func cancel(runID: UUID) {
        for (_, value) in active where value.runID == runID { value.task.cancel() }
    }

    public func cancelAll() {
        executionScope.invalidate()
        for value in active.values { value.task.cancel() }
        // Keep active entries until their executor unwinds; never report an
        // ignored cancellation as success or free another run's active entry.
    }

    private func run(_ workflow: AgentWorkflow, origin: AgentWorkflowRunOrigin, library: [AgentWorkflow], deadline: TimeInterval?,
                     requireTriggerMatch: Bool = true, executionLease: AgentWorkflowExecutionScope.Lease? = nil) async -> AgentWorkflowRun {
        let lease: AgentWorkflowExecutionScope.Lease
        do { lease = try executionScope.capture(inheriting: executionLease) }
        catch { return terminal(workflow, origin: origin, generation: generations[workflow.id] ?? 0,
                                status: .cancelled, failure: AgentWorkflowError.cancelled.localizedDescription) }
        // Matches the source product: disablement suppresses automatic surfacing/firing,
        // while an explicit Run Now remains an intentional user action.
        if case .manual = origin { } else if !workflow.isEnabled {
            return terminal(workflow, origin: origin, generation: generations[workflow.id] ?? 0, status: .failed, failure: AgentWorkflowError.disabled.localizedDescription)
        }
        if case .manual = origin { } else if requireTriggerMatch, case .trigger(let event) = origin {
            guard case .event(let expected) = workflow.trigger, expected == event else { return terminal(workflow, origin: origin, generation: generations[workflow.id] ?? 0, status: .failed, failure: AgentWorkflowError.triggerMismatch.localizedDescription) }
        }
        active[workflow.id]?.task.cancel()
        let generation = (generations[workflow.id] ?? 0) &+ 1; generations[workflow.id] = generation
        let run = AgentWorkflowRun(workflowID: workflow.id, generation: generation, origin: origin)
        history.append(run)
        trimHistory()
        do { try persistHistory() }
        catch {
            history.removeAll { $0.id == run.id }
            return terminal(workflow, run: run, status: .failed,
                failure: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        let executor = self.executor
        let task = Task<[String], Error> {
            let references = try AgentWorkflowReferenceResolver.resolve(in: workflow, library: library)
            return try await Self.withDeadline(deadline ?? self.defaultDeadline) {
                var outputs: [String] = []
                for (index, step) in workflow.steps.enumerated() {
                    try lease.check()
                    let output: String
                    do {
                        output = try await executor.execute(.init(workflowID: workflow.id, agentID: workflow.agentID, runID: run.id, generation: generation,
                            stepIndex: index, step: step, referencedWorkflows: references, priorOutputs: outputs,
                            executionLease: lease, workflow: workflow, origin: origin))
                    } catch let pending as AgentWorkflowPromptSuspension {
                        try lease.check()
                        guard pending.output.utf8.count <= AgentWorkflowLimits.maximumBodyBytes,
                              outputs.reduce(0, { $0 + $1.utf8.count }) + pending.output.utf8.count <= AgentWorkflowLimits.maximumBodyBytes
                        else { throw AgentWorkflowError.boundsExceeded("step outputs") }
                        throw AgentWorkflowPipelineSuspension(outputs: outputs + [pending.output])
                    }
                    try lease.check()
                    guard output.utf8.count <= AgentWorkflowLimits.maximumBodyBytes,
                          outputs.reduce(0, { $0 + $1.utf8.count }) + output.utf8.count <= AgentWorkflowLimits.maximumBodyBytes
                    else { throw AgentWorkflowError.boundsExceeded("step outputs") }
                    outputs.append(output)
                }
                return outputs
            }
        }
        active[workflow.id] = (run.id, task)
        do {
            let outputs = try await task.value
            return try lease.commit {
                guard generations[workflow.id] == generation else { return terminal(workflow, run: run, status: .failed, failure: AgentWorkflowError.staleGeneration.localizedDescription) }
                active.removeValue(forKey: workflow.id)
                return terminal(workflow, run: run, status: .succeeded, outputs: outputs)
            }
        } catch {
            if generations[workflow.id] == generation { active.removeValue(forKey: workflow.id) }
            if error is CancellationError || task.isCancelled || (try? lease.check()) == nil {
                return terminal(workflow, run: run, status: .cancelled, failure: AgentWorkflowError.cancelled.localizedDescription)
            }
            if let workflowError = error as? AgentWorkflowError, workflowError == .deadlineExceeded {
                return terminal(workflow, run: run, status: .deadlineExceeded, failure: AgentWorkflowError.deadlineExceeded.localizedDescription)
            }
            if let pending = error as? AgentWorkflowPipelineSuspension {
                do {
                    return try lease.commit {
                        guard generations[workflow.id] == generation else { throw CancellationError() }
                        return terminal(workflow, run: run, status: .waitingForReply, outputs: pending.outputs)
                    }
                } catch { return terminal(workflow, run: run, status: .cancelled, failure: AgentWorkflowError.cancelled.localizedDescription) }
            }
            return terminal(workflow, run: run, status: .failed,
                failure: (error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
    }

    private func terminal(_ workflow: AgentWorkflow, origin: AgentWorkflowRunOrigin, generation: UInt64,
                          status: AgentWorkflowRunStatus, failure: String?) -> AgentWorkflowRun {
        terminal(workflow, run: .init(workflowID: workflow.id, generation: generation, origin: origin), status: status, failure: failure)
    }
    private func terminal(_ workflow: AgentWorkflow, run: AgentWorkflowRun, status: AgentWorkflowRunStatus,
                          outputs: [String] = [], failure: String? = nil) -> AgentWorkflowRun {
        var result = run
        result.status = status
        result.finishedAt = .now
        result.outputs = outputs
        result.failure = failure.map { Self.utf8Prefix($0, maximumBytes: AgentWorkflowLimits.maximumRunFailureBytes) }
        if let index = history.firstIndex(where: { $0.id == result.id }) { history[index] = result }
        else { history.append(result) }
        trimHistory()
        do { try persistHistory() }
        catch {
            result.status = .failed
            result.failure = Self.utf8Prefix(String(describing: error), maximumBytes: AgentWorkflowLimits.maximumRunFailureBytes)
            if let index = history.firstIndex(where: { $0.id == result.id }) { history[index] = result }
        }
        return result
    }

    private func trimHistory() {
        if history.count > AgentWorkflowLimits.maximumRuns {
            history.removeFirst(history.count - AgentWorkflowLimits.maximumRuns)
        }
    }

    private func persistHistory() throws { try historyPersistence?.save(history) }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let scalarBytes = value[end..<next].utf8.count
            guard bytes + scalarBytes <= maximumBytes else { break }
            bytes += scalarBytes
            end = next
        }
        return String(value[..<end])
    }

    private static func withDeadline<T: Sendable>(_ seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(0.001, min(seconds, 24 * 60 * 60)) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds); throw AgentWorkflowError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
