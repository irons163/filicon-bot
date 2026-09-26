import Foundation
import FiliconAgents
import FiliconDomain
import FiliconProviderKit

/// Fresh, tool-free maintenance requests. This transport does not enable
/// synthesis or save memories; the host pipeline owns consent and persistence.
public struct AgentMemorySynthesisTransport: Sendable {
    private let agents: AgentService
    private let coordinator: TurnCoordinator
    private let timeout: Duration

    public init(agents: AgentService, registry: ProviderRegistry, scheduler: AgentExecutionScheduler,
                timeout: Duration = .seconds(45)) {
        self.agents = agents
        self.coordinator = TurnCoordinator(registry: registry, agentScheduler: scheduler)
        self.timeout = timeout
    }

    public func cancel(sessionID: UUID, lifetime: AgentMemorySuggestionLifetime) async {
        lifetime.close()
        await coordinator.cancel(conversationID: sessionID)
    }

    public func execute(stage: AgentMemorySynthesisStage, instructions: String, payload: String,
                        profile: AgentProfile, sessionID: UUID,
                        lifetime: AgentMemorySuggestionLifetime) async throws -> String {
        try lifetime.check()
        guard instructions.utf8.count <= 16_384, payload.utf8.count <= 2_097_152 else {
            throw AgentMemorySuggestionError.invalid
        }
        let check: @Sendable () async throws -> Void = {
            try lifetime.check()
            guard let current = await agents.profile(id: profile.id), current.archivedAt == nil,
                  current.providerID == profile.providerID, current.modelID == profile.modelID else {
                throw CancellationError()
            }
        }
        try await check()
        let request = InferenceRequest(conversationID: sessionID, modelID: profile.modelID, messages: [
            .init(role: .system, text: instructions), .init(role: .user, text: payload)
        ])
        let output = MemorySynthesisOutput(limit: stage == .proposal ? 262_144 : 1_024)
        try await coordinator.send(request: request, providerID: profile.providerID,
            agentID: profile.id, agentLane: .background, executionTimeout: timeout, onStart: check) { event in
                try lifetime.check()
                try await output.consume(event)
            }
        try await check()
        return try await output.result()
    }
}

private actor MemorySynthesisOutput {
    private let limit: Int
    private var text = ""
    private var bytes = 0
    private var completed = false
    init(limit: Int) { self.limit = limit }
    func consume(_ event: InferenceEvent) throws {
        if completed {
            if case .usage = event { return }
            throw AgentMemorySuggestionError.invalid
        }
        switch event {
        case .textDelta(let delta):
            let count = delta.utf8.count
            guard count <= limit - bytes else { throw AgentMemorySuggestionError.invalid }
            bytes += count; text += delta
        case .completed(.stop): completed = true
        case .responseStarted, .usage, .reasoningDelta: break
        default: throw AgentMemorySuggestionError.invalid
        }
    }
    func result() throws -> String {
        guard completed else { throw AgentMemorySuggestionError.invalid }
        return text
    }
}
