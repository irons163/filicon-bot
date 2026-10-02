import Foundation
import ImageIO
import Darwin
import FiliconDomain

public enum AgentImageError: String, LocalizedError, Sendable {
    case invalid = "Choose a valid, single-frame PNG or JPEG image."
    case limit = "Use at most 4 images, 5 MB each and 12 MB total."
    case galleryLimit = "Use images up to 5 MB each and 12 MB total."
    case unavailable = "This image is not available in the current request."
    case unsupported = "The recipient model does not support image input. No image was sent to the model."
    case group = "Forwarding images to a group with SendToAgent is not supported."
    public var errorDescription: String? { rawValue }
}

/// Separate, immutable mailbox blobs. No arbitrary model URL/path reads; the
/// host imports files explicitly selected by the user and tools pass IDs only.
public actor AgentImageStore {
    public static let maximumBytes = 5 * 1_024 * 1_024
    public static let maximumGalleryBytes = 12 * 1_024 * 1_024
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

    public func storageInventory() async throws -> AttachmentStoreInventory {
        try await store.inventory()
    }

    /// Installs a reviewed snapshot using descriptor-relative, exclusive CAS
    /// creation. A shard/blob symlink or a corrupt existing blob cannot be reused.
    /// The host must reserve quota before calling this method.
    public func importCapturedGalleryImage(_ prepared: PreparedAgentGalleryImage,
        createdAt: Date = Date()) async throws -> AttachmentMetadata {
        guard try Self.validate(prepared.file.bytes) == prepared.mimeType else { throw AgentImageError.invalid }
        let installed = try await store.ingest(prepared: prepared.file, createdAt: createdAt,
            verifiedImageMIMEType: prepared.mimeType)
        // Image type comes from decoded bytes, not a potentially misleading
        // workspace filename. No unverified document is promoted to an image.
        return .init(id: installed.id, filename: installed.filename, mimeType: prepared.mimeType,
            byteCount: installed.byteCount, kind: .image, createdAt: installed.createdAt, altText: prepared.altText)
    }

    public func load(_ images: [AttachmentMetadata]) async throws -> [InferenceAttachment] {
        guard images.count <= 4 else { throw AgentImageError.limit }
        return try await loadVerifiedImages(images, limitError: .limit, allowsRepeatedSources: false)
    }

    /// Human-visible, host-reviewed publication only. Callers must validate the
    /// exact saved gallery layout and account scope. This is not a capability to
    /// pass more images into an inference request or a SendToAgent delivery.
    public func loadPublishedGallery(_ images: [AttachmentMetadata]) async throws -> [InferenceAttachment] {
        try await loadVerifiedImages(images, limitError: .galleryLimit, allowsRepeatedSources: true)
    }

    public nonisolated static func validatePublishedGalleryMetadata(_ images: [AttachmentMetadata]) throws {
        try validateMetadata(images, limitError: .galleryLimit, allowsRepeatedSources: true)
    }

    private nonisolated static func validateMetadata(_ images: [AttachmentMetadata], limitError: AgentImageError,
                                                    allowsRepeatedSources: Bool) throws {
        guard allowsRepeatedSources || Set(images.map(\.id)).count == images.count else { throw limitError }
        var remaining = Int64(Self.maximumGalleryBytes)
        var sources: [String: AttachmentMetadata] = [:]
        for image in images {
            guard image.byteCount > 0, image.byteCount <= Self.maximumBytes,
                  image.byteCount <= remaining else { throw limitError }
            remaining -= image.byteCount
            // Captions/names are occurrence-local; content size and decoded
            // MIME cannot disagree for the same content-addressed source.
            if let previous = sources[image.id],
               previous.byteCount != image.byteCount || previous.mimeType != image.mimeType {
                throw AgentImageError.invalid
            }
            sources[image.id] = image
        }
        guard images.allSatisfy({ $0.kind == .image }) else { throw AgentImageError.invalid }
    }

    private func loadVerifiedImages(_ images: [AttachmentMetadata], limitError: AgentImageError,
                                    allowsRepeatedSources: Bool) async throws -> [InferenceAttachment] {
        try Self.validateMetadata(images, limitError: limitError, allowsRepeatedSources: allowsRepeatedSources)
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

    /// Bounded display bytes, not a replacement for the original CAS image.
    /// Actor isolation keeps the potentially expensive decode off the UI actor.
    public func thumbnail(for image: AttachmentMetadata, maximumDimension: Int = 640) async throws -> Data {
        guard (1...1_024).contains(maximumDimension) else { throw AgentImageError.invalid }
        let original = try await load([image])
        try Task.checkCancellation()
        guard let bytes = original.first?.data,
              let source = CGImageSourceCreateWithData(bytes as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: false
              ] as CFDictionary),
              thumbnail.width > 0, thumbnail.height > 0,
              thumbnail.width <= maximumDimension, thumbnail.height <= maximumDimension else { throw AgentImageError.invalid }
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw AgentImageError.invalid
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentImageError.invalid }
        try Task.checkCancellation()
        return data as Data
    }

    public static func validate(_ data: Data) throws -> String {
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
