import Foundation

/// Display-only provenance for an accepted remote human message. No credential,
/// configuration fence, local human permission, or delivery consent is encoded.
public struct ExternalChannelMessageSource: Codable, Hashable, Sendable {
    public let connectionID: UUID
    public let externalEventID: String
    public let owner: DirectConversationAgentBinding
    public let conversationID: UUID
    public let platform: String
    public let channelID: String
    public let threadID: String?
    public let senderID: String
    public let senderName: String
    public let receivedAt: Date

    public init(connectionID: UUID, externalEventID: String, owner: DirectConversationAgentBinding,
                conversationID: UUID, platform: String, channelID: String, threadID: String?,
                senderID: String, senderName: String, receivedAt: Date) {
        self.connectionID = connectionID; self.externalEventID = externalEventID; self.owner = owner
        self.conversationID = conversationID; self.platform = platform; self.channelID = channelID
        self.threadID = threadID; self.senderID = senderID; self.senderName = senderName
        self.receivedAt = Date(timeIntervalSince1970: (receivedAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
    public var envelopeID: String { "\(connectionID.uuidString):\(externalEventID)" }
    public var address: String { "\(platform):\(channelID)" + (threadID.map { ":\($0)" } ?? "") }
    public var isValid: Bool {
        ["slack", "discord"].contains(platform) && receivedAt.timeIntervalSince1970.isFinite
            && Self.label(owner.accountID, limit: 256) && Self.label(externalEventID, limit: 2_048)
            && Self.label(channelID, limit: 512) && (threadID.map { Self.label($0, limit: 512) } ?? true)
            && Self.label(senderID, limit: 512) && Self.label(senderName, limit: 8_000)
    }
    private static func label(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit
            && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

/// Display metadata for a bounded, current remote image batch. Passing this
/// shape check does not admit a blob read, an inference or a publication.
public enum ExternalChannelImagePolicy {
    public static let maximumCount = 4
    public static let maximumBytes: Int64 = 5 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 12 * 1_024 * 1_024

    public static func accepts(_ images: [AttachmentMetadata], receivedAt: Date) -> Bool {
        guard images.count <= maximumCount, Set(images.map(\.id)).count == images.count else { return false }
        var remaining = maximumTotalBytes
        for image in images {
            guard image.id.utf8.count == 64,
                  image.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  image.kind == .image, ["image/png", "image/jpeg"].contains(image.mimeType),
                  image.byteCount > 0, image.byteCount <= maximumBytes, image.byteCount <= remaining,
                  image.createdAt == receivedAt, image.altText == nil,
                  !image.filename.isEmpty, image.filename != ".", image.filename != "..",
                  image.filename.utf8.count <= 255, !image.filename.contains("/"), !image.filename.contains("\\"),
                  !image.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
            remaining -= image.byteCount
        }
        return true
    }
}

extension ChatMessage {
    /// Stored provenance must not be downgraded into a local human instruction.
    public var hasValidExternalChannelSource: Bool {
        guard let source = externalChannelSource else { return true }
        return source.isValid && role == .user && agentMessageSource == nil
            && createdAt == source.receivedAt && deliveryStatus == .succeeded && deliveryError == nil
            && text.count <= 8_000 && ExternalChannelImagePolicy.accepts(attachments, receivedAt: source.receivedAt)
            && toolActivities.isEmpty && transcriptCards.isEmpty
            && reasoningText.isEmpty && remoteAttachment == nil && remoteImages == nil && imageGalleryLayout == nil
    }
}
