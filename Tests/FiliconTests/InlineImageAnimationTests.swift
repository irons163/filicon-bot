import Foundation
import CoreGraphics
import ImageIO
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
import zlib

@Suite("Bounded inline image animation", .timeLimit(.minutes(1)))
struct InlineImageAnimationTests {
    @Test(arguments: ["com.compuserve.gif", "apng", "org.webmproject.webp", "public.tiff",
        "com.microsoft.bmp", "public.heic", "public.png", "public.jpeg"])
    func reviewedLocalFormatsPreserveOriginalBytesWithoutGrantingModelInput(type: String) async throws {
        let actualType = type == "apng" ? "public.png" : type
        let animated = ["com.compuserve.gif", "apng", "org.webmproject.webp"].contains(type)
        let bytes = try type == "org.webmproject.webp" ? webP(loops: 2)
            : image(type: actualType, frames: animated || type == "public.tiff" ? 2 : 1, loops: 2)
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-local-format-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_000)
        let captured = try PreparedAgentGalleryImage(bytes: bytes, filename: "not-an-image.txt", altText: "已核准的設計")
        let store = AgentImageStore(rootURL: root)
        let saved = try await store.importCapturedGalleryImage(captured, createdAt: date)
        expectNoDifference(saved.filename, "not-an-image.txt")
        expectNoDifference(saved.mimeType, captured.mimeType)
        expectNoDifference(saved.altText, "已核准的設計")
        expectNoDifference(saved.createdAt, date)
        expectNoDifference(saved.kind, .image)
        let reopened = AgentImageStore(rootURL: root)
        let loaded = try await reopened.loadPublishedGallery([saved])
        expectNoDifference(loaded, [.init(metadata: saved, data: bytes)])
        let alias = try PreparedAgentGalleryImage(bytes: bytes, filename: "different-name", altText: "第二次出現")
        let aliasMetadata = try await reopened.importCapturedGalleryImage(alias, createdAt: date)
        expectNoDifference(aliasMetadata.id, saved.id)
        let inventory = try await reopened.storageInventory()
        expectNoDifference(inventory, .init(active: [saved.id: Int64(bytes.count)], quarantined: [:], temporaryFiles: []))
        let thumbnail = try await reopened.thumbnail(for: saved, maximumDimension: 32)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        expectNoDifference(CGImageSourceGetType(source) as String?, "public.png")
        expectNoDifference(CGImageSourceGetCount(source), 1)
        let preview = try await reopened.inlinePreview(for: saved, maximumDimension: 32)
        expectNoDifference(preview.original, saved)
        expectNoDifference(preview.frames.count, animated ? 2 : 1)
        expectNoDifference(preview.playCount, animated ? 2 : 1)
        expectNoDifference(preview.isAnimated, animated)
        let aliasPreview = try await reopened.inlinePreview(for: aliasMetadata, maximumDimension: 32)
        expectNoDifference(aliasPreview.original, aliasMetadata)
        expectNoDifference(aliasPreview.frames, preview.frames)
        if ["public.png", "public.jpeg"].contains(type) {
            let inference = try await reopened.load([saved])
            expectNoDifference(inference, loaded)
        } else {
            await #expect(throws: AgentImageError.invalid) { try await reopened.load([saved]) }
            await #expect(throws: AgentImageError.invalid) {
                try await reopened.importImage(data: bytes, filename: "not-an-image.txt")
            }
        }
    }

    @Test(arguments: ["digest", "byte-count", "mime", "kind"])
    func localPreviewMetadataMustMatchCompleteOriginalBytes(mode: String) throws {
        let bytes = try image(type: "com.compuserve.gif", loops: 2)
        let original = try RemoteAttachmentImagePreparation.metadata(for: bytes,
            filename: "本機.gif", altText: "已審核", createdAt: Date(timeIntervalSince1970: 1_000))
        let changed = AttachmentMetadata(id: mode == "digest" ? String(repeating: "a", count: 64) : original.id,
            filename: original.filename, mimeType: mode == "mime" ? "image/png" : original.mimeType,
            byteCount: mode == "byte-count" ? original.byteCount + 1 : original.byteCount,
            kind: mode == "kind" ? .document : original.kind, createdAt: original.createdAt, altText: original.altText)
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, original: changed)
        }
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.thumbnail(for: bytes, original: changed)
        }
    }

    @Test func invalidLocalFramesAndCancelledCaptureNeverProducePreparedImages() async throws {
        let valid = try deltaAnimation(type: "public.png")
        var corrupt = valid.prefix(8)
        for item in try pngChunks(valid) {
            let payload = item.tag == "fdAT" ? item.payload.prefix(4) + Data([1, 2, 3, 4]) : item.payload
            corrupt.append(pngChunk(item.tag, payload))
        }
        for bytes in [Data(), Data("<svg/>".utf8), Data("<html/>".utf8), corrupt,
                      try image(type: "com.compuserve.gif", frames: 201)] {
            #expect(throws: AgentImageError.galleryInvalid) {
                try PreparedAgentGalleryImage(bytes: bytes, filename: "safe.png", altText: nil)
            }
        }
        #expect(throws: AgentImageError.galleryLimit) {
            try AgentImageStore.validatePublishedImage(Data(count: AgentImageStore.maximumBytes + 1))
        }
        #expect(throws: AgentImageError.galleryLimit) {
            try PreparedAgentGalleryImage(bytes: Data(count: AgentImageStore.maximumBytes + 1),
                filename: "safe.gif", altText: nil)
        }
        let bytes = try image(type: "com.compuserve.gif", loops: 2)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreparedAgentGalleryImage(bytes: bytes, filename: "safe.gif", altText: nil)
        }
        switch await task.result {
        case .success: Issue.record("Cancelled image capture must not be published")
        case let .failure(error): #expect(error is CancellationError)
        }
    }

    @Test(arguments: ["com.compuserve.gif", "public.png", "org.webmproject.webp"], [0, 1, 2])
    func preservesFrameOrderTimingAndLoopSemantics(type: String, loops: Int) throws {
        let bytes = try type == "org.webmproject.webp" ? webP(loops: loops) : image(type: type, loops: loops)
        let reference = try RemoteAttachmentReference(url: "https://example.com/not-a-picture.html", alt: "Design **plain text**")
        let date = Date(timeIntervalSince1970: 100)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: reference,
            maximumDimension: 64, createdAt: date)
        expectNoDifference(preview.original,
            try RemoteAttachmentImagePreparation.metadata(for: bytes, reference: reference, createdAt: date))
        expectNoDifference(preview.frames.count, 2)
        expectNoDifference(preview.isAnimated, true)
        // ImageIO's writer accepts total plays, including for GIF. The separate
        // raw application-extension fixture verifies the format's repetitions.
        expectNoDifference(preview.playCount, loops == 0 ? nil : Optional(loops))
        for (index, frame) in preview.frames.enumerated() {
            #expect(abs(frame.duration - (index == 0 ? 0.1 : 0.2)) < 0.000_001)
            let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
            expectNoDifference(CGImageSourceGetType(source) as String?, "public.png")
            expectNoDifference(CGImageSourceGetCount(source), 1)
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            expectNoDifference(image.width, frame.width)
            expectNoDifference(image.height, frame.height)
            #expect(image.width <= 64 && image.height <= 64)
            if type != "org.webmproject.webp" {
                let pixel = try pixel(image)
                #expect(index == 0 ? pixel[0] > 240 && pixel[2] < 10 : pixel[2] > 240 && pixel[0] < 10)
            }
        }
        #expect(preview.frames[0].data != preview.frames[1].data)
        expectNoDifference(preview.frameIndex(at: 0.05), 0)
        expectNoDifference(preview.frameIndex(at: 0.15), 1)
        expectNoDifference(preview.frameIndex(at: 0.35), preview.playCount == 1 ? 1 : 0)
        if let count = preview.playCount {
            expectNoDifference(preview.frameIndex(at: preview.duration * Double(count) + 0.01), 1)
            #expect(preview.nextFrameTime(after: preview.duration * Double(count) + 0.01) == nil)
        } else {
            expectNoDifference(preview.frameIndex(at: preview.duration * 100 + 0.05), 0)
            #expect(preview.nextFrameTime(after: preview.duration * 100 + 0.05) != nil)
        }
    }

    @Test(arguments: ["public.png", "public.jpeg", "public.tiff"])
    func stillAndMultipageImagesDoNotAnimate(type: String) throws {
        let bytes = try image(type: type, frames: type == "public.tiff" ? 2 : 1)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/image"))
        expectNoDifference(preview.frames.count, 1)
        expectNoDifference(preview.playCount, 1)
        expectNoDifference(preview.isAnimated, false)
        for elapsed in [-1.0, 0, 100, .infinity, .nan] {
            expectNoDifference(preview.frameIndex(at: elapsed), 0)
            #expect(preview.nextFrameTime(after: elapsed) == nil)
        }
    }

    @Test func gifWithoutLoopExtensionPlaysOnceAndStopsScheduling() throws {
        let bytes = try deltaAnimation(type: "com.compuserve.gif")
        #expect(bytes.range(of: Data("NETSCAPE2.0".utf8)) == nil)
        #expect(bytes.range(of: Data("ANIMEXTS1.0".utf8)) == nil)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/once.gif"), createdAt: Date(timeIntervalSince1970: 100))
        expectNoDifference(preview.frames.count, 2)
        expectNoDifference(preview.playCount, 1)
        expectNoDifference(preview.frameIndex(at: preview.duration + 1), 1)
        #expect(preview.nextFrameTime(after: preview.duration + 1) == nil)
    }

    @Test(arguments: ["NETSCAPE2.0", "ANIMEXTS1.0"], [0, 1, 2, 65_535])
    func rawGIFLoopExtensionsCountRepetitionsAfterFirstPlay(identifier: String, repetitions: Int) throws {
        var bytes = try deltaAnimation(type: "com.compuserve.gif")
        let insertion = try gifFrame(bytes).paletteEnd
        // Write the format's raw repetition count, not ImageIO's normalized property.
        let extensionBytes = gifLoopExtension(identifier: identifier, repetitions: repetitions)
        bytes.insert(contentsOf: extensionBytes, at: insertion)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/finite.gif"), createdAt: Date(timeIntervalSince1970: 100))
        expectNoDifference(preview.frames.count, 2)
        expectNoDifference(preview.playCount, repetitions == 0 ? nil : Optional(repetitions + 1))
        if repetitions == 0 {
            #expect(preview.nextFrameTime(after: preview.duration * 100 + 0.01) != nil)
        } else {
            let end = preview.duration * Double(repetitions + 1)
            expectNoDifference(preview.frameIndex(at: end + 0.01), 1)
            #expect(preview.nextFrameTime(after: end + 0.01) == nil)
        }
    }

    @Test(arguments: ["comment", "unknown-application", "late-comment", "sliced"])
    func GIFSignaturesOutsideApplicationBlocksDoNotChangePlayback(mode: String) throws {
        var bytes = try deltaAnimation(type: "com.compuserve.gif")
        let loop = gifLoopExtension(identifier: "NETSCAPE2.0", repetitions: 0)
        if mode == "sliced" {
            bytes = (Data([7]) + bytes + Data([9]))[1..<(bytes.count + 1)]
            #expect(bytes.startIndex != 0)
        } else {
            let insertion = mode == "late-comment" ? bytes.count - 1 : try gifFrame(bytes).paletteEnd
            let ignored = mode == "unknown-application" ? gifLoopExtension(identifier: "NOTLOOPS2.0", repetitions: 0) :
                Data([0x21, 0xfe, UInt8(loop.count)]) + loop + Data([0])
            bytes.insert(contentsOf: ignored, at: insertion)
        }
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/not-looping.gif"))
        expectNoDifference(preview.playCount, 1)
        expectNoDifference(preview.frames.count, 2)
        #expect(preview.nextFrameTime(after: preview.duration + 1) == nil)
    }

    @Test(arguments: ["NETSCAPE2.0", "ANIMEXTS1.0"])
    func GIFLoopExtensionsAfterImageDataAreRead(identifier: String) throws {
        var bytes = try deltaAnimation(type: "com.compuserve.gif")
        bytes.insert(contentsOf: gifLoopExtension(identifier: identifier, repetitions: 2), at: bytes.count - 1)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/trailing-loop.gif"))
        expectNoDifference(preview.playCount, 3)
        #expect(preview.nextFrameTime(after: preview.duration * 3 + 0.01) == nil)
    }

    @Test(arguments: ["header-length", "payload-length", "unterminated", "short-loop"])
    func malformedGIFApplicationSubblocksFailWithoutReadingOutOfBounds(mode: String) throws {
        var bytes = try deltaAnimation(type: "com.compuserve.gif")
        var application = gifLoopExtension(identifier: "NETSCAPE2.0", repetitions: 1)
        switch mode {
        case "header-length": application[2] = 255
        case "payload-length": application[14] = 255
        case "unterminated": application.removeLast()
        default: application = Data([0x21, 0xff, 11]) + Data("NETSCAPE2.0".utf8) + Data([2, 1, 1, 0])
        }
        bytes.insert(contentsOf: application, at: try gifFrame(bytes).paletteEnd)
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
                reference: .init(url: "https://example.com/malformed-loop.gif"))
        }
    }

    @Test(arguments: ["com.compuserve.gif", "public.png"])
    func totalDecodedBudgetDownsamplesLongAnimationsWithoutDroppingFrames(type: String) throws {
        let bytes = try image(type: type, frames: 200, width: 256, loops: 0)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/long.gif"), maximumDimension: 1_024)
        expectNoDifference(preview.frames.count, 200)
        #expect(preview.frames.allSatisfy { $0.width == 200 && $0.height == 200 })
        expectNoDifference(preview.frames.reduce(0) { $0 + $1.width * $1.height },
            RemoteAttachmentImagePreparation.maximumInlinePixels)
        #expect(preview.frames.reduce(0) { $0 + $1.data.count } <= RemoteAttachmentImagePreparation.maximumBytes)
    }

    @Test(arguments: ["com.compuserve.gif", "public.png"])
    func deltaFramesKeepOriginalCanvasAndPreviousPixels(type: String) throws {
        let bytes = try deltaAnimation(type: type)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/delta"), maximumDimension: 64)
        expectNoDifference(preview.frames.count, 2)
        let frame = try #require(preview.frames.last)
        expectNoDifference(frame.width, 16)
        expectNoDifference(frame.height, 16)
        let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let center = try pixel(#require(image.cropping(to: .init(x: 6, y: 6, width: 1, height: 1))))
        let bottomRight = try pixel(#require(image.cropping(to: .init(x: 14, y: 14, width: 1, height: 1))))
        #expect(center[2] > 240 && center[0] < 10)
        #expect(bottomRight[0] > 240 && bottomRight[2] < 10)
    }

    @Test(arguments: ["com.compuserve.gif", "public.png"], [0, 1, 2])
    func disposalAppliesOnlyToPriorFrameRegion(type: String, disposal: Int) throws {
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for:
            deltaAnimation(type: type, disposal: disposal, thirdFrame: true),
            reference: .init(url: "https://example.com/disposal"), maximumDimension: 64)
        expectNoDifference(preview.frames.count, 3)
        let source = try #require(CGImageSourceCreateWithData(preview.frames[2].data as CFData, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let center = try pixel(#require(rendered.cropping(to: .init(x: 6, y: 6, width: 1, height: 1))))
        let corner = try pixel(#require(rendered.cropping(to: .init(x: 14, y: 14, width: 1, height: 1))))
        let newest = try pixel(#require(rendered.cropping(to: .init(x: 0, y: 0, width: 1, height: 1))))
        #expect(corner[0] > 240 && corner[2] < 10)
        #expect(newest[1] > 240 && newest[0] < 10)
        if disposal == 0 { #expect(center[2] > 240 && center[0] < 10) }
        else if disposal == 1 { #expect(center[3] == 0) }
        else { #expect(center[0] > 240 && center[2] < 10) }
    }

    @Test(arguments: [false, true])
    func transparentAPNGFramesRespectSourceAndOverBlend(over: Bool) throws {
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for:
            deltaAnimation(type: "public.png", alpha: 0.5, over: over),
            reference: .init(url: "https://example.com/blend"), maximumDimension: 64)
        let source = try #require(CGImageSourceCreateWithData(preview.frames[1].data as CFData, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let color = try pixel(#require(rendered.cropping(to: .init(x: 6, y: 6, width: 1, height: 1))))
        if over {
            #expect(color[0] > 100 && color[2] > 100 && color[3] == 255)
        } else {
            #expect(color[0] < 10 && color[2] > 100 && color[3] > 120 && color[3] < 140)
        }
    }

    @Test(arguments: [1, 2])
    func firstAPNGPreviousDisposalIsTransparentBackground(disposal: Int) throws {
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for:
            deltaAnimation(type: "public.png", firstDisposal: disposal),
            reference: .init(url: "https://example.com/first-disposal.png"))
        let source = try #require(CGImageSourceCreateWithData(preview.frames[1].data as CFData, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let corner = try pixel(#require(rendered.cropping(to: .init(x: 14, y: 14, width: 1, height: 1))))
        expectNoDifference(corner, [0, 0, 0, 0])
        let center = try pixel(#require(rendered.cropping(to: .init(x: 6, y: 6, width: 1, height: 1))))
        #expect(center[2] > 240 && center[3] == 255)
    }

    @Test(arguments: ["0:1", "0:2", "0:4", "0:8", "0:16", "3:1", "3:2", "3:4", "3:8",
                      "2:8", "2:16", "4:8", "4:16", "6:8", "6:16"], [false, true])
    func apngColorDepthAndAdam7RemainDecodable(format: String, interlaced: Bool) throws {
        let components = format.split(separator: ":").map { Int($0)! }
        let bytes = try plainAPNG(color: components[0], depth: components[1], interlaced: interlaced)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for:
            bytes,
            reference: .init(url: "https://example.com/color-depth.png"))
        expectNoDifference(preview.frames.count, 2)
        for (index, frame) in preview.frames.enumerated() {
            expectNoDifference(frame.width, 13)
            expectNoDifference(frame.height, 9)
            let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
            let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let color = try pixel(rendered)
            let pixels = try rgba(rendered)
            #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 })
            if components[0] == 0 || components[0] == 4 {
                expectNoDifference(color, index == 0 ? [255, 255, 255, 255] : [0, 0, 0, 255])
            } else {
                expectNoDifference(color, index == 0 ? [255, 0, 0, 255] : [0, 0, 255, 255])
            }
        }
    }

    @Test(arguments: [false, true])
    func grayAlpha16PreservesHalfOpacityAndOverBlend(over: Bool) throws {
        let bytes = try plainAPNG(color: 4, depth: 16, interlaced: false, lastAlpha: 32_768, over: over)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/half-opacity.png"))
        let source = try #require(CGImageSourceCreateWithData(preview.frames[1].data as CFData, nil))
        let pixels = try rgba(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            expectNoDifference(pixels[offset + 3], over ? 255 : 128)
            if over { #expect((120...135).contains(pixels[offset])) }
            else { expectNoDifference(Array(pixels[offset..<(offset + 3)]), [0, 0, 0]) }
        }
    }

    @Test(arguments: ["animated", "gray-alpha", "still-gray-alpha"])
    func slicedPNGInputsPreserveMetadataAndFrames(mode: String) throws {
        var bytes = try mode == "animated" ? image(type: "public.png") :
            plainAPNG(color: 4, depth: 16, interlaced: true)
        if mode == "still-gray-alpha" {
            let chunks = try pngChunks(bytes)
            bytes = Data(bytes.prefix(8))
            for chunk in chunks where ["IHDR", "IDAT", "IEND"].contains(chunk.tag) {
                bytes.append(pngChunk(chunk.tag, chunk.payload))
            }
        }
        let prefixed = Data([0, 1, 2, 3]) + bytes
        let sliced = prefixed.dropFirst(4)
        expectNoDifference(sliced.startIndex, 4)
        let reference = try RemoteAttachmentReference(url: "https://example.com/slice.png", alt: "Exact bytes")
        let date = Date(timeIntervalSince1970: 100)
        let metadata = try RemoteAttachmentImagePreparation.metadata(for: bytes, reference: reference, createdAt: date)
        expectNoDifference(try RemoteAttachmentImagePreparation.metadata(for: sliced, reference: reference, createdAt: date), metadata)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: reference, createdAt: date)
        expectNoDifference(try RemoteAttachmentImagePreparation.inlinePreview(for: sliced, reference: reference, createdAt: date), preview)
        let thumbnail = try RemoteAttachmentImagePreparation.thumbnail(for: bytes, reference: reference, createdAt: date)
        let actual = try RemoteAttachmentImagePreparation.thumbnail(for: sliced, reference: reference, createdAt: date)
        expectNoDifference(actual.data, thumbnail.data)
        expectNoDifference(actual.original, metadata)
    }

    @Test(arguments: [5, 64])
    func stillGrayAlpha16UsesSameBoundedRowPreservingPath(dimension: Int) throws {
        let animated = try plainAPNG(color: 4, depth: 16, interlaced: true)
        var bytes = animated.prefix(8)
        for chunk in try pngChunks(animated) where ["IHDR", "IDAT", "IEND"].contains(chunk.tag) {
            bytes.append(pngChunk(chunk.tag, chunk.payload))
        }
        let reference = try RemoteAttachmentReference(url: "https://example.com/still.png")
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: reference, maximumDimension: dimension)
        expectNoDifference(preview.frames.count, 1)
        let thumbnail = try RemoteAttachmentImagePreparation.thumbnail(for: bytes, reference: reference, maximumDimension: dimension)
        expectNoDifference(preview.frames[0].data, thumbnail.data)
        #expect(thumbnail.width <= dimension && thumbnail.height <= dimension)
        let source = try #require(CGImageSourceCreateWithData(thumbnail.data as CFData, nil))
        let pixels = try rgba(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        #expect(pixels.allSatisfy { $0 == 255 })
    }

    @Test(arguments: [false, true])
    func webPPartialFramesPreserveCanvasAndHonorDisposal(dispose: Bool) throws {
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for:
            webP(loops: 0, sideBySide: true, disposeFirst: dispose),
            reference: .init(url: "https://example.com/canvas.webp"), maximumDimension: 64)
        expectNoDifference(preview.frames.count, 2)
        let images = try preview.frames.map { frame in
            let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
            return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
        expectNoDifference(images.map(\.width), [64, 64])
        expectNoDifference(images[0].height, images[1].height)
        let left = CGRect(x: 1, y: 0, width: 30, height: images[0].height)
        let firstLeft = try rgba(#require(images[0].cropping(to: left)))
        #expect(stride(from: 3, to: firstLeft.count, by: 4).contains { firstLeft[$0] > 0 })
        let secondLeft = try rgba(#require(images[1].cropping(to: left)))
        if dispose { #expect(secondLeft.allSatisfy { $0 == 0 }) }
        else { expectNoDifference(secondLeft, firstLeft) }
        let right = try rgba(#require(images[1].cropping(to:
            .init(x: 33, y: 0, width: 30, height: images[1].height))))
        #expect(stride(from: 3, to: right.count, by: 4).contains { right[$0] > 0 })
    }

    @Test func webPAlphaBlendKeepsVisiblePixelsBehindTransparentFrame() throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/blend.webp")
        let replacement = try RemoteAttachmentImagePreparation.inlinePreview(for: webP(loops: 0),
            reference: reference, maximumDimension: 256)
        let blended = try RemoteAttachmentImagePreparation.inlinePreview(for: webP(loops: 0, over: true),
            reference: reference, maximumDimension: 256)
        let pixels = try (replacement.frames + [blended.frames[1]]).map { frame in
            let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
            return try rgba(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        }
        let retained = try #require(stride(from: 0, to: pixels[0].count, by: 4).first { index in
            pixels[0][index + 3] == 255 && pixels[1][index + 3] == 0
        })
        expectNoDifference(pixels[2][retained + 3], pixels[0][retained + 3])
        for channel in 0..<3 { #expect(abs(Int(pixels[2][retained + channel]) - Int(pixels[0][retained + channel])) <= 8) }
        #expect(pixels[2] != pixels[1])
    }

    @Test func apngFallbackImageIsNotAnAnimationFrame() throws {
        let bytes = try deltaAnimation(type: "public.png", separateFallback: true)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/fallback.png"))
        expectNoDifference(preview.frames.count, 2)
        expectNoDifference(preview.isAnimated, true)
        let source = try #require(CGImageSourceCreateWithData(preview.frames[0].data as CFData, nil))
        let color = try pixel(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        #expect(color[0] > 240 && color[1] < 100 && color[2] < 10)
        let thumbnail = try RemoteAttachmentImagePreparation.thumbnail(for: bytes,
            reference: .init(url: "https://example.com/fallback.png"))
        expectNoDifference(thumbnail.data, preview.frames[0].data)
    }

    @Test(arguments: Array(1...8))
    func apngFirstPartialFrameAndOrientationDoNotIncludeStaticCover(orientation: Int) throws {
        let bytes = try deltaAnimation(type: "public.png", separateFallback: true, firstPartial: true, orientation: orientation)
        let original = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [CFString: Any])
        expectNoDifference((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, orientation)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/oriented.png"))
        let source = try #require(CGImageSourceCreateWithData(preview.frames[0].data as CFData, nil))
        let rendered = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let position = [(6, 2), (9, 2), (9, 13), (6, 13), (2, 6), (13, 6), (13, 9), (2, 9)][orientation - 1]
        let color = try pixel(#require(rendered.cropping(to: .init(x: position.0, y: position.1, width: 1, height: 1))))
        #expect(color[0] > 240 && color[1] < 100 && color[2] < 10 && color[3] == 255)
        let data = try rgba(rendered)
        #expect(stride(from: 3, to: data.count, by: 4).filter { data[$0] != 0 }.count == 64)
    }

    @Test(arguments: ["duplicate-header", "unknown-critical", "crc", "sequence", "overflow-offset", "missing-frame",
                      "interleaved-idat", "iend-data", "filter", "extra-inflated-byte", "truncated-inflated-row", "trailing-zlib"])
    func malformedAPNGCannotBorrowValidPixelsFromAnotherFrame(mode: String) throws {
        let valid = try deltaAnimation(type: "public.png")
        var chunks = try pngChunks(valid)
        let frame = try #require(chunks.firstIndex { $0.tag == "fdAT" })
        let control = try #require(chunks.indices.last { chunks[$0].tag == "fcTL" })
        switch mode {
        case "duplicate-header": chunks.insert(chunks[0], at: 1)
        case "unknown-critical": chunks.insert(("ABCD", Data()), at: 1)
        case "sequence": chunks[frame].payload.replaceSubrange(0..<4, with: bigEndian(0))
        case "overflow-offset": chunks[control].payload.replaceSubrange(12..<16, with: bigEndian(Int(UInt32.max)))
        case "missing-frame": chunks.remove(at: frame)
        case "interleaved-idat": chunks.insert(("IDAT", Data()), at: frame + 1)
        case "iend-data": chunks[chunks.count - 1].payload = Data([0])
        case "filter", "extra-inflated-byte", "truncated-inflated-row":
            var rows = Data(repeating: 0, count: (8 * 4 + 1) * 8)
            if mode == "filter" { rows[0] = 5 }
            else if mode == "extra-inflated-byte" { rows.append(0) }
            else { rows.removeLast() }
            chunks[frame].payload = chunks[frame].payload.prefix(4) + (try deflated(rows))
        case "trailing-zlib": chunks[frame].payload.append(0)
        default: break
        }
        var bytes = valid.prefix(8)
        for chunk in chunks { bytes.append(pngChunk(chunk.tag, chunk.payload)) }
        if mode == "crc" { bytes[bytes.count - 1] ^= 1 }
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
                reference: .init(url: "https://example.com/malformed.png"))
        }
    }

    @Test(arguments: [0.0, 0.01, 0.02, 10.0])
    func zeroAndShortDelaysCannotCreateBusyLoops(delay: Double) throws {
        let bytes = try image(type: "com.compuserve.gif", loops: 0, delays: [delay, 0.2])
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes,
            reference: .init(url: "https://example.com/fast"))
        let expected = delay == 0 ? 0.1 : max(0.02, delay)
        #expect(abs(preview.frames[0].duration - expected) < 0.000_001)
        #expect(preview.nextFrameTime(after: 0)! > 0)
    }

    @Test func schedulesOnlyFrameTransitionsAndStopsFinitePlayback() throws {
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: image(type: "public.png", loops: 2),
            reference: .init(url: "https://example.com/a.png"))
        for (elapsed, expected) in [(-1.0, 0.0), (0.0, 0.1), (0.15, 0.3), (0.35, 0.4), (0.45, 0.6)] {
            #expect(abs(try #require(preview.nextFrameTime(after: elapsed)) - expected) < 0.000_001)
        }
        #expect(preview.nextFrameTime(after: 0.61) == nil)
        #expect(preview.nextFrameTime(after: .infinity) == nil)
        #expect(preview.nextFrameTime(after: .nan) == nil)
        expectNoDifference(preview.frameIndex(at: .infinity), 0)
        expectNoDifference(preview.frameIndex(at: .nan), 0)
    }

    @Test func rejectsInvalidLaterFramesBoundsAndCancellation() async throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/trusted.gif")
        for bytes in [Data(), Data("<svg/>".utf8), Data("<html/>".utf8),
                      try image(type: "com.compuserve.gif", frames: 201)] {
            #expect(throws: (any Error).self) {
                try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: reference)
            }
        }
        let valid = try deltaAnimation(type: "public.png")
        var corrupt = valid.prefix(8)
        for item in try pngChunks(valid) {
            let payload = item.tag == "fdAT" ? item.payload.prefix(4) + Data([1, 2, 3, 4]) : item.payload
            corrupt.append(pngChunk(item.tag, payload))
        }
        let corruptSource = try #require(CGImageSourceCreateWithData(corrupt as CFData, nil))
        expectNoDifference(CGImageSourceGetCount(corruptSource), 2)
        #expect(CGImageSourceCreateImageAtIndex(corruptSource, 0, nil) != nil)
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.inlinePreview(for: corrupt, reference: reference)
        }
        let bytes = try image(type: "com.compuserve.gif", loops: 0)
        for limit in [-1, 0, 1_025, Int.max] {
            #expect(throws: RemoteAttachmentImageError.decodeLimit) {
                try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: reference, maximumDimension: limit)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: reference)
        }
        switch await task.result {
        case .success: Issue.record("Cancelled preparation must not return any frames")
        case let .failure(error): #expect(error is CancellationError)
        }
    }

    private func pixel(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: .init(x: 0, y: 0, width: 1, height: 1))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self), count: 4))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
            count: image.width * image.height * 4))
    }

    private func image(type: String, frames: Int = 2, width: Int = 16,
                       loops: Int? = nil, delays: [Double] = [0.1, 0.2], color: CGColor? = nil) throws -> Data {
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, frames, nil))
        let dictionary = type == "public.png" ? kCGImagePropertyPNGDictionary : kCGImagePropertyGIFDictionary
        let loop = type == "public.png" ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyGIFLoopCount
        let delay = type == "public.png" ? kCGImagePropertyAPNGUnclampedDelayTime : kCGImagePropertyGIFUnclampedDelayTime
        if let loops { CGImageDestinationSetProperties(destination, [dictionary: [loop: loops]] as CFDictionary) }
        for index in 0..<frames {
            let size = width
            let context = try #require(CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(color ?? CGColor(red: index.isMultiple(of: 2) ? 1 : 0, green: 0,
                blue: index.isMultiple(of: 2) ? 0 : 1, alpha: 1))
            context.fill(.init(x: 0, y: 0, width: size, height: size))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                [dictionary: [delay: delays[index % delays.count]]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func gifLoopExtension(identifier: String, repetitions: Int) -> Data {
        Data([0x21, 0xff, 11]) + Data(identifier.utf8)
            + Data([3, 1]) + integer(repetitions, bytes: 2) + Data([0])
    }

    private func deltaAnimation(type: String, disposal: Int = 0, thirdFrame: Bool = false,
                                alpha: CGFloat = 1, over: Bool = false, separateFallback: Bool = false,
                                firstPartial: Bool = false, orientation: Int = 1, firstDisposal: Int = 0) throws -> Data {
        let canvas = try image(type: type, frames: 1)
        let frames = try [firstPartial ? image(type: type, frames: 1, width: 8) : canvas,
            image(type: type, frames: 1, width: 8, color: .init(red: 0, green: 0, blue: 1, alpha: alpha)),
            image(type: type, frames: 1, width: 2, color: .init(red: 0, green: 1, blue: 0, alpha: 1))]
        let count = thirdFrame ? 3 : 2
        if type == "com.compuserve.gif" {
            var output = frames[0].prefix(try gifFrame(frames[0]).paletteEnd)
            output.replaceSubrange(0..<6, with: Data("GIF89a".utf8))
            for (index, bytes) in frames.prefix(count).enumerated() {
                let frame = try gifFrame(bytes)
                let keep = index == 1 ? disposal + 1 : 1
                output.append(Data([0x21, 0xf9, 4, UInt8(keep << 2) | 1, 10, 0, frame.transparentIndex, 0]))
                let offset = index == 1 ? 4 : 0
                let size = index == 0 ? 16 : index == 1 ? 8 : 2
                output.append(Data([0x2c]) + integer(offset, bytes: 2) + integer(offset, bytes: 2)
                    + integer(size, bytes: 2) + integer(size, bytes: 2) + Data([0x80 | (bytes[10] & 7)]))
                output.append(bytes[13..<frame.paletteEnd])
                output.append(bytes[(frame.start + 10)..<frame.end])
            }
            output.append(0x3b)
            return output
        }
        let firstChunks = try pngChunks(canvas)
        var output = canvas.prefix(8)
        for item in firstChunks where item.tag != "IDAT" && item.tag != "IEND" {
            output.append(pngChunk(item.tag, item.payload))
            if item.tag == "IHDR", orientation != 1 {
                let tiff = Data([0x49, 0x49, 42, 0]) + integer(8, bytes: 4) + integer(1, bytes: 2)
                    + integer(0x112, bytes: 2) + integer(3, bytes: 2) + integer(1, bytes: 4)
                    + integer(orientation, bytes: 2) + Data(repeating: 0, count: 6)
                output.append(pngChunk("eXIf", tiff))
            }
        }
        output.append(pngChunk("acTL", bigEndian(count) + bigEndian(0)))
        if separateFallback {
            let fallback = try image(type: type, frames: 1, color: .init(red: 0, green: 1, blue: 0, alpha: 1))
            for item in try pngChunks(fallback) where item.tag == "IDAT" { output.append(pngChunk("IDAT", item.payload)) }
        }
        var sequence = 0
        for (index, bytes) in frames.prefix(count).enumerated() {
            let size = index == 0 ? (firstPartial ? 8 : 16) : index == 1 ? 8 : 2
            let x = index == 1 || index == 0 && firstPartial ? 4 : 0
            let y = index == 1 ? 4 : 0
            output.append(pngChunk("fcTL", bigEndian(sequence) + bigEndian(size) + bigEndian(size)
                + bigEndian(x) + bigEndian(y) + Data([0, 1, 0, 10,
                    UInt8(index == 1 ? disposal : index == 0 ? firstDisposal : 0), index == 1 && over ? 1 : 0])))
            sequence += 1
            for item in try pngChunks(bytes) where item.tag == "IDAT" {
                if index == 0, !separateFallback { output.append(pngChunk("IDAT", item.payload)) }
                else { output.append(pngChunk("fdAT", bigEndian(sequence) + item.payload)); sequence += 1 }
            }
        }
        output.append(pngChunk("IEND", Data()))
        return output
    }

    private func plainAPNG(color: Int, depth: Int, interlaced: Bool, lastAlpha: UInt16? = nil, over: Bool = false) throws -> Data {
        var bytes = Data([137, 80, 78, 71, 13, 10, 26, 10])
        bytes.append(pngChunk("IHDR", bigEndian(13) + bigEndian(9) + Data([UInt8(depth), UInt8(color), 0, 0, interlaced ? 1 : 0])))
        if color == 3 { bytes.append(pngChunk("PLTE", Data([255, 0, 0, 0, 0, 255]))) }
        bytes.append(pngChunk("acTL", bigEndian(2) + bigEndian(1)))
        let passes = interlaced ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
            (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)] : [(0, 0, 1, 1)]
        for index in 0..<2 {
            let sequence = index == 0 ? 0 : 1
            bytes.append(pngChunk("fcTL", bigEndian(sequence) + bigEndian(13) + bigEndian(9)
                + bigEndian(0) + bigEndian(0) + Data([0, 1, 0, 10, 0, index == 1 && over ? 1 : 0])))
            var rows = Data()
            for pass in passes where pass.0 < 13 && pass.1 < 9 {
                let width = (13 - pass.0 + pass.2 - 1) / pass.2
                let height = (9 - pass.1 + pass.3 - 1) / pass.3
                var pixels = Data()
                if color == 0 || color == 3 {
                    let byte = color == 0 ? (index == 0 ? 255 : 0) : index == 0 ? 0 : 255 / ((1 << depth) - 1)
                    pixels = Data(repeating: UInt8(byte), count: (width * depth + 7) / 8)
                } else {
                    let values: [UInt8] = color == 4 ? [index == 0 ? 255 : 0, 255] :
                        [index == 0 ? 255 : 0, 0, index == 0 ? 0 : 255] + (color == 6 ? [255] : [])
                    for _ in 0..<width {
                        for (channel, value) in values.enumerated() {
                            if index == 1, let lastAlpha, channel == values.count - 1, color == 4 || color == 6 {
                                pixels.append(UInt8(lastAlpha >> 8))
                                if depth == 16 { pixels.append(UInt8(truncatingIfNeeded: lastAlpha)) }
                            } else { pixels.append(contentsOf: repeatElement(value, count: depth / 8)) }
                        }
                    }
                }
                for _ in 0..<height { rows.append(0); rows.append(pixels) }
            }
            let compressed = try deflated(rows)
            bytes.append(pngChunk(index == 0 ? "IDAT" : "fdAT", index == 0 ? compressed : bigEndian(2) + compressed))
        }
        bytes.append(pngChunk("IEND", Data()))
        return bytes
    }

    private func gifFrame(_ bytes: Data) throws -> (start: Int, end: Int, paletteEnd: Int, transparentIndex: UInt8) {
        let paletteEnd = 13 + 3 * (1 << (Int(bytes[10] & 7) + 1))
        var cursor = paletteEnd
        var transparentIndex: UInt8 = 0
        while bytes[cursor] == 0x21 {
            if bytes[cursor + 1] == 0xf9 { transparentIndex = bytes[cursor + 6] }
            cursor += 2
            while bytes[cursor] != 0 { cursor += Int(bytes[cursor]) + 1 }
            cursor += 1
        }
        try #require(bytes[cursor] == 0x2c)
        let start = cursor
        cursor += 10
        if bytes[start + 9] & 0x80 != 0 { cursor += 3 * (1 << (Int(bytes[start + 9] & 7) + 1)) }
        cursor += 1
        while bytes[cursor] != 0 { cursor += Int(bytes[cursor]) + 1 }
        return (start, cursor + 1, paletteEnd, transparentIndex)
    }

    private func pngChunks(_ bytes: Data) throws -> [(tag: String, payload: Data)] {
        var output: [(String, Data)] = []
        var cursor = 8
        while cursor + 12 <= bytes.count {
            let length = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[cursor + $1]) }
            try #require(length <= bytes.count - cursor - 12)
            output.append((String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self),
                bytes.subdata(in: (cursor + 8)..<(cursor + 8 + length))))
            cursor += length + 12
        }
        expectNoDifference(cursor, bytes.count)
        return output
    }

    private func bigEndian(_ value: Int) -> Data {
        Data((0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }

    private func pngChunk(_ tag: String, _ payload: Data) -> Data {
        let checked = Data(tag.utf8) + payload
        var crc: UInt32 = 0xffff_ffff
        for byte in checked {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0) }
        }
        return bigEndian(payload.count) + checked + bigEndian(Int(crc ^ 0xffff_ffff))
    }

    private func deflated(_ data: Data) throws -> Data {
        var length = compressBound(uLong(data.count))
        var output = Data(count: Int(length))
        let result = output.withUnsafeMutableBytes { buffer in
            data.withUnsafeBytes { input in
                compress2(buffer.bindMemory(to: UInt8.self).baseAddress, &length,
                    input.bindMemory(to: UInt8.self).baseAddress, uLong(data.count), Z_BEST_SPEED)
            }
        }
        try #require(result == Z_OK)
        return output.prefix(Int(length))
    }

    /// A RIFF animation assembled from two existing, repository-owned WebP
    /// sprites. No codec executable, copied external fixture or network needed.
    private func webP(loops: Int, sideBySide: Bool = false, disposeFirst: Bool = false, over: Bool = false) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var body = Data("WEBP".utf8)
        body.append(chunk("VP8X", Data([0x12, 0, 0, 0]) + integer(sideBySide ? 3_071 : 1_535, bytes: 3)
            + integer(2_287, bytes: 3)))
        body.append(chunk("ANIM", Data(repeating: 0, count: 4) + integer(loops, bytes: 2)))
        for (index, name) in ["codex", "dewey"].enumerated() {
            let bytes = try Data(contentsOf: root.appending(path: "Sources/Filicon/Resources/PetAvatars/\(name).webp"))
            var cursor = 12
            var pixels = Data()
            while cursor + 8 <= bytes.count {
                let length = (0..<4).reduce(0) { $0 | Int(bytes[cursor + 4 + $1]) << ($1 * 8) }
                let end = cursor + 8 + length + (length % 2)
                try #require(end <= bytes.count)
                let tag = String(decoding: bytes[cursor..<(cursor + 4)], as: UTF8.self)
                if ["ALPH", "VP8 ", "VP8L"].contains(tag) { pixels.append(bytes[cursor..<end]) }
                cursor = end
            }
            try #require(!pixels.isEmpty)
            let header = integer(sideBySide && index == 1 ? 768 : 0, bytes: 3) + integer(0, bytes: 3)
                + integer(1_535, bytes: 3) + integer(2_287, bytes: 3)
                + integer(index == 0 ? 100 : 200, bytes: 3)
                + Data([index == 0 && disposeFirst ? 3 : index == 1 && over ? 0 : 2])
            body.append(chunk("ANMF", header + pixels))
        }
        return Data("RIFF".utf8) + integer(body.count, bytes: 4) + body
    }

    private func integer(_ value: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private func chunk(_ tag: String, _ payload: Data) -> Data {
        Data(tag.utf8) + integer(payload.count, bytes: 4) + payload + Data(repeating: 0, count: payload.count % 2)
    }
}
