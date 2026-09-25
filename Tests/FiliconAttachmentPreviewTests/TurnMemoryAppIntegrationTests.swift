import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor TurnMemoryRequestProbe {
    private var requests: [InferenceRequest] = []
    func append(_ request: InferenceRequest) { requests.append(request) }
    func values() -> [InferenceRequest] { requests }
}

private struct SuccessfulTurnMemoryProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "memory-app", displayName: "Memory app", requiresAPIKey: false)
    let probe: TurnMemoryRequestProbe

    func models() async throws -> [AIModel] { [.init(id: "memory-app-model")] }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if request.toolExchanges.isEmpty {
                        await probe.append(request)
                        let call = try NormalizedToolCall(id: "publish-answer", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(["text": "durable answer"]))
                        continuation.yield(.responseStarted(id: UUID().uuidString))
                        continuation.yield(.textDelta("private draft"))
                        continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                        continuation.yield(.toolCallCompleted(call))
                        continuation.yield(.completed(.toolUse))
                    } else { continuation.yield(.completed(.stop)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
        }
    }
}

@Suite("Turn memory app integration")
struct TurnMemoryAppIntegrationTests {
    @Test @MainActor func successfulPersistedTurnsCommitMemoryWithoutDuplicatingHydratedInference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-turn-memory-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        let probe = TurnMemoryRequestProbe()
        await model.registry.register(SuccessfulTurnMemoryProvider(probe: probe))
        let conversationID = try #require(model.selection)
        let index = try #require(model.conversations.firstIndex(where: { $0.id == conversationID }))
        model.conversations[index].providerID = "memory-app"
        model.conversations[index].modelID = "memory-app-model"
        await model.refreshModels()

        model.draft = "first question"
        model.send()
        #expect(await Self.waitUntil {
            let requestCount = await probe.values().count
            return !model.running.contains(conversationID) && requestCount == 1
        })

        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        #expect(try await store.recentTurnMemory(conversationID: conversationID).count == 1)

        model.draft = "second question"
        model.send()
        #expect(await Self.waitUntil {
            let requestCount = await probe.values().count
            return !model.running.contains(conversationID) && requestCount == 2
        })
        let requests = await probe.values()
        // Live host metadata accompanies inference, not durable conversation
        // memory. It must occur once and must not duplicate hydrated messages.
        let hostContext = requests[1].messages.filter { $0.role == .system }
        expectNoDifference(hostContext.count, 2)
        expectNoDifference(hostContext.filter { $0.text.hasPrefix("Current Filicon host-tool permissions") }.count, 1)
        expectNoDifference(hostContext.filter { $0.text.contains("SendMessage publishes text") }.count, 1)
        let transcript = requests[1].messages.filter { $0.role != .system }
        expectNoDifference(transcript.map(\.role), [.user, .assistant, .user])
        expectNoDifference(transcript.map(\.text), ["first question", "durable answer", "second question"])
        #expect(!model.conversations[index].messages.contains { $0.role == .system })
        let reopenedStore = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        #expect(try await reopenedStore.recentTurnMemory(conversationID: conversationID).count == 2)
    }

    @MainActor private static func waitUntil(
        attempts: Int = 400,
        _ predicate: @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
