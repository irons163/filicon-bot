import Foundation
import FiliconDomain

public enum TranscriptHubError: Error, Equatable, Sendable {
    case invalidCapacity
    case emptyTransaction
    case malformed(String)
    case foreignConversation(expected: UUID, received: UUID)
    case foreignReplica(expected: String, received: String)
    case staleGeneration(expected: UUID, received: UUID)
    case staleSequence(last: UInt64, received: UInt64)
    case sequenceGap(expected: UInt64, received: UInt64)
    case duplicateMessage(UUID)
    case missingMessage(UUID)
    case subscriberOverflow
    case conversationDeleted(UUID)
    case injectedFailure(TranscriptCommitStage)
}

public enum TranscriptCommitStage: String, Codable, Equatable, Sendable {
    case afterJournal
    case afterCheckpoint
}

public enum TranscriptMutation: Codable, Hashable, Sendable {
    case append(ChatMessage)
    case update(ChatMessage)
    case remove(messageID: UUID)
    case clear
}

public struct TranscriptEvent: Codable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let replicaKey: String
    public let generation: UUID
    public let sequence: UInt64
    public let mutations: [TranscriptMutation]

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        replicaKey: String,
        generation: UUID,
        sequence: UInt64,
        mutations: [TranscriptMutation]
    ) {
        self.id = id
        self.conversationID = conversationID
        self.replicaKey = replicaKey
        self.generation = generation
        self.sequence = sequence
        self.mutations = mutations
    }
}

public struct TranscriptFence: Codable, Hashable, Sendable {
    public let generation: UUID
    public let throughSequence: UInt64

    public init(generation: UUID, throughSequence: UInt64) {
        self.generation = generation
        self.throughSequence = throughSequence
    }
}

public struct TranscriptSnapshot: Codable, Hashable, Sendable {
    public let conversationID: UUID
    public let replicaKey: String
    public let fence: TranscriptFence
    public let messages: [ChatMessage]
}

public struct TranscriptSubscription: Sendable {
    public let snapshot: TranscriptSnapshot
    public let events: AsyncThrowingStream<TranscriptEvent, any Error>
}

