import Foundation
import FiliconDomain
import FiliconProviderKit

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
        let onEvent: @Sendable (InferenceEvent) async -> Void
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct ActiveTurn {
        let token: UUID
        let task: Task<Void, any Error>
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let registry: ProviderRegistry
    private let toolCatalog: ToolCatalog?
    private var active: [UUID: ActiveTurn] = [:]
    private var pending: [UUID: [Submission]] = [:]

    public init(registry: ProviderRegistry, toolCatalog: ToolCatalog? = nil) { self.registry = registry; self.toolCatalog = toolCatalog }

    public func send(
        request: InferenceRequest,
        providerID: ProviderID,
        onEvent: @escaping @Sendable (InferenceEvent) async -> Void
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
        let task = Task {
            let stream: AsyncThrowingStream<InferenceEvent, Error>
            if let catalog {
                stream = await ToolLoop(provider: submission.provider, catalog: catalog).run(
                    submission.request,
                    context: ToolContext(conversationID: conversationID)
                )
            } else {
                stream = submission.provider.stream(submission.request)
            }
            for try await event in stream {
                try Task.checkCancellation()
                await submission.onEvent(event)
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
