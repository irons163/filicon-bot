import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
@testable import Filicon

@Suite("Direct reference navigation")
struct DirectReferenceNavigationTests {
    @Test @MainActor func oldReferenceLoadsFullHistoryAndOpensOnlyInItsConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-reference-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var conversation = Conversation(title: "References")
        conversation.messages = (0..<160).map { index in
            ChatMessage(role: index == 0 ? .user : .assistant, text: "Message \(index)",
                        shortAddress: index == 0 ? "t0u" : "t0s\(index - 1)")
        }
        let original = try #require(conversation.messages.first)
        let response = try #require(conversation.messages.last)
        conversation.messages[159].text = "See [original](sand-msg:t0u)."
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(conversation, replacingLoadedMessageIDs: [], historyComplete: true)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        expectNoDifference(model.selection, conversation.id)
        #expect(model.selectedConversationHasOlderMessages)
        let url = try #require(URL(string: "sand-msg:t0u"))
        expectNoDifference(model.directMessageReferences(for: conversation.id)?.target(
            for: url, from: response.id, in: conversation.id), nil)
        await model.prepareDirectMessageReferences(for: conversation.id)
        expectNoDifference(model.selectedConversation?.messages.count, 160)
        expectNoDifference(model.directMessageReferences(for: conversation.id)?.target(
            for: url, from: response.id, in: conversation.id), original.id)

        var jumped: UUID?
        var externalOpened = false
        var transcript = TranscriptPresentationState(messages: conversation.messages)
        #expect(!transcript.visibleMessages(from: conversation.messages).contains(where: { $0.id == original.id }))
        let view = RichMarkdownView.transcript(source: "See [original](sand-msg:t0u).",
            messageReferences: .init(target: {
                model.directMessageReferences(for: conversation.id)?.target(
                    for: $0, from: response.id, in: conversation.id)
            }, show: {
                if transcript.exposeMessage(id: $0, in: conversation.messages) { jumped = $0 }
            }), openLink: { _ in externalOpened = true; return true })
        #expect(view.open(url))
        expectNoDifference(jumped, original.id)
        #expect(transcript.visibleMessages(from: conversation.messages).contains(where: { $0.id == original.id }))
        expectNoDifference(externalOpened, false)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == conversation.id }))
        model.conversations[ci].messages.removeFirst()
        #expect(!view.open(url))
        model.selection = nil
        #expect(!view.open(url))
        expectNoDifference(externalOpened, false)
    }
}
