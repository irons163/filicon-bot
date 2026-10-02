import CryptoKit
import Foundation
import ImageIO
import FiliconAgents
import FiliconDomain
import zlib

public enum RemoteAttachmentImageError: Error, Equatable, Sendable {
    case byteLimit
    case unsupportedOrInvalid
    case decodeLimit
}

/// Prepares bytes for a local image preview, not model input. Never trusts the
/// URL extension or server MIME and never rewrites an animated image to a still.
public enum RemoteAttachmentImagePreparation {
    public static let maximumBytes = 32 * 1_024 * 1_024
    /// The complete inline sequence, not each frame, shares this decoded-pixel
    /// budget. Long animations are downsampled further rather than dropped.
    public static let maximumInlinePixels = 8_000_000

    public struct InlineFrame: Sendable, Equatable {
        public let data: Data
        public let width: Int
        public let height: Int
        public let duration: TimeInterval
    }

    public struct InlinePreview: Sendable, Equatable {
        public let frames: [InlineFrame]
        public let original: AttachmentMetadata
        /// Complete plays; nil means forever. A multipage document is still.
        public let playCount: Int?
        public var isAnimated: Bool { frames.count > 1 }
        public var duration: TimeInterval { frames.reduce(0) { $0 + $1.duration } }

        public func frameIndex(at elapsed: TimeInterval) -> Int {
            guard isAnimated, elapsed.isFinite, elapsed > 0 else { return 0 }
            if let playCount, elapsed >= duration * Double(playCount) { return frames.count - 1 }
            let position = elapsed.truncatingRemainder(dividingBy: duration)
            var boundary: TimeInterval = 0
            for (index, frame) in frames.enumerated() {
                boundary += frame.duration
                if position < boundary { return index }
            }
            return frames.count - 1
        }

        /// Only frame boundaries wake the UI; finite sequences stop scheduling.
        public func nextFrameTime(after elapsed: TimeInterval) -> TimeInterval? {
            guard isAnimated, elapsed.isFinite else { return nil }
            if elapsed < 0 { return 0 }
            if let playCount, elapsed >= duration * Double(playCount) { return nil }
            let cycle = floor(elapsed / duration) * duration
            var boundary = cycle
            for frame in frames {
                boundary += frame.duration
                if boundary > elapsed { return boundary }
            }
            return cycle + duration + frames[0].duration
        }
    }

    /// A bounded first-frame PNG for inline display. The original bytes and their
    /// metadata remain separate, so a thumbnail never replaces an animated file.
    public struct Thumbnail: Sendable {
        public let data: Data
        public let width: Int
        public let height: Int
        public let original: AttachmentMetadata
    }

    public static func thumbnail(for data: Data, reference: RemoteAttachmentReference,
                                 maximumDimension: Int = 640, createdAt: Date = Date()) throws -> Thumbnail {
        let original = try metadata(for: data, reference: reference, createdAt: createdAt)
        return try prepareThumbnail(for: data, original: original, maximumDimension: maximumDimension)
    }

    public static func thumbnail(for data: Data, original: AttachmentMetadata,
                                 maximumDimension: Int = 640) throws -> Thumbnail {
        try validateOriginal(data, original: original)
        return try prepareThumbnail(for: data, original: original, maximumDimension: maximumDimension)
    }

