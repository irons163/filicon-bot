import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private final class PublicationSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let point: StorageQuotaFaultPoint
    init(_ point: StorageQuotaFaultPoint) { self.point = point }
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if armed && self.point == point {
            armed = false
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private struct RetryingPublicationProvider: AIProvider {
    let fault: PublicationSaveFault
    let failSecond: Bool
    let descriptor = ProviderDescriptor(id: "publication-failure", displayName: "Publication failure", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let count = request.toolExchanges.count
                let failureIndex = failSecond ? 1 : 0
                if count == failureIndex { fault.arm() }
                if count == failureIndex + 1 {
                    let result = try #require(request.toolExchanges.last?.results.first)
                    #expect(result.isError)
                    #expect(!result.wireText.contains("Saved message receipt:"))
                }
                if count < failureIndex + 2 {
                    let call = try NormalizedToolCall(id: .init(rawValue: "attempt-\(count)"), name: "SendMessage",
                        argumentsJSON: JSONEncoder().encode(["text": failSecond && count == 0 ? "Progress" : "Retry-safe answer"]))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    let result = try #require(request.toolExchanges.last?.results.first)
                    #expect(!result.isError)
                    #expect(result.wireText.contains("Saved message receipt:"))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Direct publication save failures")
struct DirectPublicationFailureTests {
    @Test(arguments: [StorageQuotaFaultPoint.afterTemporaryWriteBeforeRename, .afterReservationPersist, .afterCommitPersist], [true, false])
    @MainActor func failedSaveHasNoSuccessReceiptAndCanRetry(point: StorageQuotaFaultPoint, failSecond: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-save-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = PublicationSaveFault(point)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            quotaFaultInjector: { try fault.inject($0) })
        await model.bootstrap()
        await model.registry.register(RetryingPublicationProvider(fault: fault, failSecond: failSecond))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "publication-failure"
        model.conversations[ci].modelID = "test"
        await model.refreshModels()
        model.draft = "Please answer"
        model.send()
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let expected = failSecond ? ["Progress", "Retry-safe answer"] : ["Retry-safe answer"]
        expectNoDifference(model.conversations[ci].messages.filter { $0.role == .assistant }.map(\.text), expected)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        expectNoDifference(saved.messages.filter { $0.role == .assistant }.map(\.text), expected)
        let memory = try await store.recentTurnMemory(conversationID: id)
        expectNoDifference(memory.count, expected.count)
        let ledger = try StorageQuotaLedger.live(dataRoot: root)
        let usage = await ledger.usage()
        expectNoDifference(usage.reservationCount, 0)
        expectNoDifference(usage.projectedBytes, usage.committedBytes)
    }
}
