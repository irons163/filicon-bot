import Foundation
import Testing
import FiliconDomain
import FiliconAppServices

@Suite("ConversationStore paged app integration")
struct ConversationPagingIntegrationTests {
    @Test func metadataBootstrapAndMessageWindowsStayBounded() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FiliconPaging-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let large = Conversation(
            title: "Large",
            messages: (0..<250).map { ChatMessage(role: .user, text: "m\($0)") },
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let other = Conversation(title: "Other", updatedAt: Date(timeIntervalSince1970: 1))
        try await store.save([large, other])

        let metadata = try await store.conversationPage(limit: 1)
        #expect(metadata.items.count == 1)
        #expect(metadata.items[0].id == large.id)
        #expect(metadata.items[0].messages.isEmpty)
        let metadataContinuation = try #require(metadata.continuation)
        let remaining = try await store.conversationPage(after: metadataContinuation, limit: 1)
        #expect(remaining.items.map(\.id) == [other.id])

        let newest = try await store.messagePage(conversationID: large.id, limit: 100)
        #expect(newest.items.count == 100)
        #expect(newest.items.first?.text == "m150")
        #expect(newest.items.last?.text == "m249")
        #expect(newest.continuation != nil)
    }

    @Test func partialWindowUpsertPreservesUnseenRowsAndPropagatesLoadedDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "FiliconPagedWrite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let original = Conversation(
            title: "Before",
            messages: (0..<150).map { ChatMessage(role: .user, text: "m\($0)") }
        )
        let neverLoadedByApp = Conversation(
            title: "Unseen conversation",
            messages: [.init(role: .user, text: "must survive")]
        )
        try await store.save([original, neverLoadedByApp])
        let page = try await store.messagePage(conversationID: original.id, limit: 100)
        let deletedID = try #require(page.items.first?.id)

        var partial = original
        partial.title = "After"
        partial.messages = Array(page.items.dropFirst())
        let loadedIDs = Set(page.items.map(\.id))
        try await store.upsert(partial, replacingLoadedMessageIDs: loadedIDs, historyComplete: false)

        let stored = try #require(try await store.conversation(id: original.id))
        #expect(stored.title == "After")
        #expect(stored.messages.count == 149)
        #expect(!stored.messages.contains(where: { $0.id == deletedID }))
        #expect(stored.messages.first?.text == "m0")
        #expect(stored.messages.last?.text == "m149")
        let untouched = try #require(try await store.conversation(id: neverLoadedByApp.id))
        #expect(untouched.messages.map(\.text) == ["must survive"])
    }
}