    private static func prepareThumbnail(for data: Data, original: AttachmentMetadata,
                                         maximumDimension: Int) throws -> Thumbnail {
        guard (1...1_024).contains(maximumDimension) else { throw RemoteAttachmentImageError.decodeLimit }
        try Task.checkCancellation()
        if original.mimeType == "image/png", let animation = try pngAnimation(data) {
            let preview = try preparePNGAnimation(animation, original: original,
                maximumDimension: maximumDimension, firstFrameOnly: true)
            let frame = preview.frames[0]
            return Thumbnail(data: frame.data, width: frame.width, height: frame.height, original: original)
        }
        let image: CGImage
        if original.mimeType == "image/svg+xml" {
            image = try vectorForDisplay(data, maximumDimension: maximumDimension)
        } else {
            guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            image = try imageForDisplay(source, index: 0, dimension: maximumDimension,
                grayAlpha16: original.mimeType == "image/png" && hasGrayAlpha16PNGHeader(data))
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
        try Task.checkCancellation()
        return Thumbnail(data: output as Data, width: image.width, height: image.height, original: original)
    }

    /// Produces display-only PNG frames after validating the *entire* original
    /// image. GIF, APNG and WebP timing is distinct from multipage TIFF/HEIF.
    /// Nothing here downloads, writes a file or grants model image access.
    public static func inlinePreview(for data: Data, reference: RemoteAttachmentReference,
                                     maximumDimension: Int = 640, createdAt: Date = Date()) throws -> InlinePreview {
        let original = try metadata(for: data, reference: reference, createdAt: createdAt)
        return try prepareInlinePreview(for: data, original: original, maximumDimension: maximumDimension)
    }

    public static func inlinePreview(for data: Data, original: AttachmentMetadata,
                                     maximumDimension: Int = 640) throws -> InlinePreview {
        try validateOriginal(data, original: original)
        return try prepareInlinePreview(for: data, original: original, maximumDimension: maximumDimension)
    }

    private static func prepareInlinePreview(for data: Data, original: AttachmentMetadata,
                                             maximumDimension: Int) throws -> InlinePreview {
        guard (1...1_024).contains(maximumDimension) else { throw RemoteAttachmentImageError.decodeLimit }
        if original.mimeType == "image/png", let animation = try pngAnimation(data) {
            return try preparePNGAnimation(animation, original: original, maximumDimension: maximumDimension)
        }
        if original.mimeType == "image/svg+xml" {
            let thumbnail = try prepareThumbnail(for: data, original: original, maximumDimension: maximumDimension)
            return InlinePreview(frames: [.init(data: thumbnail.data, width: thumbnail.width,
                height: thumbnail.height, duration: 0)], original: original, playCount: 1)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData,
            [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        let animation = animationProperties(source: source, mime: original.mimeType)
        let count = animation == nil ? 1 : CGImageSourceGetCount(source)
        let dimension = min(maximumDimension, Int(sqrt(Double(maximumInlinePixels / count))))
        var frames: [InlineFrame] = []
        var pixels = 0
        var encodedBytes = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let image = try imageForDisplay(source, index: index, dimension: dimension,
                grayAlpha16: original.mimeType == "image/png" && hasGrayAlpha16PNGHeader(data))
            pixels += image.width * image.height
            guard pixels <= maximumInlinePixels else { throw RemoteAttachmentImageError.decodeLimit }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            encodedBytes += output.length
            guard encodedBytes <= maximumBytes else { throw RemoteAttachmentImageError.byteLimit }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let frameDuration = try animation.map { keys in
                let timing = properties?[keys.dictionary] as? [CFString: Any]
                let value = (timing?[keys.unclamped] ?? timing?[keys.delay]) as? NSNumber
                guard let value else { return 0.1 }
                let seconds = value.doubleValue
                guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else {
                    throw RemoteAttachmentImageError.decodeLimit
                }
                // Zero-delay files must not create a busy-loop schedule.
                return seconds == 0 ? 0.1 : max(0.02, seconds)
            } ?? 0
            frames.append(InlineFrame(data: output as Data, width: image.width, height: image.height,
                duration: frameDuration))
        }
        try Task.checkCancellation()
        let playCount: Int?
        if original.mimeType == "image/gif", count > 1 {
            playCount = try gifPlayCount(data)
        } else if let animation, count > 1 {
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            let values = properties?[animation.dictionary] as? [CFString: Any]
            if let value = values?[animation.loop] as? NSNumber {
                let loops = value.doubleValue
                guard loops.isFinite, loops >= 0, loops.rounded(.down) == loops, loops <= Double(UInt32.max) else {
                    throw RemoteAttachmentImageError.decodeLimit
                }
                // APNG/WebP store total plays. Zero means endless playback.
                playCount = loops == 0 ? nil : Int(loops)
            } else { playCount = 1 }
        } else { playCount = 1 }
        return InlinePreview(frames: frames, original: original, playCount: playCount)
    }

    /// Modern ImageIO normalizes NETSCAPE counts but ignores ANIMEXTS. Read the
    /// raw application blocks once, rather than adding a second "first play" or
    /// searching for a signature that might occur inside comments/pixel data.
    /// ImageIO still validates and decodes every frame; this only reads looping.
    private static func gifPlayCount(_ data: Data) throws -> Int? {
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 13,
                  bytes.prefix(6).elementsEqual("GIF89a".utf8) || bytes.prefix(6).elementsEqual("GIF87a".utf8) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            var cursor = 13
            var plays: Int? = 1
            func take(_ count: Int) throws -> Range<Int> {
                guard count >= 0, count <= bytes.count - cursor else {
                    throw RemoteAttachmentImageError.unsupportedOrInvalid
                }
                let start = cursor
                cursor += count
                return start..<cursor
            }
            func block() throws -> Range<Int>? {
                try Task.checkCancellation()
                let size = Int(bytes[try take(1).lowerBound])
                return size == 0 ? nil : try take(size)
            }
            func subblocks(readLoop: Bool = false) throws {
                while let payload = try block() {
                    if readLoop, bytes[payload.lowerBound] & 7 == 1 {
                        guard payload.count >= 3 else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                        let raw = Int(bytes[payload.lowerBound + 1]) | Int(bytes[payload.lowerBound + 2]) << 8
                        plays = raw == 0 ? nil : raw + 1
                    }
                }
            }
            if bytes[10] & 0x80 != 0 { _ = try take(3 * (1 << (Int(bytes[10] & 7) + 1))) }
            while cursor < bytes.count {
                try Task.checkCancellation()
                switch bytes[try take(1).lowerBound] {
                case 0x3b: return plays // The trailer ends the GIF stream.
                case 0x00: continue // Padding accepted by the native decoder.
                case 0x21:
                    let label = bytes[try take(1).lowerBound]
                    guard let header = try block() else { continue }
                    let application = bytes[header]
                    let readLoop = label == 0xff && header.count == 11 &&
                        (application.elementsEqual("NETSCAPE2.0".utf8) || application.elementsEqual("ANIMEXTS1.0".utf8))
                    try subblocks(readLoop: readLoop)
                case 0x2c:
                    let descriptor = try take(9)
                    let flags = bytes[descriptor.lowerBound + 8]
                    if flags & 0x80 != 0 { _ = try take(3 * (1 << (Int(flags & 7) + 1))) }
                    _ = try take(1) // LZW minimum code size; payload stays with ImageIO.
                    try subblocks()
                default: throw RemoteAttachmentImageError.unsupportedOrInvalid
                }
            }
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
    }

    private struct AnimationKeys {
        let dictionary: CFString
        let delay: CFString
        let unclamped: CFString
        let loop: CFString
    }

    private static func animationProperties(source: CGImageSource, mime: String) -> AnimationKeys? {
        guard CGImageSourceGetCount(source) > 1 else { return nil }
        switch mime {
        case "image/gif":
            return AnimationKeys(dictionary: kCGImagePropertyGIFDictionary,
                delay: kCGImagePropertyGIFDelayTime, unclamped: kCGImagePropertyGIFUnclampedDelayTime,
                loop: kCGImagePropertyGIFLoopCount)
        case "image/png":
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            guard png?[kCGImagePropertyAPNGDelayTime] != nil || png?[kCGImagePropertyAPNGUnclampedDelayTime] != nil else { return nil }
            return AnimationKeys(dictionary: kCGImagePropertyPNGDictionary,
                delay: kCGImagePropertyAPNGDelayTime, unclamped: kCGImagePropertyAPNGUnclampedDelayTime,
                loop: kCGImagePropertyAPNGLoopCount)
        case "image/webp":
            return AnimationKeys(dictionary: kCGImagePropertyWebPDictionary,
                delay: kCGImagePropertyWebPDelayTime, unclamped: kCGImagePropertyWebPUnclampedDelayTime,
                loop: kCGImagePropertyWebPLoopCount)
        default: return nil
        }
    }

    public static func metadata(for data: Data, reference: RemoteAttachmentReference,
                                createdAt: Date = Date()) throws -> AttachmentMetadata {
        try verifiedMetadata(for: data, filename: nil, altText: reference.alt, createdAt: createdAt)
    }

    public static func metadata(for data: Data, filename: String, altText: String? = nil,
                                createdAt: Date = Date()) throws -> AttachmentMetadata {
        try verifiedMetadata(for: data, filename: filename, altText: altText, createdAt: createdAt)
    }

    private static func validateOriginal(_ data: Data, original: AttachmentMetadata) throws {
        let actual = try metadata(for: data, filename: original.filename,
            altText: original.altText, createdAt: original.createdAt)
        guard original == actual else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
    }

    private static func verifiedMetadata(for data: Data, filename: String?, altText: String?,
                                         createdAt: Date) throws -> AttachmentMetadata {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= maximumBytes else { throw RemoteAttachmentImageError.byteLimit }
        if StaticSVGImagePreparation.isXML(data) {
            _ = try vectorForDisplay(data, maximumDimension: 1_024)
            return makeMetadata(for: data, format: ("svg", "image/svg+xml"), filename: filename,
                altText: altText, createdAt: createdAt)
        }
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
        case "public.avif": format = ("avif", "image/avif")
        case "com.microsoft.ico": format = ("ico", "image/x-icon")
        case "public.heic": format = ("heic", "image/heic")
        case "public.heif": format = ("heif", "image/heif")
        default: throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        if type == "public.png", let animation = try pngAnimation(data) {
            try validatePNGAnimation(animation)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
        guard count <= 200 else { throw RemoteAttachmentImageError.decodeLimit }
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
        return makeMetadata(for: data, format: format, filename: filename, altText: altText, createdAt: createdAt)
    }

    private static func vectorForDisplay(_ data: Data, maximumDimension: Int) throws -> CGImage {
        guard data.count <= StaticSVGImagePreparation.maximumSourceBytes else { throw RemoteAttachmentImageError.byteLimit }
        try Task.checkCancellation()
        do {
            let image = try StaticSVGImagePreparation.image(for: data, maximumDimension: maximumDimension)
            try Task.checkCancellation()
            return image
        } catch is CancellationError { throw CancellationError() }
        catch AgentAvatarStoreError.unsafeDimensions { throw RemoteAttachmentImageError.decodeLimit }
        catch { throw RemoteAttachmentImageError.unsupportedOrInvalid }
    }

    private static func makeMetadata(for data: Data, format: (extension: String, mime: String),
        filename: String?, altText: String?, createdAt: Date) -> AttachmentMetadata {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AttachmentMetadata(id: digest, filename: filename ?? "remote-image.\(format.extension)",
            mimeType: format.mime, byteCount: Int64(data.count), kind: .image,
            createdAt: createdAt, altText: altText)
    }

    private struct PNGFrame {
        let width: Int
        let height: Int
        let x: Int
        let y: Int
        let dispose: UInt8
        let blend: UInt8
        let duration: TimeInterval
        var compressed = Data()
    }

    private struct PNGAnimation {
        let header: Data
        let width: Int
        let height: Int
        let plays: Int
        let sharedChunks: Data
        let fallback: Data
        let frames: [PNGFrame]
        let orientation: Int
    }

    private static func pngAnimation(_ data: Data) throws -> PNGAnimation? {
        let data = data.startIndex == 0 ? data : Data(data)
        // Locate animation control without copying ordinary PNG metadata chunks.
        var scan = 8
        var animated = false
        while scan + 12 <= data.count {
            try Task.checkCancellation()
            let length = pngInteger(data, scan)
            guard length <= data.count - scan - 12 else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            let tag = String(decoding: data[(scan + 4)..<(scan + 8)], as: UTF8.self)
            if tag == "acTL" { animated = true; break }
            scan += length + 12
            if tag == "IEND" { break }
        }
        guard animated else { return nil }
        var cursor = 8
        var chunks: [(tag: String, payload: Data, crc: UInt32)] = []
        while cursor + 12 <= data.count {
            try Task.checkCancellation()
            let length = pngInteger(data, cursor)
            guard length <= data.count - cursor - 12, chunks.count < 16_384 else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            let tag = String(decoding: data[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            let payload = data.subdata(in: (cursor + 8)..<(cursor + 8 + length))
            chunks.append((tag, payload, UInt32(pngInteger(data, cursor + 8 + length))))
            cursor += length + 12
            if tag == "IEND" { break }
        }
        guard cursor == data.count, chunks.first?.tag == "IHDR", chunks.last?.tag == "IEND",
              chunks.last?.payload.isEmpty == true,
              let header = chunks.first?.payload, header.count == 13,
              chunks.filter({ $0.tag == "IHDR" }).count == 1 else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        let width = pngInteger(header, 0), height = pngInteger(header, 4)
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 64_000_000 else {
            throw RemoteAttachmentImageError.decodeLimit
        }
        var count: Int?
        var plays = 0
        var sequence = 0
        var shared = Data()
        var fallback = Data()
        var frames: [PNGFrame] = []
        var sawIDAT = false
        var finishedIDAT = false
        var defaultIsFrame = false
        var colorChunks = Set<String>()
        for (tag, payload, checksum) in chunks {
            try Task.checkCancellation()
            guard pngCRC(Data(tag.utf8) + payload) == checksum else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            let letters = Array(tag.utf8)
            guard letters.count == 4, letters.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
                  (65...90).contains(letters[2]) else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            if sawIDAT, tag != "IDAT" { finishedIDAT = true }
            switch tag {
            case "acTL":
                guard count == nil, !sawIDAT, payload.count == 8 else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                count = pngInteger(payload, 0); plays = pngInteger(payload, 4)
                guard let count, count > 0, count <= 200 else { throw RemoteAttachmentImageError.decodeLimit }
            case "fcTL":
                guard count != nil, payload.count == 26, pngInteger(payload, 0) == sequence,
                      frames.last?.compressed.isEmpty != true else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                sequence += 1
                let w = pngInteger(payload, 4), h = pngInteger(payload, 8)
                let x = pngInteger(payload, 12), y = pngInteger(payload, 16)
                guard w > 0, h > 0, w <= width, h <= height, x <= width - w, y <= height - h,
                      payload[24] <= 2, payload[25] <= 1, frames.count < 200 else {
                    throw RemoteAttachmentImageError.unsupportedOrInvalid
                }
                if !sawIDAT {
                    guard frames.isEmpty, w == width, h == height, x == 0, y == 0 else {
                        throw RemoteAttachmentImageError.unsupportedOrInvalid
                    }
                    defaultIsFrame = true
                }
                let numerator = Int(payload[20]) * 256 + Int(payload[21])
                let denominator = Int(payload[22]) * 256 + Int(payload[23])
                let delay = Double(numerator) / Double(denominator == 0 ? 100 : denominator)
                frames.append(PNGFrame(width: w, height: h, x: x, y: y, dispose: payload[24], blend: payload[25],
                    duration: delay == 0 ? 0.1 : max(0.02, delay)))
            case "IDAT":
                guard count != nil, !finishedIDAT, frames.count <= 1 else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                sawIDAT = true
                if defaultIsFrame { frames[0].compressed.append(payload) }
                else { fallback.append(payload) }
            case "fdAT":
                guard sawIDAT, !frames.isEmpty, payload.count >= 4, pngInteger(payload, 0) == sequence,
                      !(defaultIsFrame && frames.count == 1) else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                sequence += 1
                frames[frames.count - 1].compressed.append(payload.dropFirst(4))
            case "PLTE", "tRNS", "cHRM", "gAMA", "iCCP", "sRGB":
                guard !sawIDAT, colorChunks.insert(tag).inserted else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                shared.append(pngChunk(tag, payload))
            case "IHDR", "IEND": break
            default:
                guard (97...122).contains(letters[0]) else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            }
        }
        guard sawIDAT, count == frames.count, frames.last?.compressed.isEmpty == false,
              defaultIsFrame || !fallback.isEmpty else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return PNGAnimation(header: header, width: width, height: height, plays: plays, sharedChunks: shared,
            fallback: fallback, frames: frames, orientation: orientation)
    }

    private static func validatePNGAnimation(_ animation: PNGAnimation) throws {
        var pixels = animation.fallback.isEmpty ? 0 : animation.width * animation.height
        for frame in animation.frames { pixels += frame.width * frame.height }
        guard pixels <= 128_000_000 else { throw RemoteAttachmentImageError.decodeLimit }
        if !animation.fallback.isEmpty {
            try validatePNGStream(animation.fallback, header: animation.header, width: animation.width, height: animation.height)
        }
        for frame in animation.frames {
            try validatePNGStream(frame.compressed, header: animation.header, width: frame.width, height: frame.height)
        }
    }

    private static func validatePNGStream(_ compressed: Data, header: Data, width: Int, height: Int) throws {
        let channels: Int
        switch header[9] {
        case 0, 3: channels = 1
        case 2: channels = 3
        case 4: channels = 2
        case 6: channels = 4
        default: throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        let depth = Int(header[8])
        guard [1, 2, 4, 8, 16].contains(depth), (channels == 1 || depth >= 8),
              header[9] != 3 || depth <= 8, header[10] == 0, header[11] == 0, header[12] <= 1 else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        let passes = header[12] == 0 ? [(0, 0, 1, 1)] :
            [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
        let scanlines = passes.compactMap { pass -> (length: Int, count: Int)? in
            guard width > pass.0, height > pass.1 else { return nil }
            let w = (width - pass.0 + pass.2 - 1) / pass.2
            let h = (height - pass.1 + pass.3 - 1) / pass.3
            return ((w * channels * depth + 7) / 8 + 1, h)
        }
        let expected = scanlines.reduce(0) { $0 + $1.length * $1.count }
        var pass = 0, row = 0, rowOffset = 0
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        defer { inflateEnd(&stream) }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        try compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(compressed.count)
            try buffer.withUnsafeMutableBufferPointer { output in
                while true {
                    try Task.checkCancellation()
                    stream.next_out = output.baseAddress; stream.avail_out = uInt(output.count)
                    let result = inflate(&stream, Z_NO_FLUSH)
                    guard stream.total_out <= expected else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                    let produced = output.count - Int(stream.avail_out)
                    var offset = 0
                    while offset < produced {
                        guard pass < scanlines.count else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                        if rowOffset == 0, output[offset] > 4 { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                        let length = min(produced - offset, scanlines[pass].length - rowOffset)
                        offset += length; rowOffset += length
                        if rowOffset == scanlines[pass].length {
                            rowOffset = 0; row += 1
                            if row == scanlines[pass].count { pass += 1; row = 0 }
                        }
                    }
                    if result == Z_STREAM_END {
                        guard stream.total_out == expected, stream.avail_in == 0 else {
                            throw RemoteAttachmentImageError.unsupportedOrInvalid
                        }
                        return
                    }
                    guard result == Z_OK, stream.avail_out == 0 else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
                }
            }
        }
    }

    private static func preparePNGAnimation(_ animation: PNGAnimation, original: AttachmentMetadata,
                                            maximumDimension: Int, firstFrameOnly: Bool = false) throws -> InlinePreview {
        let count = firstFrameOnly ? 1 : animation.frames.count
        let dimension = min(maximumDimension, Int(sqrt(Double(maximumInlinePixels / count))))
        let scale = min(1, Double(dimension) / Double(max(animation.width, animation.height)))
        let width = max(1, Int(Double(animation.width) * scale)), height = max(1, Int(Double(animation.height) * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        var frames: [InlineFrame] = []
        var encodedBytes = 0
        var pixels = 0
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, frame) in animation.frames.prefix(count).enumerated() {
            try Task.checkCancellation()
            let header = pngBytes(frame.width) + pngBytes(frame.height) + animation.header.dropFirst(8)
            let bytes = Data([137, 80, 78, 71, 13, 10, 26, 10]) + pngChunk("IHDR", header)
                + animation.sharedChunks + pngChunk("IDAT", frame.compressed) + pngChunk("IEND", Data())
            let frameDimension = min(dimension, max(1, Int(ceil(Double(max(frame.width, frame.height)) * scale))))
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            let image = try imageForDisplay(source, index: 0, dimension: frameDimension, transform: false,
                grayAlpha16: animation.header[8] == 16 && animation.header[9] == 4)
            let rect = CGRect(x: Double(frame.x) * Double(width) / Double(animation.width),
                y: Double(animation.height - frame.y - frame.height) * Double(height) / Double(animation.height),
                width: Double(frame.width) * Double(width) / Double(animation.width),
                height: Double(frame.height) * Double(height) / Double(animation.height))
            let previous = frame.dispose == 2 && index > 0 ? context.makeImage() : nil
            if frame.blend == 0 { context.clear(rect) }
            context.draw(image, in: rect)
            guard let composed = context.makeImage() else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            CGImageDestinationAddImage(destination, composed, [kCGImagePropertyOrientation: animation.orientation] as CFDictionary)
            guard CGImageDestinationFinalize(destination),
                  let orientedSource = CGImageSourceCreateWithData(output as CFData, nil),
                  let oriented = CGImageSourceCreateThumbnailAtIndex(orientedSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension
                  ] as CFDictionary), oriented.width > 0, oriented.height > 0,
                  oriented.width <= dimension, oriented.height <= dimension else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            pixels += oriented.width * oriented.height
            guard pixels <= maximumInlinePixels else { throw RemoteAttachmentImageError.decodeLimit }
            let final = NSMutableData()
            guard let finalDestination = CGImageDestinationCreateWithData(final, "public.png" as CFString, 1, nil) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            CGImageDestinationAddImage(finalDestination, oriented, nil)
            guard CGImageDestinationFinalize(finalDestination) else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            encodedBytes += final.length
            guard encodedBytes <= maximumBytes else { throw RemoteAttachmentImageError.byteLimit }
            frames.append(InlineFrame(data: final as Data, width: oriented.width, height: oriented.height, duration: frame.duration))
            if frame.dispose == 1 || frame.dispose == 2 && index == 0 { context.clear(rect) }
            else if let previous {
                context.clear(CGRect(x: 0, y: 0, width: width, height: height))
                context.draw(previous, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }
        try Task.checkCancellation()
        return InlinePreview(frames: frames, original: original, playCount: animation.plays == 0 ? nil : animation.plays)
    }

    /// The native 16-bit gray/alpha thumbnail lost all but its first row in
    /// the fixture. Render a non-cached source into a bounded RGBA canvas for
    /// this format; the original frame/pixel limits still apply before here.
    private static func imageForDisplay(_ source: CGImageSource, index: Int, dimension: Int,
                                        transform: Bool = true, grayAlpha16: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        var preparedSource = source
        var preparedIndex = index
        if grayAlpha16 {
            guard let original = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            let scale = min(1, Double(dimension) / Double(max(original.width, original.height)))
            let width = max(1, Int(Double(original.width) * scale)), height = max(1, Int(Double(original.height) * scale))
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw RemoteAttachmentImageError.unsupportedOrInvalid }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let normalized = CGImageSourceCreateWithData(bytes, nil) else {
                throw RemoteAttachmentImageError.unsupportedOrInvalid
            }
            preparedSource = normalized; preparedIndex = 0
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(preparedSource, preparedIndex, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: transform,
            kCGImageSourceThumbnailMaxPixelSize: dimension, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), image.width > 0, image.height > 0,
              image.width <= dimension, image.height <= dimension else {
            throw RemoteAttachmentImageError.unsupportedOrInvalid
        }
        try Task.checkCancellation()
        return image
    }

    private static func pngInteger(_ data: Data, _ offset: Int) -> Int {
        (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
    }

    private static func hasGrayAlpha16PNGHeader(_ data: Data) -> Bool {
        data.count > 25 && data[data.startIndex + 24] == 16 && data[data.startIndex + 25] == 4
    }

    private static func pngBytes(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private static func pngCRC(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
    }

    private static func pngChunk(_ tag: String, _ payload: Data) -> Data {
        let checked = Data(tag.utf8) + payload
        return pngBytes(payload.count) + checked + pngBytes(Int(pngCRC(checked)))
    }
}
