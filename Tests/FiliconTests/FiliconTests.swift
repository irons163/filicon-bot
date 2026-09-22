import Foundation
import Testing
import CustomDump
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
    private var released = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func begin(_ id: UUID) {
        activeByConversation[id, default: 0] += 1; maximumByConversation[id] = max(maximumByConversation[id, default: 0], activeByConversation[id]!); totalActive += 1; maximumTotal = max(maximumTotal, totalActive)
    }
    func end(_ id: UUID) { activeByConversation[id, default: 1] -= 1; totalActive -= 1 }
    func hold() async throws {
        let token = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if released { return }
            try await withCheckedThrowingContinuation { waiters[token] = $0 }
        } onCancel: {
            Task { await self.cancelWait(token) }
        }
    }
    func release() {
        released = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
    private func cancelWait(_ token: UUID) { waiters.removeValue(forKey: token)?.resume(throwing: CancellationError()) }
}

struct ProbedProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "probe", displayName: "Probe", requiresAPIKey: false)
    let probe: ConcurrencyProbe
    func models() async throws -> [AIModel] { [.init(id: "probe")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.begin(request.conversationID)
                do {
                    try await probe.hold()
                    await probe.end(request.conversationID)
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch {
                    await probe.end(request.conversationID)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

@Test(.timeLimit(.minutes(1))) func coordinatorSerializesOneConversationButAllowsDifferentOnes() async throws {
    let probe = ConcurrencyProbe(), registry = ProviderRegistry()
    await registry.register(ProbedProvider(probe: probe))
    let coordinator = TurnCoordinator(registry: registry)
    let first = UUID(), second = UUID()
    func request(_ id: UUID) -> InferenceRequest { .init(conversationID: id, modelID: "probe", messages: []) }
    async let a: Void = coordinator.send(request: request(first), providerID: "probe") { _ in }
    async let b: Void = coordinator.send(request: request(first), providerID: "probe") { _ in }
    async let c: Void = coordinator.send(request: request(second), providerID: "probe") { _ in }
    // Hold both transports until the duplicate conversation is observably
    // queued. No assumption about how much work the machine can start in 80 ms.
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if await probe.totalActive == 2, await coordinator.queuedCount(conversationID: first) == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await probe.totalActive == 2)
    try #require(await coordinator.queuedCount(conversationID: first) == 1)
    await probe.release()
    _ = try await (a, b, c)
    let maxima = await probe.maximumByConversation, total = await probe.maximumTotal
    expectNoDifference(maxima, [first: 1, second: 1])
    expectNoDifference(total, 2)
    let remaining = await probe.totalActive
    expectNoDifference(remaining, 0)
}
