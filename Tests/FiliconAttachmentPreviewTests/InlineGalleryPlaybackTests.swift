import AppKit
import SwiftUI
import ImageIO
import Testing
import CustomDump
import FiliconDomain
import FiliconAgents
@testable import FiliconAppServices
@testable import Filicon

private struct InlinePlaybackGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()
    func wait() async {
        entered.continuation.yield(())
        for await _ in release.stream { break }
    }
    func waitUntilEntered() async { for await _ in entered.stream { break } }
    func finish() { release.continuation.finish(); entered.continuation.finish() }
}

@Suite("Inline gallery playback and view lifecycle", .timeLimit(.minutes(1)))
@MainActor struct InlineGalleryPlaybackTests {
    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [320.0, 620.0])
    func framesRenderDifferentPixelsAndPausedStateKeepsFirstFrame(language: String, width: Double) throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/animation", alt: "Design 設計")
        let prepared = try RemoteAttachmentImagePreparation.inlinePreview(for: animation(), reference: reference,
            createdAt: Date(timeIntervalSince1970: 100))
        let display = try RemoteGalleryDisplay(preview: prepared)
        try FiliconLocalization.$languageOverride.withValue(language) {
            for (elapsed, paused) in [(0.05, false), (0.15, false), (0.15, true)] {
                let view = VStack(spacing: 8) {
                    RemoteGalleryFrameView(display: display, elapsed: elapsed, paused: paused)
                    Text(verbatim: reference.alt ?? "")
                }.padding(16).frame(width: width).background(Color.white)
                    .environment(\.colorScheme, .light).environment(\.locale, Locale(identifier: language))
                let renderer = ImageRenderer(content: view)
                let rendered = try #require(renderer.cgImage)
                expectNoDifference(rendered.width, Int(width))
                #expect(rendered.height > 250 && rendered.height < 350)
                let bitmap = NSBitmapImageRep(cgImage: rendered)
                let color = try #require(bitmap.colorAt(x: rendered.width / 2, y: 100)?.usingColorSpace(.deviceRGB))
                if elapsed == 0.05 || paused { #expect(color.redComponent > 0.95 && color.blueComponent < 0.05) }
                else { #expect(color.blueComponent > 0.95 && color.redComponent < 0.05) }
                if language == "zh-Hant", width == 320 {
                    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    let label = paused ? "paused" : elapsed == 0.05 ? "first" : "second"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: root.appending(path: ".build/validation/gallery-animation-\(label).png"))
                }
            }
        }
    }

    @Test(arguments: [false, true], [ScenePhase.active, .inactive, .background])
    func playbackViewRespectsMotionAndSceneActivity(reduceMotion: Bool, scene: ScenePhase) throws {
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: animation(),
            reference: .init(url: "https://example.com/activity.gif"), createdAt: Date(timeIntervalSince1970: 100))
        let view = RemoteGalleryPlaybackView(display: try RemoteGalleryDisplay(preview: preview),
            startedAt: Date(timeIntervalSince1970: 100), reduceMotion: reduceMotion, isActive: scene == .active)
            .frame(width: 320, height: 240)
        let renderer = ImageRenderer(content: view)
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let color = try #require(bitmap.colorAt(x: 160, y: 100)?.usingColorSpace(.deviceRGB))
        if scene == .active && !reduceMotion { #expect(color.blueComponent > 0.95 && color.redComponent < 0.05) }
        else { #expect(color.redComponent > 0.95 && color.blueComponent < 0.05) }
    }

    @Test func finiteTimelineUsesFrameBoundariesAndDoesNotKeepTicking() throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/a.gif")
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: animation(), reference: reference)
        let date = Date(timeIntervalSince1970: 100)
        let schedule = RemoteGalleryTimeline(preview: preview, startedAt: date)
        let entries = Array(schedule.entries(from: date, mode: .normal))
        expectNoDifference(entries, [date, date.addingTimeInterval(0.1), date.addingTimeInterval(0.3),
            date.addingTimeInterval(0.4), date.addingTimeInterval(0.6)])
        expectNoDifference(entries.map { preview.frameIndex(at: $0.timeIntervalSince(date) + 0.000_001) }, [0, 1, 0, 1, 1])
        expectNoDifference(Array(schedule.entries(from: date.addingTimeInterval(10), mode: .lowFrequency)),
            [date.addingTimeInterval(10)])
    }

    @Test(arguments: ["cancel", "leave", "replace", "error-after-leave"])
    func lateResultsNeverRestoreCancelledOrReplacedAnimation(mode: String) async throws {
        let old = try RemoteAttachmentImagePreparation.inlinePreview(for: animation(),
            reference: .init(url: "https://example.com/old", alt: "Old"), createdAt: Date(timeIntervalSince1970: 100))
        let new = try RemoteAttachmentImagePreparation.inlinePreview(for: animation(type: "public.png"),
            reference: .init(url: "https://example.com/new", alt: "New"), createdAt: Date(timeIntervalSince1970: 100))
        let model = RemoteGalleryCardModel()
        let gate = InlinePlaybackGate()
        defer { gate.finish() }
        let task = Task { @MainActor in
            await model.previewButtonTapped(onThumbnail: { _ in
                await gate.wait()
                if mode == "error-after-leave" { throw CocoaError(.fileReadCorruptFile) }
                return old
            }, onPreview: nil, approveRedirect: { _, _ in Issue.record("Unexpected redirect"); return false })
        }
        await gate.waitUntilEntered()
        expectNoDifference(model.state, .init(isLoading: true))
        #expect(model.display == nil)
        if mode == "cancel" { task.cancel() }
        else {
            await expectDifference(model.state) { model.cancelButtonTapped() } changes: { $0.isLoading = false }
        }
        if mode == "replace" {
            await model.previewButtonTapped(onThumbnail: { _ in new }, onPreview: nil,
                approveRedirect: { _, _ in Issue.record("Unexpected redirect"); return false })
        }
        gate.finish()
        await task.value
        expectNoDifference(model.state, .init(preview: mode == "replace" ? new : nil))
        expectNoDifference(model.display?.preview, mode == "replace" ? new : nil)
        if mode == "replace" {
            await expectDifference(model.state) { model.cancelButtonTapped() } changes: { $0.preview = nil }
            #expect(model.display == nil)
        }
    }

    @Test func failureIsVisibleAndCanBeRetriedWithoutLeakingOldPlayback() async throws {
        let model = RemoteGalleryCardModel()
        await model.previewButtonTapped(onThumbnail: { _ in throw CocoaError(.fileReadCorruptFile) },
            onPreview: nil, approveRedirect: { _, _ in false })
        expectNoDifference(model.state, .init(previewFailed: true))
        let preview = try RemoteAttachmentImagePreparation.inlinePreview(for: animation(),
            reference: .init(url: "https://example.com/retry"))
        await model.previewButtonTapped(onThumbnail: { _ in preview }, onPreview: nil, approveRedirect: { _, _ in false })
        expectNoDifference(model.state, .init(preview: preview))
        expectNoDifference(model.display?.images.count, 2)
        model.cancelButtonTapped()
        var opened = 0
        await model.previewButtonTapped(onThumbnail: nil, onPreview: { _ in opened += 1 },
            approveRedirect: { _, _ in false })
        expectNoDifference(opened, 1)
        expectNoDifference(model.state, .init())
        #expect(model.display == nil)
    }

    @Test(arguments: ["direct", "group", "mailbox"], ["com.compuserve.gif", "public.png"])
    func exactSavedGalleryReturnsAnimationAndModalRetainsOriginal(route: String, type: String) async throws {
        let fixture = try await makeFixture(route: route)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        defer { fixture.model.dismissAttachmentPreview() }
        let bytes = try animation(type: type)
        var downloads = 0
        fixture.model.remoteAttachmentDownloader = RemotePreviewFixture(data: bytes, substitutedReference: nil,
            beforeReturn: { downloads += 1 })
        let wrong = try RemoteAttachmentReference(url: fixture.reference.url, alt: "Unreviewed alt")
        await #expect(throws: CancellationError.self) {
            try await fixture.model.remoteGalleryPreview(wrong, at: fixture.location, approveRedirect: { _, _ in false })
        }
        expectNoDifference(downloads, 0)
        let preview = try await fixture.model.remoteGalleryPreview(fixture.reference, at: fixture.location,
            approveRedirect: { _, _ in false })
        let expected = try RemoteAttachmentImagePreparation.inlinePreview(for: bytes, reference: fixture.reference,
            createdAt: preview.original.createdAt)
        expectNoDifference(preview, expected)
        expectNoDifference(preview.frames.count, 2)
        #expect(fixture.model.attachmentPreview == nil)
        try await fixture.model.previewRemoteAttachment(fixture.reference, at: fixture.location)
        let modal = try #require(fixture.model.attachmentPreview)
        expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: modal.files[0]), bytes)
        expectNoDifference(modal.metadata?.mimeType, type == "public.png" ? "image/png" : "image/gif")
        expectNoDifference(downloads, 2)
        fixture.model.dismissAttachmentPreview()
        fixture.model.remoteAttachmentDownloader = RemotePreviewFixture(data: bytes, substitutedReference: nil,
            beforeReturn: { await fixture.model.cancelAutoReviewApprovals(nextAccountID: "other") })
        await #expect(throws: CancellationError.self) {
            try await fixture.model.remoteGalleryPreview(fixture.reference, at: fixture.location,
                approveRedirect: { _, _ in false })
        }
        #expect(fixture.model.attachmentPreview == nil)
    }

    private func animation(type: String = "com.compuserve.gif") throws -> Data {
        let context = try #require(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 2, nil))
        let dictionary = type == "public.png" ? kCGImagePropertyPNGDictionary : kCGImagePropertyGIFDictionary
        let delay = type == "public.png" ? kCGImagePropertyAPNGUnclampedDelayTime : kCGImagePropertyGIFUnclampedDelayTime
        let loop = type == "public.png" ? kCGImagePropertyAPNGLoopCount : kCGImagePropertyGIFLoopCount
        CGImageDestinationSetProperties(destination, [dictionary: [loop: 2]] as CFDictionary)
        for index in 0..<2 {
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: 0, blue: index == 0 ? 0 : 1, alpha: 1))
            context.fill(.init(x: 0, y: 0, width: 32, height: 32))
            CGImageDestinationAddImage(destination, try #require(context.makeImage()),
                [dictionary: [delay: index == 0 ? 0.1 : 0.2]] as CFDictionary)
        }
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeFixture(route: String) async throws -> (root: URL, model: AppModel,
        reference: RemoteAttachmentReference, location: AppModel.RemoteAttachmentLocation) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-inline-animation-\(UUID())")
        var prepared = false
        defer { if !prepared { try? FileManager.default.removeItem(at: root) } }
        let reference = try RemoteAttachmentReference(url: "https://example.com/image-not-executable.html", alt: "Reviewed design")
        let gallery = try RemoteImageGallery(images: [reference])
        if route == "direct" {
            let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            let message = ChatMessage(role: .assistant, text: "Design", remoteImages: gallery)
            let conversation = Conversation(messages: [message])
            model.conversations = [conversation]; model.selection = conversation.id
            prepared = true
            return (root, model, reference, .direct(conversation.id, message.id))
        }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", at: Date(timeIntervalSince1970: 100))
        let recipient = try await agents.create(name: "Designer", at: Date(timeIntervalSince1970: 100))
        if route == "group" {
            let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
            let group = try await groups.create(name: "Team", memberIDs: [sender.id, recipient.id])
            let message = RoomMessage(groupID: group.id, senderID: sender.id, text: "Design", remoteImages: gallery)
            try await groups.postAgentMessage(message, audience: groups.audience(groupID: group.id, senderID: sender.id), lifetime: .init())
            let reopenedAgents = try AgentService(storeURL: root.appending(path: "agents.json"))
            let reopened = try GroupService(agents: reopenedAgents, storeURL: root.appending(path: "groups.json"))
            let saved = await reopened.messages(groupID: group.id)
            expectNoDifference(saved.first { $0.id == message.id }?.remoteImages, gallery)
            let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            model.selectedGroupID = group.id
            prepared = true
            return (root, model, reference, .group(group.id, message.id))
        }
        let origin = UUID()
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "agent-messages.json"))
        let incoming = AgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Design",
            delivery: .init(chainID: UUID(), originConversationID: origin, state: .queued))
        try await messenger.send(incoming)
        try await messenger.updateDelivery(id: incoming.id, state: .running)
        let reviewed = ReviewedMailboxImageGallery(text: "Design", gallery: gallery, incomingID: incoming.id,
            originID: origin, senderID: recipient.id, messageID: UUID(), lifetime: .init())
        let publication = try await messenger.publishImageGallery(reviewed)
        try await messenger.updateDelivery(id: incoming.id, state: .completed)
        let reopenedAgents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let reopened = try AgentMessenger(service: reopenedAgents, storeURL: root.appending(path: "agent-messages.json"))
        let saved = await reopened.allMessages()
        expectNoDifference(saved.first { $0.id == incoming.id }?.delivery?.publications?
            .first { $0.id == publication.id }?.remoteImages, gallery)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        prepared = true
        return (root, model, reference, .mailbox(incoming.id, publication.id))
    }
}
