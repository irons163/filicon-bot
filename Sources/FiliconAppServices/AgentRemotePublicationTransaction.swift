import Foundation
import FiliconAgents
import FiliconDomain

/// Host-owned approval and persistence of a locator. No download, credentials,
/// MIME inference, or local attachment ownership is implied by this receipt.
public actor AgentRemotePublicationTransaction {
    public struct Review: Sendable, Equatable {
        public let conversationID: UUID
        public let senderID: UUID
        public let reference: RemoteAttachmentReference
        public let replyTo: UUID?
    }
    public struct Receipt: Sendable, Equatable {
        public let messageID: UUID
        public let review: Review
        public init(messageID: UUID, review: Review) {
            self.messageID = messageID; self.review = review
        }
    }
    public enum Failure: Error, Equatable, Sendable {
        case unavailable, busy, duplicateCall, uncertainCommit, invalidReceipt
    }
    public typealias Authorize = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Void
    public typealias Commit = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Receipt
    public nonisolated let conversationID: UUID
    public nonisolated let destinationConversationID: UUID
    public nonisolated let senderID: UUID
    private let validateScope: @Sendable () async throws -> Void
    private let authorize: Authorize
    private let commit: Commit
    private struct Key: Hashable { let run: UUID; let call: ToolCallID }
    private var completed: [Key: Receipt] = [:]
    private var attempted: Set<Key> = []
    private var messageIDs: Set<UUID> = []
    private var published: Set<RemoteAttachmentReference> = []
    private var busy = false
    private var closed = false

    public init(conversationID: UUID, senderID: UUID, destinationConversationID: UUID? = nil,
        validateScope: @escaping @Sendable () async throws -> Void,
        authorize: @escaping Authorize, commit: @escaping Commit) {
        self.conversationID = conversationID; self.senderID = senderID
        self.destinationConversationID = destinationConversationID ?? conversationID
        self.validateScope = validateScope; self.authorize = authorize; self.commit = commit
    }
    public func close() { closed = true }

    public func publish(reference: RemoteAttachmentReference, replyTo: UUID?,
        call: NormalizedToolCall, context: ToolContext) async throws -> Receipt {
        guard context.conversationID == conversationID, call.name == "SendMessage" else { throw Failure.unavailable }
        let key = Key(run: context.runID, call: call.id)
        let review = Review(conversationID: destinationConversationID, senderID: senderID, reference: reference, replyTo: replyTo)
        if let prior = completed[key] {
            guard prior.review == review else { throw Failure.duplicateCall }
            return prior
        }
        guard !attempted.contains(key) else { throw Failure.uncertainCommit }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        try await checkScope()
        guard !published.contains(reference) else { throw Failure.duplicateCall }
        try await authorize(review, call, context)
        try await checkScope()
        attempted.insert(key)
        let receipt = try await commit(review, call, context)
        guard receipt.review == review, !messageIDs.contains(receipt.messageID) else { throw Failure.invalidReceipt }
        completed[key] = receipt
        messageIDs.insert(receipt.messageID)
        published.insert(reference)
        // Stop after a successful commit must not erase the durable outcome.
        return receipt
    }

    private func checkScope() async throws {
        try Task.checkCancellation()
        guard !closed else { throw Failure.unavailable }
        try await validateScope()
        try Task.checkCancellation()
        guard !closed else { throw Failure.unavailable }
    }
}
