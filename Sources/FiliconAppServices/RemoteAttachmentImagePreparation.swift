import CryptoKit
import Foundation
import ImageIO
import FiliconDomain

public enum RemoteAttachmentImageError: Error, Equatable, Sendable {
    case byteLimit
    case unsupportedOrInvalid
    case decodeLimit
}

/// Prepares bytes for a local image preview, not model input. Never trusts the
/// URL extension or server MIME and never rewrites an animated image to a still.
public enum RemoteAttachmentImagePreparation {
    public static let maximumBytes = 32 * 1_024 * 1_024

    public static func metadata(for data: Data, reference: RemoteAttachmentReference,
                                createdAt: Date = Date()) throws -> AttachmentMetadata {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes else { throw RemoteAttachmentImageError.byteLimit }
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String? else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        let format: (extension: String, mime: String)
        switch type {
        case "public.png": format = ("png", "image/png")
        case "public.jpeg": format = ("jpg", "image/jpeg")
        case "com.compuserve.gif": format = ("gif", "image/gif")
        case "public.tiff": format = ("tiff", "image/tiff")
        case "com.microsoft.bmp": format = ("bmp", "image/bmp")
        case "org.webmproject.webp": format = ("webp", "image/webp")
        case "public.heic": format = ("heic", "image/heic")
        case "public.heif": format = ("heif", "image/heif")
        default: throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 200 else { throw RemoteAttachmentImageError.decodeLimit }
        var totalPixels = 0
        // Validate all frame dimensions before decoding even the first frame.
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 64_000_000 else { throw RemoteAttachmentImageError.decodeLimit }
            totalPixels += width * height
            guard totalPixels <= 128_000_000 else { throw RemoteAttachmentImageError.decodeLimit }
        }
        for index in 0..<count {
            try Task.checkCancellation()
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCache: false] as CFDictionary) != nil else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AttachmentMetadata(id: digest, filename: "remote-image.\(format.extension)",
            mimeType: format.mime, byteCount: Int64(data.count), kind: .image,
            createdAt: createdAt, altText: reference.alt)
    }
}
