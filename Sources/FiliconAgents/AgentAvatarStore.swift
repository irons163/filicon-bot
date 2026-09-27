import Foundation
import AppKit
import CryptoKit
import ImageIO
import Darwin

public enum AgentAvatarStoreError: LocalizedError, Equatable, Sendable {
    case fileTooLarge
    case invalidImage
    case unsafeDimensions
    case invalidCrop
    case encodingFailed
    case unsafePath

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge: "Avatar images must be smaller than 25 MB."
        case .invalidImage: "The selected file is not a supported image."
        case .unsafeDimensions: "The image dimensions are too large to decode safely."
        case .invalidCrop: "Avatar zoom must be between 1× and 5× and the focal point must be inside the image."
        case .encodingFailed: "The avatar could not be encoded as PNG."
        case .unsafePath: "The avatar store refused an unsafe path."
        }
    }
}

public struct AgentAvatarCrop: Equatable, Sendable {
    public var focusX: Double
    public var focusY: Double
    public var zoom: Double

    public init(focusX: Double = 0.5, focusY: Double = 0.5, zoom: Double = 1) {
        self.focusX = focusX; self.focusY = focusY; self.zoom = zoom
    }
}

/// Exact PNG bytes to preview and later install. Only the bounded decoder can
/// construct this value; it carries no source path to reopen after approval.
public struct PreparedAgentAvatar: Sendable, Equatable {
    public let pngData: Data
    public let avatar: AgentAvatar
    fileprivate init(pngData: Data, avatar: AgentAvatar) {
        self.pngData = pngData
        self.avatar = avatar
    }
}

/// Decodes through ImageIO, bounds the working image, and stores only a 256 px PNG in CAS.
public struct AgentAvatarStore: Sendable {
    public static let maximumInputBytes = 25 * 1_024 * 1_024
    public static let maximumDecodeDimension = 20_000
    public static let maximumDecodePixels = 100_000_000
    public static let normalizedDimension = 1_024
    public static let outputDimension = 256

    public let rootURL: URL
    public init(rootURL: URL) { self.rootURL = rootURL.standardizedFileURL }

    public func importImage(at sourceURL: URL, crop: AgentAvatarCrop, shape: AgentAvatarShape = .circle) throws -> AgentAvatar {
        let bytes = try readRegularFile(sourceURL, maximumBytes: Self.maximumInputBytes)
        return try install(prepareImage(data: bytes, crop: crop, shape: shape))
    }

