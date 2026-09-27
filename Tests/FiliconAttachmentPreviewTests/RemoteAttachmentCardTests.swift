import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
@testable import Filicon

@Suite("Remote attachment card rendering", .timeLimit(.minutes(1)))
@MainActor struct RemoteAttachmentCardTests {
    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [false, true])
    func renderDoesNotOpenURL(language: String, dark: Bool) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let reference = try RemoteAttachmentReference(url: "https://example.com/media?signature=a%2Bb#preview",
                alt: String(repeating: "報表 **plain text** ", count: 20))
            let host = NSHostingView(rootView: RemoteAttachmentCard(reference: reference)
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
        }
    }
}
