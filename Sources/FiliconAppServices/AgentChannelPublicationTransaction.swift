import Foundation
import FiliconAgents
import FiliconChannels
import FiliconDomain

/// Parsed model intent, not a connection, account, source-access grant or consent.
/// The reference channel contract sends only the first URL image with the text
/// as its caption. The complete intent is retained for review and call replay.
public struct AgentChannelMessage: Sendable, Equatable {
    public let address: ChannelAddress
    public let text: String
    public let images: [AgentMessageImageInput]
    public let attachment: AgentMessageImageInput?
    public var source: AgentMessageImageInput? { attachment ?? images.first }
    public var discardedImageCount: Int { max(0, images.count - 1) }
    public var isImage: Bool { attachment == nil && !images.isEmpty }

    public static func parse(_ object: [String: Any]) throws -> Self {
        guard let channel = object["channel"] as? String, channel.utf8.count <= 1_024,
              let separator = channel.firstIndex(of: ":"),
              let type = object["type"] as? String, ["text", "attachment"].contains(type) else {
            throw ChannelPublicationError.invalid
        }
        let platform = channel[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let channelID = channel[channel.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["slack", "discord"].contains(platform), !channelID.isEmpty, channelID.utf8.count <= 512,
              !channelID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ChannelPublicationError.invalid
        }
        let address = ChannelAddress(platform: platform, channelID: channelID)
        if type == "attachment" {
            guard Set(object.keys).isSubset(of: ["type", "channel", "url", "alt", "reply_to"]),
                  let url = object["url"] as? String else { throw ChannelPublicationError.invalid }
            var entry: [String: Any] = ["url": url]
            if let alt = object["alt"] { entry["alt"] = alt }
            let source = try AgentMessageImageInput(entry: entry)
            return .init(address: address, text: source.alt ?? "", images: [], attachment: source)
        }
        guard Set(object.keys).isSubset(of: ["type", "channel", "content", "images", "reply_to"]),
              let content = object["content"] as? String, content.count <= 8_000,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChannelPublicationError.invalid
        }
        let images: [AgentMessageImageInput]
        if let raw = object["images"] {
            guard let entries = raw as? [[String: Any]], entries.count <= 64 else { throw ChannelPublicationError.invalid }
            images = try entries.map { entry in
                let input = try AgentMessageImageInput(entry: entry)
                guard case .hostImage = input.source else { return input }
                throw ChannelPublicationError.invalid
            }
        } else { images = [] }
        return .init(address: address, text: content.trimmingCharacters(in: .whitespacesAndNewlines),
                     images: images, attachment: nil)
    }
}

/// Immutable bytes prepared by an independently authorized host source reader.
public struct PreparedAgentChannelAttachment: Sendable, Equatable {
    public let file: PreparedAgentPublicationFile
    public let mimeType: String
    public var metadata: ChannelAttachment {
        .init(blobID: file.digest, filename: file.filename, mimeType: mimeType, byteCount: Int64(file.bytes.count))
    }
    public init(file: PreparedAgentPublicationFile, mimeType: String) throws {
        guard file.bytes.count <= 25 * 1_024 * 1_024 else { throw ChannelPublicationError.invalid }
        let mime = mimeType.lowercased()
        guard mime.utf8.count <= 128,
              mime.range(of: "^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$", options: .regularExpression) != nil,
              mime.hasPrefix("image/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/")
                || mime.hasPrefix("text/") || ["application/pdf", "application/json", "application/zip", "application/octet-stream"].contains(mime) else {
            throw ChannelPublicationError.invalid
        }
        self.file = file; self.mimeType = mime
    }
}

