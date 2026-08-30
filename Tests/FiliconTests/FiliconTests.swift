import Foundation
import Testing
import FiliconDomain
import FiliconProviderKit
import FiliconAppServices

@Test func sseParserHandlesArbitraryChunks() {
    var parser = SSEParser()
    #expect(parser.feed(Data("event: message\nda".utf8)).isEmpty)
    #expect(parser.feed(Data("ta: {\"delta\":\"hi\"}\n\n".utf8)) == ["{\"delta\":\"hi\"}"])
    #expect(parser.feed(Data("data: one\ndata: two\n\n".utf8)) == ["one\ntwo"])
    #expect(parser.feed(Data("data: network\r\n\r\n".utf8)) == ["network"])
}

@Test func ndjsonParserHandlesSplitLinesAndEOF() {
    var parser = NDJSONParser()
    #expect(parser.feed(Data("{\"a\":".utf8)).isEmpty)
    #expect(parser.feed(Data("1}\n{\"b\":2".utf8)) == ["{\"a\":1}"])
    #expect(parser.finish() == ["{\"b\":2"])
}

@Test func conversationStoreRoundTripsAtomically() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConversationStore(fileURL: directory.appending(path: "conversations.json"))
    let expected = [Conversation(title: "Test", messages: [ChatMessage(role: .user, text: "hello")])]
    try await store.save(expected)
    let loaded = try await store.load()
    #expect(loaded.count == 1)
    #expect(loaded.first?.id == expected.first?.id)
    #expect(loaded.first?.title == "Test")
    #expect(loaded.first?.messages.first?.text == "hello")
    #expect(abs((loaded.first?.updatedAt.timeIntervalSince1970 ?? 0) - expected[0].updatedAt.timeIntervalSince1970) < 0.001)
    #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "conversations.json.tmp").path))
}

actor ConcurrencyProbe {
    var activeByConversation: [UUID: Int] = [:]
    var maximumByConversation: [UUID: Int] = [:]
    var totalActive = 0
    var maximumTotal = 0
    func begin(_ id: UUID) {
        activeByConversation[id, default: 0] += 1; maximumByConversation[id] = max(maximumByConversation[id, default: 0], activeByConversation[id]!); totalActive += 1; maximumTotal = max(maximumTotal, totalActive)
    }
    func end(_ id: UUID) { activeByConversation[id, default: 1] -= 1; totalActive -= 1 }
}

struct ProbedProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "probe", displayName: "Probe", requiresAPIKey: false)
    let probe: ConcurrencyProbe
    func models() async throws -> [AIModel] { [.init(id: "probe")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.begin(request.conversationID)
                try? await Task.sleep(for: .milliseconds(80))
                await probe.end(request.conversationID)
                continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@Test func coordinatorSerializesOneConversationButAllowsDifferentOnes() async throws {
    let probe = ConcurrencyProbe(), registry = ProviderRegistry()
    await registry.register(ProbedProvider(probe: probe))
    let coordinator = TurnCoordinator(registry: registry)
    let first = UUID(), second = UUID()
    func request(_ id: UUID) -> InferenceRequest { .init(conversationID: id, modelID: "probe", messages: []) }
    async let a: Void = coordinator.send(request: request(first), providerID: "probe") { _ in }
    async let b: Void = coordinator.send(request: request(first), providerID: "probe") { _ in }
    async let c: Void = coordinator.send(request: request(second), providerID: "probe") { _ in }
    _ = try await (a, b, c)
    #expect(await probe.maximumByConversation[first] == 1)
    #expect(await probe.maximumTotal >= 2)
}
