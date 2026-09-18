import Foundation
import ImageIO
import Darwin
import FiliconDomain

public enum AgentImageError: String, LocalizedError, Sendable {
    case invalid = "Choose a valid, single-frame PNG or JPEG image."
    case limit = "Use at most 4 images, 5 MB each and 12 MB total."
    case unavailable = "This image is not available in the current peer message."
    case unsupported = "The recipient model does not support image input. No image was sent to the model."
    case group = "Forwarding images to a group with SendToAgent is not supported."
    public var errorDescription: String? { rawValue }
}

/// Separate, immutable mailbox blobs. No arbitrary model URL/path reads; the
/// host imports files explicitly selected by the user and tools pass IDs only.
public actor AgentImageStore {
    public static let maximumBytes = 5 * 1_024 * 1_024
    private let store: AttachmentStore
    public init(rootURL: URL) { store = AttachmentStore(rootURL: rootURL) }

    public func importImage(fileURL: URL) async throws -> AttachmentMetadata {
        guard fileURL.isFileURL else { throw AgentImageError.invalid }
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        let fd = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AgentImageError.invalid }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw AgentImageError.invalid }
        guard info.st_size > 0, info.st_size <= Self.maximumBytes else { throw AgentImageError.limit }
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        try Task.checkCancellation()
        return try await importImage(data: bytes, filename: fileURL.lastPathComponent)
    }

    public func importImage(data: Data, filename: String) async throws -> AttachmentMetadata {
        let mime = try Self.validate(data)
        try Task.checkCancellation()
        return try await store.ingest(data: data, filename: filename, declaredMIMEType: mime)
    }

    public func load(_ images: [AttachmentMetadata]) async throws -> [InferenceAttachment] {
        guard images.count <= 4, Set(images.map(\.id)).count == images.count,
              images.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= Self.maximumBytes }),
              images.reduce(Int64(0), { $0 + $1.byteCount }) <= 12 * 1_024 * 1_024 else { throw AgentImageError.limit }
        var result: [InferenceAttachment] = []
        for image in images {
            try Task.checkCancellation()
            guard image.kind == .image else { throw AgentImageError.invalid }
            let bytes = try await store.data(for: image)
            guard try Self.validate(bytes) == image.mimeType else { throw AgentImageError.invalid }
            result.append(.init(metadata: image, data: bytes))
        }
        try Task.checkCancellation()
        return result
    }

    private static func validate(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumBytes else { throw AgentImageError.limit }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?, ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 8_192, height <= 8_192, width * height <= 16_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw AgentImageError.invalid }
        return type == "public.png" ? "image/png" : "image/jpeg"
    }
}