/// A conversation-scoped, bounded event hub. Mutations are journaled before
/// they become observable and checkpointed before the journal is removed.
/// Reopening therefore replays a committed journal exactly once after either
/// process termination point.
public actor TranscriptEventHub {
    public nonisolated let conversationID: UUID
    public nonisolated let replicaKey: String
    public nonisolated let generation: UUID

    private struct Checkpoint: Codable {
        let formatVersion: Int
        let conversationID: UUID
        let replicaKey: String
        let generation: UUID?
        let throughSequence: UInt64
        let messages: [ChatMessage]
    }

    private let directoryURL: URL
    private let checkpointURL: URL
    private let journalURL: URL
    private let subscriberBufferSize: Int
    private let faultAt: TranscriptCommitStage?
    private var messages: [ChatMessage]
    private var sequence: UInt64 = 0
    private var continuations: [UUID: AsyncThrowingStream<TranscriptEvent, any Error>.Continuation] = [:]

    public init(
        conversationID: UUID,
        replicaDirectoryURL: URL,
        subscriberBufferSize: Int = 64,
        generation: UUID = UUID(),
        faultAt: TranscriptCommitStage? = nil
    ) throws {
        guard subscriberBufferSize > 0 else { throw TranscriptHubError.invalidCapacity }
        self.conversationID = conversationID
        replicaKey = "conversation:\(conversationID.uuidString.lowercased())"
        self.generation = generation
        directoryURL = replicaDirectoryURL
        checkpointURL = replicaDirectoryURL.appendingPathComponent("transcript-checkpoint.json")
        journalURL = replicaDirectoryURL.appendingPathComponent("transcript-journal.json")
        self.subscriberBufferSize = subscriberBufferSize
        self.faultAt = faultAt

        try Self.prepareReplicaDirectory(replicaDirectoryURL)
        let recovered = try Self.recover(
            checkpointURL: checkpointURL,
            journalURL: journalURL,
            conversationID: conversationID,
            replicaKey: replicaKey
        )
        messages = recovered.messages
        // A generation is a process lifetime fence, matching HostReplicaWriter.
        // Reopen begins a new generation and sequence space after recovery.
        sequence = 0
    }

    public func snapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(
            conversationID: conversationID,
            replicaKey: replicaKey,
            fence: TranscriptFence(generation: generation, throughSequence: sequence),
            messages: messages
        )
    }

    public func subscribe() -> TranscriptSubscription {
        let id = UUID()
        let pair = AsyncThrowingStream<TranscriptEvent, any Error>.makeStream(
            bufferingPolicy: .bufferingNewest(subscriberBufferSize)
        )
        continuations[id] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return TranscriptSubscription(snapshot: snapshot(), events: pair.stream)
    }

    public func invalidate() {
        for continuation in continuations.values {
            continuation.finish(throwing: TranscriptHubError.conversationDeleted(conversationID))
        }
        continuations.removeAll()
    }

    @discardableResult
    public func transact(_ mutations: [TranscriptMutation]) throws -> TranscriptEvent {
        guard !mutations.isEmpty else { throw TranscriptHubError.emptyTransaction }
        let nextMessages = try Self.applying(mutations, to: messages)
        let event = TranscriptEvent(
            conversationID: conversationID,
            replicaKey: replicaKey,
            generation: generation,
            sequence: sequence + 1,
            mutations: mutations
        )

        try Self.write([event], to: journalURL)
        if faultAt == .afterJournal { throw TranscriptHubError.injectedFailure(.afterJournal) }
        let checkpoint = Checkpoint(
            formatVersion: 1,
            conversationID: conversationID,
            replicaKey: replicaKey,
            generation: generation,
            throughSequence: event.sequence,
            messages: nextMessages
        )
        try Self.write(checkpoint, to: checkpointURL)
        if faultAt == .afterCheckpoint { throw TranscriptHubError.injectedFailure(.afterCheckpoint) }
        try Self.write([TranscriptEvent](), to: journalURL)

        messages = nextMessages
        sequence = event.sequence
        var overflowed: [UUID] = []
        for (id, continuation) in continuations {
            if case .dropped = continuation.yield(event) {
                continuation.finish(throwing: TranscriptHubError.subscriberOverflow)
                overflowed.append(id)
            }
        }
        for id in overflowed { continuations.removeValue(forKey: id) }
        return event
    }

    @discardableResult public func append(_ message: ChatMessage) throws -> TranscriptEvent {
        try transact([.append(message)])
    }

    @discardableResult public func update(_ message: ChatMessage) throws -> TranscriptEvent {
        try transact([.update(message)])
    }

    @discardableResult public func remove(messageID: UUID) throws -> TranscriptEvent {
        try transact([.remove(messageID: messageID)])
    }

    @discardableResult public func clear() throws -> TranscriptEvent {
        try transact([.clear])
    }

    /// Applies an event obtained from this hub's current subscription. Callers
    /// must retain the subscription snapshot fence; old generations and gaps
    /// are rejected rather than coerced into a plausible state.
    public func validate(_ event: TranscriptEvent, after fence: TranscriptFence) throws {
        guard event.conversationID == conversationID else {
            throw TranscriptHubError.foreignConversation(expected: conversationID, received: event.conversationID)
        }
        guard event.replicaKey == replicaKey else {
            throw TranscriptHubError.foreignReplica(expected: replicaKey, received: event.replicaKey)
        }
        guard event.generation == fence.generation else {
            throw TranscriptHubError.staleGeneration(expected: fence.generation, received: event.generation)
        }
        guard event.sequence > fence.throughSequence else {
            throw TranscriptHubError.staleSequence(last: fence.throughSequence, received: event.sequence)
        }
        guard event.sequence == fence.throughSequence + 1 else {
            throw TranscriptHubError.sequenceGap(expected: fence.throughSequence + 1, received: event.sequence)
        }
        guard !event.mutations.isEmpty else { throw TranscriptHubError.emptyTransaction }
        for mutation in event.mutations {
            switch mutation {
            case .append(let message), .update(let message): try Self.validate(message)
            case .remove, .clear: break
            }
        }
    }

    private func removeSubscriber(_ id: UUID) { continuations.removeValue(forKey: id) }

    private static func applying(_ mutations: [TranscriptMutation], to original: [ChatMessage]) throws -> [ChatMessage] {
        guard !mutations.isEmpty else { throw TranscriptHubError.emptyTransaction }
        var result = original
        for mutation in mutations {
            switch mutation {
            case .append(let message):
                try validate(message)
                guard !result.contains(where: { $0.id == message.id }) else {
                    throw TranscriptHubError.duplicateMessage(message.id)
                }
                result.append(message)
            case .update(let message):
                try validate(message)
                guard let index = result.firstIndex(where: { $0.id == message.id }) else {
                    throw TranscriptHubError.missingMessage(message.id)
                }
                result[index] = message
            case .remove(let messageID):
                guard let index = result.firstIndex(where: { $0.id == messageID }) else {
                    throw TranscriptHubError.missingMessage(messageID)
                }
                result.remove(at: index)
                for index in result.indices where result[index].replyToMessageID == messageID {
                    result[index].replyToMessageID = nil
                }
            case .clear:
                result.removeAll(keepingCapacity: false)
            }
        }
        return result
    }

    private static func validate(_ message: ChatMessage) throws {
        // Only exact ordered image metadata permits repeated sources. Ordinary
        // attachments and bounded turn-memory evidence remain source-unique.
        if let layout = message.imageGalleryLayout,
           !layout.matches(attachments: message.attachments, remoteGallery: message.remoteImages) {
            throw TranscriptHubError.malformed("invalid ordered image gallery for message \(message.id)")
        }
        var attachmentIDs = Set<String>()
        for attachment in message.attachments {
            guard !attachment.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  attachment.byteCount >= 0,
                  attachmentIDs.insert(attachment.id).inserted || message.imageGalleryLayout != nil else {
                throw TranscriptHubError.malformed("invalid or duplicate attachment metadata for message \(message.id)")
            }
        }
    }

    private static func recover(
        checkpointURL: URL,
        journalURL: URL,
        conversationID: UUID,
        replicaKey: String
    ) throws -> Checkpoint {
        var checkpoint: Checkpoint
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            checkpoint = try decode(Checkpoint.self, from: checkpointURL)
            guard checkpoint.formatVersion == 1 else { throw TranscriptHubError.malformed("unsupported checkpoint version") }
            guard checkpoint.conversationID == conversationID else {
                throw TranscriptHubError.foreignConversation(expected: conversationID, received: checkpoint.conversationID)
            }
            guard checkpoint.replicaKey == replicaKey else {
                throw TranscriptHubError.foreignReplica(expected: replicaKey, received: checkpoint.replicaKey)
            }
            // An empty checkpoint is the normal durable representation after
            // clearing a conversation.  There is no transaction to validate
            // in that case, so do not route it through `applying`, which
            // deliberately rejects empty transactions.
            if !checkpoint.messages.isEmpty {
                _ = try applying(checkpoint.messages.map(TranscriptMutation.append), to: [])
            }
        } else {
            checkpoint = Checkpoint(formatVersion: 1, conversationID: conversationID, replicaKey: replicaKey, generation: nil, throughSequence: 0, messages: [])
        }

        guard FileManager.default.fileExists(atPath: journalURL.path) else { return checkpoint }
        let events = try decode([TranscriptEvent].self, from: journalURL)
        var messages = checkpoint.messages
        var replayGeneration = checkpoint.generation
        var through = checkpoint.throughSequence
        for event in events {
            guard event.conversationID == conversationID else {
                throw TranscriptHubError.foreignConversation(expected: conversationID, received: event.conversationID)
            }
            guard event.replicaKey == replicaKey else {
                throw TranscriptHubError.foreignReplica(expected: replicaKey, received: event.replicaKey)
            }
            if replayGeneration == event.generation, event.sequence <= through { continue }
            if replayGeneration != event.generation {
                guard through == 0 || events.count == 1 else { throw TranscriptHubError.malformed("mixed journal generations") }
                replayGeneration = event.generation
                through = 0
            }
            guard event.sequence == through + 1 else {
                throw TranscriptHubError.sequenceGap(expected: through + 1, received: event.sequence)
            }
            messages = try applying(event.mutations, to: messages)
            through = event.sequence
        }
        let recovered = Checkpoint(formatVersion: 1, conversationID: conversationID, replicaKey: replicaKey, generation: replayGeneration, throughSequence: through, messages: messages)
        try write(recovered, to: checkpointURL)
        try write([TranscriptEvent](), to: journalURL)
        return recovered
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        do {
            try requireRegularFile(url)
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw TranscriptHubError.malformed("empty durable replica file") }
            return try JSONDecoder().decode(type, from: data)
        } catch let error as TranscriptHubError { throw error }
        catch { throw TranscriptHubError.malformed("cannot decode \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try requireRegularFile(url) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private static func prepareReplicaDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isDirectory == true, values.isSymbolicLink != true else {
                throw TranscriptHubError.malformed("unsafe transcript replica directory")
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TranscriptHubError.malformed("unsafe durable replica file")
        }
    }
}

