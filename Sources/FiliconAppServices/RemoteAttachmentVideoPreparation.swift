import AVFoundation
import CryptoKit
import Foundation
import FiliconDomain

public enum RemoteAttachmentVideoError: Error, Equatable, Sendable {
    case unsupported
    case boundsExceeded
}

/// Local, self-contained ISO media only. Playlists and external media references
/// are not download capabilities and must never be followed by the parser.
public enum RemoteAttachmentVideoPreparation {
    public static let maximumBytes = 200 * 1_024 * 1_024

    public static func isCandidate(_ data: Data) -> Bool {
        guard data.count >= 12, data.subdata(in: 4..<8) == Data("ftyp".utf8) else { return false }
        // HEIF images share the ISO container header; preserve their image path.
        let imageBrands = ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"]
        return !imageBrands.contains(String(decoding: data.subdata(in: 8..<12), as: UTF8.self))
    }

    public static func metadata(for data: Data, reference: RemoteAttachmentReference,
                                createdAt: Date = Date()) async throws -> AttachmentMetadata {
        try Task.checkCancellation()
        guard isCandidate(data) else { throw RemoteAttachmentVideoError.unsupported }
        guard data.count <= maximumBytes else { throw RemoteAttachmentVideoError.boundsExceeded }
        let directory = FileManager.default.temporaryDirectory.appending(path: "FiliconMediaCheck-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let quickTime = data.subdata(in: 8..<12) == Data("qt  ".utf8)
        let url = directory.appending(path: quickTime ? "media.mov" : "media.mp4")
        try data.write(to: url, options: .withoutOverwriting)
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        defer { asset.cancelLoading() }
        return try await withTaskCancellationHandler {
        guard try await asset.load(.isPlayable) else { throw RemoteAttachmentVideoError.unsupported }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= 86_400 else { throw RemoteAttachmentVideoError.boundsExceeded }
        let tracks = try await asset.load(.tracks)
        guard !tracks.isEmpty, tracks.count <= 16 else { throw RemoteAttachmentVideoError.boundsExceeded }
        var hasVideo = false
        var hasAudio = false
        for track in tracks {
            try Task.checkCancellation()
            if track.mediaType == .video {
                hasVideo = true
                let size = try await track.load(.naturalSize)
                guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                      size.width <= 16_384, size.height <= 16_384,
                      size.width * size.height <= 64_000_000 else { throw RemoteAttachmentVideoError.boundsExceeded }
            } else if track.mediaType == .audio { hasAudio = true }
        }
        try Task.checkCancellation()
        guard hasVideo || hasAudio else { throw RemoteAttachmentVideoError.unsupported }
        let filename = quickTime ? "remote-media.mov" : hasVideo ? "remote-media.mp4" : "remote-media.m4a"
        let mime = quickTime ? "video/quicktime" : hasVideo ? "video/mp4" : "audio/mp4"
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AttachmentMetadata(id: digest, filename: filename, mimeType: mime, byteCount: Int64(data.count),
            kind: hasVideo ? .video : .audio, createdAt: createdAt, altText: reference.alt)
        } onCancel: {
            asset.cancelLoading()
        }
    }
}
