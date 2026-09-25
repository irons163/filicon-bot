import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconAgents
@testable import Filicon

private struct DirectPublicationProvider: AIProvider {
    let publishes: Bool
    let toolSupport: Bool
    var replyMode: String? = nil
    var cloudID: String? = nil
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
                if replyMode != nil {
                    #expect(request.messages.contains { $0.role == .system && $0.text.contains("This is a direct conversation.") })
                    #expect(!request.messages.contains { $0.role == .system && $0.text.contains("Private foreign message") })
                }
                continuation.yield(.textDelta(toolSupport ? "PRIVATE DRAFT" : "Plain answer"))
                if toolSupport { continuation.yield(.reasoningDelta("PRIVATE REASONING")) }
                if toolSupport && publishes && request.toolExchanges.count < 2 {
                    let index = request.toolExchanges.count
                    var arguments = ["type": "text", "content": index == 0 ? "Progress" : "Result"]
                    if let cloudID, index == 0 {
                        arguments = ["type": "cursor-agent", "bcId": cloudID]
                    }
                    if replyMode == "current" {
                        arguments["reply_to"] = request.messages.last(where: { $0.role == .user })?.id.uuidString
                    } else if replyMode == "foreign" {
                        arguments["reply_to"] = "00000000-0000-0000-0000-000000000123"
                    } else if replyMode == "receipt", index == 1 {
                        let result = try #require(request.toolExchanges.first?.results.first?.wireText)
                        let start = try #require(result.range(of: "Saved message receipt: ")?.upperBound)
                        let end = try #require(result[start...].firstIndex(of: "}"))
                        let json = try #require(JSONSerialization.jsonObject(with: Data(result[start...end].utf8)) as? [String: String])
                        arguments["reply_to"] = try #require(json["messageID"])
                    }
                    let call = try NormalizedToolCall(id: .init(rawValue: "publish-\(index)"), name: "SendMessage",
                        argumentsJSON: JSONEncoder().encode(arguments))
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
    var replyToUser = false
    let descriptor = ProviderDescriptor(id: "delayed-direct-test", displayName: "Delayed direct test", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    if request.toolExchanges.isEmpty {
                        entered.yield(())
                        for await _ in release { break }
                        var arguments = ["text": "LATE MESSAGE"]
                        if replyToUser { arguments["reply_to"] = request.messages.last(where: { $0.role == .user })?.id.uuidString }
                        let call = try NormalizedToolCall(id: "late-publication", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(arguments))
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
    @Test @MainActor func cloudReferenceIsSavedAndCanBeRepliedTo() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-cloud-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        let reference = try CursorAgentReference(bcID: "remote / 設計?#")
        await model.registry.register(DirectPublicationProvider(publishes: true, toolSupport: true,
            replyMode: "receipt", cloudID: reference.bcID))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "direct-publication-test"
        model.conversations[ci].modelID = "test"
        await model.refreshModels()
        model.draft = "Reference the cloud task"
        model.send()
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        let messages = saved.messages.filter { $0.role == .assistant && !$0.text.isEmpty }
        expectNoDifference(messages.map(\.text), [reference.summary, "Result"])
        let first = try #require(messages.first)
        let card = try #require(first.transcriptCards.first)
        expectNoDifference(card.externalCursorReference, reference)
        expectNoDifference(card.actions.count, 0)
        expectNoDifference(messages.last?.replyToMessageID, first.id)
        expectNoDifference(model.conversations[ci].messages.first(where: { $0.id == first.id })?.transcriptCards,
            first.transcriptCards)
        expectNoDifference(card.externalCursorReference?.url.host, "cursor.com")
    }

    @Test(arguments: ["current", "receipt", "foreign"]) @MainActor
    func directRepliesUseOnlySavedSameConversationTargets(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-reply-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DirectPublicationProvider(publishes: true, toolSupport: true, replyMode: mode))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        // A real message in another conversation must never enter this directory.
        var foreign = Conversation(title: "Foreign", providerID: "fake", modelID: "fake-stream")
        let foreignID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000123"))
        foreign.messages = [.init(id: foreignID, role: .user, text: "Private foreign message")]
        model.conversations.append(foreign)
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
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        let messages = saved.messages.filter { $0.role == .assistant && !$0.text.isEmpty }
        if mode == "foreign" { expectNoDifference(messages.count, 0) }
        else {
            expectNoDifference(messages.map(\.text), ["Progress", "Result"])
            let first = try #require(messages.first)
            let last = try #require(messages.last)
            let user = try #require(saved.messages.first(where: { $0.role == .user }))
            expectNoDifference(first.replyToMessageID, mode == "current" ? user.id : nil)
            expectNoDifference(last.replyToMessageID, mode == "current" ? user.id : first.id)
        }
    }

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

    @Test(.timeLimit(.minutes(1)), arguments: ["stop", "account", "delete", "target-deleted"]) @MainActor
    func latePublicationsCannotOutliveTheirHostScope(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-fence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (entered, ready) = AsyncStream<Void>.makeStream()
        let (release, resume) = AsyncStream<Void>.makeStream()
        defer { ready.finish(); resume.finish() }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DelayedDirectPublicationProvider(entered: ready, release: release, replyToUser: action == "target-deleted"))
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
        else if action == "target-deleted" {
            let user = try #require(model.conversations[ci].messages.first(where: { $0.role == .user }))
            model.deleteMessage(id: user.id)
        }
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
