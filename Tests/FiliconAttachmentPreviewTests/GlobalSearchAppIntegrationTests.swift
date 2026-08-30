import Foundation
import Testing
import FiliconAppServices
import FiliconDomain
@testable import Filicon

@Suite("Global search app integration")
struct GlobalSearchAppIntegrationTests {
    @Test @MainActor func conversationSearchIsPreservedAndMessagesMergeLiveTranscript() async throws {
        let root = try makeRoot("search-merge")
        defer { try? FileManager.default.removeItem(at: root) }
        let messageID = UUID()
        let persisted = Conversation(
            title: "Project Aurora",
            messages: [.init(id: messageID, role: .assistant, text: "persisted text")]
        )
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save([persisted])
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)

        model.searchQuery = "Aurora"
        await model.performGlobalSearch()
        #expect(model.searchResults.map(\.id) == [persisted.id])
        #expect(model.globalSearchState == .results)

        var live = persisted
        live.messages[0].text = "a streaming needle that is newer than the index"
        model.conversations = [live]
        model.globalSearchTab = .messages
        model.searchQuery = "streaming needle"
        await model.performGlobalSearch()
        #expect(model.globalMessageSearchResults.count == 1)
        #expect(model.globalMessageSearchResults.first?.messageID == messageID)
        #expect(model.globalMessageSearchResults.first?.snippet.contains("streaming needle") == true)
    }

    @Test @MainActor func emptyFileQueryReturnsRecentVisibleMedia() async throws {
        let root = try makeRoot("search-media")
        defer { try? FileManager.default.removeItem(at: root) }
        let recent = AttachmentMetadata(
            id: String(repeating: "a", count: 64), filename: "recent.png", mimeType: "image/png",
            byteCount: 12, kind: .image, createdAt: Date(timeIntervalSince1970: 20)
        )
        let hidden = AttachmentMetadata(
            id: String(repeating: "b", count: 64), filename: "hidden.pdf", mimeType: "application/pdf",
            byteCount: 20, kind: .document, createdAt: Date(timeIntervalSince1970: 30)
        )
        let conversations = [
            Conversation(title: "Visible", messages: [.init(role: .user, text: "", attachments: [recent])]),
            Conversation(title: "Hidden", messages: [.init(role: .user, text: "", attachments: [hidden])], hiddenAt: .now),
        ]
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save(conversations)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        model.globalSearchTab = .files
        model.searchQuery = ""

        await model.performGlobalSearch()

        #expect(model.globalMediaSearchResults.map(\.attachmentID) == [recent.id])
        #expect(model.globalSearchState == .results)
    }

    @Test @MainActor func messageResultLoadsWholeTranscriptAndPublishesExactJump() async throws {
        let root = try makeRoot("search-jump")
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = (0..<180).map { ChatMessage(role: .user, text: "message \($0)") }
        let target = messages[5]
        let conversation = Conversation(title: "Long transcript", messages: messages)
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save([conversation])
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        var metadata = conversation
        metadata.messages = []
        model.conversations = [metadata]

        await model.openGlobalMessageSearchHit(.init(
            conversationID: conversation.id,
            messageID: target.id,
            role: target.role,
            timestamp: target.createdAt,
            snippet: target.text
        ))

        #expect(model.route == .conversation(conversation.id))
        #expect(model.selectedConversation?.messages.count == messages.count)
        #expect(model.requestedMessageJumpID == target.id)
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