public struct TurnMemoryExchange: Codable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let occurredAt: Date
    public let user: String
    public let assistant: String
    public let userMessageID: UUID?
    public let assistantMessageID: UUID?
    public let attachmentIDs: [String]
    public let attachments: [AttachmentMetadata]

    public init(
        id: UUID = UUID(), conversationID: UUID, occurredAt: Date,
        user: String, assistant: String, userMessageID: UUID? = nil,
        assistantMessageID: UUID? = nil, attachmentIDs: [String] = [],
        attachments: [AttachmentMetadata] = []
    ) {
        self.id = id
        self.conversationID = conversationID
        self.occurredAt = occurredAt
        self.user = user
        self.assistant = assistant
        self.userMessageID = userMessageID
        self.assistantMessageID = assistantMessageID
        self.attachmentIDs = attachmentIDs
        self.attachments = attachments
    }
}

public struct TurnMemorySnapshot: Codable, Hashable, Sendable {
    public let formatVersion: Int
    public let conversationID: UUID
    public let capacity: Int
    public let exchanges: [TurnMemoryExchange]

    public init(formatVersion: Int = 1, conversationID: UUID, capacity: Int, exchanges: [TurnMemoryExchange]) {
        self.formatVersion = formatVersion
        self.conversationID = conversationID
        self.capacity = capacity
        self.exchanges = exchanges
    }
}

