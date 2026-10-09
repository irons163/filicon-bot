import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconAgents
@testable import Filicon

private final class DirectReactionQuotaFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var count = 0
    func arm() { lock.withLock { armed = true } }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        try lock.withLock {
            if armed, point == .afterCommitPersist {
                armed = false; count += 1
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
    func injectedCount() -> Int { lock.withLock { count } }
}

private struct DirectPublicationProvider: AIProvider {
    let publishes: Bool
    let toolSupport: Bool
    var replyMode: String? = nil
    var cloudID: String? = nil
    var expectedAgentInstructions: String? = nil
    var reacts = false
    var armReaction: @Sendable () -> Void = {}
    var descriptor: ProviderDescriptor {
        .init(id: "direct-publication-test", displayName: "Direct publication test",
              requiresAPIKey: false, supportsToolCalling: toolSupport)
    }
    func models() async throws -> [AIModel] {
        [.init(id: "test", capabilities: .init(inputModalities: [.text, .document]))]
    }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let tools = request.tools.map(\.name)
                if let expectedAgentInstructions {
                    #expect(request.messages.contains { $0.role == .system && $0.text.contains(expectedAgentInstructions) })
                }
                if toolSupport { #expect(tools.contains("SendMessage")) }
                else { #expect(!tools.contains("SendMessage")) }
                if replyMode != nil {
                    #expect(request.messages.contains { $0.role == .system && $0.text.contains("This is a direct conversation.") })
                    #expect(request.messages.contains { $0.role == .system && $0.text.contains("[descriptive label](sand-msg:<shortAddress>)") })
                    #expect(!request.messages.contains { $0.role == .system && $0.text.contains("Inline sand-msg navigation is not available here.") })
                    #expect(!request.messages.contains { $0.role == .system && $0.text.contains("Private foreign message") })
                }
                continuation.yield(.textDelta(toolSupport ? "PRIVATE DRAFT" : "Plain answer"))
                if toolSupport { continuation.yield(.reasoningDelta("PRIVATE REASONING")) }
                if reacts && request.toolExchanges.isEmpty {
                    armReaction()
                    #expect(tools.contains("ReactToMessage"))
                    let address = try #require(request.messages.last(where: { $0.role == .user })?.shortAddress)
                    let call = try NormalizedToolCall(id: "direct-tap", name: "ReactToMessage",
                        argumentsJSON: JSONEncoder().encode(["message_address": address, "emoji": "👍"]))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else if toolSupport && publishes && request.toolExchanges.count < 2 {
                    let index = request.toolExchanges.count
                    var arguments = ["type": "text", "content": index == 0 ? "Progress" : "Result"]
                    if let cloudID, index == 0 {
                        arguments = ["type": "cursor-agent", "bcId": cloudID]
                    }
                    if replyMode == "current" {
                        arguments["reply_to"] = request.messages.last(where: { $0.role == .user })?.id.uuidString
                    } else if replyMode == "current-short" {
                        arguments["reply_to"] = try #require(request.messages.last(where: { $0.role == .user })?.shortAddress)
                    } else if replyMode == "foreign" {
                        arguments["reply_to"] = "00000000-0000-0000-0000-000000000123"
                    } else if (replyMode == "receipt" || replyMode == "receipt-short"), index == 1 {
                        let result = try #require(request.toolExchanges.first?.results.first?.wireText)
                        let start = try #require(result.range(of: "Saved message receipt: ")?.upperBound)
                        let end = try #require(result[start...].firstIndex(of: "}"))
                        let json = try #require(JSONSerialization.jsonObject(with: Data(result[start...end].utf8)) as? [String: String])
                        arguments["reply_to"] = try #require(json[replyMode == "receipt-short" ? "shortAddress" : "messageID"])
                    }
                    let call = try NormalizedToolCall(id: .init(rawValue: "publish-\(index)"), name: "SendMessage",
                        argumentsJSON: JSONEncoder().encode(arguments))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    if reacts {
                        let result = try #require(request.toolExchanges.last?.results.first)
                        #expect(!result.isError)
                        #expect(result.wireText.contains("Added 👍"))
                    }
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct DelayedDirectPublicationProvider: AIProvider {
    let entered: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    var replyToUser = false
    var reacts = false
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
                        if reacts {
                            arguments = ["message_address": try #require(request.messages.last(where: { $0.role == .user })?.shortAddress), "emoji": "👍"]
                        }
                        let call = try NormalizedToolCall(id: "late-publication", name: reacts ? "ReactToMessage" : "SendMessage",
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
    @Test(.timeLimit(.minutes(1)), arguments: ["stop", "account", "private-aba", "rebind-aba", "reasoning-aba", "navigate"])
    @MainActor func lateDirectReactionsCannotOutliveOriginalRun(action: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-reaction-fence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = AsyncStream<Void>.makeStream(), release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DelayedDirectPublicationProvider(entered: entered.continuation,
            release: release.stream, reacts: true))
        let originalProfile = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "Original",
            providerID: "delayed-direct-test", modelID: "test"))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        let binding = DirectConversationAgentBinding(accountID: "local", agentID: originalProfile.id)
        model.conversations[ci].providerID = originalProfile.providerID
        model.conversations[ci].modelID = originalProfile.modelID
        model.conversations[ci].agentBinding = binding
        await model.refreshModels()
        model.draft = "Thank you"
        model.send()
        for await _ in entered.stream { break }
        switch action {
        case "stop": model.cancel()
        case "account": await model.cancelAutoReviewApprovals(nextAccountID: "another-account")
        case "private-aba":
            var changed = originalProfile; changed.instructions = "Changed"
            #expect(await model.updateAgent(changed))
            #expect(await model.updateAgent(originalProfile))
        case "navigate": model.addConversation()
        case "reasoning-aba":
            let original = model.conversations[ci].reasoningEffort
            model.conversations[ci].reasoningEffort = original == .high ? .low : .high
            model.conversations[ci].reasoningEffort = original
        default:
            model.conversations[ci].agentBinding = nil
            model.conversations[ci].agentBinding = binding
        }
        release.continuation.yield(())
        for _ in 0..<1000 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        if action == "navigate" {
            #expect(model.selection != id)
            let user = try #require(saved.messages.last(where: { $0.role == .user }))
            expectNoDifference(user.reactions, [.init(emoji: "👍", actorID: "agent:\(originalProfile.id.uuidString)")])
            let projected = try #require(model.conversations.first { $0.id == id })
            expectNoDifference(projected.messages.first(where: { $0.id == user.id })?.reactions, user.reactions)
            for chat in model.conversations where chat.id != id {
                for message in chat.messages { expectNoDifference(message.reactions, []) }
            }
        } else {
            for message in saved.messages { expectNoDifference(message.reactions, []) }
            for message in model.conversations.flatMap(\.messages) { expectNoDifference(message.reactions, []) }
        }
    }

    @Test(arguments: [false, true]) @MainActor
    func boundDirectModelActuallySavesReactionInOriginalConversation(postCommitQuotaFailure: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-reaction-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = DirectReactionQuotaFault()
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            quotaFaultInjector: { try fault.inject($0) })
        await model.bootstrap()
        await model.registry.register(DirectPublicationProvider(publishes: false, toolSupport: true, reacts: true,
            armReaction: { if postCommitQuotaFailure { fault.arm() } }))
        let agent = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "React sparingly",
            providerID: "direct-publication-test", modelID: "test"))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = agent.providerID
        model.conversations[ci].modelID = agent.modelID
        model.conversations[ci].agentBinding = .init(accountID: "local", agentID: agent.id)
        await model.refreshModels()
        model.draft = "Thank you"
        model.send()
        for _ in 0..<1000 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        #expect(postCommitQuotaFailure ? model.errorMessage != nil : model.errorMessage == nil)
        expectNoDifference(fault.injectedCount(), postCommitQuotaFailure ? 1 : 0)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        let user = try #require(saved.messages.last(where: { $0.role == .user }))
        expectNoDifference(user.reactions, [.init(emoji: "👍", actorID: "agent:\(agent.id.uuidString)")])
        expectNoDifference(model.conversations.first(where: { $0.id == id })?.messages.first(where: { $0.id == user.id })?.reactions,
            user.reactions)
        #expect(!saved.messages.contains { $0.text.contains("PRIVATE DRAFT") || $0.reasoningText.contains("PRIVATE REASONING") })
        #expect(!saved.messages.contains { $0.role == .assistant })
    }

    @Test(arguments: ["instructions", "archive", "unbind"])
    @MainActor func queuedBoundTurnRevalidatesBeforeProviderStarts(change: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-bound-queue-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DirectPublicationProvider(publishes: false, toolSupport: false))
        var agent = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "Original",
            providerID: "direct-publication-test", modelID: "test"))
        let agentID = agent.id
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = agent.providerID
        model.conversations[ci].modelID = agent.modelID
        model.conversations[ci].agentBinding = .init(accountID: "local", agentID: agentID)
        await model.refreshModels()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let blocker = Task {
            try await model.agentExecutionScheduler.withExclusiveAccess(agentID: agentID) {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            }
        }
        defer { release.continuation.finish(); blocker.cancel() }
        for await _ in entered.stream { break }
        model.draft = "Review"
        model.send()
        for _ in 0..<600 {
            if await model.agentExecutionScheduler.snapshot(agentID: agentID).queuedCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let queued = await model.agentExecutionScheduler.snapshot(agentID: agentID)
        expectNoDifference(queued.queuedCount, 1)
        if change == "instructions" {
            agent.instructions = "Changed after enqueue"
            #expect(await model.updateAgent(agent))
        } else if change == "archive" { await model.archiveAgent(id: agentID) }
        else { model.conversations[ci].agentBinding = nil }
        release.continuation.finish()
        try await blocker.value
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        #expect(!model.conversations[ci].messages.contains { $0.text == "Plain answer" })
    }

    @Test(arguments: [false, true]) @MainActor
    func boundAgentUsesLiveIdentityOrRejectsArchivedAgent(archived: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-bound-direct-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        await model.registry.register(DirectPublicationProvider(publishes: false, toolSupport: false,
            expectedAgentInstructions: "Use the designer's accessibility checklist."))
        let agent = try #require(await model.createAgent(name: "Designer", summary: "Design review",
            instructions: "Use the designer's accessibility checklist.",
            providerID: "direct-publication-test", modelID: "test"))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = agent.providerID
        model.conversations[ci].modelID = agent.modelID
        model.conversations[ci].agentBinding = .init(accountID: "local", agentID: agent.id)
        if archived { await model.archiveAgent(id: agent.id) }
        await model.refreshModels()
        model.draft = "Review the design"
        model.send()
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let answers = model.conversations[ci].messages.filter { $0.role == .assistant && !$0.text.isEmpty }
        expectNoDifference(answers.map(\.text), archived ? [] : ["Plain answer"])
        if archived { #expect(model.errorMessage != nil) }
    }

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

    @Test(arguments: ["current", "receipt", "foreign", "current-short", "receipt-short"], [false, true]) @MainActor
    func directRepliesUseOnlySavedSameConversationTargets(mode: String, fileOnly: Bool) async throws {
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
        if fileOnly {
            let storage = AttachmentStore(rootURL: root.appending(path: "attachments"))
            let file = try await storage.ingest(data: Data("Report fixture".utf8),
                filename: "report.txt", declaredMIMEType: "text/plain")
            model.pendingAttachments = [file]
        }
        model.draft = fileOnly ? "" : "Please work"
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
            expectNoDifference(first.replyToMessageID, mode.hasPrefix("current") ? user.id : nil)
            expectNoDifference(last.replyToMessageID, mode.hasPrefix("current") ? user.id : first.id)
            expectNoDifference(user.shortAddress, "t0u")
            expectNoDifference(messages.map(\.shortAddress), ["t0s0", "t0s1"])
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
