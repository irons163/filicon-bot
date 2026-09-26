import Foundation
import FiliconDomain
import FiliconPersistence

public struct ConversationMetadataBatch: Sendable {
    public let items: [Conversation]
    public let continuation: ConversationMetadataContinuation?
}

public struct ConversationMetadataContinuation: Sendable {
    fileprivate let fence: PaginationFence
    fileprivate let cursor: ConversationCursor
}

public struct MessageHistoryBatch: Sendable {
    public let items: [ChatMessage]
    public let continuation: MessageHistoryContinuation?
}

public struct MessageHistoryContinuation: Sendable {
    fileprivate let fence: PaginationFence
    fileprivate let cursor: MessageCursor
}

public actor ConversationStore {
    private let legacyURL: URL
    private let databaseURL: URL
    private let backupURL: URL
    private let markerURL: URL
    private let transcriptService: ConversationTranscriptService
    private var repository: ConversationRepository?
    private var importChecked = false

    public init(fileURL: URL) {
        legacyURL = fileURL
        let directory = fileURL.deletingLastPathComponent()
        databaseURL = directory.appending(path: "conversations.sqlite3")
        backupURL = directory.appending(path: "conversations.json.migrated-backup")
        markerURL = directory.appending(path: ".sqlite-migration-complete")
        transcriptService = ConversationTranscriptService(dataRootURL: directory)
    }

    public static func defaultURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return root.appending(path: "Filicon", directoryHint: .isDirectory).appending(path: "conversations.json")
    }

    public func load() async throws -> [Conversation] {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        let values = try await repository.load()
        try await transcriptService.reconcileAll(values)
        return values
    }

    /// Loads metadata only. A continuation preserves the repository keyset
    /// fence, so callers never have to manufacture or decode persistence cursors.
    public func conversationPage(
        after continuation: ConversationMetadataContinuation? = nil,
        limit: Int = 50
    ) async throws -> ConversationMetadataBatch {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        let fence = continuation?.fence ?? PaginationFence()
        let page = try await repository.conversationPage(.init(
            fence: fence,
            after: continuation?.cursor,
            limit: limit
        ))
        for item in page.items {
            if let canonical = try await repository.conversation(id: item.id) {
                try await transcriptService.reconcile(canonical)
            }
        }
        return ConversationMetadataBatch(
            items: page.items,
            continuation: page.nextCursor.map { .init(fence: page.fence, cursor: $0) }
        )
    }

    /// Durable, metadata-only lookup; never infer ownership from a chat title.
    public func uniqueBoundConversation(accountID: String, agentID: UUID) async throws -> Conversation? {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        return try await repository.uniqueBoundConversation(accountID: accountID, agentID: agentID)
    }

    /// Loads one backwards keyset page, returned in chronological order.
    public func messagePage(
        conversationID: UUID,
        before continuation: MessageHistoryContinuation? = nil,
        limit: Int = 100
    ) async throws -> MessageHistoryBatch {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        let fence = continuation?.fence ?? PaginationFence()
        let page = try await repository.messagePage(conversationID: conversationID, request: .init(
            fence: fence,
            before: continuation?.cursor,
            limit: limit
        ))
        if let canonical = try await repository.conversation(id: conversationID) {
            try await transcriptService.reconcile(canonical)
        }
        return MessageHistoryBatch(
            items: page.items,
            continuation: page.nextCursor.map { .init(fence: page.fence, cursor: $0) }
        )
    }

    public func conversation(id: UUID) async throws -> Conversation? {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        let value = try await repository.conversation(id: id)
        if let value { try await transcriptService.reconcile(value) }
        return value
    }

    /// Persists a possibly paged in-memory conversation without dropping rows
    /// that have not been loaded. `replacingLoadedMessageIDs` is also how a
    /// deletion from the loaded window is distinguished from an unseen row.
    public func upsert(
        _ conversation: Conversation,
        replacingLoadedMessageIDs: Set<UUID>,
        historyComplete: Bool
    ) async throws {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        guard !historyComplete, let canonical = try await repository.conversation(id: conversation.id) else {
            try await repository.upsert(conversation)
            try await transcriptService.reconcile(conversation)
            return
        }
        var merged = conversation
        // A paged view must not discard reservations belonging to unseen or
        // deleted messages; canonical identity wins over stale metadata.
        merged.messageAddressReservations.merge(canonical.messageAddressReservations) { _, saved in saved }
        let unseen = canonical.messages.filter { !replacingLoadedMessageIDs.contains($0.id) }
        merged.messages = Self.mergeChronologically(older: unseen, newer: conversation.messages)
        try await repository.upsert(merged)
        try await transcriptService.reconcile(merged)
    }

    public func delete(id: UUID) async throws {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        try await repository.delete(id: id)
        try await transcriptService.delete(conversationID: id)
    }

    public func save(_ conversations: [Conversation]) async throws {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        try await repository.save(conversations)
        try await transcriptService.reconcileAll(conversations)
    }

    public func search(_ query: String, limit: Int = 50, includeHidden: Bool = true,
                       visibility: [ConversationVisibilityOverride] = []) async throws -> [Conversation] {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        let values = try await repository.search(query, limit: limit, includeHidden: includeHidden, visibility: visibility)
        for value in values { try await transcriptService.reconcile(value) }
        return values
    }

    /// Returns a canonical snapshot followed by ordered durable mutations.
    /// The SQLite row is synchronized before the subscription is fenced.
    public func subscribeTranscript(conversationID: UUID) async throws -> TranscriptSubscription {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        guard let conversation = try await repository.conversation(id: conversationID) else {
            throw TranscriptHubError.conversationDeleted(conversationID)
        }
        return try await transcriptService.subscribe(to: conversation)
    }

    /// Records a completed user/assistant exchange only after both message IDs
    /// can be proven to belong to the canonical SQLite conversation.
    @discardableResult
    public func recordFinalAssistantTurn(
        conversationID: UUID,
        userMessageID: UUID,
        assistantMessageID: UUID
    ) async throws -> TurnMemoryExchange {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        guard let conversation = try await repository.conversation(id: conversationID) else {
            throw TranscriptHubError.conversationDeleted(conversationID)
        }
        return try await transcriptService.recordFinalAssistantTurn(
            in: conversation,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID
        )
    }

    /// Convenience for the production streaming path: the nearest preceding
    /// persisted user message is paired with the final assistant message.
    @discardableResult
    public func recordFinalAssistantTurn(
        conversationID: UUID,
        assistantMessageID: UUID
    ) async throws -> TurnMemoryExchange {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        guard let conversation = try await repository.conversation(id: conversationID) else {
            throw TranscriptHubError.conversationDeleted(conversationID)
        }
        guard let assistantIndex = conversation.messages.firstIndex(where: { $0.id == assistantMessageID }) else {
            throw TranscriptHubError.missingMessage(assistantMessageID)
        }
        guard let user = conversation.messages[..<assistantIndex].last(where: { $0.role == .user }) else {
            throw TranscriptHubError.malformed("final assistant turn has no preceding persisted user message")
        }
        return try await transcriptService.recordFinalAssistantTurn(
            in: conversation,
            userMessageID: user.id,
            assistantMessageID: assistantMessageID
        )
    }

    public func recentTurnMemory(conversationID: UUID) async throws -> [TurnMemoryExchange] {
        try await recentTurnMemorySnapshot(conversationID: conversationID).exchanges
    }

    public func recentTurnMemorySnapshot(conversationID: UUID) async throws -> TurnMemorySnapshot {
        let repository = try resolveRepository()
        try await importLegacyIfNeeded(into: repository)
        guard let conversation = try await repository.conversation(id: conversationID) else {
            throw TranscriptHubError.conversationDeleted(conversationID)
        }
        return try await transcriptService.recentMemory(for: conversation)
    }

    /// Latest startup recovery information suitable for a user-visible notice.
    public func recoveryReport() throws -> PersistenceRecoveryReport? {
        try resolveRepository().initialRecoveryReport
    }

    /// Explicitly rebuilds derived search/index state without replacing any
    /// conversation or message rows.
    public func rebuildSearchIndex() async throws -> PersistenceRecoveryReport {
        try await resolveRepository().rebuildSearchIndex()
    }

    private func resolveRepository() throws -> ConversationRepository {
        if let repository { return repository }
        let value = try ConversationRepository(databaseURL: databaseURL)
        repository = value
        return value
    }

    // Kept internal so the global-search extension can share the same lazy
    // repository/import lifecycle without exposing persistence to the UI.
    func resolveRepositoryForGlobalSearch() throws -> ConversationRepository { try resolveRepository() }

    func ensureLegacyImportForGlobalSearch(into repository: ConversationRepository) async throws {
        try await importLegacyIfNeeded(into: repository)
    }

    private func importLegacyIfNeeded(into repository: ConversationRepository) async throws {
        guard !importChecked else { return }
        if FileManager.default.fileExists(atPath: markerURL.path) || !FileManager.default.fileExists(atPath: legacyURL.path) {
            importChecked = true
            return
        }
        let existing = try await repository.load()
        if existing.isEmpty {
            let data: Data
            do { data = try Data(contentsOf: legacyURL) }
            catch { throw PersistenceError.invalidLegacy(error.localizedDescription) }
            let values: [Conversation]
            do { values = try decodeLegacy(data) }
            catch { throw PersistenceError.invalidLegacy(error.localizedDescription) }
            try await repository.save(values)
        }
        do {
            if !FileManager.default.fileExists(atPath: backupURL.path) { try FileManager.default.copyItem(at: legacyURL, to: backupURL) }
            try Data("schema=1\n".utf8).write(to: markerURL, options: .atomic)
        } catch {
            throw PersistenceError.invalidLegacy("data imported, but backup marker failed: \(error.localizedDescription)")
        }
        importChecked = true
    }

    private func decodeLegacy(_ data: Data) throws -> [Conversation] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode([Conversation].self, from: data) { return value }
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Conversation].self, from: data)
    }

    private static func mergeChronologically(older: [ChatMessage], newer: [ChatMessage]) -> [ChatMessage] {
        let newerIDs = Set(newer.map(\.id))
        return older.filter { !newerIDs.contains($0.id) } + newer
    }
}
