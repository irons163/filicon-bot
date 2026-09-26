import Foundation

/// Host-owned pending evidence only. Taking a batch does not authorize inference:
/// the consumer must revalidate consent, profile and its cancellation lifetime.
/// No persistence or timers; the owning actor drives the monotonic debounce.
public struct AgentMemorySynthesisQueue: Sendable {
    public struct Entry: Equatable, Sendable {
        public let originID: UUID
        public let evidence: AgentMemorySynthesisEvidence
        public init(originID: UUID, evidence: AgentMemorySynthesisEvidence) {
            self.originID = originID; self.evidence = evidence
        }
    }
    public struct Batch: Equatable, Sendable {
        public let settings: AgentMemorySynthesisSettings
        public fileprivate(set) var entries: [Entry]
        public fileprivate(set) var temporalReview = false
    }
    public struct Admission: Equatable, Sendable {
        public let inserted: Bool
        public let droppedAgents: Int
        public let droppedEvidence: Int
        public init(inserted: Bool, droppedAgents: Int, droppedEvidence: Int) {
            self.inserted = inserted; self.droppedAgents = droppedAgents; self.droppedEvidence = droppedEvidence
        }
    }
    private struct Key: Hashable, Sendable { let accountID: String; let agentID: UUID }
    private var order: [Key] = []
    private var pending: [Key: Batch] = [:]
    public private(set) var nextRun: ContinuousClock.Instant?
    public var count: Int { pending.count }
    public init() {}

    /// A date-only review is not fabricated conversational evidence.
    @discardableResult
    public mutating func enqueueTemporal(settings: AgentMemorySynthesisSettings,
                                         now: ContinuousClock.Instant) throws -> Admission {
        guard settings.enabled, settings.revision != nil,
              !settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.accountID.utf8.count <= 256 else { throw AgentMemorySuggestionError.invalid }
        let key = Key(accountID: settings.accountID, agentID: settings.agentID)
        if pending[key]?.settings == settings, pending[key]?.temporalReview == true {
            return .init(inserted: false, droppedAgents: 0, droppedEvidence: 0)
        }
        var dropped = 0, agents = 0
        if let previous = pending[key], previous.settings != settings {
            dropped = previous.entries.count
            removeAgent(accountID: settings.accountID, agentID: settings.agentID)
        }
        if pending[key] == nil {
            if order.count == 64 {
                let oldest = order.removeFirst()
                dropped += pending.removeValue(forKey: oldest)?.entries.count ?? 0
                agents = 1
            }
            order.append(key)
            pending[key] = .init(settings: settings, entries: [])
        }
        pending[key]?.temporalReview = true
        nextRun = now.advanced(by: .seconds(15))
        return .init(inserted: true, droppedAgents: agents, droppedEvidence: dropped)
    }

    /// Used by the host to release per-evidence cancellation context after eviction.
    public func contains(settings: AgentMemorySynthesisSettings, evidenceID: String) -> Bool {
        guard let batch = pending[Key(accountID: settings.accountID, agentID: settings.agentID)],
              batch.settings == settings else { return false }
        return batch.entries.contains { $0.evidence.id == evidenceID }
    }

