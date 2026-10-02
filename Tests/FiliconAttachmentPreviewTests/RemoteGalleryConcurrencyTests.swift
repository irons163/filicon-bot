import AppKit
import Testing
import CustomDump
import FiliconDomain
@testable import FiliconAppServices
@testable import Filicon

/// Explicit suspension points, not timing guesses or a real network service.
private struct GalleryDownloadGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    func wait() async {
        entered.continuation.yield(())
        for await _ in released.stream { break }
    }
    func waitUntilEntered() async {
        for await _ in entered.stream { break }
    }
    func release() { released.continuation.yield(()); released.continuation.finish() }
    func finish() { entered.continuation.finish(); released.continuation.finish() }
}

private actor GalleryDownloadProbe {
    private(set) var urls: [String] = []
    func record(_ reference: RemoteAttachmentReference) { urls.append(reference.url) }
}

private struct GatedGalleryDownloader: RemoteAttachmentDownloading {
    let data: Data
    let gates: [String: GalleryDownloadGate]
    let redirects: [String: String]
    let probe: GalleryDownloadProbe

    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        await probe.record(reference)
        await gates[reference.url]?.wait()
        try Task.checkCancellation()
        if let target = redirects[reference.url] { throw RemoteAttachmentDownloadError.redirect(target) }
        return .init(reference: reference, data: data, declaredMIMEType: "image/png")
    }
}

