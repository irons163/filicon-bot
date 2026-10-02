import AppKit
import Combine
import CoreGraphics
import ImageIO
import SwiftUI
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
@testable import Filicon

private let galleryCardinalityLanguages = ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"]

private enum GalleryPreviewOutcome: Sendable {
    case opened
    case failed(String)
}

private struct GalleryPreviewTestFailure: Error {
    let message: String
}

@Suite("Larger reviewed galleries render and open completely", .timeLimit(.minutes(1)))
@MainActor struct GalleryCardinalityAppTests {
    @Test(arguments: galleryCardinalityLanguages, [320.0, 620.0])
    func everyRowKeepsItsOrderedPixelsInSevenLanguages(language: String, width: Double) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            for count in [5, 17, 100] {
                let items = try (0..<count).map { index -> ImageGalleryLayout.Item in
                    if index.isMultiple(of: 2) { return .attachment("image-\(index)") }
                    return .remote(try RemoteAttachmentReference(url: "https://example.com/image-\(index)"))
                }
                let view = OrderedImageGalleryLayout(items: items) { _, item in
                    let index = galleryIndex(item)
                    VStack(alignment: .leading, spacing: 6) {
                        Color(nsColor: galleryColor(index)).frame(height: 64)
                        Text(l10n("Image")).font(.caption).frame(height: 20, alignment: .leading)
                    }
                }.padding(16).frame(width: width, alignment: .leading)
                    .environment(\.locale, Locale(identifier: language))
                    .environment(\.colorScheme, .light).background(Color.white)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 1
                let rendered = try #require(renderer.cgImage)
                let rows = (count + 1) / 2
                expectNoDifference(rendered.width, Int(width))
                expectNoDifference(rendered.height, 32 + rows * 90 + (rows - 1) * 12)
                let bitmap = NSBitmapImageRep(cgImage: rendered)
                // Render reference swatches through the same color-managed SDK
                // path. Device RGB input numbers are not sRGB screenshot bytes.
                let palette = HStack(spacing: 0) {
                    ForEach(0..<count, id: \.self) { index in
                        Color(nsColor: galleryColor(index)).frame(width: 8, height: 8)
                    }
                }
                let paletteRenderer = ImageRenderer(content: palette)
                paletteRenderer.scale = 1
                let palettePixels = NSBitmapImageRep(cgImage: try #require(paletteRenderer.cgImage))
                let columnWidth = (min(560, width - 32) - 12) / 2
                for index in 0..<count {
                    let x = Int(16 + columnWidth / 2 + Double(index % 2) * (columnWidth + 12))
                    let y = 16 + (index / 2) * 102 + 32
                    let pixel = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let expected = try #require(palettePixels.colorAt(x: index * 8 + 4, y: 4)?.usingColorSpace(.deviceRGB))
                    #expect(abs(pixel.redComponent - expected.redComponent) < 0.02)
                    #expect(abs(pixel.greenComponent - expected.greenComponent) < 0.02)
                    #expect(abs(pixel.blueComponent - expected.blueComponent) < 0.02)
                }
                if language == "zh-Hant", count == 17 {
                    try saveRendered(bitmap, named: "gallery-cardinality-ordered-\(Int(width))")
                }
            }
        }
    }

    @Test(arguments: galleryCardinalityLanguages, [320.0, 620.0])
    func realRemoteCardsIncludeEveryRowWithoutDownloading(language: String, width: Double) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let gallery = try RemoteImageGallery(images: (0..<17).map {
                try RemoteAttachmentReference(url: String(format: "https://example.com/image-%02d", $0), alt: "Design 設計")
            })
            let firstRow = try RemoteImageGallery(images: Array(gallery.images.prefix(width == 320 ? 1 : 2)))
            let cellHeight = try renderRemoteGallery(firstRow, language: language, width: width).height - 32
            let rendered = try renderRemoteGallery(gallery, language: language, width: width)
            let rows = width == 320 ? 17 : 9
            expectNoDifference(rendered.width, Int(width))
            // Font metrics can round each independently rendered row by one pixel.
            let expectedHeight = 32 + rows * cellHeight + (rows - 1) * 12
            #expect(abs(rendered.height - expectedHeight) <= rows + 2)
            if language == "zh-Hant" {
                try saveRendered(NSBitmapImageRep(cgImage: rendered), named: "gallery-cardinality-remote-\(Int(width))")
            }
        }
    }

    @Test(arguments: [5, 17, 100])
    func lastImageOpensWithEveryOriginalAndDismissalRemovesEveryPreview(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-large-gallery-viewer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let store = AgentImageStore(rootURL: root.appending(path: "agent-message-images"))
        var originals: [Data] = []
        var metadata: [AttachmentMetadata] = []
        for index in 0..<count {
            let bytes = try galleryPNG(index)
            originals.append(bytes)
            metadata.append(try await store.importCapturedGalleryImage(
                .init(bytes: bytes, filename: "image-\(index).png", altText: "Image \(index)"),
                createdAt: Date(timeIntervalSince1970: 1_000)))
        }
        let selected = try #require(metadata.last)
        let outcomes = AsyncStream<GalleryPreviewOutcome>.makeStream()
        let subscription = model.$attachmentPreview.compactMap { item -> GalleryPreviewOutcome? in
            item == nil ? nil : .opened
        }.merge(with: model.$errorMessage.compactMap { $0.map(GalleryPreviewOutcome.failed) })
            .sink { outcomes.continuation.yield($0) }
        defer { subscription.cancel(); outcomes.continuation.finish() }
        var iterator = outcomes.stream.makeAsyncIterator()
        model.openAgentMessageImage(selected, gallery: metadata)
        let next = await iterator.next()
        let outcome = try #require(next)
        let preview: AttachmentPreviewItem
        switch outcome {
        case .opened: preview = try #require(model.attachmentPreview)
        case let .failed(message):
            Issue.record("Opening the last reviewed gallery image failed: \(message)")
            throw GalleryPreviewTestFailure(message: message)
        }
        expectNoDifference(preview.files.count, count)
        expectNoDifference(preview.files.map(\.metadata), metadata.map(Optional.some))
        expectNoDifference(preview.metadata, selected)
        expectNoDifference(preview.filename, selected.filename)
        expectNoDifference(try preview.files.map { try AttachmentFileIntegrity().verifiedData(for: $0) }, originals)
        #expect(model.errorMessage == nil)
        let thumbnail = try await model.agentMessageImageThumbnailData(selected)
        #expect(NSBitmapImageRep(data: thumbnail) != nil)
        model.dismissAttachmentPreview()
        #expect(model.attachmentPreview == nil)
        #expect(preview.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
    }

    @Test func galleryByteLimitIsLocalizedWithoutClaimingFourImageLimit() {
        let key = AgentImageError.galleryLimit.rawValue
        let expected = ["en": key, "zh-Hant": "圖片每張最多 5 MB，總計最多 12 MB。",
            "zh-Hans": "图片每张最多 5 MB，总计最多 12 MB。", "fr": "Limite : 5 Mo par image et 12 Mo au total.",
            "es": "Máximo 5 MB por imagen y 12 MB en total.", "ja": "画像は1枚5 MB、合計12 MBまでです。",
            "ko": "이미지는 장당 5 MB, 총 12 MB까지 사용할 수 있습니다."]
        for language in galleryCardinalityLanguages {
            expectNoDifference(FiliconLocalization.string(key, language: language), expected[language])
        }
        expectNoDifference(AgentImageError.limit.rawValue, "Use at most 4 images, 5 MB each and 12 MB total.")
    }

    private func galleryIndex(_ item: ImageGalleryLayout.Item) -> Int {
        let id: String
        switch item {
        case let .attachment(value): id = value
        case let .remote(reference): id = URL(string: reference.url)!.lastPathComponent
        }
        return Int(id.dropFirst("image-".count))!
    }

    private func galleryColor(_ index: Int) -> NSColor {
        NSColor(deviceRed: Double((index % 20) + 1) / 21, green: Double((index / 20) + 1) / 6, blue: 0.75, alpha: 1)
    }

    private func galleryPNG(_ index: Int) throws -> Data {
        let pixels = Data([UInt8(index + 1), 0, 0, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let bytes = NSMutableData()
        let writer = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil)
        try #require(CGImageDestinationFinalize(writer))
        return bytes as Data
    }

    private func renderRemoteGallery(_ gallery: RemoteImageGallery, language: String, width: Double) throws -> CGImage {
        let view = RemoteImageGalleryView(gallery: gallery,
            onPreview: { _, _ in Issue.record("Rendering must not download a preview") },
            onThumbnail: { _, _ in
                Issue.record("Rendering must not download a thumbnail")
                throw CancellationError()
            })
            .padding(16).frame(width: width, alignment: .leading)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.colorScheme, .light)
            .environment(\.openURL, OpenURLAction { _ in
                Issue.record("Rendering must not open a remote URL")
                return .handled
            }).background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func saveRendered(_ bitmap: NSBitmapImageRep, named name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: root.appending(path: ".build/validation/\(name).png"))
    }
}
