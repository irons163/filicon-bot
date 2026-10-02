import Foundation
import FiliconAgents

/// App-facing boundary for workflow CRUD, import, dispatch, cancellation, and durable history.
/// Event listeners and schedulers supply already-authenticated/validated keys; this coordinator
/// only dispatches exact trigger matches and never grants connector or tool authority.
public actor WorkflowService {
    private let store: AgentWorkflowStore
    private let runtime: AgentWorkflowRuntime
    private let executionScope: AgentWorkflowExecutionScope

    public init(store: AgentWorkflowStore, runtime: AgentWorkflowRuntime,
                executionScope: AgentWorkflowExecutionScope = .init()) {
        self.store = store
        self.runtime = runtime
        self.executionScope = executionScope
    }

    public static func persistent(workflowsURL: URL, runHistoryURL: URL,
                                  promptExecutor: any AgentWorkflowPromptExecuting,
                                  actionAuthorizer: any AgentWorkflowActionAuthorizing = DenyAllAgentWorkflowActions(),
                                  actionHandler: any AgentWorkflowActionHandling,
                                  defaultDeadline: TimeInterval = 15 * 60,
                                  executionScope: AgentWorkflowExecutionScope = .init()) throws -> WorkflowService {
        let executor = AuthorizedAgentWorkflowExecutor(
            promptExecutor: promptExecutor,
            actionAuthorizer: actionAuthorizer,
            actionHandler: actionHandler
        )
        return try WorkflowService(
            store: AgentWorkflowStore(persistenceURL: workflowsURL),
            runtime: AgentWorkflowRuntime(
                executor: executor,
                defaultDeadline: defaultDeadline,
                historyURL: runHistoryURL,
                executionScope: executionScope
            ),
            executionScope: executionScope
        )
    }

    public func workflows() async -> [AgentWorkflow] { await store.list() }
    public func workflow(id: String) async -> AgentWorkflow? { await store.get(id) }
    public func writeSnapshot() async -> AgentWorkflowLibrarySnapshot { await store.writeSnapshot() }
    public func applyAgentWrite(_ change: AgentWorkflowWrite, lifetime: AgentWorkflowWriteLifetime,
                                at date: Date = .now) async throws -> AgentWorkflow {
        try await store.applyAgentWrite(change, lifetime: lifetime, at: date)
    }
    public func applyAgentDeletion(_ change: AgentWorkflowDeletion, lifetime: AgentWorkflowDeletionLifetime) async throws {
        try await store.applyAgentDeletion(change, lifetime: lifetime)
    }
    public func runs(workflowID: String? = nil) async -> [AgentWorkflowRun] {
        await runtime.runs(workflowID: workflowID)
    }

    @discardableResult
    public func create(_ workflow: AgentWorkflow) async throws -> AgentWorkflow {
        try await store.create(workflow)
    }

    @discardableResult
    public func update(id: String, with workflow: AgentWorkflow) async throws -> AgentWorkflow {
        try await store.update(id, with: workflow)
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, id: String) async throws -> AgentWorkflow {
        try await store.setEnabled(enabled, id: id)
    }

    public func delete(id: String) async throws { try await store.delete(id) }

    @discardableResult
    public func importText(_ markdown: String, fallbackName: String? = nil) async throws -> AgentWorkflow {
        try await store.importText(markdown, fallbackName: fallbackName)
    }

    @discardableResult
    public func importSkill(_ payload: AgentWorkflowSkillImportPayload) async throws -> AgentWorkflow {
        try await store.importSkill(payload)
    }

    @discardableResult
    public func importURL(_ url: URL, fallbackName: String? = nil,
                          fetcher: any AgentWorkflowHTTPSFetching = URLSessionAgentWorkflowFetcher()) async throws -> AgentWorkflow {
        try await store.importURL(url, fallbackName: fallbackName, fetcher: fetcher)
    }

    @discardableResult
    public func linkLiveSource(_ url: URL, fallbackName: String? = nil) async throws -> AgentWorkflow {
        try await store.linkLiveSource(url, fallbackName: fallbackName)
    }

    public func portPrivateSkills(_ payloads: [AgentWorkflowSkillImportPayload]) async -> AgentWorkflowImportResult {
        await store.portPrivateSkills(payloads)
    }

    /// Ensures the managed workflow used by Teach recordings exists without
    /// replacing a user's already-installed implementation.
    @discardableResult
    public func ensureLearningWorkflow(agentID: UUID?) async throws -> AgentWorkflow {
        if var existing = await store.get("learn-from-demonstration") {
            if !existing.isEnabled {
                existing = try await store.setEnabled(true, id: existing.id)
            }
            return existing
        }
        return try await store.create(.init(
            id: "learn-from-demonstration",
            agentID: agentID,
            name: "Learn from demonstration",
            description: "Analyze a private Teach recording and turn the demonstrated task into reusable instructions.",
            steps: [.prompt("Analyze the attached Teach recording carefully. Infer the demonstrated task, important decisions, and repeatable steps. Produce concise reusable instructions, call out uncertainty, and never invent actions that are not visible in the recording.")]
        ))
    }

    public func runNow(id: String, deadline: TimeInterval? = nil,
                       executionLease: AgentWorkflowExecutionScope.Lease? = nil) async throws -> AgentWorkflowRun {
        let lease = try executionScope.capture(inheriting: executionLease)
        try lease.check()
        let library = await store.list()
        try lease.check()
        guard let workflow = library.first(where: { $0.id == id }) else { throw AgentWorkflowError.notFound }
        return await runtime.runManual(workflow, library: library, deadline: deadline, executionLease: lease)
    }

    public func dispatchEvent(_ event: String, deadline: TimeInterval? = nil,
                              executionLease: AgentWorkflowExecutionScope.Lease? = nil) async throws -> [AgentWorkflowRun] {
        let lease = try executionScope.capture(inheriting: executionLease)
        try lease.check()
        let normalized = try Self.normalized(event, maximumCharacters: 128, field: "event")
        let library = await store.list()
        try lease.check()
        return await runtime.fire(event: normalized, workflows: library, deadline: deadline, executionLease: lease)
    }

    /// Called when the scheduler declares one normalized schedule expression due.
    public func dispatchSchedule(_ schedule: String, deadline: TimeInterval? = nil,
                                 executionLease: AgentWorkflowExecutionScope.Lease? = nil) async throws -> [AgentWorkflowRun] {
        let lease = try executionScope.capture(inheriting: executionLease)
        try lease.check()
        let normalized = try Self.normalizedSchedule(schedule)
        let library = await store.list()
        try lease.check()
        return await runtime.fire(schedule: normalized, workflows: library, deadline: deadline, executionLease: lease)
    }

    public func replay(runID: UUID, deadline: TimeInterval? = nil,
                       executionLease: AgentWorkflowExecutionScope.Lease? = nil) async throws -> AgentWorkflowRun {
        let lease = try executionScope.capture(inheriting: executionLease)
        try lease.check()
        let library = await store.list()
        guard let prior = await runtime.runs().first(where: { $0.id == runID }),
              let workflow = library.first(where: { $0.id == prior.workflowID }) else {
            throw AgentWorkflowError.replayRejected
        }
        try lease.check()
        return try await runtime.replay(runID: runID, workflow: workflow, library: library, deadline: deadline, executionLease: lease)
    }

    public func cancel(workflowID: String) async { await runtime.cancel(workflowID: workflowID) }
    public func cancel(runID: UUID) async { await runtime.cancel(runID: runID) }

    public func cancelAll() async {
        executionScope.invalidate()
        await runtime.cancelAll()
    }

    private static func normalized(_ value: String, maximumCharacters: Int, field: String) throws -> String {
        let clean = value
            .replacingOccurrences(of: #"[\r\n]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw AgentWorkflowError.malformed("empty \(field)") }
        guard clean.count <= maximumCharacters else { throw AgentWorkflowError.boundsExceeded(field) }
        return clean
    }

    private static func normalizedSchedule(_ value: String) throws -> String {
        let clean = try normalized(value, maximumCharacters: 256, field: "schedule")
        return clean.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