/// Bounded recent turn evidence. Snapshot bytes are stable (sorted JSON keys)
/// and hydration rejects wrong-scope, duplicate, unordered, or blank evidence.
public actor TurnMemoryBuffer {
    public nonisolated let conversationID: UUID
    public nonisolated let capacity: Int
    private var exchanges: [TurnMemoryExchange]

    public init(conversationID: UUID, capacity: Int = 20) throws {
        guard capacity > 0 else { throw TranscriptHubError.invalidCapacity }
        self.conversationID = conversationID
        self.capacity = capacity
        exchanges = []
    }

    public init(snapshot: TurnMemorySnapshot) throws {
        guard snapshot.formatVersion == 1 else { throw TranscriptHubError.malformed("unsupported memory snapshot version") }
        guard snapshot.capacity > 0, snapshot.exchanges.count <= snapshot.capacity else { throw TranscriptHubError.invalidCapacity }
        try Self.validate(snapshot.exchanges, conversationID: snapshot.conversationID)
        conversationID = snapshot.conversationID
        capacity = snapshot.capacity
        exchanges = snapshot.exchanges
    }

    public func record(_ exchange: TurnMemoryExchange) throws {
        guard exchange.conversationID == conversationID else {
            throw TranscriptHubError.foreignConversation(expected: conversationID, received: exchange.conversationID)
        }
        try Self.validate([exchange], conversationID: conversationID)
        guard !exchanges.contains(where: { $0.id == exchange.id }) else {
            throw TranscriptHubError.malformed("duplicate memory exchange id")
        }
        if let last = exchanges.last, exchange.occurredAt < last.occurredAt {
            throw TranscriptHubError.malformed("turn memory evidence is out of order")
        }
        exchanges.append(exchange)
        if exchanges.count > capacity { exchanges.removeFirst(exchanges.count - capacity) }
    }

    public func snapshot() -> TurnMemorySnapshot {
        TurnMemorySnapshot(formatVersion: 1, conversationID: conversationID, capacity: capacity, exchanges: exchanges)
    }

    public func snapshotData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(snapshot())
    }

    public static func hydrate(_ data: Data) throws -> TurnMemoryBuffer {
        guard !data.isEmpty else { throw TranscriptHubError.malformed("empty memory snapshot") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try TurnMemoryBuffer(snapshot: decoder.decode(TurnMemorySnapshot.self, from: data)) }
        catch let error as TranscriptHubError { throw error }
        catch { throw TranscriptHubError.malformed("cannot decode memory snapshot: \(error.localizedDescription)") }
    }

    public static func hydrate(
        _ data: Data,
        expectedConversationID: UUID,
        capacity: Int
    ) throws -> TurnMemoryBuffer {
        let buffer = try hydrate(data)
        guard buffer.conversationID == expectedConversationID else {
            throw TranscriptHubError.foreignConversation(expected: expectedConversationID, received: buffer.conversationID)
        }
        guard buffer.capacity == capacity else { throw TranscriptHubError.invalidCapacity }
        return buffer
    }

    private static func validate(_ values: [TurnMemoryExchange], conversationID: UUID) throws {
        var ids = Set<UUID>()
        var previousDate: Date?
        for value in values {
            guard value.conversationID == conversationID else {
                throw TranscriptHubError.foreignConversation(expected: conversationID, received: value.conversationID)
            }
            guard !value.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ids.insert(value.id).inserted else {
                throw TranscriptHubError.malformed("blank or duplicate turn memory evidence")
            }
            let cleaned = value.attachmentIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard !cleaned.contains(where: \ .isEmpty), Set(cleaned).count == cleaned.count else {
                throw TranscriptHubError.malformed("blank or duplicate turn memory attachment id")
            }
            guard Set(value.attachments.map(\.id)).count == value.attachments.count,
                  value.attachments.allSatisfy({ attachment in
                      !attachment.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      !attachment.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                      attachment.byteCount >= 0
                  }) else {
                throw TranscriptHubError.malformed("invalid or duplicate turn memory attachment metadata")
            }
            if let previousDate, value.occurredAt < previousDate {
                throw TranscriptHubError.malformed("turn memory evidence is out of order")
            }
            previousDate = value.occurredAt
        }
    }
}