    /// No disk writes. Host file authorization and model-specific limits belong
    /// to the caller; this shared manual/model codec never fetches a URL.
    public func prepareImage(data: Data, crop: AgentAvatarCrop = .init(),
                             shape: AgentAvatarShape = .circle) throws -> PreparedAgentAvatar {
        guard crop.zoom.isFinite, (1...5).contains(crop.zoom),
              crop.focusX.isFinite, crop.focusY.isFinite,
              (0...1).contains(crop.focusX), (0...1).contains(crop.focusY) else {
            throw AgentAvatarStoreError.invalidCrop
        }
        guard data.count < Self.maximumInputBytes else { throw AgentAvatarStoreError.fileTooLarge }
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { throw AgentAvatarStoreError.invalidImage }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { throw AgentAvatarStoreError.invalidImage }
        guard width <= Self.maximumDecodeDimension, height <= Self.maximumDecodeDimension,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= Self.maximumDecodePixels else { throw AgentAvatarStoreError.unsafeDimensions }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.normalizedDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let normalized = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let output = render(normalized, crop: crop) else { throw AgentAvatarStoreError.invalidImage }
        let representation = NSBitmapImageRep(cgImage: output)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            throw AgentAvatarStoreError.encodingFailed
        }
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let relativePath = "\(digest.prefix(2))/\(digest).png"
        return PreparedAgentAvatar(pngData: png, avatar: .image(hash: digest, relativePath: relativePath, shape: shape))
    }

    /// Installs only the bytes shown during approval, never a mutable source URL.
    public func install(_ prepared: PreparedAgentAvatar) throws -> AgentAvatar {
        guard let relativePath = prepared.avatar.imageRelativePath, let digest = prepared.avatar.imageHash else {
            throw AgentAvatarStoreError.invalidImage
        }
        let png = prepared.pngData
        try prepareRoot()
        let destination = try checkedURL(relativePath: relativePath, expectedHash: digest)
        try rejectSymbolicLink(at: destination.deletingLastPathComponent(), ifPresent: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rejectSymbolicLink(at: destination.deletingLastPathComponent(), ifPresent: false)
        try rejectSymbolicLink(at: destination, ifPresent: true)
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = destination.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
            do {
                try png.write(to: temporary, options: .withoutOverwriting)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if !FileManager.default.fileExists(atPath: destination.path) { throw error }
            }
        }
        // Do not silently reuse a corrupt blob or a raced replacement under a
        // legitimate CAS name. Existing users keep their reference unchanged.
        guard try readRegularFile(destination, maximumBytes: Self.maximumInputBytes) == png else {
            throw AgentAvatarStoreError.invalidImage
        }
        return prepared.avatar
    }

    public func imageURL(for avatar: AgentAvatar) -> URL? {
        guard avatar.kind == .image, let path = avatar.imageRelativePath, let hash = avatar.imageHash else { return nil }
        guard let url = try? checkedURL(relativePath: path, expectedHash: hash),
              FileManager.default.fileExists(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]))?.isRegularFile == true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true,
              (try? rejectSymbolicLink(at: rootURL, ifPresent: false)) != nil,
              (try? rejectSymbolicLink(at: url.deletingLastPathComponent(), ifPresent: false)) != nil,
              let bytes = try? readRegularFile(url, maximumBytes: Self.maximumInputBytes),
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash.lowercased() else { return nil }
        return url
    }

    private func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
        guard url.isFileURL else { throw AgentAvatarStoreError.unsafePath }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw AgentAvatarStoreError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AgentAvatarStoreError.invalidImage
        }
        guard info.st_size >= 0, info.st_size < maximumBytes else { throw AgentAvatarStoreError.fileTooLarge }
        let bytes = try handle.read(upToCount: maximumBytes) ?? Data()
        guard bytes.count < maximumBytes else { throw AgentAvatarStoreError.fileTooLarge }
        return bytes
    }

    private func checkedURL(relativePath: String, expectedHash: String) throws -> URL {
        let hash = expectedHash.lowercased()
        guard hash.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
              relativePath == "\(hash.prefix(2))/\(hash).png",
              !relativePath.hasPrefix("/"), !relativePath.split(separator: "/").contains("..") else {
            throw AgentAvatarStoreError.unsafePath
        }
        let result = rootURL.appending(path: relativePath).standardizedFileURL
        let prefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard result.path.hasPrefix(prefix) else { throw AgentAvatarStoreError.unsafePath }
        return result
    }

    private func prepareRoot() throws {
        try rejectSymbolicLink(at: rootURL, ifPresent: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try rejectSymbolicLink(at: rootURL, ifPresent: false)
    }

    private func rejectSymbolicLink(at url: URL, ifPresent: Bool) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            if ifPresent { return }
            throw AgentAvatarStoreError.unsafePath
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        if values.isSymbolicLink == true { throw AgentAvatarStoreError.unsafePath }
    }

    private func render(_ image: CGImage, crop: AgentAvatarCrop) -> CGImage? {
        let dimension = Self.outputDimension
        guard let context = CGContext(
            data: nil, width: dimension, height: dimension, bitsPerComponent: 8,
            bytesPerRow: dimension * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.clear.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: dimension, height: dimension))
        let width = Double(image.width), height = Double(image.height), output = Double(dimension)
        let baseScale = max(output / width, output / height)
        let scale = baseScale * crop.zoom
        let drawnWidth = width * scale, drawnHeight = height * scale
        let overflowX = max(0, drawnWidth - output), overflowY = max(0, drawnHeight - output)
        let originX = -overflowX * crop.focusX
        // Core Graphics has a bottom-left origin; invert the UI's top-down focal Y.
        let originY = -overflowY * (1 - crop.focusY)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: originX, y: originY, width: drawnWidth, height: drawnHeight))
        return context.makeImage()
    }
}
