import Foundation
import FiliconAgents
import FiliconDomain

/// A host dispatch capability; validation must reject cancellation and stale scope.
public struct AgentBackgroundGroupGalleryServices: Sendable {
    public let originID: UUID
    public let groupID: UUID
    public let validate: @Sendable () async throws -> Void
    public let authorize: AgentMessagingSession.GalleryPublicationAuthorizer
    public init(originID: UUID, groupID: UUID,
                validate: @escaping @Sendable () async throws -> Void,
                authorize: @escaping AgentMessagingSession.GalleryPublicationAuthorizer) {
        self.originID = originID; self.groupID = groupID
        self.validate = validate; self.authorize = authorize
    }
}

/// One reviewed text-and-gallery publication. The host commits exactly one durable message.
/// Locators are not downloaded by this transaction and confer no network or file permission.
public actor AgentGalleryPublicationTransaction {
    public struct Review: Equatable, Sendable {
        public let conversationID: UUID
        public let senderID: UUID
        public let text: String
        public let gallery: RemoteImageGallery
        public let replyTo: UUID?
    }
    public struct Receipt: Equatable, Sendable {
        public let review: Review
        public let message: RoomMessage
        public init(review: Review, message: RoomMessage) {
            self.review = review; self.message = message
        }
    }
    public enum Failure: Error, Equatable, Sendable {
        case unavailable, invalidText, busy, duplicateCall, uncertainCommit, invalidReceipt
    }
    public nonisolated let conversationID: UUID
    public nonisolated let destinationConversationID: UUID
    public nonisolated let senderID: UUID
    public typealias Authorize = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Void
    public typealias Commit = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Receipt
    private let validateScope: @Sendable () async throws -> Void
    private let authorize: Authorize
    private let commit: Commit
    private struct Key: Hashable { let run: UUID; let call: ToolCallID }
    private var completed: [Key: Receipt] = [:]
    private var attempted: Set<Key> = []
    private var messageIDs: Set<UUID> = []
    private var published: [Review] = []
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

    public func publish(text: String, gallery: RemoteImageGallery, replyTo: UUID?,
                        call: NormalizedToolCall, context: ToolContext) async throws -> Receipt {
        guard context.conversationID == conversationID, call.name == "SendMessage" else { throw Failure.unavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 8_000, text.utf8.count <= 32_000 else { throw Failure.invalidText }
        let key = Key(run: context.runID, call: call.id)
        let review = Review(conversationID: destinationConversationID, senderID: senderID,
            text: text, gallery: gallery, replyTo: replyTo)
        if let prior = completed[key] {
            guard prior.review == review else { throw Failure.duplicateCall }
            return prior
        }
        guard !attempted.contains(key) else { throw Failure.uncertainCommit }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        try await checkScope()
        guard !published.contains(review) else { throw Failure.duplicateCall }
        try await authorize(review, call, context)
        try await checkScope()
        attempted.insert(key)
        let receipt = try await commit(review, call, context)
        let message = receipt.message
        guard receipt.review == review, !messageIDs.contains(message.id),
              message.groupID == review.conversationID, message.senderID == review.senderID,
              message.text == review.text, message.remoteImages == review.gallery,
              message.replyToMessageID == review.replyTo, message.remoteAttachment == nil,
              (message.images ?? []).isEmpty, (message.files ?? []).isEmpty,
              message.question == nil, message.secretRequest == nil, message.cursorAgent == nil,
              message.questionReplyTo == nil, message.memberOutcome == nil,
              message.toolActivities.isEmpty else { throw Failure.invalidReceipt }
        completed[key] = receipt
        messageIDs.insert(message.id)
        published.append(review)
        // A cancellation after durable commit must not erase a known saved outcome.
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
