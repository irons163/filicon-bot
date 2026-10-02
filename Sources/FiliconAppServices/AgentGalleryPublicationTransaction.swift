import Foundation
import FiliconAgents
import FiliconDomain

public typealias AgentGalleryImagePreparer = @Sendable (AgentProfile, String, String?, NormalizedToolCall, ToolContext) async throws -> PreparedAgentGalleryImage
/// Host-owned installation boundary. Production callers reserve app-wide
/// quota before installing captured bytes; no model-provided path is reopened.
public typealias AgentGalleryImageImporter = @Sendable (PreparedAgentGalleryImage) async throws -> AttachmentMetadata

/// Exact, validated bytes captured from a host-authorized local file before
/// review. The source path is deliberately not retained in the saved message.
public struct PreparedAgentGalleryImage: Equatable, Sendable {
    public let file: PreparedAgentPublicationFile
    public let mimeType: String
    public let altText: String?

    public init(bytes: Data, filename: String, altText: String?) throws {
        guard bytes.count <= AgentImageStore.maximumBytes else { throw AgentImageError.limit }
        if let altText {
            guard !altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  altText.count <= 500, altText.utf8.count <= 2_000,
                  !altText.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AgentImageError.invalid
            }
        }
        mimeType = try AgentImageStore.validate(bytes)
        file = try PreparedAgentPublicationFile(bytes: bytes, filename: filename)
        self.altText = altText
    }
}

/// Bound to one host-owned mailbox delivery, not model-provided scope.
public struct AgentMailboxGalleryServices: Sendable {
    public let incomingID: UUID
    public let originID: UUID
    public let senderID: UUID
    public let validate: @Sendable () async throws -> Void
    public let authorize: AgentMessagingSession.GalleryPublicationAuthorizer
    public let prepareLocalImage: AgentGalleryImagePreparer?
    public init(incomingID: UUID, originID: UUID, senderID: UUID,
                validate: @escaping @Sendable () async throws -> Void,
                authorize: @escaping AgentMessagingSession.GalleryPublicationAuthorizer,
                prepareLocalImage: AgentGalleryImagePreparer? = nil) {
        self.incomingID = incomingID; self.originID = originID; self.senderID = senderID
        self.validate = validate; self.authorize = authorize; self.prepareLocalImage = prepareLocalImage
    }
}

/// A host dispatch capability; validation must reject cancellation and stale scope.
public struct AgentBackgroundGroupGalleryServices: Sendable {
    public let originID: UUID
    public let groupID: UUID
    public let validate: @Sendable () async throws -> Void
    public let authorize: AgentMessagingSession.GalleryPublicationAuthorizer
    public let prepareLocalImage: AgentGalleryImagePreparer?
    public init(originID: UUID, groupID: UUID,
                validate: @escaping @Sendable () async throws -> Void,
                authorize: @escaping AgentMessagingSession.GalleryPublicationAuthorizer,
                prepareLocalImage: AgentGalleryImagePreparer? = nil) {
        self.originID = originID; self.groupID = groupID
        self.validate = validate; self.authorize = authorize; self.prepareLocalImage = prepareLocalImage
    }
}

