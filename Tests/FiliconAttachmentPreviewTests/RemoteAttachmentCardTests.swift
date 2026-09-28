import AppKit
import AVFoundation
import CoreVideo
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
@testable import Filicon
@testable import FiliconAppServices

struct RemotePreviewFixture: RemoteAttachmentDownloading {
    let data: Data
    let substitutedReference: RemoteAttachmentReference?
    let beforeReturn: @MainActor @Sendable () async -> Void
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        await beforeReturn()
        return RemoteAttachmentDownload(reference: substitutedReference ?? reference, data: data, declaredMIMEType: "text/html")
    }
}

@MainActor func verifySavedRemotePreview(model: AppModel, reference: RemoteAttachmentReference,
                                        location: AppModel.RemoteAttachmentLocation,
                                        wrongLocation: AppModel.RemoteAttachmentLocation) async throws {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
    for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.blue, atX: x, y: y) } }
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    var downloads = 0
    model.remoteAttachmentDownloader = RemotePreviewFixture(data: data, substitutedReference: nil,
        beforeReturn: { downloads += 1 })
    do {
        try await model.previewRemoteAttachment(reference, at: wrongLocation)
        Issue.record("Unknown message identity must not download")
    } catch is CancellationError {}
    expectNoDifference(downloads, 0)
    try await model.previewRemoteAttachment(reference, at: location)
    expectNoDifference(downloads, 1)
    let item = try #require(model.attachmentPreview)
    defer { model.dismissAttachmentPreview() }
    expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), data)
    expectNoDifference(item.metadata?.altText, reference.alt)
    model.dismissAttachmentPreview()
    #expect(!FileManager.default.fileExists(atPath: item.fileURL.path))

    if case let .group(groupID, _) = location {
        model.remoteAttachmentDownloader = RemotePreviewFixture(data: data, substitutedReference: nil,
            beforeReturn: { model.selectedGroupID = UUID() })
        do {
            try await model.previewRemoteAttachment(reference, at: location)
            Issue.record("A group switch must invalidate the pending preview")
        } catch is CancellationError {}
        #expect(model.attachmentPreview == nil)
        model.selectedGroupID = groupID
    }
    model.remoteAttachmentDownloader = RemotePreviewFixture(data: data, substitutedReference: nil,
        beforeReturn: { await model.cancelAutoReviewApprovals(nextAccountID: "preview-other-account") })
    do {
        try await model.previewRemoteAttachment(reference, at: location)
        Issue.record("An account switch must invalidate the pending preview")
    } catch is CancellationError {}
    #expect(model.attachmentPreview == nil)
}

