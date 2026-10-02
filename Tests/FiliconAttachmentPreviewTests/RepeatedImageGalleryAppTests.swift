import AppKit
import Combine
import SwiftUI
import Testing
import CustomDump
import FiliconDomain
@testable import FiliconAppServices
@testable import Filicon

private let repeatedGalleryLanguages = ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"]
private let repeatedGalleryDate = Date(timeIntervalSince1970: 1_000)

private enum RepeatedPreviewOutcome: Sendable {
    case opened
    case failed(String)
}

private func repeatedAppPNG() throws -> Data {
    try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
}

@MainActor private final class RepeatedRemoteDownloader: RemoteAttachmentDownloading {
    let bytes: Data
    var requests: [RemoteAttachmentReference] = []
    init(bytes: Data) { self.bytes = bytes }
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        requests.append(reference)
        return .init(reference: reference, data: bytes, declaredMIMEType: "text/html")
    }
}

@Suite("Repeated gallery occurrences render and open independently", .timeLimit(.minutes(1)))
@MainActor struct RepeatedImageGalleryAppTests {
    @Test(arguments: repeatedGalleryLanguages, [320.0, 620.0])
    func remoteRepeatCardsRenderEachCaptionWithoutImplicitNetworkOrURLActions(language: String, width: Double) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let references = try (0..<5).map { index in
                try RemoteAttachmentReference(url: "https://example.com/same?signature=a%2Bb", alt: "Caption \(index) — 設計")
            }
            let gallery = try RemoteImageGallery(images: references)
            let action: RemotePreviewAction = { _ in Issue.record("Rendering must not download") }
            let actual = RemoteImageGalleryView(gallery: gallery, onPreview: { _, review in try await action(review) })
            let expected = LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(references.indices, id: \.self) { index in
                    RemoteAttachmentCard(reference: references[index], onPreview: action, isImage: true)
                }
            }
            let actualPixels = try render(actual, language: language, width: width)
            let expectedPixels = try render(expected, language: language, width: width)
            expectNoDifference(actualPixels.width, expectedPixels.width)
            expectNoDifference(actualPixels.height, expectedPixels.height)
            expectNoDifference(actualPixels.dataProvider?.data as Data?, expectedPixels.dataProvider?.data as Data?)
            if language == "zh-Hant" { try save(actualPixels, name: "gallery-repeat-remote-\(Int(width))") }
        }
    }

    @Test(arguments: repeatedGalleryLanguages, [320.0, 620.0])
    func localRepeatGridProvidesEveryOccurrenceIndexAndCaption(language: String, width: Double) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let images = (0..<5).map { index in
                AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "same.png", mimeType: "image/png",
                    byteCount: 100, kind: .image, createdAt: repeatedGalleryDate, altText: "Caption \(index)")
            }
            let actual = AgentMessageImageGallery(images: images) { index, image in
                occurrenceMarker(index: index, caption: image.altText)
            }
            let expected = LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading),
                GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 12) {
                ForEach(images.indices, id: \.self) { index in
                    occurrenceMarker(index: index, caption: "Caption \(index)")
                }
            }.frame(maxWidth: 560, alignment: .leading)
            let actualPixels = try render(actual, language: language, width: width)
            let expectedPixels = try render(expected, language: language, width: width)
            expectNoDifference(actualPixels.width, Int(width))
            expectNoDifference(actualPixels.height, expectedPixels.height)
            expectNoDifference(actualPixels.dataProvider?.data as Data?, expectedPixels.dataProvider?.data as Data?)
            if language == "zh-Hant" { try save(actualPixels, name: "gallery-repeat-local-\(Int(width))") }
        }
    }

    @Test(arguments: [0, 2, 4], [false, true])
    func viewerOpensTheSelectedOccurrenceEvenWhenSourceAndMetadataRepeat(index: Int, exact: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-viewer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let store = AgentImageStore(rootURL: root.appending(path: "agent-message-images"))
        let bytes = try repeatedAppPNG()
        var images: [AttachmentMetadata] = []
        for ordinal in 0..<5 {
            images.append(try await store.importCapturedGalleryImage(.init(bytes: bytes,
                filename: exact ? "same.png" : "alias-\(ordinal).png", altText: exact ? "Same caption" : "Caption \(ordinal)"),
                createdAt: repeatedGalleryDate))
        }
        let events = AsyncStream<RepeatedPreviewOutcome>.makeStream()
        let subscription = model.$attachmentPreview.compactMap { $0 == nil ? nil : RepeatedPreviewOutcome.opened }
            .merge(with: model.$errorMessage.compactMap { $0.map(RepeatedPreviewOutcome.failed) })
            .sink { events.continuation.yield($0) }
        defer { subscription.cancel(); events.continuation.finish() }
        var iterator = events.stream.makeAsyncIterator()
        // The default metadata-only route must choose the first exact match;
        // real gallery cards pass the explicit position, including exact repeats.
        model.openAgentMessageImage(images[index], gallery: images, selectedIndex: index == 0 ? nil : index)
        let next = await iterator.next()
        switch try #require(next) {
        case .opened: break
        case let .failed(message): Issue.record("Repeated gallery failed to open: \(message)"); return
        }
        let preview = try #require(model.attachmentPreview)
        expectNoDifference(preview.files.map(\.metadata), images.map(Optional.some))
        expectNoDifference(preview.initialFileID, preview.files[index].id)
        expectNoDifference(preview.metadata, images[index])
        expectNoDifference(try preview.files.map { try AttachmentFileIntegrity().verifiedData(for: $0) }, Array(repeating: bytes, count: 5))
        expectNoDifference(Set(preview.files.map(\.fileURL)).count, 5)
        model.dismissAttachmentPreview()
        #expect(preview.files.allSatisfy { !FileManager.default.fileExists(atPath: $0.fileURL.path) })
        #expect(model.errorMessage == nil)
    }

    @Test func invalidOccurrenceSelectionHasNoPreviewOrErrorSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-selection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let store = AgentImageStore(rootURL: root.appending(path: "agent-message-images"))
        let image = try await store.importCapturedGalleryImage(.init(bytes: repeatedAppPNG(), filename: "same.png", altText: "First"),
            createdAt: repeatedGalleryDate)
        var second = image
        second.altText = "Second"
        for index in [-1, 1, 2] {
            model.openAgentMessageImage(image, gallery: [image, second], selectedIndex: index)
            #expect(model.attachmentPreview == nil)
            #expect(model.errorMessage == nil)
        }
    }

    @Test func remotePreviewUsesTheExactSavedCaptionAndNeverAnUnreviewedAlias() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let references = try (0..<5).map { try RemoteAttachmentReference(url: "https://example.com/same", alt: "Caption \($0)") }
        let gallery = try RemoteImageGallery(images: references)
        let layout = try ImageGalleryLayout(items: references.map(ImageGalleryLayout.Item.remote))
        let message = ChatMessage(role: .assistant, text: "Compare", remoteImages: gallery, imageGalleryLayout: layout)
        let conversation = Conversation(messages: [message])
        model.conversations = [conversation]
        model.selection = conversation.id
        let downloader = RepeatedRemoteDownloader(bytes: try repeatedAppPNG())
        model.remoteAttachmentDownloader = downloader
        let location = AppModel.RemoteAttachmentLocation.direct(conversation.id, message.id)
        let wrong = try RemoteAttachmentReference(url: references[0].url, alt: "Not saved")
        await #expect(throws: CancellationError.self) {
            try await model.remoteGalleryPreview(wrong, at: location, approveRedirect: { _, _ in false })
        }
        expectNoDifference(downloader.requests, [])
        for reference in references {
            let preview = try await model.remoteGalleryPreview(reference, at: location, approveRedirect: { _, _ in false })
            expectNoDifference(preview.original.altText, reference.alt)
        }
        expectNoDifference(downloader.requests, references)
        #expect(model.attachmentPreview == nil)
    }

    @Test func repeatedPhysicalBlobIsChargedOnceByTheExistingAppQuotaWriter() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = try StorageQuotaLedger.live(dataRoot: root, clock: { repeatedGalleryDate })
        let writer = AppQuotaWriter(ledger: ledger), store = AgentImageStore(rootURL: root.appending(path: "images"))
        let bytes = try repeatedAppPNG()
        var images: [AttachmentMetadata] = []
        for ordinal in 0..<5 {
            let prepared = try PreparedAgentGalleryImage(bytes: bytes, filename: "alias-\(ordinal).png", altText: "Caption \(ordinal)")
            images.append(try await writer.perform(scope: "agent-image-blob", key: prepared.file.digest, data: bytes) {
                try await store.importCapturedGalleryImage(prepared, createdAt: repeatedGalleryDate)
            })
        }
        let usage = await ledger.usage()
        expectNoDifference(usage.committedBytes, Int64(bytes.count))
        expectNoDifference(usage.projectedBytes, Int64(bytes.count))
        expectNoDifference(usage.recordCount, 1)
        expectNoDifference(usage.reservationCount, 0)
        let record = await ledger.record(scope: "agent-image-blob", key: images[0].id)
        expectNoDifference(record, .init(scope: "agent-image-blob", key: images[0].id, byteCount: Int64(bytes.count), generation: 5))
        let loaded = try await store.loadPublishedGallery(images)
        expectNoDifference(loaded.map(\.metadata), images)
        expectNoDifference(loaded.map(\.data), Array(repeating: bytes, count: 5))
    }

    private func occurrenceMarker(index: Int, caption: String?) -> some View {
        VStack(spacing: 6) {
            Color(hue: Double(index) / 6, saturation: 1, brightness: 0.7).frame(height: 64)
            Text(verbatim: "\(index): \(caption ?? "")").font(.caption)
        }
    }

    private func render<V: View>(_ view: V, language: String, width: Double) throws -> CGImage {
        let renderer = ImageRenderer(content: view.padding(16).frame(width: width, alignment: .leading)
            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light)
            .environment(\.openURL, OpenURLAction { _ in Issue.record("Rendering must not open a URL"); return .handled })
            .background(Color.white))
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    private func save(_ image: CGImage, name: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: root.appending(path: ".build/validation/\(name).png"))
    }
}
