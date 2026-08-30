import XCTest
import FiliconAppServices
import FiliconDomain
import FiliconPersistence

final class ConversationStoreTranscriptTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-store-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func message(_ role: MessageRole, _ text: String, id: UUID = UUID(), date: TimeInterval = 1) -> ChatMessage {
        ChatMessage(id: id, role: role, text: text, createdAt: Date(timeIntervalSince1970: date))
    }

    func testStorePublishesExactUpdateRemoveAndClearTransactions() async throws {
        let root = try root()
        let store = ConversationStore(fileURL: root.appendingPathComponent("conversations.json"))
        let id = UUID()
        let first = message(.user, "one")
        try await store.upsert(Conversation(id: id, messages: [first]), replacingLoadedMessageIDs: [], historyComplete: true)
        let subscription = try await store.subscribeTranscript(conversationID: id)
        XCTAssertEqual(subscription.snapshot.messages, [first])
        var iterator = subscription.events.makeAsyncIterator()

        var updated = first
        updated.text = "two"
        try await store.upsert(Conversation(id: id, messages: [updated]), replacingLoadedMessageIDs: [first.id], historyComplete: true)
        let updateEvent = try await iterator.next()
        XCTAssertEqual(updateEvent?.mutations, [.update(updated)])

        try await store.upsert(Conversation(id: id, messages: []), replacingLoadedMessageIDs: [first.id], historyComplete: true)
        let clearEvent = try await iterator.next()
        XCTAssertEqual(clearEvent?.mutations, [.clear])
    }

    func testPagedUpsertPreservesUnseenMessagesInCanonicalAndReplica() async throws {
        let root = try root()
        let store = ConversationStore(fileURL: root.appendingPathComponent("conversations.json"))
        let id = UUID()
        let older = message(.user, "older")
        let newer = message(.assistant, "newer", date: 2)
        try await store.upsert(Conversation(id: id, messages: [older, newer]), replacingLoadedMessageIDs: [], historyComplete: true)

        var changed = newer
        changed.text = "changed"
        try await store.upsert(Conversation(id: id, messages: [changed]), replacingLoadedMessageIDs: [newer.id], historyComplete: false)
        let canonical = try await store.conversation(id: id)
        XCTAssertEqual(canonical?.messages, [older, changed])
        let replica = try await store.subscribeTranscript(conversationID: id)
        XCTAssertEqual(replica.snapshot.messages, [older, changed])
    }

    func testDeleteFencesSubscriberAndRecreateStartsClean() async throws {
        let root = try root()
        let store = ConversationStore(fileURL: root.appendingPathComponent("conversations.json"))
        let id = UUID()
        try await store.upsert(Conversation(id: id, messages: [message(.user, "old")]), replacingLoadedMessageIDs: [], historyComplete: true)
        let subscription = try await store.subscribeTranscript(conversationID: id)
        var iterator = subscription.events.makeAsyncIterator()
        try await store.delete(id: id)
        await XCTAssertStoreThrowsErrorAsync { try await iterator.next() }

        let fresh = message(.user, "fresh")
        try await store.upsert(Conversation(id: id, messages: [fresh]), replacingLoadedMessageIDs: [], historyComplete: true)
        let recreated = try await store.subscribeTranscript(conversationID: id)
        XCTAssertEqual(recreated.snapshot.messages, [fresh])
        XCTAssertNotEqual(recreated.snapshot.fence.generation, subscription.snapshot.fence.generation)
    }

    func testTurnMemoryPersistsIsBoundedAndRejectsMissingOrForeignEvidence() async throws {
        let root = try root()
        let id = UUID()
        var messages: [ChatMessage] = []
        let store = ConversationStore(fileURL: root.appendingPathComponent("conversations.json"))
        for index in 0..<22 {
            let user = message(.user, "u\(index)", date: TimeInterval(index * 2 + 1))
            let assistant = message(.assistant, "a\(index)", date: TimeInterval(index * 2 + 2))
            messages += [user, assistant]
            try await store.upsert(Conversation(id: id, messages: messages), replacingLoadedMessageIDs: Set(messages.map(\.id)), historyComplete: true)
            _ = try await store.recordFinalAssistantTurn(conversationID: id, userMessageID: user.id, assistantMessageID: assistant.id)
        }
        let bounded = try await store.recentTurnMemory(conversationID: id)
        XCTAssertEqual(bounded.count, 20)

        let memoryURL = root.appendingPathComponent("conversation-replicas/\(id.uuidString.lowercased())/turn-memory.json")
        let reopened = try TurnMemoryBuffer.hydrate(Data(contentsOf: memoryURL), expectedConversationID: id, capacity: 20)
        let hydrated = await reopened.snapshot().exchanges
        XCTAssertEqual(hydrated.map(\.user), (2..<22).map { "u\($0)" })
        await XCTAssertStoreThrowsErrorAsync {
            try await store.recordFinalAssistantTurn(conversationID: id, userMessageID: UUID(), assistantMessageID: messages.last!.id)
        }
        await XCTAssertStoreThrowsErrorAsync {
            try await store.recordFinalAssistantTurn(conversationID: UUID(), userMessageID: messages[0].id, assistantMessageID: messages[1].id)
        }
    }
}

private func XCTAssertStoreThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}
