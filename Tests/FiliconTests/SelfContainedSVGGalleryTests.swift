import CoreGraphics
import CryptoKit
import CustomDump
import FiliconAppServices
import FiliconDomain
import Foundation
import ImageIO
import Testing

@Suite("Self-contained SVG galleries", .timeLimit(.minutes(1)))
struct SelfContainedSVGGalleryTests {
    @Test(arguments: [
        "<rect width='32' height='16' fill='red'/>",
        "<g transform='translate(1 1)'><path d='M0 0 H30 V14 H0 Z' fill='blue'/></g>",
        "<defs><linearGradient id='paint'><stop offset='0' stop-color='red'/><stop offset='1' stop-color='blue'/></linearGradient></defs><rect width='32' height='16' fill='url(#paint)'/>"
    ])
    func originalVectorBytesAndMetadataSurviveLocalAndRemotePreviews(body: String) async throws {
        let bytes = svg(body)
        let date = Date(timeIntervalSince1970: 1_000)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let remote = try RemoteAttachmentReference(url: "https://example.com/not-an-image.html", alt: "Reviewed vector")
        let expected = AttachmentMetadata(id: digest, filename: "remote-image.svg", mimeType: "image/svg+xml",
            byteCount: Int64(bytes.count), kind: .image, createdAt: date, altText: remote.alt)
        let metadata = try RemoteAttachmentImagePreparation.metadata(for: bytes, reference: remote, createdAt: date)
        expectNoDifference(metadata, expected)
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: remote,
            maximumDimension: 8, createdAt: date)
        expectNoDifference(preview.original, expected)
        expectNoDifference(preview.frames.count, 1)
        expectNoDifference(preview.isAnimated, false)
        expectNoDifference(preview.playCount, 1)
        let frame = try #require(preview.frames.first)
        expectNoDifference(frame.width, 8)
        expectNoDifference(frame.height, 4)
        expectNoDifference(frame.duration, 0)
        let source = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
        expectNoDifference(CGImageSourceGetType(source) as String?, "public.png")
        expectNoDifference(CGImageSourceGetCount(source), 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        expectNoDifference(image.width, 8)
        expectNoDifference(image.height, 4)
        var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
        try pixels.withUnsafeMutableBytes { storage in
            let context = try #require(CGContext(data: storage.baseAddress, width: 8, height: 4,
                bitsPerComponent: 8, bytesPerRow: 8 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 8, height: 4))
        }
        let center = (2 * 8 + 4) * 4
        #expect(pixels[center + 3] > 240)
        if body.contains("linearGradient") { #expect(pixels[center] > 20 && pixels[center + 2] > 20) }
        else if body.contains("blue") { #expect(pixels[center + 2] > 240 && pixels[center] < 10) }
        else { #expect(pixels[center] > 240 && pixels[center + 2] < 10) }
        let local = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, original: expected,
            maximumDimension: 8)
        expectNoDifference(local, preview)
        let thumbnail = try RemoteAttachmentImagePreparation.thumbnail(for: bytes, original: expected,
            maximumDimension: 8)
        expectNoDifference(thumbnail.original, expected)
        expectNoDifference(thumbnail.width, 8)
        expectNoDifference(thumbnail.height, 4)
        expectNoDifference(thumbnail.data, frame.data)
        #expect(preview.nextFrameTime(after: 10) == nil)

        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-svg-gallery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let captured = try PreparedAgentGalleryImage(bytes: bytes, filename: "本機設計.txt", altText: "已審核向量")
        let store = AgentImageStore(rootURL: root)
        let saved = try await store.importCapturedGalleryImage(captured, createdAt: date)
        let expectedSaved = AttachmentMetadata(id: digest, filename: "本機設計.txt", mimeType: "image/svg+xml",
            byteCount: Int64(bytes.count), kind: .image, createdAt: date, altText: "已審核向量")
        expectNoDifference(saved, expectedSaved)
        let reopened = AgentImageStore(rootURL: root)
        let loaded = try await reopened.loadPublishedGallery([saved])
        expectNoDifference(loaded, [.init(metadata: expectedSaved, data: bytes)])
        let alias = try PreparedAgentGalleryImage(bytes: bytes, filename: "another-name.svg", altText: "Alias")
        let aliasSaved = try await reopened.importCapturedGalleryImage(alias, createdAt: date)
        expectNoDifference(aliasSaved.id, digest)
        let inventory = try await reopened.storageInventory()
        expectNoDifference(inventory, .init(active: [digest: Int64(bytes.count)], quarantined: [:], temporaryFiles: []))
        let reopenedPreview = try await reopened.inlinePreview(for: saved, maximumDimension: 8)
        expectNoDifference(reopenedPreview.frames, preview.frames)
        expectNoDifference(reopenedPreview.original, expectedSaved)
        await #expect(throws: AgentImageError.invalid) { try await reopened.load([saved]) }
        await #expect(throws: AgentImageError.invalid) { try await reopened.importImage(data: bytes, filename: "vector.png") }
    }

    @Test(arguments: [
        "<script>alert(1)</script>",
        "<image href='https://example.invalid/private.png'/>",
        "<image href='file:///private/secret'/>",
        "<foreignObject><body>unsafe</body></foreignObject>",
        "<style>@import 'https://example.invalid/style';</style>",
        "<rect width='32' height='16' style='fill:red'/>",
        "<rect fill='url(https://example.invalid/image)'/>",
        "<rect fill='url(data:image/svg+xml,anything)'/>",
        "<rect fill='url(#missing)'/>",
        "<rect onload='alert(1)'/>",
        "<use href='#recursive' id='recursive'/>",
        "<animate attributeName='x'/>",
        "<?xml-stylesheet href='https://example.invalid/style'?>",
        "<g xmlns='https://example.invalid/namespace'/>",
        "<rect fill='u&#114;l(https://example.invalid/image)'/>",
        "<linearGradient id='paint'><rect fill='url(#paint)'/></linearGradient>",
        "<linearGradient id='paint'/><rect id='paint'/>",
        "<rect>"
    ])
    func unsafeAndUnsupportedVectorsNeverBecomeGalleryImages(body: String) throws {
        let bytes = svg(body)
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.metadata(for: bytes, filename: "safe.png")
        }
        #expect(throws: AgentImageError.galleryInvalid) {
            try PreparedAgentGalleryImage(bytes: bytes, filename: "safe.png", altText: nil)
        }
    }

    @Test func malformedEncodingsEntitiesAndComplexityRemainRejected() throws {
        let validText = String(decoding: svg("<rect width='32' height='16' fill='red'/>"), as: UTF8.self)
        let inputs = [
            Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///private/secret'>]><svg xmlns='http://www.w3.org/2000/svg' width='32' height='16'>&x;</svg>".utf8),
            try #require(validText.data(using: .utf16)),
            try #require(validText.data(using: .utf32)),
            Data("<svg/>".utf8), Data("<html/>".utf8),
            svg(String(repeating: "<g>", count: 65) + String(repeating: "</g>", count: 65)),
            svg(String(repeating: "<rect/>", count: 4_096)),
            Data("<svg xmlns='http://www.w3.org/2000/svg' width='9999999' height='16'/>".utf8)
        ]
        for bytes in inputs {
            #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
                try RemoteAttachmentImagePreparation.metadata(for: bytes, filename: "safe.svg")
            }
            #expect(throws: AgentImageError.galleryInvalid) {
                try PreparedAgentGalleryImage(bytes: bytes, filename: "safe.svg", altText: nil)
            }
        }
    }

    @Test func metadataForgeryAndCancelledVectorPreparationCannotPublish() async throws {
        let bytes = svg("<rect width='32' height='16' fill='red'/>")
        let date = Date(timeIntervalSince1970: 1_000)
        let original = try RemoteAttachmentImagePreparation.metadata(for: bytes, filename: "vector.svg", createdAt: date)
        let wrong = AttachmentMetadata(id: original.id, filename: original.filename, mimeType: "image/png",
            byteCount: original.byteCount, kind: .image, createdAt: date)
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, original: wrong)
        }
        #expect(throws: RemoteAttachmentImageError.unsupportedOrInvalid) {
            try RemoteAttachmentImagePreparation.thumbnail(for: bytes, original: wrong)
        }
        for dimension in [0, 1_025] {
            #expect(throws: RemoteAttachmentImageError.decodeLimit) {
                try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, original: original, maximumDimension: dimension)
            }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try PreparedAgentGalleryImage(bytes: bytes, filename: "vector.svg", altText: nil)
        }
        switch await task.result {
        case .success: Issue.record("Cancelled vector preparation must not be published")
        case let .failure(error): #expect(error is CancellationError)
        }
    }

    @Test(arguments: ["plain", "bom", "declaration", "leading-space", "unicode-description", "large-viewbox"])
    func utf8HeadersAndDeclaredDimensionsKeepBoundedDisplay(mode: String) throws {
        var text = String(decoding: svg("<rect width='32' height='16' fill='red'/>"), as: UTF8.self)
        switch mode {
        case "bom": text = "\u{FEFF}" + text
        case "declaration": text = "<?xml version='1.0' encoding='UTF-8'?>" + text
        case "leading-space": text = " \n\t" + text
        case "unicode-description": text = String(decoding: svg("<desc>已審核 — résumé</desc><rect width='32' height='16' fill='red'/>"), as: UTF8.self)
        case "large-viewbox": text = "<svg xmlns='http://www.w3.org/2000/svg' width='20000' height='10000' viewBox='0 0 32 16'><rect width='32' height='16' fill='red'/></svg>"
        default: break
        }
        let bytes = Data(text.utf8)
        let metadata = try RemoteAttachmentImagePreparation.metadata(for: bytes, filename: "header.svg",
            createdAt: Date(timeIntervalSince1970: 1_000))
        expectNoDifference(metadata.mimeType, "image/svg+xml")
        expectNoDifference(metadata.byteCount, Int64(bytes.count))
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, original: metadata,
            maximumDimension: 8)
        let frame = try #require(preview.frames.first)
        expectNoDifference(frame.width, 8)
        expectNoDifference(frame.height, 4)
        expectNoDifference(preview.frames.count, 1)
    }

    @Test func svgSourceByteLimitIsIndependentOfRemoteRasterLimit() throws {
        var bytes = svg("<rect width='32' height='16' fill='red'/>")
        bytes.append(Data(repeating: 0x20, count: AgentImageStore.maximumBytes - bytes.count + 1))
        #expect(bytes.count < RemoteAttachmentImagePreparation.maximumBytes)
        #expect(throws: RemoteAttachmentImageError.byteLimit) {
            try RemoteAttachmentImagePreparation.metadata(for: bytes, filename: "large.svg")
        }
        #expect(throws: AgentImageError.galleryLimit) {
            try PreparedAgentGalleryImage(bytes: bytes, filename: "large.svg", altText: nil)
        }
    }

    private func svg(_ body: String) -> Data {
        Data("<svg xmlns='http://www.w3.org/2000/svg' width='32' height='16'>\(body)</svg>".utf8)
    }
}
