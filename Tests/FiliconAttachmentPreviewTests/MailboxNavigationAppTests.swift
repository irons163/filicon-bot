import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
@testable import Filicon

@Suite("Mailbox navigation app integration", .timeLimit(.minutes(1)))
@MainActor struct MailboxNavigationAppTests {
    @Test func oldReferenceRevealsBoundedRowWithoutChangingMailboxOrOpeningExternalURL() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-navigation-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scope = UUID(), sender = UUID(), recipient = UUID()
        var messages = (0...510).map { number in
            AgentMessage(senderID: sender, recipientID: recipient, text: "Message \(number)",
                createdAt: Date(timeIntervalSince1970: Double(number)),
                delivery: .init(chainID: scope, originConversationID: scope, state: .completed))
        }
        let original = try #require(messages.first)
        var publication = RoomMessage(groupID: scope, senderID: recipient,
            text: "See [original](sand-msg:t0u). [Missing](sand-msg:t999u)")
        publication.replyToMessageID = original.id
        messages[510].delivery?.publications = [publication]
        struct Stored: Encodable {
            let messages: [AgentMessage]
            let mailboxAddresses: [UUID: String]
            let mailboxHumanInputs: Set<UUID>
        }
        let file = root.appending(path: "agent-messages.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(Stored(messages: messages, mailboxAddresses: [original.id: "t0u", publication.id: "t510s0"],
            mailboxHumanInputs: Set(messages.map(\.id)))).write(to: file)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadAgentMessages()
        expectNoDifference(model.agentMessages.count, 500)
        #expect(!model.agentMessages.contains(where: { $0.id == original.id }))
        let bytes = try Data(contentsOf: file)
        let unread = model.agentMessageUnreadCounts
        let incoming = messages[510]
        var jumped: [UUID] = []
        let view = RichMarkdownView(source: publication.text, messageReferences: .init(
            target: { model.mailboxMessageReferences.target(for: $0, from: publication.id, replyingTo: incoming.id)?.message.id },
            show: { id in
                guard let destination = model.mailboxMessageReferences.referenceTarget(id, from: publication.id, replyingTo: incoming.id) else {
                    Issue.record("Expected a canonical destination"); return
                }
                model.revealMailboxIncoming(destination.incoming)
                jumped.append(id)
            }), openLink: { _ in Issue.record("Internal navigation must not open an external URL"); return false })
        #expect(view.open(URL(string: "sand-msg:t0u")!))
        #expect(!view.open(URL(string: "sand-msg:t999u")!))
        #expect(!view.open(URL(string: "sand-msg://t0u")!))
        expectNoDifference(jumped, [original.id])
        expectNoDifference(model.agentMessages.count, 500)
        #expect(model.agentMessages.contains(where: { $0.id == original.id }))
        let rows = MailboxTimelineRow.rows(for: model.agentMessages)
        #expect(rows.contains(where: { $0.id == original.id }))
        #expect(rows.contains(where: { $0.id == publication.id }))
        expectNoDifference(Set(rows.map(\.id)).count, rows.count)
        await model.reloadAgentMessages()
        #expect(model.agentMessages.contains(where: { $0.id == original.id }))
        expectNoDifference(model.agentMessageUnreadCounts, unread)
        expectNoDifference(model.runningAgentMessageScopes, [])
        expectNoDifference(try Data(contentsOf: file), bytes)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [false, true])
    func navigationQuoteAndMarkdownRenderWithoutClipping(language: String, dark: Bool) throws {
        try FiliconLocalization.$languageOverride.withValue(language) {
            let scope = UUID(), sender = UUID(), recipient = UUID()
            let original = AgentMessage(senderID: sender, recipientID: recipient, text: "Original layout / 原始版面",
                delivery: .init(chainID: scope, originConversationID: scope))
            var current = AgentMessage(senderID: sender, recipientID: recipient, text: "Review",
                delivery: .init(chainID: scope, originConversationID: scope))
            var publication = RoomMessage(groupID: scope, senderID: recipient,
                text: "See [original layout / 原始版面](sand-msg:t0u). **Keep the hierarchy clear.**")
            publication.replyToMessageID = original.id
            current.delivery?.publications = [publication]
            let index = MailboxMessageReferences(history: [original, current], addresses: [original.id: "t0u"], humanInputs: [original.id])
            let host = NSHostingView(rootView: AgentPublishedResponses(publications: [publication],
                replySource: { index.quotedTarget(from: $0.id, replyingTo: current.id)?.message },
                replyAuthor: { _ in FiliconLocalization.string("You") },
                references: { item in .init(target: { index.target(for: $0, from: item.id, replyingTo: current.id)?.message.id },
                                           show: { _ in Issue.record("Rendering is not a click") }) },
                onShowReply: { _ in Issue.record("Rendering is not a click") })
                .padding(16).frame(width: 420).background(FiliconTheme.canvas)
                .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            expectNoDifference(size.width, 420)
            #expect(size.height > 100 && size.height < 700)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "mailbox-navigation-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
