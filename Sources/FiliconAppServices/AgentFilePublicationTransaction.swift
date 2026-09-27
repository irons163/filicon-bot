import CryptoKit
import Foundation
import FiliconDomain
import FiliconAgents

/// Host services for a foreground group publisher. Commit owns quota and blob
/// references and must invoke save only after installing the reviewed bytes.
/// No defaults: absent services mean the model has no file publication tool.
public struct AgentGroupFilePublicationServices: Sendable {
    public typealias Prepare = @Sendable (AgentProfile, String, NormalizedToolCall, ToolContext) async throws -> PreparedAgentPublicationFile
    public typealias Authorize = @Sendable (AgentProfile, AgentFilePublicationTransaction.Review, NormalizedToolCall, ToolContext) async throws -> Void
    public typealias Save = @Sendable (AttachmentMetadata, UUID) async throws -> RoomMessage
    public typealias Commit = @Sendable (AgentFilePublicationTransaction.Review, NormalizedToolCall, ToolContext, @escaping Save) async throws -> RoomMessage
    public let prepare: Prepare
    public let authorize: Authorize
    public let commit: Commit
    public init(prepare: @escaping Prepare, authorize: @escaping Authorize, commit: @escaping Commit) {
        self.prepare = prepare; self.authorize = authorize; self.commit = commit
    }
}

/// Capability for one host-owned delegation, never reconstructed from model
/// arguments. The host validator must fence the exact dispatch, not merely
/// the continued existence of the source and destination conversations.
public struct AgentBackgroundGroupFileServices: Sendable {
    public let originID: UUID
    public let groupID: UUID
    public let services: AgentGroupFilePublicationServices
    public let validate: @Sendable () async throws -> Void
    public init(originID: UUID, groupID: UUID, services: AgentGroupFilePublicationServices,
                validate: @escaping @Sendable () async throws -> Void) {
        self.originID = originID; self.groupID = groupID
        self.services = services; self.validate = validate
    }
}

/// Captured bytes, not a promise to read a mutable path after approval.
public struct PreparedAgentPublicationFile: Sendable, Equatable {
    public let bytes: Data
    public let filename: String
    public let digest: String

    public init(bytes: Data, filename: String) throws {
        guard !filename.isEmpty, filename != ".", filename != "..", filename.utf8.count <= 255,
              !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AttachmentStoreError.invalidFilename
        }
        let limit = AttachmentLimits.byteLimit(filename: filename)
        guard bytes.count <= limit else { throw AttachmentStoreError.tooLarge(filename: filename, limitBytes: limit) }
        self.bytes = bytes
        self.filename = filename
        digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AgentFilePublicationError: Error, Sendable, Equatable {
    case unavailable, invalidReceipt, duplicateCall, busy, uncertainCommit
}

/// One host-owned turn's file publication transaction. The source reader and
/// publication approver are independent capabilities. The commit callback must
/// reserve quota, install these exact bytes and durably save the message, using
/// the supplied call identity for idempotence. No default permissive callbacks.
public actor AgentFilePublicationTransaction {
    public struct Review: Sendable, Equatable {
        public let conversationID: UUID
        public let senderID: UUID
        public let replyTo: UUID?
        public let file: PreparedAgentPublicationFile
    }
    public struct Receipt: Sendable, Equatable {
        public let messageID: UUID
        public let conversationID: UUID
        public let senderID: UUID
        public let replyTo: UUID?
        public let digest: String
        public let filename: String
        public let byteCount: Int
        public let savedMessage: RoomMessage?

        public init(messageID: UUID, conversationID: UUID, senderID: UUID, replyTo: UUID?,
                    digest: String, filename: String, byteCount: Int, savedMessage: RoomMessage? = nil) {
            self.messageID = messageID; self.conversationID = conversationID; self.senderID = senderID
            self.replyTo = replyTo; self.digest = digest; self.filename = filename; self.byteCount = byteCount
            self.savedMessage = savedMessage
        }
    }
    public typealias Prepare = @Sendable (String, NormalizedToolCall, ToolContext) async throws -> PreparedAgentPublicationFile
    public typealias Authorize = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Void
    public typealias Commit = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Receipt
    private struct Key: Hashable { let runID: UUID; let callID: ToolCallID }
    private struct Input: Equatable { let url: String; let replyTo: UUID? }
    private struct Completed { let input: Input; let receipt: Receipt }
    public nonisolated let conversationID: UUID
    public nonisolated let destinationConversationID: UUID
    public nonisolated let senderID: UUID
    private let prepare: Prepare
    private let authorize: Authorize
    private let commit: Commit
    private let validateScope: @Sendable () async throws -> Void
    private var completed: [Key: Completed] = [:]
    private var attempted: Set<Key> = []
    private var messageIDs: Set<UUID> = []
    private var publishedDigests: Set<String> = []
    private var busy = false
    private var closed = false

    public init(conversationID: UUID, senderID: UUID, destinationConversationID: UUID? = nil,
                validateScope: @escaping @Sendable () async throws -> Void,
                prepare: @escaping Prepare, authorize: @escaping Authorize, commit: @escaping Commit) {
        self.conversationID = conversationID; self.senderID = senderID
        self.destinationConversationID = destinationConversationID ?? conversationID
        self.validateScope = validateScope; self.prepare = prepare; self.authorize = authorize; self.commit = commit
    }

    public func close() { closed = true }

    public func publish(url: String, replyTo: UUID?, call: NormalizedToolCall, context: ToolContext) async throws -> Receipt {
        guard context.conversationID == conversationID, call.name == "SendMessage",
              !url.isEmpty, url.utf8.count <= 16_384 else {
            throw AgentFilePublicationError.unavailable
        }
        let key = Key(runID: context.runID, callID: call.id), input = Input(url: url, replyTo: replyTo)
        // A known durable result remains queryable after cancellation/close;
        // retrieving it never reads or writes anything again.
        if let previous = completed[key] {
            guard previous.input == input else { throw AgentFilePublicationError.duplicateCall }
            return previous.receipt
        }
        guard !attempted.contains(key) else { throw AgentFilePublicationError.uncertainCommit }
        guard !busy else { throw AgentFilePublicationError.busy }
        busy = true
        defer { busy = false }
        try await checkScope()
        let file = try await prepare(url, call, context)
        try await checkScope()
        guard !publishedDigests.contains(file.digest) else { throw AgentFilePublicationError.duplicateCall }
        let review = Review(conversationID: destinationConversationID, senderID: senderID, replyTo: replyTo, file: file)
        try await authorize(review, call, context)
        try await checkScope()
        // A thrown save can be ambiguous. Never repeat the side effect under
        // this identity; recovery must inspect durable state, not blindly retry.
        attempted.insert(key)
        let receipt = try await commit(review, call, context)
        guard receipt.conversationID == destinationConversationID, receipt.senderID == senderID,
              receipt.replyTo == replyTo, receipt.digest == file.digest,
              receipt.filename == file.filename, receipt.byteCount == file.bytes.count,
              !messageIDs.contains(receipt.messageID) else { throw AgentFilePublicationError.invalidReceipt }
        messageIDs.insert(receipt.messageID)
        publishedDigests.insert(file.digest)
        completed[key] = Completed(input: input, receipt: receipt)
        // Do not erase or misreport a durable save if Stop arrived during it.
        return receipt
    }

    private func checkScope() async throws {
        try Task.checkCancellation()
        guard !closed else { throw AgentFilePublicationError.unavailable }
        try await validateScope()
        try Task.checkCancellation()
        guard !closed else { throw AgentFilePublicationError.unavailable }
    }
}