@Suite("Remote attachment card rendering", .timeLimit(.minutes(1)))
@MainActor struct RemoteAttachmentCardTests {
    @Test func inlineThumbnailRendersVerifiedPixels() throws {
        let context = try #require(CGContext(data: nil, width: 320, height: 160, bitsPerComponent: 8,
            bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 160, y: 0, width: 160, height: 160))
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        let source = try #require(bitmap.representation(using: .png, properties: [:]))
        let reference = try RemoteAttachmentReference(url: "https://example.com/design", alt: "Blue and orange design")
        let prepared = try RemoteAttachmentImagePreparation.thumbnail(for: source, reference: reference)
        let preparedPixels = try #require(NSBitmapImageRep(data: prepared.data))
        let preparedLeft = try #require(preparedPixels.colorAt(x: 80, y: 80)?.usingColorSpace(.deviceRGB))
        #expect(preparedLeft.blueComponent > 0.8 && preparedLeft.redComponent < 0.2)
        let image = try #require(NSImage(data: prepared.data))
        let view = VStack(alignment: .leading, spacing: 12) {
            Text("Compare designs")
            RemoteGalleryThumbnailView(image: image, alt: reference.alt)
            Text(verbatim: reference.alt ?? "")
        }.padding(16).frame(width: 360).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.height > 320 && rendered.height < 650)
        expectNoDifference(rendered.width, 720)
        let pixels = NSBitmapImageRep(cgImage: rendered)
        let left = try #require(pixels.colorAt(x: 180, y: rendered.height / 2)?.usingColorSpace(.deviceRGB))
        let right = try #require(pixels.colorAt(x: 540, y: rendered.height / 2)?.usingColorSpace(.deviceRGB))
        #expect(left.blueComponent > 0.8 && left.redComponent < 0.2)
        #expect(right.redComponent > 0.8 && right.blueComponent < 0.2)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try #require(NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
            .write(to: root.appending(path: ".build/validation/gallery-inline.png"))
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [320.0, 620.0])
    func galleryRendersWithoutFetching(language: String, width: Double) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let gallery = try RemoteImageGallery(images: (1...4).map {
                try RemoteAttachmentReference(url: "https://example.com/image-\($0)?sig=exact",
                    alt: "\($0) — Design **plain text** 設計")
            })
            let host = NSHostingView(rootView: VStack(alignment: .leading) {
                Text("Compare these designs")
                RemoteImageGalleryView(gallery: gallery) { _, _ in Issue.record("Rendering must not download") }
            }.padding(16).frame(width: width)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.openURL, OpenURLAction { _ in Issue.record("Rendering must not open URLs"); return .handled })
                .environment(\.colorScheme, .light).background(Color.white))
            let size = host.fittingSize
            expectNoDifference(size.width, width)
            #expect(size.height > 100 && size.height < 1800)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if language == "en", width == 620 {
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                let output = root.appending(path: ".build/validation/gallery-ui.png")
                let renderer = ImageRenderer(content: host.rootView)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: output)
            }
        }
    }

    @Test(arguments: ["success", "foreign", "removed", "switched", "invalid"], [false, true])
    func galleryPreviewRequiresExactSavedImage(mode: String, inline: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "gallery-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let reference = try RemoteAttachmentReference(url: "https://example.com/a", alt: "Design A")
        let gallery = try RemoteImageGallery(images: [reference])
        let message = ChatMessage(role: .assistant, text: "Designs", remoteImages: gallery)
        let conversation = Conversation(messages: [message])
        model.conversations = [conversation]; model.selection = conversation.id
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        var downloads = 0
        model.remoteAttachmentDownloader = RemotePreviewFixture(data: mode == "invalid" ? Data("not image".utf8) : data,
            substitutedReference: nil, beforeReturn: {
                downloads += 1
                if mode == "removed" { model.conversations[0].messages[0].remoteImages = nil }
                if mode == "switched" { model.selection = UUID() }
            })
        let requested = mode == "foreign" ? try RemoteAttachmentReference(url: reference.url, alt: "Not reviewed") : reference
        do {
            if inline {
                let bytes = try await model.remoteGalleryThumbnail(requested, at: .direct(conversation.id, message.id), approveRedirect: { _, _ in false })
                expectNoDifference(mode, "success")
                #expect(model.attachmentPreview == nil)
                let image = try #require(NSBitmapImageRep(data: bytes))
                expectNoDifference(image.pixelsWide, 2)
                expectNoDifference(image.pixelsHigh, 2)
            } else {
            try await model.previewRemoteAttachment(requested, at: .direct(conversation.id, message.id))
            expectNoDifference(mode, "success")
            let item = try #require(model.attachmentPreview)
            expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), data)
            expectNoDifference(item.metadata?.altText, reference.alt)
            expectNoDifference(item.metadata?.kind, .image)
            }
        } catch { #expect(mode != "success"); #expect(model.attachmentPreview == nil) }
        expectNoDifference(downloads, mode == "foreign" ? 0 : 1)
    }

    @Test(arguments: ["approve", "deny", "switch", "dismiss", "account"])
    func redirectDecisionRevalidatesMessageScope(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "redirect-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let source = try RemoteAttachmentReference(url: "https://example.com/start", alt: "Original")
        let message = ChatMessage(role: .assistant, text: "", remoteAttachment: source)
        let conversation = Conversation(messages: [message])
        model.conversations = [conversation]
        model.selection = conversation.id
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.blue, atX: x, y: y) } }
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let downloader = RedirectAppFixture(data: bytes)
        model.remoteAttachmentDownloader = downloader
        do {
            try await model.previewRemoteAttachment(source, at: .direct(conversation.id, message.id)) { from, to in
                expectNoDifference(from, source)
                expectNoDifference(to.url, "https://other.example/final")
                if mode == "switch" { model.selection = UUID() }
                if mode == "dismiss" { model.dismissAttachmentPreview() }
                if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "redirect-other") }
                return mode != "deny"
            }
            expectNoDifference(mode, "approve")
            let item = try #require(model.attachmentPreview)
            expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), bytes)
            expectNoDifference(item.metadata?.altText, "Original")
        } catch is CancellationError {
            #expect(mode != "approve")
            #expect(model.attachmentPreview == nil)
        }
        let count = await downloader.count
        expectNoDifference(count, mode == "approve" ? 2 : 1)
    }

    @Test(arguments: ["approve", "deny", "cancel", "replace"])
    func redirectReviewResumesExactlyOnce(mode: String) async throws {
        let model = RemoteRedirectReviewModel()
        let source = try RemoteAttachmentReference(url: "https://example.com/start")
        let destination = try RemoteAttachmentReference(url: "https://other.example/end")
        let task = Task { try await model.review(source, destination) }
        let deadline = ContinuousClock.now + .seconds(5)
        while model.request == nil && ContinuousClock.now < deadline { await Task.yield() }
        let request = try #require(model.request)
        expectNoDifference(request.source, source)
        expectNoDifference(request.destination, destination)
        if mode == "cancel" {
            task.cancel()
            do { _ = try await task.value; Issue.record("Expected cancellation") }
            catch is CancellationError {}
        } else if mode == "replace" {
            let second = Task { try await model.review(destination, source) }
            let firstResult = try await task.value
            expectNoDifference(firstResult, false)
            model.resolve(approved: true)
            let secondResult = try await second.value
            expectNoDifference(secondResult, true)
        } else {
            model.resolve(approved: mode == "approve")
            model.resolve(approved: false)
            let result = try await task.value
            expectNoDifference(result, mode == "approve")
        }
        #expect(model.request == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func videoPreviewUsesVerifiedBytesAndCleansUp(quickTime: Bool, cancelled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-video-app-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: quickTime ? "fixture.mov" : "fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: quickTime ? .mov : .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16])
        writer.add(input)
        try #require(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var optionalBuffer: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32ARGB,
            nil, &optionalBuffer) == kCVReturnSuccess)
        let buffer = try #require(optionalBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = ContinuousClock.now + .seconds(5)
        while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(input.isReadyForMoreMediaData)
        try #require(adaptor.append(buffer, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
        let bytes = try Data(contentsOf: url)
        let model = AppModel(applicationSupportRoot: root.appending(path: "app"), bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let reference = try RemoteAttachmentReference(url: "https://example.com/misleading.png", alt: "Video fixture")
        let message = ChatMessage(role: .assistant, text: "", remoteAttachment: reference)
        let conversation = Conversation(messages: [message])
        model.conversations = [conversation]
        model.selection = conversation.id
        model.remoteAttachmentDownloader = RemotePreviewFixture(data: bytes, substitutedReference: nil,
            beforeReturn: { if cancelled { withUnsafeCurrentTask { $0?.cancel() } } })
        let preview = Task { @MainActor in
            try await model.previewRemoteAttachment(reference, at: .direct(conversation.id, message.id))
        }
        if cancelled {
            do {
                try await preview.value
                Issue.record("Cancelled video must not become a preview")
            } catch is CancellationError {}
            #expect(model.attachmentPreview == nil)
            return
        }
        try await preview.value
        let item = try #require(model.attachmentPreview)
        let metadata = try #require(item.metadata)
        expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), bytes)
        expectNoDifference(metadata.mimeType, quickTime ? "video/quicktime" : "video/mp4")
        expectNoDifference(metadata.altText, "Video fixture")
        expectNoDifference(metadata.kind, .video)
        expectNoDifference(AttachmentViewerKind.classify(filename: item.fileURL.lastPathComponent,
            mimeType: metadata.mimeType), .audiovisual)
        #expect(item.fileURL != url)
        model.dismissAttachmentPreview()
        #expect(!FileManager.default.fileExists(atPath: item.fileURL.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test(arguments: ["success", "pdf", "removed", "switched", "dismissed", "mismatch", "invalid"])
    func directPreviewIsIdentityBoundAndCleanedUp(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "remote-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        defer { model.dismissAttachmentPreview() }
        let reference = try RemoteAttachmentReference(url: "https://example.com/not-an-extension", alt: "Preview")
        let message = ChatMessage(role: .assistant, text: "", remoteAttachment: reference)
        let conversation = Conversation(messages: [message])
        model.conversations = [conversation]
        model.selection = conversation.id
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        var previewBytes = png
        if mode == "pdf" {
            let bytes = NSMutableData()
            let consumer = try #require(CGDataConsumer(data: bytes))
            var page = CGRect(x: 0, y: 0, width: 612, height: 792)
            let context = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
            context.beginPDFPage(nil)
            context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
            context.endPDFPage()
            context.closePDF()
            previewBytes = bytes as Data
        }
        model.remoteAttachmentDownloader = RemotePreviewFixture(data: mode == "invalid" ? Data("bad".utf8) : previewBytes,
            substitutedReference: mode == "mismatch" ? try RemoteAttachmentReference(url: "https://other.example/image") : nil,
            beforeReturn: {
                if mode == "removed" { model.conversations[0].messages = [] }
                if mode == "switched" { model.selection = UUID() }
                if mode == "dismissed" { model.dismissAttachmentPreview() }
            })
        do {
            try await model.previewRemoteAttachment(reference, at: .direct(conversation.id, message.id))
            #expect(["success", "pdf"].contains(mode))
            let item = try #require(model.attachmentPreview)
            expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), previewBytes)
            expectNoDifference(item.metadata?.mimeType, mode == "pdf" ? "application/pdf" : "image/png")
            let url = item.fileURL
            model.dismissAttachmentPreview()
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } catch {
            #expect(!["success", "pdf"].contains(mode))
            #expect(model.attachmentPreview == nil)
        }
    }

    @Test func replySummaryUsesDescriptionOrExactLocator() throws {
        for alt in [nil, "報表 **plain text**", String(repeating: "文", count: 300)] as [String?] {
            let reference = try RemoteAttachmentReference(url: "https://example.com/report?sig=a%2Bb", alt: alt)
            let preview = ReplyPreviewPresentation.make(for: ChatMessage(role: .assistant, text: "", remoteAttachment: reference))
            expectNoDifference(preview.kind, .attachment)
            expectNoDifference(preview.symbolName, "link")
            expectNoDifference(preview.detail, String((alt ?? reference.url).prefix(240)))
        }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [false, true])
    func renderDoesNotOpenURL(language: String, dark: Bool) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let reference = try RemoteAttachmentReference(url: "https://example.com/media?signature=a%2Bb#preview",
                alt: String(repeating: "報表 **plain text** ", count: 20))
            let host = NSHostingView(rootView: RemoteAttachmentCard(reference: reference, onPreview: { _ in
                Issue.record("Rendering must not download remote content")
            })
                .padding(16).frame(width: 320)
                .environment(\.openURL, OpenURLAction { _ in
                    Issue.record("Rendering must not open remote content"); return .handled
                }).environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            expectNoDifference(size.width, 320)
            #expect(size.height > 80 && size.height < 400)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)

            let publication = ReviewedMailboxRemoteAttachment(reference: reference, incomingID: UUID(),
                originID: UUID(), senderID: UUID(), messageID: UUID(), lifetime: AgentPublicationLifetime()).publication
            let replies = NSHostingView(rootView: VStack {
                GroupReplyPreview(original: publication, author: "Agent", onOpen: {})
                MailboxReplyPreview(original: publication, author: "Agent", onOpen: {})
            }.padding(16).frame(width: 360)
                .environment(\.openURL, OpenURLAction { _ in
                    Issue.record("Reply previews must not open remote content"); return .handled
                }).environment(\.colorScheme, dark ? .dark : .light))
            let replySize = replies.fittingSize
            expectNoDifference(replySize.width, 360)
            #expect(replySize.height > 80 && replySize.height < 450)
            replies.frame = .init(origin: .zero, size: replySize)
            replies.layoutSubtreeIfNeeded()
            let replyBitmap = try #require(replies.bitmapImageRepForCachingDisplay(in: replies.bounds))
            replies.cacheDisplay(in: replies.bounds, to: replyBitmap)
            let mailbox = NSHostingView(rootView: AgentPublishedResponses(publications: [publication])
                .padding(16).frame(width: 360)
                .environment(\.openURL, OpenURLAction { _ in
                    Issue.record("Mailbox rendering must not open remote content"); return .handled
                }).environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light))
            mailbox.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let mailboxSize = mailbox.fittingSize
            expectNoDifference(mailboxSize.width, 360)
            #expect(mailboxSize.height > 100 && mailboxSize.height < 450)
            mailbox.frame = .init(origin: .zero, size: mailboxSize)
            mailbox.layoutSubtreeIfNeeded()
            let mailboxBitmap = try #require(mailbox.bitmapImageRepForCachingDisplay(in: mailbox.bounds))
            mailbox.cacheDisplay(in: mailbox.bounds, to: mailboxBitmap)

            let root = FileManager.default.temporaryDirectory.appending(path: "remote-direct-ui-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            let message = ChatMessage(role: .assistant, text: "", remoteAttachment: reference)
            let direct = NSHostingView(rootView: TranscriptMessageView(message: message,
                conversation: Conversation(messages: [message]), onJumpToMessage: { _ in })
                .environmentObject(model).padding(16).frame(width: 520)
                .environment(\.openURL, OpenURLAction { _ in
                    Issue.record("Direct rendering must not open remote content"); return .handled
                }).environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light))
            direct.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let directSize = direct.fittingSize
            expectNoDifference(directSize.width, 520)
            #expect(directSize.height > 80 && directSize.height < 500)
            direct.frame = .init(origin: .zero, size: directSize)
            direct.layoutSubtreeIfNeeded()
            let directBitmap = try #require(direct.bitmapImageRepForCachingDisplay(in: direct.bounds))
            direct.cacheDisplay(in: direct.bounds, to: directBitmap)
        }
    }
}

private actor RedirectAppFixture: RemoteAttachmentDownloading {
    let data: Data
    var count = 0
    init(data: Data) { self.data = data }
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        count += 1
        if count == 1 { throw RemoteAttachmentDownloadError.redirect("https://other.example/final") }
        return RemoteAttachmentDownload(reference: reference, data: data, declaredMIMEType: nil)
    }
}
