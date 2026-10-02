import AppKit
import Combine
import SwiftUI
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
@testable import Filicon

private struct LocalFormatPreviewGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    func wait() async {
        entered.continuation.yield(())
        for await _ in release.stream { break }
    }
    func waitUntilEntered() async { for await _ in entered.stream { break } }
    func finish() { release.continuation.finish(); entered.continuation.finish() }
}

@Suite("Local gallery formats and playback", .timeLimit(.minutes(1)))
@MainActor struct LocalGalleryFormatsAppTests {
    @Test(arguments: ["gif", "apng", "webp", "tiff", "bmp", "heic", "avif", "ico"])
    func inlinePreviewAndModalRetainExactCapturedOriginals(type: String) async throws {
        let fixture = try await fixture(type: type)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { fixture.model.dismissAttachmentPreview() }
        let preview = try await fixture.model.agentMessageImageInlinePreview(fixture.metadata)
        expectNoDifference(preview.original, fixture.metadata)
        expectNoDifference(preview.frames.count, ["gif", "apng", "webp"].contains(type) ? 2 : 1)
        let reopened = AppModel(applicationSupportRoot: fixture.root, bootstrapImmediately: false)
        let reopenedPreview = try await reopened.agentMessageImageInlinePreview(fixture.metadata)
        expectNoDifference(reopenedPreview, preview)
        let original = try await reopened.agentMessageImageData(fixture.metadata)
        expectNoDifference(original, fixture.bytes)
        let events = AsyncStream<Bool>.makeStream()
        defer { events.continuation.finish() }
        let opened = fixture.model.$attachmentPreview.sink { if $0 != nil { events.continuation.yield(true) } }
        let failed = fixture.model.$errorMessage.sink { if $0 != nil { events.continuation.yield(false) } }
        defer { opened.cancel(); failed.cancel() }
        fixture.model.openAgentMessageImage(fixture.metadata, gallery: [fixture.metadata], selectedIndex: 0)
        for await result in events.stream { expectNoDifference(result, true); break }
        let modal = try #require(fixture.model.attachmentPreview)
        expectNoDifference(modal.metadata, fixture.metadata)
        expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: modal.files[0]), fixture.bytes)
        let urls = modal.files.map(\.fileURL)
        await fixture.model.cancelAutoReviewApprovals(nextAccountID: "different")
        #expect(fixture.model.attachmentPreview == nil)
        #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"],
        [320.0, 620.0].flatMap { width in ["gif", "avif", "ico"].map { (width: width, type: $0) } })
    func actualLocalImageCardRendersFirstFrameAndDescriptionsWithoutClipping(language: String,
        variant: (width: Double, type: String)) async throws {
        let (width, type) = variant
        let fixture = try await fixture(type: type)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let preview = try await fixture.model.agentMessageImageInlinePreview(fixture.metadata)
        let display = try RemoteGalleryDisplay(preview: preview)
        try FiliconLocalization.$languageOverride.withValue(language) {
            let actual = AgentMessageImagePreviewContent(image: fixture.metadata, preview: nil,
                animation: display, compact: true, expanded: true)
                .environment(\.scenePhase, .inactive)
            let firstImage = try #require(NSImage(data: preview.frames[0].data))
            let expected = AgentMessageImagePreviewContent(image: fixture.metadata,
                preview: firstImage, compact: true, expanded: true)
            let actualPixels = try render(actual, language: language, width: width)
            let expectedPixels = try render(expected, language: language, width: width)
            expectNoDifference(actualPixels.width, Int(width))
            expectNoDifference(actualPixels.height, expectedPixels.height)
            let actualData = try #require(actualPixels.dataProvider?.data as Data?)
            let expectedData = try #require(expectedPixels.dataProvider?.data as Data?)
            expectNoDifference(actualData, expectedData)
            if language == "zh-Hant" {
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let output = try #require(NSBitmapImageRep(cgImage: actualPixels).representation(using: .png, properties: [:]))
                try output.write(to: root.appending(path: ".build/validation/local-gallery-\(type)-\(Int(width)).png"))
            }
        }
    }

    @Test(arguments: ["cancel", "leave", "replace", "error-after-leave"])
    func localLateResultsNeverRestoreCancelledOrReplacedPlayback(mode: String) async throws {
        let fixture = try await fixture(type: "gif")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try await fixture.model.agentMessageImageInlinePreview(fixture.metadata)
        let nextBytes = try LocalGalleryFormatFixture.bytes(type: "apng", index: 1)
        let next = try RemoteAttachmentImagePreparation.inlinePreview(for: nextBytes,
            original: RemoteAttachmentImagePreparation.metadata(for: nextBytes, filename: "新設計.png",
                altText: "新版本", createdAt: Date(timeIntervalSince1970: 1_000)))
        let model = RemoteGalleryCardModel()
        let gate = LocalFormatPreviewGate()
        defer { gate.finish() }
        let task = Task { @MainActor in
            await model.previewRequested {
                await gate.wait()
                if mode == "error-after-leave" { throw CocoaError(.fileReadCorruptFile) }
                return old
            }
        }
        await gate.waitUntilEntered()
        expectNoDifference(model.state, .init(isLoading: true))
        if mode == "cancel" { task.cancel() }
        else {
            await expectDifference(model.state) { model.cancelButtonTapped() } changes: { $0.isLoading = false }
        }
        if mode == "replace" { await model.previewRequested { next } }
        gate.finish()
        await task.value
        expectNoDifference(model.state, .init(preview: mode == "replace" ? next : nil))
        expectNoDifference(model.display?.preview, mode == "replace" ? next : nil)
    }

    @Test func spoofedMetadataCannotProduceLocalPlayback() async throws {
        let fixture = try await fixture(type: "gif")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong = AttachmentMetadata(id: fixture.metadata.id, filename: fixture.metadata.filename,
            mimeType: "image/png", byteCount: fixture.metadata.byteCount, kind: .image,
            createdAt: fixture.metadata.createdAt, altText: fixture.metadata.altText)
        await #expect(throws: AgentImageError.invalid) { try await fixture.model.agentMessageImageInlinePreview(wrong) }
        #expect(fixture.model.attachmentPreview == nil)
    }

    private func fixture(type: String) async throws -> (root: URL, model: AppModel, metadata: AttachmentMetadata, bytes: Data) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-local-gallery-playback-\(UUID())")
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: root) } }
        let bytes = try LocalGalleryFormatFixture.bytes(type: type)
        let captured = try PreparedAgentGalleryImage(bytes: bytes, filename: "本機設計.txt", altText: "Reviewed design — 已審核")
        let store = AgentImageStore(rootURL: root.appending(path: "agent-message-images"))
        let metadata = try await store.importCapturedGalleryImage(captured, createdAt: Date(timeIntervalSince1970: 1_000))
        prepared = true
        return (root, AppModel(applicationSupportRoot: root, bootstrapImmediately: false), metadata, bytes)
    }

    private func render(_ view: some View, language: String, width: Double) throws -> CGImage {
        let renderer = ImageRenderer(content: view.padding(16).frame(width: width).background(Color.white)
            .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: language)))
        return try #require(renderer.cgImage)
    }
}
