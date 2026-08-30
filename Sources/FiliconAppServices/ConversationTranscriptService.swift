import Foundation
import FiliconDomain
import FiliconPersistence

/// Maintains the conversation-scoped durable replicas derived from SQLite.
/// SQLite is authoritative: callers commit there first and then reconcile here.
public actor ConversationTranscriptService {
    private let rootURL: URL
    private let memoryCapacity: Int
    private var hubs: [UUID: TranscriptEventHub] = [:]
    private var memories: [UUID: TurnMemoryBuffer] = [:]

    public init(dataRootURL: URL, memoryCapacity: Int = 20) {
        rootURL = dataRootURL.appendingPathComponent("conversation-replicas", isDirectory: true)
        self.memoryCapacity = memoryCapacity
    }

    public func reconcile(_ conversation: Conversation) async throws {
        let hub = try resolveHub(conversationID: conversation.id)
        let snapshot = await hub.snapshot()
        let mutations = Self.exactMutations(from: snapshot.messages, to: conversation.messages)
        if !mutations.isEmpty { _ = try await hub.transact(mutations) }
        try await pruneMemory(to: conversation)
    }

    public func reconcileAll(_ conversations: [Conversation]) async throws {
        let canonicalIDs = Set(conversations.map(\.id))
        for conversation in conversations { try await reconcile(conversation) }
        try await removeOrphanReplicas(keeping: canonicalIDs)
    }

    public func subscribe(to conversation: Conversation) async throws -> TranscriptSubscription {
        try await reconcile(conversation)
        return await resolveCachedHub(conversationID: conversation.id).subscribe()
    }

    public func delete(conversationID: UUID) async throws {
        if let hub = hubs.removeValue(forKey: conversationID) { await hub.invalidate() }
        memories.removeValue(forKey: conversationID)
        let url = replicaURL(for: conversationID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try Self.requireDirectory(url, allowMissing: false)
        try FileManager.default.removeItem(at: url)
    }

    @discardableResult
    public func recordFinalAssistantTurn(
        in conversation: Conversation,
        userMessageID: UUID,
        assistantMessageID: UUID
    ) async throws -> TurnMemoryExchange {
        guard let user = conversation.messages.first(where: { $0.id == userMessageID }) else {
            throw TranscriptHubError.missingMessage(userMessageID)
        }
        guard let assistant = conversation.messages.first(where: { $0.id == assistantMessageID }) else {
            throw TranscriptHubError.missingMessage(assistantMessageID)
        }
        guard user.role == .user, assistant.role == .assistant,
              assistant.deliveryStatus == .succeeded else {
            throw TranscriptHubError.malformed("turn memory requires a persisted user message and final assistant message")
        }
        try await reconcile(conversation)
        let buffer = try resolveMemory(conversationID: conversation.id)
        var seenAttachmentIDs = Set<String>()
        let attachments = (user.attachments + assistant.attachments).filter {
            seenAttachmentIDs.insert($0.id).inserted
        }
        let exchange = TurnMemoryExchange(
            conversationID: conversation.id,
            occurredAt: assistant.createdAt,
            user: user.text,
            assistant: assistant.text,
            userMessageID: user.id,
            assistantMessageID: assistant.id,
            attachmentIDs: attachments.map(\.id),
            attachments: attachments
        )
        let previous = await buffer.snapshot()
        if let recorded = previous.exchanges.first(where: {
            $0.userMessageID == user.id && $0.assistantMessageID == assistant.id
        }) { return recorded }
        try await buffer.record(exchange)
        do {
            try await persistMemory(buffer, conversationID: conversation.id)
        } catch {
            memories[conversation.id] = try TurnMemoryBuffer(snapshot: previous)
            throw error
        }
        return exchange
    }

    public func recentMemory(for conversation: Conversation) async throws -> TurnMemorySnapshot {
        try await reconcile(conversation)
        let memory = try resolveMemory(conversationID: conversation.id)
        return await memory.snapshot()
    }

    private func resolveCachedHub(conversationID: UUID) -> TranscriptEventHub {
        // Only called after `resolveHub`/`reconcile` has populated the cache.
        hubs[conversationID]!
    }

    private func resolveHub(conversationID: UUID) throws -> TranscriptEventHub {
        if let hub = hubs[conversationID] { return hub }
        try ensureRoot()
        let directory = replicaURL(for: conversationID)
        try Self.requireDirectory(directory, allowMissing: true)
        let hub = try TranscriptEventHub(conversationID: conversationID, replicaDirectoryURL: directory)
        hubs[conversationID] = hub
        return hub
    }

    private func resolveMemory(conversationID: UUID) throws -> TurnMemoryBuffer {
        if let memory = memories[conversationID] { return memory }
        let url = memoryURL(for: conversationID)
        let memory: TurnMemoryBuffer
        if FileManager.default.fileExists(atPath: url.path) {
            try Self.requireRegularFile(url)
            memory = try TurnMemoryBuffer.hydrate(
                Data(contentsOf: url),
                expectedConversationID: conversationID,
                capacity: memoryCapacity
            )
        } else {
            memory = try TurnMemoryBuffer(conversationID: conversationID, capacity: memoryCapacity)
        }
        memories[conversationID] = memory
        return memory
    }

    private func pruneMemory(to conversation: Conversation) async throws {
        let url = memoryURL(for: conversation.id)
        guard memories[conversation.id] != nil || FileManager.default.fileExists(atPath: url.path) else { return }
        let buffer = try resolveMemory(conversationID: conversation.id)
        let snapshot = await buffer.snapshot()
        let messages = Dictionary(uniqueKeysWithValues: conversation.messages.map { ($0.id, $0) })
        let retained = snapshot.exchanges.filter { exchange in
            guard let userID = exchange.userMessageID,
                  let assistantID = exchange.assistantMessageID,
                  let user = messages[userID], user.role == .user,
                  let assistant = messages[assistantID], assistant.role == .assistant,
                  assistant.deliveryStatus == .succeeded else { return false }
            return true
        }
        guard retained != snapshot.exchanges else { return }
        let replacement = try TurnMemoryBuffer(snapshot: TurnMemorySnapshot(
            formatVersion: 1,
            conversationID: conversation.id,
            capacity: memoryCapacity,
            exchanges: retained
        ))
        do {
            try await persistMemory(replacement, conversationID: conversation.id)
            memories[conversation.id] = replacement
        } catch {
            memories[conversation.id] = buffer
            throw error
        }
    }

    private func persistMemory(_ buffer: TurnMemoryBuffer, conversationID: UUID) async throws {
        let directory = replicaURL(for: conversationID)
        try Self.requireDirectory(directory, allowMissing: false)
        let url = memoryURL(for: conversationID)
        if FileManager.default.fileExists(atPath: url.path) { try Self.requireRegularFile(url) }
        try await buffer.snapshotData().write(to: url, options: .atomic)
    }

    private func ensureRoot() throws {
        let parent = rootURL.deletingLastPathComponent()
        try Self.requireDirectory(parent, allowMissing: false)
        try Self.requireDirectory(rootURL, allowMissing: true)
        if !FileManager.default.fileExists(atPath: rootURL.path) {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        }
    }

    private func removeOrphanReplicas(keeping ids: Set<UUID>) async throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try Self.requireDirectory(rootURL, allowMissing: false)
        let children = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent), child.lastPathComponent == id.uuidString.lowercased() else {
                throw TranscriptHubError.malformed("foreign entry in transcript replica root")
            }
            guard !ids.contains(id) else { continue }
            try Self.requireDirectory(child, allowMissing: false)
            if let hub = hubs.removeValue(forKey: id) { await hub.invalidate() }
            memories.removeValue(forKey: id)
            try FileManager.default.removeItem(at: child)
        }
    }

    private func replicaURL(for conversationID: UUID) -> URL {
        rootURL.appendingPathComponent(conversationID.uuidString.lowercased(), isDirectory: true)
    }

    private func memoryURL(for conversationID: UUID) -> URL {
        replicaURL(for: conversationID).appendingPathComponent("turn-memory.json")
    }

    private static func exactMutations(from old: [ChatMessage], to new: [ChatMessage]) -> [TranscriptMutation] {
        guard old != new else { return [] }
        if old.map(\.id) == new.map(\.id) {
            return zip(old, new).compactMap { $0 == $1 ? nil : .update($1) }
        }
        if new.isEmpty { return [.clear] }
        return [.clear] + new.map(TranscriptMutation.append)
    }

    private static func requireDirectory(_ url: URL, allowMissing: Bool) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            if allowMissing { return }
            throw TranscriptHubError.malformed("missing replica directory")
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
            throw TranscriptHubError.malformed("unsafe transcript replica directory")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TranscriptHubError.malformed("unsafe transcript replica file")
        }
    }
}