    @discardableResult
    public mutating func enqueue(settings: AgentMemorySynthesisSettings, entry: Entry,
                                 now: ContinuousClock.Instant) throws -> Admission {
        let evidence = entry.evidence
        guard settings.enabled, settings.revision != nil,
              !settings.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              settings.accountID.utf8.count <= 256,
              evidence.occurredAt.timeIntervalSince1970.isFinite,
              !evidence.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !evidence.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !["PASS", "(PASS)"].contains(evidence.assistant.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()),
              evidence.user.count <= 8_000, evidence.assistant.count <= 8_000,
              evidence.user.utf8.count <= 32_000, evidence.assistant.utf8.count <= 32_000 else {
            throw AgentMemorySuggestionError.invalid
        }
        do {
            _ = try AgentMemorySynthesisProposal.parse(#"{"changes":[]}"#, evidenceIDs: [evidence.id], mutableMemoryIDs: [])
        } catch {
            throw AgentMemorySuggestionError.invalid
        }
        let key = Key(accountID: settings.accountID, agentID: settings.agentID)
        if let current = pending[key], current.settings == settings,
           let duplicate = current.entries.first(where: { $0.evidence.id == evidence.id }) {
            guard duplicate == entry else { throw AgentMemorySuggestionError.invalid }
            return .init(inserted: false, droppedAgents: 0, droppedEvidence: 0)
        }
        var droppedAgents = 0, droppedEvidence = 0
        // Never mix evidence captured under different consent revisions.
        if let current = pending[key], current.settings != settings {
            droppedEvidence += current.entries.count
            pending[key] = nil; order.removeAll { $0 == key }
        }
        if pending[key] == nil {
            if order.count == 64 {
                let oldest = order.removeFirst()
                droppedEvidence += pending.removeValue(forKey: oldest)?.entries.count ?? 0
                droppedAgents = 1
            }
            order.append(key)
            pending[key] = .init(settings: settings, entries: [])
        }
        if pending[key]?.entries.count == 12 {
            pending[key]?.entries.removeFirst()
            droppedEvidence += 1
        }
        pending[key]?.entries.append(entry)
        nextRun = now.advanced(by: .seconds(15))
        return .init(inserted: true, droppedAgents: droppedAgents, droppedEvidence: droppedEvidence)
    }

    /// Restore older evidence ahead of evidence that arrived during execution.
    /// Capacity shedding keeps the newest evidence; never replace newer consent.
    public mutating func requeue(_ batch: Batch, now: ContinuousClock.Instant) throws {
        let key = Key(accountID: batch.settings.accountID, agentID: batch.settings.agentID)
        if let current = pending[key], current.settings != batch.settings { return }
        var merged = batch.entries
        for entry in pending[key]?.entries ?? [] {
            if let duplicate = merged.first(where: { $0.evidence.id == entry.evidence.id }) {
                guard duplicate == entry else { throw AgentMemorySuggestionError.invalid }
            } else { merged.append(entry) }
        }
        // Stage the whole operation so an invalid entry cannot partially restore.
        var candidate = self
        let temporal = batch.temporalReview || pending[key]?.temporalReview == true
        candidate.removeAgent(accountID: batch.settings.accountID, agentID: batch.settings.agentID)
        for entry in merged.suffix(12) {
            try candidate.enqueue(settings: batch.settings, entry: entry, now: now)
        }
        if temporal { try candidate.enqueueTemporal(settings: batch.settings, now: now) }
        self = candidate
    }

    /// Atomically detach ready batches. Evidence enqueued while a detached batch
    /// is running belongs to a later batch and cannot be erased by its completion.
    public mutating func takeReady(now: ContinuousClock.Instant) -> [Batch] {
        guard let nextRun, now >= nextRun else { return [] }
        let result = order.compactMap { pending[$0] }
        removeAll()
        return result
    }

    public mutating func removeAgent(accountID: String, agentID: UUID) {
        let key = Key(accountID: accountID, agentID: agentID)
        pending[key] = nil; order.removeAll { $0 == key }
        if pending.isEmpty { nextRun = nil }
    }

    public mutating func removeOrigin(_ originID: UUID) {
        for key in order {
            pending[key]?.entries.removeAll { $0.originID == originID }
            if pending[key]?.entries.isEmpty == true, pending[key]?.temporalReview != true { pending[key] = nil }
        }
        order.removeAll { pending[$0] == nil }
        if pending.isEmpty { nextRun = nil }
    }

    public mutating func removeEvidence(settings: AgentMemorySynthesisSettings, evidenceID: String) {
        let key = Key(accountID: settings.accountID, agentID: settings.agentID)
        guard pending[key]?.settings == settings else { return }
        pending[key]?.entries.removeAll { $0.evidence.id == evidenceID }
        if pending[key]?.entries.isEmpty == true, pending[key]?.temporalReview != true {
            pending[key] = nil; order.removeAll { $0 == key }
        }
        if pending.isEmpty { nextRun = nil }
    }

    public mutating func removeAll() {
        order.removeAll(); pending.removeAll(); nextRun = nil
    }

    public func containsTemporal(settings: AgentMemorySynthesisSettings) -> Bool {
        let batch = pending[Key(accountID: settings.accountID, agentID: settings.agentID)]
        return batch?.settings == settings && batch?.temporalReview == true
    }

    public mutating func removeTemporal(settings: AgentMemorySynthesisSettings) {
        let key = Key(accountID: settings.accountID, agentID: settings.agentID)
        guard pending[key]?.settings == settings else { return }
        pending[key]?.temporalReview = false
        if pending[key]?.entries.isEmpty == true {
            pending[key] = nil; order.removeAll { $0 == key }
        }
        if pending.isEmpty { nextRun = nil }
    }
}
