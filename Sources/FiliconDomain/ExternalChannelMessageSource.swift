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
    public static let supportedMIMETypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]
    public static let maximumCount = 4
    public static let maximumBytes: Int64 = 5 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 12 * 1_024 * 1_024
    public static let maximumImageDimension = 8_192
    public static let maximumImagePixels = 16_000_000

    /// A header bound, not image validation. ImageIO can report the smaller
    /// frame size for an oversized GIF logical screen, so check both before
    /// decoding. Callers must still fully decode and reject multiple frames.
    public static func hasBoundedGIFLogicalScreen(_ data: Data) -> Bool {
        let header = [UInt8](data.prefix(10))
        guard header.count == 10,
              header.prefix(6).elementsEqual("GIF87a".utf8)
                || header.prefix(6).elementsEqual("GIF89a".utf8) else { return false }
        let width = Int(header[6]) | Int(header[7]) << 8
        let height = Int(header[8]) | Int(header[9]) << 8
        return width > 0 && height > 0 && width <= maximumImageDimension
            && height <= maximumImageDimension && width * height <= maximumImagePixels
    }

    /// Container/frame header bounds, not image validation. Check both the
    /// extended canvas and bitstream dimensions before ImageIO decodes pixels.
    /// This input path rejects animation (even one ANMF frame), partial chunks
    /// and trailing bytes; callers must still fully decode exactly one image.
    public static func hasBoundedStaticWebP(_ data: Data) -> Bool {
        guard data.count >= 20, data.count <= maximumBytes else { return false }
        return data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            func littleEndian(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << ($1 * 8) }
            }
            func bounded(_ width: Int, _ height: Int) -> Bool {
                width > 0 && height > 0 && width <= maximumImageDimension
                    && height <= maximumImageDimension && width * height <= maximumImagePixels
            }
            let lossy = 0x20385056, lossless = 0x4c385056, extended = 0x58385056 // VP8 / VP8L / VP8X
            guard littleEndian(0, 4) == 0x46464952, littleEndian(8, 4) == 0x50424557, // RIFF / WEBP
                  littleEndian(4, 4) == bytes.count - 8,
                  [lossy, lossless, extended].contains(littleEndian(12, 4)) else { return false }
            var offset = 12, hasImage = false
            while offset < bytes.count {
                guard bytes.count - offset >= 8 else { return false }
                let tag = littleEndian(offset, 4), size = littleEndian(offset + 4, 4), payload = offset + 8
                guard size <= bytes.count - payload else { return false }
                switch tag {
                case extended:
                    guard offset == 12, size == 10, bytes[payload] & 0x02 == 0,
                          bounded(littleEndian(payload + 4, 3) + 1, littleEndian(payload + 7, 3) + 1) else { return false }
                case lossy:
                    guard !hasImage, size >= 10, bytes[payload + 3] == 0x9d,
                          bytes[payload + 4] == 0x01, bytes[payload + 5] == 0x2a,
                          bounded(littleEndian(payload + 6, 2) & 0x3fff,
                              littleEndian(payload + 8, 2) & 0x3fff) else { return false }
                    hasImage = true
                case lossless:
                    guard !hasImage, size >= 5, bytes[payload] == 0x2f else { return false }
                    let dimensions = littleEndian(payload + 1, 4)
                    guard bounded((dimensions & 0x3fff) + 1, ((dimensions >> 14) & 0x3fff) + 1) else { return false }
                    hasImage = true
                case 0x4d494e41, 0x464d4e41: return false // ANIM / ANMF, even without the animation flag
                default: break // ImageIO validates remaining image/metadata chunks.
                }
                let paddedSize = size + (size & 1)
                guard paddedSize <= bytes.count - payload,
                      size & 1 == 0 || bytes[payload + size] == 0 else { return false }
                offset = payload + paddedSize
            }
            return hasImage
        }
    }

    public static func accepts(_ images: [AttachmentMetadata], receivedAt: Date) -> Bool {
        guard images.count <= maximumCount, Set(images.map(\.id)).count == images.count else { return false }
        var remaining = maximumTotalBytes
        for image in images {
            guard image.id.utf8.count == 64,
                  image.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  image.kind == .image, supportedMIMETypes.contains(image.mimeType),
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