/// One host-bound SendMessage destination capability. Approval covers the exact
/// queue proposal and captured bytes. It never sends a network request itself.
public actor AgentChannelPublicationTransaction {
    public struct Review: Sendable, Equatable {
        public let conversationID: UUID
        public let senderID: UUID
        public let message: AgentChannelMessage
        public let publication: ChannelPublication
        /// A local transcript quote, never an external platform thread ID.
        public let replyTo: UUID?
        public let attachment: PreparedAgentChannelAttachment?
    }
    public struct Receipt: Sendable, Equatable {
        public let review: Review
        public let delivery: ChannelDelivery
    }
    public enum Failure: String, LocalizedError, Sendable, Equatable {
        case unavailable = "Channel publication is not available in this host context. Nothing new was queued."
        case busy = "A channel publication is already being reviewed."
        case duplicateCall = "That call identity or payload already belongs to another publication. Do not resend it."
        case uncertainCommit = "That publication attempt has no confirmed receipt. Inspect the channel queue before retrying; do not resend automatically."
        case invalidAttachment = "The host did not install the exact reviewed attachment. Nothing was queued."
        public var errorDescription: String? { rawValue }
    }
    public typealias Prepare = @Sendable (AgentMessageImageInput, Bool, NormalizedToolCall, ToolContext) async throws -> PreparedAgentChannelAttachment
    public typealias Authorize = @Sendable (Review, NormalizedToolCall, ToolContext) async throws -> Void
    public typealias Install = @Sendable (PreparedAgentChannelAttachment) async throws -> ChannelAttachment
    public nonisolated let conversationID: UUID
    public nonisolated let senderID: UUID
    public nonisolated let agentID: UUID
    public nonisolated let supportsAttachments: Bool
    public nonisolated let supportsRemoteSources: Bool
    private nonisolated let lifetime: ChannelPublicationLifetime
    private let accountID: String
    private let channels: ChannelService
    private let validateScope: @Sendable () async throws -> Void
    private let prepare: Prepare?
    private let install: Install?
    private let authorize: Authorize
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> Date
    private struct Key: Hashable { let run: UUID; let call: ToolCallID }
    private struct Input: Equatable { let message: AgentChannelMessage; let replyTo: UUID? }
    private struct Completed { let input: Input; let receipt: Receipt }
    private struct Fingerprint: Hashable { let address: ChannelAddress; let outbound: ChannelOutbound }
    private var completed: [Key: Completed] = [:]
    private var attempted: Set<Key> = []
    private var published: Set<Fingerprint> = []
    private var usedIDs: Set<UUID> = []
    private var busy = false

    public init(conversationID: UUID, senderID: UUID, agentID: UUID, accountID: String,
                channels: ChannelService, lifetime: ChannelPublicationLifetime = .init(),
                validateScope: @escaping @Sendable () async throws -> Void,
                authorize: @escaping Authorize, prepare: Prepare? = nil, install: Install? = nil,
                supportsRemoteSources: Bool = false,
                makeID: @escaping @Sendable () -> UUID = { UUID() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.conversationID = conversationID; self.senderID = senderID; self.agentID = agentID
        self.accountID = accountID; self.channels = channels; self.lifetime = lifetime
        self.validateScope = validateScope; self.authorize = authorize
        supportsAttachments = prepare != nil && install != nil
        self.supportsRemoteSources = supportsAttachments && supportsRemoteSources
        self.prepare = supportsAttachments ? prepare : nil; self.install = supportsAttachments ? install : nil
        self.makeID = makeID; self.now = now
    }

    /// Synchronous Stop fence, including while this actor waits for approval.
    public nonisolated func close() { lifetime.close() }

    public func publish(_ message: AgentChannelMessage, replyTo: UUID?, call: NormalizedToolCall,
                        context: ToolContext) async throws -> Receipt {
        guard call.name == "SendMessage", context.conversationID == conversationID else { throw Failure.unavailable }
        let key = Key(run: context.runID, call: call.id), input = Input(message: message, replyTo: replyTo)
        if let previous = completed[key] {
            guard previous.input == input else { throw Failure.duplicateCall }
            return previous.receipt
        }
        guard !attempted.contains(key) else { throw Failure.uncertainCommit }
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        try await checkScope()
        // Resolve ownership before source reads. Neither a model address nor a
        // source approval can create a connection or use another agent's token.
        _ = try await channels.proposePublication(agentID: agentID, accountID: accountID,
            outbound: .init(text: message.text.isEmpty ? "Attachment" : message.text), to: message.address,
            requiresAttachments: message.source != nil)
        try await checkScope()
        let attachment: PreparedAgentChannelAttachment?
        if let source = message.source {
            guard let prepare, install != nil else { throw Failure.unavailable }
            if case .remote = source.source { guard supportsRemoteSources else { throw Failure.unavailable } }
            attachment = try await prepare(source, message.isImage, call, context)
            if message.isImage, let attachment {
                guard try AgentImageStore.validatePublishedImage(attachment.file.bytes) == attachment.mimeType else {
                    throw Failure.invalidAttachment
                }
            }
            try await checkScope()
        } else { attachment = nil }
        let publication = try await channels.proposePublication(agentID: agentID, accountID: accountID,
            outbound: .init(text: message.text, attachments: attachment.map { [$0.metadata] } ?? []), to: message.address)
        let fingerprint = Fingerprint(address: publication.address, outbound: publication.outbound)
        guard !published.contains(fingerprint) else { throw Failure.duplicateCall }
        let review = Review(conversationID: conversationID, senderID: senderID, message: message,
                            publication: publication, replyTo: replyTo, attachment: attachment)
        try await authorize(review, call, context)
        try await checkScope()
        if let attachment {
            guard let install, try await install(attachment) == attachment.metadata else { throw Failure.invalidAttachment }
            try await checkScope()
        }
        let id = makeID()
        guard usedIDs.insert(id).inserted else { throw Failure.duplicateCall }
        attempted.insert(key)
        let delivery = try await channels.enqueueApprovedPublication(publication, lifetime: lifetime,
            idempotencyKey: id, at: now())
        let receipt = Receipt(review: review, delivery: delivery)
        completed[key] = .init(input: input, receipt: receipt)
        published.insert(fingerprint)
        // No post-save cancellation check: the durable queue receipt is the
        // truth even if Stop/account transition arrived during the save.
        return receipt
    }

    private func checkScope() async throws {
        try lifetime.check()
        try await validateScope()
        try lifetime.check()
    }
}