/// One reviewed text-and-gallery publication. The host commits exactly one durable message.
/// Locators are not downloaded by this transaction and confer no network or file permission.
public actor AgentGalleryPublicationTransaction {
    public enum Image: Equatable, Sendable {
        case local(PreparedAgentGalleryImage)
        case remote(RemoteAttachmentReference)
    }
    public struct Review: Equatable, Sendable {
        public let conversationID: UUID
        public let senderID: UUID
        public let text: String
        public let images: [Image]
        public let replyTo: UUID?

        public var gallery: RemoteImageGallery? {
            let references = images.compactMap { image -> RemoteAttachmentReference? in
                if case let .remote(reference) = image { return reference }
                return nil
            }
            return references.isEmpty ? nil : try? RemoteImageGallery(images: references)
        }
        public var localImages: [PreparedAgentGalleryImage] {
            images.compactMap { image in if case let .local(value) = image { value } else { nil } }
        }
        public var layout: ImageGalleryLayout? {
            try? ImageGalleryLayout(items: images.map { image in
                switch image {
                case let .local(value): .attachment(value.file.digest)
                case let .remote(reference): .remote(reference)
                }
            })
        }
    }
    public struct Receipt: Equatable, Sendable {
        public let review: Review
        public let message: RoomMessage
        public init(review: Review, message: RoomMessage) {
            self.review = review; self.message = message
        }
    }
    public enum Failure: Error, Equatable, Sendable {
        case unavailable, invalidText, invalidGallery, busy, duplicateCall, uncertainCommit, invalidReceipt
    }
    public nonisolated let conversationID: UUID
    public nonisolated let destinationConversationID: UUID
    public nonisolated let senderID: UUID
    public typealias Authorize = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Void
    public typealias Commit = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Receipt
    public typealias PrepareLocalImage = @Sendable (String, String?, NormalizedToolCall, ToolContext) async throws -> PreparedAgentGalleryImage
    private let validateScope: @Sendable () async throws -> Void
    private let authorize: Authorize
    private let commit: Commit
    private let prepareLocalImage: PrepareLocalImage?
    private struct Key: Hashable { let run: UUID; let call: ToolCallID }
    private var completed: [Key: Receipt] = [:]
    private var attempted: Set<Key> = []
    private var messageIDs: Set<UUID> = []
    private var published: [Review] = []
    private var busy = false
    private var closed = false

    public init(conversationID: UUID, senderID: UUID, destinationConversationID: UUID? = nil,
                validateScope: @escaping @Sendable () async throws -> Void,
                prepareLocalImage: PrepareLocalImage? = nil,
                authorize: @escaping Authorize, commit: @escaping Commit) {
        self.conversationID = conversationID; self.senderID = senderID
        self.destinationConversationID = destinationConversationID ?? conversationID
        self.validateScope = validateScope; self.prepareLocalImage = prepareLocalImage
        self.authorize = authorize; self.commit = commit
    }
    public func close() { closed = true }

    public nonisolated var supportsLocalImages: Bool { prepareLocalImage != nil }

    public func prepareLocal(url: String, altText: String?, call: NormalizedToolCall,
                             context: ToolContext) async throws -> PreparedAgentGalleryImage {
        guard context.conversationID == conversationID, call.name == "SendMessage",
              let prepareLocalImage else { throw Failure.unavailable }
        try await checkScope()
        let image = try await prepareLocalImage(url, altText, call, context)
        try await checkScope()
        return image
    }

    public func publish(text: String, gallery: RemoteImageGallery, replyTo: UUID?,
                        call: NormalizedToolCall, context: ToolContext) async throws -> Receipt {
        try await publish(text: text, images: gallery.images.map(Image.remote), replyTo: replyTo,
            call: call, context: context)
    }

    public func publish(text: String, images: [Image], replyTo: UUID?,
                        call: NormalizedToolCall, context: ToolContext) async throws -> Receipt {
        guard context.conversationID == conversationID, call.name == "SendMessage" else { throw Failure.unavailable }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 8_000, text.utf8.count <= 32_000 else { throw Failure.invalidText }
        guard !images.isEmpty,
              images.reduce(0, { total, image in
                  if case let .local(local) = image { return total + local.file.bytes.count }
                  return total
              }) <= AgentImageStore.maximumGalleryBytes else { throw Failure.invalidGallery }
        let remoteReferences = images.compactMap { image -> RemoteAttachmentReference? in
            if case let .remote(reference) = image { return reference }
            return nil
        }
        let gallery = remoteReferences.isEmpty ? nil : try RemoteImageGallery(images: remoteReferences)
        let key = Key(run: context.runID, call: call.id)
        let review = Review(conversationID: destinationConversationID, senderID: senderID,
            text: text, images: images, replyTo: replyTo)
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
        let expectedLocal = review.localImages
        let actualLocal = message.images ?? []
        let localMatches = expectedLocal.count == actualLocal.count && zip(expectedLocal, actualLocal).allSatisfy { prepared, metadata in
            metadata.id == prepared.file.digest && metadata.filename == prepared.file.filename
                && metadata.mimeType == prepared.mimeType && metadata.byteCount == prepared.file.bytes.count
                && metadata.kind == .image && metadata.altText == prepared.altText
        }
        guard receipt.review == review, !messageIDs.contains(message.id),
              message.groupID == review.conversationID, message.senderID == review.senderID,
              message.text == review.text, message.remoteImages == gallery,
              localMatches, message.imageGalleryLayout == review.layout,
              message.replyToMessageID == review.replyTo, message.remoteAttachment == nil,
              (message.files ?? []).isEmpty,
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
