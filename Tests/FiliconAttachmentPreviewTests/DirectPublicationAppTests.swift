import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private struct DirectPublicationProvider: AIProvider {
    let publishes: Bool
    let toolSupport: Bool
    var descriptor: ProviderDescriptor {
        .init(id: "direct-publication-test", displayName: "Direct publication test",
              requiresAPIKey: false, supportsToolCalling: toolSupport)
    }
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let tools = request.tools.map(\.name)
                if toolSupport { #expect(tools.contains("SendMessage")) }
                else { #expect(!tools.contains("SendMessage")) }
                continuation.yield(.textDelta(toolSupport ? "PRIVATE DRAFT" : "Plain answer"))
                if toolSupport { continuation.yield(.reasoningDelta("PRIVATE REASONING")) }
                if toolSupport && publishes && request.toolExchanges.count < 2 {
                    let index = request.toolExchanges.count
                    let call = try NormalizedToolCall(id: .init(rawValue: "publish-\(index)"), name: "SendMessage",
                        argumentsJSON: JSONEncoder().encode(["type": "text", "content": index == 0 ? "Progress" : "Result"]))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else { continuation.yield(.completed(.stop)) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct DelayedDirectPublicationProvider: AIProvider {
    let entered: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    let descriptor = ProviderDescriptor(id: "delayed-direct-test", displayName: "Delayed direct test", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if request.toolExchanges.isEmpty {
                        entered.yield(())
                        for await _ in release { break }
                        let call = try NormalizedToolCall(id: "late-publication", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(["text": "LATE MESSAGE"]))
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

@Suite("Direct conversation publications")
struct DirectPublicationAppTests {
    @Test @MainActor func offlineDemoKeepsItsTextOnlyAnswer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-demo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        #expect(!FakeProvider().descriptor.supportsToolCalling)
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "fake"
        model.conversations[ci].modelID = "fake-stream"
        await model.refreshModels()
        model.draft = "Hello"
        model.send()
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        expectNoDifference(model.conversations[ci].messages.last?.text, "Hello from Filicon.")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["stop", "account", "delete"]) @MainActor
    func latePublicationsCannotOutliveTheirHostScope(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-fence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (entered, ready) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { ready.finish(); resume.finish() }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DelayedDirectPublicationProvider(entered: ready, release: release))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "delayed-direct-test"
        model.conversations[ci].modelID = "test"
        await model.refreshModels()
        model.draft = "Please work"
        model.send()
        for await _ in entered { break }
        if action == "stop" { model.cancel() }
        else if action == "delete" { model.deleteConversation(id: id) }
        else { await model.cancelAutoReviewApprovals(nextAccountID: "another-account") }
        resume.yield(())
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        #expect(!model.conversations.flatMap(\.messages).contains { $0.text.contains("LATE MESSAGE") })
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let durable = try await store.load()
        #expect(!durable.flatMap(\.messages).contains { $0.text.contains("LATE MESSAGE") })
    }

    @Test(arguments: [true, false], [true, false]) @MainActor
    func publicationsAreSeparateDurableMessagesWithoutPrivateDrafts(toolSupport: Bool, publishes: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DirectPublicationProvider(publishes: publishes, toolSupport: toolSupport))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "direct-publication-test"
        model.conversations[ci].modelID = "test"
        await model.refreshModels()
        model.draft = "Please work"
        model.send()
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let expected = toolSupport ? (publishes ? ["Progress", "Result"] : []) : ["Plain answer"]
        let messages = model.conversations[ci].messages.filter { $0.role == .assistant }
        if toolSupport && !publishes { expectNoDifference(messages.count, 0) }
        expectNoDifference(messages.map(\.text).filter { !$0.isEmpty }, expected)
        #expect(messages.allSatisfy { $0.reasoningText.isEmpty })
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let durable = try await store.load()
        let saved = try #require(durable.first(where: { $0.id == id }))
        expectNoDifference(saved.messages.filter { $0.role == .assistant }.map(\.text).filter { !$0.isEmpty }, expected)
        #expect(!String(decoding: try JSONEncoder().encode(saved), as: UTF8.self).contains("PRIVATE"))
        let memory = try await store.recentTurnMemory(conversationID: id)
        expectNoDifference(memory.count, expected.count)
    }
}
