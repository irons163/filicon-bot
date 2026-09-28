import AppKit
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
        try await model.previewRemoteImage(reference, at: wrongLocation)
        Issue.record("Unknown message identity must not download")
    } catch is CancellationError {}
    expectNoDifference(downloads, 0)
    try await model.previewRemoteImage(reference, at: location)
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
            try await model.previewRemoteImage(reference, at: location)
            Issue.record("A group switch must invalidate the pending preview")
        } catch is CancellationError {}
        #expect(model.attachmentPreview == nil)
        model.selectedGroupID = groupID
    }
    model.remoteAttachmentDownloader = RemotePreviewFixture(data: data, substitutedReference: nil,
        beforeReturn: { await model.cancelAutoReviewApprovals(nextAccountID: "preview-other-account") })
    do {
        try await model.previewRemoteImage(reference, at: location)
        Issue.record("An account switch must invalidate the pending preview")
    } catch is CancellationError {}
    #expect(model.attachmentPreview == nil)
}

@Suite("Remote attachment card rendering", .timeLimit(.minutes(1)))
@MainActor struct RemoteAttachmentCardTests {
    @Test(arguments: ["success", "removed", "switched", "dismissed", "mismatch", "invalid"])
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
        model.remoteAttachmentDownloader = RemotePreviewFixture(data: mode == "invalid" ? Data("bad".utf8) : png,
            substitutedReference: mode == "mismatch" ? try RemoteAttachmentReference(url: "https://other.example/image") : nil,
            beforeReturn: {
                if mode == "removed" { model.conversations[0].messages = [] }
                if mode == "switched" { model.selection = UUID() }
                if mode == "dismissed" { model.dismissAttachmentPreview() }
            })
        do {
            try await model.previewRemoteImage(reference, at: .direct(conversation.id, message.id))
            expectNoDifference(mode, "success")
            let item = try #require(model.attachmentPreview)
            expectNoDifference(try AttachmentFileIntegrity().verifiedData(for: item.files[0]), png)
            expectNoDifference(item.metadata?.mimeType, "image/png")
            let url = item.fileURL
            model.dismissAttachmentPreview()
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } catch {
            #expect(mode != "success")
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
            let host = NSHostingView(rootView: RemoteAttachmentCard(reference: reference, onPreview: {
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
