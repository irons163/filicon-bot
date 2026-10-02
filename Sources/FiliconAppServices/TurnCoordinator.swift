import Foundation
import FiliconDomain
import FiliconProviderKit
import FiliconAgents

public struct ModelRefreshTicket: Equatable, Sendable {
    fileprivate let generation: UInt64
    public let accountGeneration: UInt64
    public let conversationID: UUID
    public let providerID: ProviderID
}

public struct ModelRefreshGuard: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func begin(
        accountGeneration: UInt64 = 0,
        conversationID: UUID,
        providerID: ProviderID
    ) -> ModelRefreshTicket {
        generation &+= 1
        return ModelRefreshTicket(
            generation: generation,
            accountGeneration: accountGeneration,
            conversationID: conversationID,
            providerID: providerID
        )
    }

    public func accepts(
        _ ticket: ModelRefreshTicket,
        accountGeneration: UInt64 = 0,
        selectedConversationID: UUID?,
        selectedProviderID: ProviderID?
    ) -> Bool {
        ticket.generation == generation
            && ticket.accountGeneration == accountGeneration
            && ticket.conversationID == selectedConversationID
            && ticket.providerID == selectedProviderID
    }
}

public actor TurnCoordinator {
    private struct Submission {
        let token: UUID
        let request: InferenceRequest
        let provider: any AIProvider
        let additionalTools: [any ToolExecutor]
        let toolContext: ToolContext
        let agentID: UUID?
        let agentLane: AgentExecutionLane
        let priority: Bool
        let executionTimeout: Duration?
        let onStart: @Sendable () async throws -> Void
        let onEvent: @Sendable (InferenceEvent) async throws -> Void
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ActiveTurn {
        let token: UUID
        let task: Task<Void, any Error>
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let registry: ProviderRegistry
    private let toolCatalog: ToolCatalog?
    /// Provider support alone does not mean the host will supply tools.
    public nonisolated var supportsToolExecution: Bool { toolCatalog != nil }
    private let agentScheduler: AgentExecutionScheduler
    private var active: [UUID: ActiveTurn] = [:]
    private var pending: [UUID: [Submission]] = [:]

    public init(registry: ProviderRegistry, toolCatalog: ToolCatalog? = nil,
                agentScheduler: AgentExecutionScheduler = AgentExecutionScheduler()) {
        self.registry = registry; self.toolCatalog = toolCatalog; self.agentScheduler = agentScheduler
    }

    public func send(
        request: InferenceRequest,
        providerID: ProviderID,
        additionalTools: [any ToolExecutor] = [],
        toolContext: ToolContext? = nil,
        agentID: UUID? = nil,
        agentLane: AgentExecutionLane = .user,
        priority: Bool = false,
        executionTimeout: Duration? = nil,
        onStart: @escaping @Sendable () async throws -> Void = {},
        onEvent: @escaping @Sendable (InferenceEvent) async throws -> Void
    ) async throws {
        guard let provider = await registry.provider(id: providerID) else {
            throw ProviderError.invalidResponse
        }
        let token = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let submission = Submission(
                    token: token,
                    request: request,
                    provider: provider,
                    additionalTools: additionalTools,
                    toolContext: toolContext ?? ToolContext(conversationID: request.conversationID),
                    agentID: agentID,
                    agentLane: agentLane,
                    priority: priority,
                    executionTimeout: executionTimeout,
                    onStart: onStart,
                    onEvent: onEvent,
                    continuation: continuation
                )
                enqueue(submission, conversationID: request.conversationID)
            }
        } onCancel: {
            Task { await self.cancelSubmission(token: token, conversationID: request.conversationID) }
        }
    }

    public func cancel(conversationID: UUID) {
        let queued = pending.removeValue(forKey: conversationID) ?? []
        for submission in queued {
            submission.continuation.resume(throwing: CancellationError())
        }
        active[conversationID]?.task.cancel()
    }

    public func isActive(conversationID: UUID) -> Bool {
        active[conversationID] != nil || !(pending[conversationID]?.isEmpty ?? true)
    }

    public func queuedCount(conversationID: UUID) -> Int {
        pending[conversationID]?.count ?? 0
    }

    private func enqueue(_ submission: Submission, conversationID: UUID) {
        pending[conversationID, default: []].append(submission)
        startNextIfNeeded(conversationID: conversationID)
    }

    private func startNextIfNeeded(conversationID: UUID) {
        guard active[conversationID] == nil,
              var queue = pending[conversationID],
              !queue.isEmpty else { return }

        let submission = queue.removeFirst()
        if queue.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = queue
        }

        let catalog = toolCatalog
        let scheduler = agentScheduler
        let task = Task {
            if let agentID = submission.agentID {
                try await scheduler.withExclusiveAccess(agentID: agentID, lane: submission.agentLane, priority: submission.priority) {
                    try await Self.execute(submission, catalog: catalog)
                }
            } else {
                try await Self.execute(submission, catalog: catalog)
            }
        }
        active[conversationID] = ActiveTurn(
            token: submission.token,
            task: task,
            continuation: submission.continuation
        )

        Task {
            let result = await task.result
            finishActive(token: submission.token, conversationID: conversationID, result: result)
        }
    }

    private static func execute(_ submission: Submission, catalog: ToolCatalog?) async throws {
        try Task.checkCancellation()
        try await submission.onStart()
        if let timeout = submission.executionTimeout {
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                tasks.addTask { try await consume(submission, catalog: catalog) }
                tasks.addTask {
                    try await Task.sleep(for: timeout)
                    throw AgentTurnTimeout()
                }
                defer { tasks.cancelAll() }
                _ = try await tasks.next()
            }
        } else { try await consume(submission, catalog: catalog) }
    }

    private static func consume(_ submission: Submission, catalog: ToolCatalog?) async throws {
        try Task.checkCancellation()
        let stream: AsyncThrowingStream<InferenceEvent, Error>
        let toolRun: ToolLoopRun?
        if let catalog, submission.provider.descriptor.supportsToolCalling {
            let run = await ToolLoop(provider: submission.provider, catalog: catalog, additionalTools: submission.additionalTools).start(
                submission.request, context: submission.toolContext, onEvent: submission.onEvent
            )
            toolRun = run; stream = run.events
        } else { toolRun = nil; stream = submission.provider.stream(submission.request) }
        var completion = InferenceResponseCompletion()
        do {
            for try await event in stream {
                try Task.checkCancellation()
                // ToolLoop awaited this callback before execution. Drain its
                // stream for completion/cancellation without delivering twice.
                if toolRun == nil {
                    try completion.consume(event)
                    try await submission.onEvent(event)
                }
            }
            try Task.checkCancellation()
            if toolRun == nil { try completion.finish() }
            await toolRun?.finish()
        } catch {
            await toolRun?.cancelAndWait()
            throw error
        }
    }

    private func finishActive(
        token: UUID,
        conversationID: UUID,
        result: Result<Void, any Error>
    ) {
        guard let turn = active[conversationID], turn.token == token else { return }
        active.removeValue(forKey: conversationID)
        switch result {
        case .success:
            turn.continuation.resume()
        case .failure(let error):
            turn.continuation.resume(throwing: error)
        }
        startNextIfNeeded(conversationID: conversationID)
    }

    private func cancelSubmission(token: UUID, conversationID: UUID) {
        if let turn = active[conversationID], turn.token == token {
            turn.task.cancel()
            return
        }
        guard var queue = pending[conversationID],
              let index = queue.firstIndex(where: { $0.token == token }) else { return }
        let submission = queue.remove(at: index)
        if queue.isEmpty {
            pending.removeValue(forKey: conversationID)
        } else {
            pending[conversationID] = queue
        }
        submission.continuation.resume(throwing: CancellationError())
    }
}

private struct AgentTurnTimeout: LocalizedError {
    var errorDescription: String? { "The delegated agent response timed out." }
}
