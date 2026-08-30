import Foundation

public enum AttachmentKind: String, Codable, Hashable, Sendable {
    case image
    case video
    case audio
    case document
    case other
}

public struct AttachmentMetadata: Identifiable, Codable, Hashable, Sendable {
    /// Lowercase SHA-256 of the stored bytes.
    public let id: String
    public let filename: String
    public let mimeType: String
    public let byteCount: Int64
    public let kind: AttachmentKind
    public let createdAt: Date

    public init(
        id: String,
        filename: String,
        mimeType: String,
        byteCount: Int64,
        kind: AttachmentKind,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.kind = kind
        self.createdAt = createdAt
    }
}

/// The durable owner of attachment bytes. A message is deliberately part of
/// the identity so deleting one message cannot release another message's use
/// of the same content-addressed blob.
public struct AttachmentReferenceOwner: Codable, Hashable, Sendable {
    public let conversationID: UUID
    public let messageID: UUID

    public init(conversationID: UUID, messageID: UUID) {
        self.conversationID = conversationID
        self.messageID = messageID
    }
}

/// An upload which has bytes on disk but is not visible to a transcript yet.
/// Commit or abort this token; tokens are intentionally opaque and restart-safe.
public struct StagedAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let metadata: AttachmentMetadata

    public init(id: UUID, metadata: AttachmentMetadata) {
        self.id = id
        self.metadata = metadata
    }
}

public struct AttachmentStorageUsage: Codable, Equatable, Sendable {
    public let activeBytes: Int64
    public let quarantinedBytes: Int64
    public let stagedBytes: Int64
    public let uniqueBlobCount: Int

    public init(activeBytes: Int64, quarantinedBytes: Int64, stagedBytes: Int64, uniqueBlobCount: Int) {
        self.activeBytes = activeBytes
        self.quarantinedBytes = quarantinedBytes
        self.stagedBytes = stagedBytes
        self.uniqueBlobCount = uniqueBlobCount
    }
}

public struct AttachmentReconciliationReport: Codable, Equatable, Sendable {
    public var removedTemporaryFiles: Int
    public var repairedTransitions: Int
    public var quarantinedUnindexedBlobs: Int
    public var removedMissingRecords: Int

    public init(removedTemporaryFiles: Int = 0, repairedTransitions: Int = 0, quarantinedUnindexedBlobs: Int = 0, removedMissingRecords: Int = 0) {
        self.removedTemporaryFiles = removedTemporaryFiles
        self.repairedTransitions = repairedTransitions
        self.quarantinedUnindexedBlobs = quarantinedUnindexedBlobs
        self.removedMissingRecords = removedMissingRecords
    }
}

public struct AttachmentGarbageCollectionReport: Codable, Equatable, Sendable {
    public let quarantined: Int
    public let restored: Int
    public let deleted: Int

    public init(quarantined: Int = 0, restored: Int = 0, deleted: Int = 0) {
        self.quarantined = quarantined
        self.restored = restored
        self.deleted = deleted
    }
}

public enum AttachmentLimits {
    public static let regularBytes: Int64 = 25 * 1_024 * 1_024
    public static let videoBytes: Int64 = 200 * 1_024 * 1_024

    private static let videoExtensions: Set<String> = [
        "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm",
    ]

    public static func isVideo(filename: String) -> Bool {
        videoExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    public static func byteLimit(filename: String, mimeType: String? = nil) -> Int64 {
        let declaredVideo = mimeType?.lowercased().hasPrefix("video/") == true
        return isVideo(filename: filename) || declaredVideo ? videoBytes : regularBytes
    }
}
