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
                       title: String = "", avatar: AgentAvatar? = nil, notifyOnAgentUpdates: Bool = true, at: Date = Date()) async throws -> AgentProfile {
        guard state.agents.count < Self.maximumAgents else { throw AgentServiceError.limitExceeded(Self.maximumAgents) }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        let profile = AgentProfile(
            name: String(name.prefix(120)), summary: String(summary.prefix(2_000)),
            instructions: String(instructions.prefix(32_000)), providerID: providerID,
            modelID: modelID, createdAt: at, title: String(title.prefix(160)), avatar: avatar,
            notifyOnAgentUpdates: notifyOnAgentUpdates
        )
        state.agents.append(profile); try persist(); return profile
    }

    public func update(_ profile: AgentProfile) async throws {
        guard let index = state.agents.firstIndex(where: { $0.id == profile.id }) else { throw AgentServiceError.unknownAgent(profile.id) }
        // An editor opened before an approved change must not silently undo it,
        // including when the preference was toggled away and back (ABA).
        guard profile.notificationSettingsRevision == state.agents[index].notificationSettingsRevision else {
            throw AgentSettingsChangeError.stale
        }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        var safe = profile
        if safe.notifyOnAgentUpdates != state.agents[index].notifyOnAgentUpdates {
            safe.notificationSettingsRevision = UUID()
        }
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

    /// Public project metadata in one account; does not expose private facts.
    public func projects(accountID: String) -> [AgentProject] {
        state.projects.filter { $0.accountID == accountID }.sorted { $0.slug < $1.slug }
    }

    public func proposeProjectChange(accountID: String, agentID: UUID, action: AgentProjectAction,
                                     slug: String, name: String? = nil, summary: String? = nil,
                                     at: Date = Date()) throws -> AgentProjectChange {
        guard !accountID.isEmpty, accountID.utf8.count <= 256,
              AgentProject.isValidSlug(slug),
              action == .create || (name == nil && summary == nil) else { throw AgentProjectError.invalid }
        func text(_ value: String, limit: Int, allowEmpty: Bool) -> Bool {
            (allowEmpty || !value.isEmpty) && value.utf8.count <= limit
                && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && value.rangeOfCharacter(from: .controlCharacters) == nil
        }
        if action == .create {
            guard let name, text(name, limit: 200, allowEmpty: false),
                  text(summary ?? "", limit: 1_000, allowEmpty: true) else { throw AgentProjectError.invalid }
        }
        guard state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else {
            throw AgentProjectError.unavailable
        }
        let previous = state.projects.first { $0.accountID == accountID && $0.slug == slug }
        if previous == nil && action != .create { throw AgentProjectError.unavailable }
        if previous == nil && projects(accountID: accountID).count >= 50 { throw AgentProjectError.limit }
        var proposed = previous ?? AgentProject(accountID: accountID, slug: slug, name: name ?? "", summary: summary ?? "",
            createdAt: at, memberIDs: [], revision: UUID())
        let joining = action != .leave
        guard proposed.memberIDs.contains(agentID) != joining else { throw AgentProjectError.unchanged }
        if joining { proposed.memberIDs.insert(agentID) } else { proposed.memberIDs.remove(agentID) }
        proposed.revision = UUID()
        return .init(action: action, agentID: agentID, previous: previous, proposed: proposed)
    }

    public func applyProjectChange(_ change: AgentProjectChange, lifetime: AgentProjectChangeLifetime) throws {
        try lifetime.check()
        try lifetime.commit(change) {
            let project = change.proposed
            guard state.agents.contains(where: { $0.id == change.agentID && $0.archivedAt == nil }) else {
                throw AgentProjectError.unavailable
            }
            let index = state.projects.firstIndex { $0.accountID == project.accountID && $0.slug == project.slug }
            guard index.map({ state.projects[$0] }) == change.previous else { throw AgentProjectError.stale }
            if let index { state.projects[index] = project }
            else {
                guard projects(accountID: project.accountID).count < 50 else { throw AgentProjectError.limit }
                state.projects.append(project)
            }
            // Metadata and membership commit atomically; persist rolls back all
            // in-memory state on failure. Leaving preserves the project itself.
            try persist()
        }
    }

    /// Only the specified writer's records; models cannot forget another writer's shard.
    public func memorySuggestions(accountID: String, agentID: UUID) throws -> AgentMemorySuggestionSnapshot {
        guard !accountID.isEmpty, accountID.count <= 512,
              state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else { throw AgentMemoryError.unavailable }
        return .init(settings: state.memorySuggestionSettings.first { $0.accountID == accountID && $0.agentID == agentID }
            ?? .init(accountID: accountID, agentID: agentID),
            suggestions: state.memorySuggestions.filter { $0.accountID == accountID && $0.agentID == agentID })
    }

    public func setMemorySuggestionsEnabled(_ enabled: Bool, expected: AgentMemorySuggestionSettings,
                                           lifetime: AgentMemorySuggestionLifetime) throws {
        try lifetime.commit {
            guard try memorySuggestions(accountID: expected.accountID, agentID: expected.agentID).settings == expected else {
                throw AgentMemorySuggestionError.stale
            }
            var next = expected; next.enabled = enabled; next.revision = UUID()
            state.memorySuggestionSettings.removeAll { $0.accountID == expected.accountID && $0.agentID == expected.agentID }
            state.memorySuggestionSettings.append(next)
            // Disabling clears unapproved candidates. Approved facts remain and
            // are still managed with Forget. Keep receipts to avoid re-extraction.
            if !enabled { state.memorySuggestions.removeAll { $0.accountID == expected.accountID && $0.agentID == expected.agentID } }
            try persist()
        }
    }

    public func shouldSuggestMemory(settings: AgentMemorySuggestionSettings, exchangeID: UUID) throws -> Bool {
        let current = try memorySuggestions(accountID: settings.accountID, agentID: settings.agentID)
        return settings.enabled && current.settings == settings && current.suggestions.count < 12
            && !state.memorySuggestionReceipts.contains { $0.accountID == settings.accountID && $0.agentID == settings.agentID && $0.exchangeID == exchangeID }
    }

    public func memorySynthesisSettings(accountID: String, agentID: UUID) throws -> AgentMemorySynthesisSettings {
        guard !accountID.isEmpty, accountID.count <= 512,
              state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else {
            throw AgentMemoryError.unavailable
        }
        return state.memorySynthesisSettings.first { $0.accountID == accountID && $0.agentID == agentID }
            ?? .init(accountID: accountID, agentID: agentID)
    }

    public func setMemorySynthesisEnabled(_ enabled: Bool, expected: AgentMemorySynthesisSettings,
                                          lifetime: AgentMemorySuggestionLifetime) throws {
        try lifetime.commit {
            guard try memorySynthesisSettings(accountID: expected.accountID, agentID: expected.agentID) == expected else {
                throw AgentMemorySuggestionError.stale
            }
            var next = expected; next.enabled = enabled; next.revision = UUID()
            state.memorySynthesisSettings.removeAll { $0.accountID == expected.accountID && $0.agentID == expected.agentID }
            state.memorySynthesisSettings.append(next)
            state.memoryTemporalReviews.removeAll { $0.settings.accountID == expected.accountID && $0.settings.agentID == expected.agentID }
            // Disabling revokes in-flight snapshots but never deletes memories.
            try persist()
        }
    }

    public func dueMemoryTemporalReviews(accountID: String, at: Date,
                                        excluding: [AgentMemorySynthesisSettings] = []) throws -> [AgentMemorySynthesisSettings] {
        guard at.timeIntervalSince1970.isFinite, !accountID.isEmpty, accountID.count <= 512 else {
            throw AgentMemorySuggestionError.invalid
        }
        var result: [AgentMemorySynthesisSettings] = []
        for agent in list() {
            let settings = try memorySynthesisSettings(accountID: accountID, agentID: agent.id)
            guard settings.enabled, settings.revision != nil, !excluding.contains(settings),
                  !memories(accountID: accountID, agentID: agent.id).isEmpty else { continue }
            let receipt = state.memoryTemporalReviews.first { $0.settings == settings }
            if let next = receipt?.nextReviewAt, next.timeIntervalSince1970.isFinite, next > at { continue }
            result.append(settings)
            if result.count == 4 { break }
        }
        return result
    }

    public func markMemoryTemporalReview(settings: AgentMemorySynthesisSettings, at: Date,
                                         lifetime: AgentMemorySuggestionLifetime) throws {
        try lifetime.commit {
            try requireMemorySynthesisConsent(settings)
            let next = at.addingTimeInterval(86_400)
            guard at.timeIntervalSince1970.isFinite, next.timeIntervalSince1970.isFinite else {
                throw AgentMemorySuggestionError.invalid
            }
            let previous = state.memoryTemporalReviews.first { $0.settings == settings }?.nextReviewAt
            let deadline = previous.map { max($0, next) } ?? next
            state.memoryTemporalReviews.removeAll { $0.settings.accountID == settings.accountID && $0.settings.agentID == settings.agentID }
            state.memoryTemporalReviews.append(.init(settings: settings, nextReviewAt: deadline))
            try persist()
        }
    }

    func requireMemorySynthesisConsent(_ settings: AgentMemorySynthesisSettings) throws {
        guard settings.enabled, settings.revision != nil,
              try memorySynthesisSettings(accountID: settings.accountID, agentID: settings.agentID) == settings else {
            throw AgentMemorySuggestionError.stale
        }
    }

    public func recordMemorySuggestions(_ suggestions: [AgentMemorySuggestion], settings: AgentMemorySuggestionSettings,
                                        exchangeID: UUID, lifetime: AgentMemorySuggestionLifetime) throws {
        try lifetime.commit {
            guard try shouldSuggestMemory(settings: settings, exchangeID: exchangeID) else { throw AgentMemorySuggestionError.stale }
            guard suggestions.count <= 4, Set(suggestions.map(\.id)).count == suggestions.count,
                  suggestions.allSatisfy({ candidate in
                    candidate.accountID == settings.accountID && candidate.agentID == settings.agentID && candidate.exchangeID == exchangeID
                        && candidate.isValid && !state.memorySuggestions.contains(where: { $0.id == candidate.id })
                  }) else {
                throw AgentMemorySuggestionError.invalid
            }
            let pending = state.memorySuggestions.filter { $0.accountID == settings.accountID && $0.agentID == settings.agentID }
            var known = Set((memories(accountID: settings.accountID, agentID: settings.agentID).map(\.fact) + pending.map(\.fact)).map(AgentMemorySuggestionParser.key))
            let additions = suggestions.filter { known.insert(AgentMemorySuggestionParser.key($0.fact)).inserted }
            state.memorySuggestions.append(contentsOf: additions.prefix(12 - pending.count))
            var receipts = state.memorySuggestionReceipts.filter { $0.accountID == settings.accountID && $0.agentID == settings.agentID }
            receipts.append(.init(accountID: settings.accountID, agentID: settings.agentID, exchangeID: exchangeID))
            state.memorySuggestionReceipts.removeAll { $0.accountID == settings.accountID && $0.agentID == settings.agentID }
            state.memorySuggestionReceipts.append(contentsOf: receipts.suffix(32))
            try persist()
        }
    }

    /// Human-only review. Atomic removal+write: failed approval cannot lose the
    /// suggestion, and a repeated/stale action cannot recreate a forgotten fact.
    public func reviewMemorySuggestion(_ suggestion: AgentMemorySuggestion, accept: Bool,
                                       lifetime: AgentMemorySuggestionLifetime) throws {
        try lifetime.commit {
            let current = try memorySuggestions(accountID: suggestion.accountID, agentID: suggestion.agentID)
            guard current.settings.enabled, current.suggestions.contains(suggestion) else { throw AgentMemorySuggestionError.stale }
            guard suggestion.isValid else { throw AgentMemorySuggestionError.invalid }
            if accept {
                let saved = memories(accountID: suggestion.accountID, agentID: suggestion.agentID)
                let duplicate = saved.first { AgentMemorySuggestionParser.key($0.fact) == AgentMemorySuggestionParser.key(suggestion.fact) }
                if let duplicate {
                    // Human approval promotes an existing synthesized fact too.
                    if let index = state.memories.firstIndex(where: { $0.id == duplicate.id }) {
                        state.memories[index] = .init(id: duplicate.id, accountID: duplicate.accountID,
                            agentID: duplicate.agentID, fact: duplicate.fact, tier: duplicate.tier,
                            scope: duplicate.scope, project: duplicate.project, createdAt: duplicate.createdAt)
                        state.memoryTombstones.remove(.init(duplicate))
                    }
                } else {
                    guard saved.count < 48, saved.reduce(0, { $0 + $1.fact.count }) + suggestion.fact.count <= 12_000,
                          suggestion.tier != .profile || saved.filter({ $0.tier == .profile }).count < 8 else { throw AgentMemoryError.limit }
                    let memory = AgentMemory(accountID: suggestion.accountID, agentID: suggestion.agentID,
                        fact: suggestion.fact, tier: suggestion.tier)
                    state.memories.append(memory)
                    state.memoryTombstones.remove(.init(memory))
                }
            }
            state.memorySuggestions.removeAll { $0.id == suggestion.id && $0.accountID == suggestion.accountID && $0.agentID == suggestion.agentID }
            try persist()
        }
    }

    public func memories(accountID: String, agentID: UUID, scope: AgentMemory.Scope = .agent, project: String? = nil) -> [AgentMemory] {
        sortedMemories(state.memories.filter { $0.accountID == accountID && $0.agentID == agentID && $0.scope == scope && $0.project == project })
    }

    func memorySynthesisSnapshot(accountID: String, agentID: UUID) throws -> AgentMemorySynthesisSnapshot {
        guard !accountID.isEmpty, accountID.count <= 512,
              state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else {
            throw AgentMemoryError.unavailable
        }
        return .init(accountID: accountID, agentID: agentID,
            memories: memories(accountID: accountID, agentID: agentID),
            tombstones: Set(state.memoryTombstones.filter {
                $0.accountID == accountID && $0.agentID == agentID && $0.scope == .agent && $0.project == nil
            }))
    }

    /// Storage half of synthesis only: a host coordinator must independently
    /// verify the proposal against its evidence before invoking this method.
    /// No model tool or current App flow exposes this internal entry point.
    func applyVerifiedMemorySynthesis(_ text: String, expected: AgentMemorySynthesisSnapshot,
                                      evidenceIDs: Set<String>, clockEvidenceID: String? = nil,
                                      at: Date, makeID: () -> UUID = UUID.init,
                                      lifetime: AgentMemorySuggestionLifetime) throws {
        try lifetime.commit {
            guard at.timeIntervalSince1970.isFinite else { throw AgentMemorySuggestionError.invalid }
            guard try memorySynthesisSnapshot(accountID: expected.accountID, agentID: expected.agentID) == expected else {
                throw AgentMemorySynthesisSnapshotChanged()
            }
            let proposal = try AgentMemorySynthesisProposal.parse(text, evidenceIDs: evidenceIDs,
                mutableMemoryIDs: expected.mutableMemoryIDs, clockEvidenceID: clockEvidenceID)
            var next = expected.memories
            for change in proposal.changes {
                if let id = change.id { next.removeAll { $0.id == id } }
                guard change.action != .remove, let content = change.content, let tier = change.tier else { continue }
                let memory = AgentMemory(synthesizedID: change.id ?? makeID(), accountID: expected.accountID,
                    agentID: expected.agentID, fact: content, tier: tier, createdAt: at)
                if expected.tombstones.contains(.init(memory)) { continue }
                if next.contains(where: { AgentMemorySuggestionParser.key($0.fact) == AgentMemorySuggestionParser.key(content) }) { continue }
                guard !next.contains(where: { $0.id == memory.id }),
                      !state.memories.contains(where: { $0.id == memory.id && $0.id != change.id }) else {
                    throw AgentMemorySuggestionError.invalid
                }
                next.append(memory)
            }
            guard next.count <= 48, next.filter({ $0.tier == .profile }).count <= 8,
                  next.reduce(0, { $0 + $1.fact.count }) <= 12_000 else { throw AgentMemoryError.limit }
            guard next != expected.memories else { return }
            // No intermediate mutation, suspension, or partial write.
            state.memories.removeAll { $0.accountID == expected.accountID && $0.agentID == expected.agentID && $0.scope == .agent }
            state.memories.append(contentsOf: next)
            try persist()
        }
    }

    public func sharedUserMemories(accountID: String) -> [AgentMemory] {
        sortedMemories(state.memories.filter { $0.accountID == accountID && $0.scope == .user })
    }

    /// User-facing account library, not a model read API. Includes departed writers.
    public func projectMemoriesForEditor(accountID: String) -> [AgentMemory] {
        sortedMemories(state.memories.filter { $0.accountID == accountID && $0.scope == .project })
    }

    public func memoryAccess(accountID: String, agentID: UUID) throws -> AgentMemoryAccess {
        guard state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else { throw AgentMemoryError.unavailable }
        let joined = projects(accountID: accountID).filter { $0.memberIDs.contains(agentID) }
        return .init(memories: memoryContext(accountID: accountID, agentID: agentID), projects: joined)
    }

    public func proposeProjectMemoryChange(accountID: String, agentID: UUID, slug: String, operation: AgentMemoryChange.Operation,
                                           fact: String, tier: AgentMemory.Tier = .log, id: UUID = UUID(), at: Date = Date()) throws -> AgentMemoryChange {
        guard AgentProject.isValidSlug(slug), let project = projects(accountID: accountID).first(where: { $0.slug == slug }),
              project.memberIDs.contains(agentID), state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else {
            throw AgentMemoryError.projectUnavailable
        }
        let memory: AgentMemory
        if operation == .write {
            memory = .init(id: id, accountID: accountID, agentID: agentID, fact: fact, tier: tier, scope: .project, project: slug, createdAt: at)
        } else {
            guard let existing = memories(accountID: accountID, agentID: agentID, scope: .project, project: slug).first(where: { $0.fact == fact }) else {
                throw AgentMemoryError.stale
            }
            memory = existing
        }
        guard !fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fact.count <= 1_000 else { throw AgentMemoryError.invalid }
        return .init(operation: operation, memory: memory, project: project)
    }

    /// One actor snapshot: own private facts plus explicitly shared facts in this account.
    public func memoryContext(accountID: String, agentID: UUID) -> [AgentMemory] {
        let active = state.agents.contains { $0.id == agentID && $0.archivedAt == nil }
        let joined = Set(projects(accountID: accountID).filter { active && $0.memberIDs.contains(agentID) }.map(\.slug))
        return sortedMemories(state.memories.filter { $0.isVisible(accountID: accountID, agentID: agentID, joinedProjects: joined) })
    }

    /// Owner validation and the visible store are one actor snapshot.
    public func searchableMemories(accountID: String, agentID: UUID) throws -> [AgentMemory] {
        guard state.agents.contains(where: { $0.id == agentID && $0.archivedAt == nil }) else {
            throw AgentMemoryError.unavailable
        }
        return memoryContext(accountID: accountID, agentID: agentID)
    }

    private func sortedMemories(_ memories: [AgentMemory]) -> [AgentMemory] {
        memories.sorted {
            if ($0.tier == .profile) != ($1.tier == .profile) { return $0.tier == .profile }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func applyMemoryChange(_ change: AgentMemoryChange, lifetime: AgentMemoryChangeLifetime) throws {
        try applyMemoryChange(change, lifetime: lifetime, fromEditor: false)
    }

    /// Explicit human editor deletion can remove departed/archived writers' facts.
    /// This path is not exposed as a model tool and cannot write new facts.
    public func forgetMemoryFromEditor(_ memory: AgentMemory, lifetime: AgentMemoryChangeLifetime) throws {
        try applyMemoryChange(.init(operation: .forget, memory: memory), lifetime: lifetime, fromEditor: true)
    }

    private func applyMemoryChange(_ change: AgentMemoryChange, lifetime: AgentMemoryChangeLifetime, fromEditor: Bool) throws {
        try lifetime.commit(change) {
            let memory = change.memory
            guard !memory.accountID.isEmpty, memory.accountID.count <= 512,
                  !memory.fact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  memory.fact.count <= 1_000 else { throw AgentMemoryError.invalid }
            guard let owner = state.agents.first(where: { $0.id == memory.agentID }),
                  change.operation == .forget || owner.archivedAt == nil else {
                throw AgentMemoryError.unavailable
            }
            if memory.scope == .project {
                guard let slug = memory.project, AgentProject.isValidSlug(slug) else { throw AgentMemoryError.projectUnavailable }
                if !fromEditor {
                    guard owner.archivedAt == nil, let project = change.project,
                          project.accountID == memory.accountID, project.slug == slug, project.memberIDs.contains(memory.agentID),
                          state.projects.first(where: { $0.accountID == memory.accountID && $0.slug == slug }) == project else {
                        throw AgentMemoryError.stale
                    }
                }
            } else if memory.project != nil || change.project != nil { throw AgentMemoryError.invalid }
            switch change.operation {
            case .write:
                guard memory.origin == .explicit else { throw AgentMemoryError.invalid }
                let current: [AgentMemory]
                switch memory.scope {
                case .user: current = sharedUserMemories(accountID: memory.accountID)
                case .agent: current = memories(accountID: memory.accountID, agentID: memory.agentID)
                case .project: current = state.memories.filter { $0.accountID == memory.accountID && $0.scope == .project && $0.project == memory.project }
                }
                guard !current.contains(where: { $0.fact == memory.fact }), !state.memories.contains(where: { $0.id == memory.id }) else {
                    throw memory.scope == .project ? AgentMemoryError.projectDuplicate : memory.scope == .user ? AgentMemoryError.sharedDuplicate : AgentMemoryError.duplicate
                }
                guard current.count < 48, current.reduce(0, { $0 + $1.fact.count }) + memory.fact.count <= 12_000,
                      memory.tier != .profile || current.filter({ $0.tier == .profile }).count < 8 else {
                    throw memory.scope == .project ? AgentMemoryError.projectLimit : memory.scope == .user ? AgentMemoryError.sharedLimit : AgentMemoryError.limit
                }
                state.memories.append(memory)
                state.memoryTombstones.remove(.init(memory))
            case .forget:
                // Record identity and content fence deletion; Date's sub-millisecond
                // floating-point round trip is not an edit or a new record.
                guard let index = state.memories.firstIndex(where: {
                    $0.id == memory.id && $0.accountID == memory.accountID && $0.agentID == memory.agentID
                        && $0.fact == memory.fact && $0.tier == memory.tier && $0.scope == memory.scope && $0.project == memory.project
                        && $0.origin == memory.origin
                }) else { throw AgentMemoryError.stale }
                state.memoryTombstones.insert(.init(state.memories[index]))
                state.memories.remove(at: index)
            }
            try persist()
        }
    }

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

    public func applyAvatarChange(_ change: AgentAvatarChange, lifetime: AgentAvatarChangeLifetime,
                                  at: Date = Date()) throws -> AgentProfile {
        try lifetime.commit(change) {
            guard change.isValid else { throw AgentAvatarChangeError.invalid }
            guard let index = state.agents.firstIndex(where: { $0.id == change.agentID }),
                  state.agents[index].archivedAt == nil else { throw AgentProfileChangeError.unavailable }
            guard state.agents[index].avatar == change.previousAvatar else { throw AgentProfileChangeError.stale }
            // Merge only the reviewed avatar; keep current persona/model/profile fields.
            state.agents[index].avatar = change.avatar
            state.agents[index].updatedAt = at
            let result = state.agents[index]
            try persist()
            return result
        }
    }

    public func applySettingsChange(_ change: AgentSettingsChange, lifetime: AgentSettingsChangeLifetime,
                                    at: Date = Date()) throws -> AgentProfile {
        try lifetime.commit(change) {
            guard let index = state.agents.firstIndex(where: { $0.id == change.agentID }),
                  state.agents[index].archivedAt == nil else { throw AgentProfileChangeError.unavailable }
            guard state.agents[index].notifyOnAgentUpdates == change.previousValue,
                  state.agents[index].notificationSettingsRevision == change.previousRevision else {
                throw AgentSettingsChangeError.stale
            }
            if change.notifyOnUpdates != change.previousValue {
                state.agents[index].notifyOnAgentUpdates = change.notifyOnUpdates
                state.agents[index].notificationSettingsRevision = UUID()
                state.agents[index].updatedAt = at
                try persist()
            }
            return state.agents[index]
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