@Suite("Independent remote gallery preview lifetimes", .timeLimit(.minutes(1)))
@MainActor struct RemoteGalleryConcurrencyTests {
    @Test(arguments: [false, true], [false, true])
    func differentInlineImagesDoNotCancelEachOther(reverse: Bool, redirect: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gates = [GalleryDownloadGate(), GalleryDownloadGate()]
        defer { gates.forEach { $0.finish() } }
        let probe = GalleryDownloadProbe()
        let targets = fixture.references.map { $0.url + "/reviewed" }
        let redirects = redirect ? Dictionary(uniqueKeysWithValues: zip(fixture.references.map(\.url), targets)) : [:]
        fixture.model.remoteAttachmentDownloader = GatedGalleryDownloader(data: fixture.bytes,
            gates: Dictionary(uniqueKeysWithValues: zip(fixture.references.map(\.url), gates)),
            redirects: redirects, probe: probe)
        var reviews: [String] = []
        var tasks: [Task<Data, any Error>] = []
        for (index, reference) in fixture.references.enumerated() {
            tasks.append(Task { @MainActor in
                try await fixture.model.remoteGalleryThumbnail(reference, at: fixture.location) { from, to in
                    expectNoDifference(from, reference)
                    expectNoDifference(to, try RemoteAttachmentReference(url: targets[index], alt: reference.alt))
                    reviews.append(to.url)
                    return true
                }
            })
            await gates[index].waitUntilEntered()
        }
        // Both operations have begun before either completes.
        let order = reverse ? [1, 0] : [0, 1]
        var results: [Int: Result<Data, any Error>] = [:]
        for index in order {
            gates[index].release()
            results[index] = await tasks[index].result
        }
        for index in 0..<2 {
            switch try #require(results[index]) {
            case let .success(bytes):
                expectNoDifference(bytes, fixture.expectedThumbnail)
            case let .failure(error):
                Issue.record("A sibling thumbnail must not cancel this image: \(error)")
            }
        }
        let urls = await probe.urls
        let expectedURLs = fixture.references.map(\.url) + (redirect ? order.map { targets[$0] } : [])
        expectNoDifference(urls, expectedURLs)
        expectNoDifference(reviews, redirect ? order.map { targets[$0] } : [])
        #expect(fixture.model.attachmentPreview == nil)
    }

    @Test(arguments: [false, true])
    func cancellingOneInlineImageDoesNotCancelItsSibling(cancelFirst: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gates = [GalleryDownloadGate(), GalleryDownloadGate()]
        defer { gates.forEach { $0.finish() } }
        let probe = GalleryDownloadProbe()
        fixture.model.remoteAttachmentDownloader = GatedGalleryDownloader(data: fixture.bytes,
            gates: Dictionary(uniqueKeysWithValues: zip(fixture.references.map(\.url), gates)),
            redirects: [:], probe: probe)
        var tasks: [Task<Data, any Error>] = []
        for (index, reference) in fixture.references.enumerated() {
            tasks.append(Task { @MainActor in
                try await fixture.model.remoteGalleryThumbnail(reference, at: fixture.location,
                    approveRedirect: { _, _ in Issue.record("Unexpected redirect"); return false })
            })
            await gates[index].waitUntilEntered()
        }
        let cancelled = cancelFirst ? 0 : 1
        tasks[cancelled].cancel()
        gates.forEach { $0.release() }
        let results = await [tasks[0].result, tasks[1].result]
        for index in 0..<2 {
            switch results[index] {
            case let .success(bytes):
                expectNoDifference(index, 1 - cancelled)
                expectNoDifference(bytes, fixture.expectedThumbnail)
            case let .failure(error):
                expectNoDifference(index, cancelled)
                #expect(error is CancellationError)
            }
        }
        let urls = await probe.urls
        expectNoDifference(urls, fixture.references.map(\.url))
        #expect(fixture.model.attachmentPreview == nil)
    }

    @Test(arguments: ["starts", "finishes", "dismiss", "standalone-first"])
    func modalPreviewAndInlineThumbnailHaveSeparateLifetimes(mode: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let inlineGate = GalleryDownloadGate(), modalGate = GalleryDownloadGate()
        defer { inlineGate.finish(); modalGate.finish() }
        let probe = GalleryDownloadProbe()
        let reference = fixture.references[0]
        fixture.model.remoteAttachmentDownloader = GatedGalleryDownloader(data: fixture.bytes,
            gates: [reference.url: inlineGate, fixture.standalone.url: modalGate], redirects: [:], probe: probe)
        var modalTask: Task<Void, any Error>?
        func startModal() -> Task<Void, any Error> {
            Task { @MainActor in
                try await fixture.model.previewRemoteAttachment(fixture.standalone, at: fixture.modalLocation)
            }
        }
        if mode == "standalone-first" {
            modalTask = startModal()
            await modalGate.waitUntilEntered()
        }
        let inlineTask = Task { @MainActor in
            try await fixture.model.remoteGalleryThumbnail(reference, at: fixture.location,
                approveRedirect: { _, _ in Issue.record("Unexpected redirect"); return false })
        }
        await inlineGate.waitUntilEntered()
        if mode == "dismiss" {
            fixture.model.dismissAttachmentPreview()
        } else if mode != "standalone-first" {
            modalTask = startModal()
            await modalGate.waitUntilEntered()
        }
        if mode == "finishes" || mode == "standalone-first" {
            modalGate.release()
            if case let .failure(error) = await modalTask?.result {
                Issue.record("An inline image must not replace the modal preview lifetime: \(error)")
            }
        }
        inlineGate.release()
        let inlineResult = await inlineTask.result
        if mode == "starts" {
            modalGate.release()
            if case let .failure(error) = await modalTask?.result { Issue.record("Modal preview failed: \(error)") }
        }
        switch inlineResult {
        case let .success(bytes): expectNoDifference(bytes, fixture.expectedThumbnail)
        case let .failure(error): Issue.record("The modal preview must not cancel an inline image: \(error)")
        }
        if mode == "dismiss" { #expect(fixture.model.attachmentPreview == nil) }
        else {
            let preview = fixture.model.attachmentPreview
            let item = try #require(preview)
            expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), fixture.bytes)
            expectNoDifference(item.metadata?.altText, fixture.standalone.alt)
        }
        let urls = await probe.urls
        let expectedURLs = mode == "dismiss" ? [reference.url]
            : mode == "standalone-first" ? [fixture.standalone.url, reference.url] : [reference.url, fixture.standalone.url]
        expectNoDifference(urls, expectedURLs)
    }

    @Test(arguments: [false, true])
    func modalPreviewStillRejectsStaleCompletion(dismiss: Bool) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = GalleryDownloadGate()
        defer { gate.finish() }
        let probe = GalleryDownloadProbe()
        fixture.model.remoteAttachmentDownloader = GatedGalleryDownloader(data: fixture.bytes,
            gates: [fixture.standalone.url: gate], redirects: [:], probe: probe)
        let oldPreview = Task { @MainActor in
            try await fixture.model.previewRemoteAttachment(fixture.standalone, at: fixture.modalLocation)
        }
        await gate.waitUntilEntered()
        if dismiss { fixture.model.dismissAttachmentPreview() }
        else { try await fixture.model.previewRemoteAttachment(fixture.references[0], at: fixture.location) }
        let current = fixture.model.attachmentPreview
        gate.release()
        switch await oldPreview.result {
        case .success: Issue.record("The superseded modal request must not replace the current viewer")
        case let .failure(error): #expect(error is CancellationError)
        }
        expectNoDifference(fixture.model.attachmentPreview?.id, current?.id)
        if dismiss { #expect(current == nil) }
        else {
            let item = try #require(current)
            expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), fixture.bytes)
            expectNoDifference(item.metadata?.altText, fixture.references[0].alt)
        }
        let urls = await probe.urls
        expectNoDifference(urls, dismiss ? [fixture.standalone.url] : [fixture.standalone.url, fixture.references[0].url])
    }

    @Test(arguments: ["account", "selection", "removed", "cancel"])
    func inlineCompletionStillRequiresCurrentScope(mode: String) async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let gate = GalleryDownloadGate()
        defer { gate.finish() }
        let probe = GalleryDownloadProbe()
        fixture.model.remoteAttachmentDownloader = GatedGalleryDownloader(data: fixture.bytes,
            gates: [fixture.references[0].url: gate], redirects: [:], probe: probe)
        let task = Task { @MainActor in
            try await fixture.model.remoteGalleryThumbnail(fixture.references[0], at: fixture.location,
                approveRedirect: { _, _ in Issue.record("Unexpected redirect"); return false })
        }
        await gate.waitUntilEntered()
        switch mode {
        case "account": await fixture.model.cancelAutoReviewApprovals(nextAccountID: "fixture-other-account")
        case "selection": fixture.model.selection = UUID()
        case "removed": fixture.model.conversations[0].messages[0].remoteImages = nil
        default: task.cancel()
        }
        gate.release()
        switch await task.result {
        case .success: Issue.record("A revoked image must not reach the inline view")
        case let .failure(error): #expect(error is CancellationError)
        }
        #expect(fixture.model.attachmentPreview == nil)
        let urls = await probe.urls
        expectNoDifference(urls, [fixture.references[0].url])
    }

    private struct Fixture {
        let root: URL
        let model: AppModel
        let bytes: Data
        let expectedThumbnail: Data
        let references: [RemoteAttachmentReference]
        let standalone: RemoteAttachmentReference
        let location: AppModel.RemoteAttachmentLocation
        let modalLocation: AppModel.RemoteAttachmentLocation
        @MainActor func cleanUp() {
            model.dismissAttachmentPreview()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "gallery-concurrency-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let context = try #require(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let references = try ["a", "b"].map { try RemoteAttachmentReference(url: "https://example.invalid/\($0)", alt: "Design \($0)") }
        let standalone = try RemoteAttachmentReference(url: "https://example.invalid/modal", alt: "Modal image")
        let message = ChatMessage(role: .assistant, text: "Designs", remoteImages: try RemoteImageGallery(images: references))
        let modal = ChatMessage(role: .assistant, text: "", remoteAttachment: standalone)
        let conversation = Conversation(messages: [message, modal])
        model.conversations = [conversation]; model.selection = conversation.id
        return Fixture(root: root, model: model, bytes: bytes,
            expectedThumbnail: try RemoteAttachmentImagePreparation.thumbnail(for: bytes, reference: references[0]).data,
            references: references, standalone: standalone,
            location: .direct(conversation.id, message.id), modalLocation: .direct(conversation.id, modal.id))
    }
}
