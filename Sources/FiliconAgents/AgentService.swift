import Foundation
import FiliconDomain

public struct AgentServiceSnapshot: Sendable {
    public let revision: UInt64
    public let agents: [AgentProfile]
    public let subagents: [SubagentRecord]

    public init(revision: UInt64, agents: [AgentProfile], subagents: [SubagentRecord]) {
        self.revision = revision
        self.agents = agents
        self.subagents = subagents
    }
}

public actor AgentService {
    public static let maximumAgents = 50
    private let storeURL: URL
    private var state: AgentPersistentState
    private var persistedState: AgentPersistentState
    private var revision: UInt64 = 0
    private var snapshotListeners: [UUID: AsyncStream<AgentServiceSnapshot>.Continuation] = [:]

    public init(storeURL: URL) throws {
        var loadedState = try Self.loadSynchronously(url: storeURL)
        let now = Date()
        var recoveredInterruptedRun = false
        for index in loadedState.subagents.indices
            where loadedState.subagents[index].status == .running
                || loadedState.subagents[index].status == .queued {
            let record = loadedState.subagents[index]
            loadedState.subagents[index].status = .interrupted
            loadedState.subagents[index].finishedAt = now
            if let wakeIndex = loadedState.wakes.firstIndex(where: { $0.workID == record.id }) {
                loadedState.wakes[wakeIndex].state = .ready
                loadedState.wakes[wakeIndex].status = .interrupted
                loadedState.wakes[wakeIndex].result = "The app restarted before this subagent finished."
                loadedState.wakes[wakeIndex].readyAt = now
            } else {
                loadedState.wakes.append(.init(
                    parentRunID: record.parentRunID,
                    workID: record.id,
                    state: .ready,
                    status: .interrupted,
                    result: "The app restarted before this subagent finished.",
                    createdAt: record.startedAt,
                    readyAt: now
                ))
            }
            recoveredInterruptedRun = true
        }
        if recoveredInterruptedRun {
            try Self.saveSynchronously(loadedState, url: storeURL)
        }
        self.storeURL = storeURL
        self.state = loadedState
        self.persistedState = loadedState
    }

    public func list(includeArchived: Bool = false) -> [AgentProfile] {
        state.agents.filter { includeArchived || $0.archivedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func create(name: String, summary: String = "", instructions: String = "",
                       providerID: ProviderID = "fake", modelID: ModelID = "fake-stream",
                       title: String = "", avatar: AgentAvatar? = nil, at: Date = Date()) async throws -> AgentProfile {
        guard state.agents.count < Self.maximumAgents else { throw AgentServiceError.limitExceeded(Self.maximumAgents) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        let profile = AgentProfile(
            name: String(name.prefix(120)), summary: String(summary.prefix(2_000)),
            instructions: String(instructions.prefix(32_000)), providerID: providerID,
            modelID: modelID, createdAt: at, title: String(title.prefix(160)), avatar: avatar
        )
        state.agents.append(profile); try persist(); return profile
    }

    public func update(_ profile: AgentProfile) async throws {
        guard let index = state.agents.firstIndex(where: { $0.id == profile.id }) else { throw AgentServiceError.unknownAgent(profile.id) }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        var safe = profile
        safe.name = String(name.prefix(120))
        safe.title = String(profile.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        safe.summary = String(profile.summary.prefix(2_000))
        safe.instructions = String(profile.instructions.prefix(32_000))
        safe.unreadCount = max(0, profile.unreadCount)
        safe.updatedAt = Date()
        state.agents[index] = safe; try persist()
    }

    public func archive(id: UUID, at: Date = Date()) async throws {
        guard let index = state.agents.firstIndex(where: { $0.id == id }) else { throw AgentServiceError.unknownAgent(id) }
        state.agents[index].archivedAt = at
        state.agents[index].status = .offline
        state.agents[index].updatedAt = at
        try persist()
    }

    public func restore(id: UUID, at: Date = Date()) async throws {
        guard let index = state.agents.firstIndex(where: { $0.id == id }) else { throw AgentServiceError.unknownAgent(id) }
        state.agents[index].archivedAt = nil
        state.agents[index].status = .idle
        state.agents[index].updatedAt = at
        try persist()
    }

    public func setPresence(id: UUID, status: AgentAvailabilityStatus, at: Date = Date()) async throws {
        guard let index = state.agents.firstIndex(where: { $0.id == id }) else { throw AgentServiceError.unknownAgent(id) }
        state.agents[index].status = state.agents[index].archivedAt == nil ? status : .offline
        state.agents[index].updatedAt = at
        try persist()
    }

    public func setUnreadCount(id: UUID, count: Int, at: Date = Date()) async throws {
        guard let index = state.agents.firstIndex(where: { $0.id == id }) else { throw AgentServiceError.unknownAgent(id) }
        state.agents[index].unreadCount = max(0, count)
        state.agents[index].updatedAt = at
        try persist()
    }

    public func clone(id: UUID, includeHistory: Bool = false) async throws -> AgentProfile {
        guard let source = state.agents.first(where: { $0.id == id }) else { throw AgentServiceError.unknownAgent(id) }
        return try await create(
            name: "\(source.name) copy", summary: source.summary, instructions: source.instructions,
            providerID: source.providerID, modelID: source.modelID, title: source.title, avatar: source.avatar
        )
    }

    public func profile(id: UUID) -> AgentProfile? { state.agents.first { $0.id == id } }

    /// Only the approved public fields are merged. Persist and publish in the
    /// same actor turn so failed writes cannot leave a phantom agent in memory.
    public func applyProfileChange(_ change: AgentProfileChange, lifetime: AgentProfileChangeLifetime,
                                   at: Date = Date()) throws -> AgentProfile {
        try lifetime.commit(change) {
            guard !change.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  change.name.count <= 120, change.description.count <= 2_000 else { throw AgentProfileChangeError.invalidFields }
            guard let requester = state.agents.first(where: { $0.id == change.requesterID }), requester.archivedAt == nil else {
                throw AgentProfileChangeError.unavailable
            }
            let result: AgentProfile
            switch change.operation {
            case .create:
                guard state.agents.count < Self.maximumAgents else { throw AgentServiceError.limitExceeded(Self.maximumAgents) }
                guard !state.agents.contains(where: { $0.id == change.targetID }),
                      requester.providerID == change.providerID, requester.modelID == change.modelID else {
                    throw AgentProfileChangeError.stale
                }
                result = AgentProfile(id: change.targetID, name: change.name, summary: change.description,
                                      instructions: change.description, providerID: change.providerID, modelID: change.modelID,
                                      createdAt: at)
                state.agents.append(result)
            case .update, .setOwnProfile:
                guard (change.operation == .setOwnProfile ? change.requesterID == change.targetID : change.requesterID != change.targetID),
                      let index = state.agents.firstIndex(where: { $0.id == change.targetID }),
                      state.agents[index].archivedAt == nil else { throw AgentProfileChangeError.unavailable }
                guard state.agents[index].name == change.previousName,
                      state.agents[index].summary == change.previousDescription else { throw AgentProfileChangeError.stale }
                guard change.operation == .setOwnProfile || !change.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || change.description == change.previousDescription else {
                    throw AgentProfileChangeError.invalidFields
                }
                state.agents[index].name = change.name
                state.agents[index].summary = change.description
                state.agents[index].updatedAt = at
                result = state.agents[index]
            }
            try persist()
            return result
        }
    }

    public func persistentStateSnapshot() -> Data? { try? JSONEncoder().encode(state) }

    /// Returns an atomically seeded state stream. The first element is the
    /// current persisted state, so consumers cannot miss a mutation between a
    /// separate initial fetch and listener registration.
    public func snapshots() -> AsyncStream<AgentServiceSnapshot> {
        let listenerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            snapshotListeners[listenerID] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotListener(listenerID) }
            }
        }
    }

    public func registerSubagent(_ record: SubagentRecord) async throws {
        guard !state.subagents.contains(where: { $0.id == record.id }) else {
            throw AgentServiceError.invalidSubagent
        }
        state.subagents.append(record)
        state.wakes.append(.init(parentRunID: record.parentRunID, workID: record.id))
        try persist()
    }

    public func updateSubagent(
        id: UUID,
        status: AgentRunStatus,
        result: String? = nil,
        usage: Usage? = nil,
        finishedAt: Date? = nil
    ) async throws {
        guard let index = state.subagents.firstIndex(where: { $0.id == id }) else {
            throw AgentServiceError.invalidSubagent
        }
        state.subagents[index].status = status
        if let result { state.subagents[index].result = result }
        if let usage { state.subagents[index].usage = usage }
        if let finishedAt { state.subagents[index].finishedAt = finishedAt }
        try persist()
    }

    public func settleSubagent(
        id: UUID,
        status: AgentRunStatus,
        result: String,
        usage: Usage,
        at: Date = Date()
    ) async throws {
        guard let index = state.subagents.firstIndex(where: { $0.id == id }) else {
            throw AgentServiceError.invalidSubagent
        }
        state.subagents[index].status = status
        state.subagents[index].result = result
        state.subagents[index].usage = usage
        state.subagents[index].finishedAt = at
        if status == .cancelled {
            state.wakes.removeAll { $0.workID == id }
        } else if let wakeIndex = state.wakes.firstIndex(where: { $0.workID == id }) {
            state.wakes[wakeIndex].state = .ready
            state.wakes[wakeIndex].status = status
            state.wakes[wakeIndex].result = result
            state.wakes[wakeIndex].readyAt = at
        }
        try persist()
    }

    public func subagent(id: UUID) -> SubagentRecord? {
        state.subagents.first { $0.id == id }
    }

    public func subagents(parentRunID: UUID? = nil) -> [SubagentRecord] {
        state.subagents
            .filter { parentRunID == nil || $0.parentRunID == parentRunID }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func pendingWakes(parentRunID: UUID? = nil) -> [PendingAgentWake] {
        state.wakes
            .filter { $0.state == .ready && (parentRunID == nil || $0.parentRunID == parentRunID) }
            .sorted { ($0.readyAt ?? $0.createdAt) < ($1.readyAt ?? $1.createdAt) }
    }

    public func acknowledgeWake(id: UUID) async throws {
        state.wakes.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        do { try Self.saveSynchronously(state, url: storeURL) }
        catch { state = persistedState; throw error }
        persistedState = state
        revision &+= 1
        let value = snapshot()
        for continuation in snapshotListeners.values { continuation.yield(value) }
    }

    private func snapshot() -> AgentServiceSnapshot {
        AgentServiceSnapshot(revision: revision, agents: state.agents, subagents: state.subagents)
    }

    private func removeSnapshotListener(_ id: UUID) {
        snapshotListeners.removeValue(forKey: id)
    }
    private static func loadSynchronously(url: URL) throws -> AgentPersistentState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: url))
    }
    private static func saveSynchronously(_ state: AgentPersistentState, url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
