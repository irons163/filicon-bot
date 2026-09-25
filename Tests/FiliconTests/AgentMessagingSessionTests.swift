import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private struct MessagingProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "messaging-test", displayName: "Messaging fixture", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor MessagingProbe {
    var requests: [InferenceRequest] = []
    var authorizations: [(UUID, UUID, String)] = []
    var messages: [RoomMessage] = []
    var contexts: [ToolContext] = []
    var peerMessages: [(AgentMessageSource, RoomMessage)] = []
    func request(_ value: InferenceRequest) -> Int { requests.append(value); return requests.count }
    func authorize(_ sender: AgentProfile, _ recipient: AgentProfile, _ text: String) { authorizations.append((sender.id, recipient.id, text)) }
    func update(_ message: RoomMessage) { messages.append(message) }
    func context(_ value: ToolContext) { contexts.append(value) }
    func peer(_ source: AgentMessageSource, _ value: RoomMessage) { peerMessages.append((source, value)) }
}

private struct MailboxVoiceProvider: AIProvider {
    let mode: String
    var descriptor: ProviderDescriptor {
        .init(id: "messaging-test", displayName: "Voice fixture", requiresAPIKey: false,
              supportsToolCalling: mode != "text-only")
    }
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            do {
                if !["text-only", "silent", "unconfigured"].contains(mode), request.toolExchanges.isEmpty {
                    #expect(request.tools.contains { $0.name == "SendMessage" && $0.description?.contains("only voice") == true })
                    let call = try NormalizedToolCall(id: "voice", name: mode == "none" ? "fixture_read" : "SendMessage",
                        argumentsJSON: Data((mode == "none" ? "{}" : mode == "failed" ? #"{"text":""}"# : #"{"text":"Published result"}"#).utf8))
                    continuation.yield(.textDelta("PRIVATE INTERMEDIATE DRAFT"))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    continuation.yield(.textDelta(["text-only", "unconfigured"].contains(mode) ? "Plain model answer" : "PRIVATE FINAL DRAFT"))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct MessagingReadTool: ToolExecutor {
    let probe: MessagingProbe
    let descriptor = ToolDescriptor(name: "fixture_read", inputSchema: Data(#"{"type":"object","properties":{},"additionalProperties":false}"#.utf8))
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await probe.context(context)
        return .init(callID: call.id, content: [.text("actual host result")])
    }
}

private func sendCall(_ target: UUID, _ text: String = "Review the layout", id: ToolCallID = "send") throws -> NormalizedToolCall {
    try .init(id: id, name: "SendToAgent", argumentsJSON: JSONEncoder().encode(["recipientID": target.uuidString, "message": text]))
}

private func prioritySendCall(_ target: UUID, _ text: String, id: ToolCallID = "urgent") throws -> NormalizedToolCall {
    struct Payload: Encodable { let recipientID: UUID; let message: String; let priority = true }
    return try .init(id: id, name: "SendToAgent", argumentsJSON: JSONEncoder().encode(Payload(recipientID: target, message: text)))
}

@Suite("SendToAgent messaging session", .timeLimit(.minutes(1)))
struct AgentMessagingSessionTests {
    @Test(arguments: ["valid", "author", "scope", "identity", "text", "pending"])
    func finalReceiptIsAtomicAndPreservesFullText(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let incoming = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Report",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            delivery: .init(chainID: UUID(), originConversationID: f.origin))
        try await f.messenger.send(incoming)
        try await f.messenger.updateDelivery(id: incoming.id, state: .running)
        let before = await f.messenger.allMessages()
        let text = String(repeating: "Full report. ", count: 1_000)
        let report = RoomMessage(id: mode == "identity" ? incoming.id : UUID(),
            groupID: mode == "scope" ? UUID() : f.origin,
            senderID: mode == "author" ? f.sender.id : f.recipient.id,
            text: mode == "text" ? "Different text" : text,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        if mode == "valid" {
            try await f.messenger.updateDelivery(id: incoming.id, state: .completed, response: text, finalPublication: report)
            let saved = try #require(await f.messenger.allMessages().first)
            expectNoDifference(saved.delivery?.finalPublication, report)
            expectNoDifference(saved.delivery?.response, String(text.prefix(8_000)))
            let restored = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
            let reopened = await restored.allMessages().first
            expectNoDifference(reopened, saved)
        } else {
            await #expect(throws: AgentPublicationError.invalid) {
                try await f.messenger.updateDelivery(id: incoming.id, state: mode == "pending" ? .running : .completed,
                    response: text, finalPublication: report)
            }
            let after = await f.messenger.allMessages()
            expectNoDifference(after, before)
        }
    }

    @Test func textOnlyProjectionFailurePreservesDurableIdentity() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MailboxVoiceProvider(mode: "text-only"))
        let session = f.session()
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Report")
        try await session.drain(onPeerMessage: { source, message in
            await f.probe.peer(source, message)
            if source.kind == .publication { throw AgentMessagingError.scopeMismatch }
        })
        let saved = try #require(await f.messenger.allMessages().first)
        let report = try #require(saved.delivery?.finalPublication)
        expectNoDifference(saved.delivery?.state, .completed)
        expectNoDifference(report.text, "Plain model answer")
        let projected = await f.probe.peerMessages.last?.1
        expectNoDifference(report, projected)
        let restored = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let reopened = await restored.allMessages().first
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let persisted = try decoder.decode(AgentMessage.self, from: encoder.encode(saved))
        expectNoDifference(reopened, persisted)
        try await session.drain(onPeerMessage: { _, _ in Issue.record("Must not rerun completed provider") })
        let again = await f.messenger.allMessages().first
        expectNoDifference(again, saved)
        try await session.close()
    }

    @Test(arguments: [AgentMessageSource.Kind.incoming, .publication])
    func peerProjectionFailureDoesNotRepublishCanonicalReceipt(kind: AgentMessageSource.Kind) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MailboxVoiceProvider(mode: "published"))
        let session = f.session()
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Report")
        try await session.drain(onPeerMessage: { source, message in
            await f.probe.peer(source, message)
            if source.kind == kind { throw AgentMessagingError.scopeMismatch }
        })
        let saved = try #require(await f.messenger.allMessages().first)
        expectNoDifference(saved.delivery?.state, .failed)
        expectNoDifference(saved.delivery?.publications?.count ?? 0, kind == .incoming ? 0 : 1)
        let peers = await f.probe.peerMessages
        expectNoDifference(peers.count, kind == .incoming ? 1 : 2)
        // Draining again never invokes either callback or repeats SendMessage.
        try await session.drain(onPeerMessage: { _, _ in Issue.record("Repeated projection") })
        let again = try #require(await f.messenger.allMessages().first)
        expectNoDifference(again, saved)
        try await session.close()
    }

    @Test(arguments: ["none", "silent", "published", "failed", "text-only", "unconfigured"])
    func onlyExplicitPublicationsReachMailboxAndProjection(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MailboxVoiceProvider(mode: mode))
        let contextURL = f.root.appending(path: "private-context.json")
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents,
            messenger: f.messenger, registry: f.registry,
            coordinator: mode == "unconfigured" ? TurnCoordinator(registry: f.registry) : f.coordinator,
            conversations: try AgentConversationStore(url: contextURL),
            authorizePublication: { _, _, _, _, _ in })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Report the result")
        try await session.drain(onUpdate: { await f.probe.update($0) }, onPeerMessage: { source, message in
            await f.probe.peer(source, message)
        })
        try await session.close()
        let saved = await f.messenger.allMessages(), projected = await f.probe.messages
        let delivery = try #require(saved.first?.delivery)
        expectNoDifference(delivery.state, .completed)
        let usesPlainText = ["text-only", "unconfigured"].contains(mode)
        let peers = await f.probe.peerMessages
        expectNoDifference(peers.count, usesPlainText || mode == "published" ? 2 : 1)
        expectNoDifference(peers.first?.0.kind, .incoming)
        expectNoDifference(peers.first?.0.authorAgentID, f.sender.id)
        expectNoDifference(peers.first?.1.text, "Report the result")
        for (source, message) in peers {
            expectNoDifference(source.accountID, "local")
            expectNoDifference(source.originConversationID, f.origin)
            expectNoDifference(source.deliveryID, saved.first?.id)
            expectNoDifference(source.recipientAgentID, f.recipient.id)
            expectNoDifference(source.authorAgentID, message.senderID)
            #expect(!message.text.contains("PRIVATE"))
            expectNoDifference(message.shortAddress, nil)
        }
        if peers.count == 2 {
            expectNoDifference(peers.last?.0.kind, .publication)
            expectNoDifference(peers.last?.0.authorAgentID, f.recipient.id)
            expectNoDifference(peers.last?.1.text, usesPlainText ? "Plain model answer" : "Published result")
            if mode == "published" { expectNoDifference(peers.last?.1.id, delivery.publications?.first?.id) }
        }
        expectNoDifference(delivery.response, usesPlainText ? "Plain model answer" : mode == "published" ? "Published result" : "")
        expectNoDifference(delivery.publications?.map(\.text) ?? [], mode == "published" ? ["Published result"] : [])
        expectNoDifference(delivery.finalPublication, usesPlainText ? peers.last?.1 : nil)
        #expect(!projected.contains { $0.text.contains("PRIVATE") })
        #expect(!String(decoding: try Data(contentsOf: f.root.appending(path: "messages.json")), as: UTF8.self).contains("PRIVATE"))
        #expect(!String(decoding: try Data(contentsOf: contextURL), as: UTF8.self).contains("PRIVATE"))
        if usesPlainText { #expect(projected.contains { $0.text == "Plain model answer" }) }
        else if mode == "silent" { #expect(projected.allSatisfy { $0.text.isEmpty && $0.toolActivities.isEmpty }) }
        else { #expect(projected.contains { !$0.toolActivities.isEmpty && $0.text.isEmpty }) }
    }

    @Test(arguments: [false, true]) func groupCloudReferenceAdaptersPreserveScope(background: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Fixture", memberIDs: [f.sender.id])
        let input = try await groups.postUserMessage("Existing reference", groupID: group.id)
        let destination = group.id, origin = background ? f.origin : group.id
        let session = AgentMessagingSession(originConversationID: origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: f.coordinator, groups: groups)
        let publish: @Sendable (GroupAgentPublication) async throws -> RoomMessage? = { value in
            expectNoDifference(value.cursorAgent?.bcID, "bc-fixture")
            expectNoDifference(value.replyToMessageID, input.id)
            #expect(value.lifetime != nil)
            var saved = RoomMessage(groupID: destination, senderID: f.sender.id, text: value.text)
            saved.cursorAgent = value.cursorAgent; saved.replyToMessageID = value.replyToMessageID
            await f.probe.update(saved)
            return saved
        }
        let tool: AgentUserMessageTool
        if background {
            tool = try await session.savedBackgroundGroupPublisher(for: f.sender.id, groupID: destination,
                memberIDs: [f.sender.id], replyHistory: [input], publish: publish)
        } else {
            tool = try await session.savedGroupPublisher(for: f.sender.id, userMessageID: input.id,
                replyHistory: [input], questionAccountID: nil, memberIDs: [f.sender.id], publish: publish)
        }
        let request = try NormalizedToolCall(id: "cloud", name: "SendMessage", argumentsJSON:
            JSONEncoder().encode(["type": "cursor-agent", "bcId": "bc-fixture", "reply_to": input.id.uuidString]))
        #expect(try await !tool.execute(request, context: .init(conversationID: origin)).isError)
        let saved = await f.probe.messages
        expectNoDifference(saved.count, 1)
        expectNoDifference(saved.first?.groupID, destination)
        try await session.close()
    }
    @Test(arguments: [true, false]) func cloudReferenceEntryIsHostGatedAndPersists(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MessagingProvider { _, execute in
            let result = try await execute(.init(id: "cloud", name: "SendMessage",
                argumentsJSON: Data(#"{"type":"cursor-agent","bcId":"bc-fixture"}"#.utf8)))
            expectNoDifference(result.isError, !enabled)
            return "Done"
        })
        let session = f.session(questions: enabled)
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Reference existing cloud agent")
        try await session.drain(onUpdate: { await f.probe.update($0) })
        try await session.close()
        let history = await f.messenger.allMessages()
        expectNoDifference(history.first?.delivery?.publications?.first?.cursorAgent?.bcID, enabled ? "bc-fixture" : nil)
        let projected = await f.probe.messages
        expectNoDifference(projected.contains { $0.cursorAgent?.bcID == "bc-fixture" }, enabled)
    }
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let messenger: AgentMessenger
        let sender: AgentProfile
        let recipient: AgentProfile
        let registry: ProviderRegistry
        let coordinator: TurnCoordinator
        let probe: MessagingProbe
        let origin = UUID()
        func session(approve: Bool = true, timeout: Duration = .seconds(10), management: AgentManagementSession? = nil,
                     questions: Bool = false) -> AgentMessagingSession {
            AgentMessagingSession(originConversationID: origin, agents: agents, messenger: messenger,
                registry: registry, coordinator: coordinator, turnTimeout: timeout,
                management: management,
                supportsMailboxQuestions: questions,
                authorize: { sender, recipient, text, _, _ in
                    await probe.authorize(sender, recipient, text)
                    if !approve { throw AgentMessagingError.approvalRequired }
                })
        }
    }

    @Test(arguments: [false, true]) func mailboxCanReplyToItsOwnSavedPublicationInTheSameTurn(shortAddress: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MessagingProvider { _, execute in
            let first = try NormalizedToolCall(id: "first", name: "SendMessage", argumentsJSON: Data(#"{"text":"Progress"}"#.utf8))
            let receipt = try await execute(first)
            #expect(!receipt.isError)
            let input = try #require(await f.messenger.allMessages().first)
            let saved = try #require(input.delivery?.publications?.first)
            let resultText = receipt.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined()
            #expect(resultText.contains(saved.id.uuidString))
            #expect(resultText.contains("t0s0"))
            #expect(resultText.contains("sand-msg"))
            let second = try NormalizedToolCall(id: "second", name: "SendMessage", argumentsJSON:
                JSONEncoder().encode(["text": "Details", "reply_to": shortAddress ? "t0s0" : saved.id.uuidString]))
            #expect(try await !execute(second).isError)
            return "Done"
        })
        let session = f.session(questions: true)
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Explain")
        try await session.drain(onUpdate: { await f.probe.update($0) })
        try await session.close()
        let projected = await f.probe.messages
        #expect(projected.contains(where: { $0.text == "Progress" }))
        #expect(projected.allSatisfy { $0.shortAddress == nil })
        let input = try #require(await f.messenger.allMessages().first)
        let publications = try #require(input.delivery?.publications)
        expectNoDifference(publications.count, 2)
        expectNoDifference(publications.last?.replyToMessageID, publications.first?.id)
        expectNoDifference(input.delivery?.state, .completed)
    }

    @Test(arguments: [true, false])
    func mailboxReplyEntryIsHostGated(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MessagingProvider { _, execute in
            let incoming = try #require(await f.messenger.allMessages().first)
            let call = try NormalizedToolCall(id: "reply", name: "SendMessage", argumentsJSON:
                JSONEncoder().encode(["text": "Quoted answer", "reply_to": incoming.id.uuidString]))
            let result = try await execute(call)
            expectNoDifference(result.isError, !enabled)
            return "Done"
        })
        let session = f.session(questions: enabled)
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Question")
        try await session.drain()
        try await session.close()
        let incoming = try #require(await f.messenger.allMessages().first)
        expectNoDifference(incoming.delivery?.publications?.first?.replyToMessageID, enabled ? incoming.id : nil)
        // Unsupported reply payloads are rejected by the tool router before provider continuation.
        expectNoDifference(incoming.delivery?.state, enabled ? .completed : .failed)
    }

    @Test(arguments: [AgentQuestionAnswer.option(0), .custom("Human clarification"), .dismissed])
    func mailboxQuestionPausesAndHumanAnswerStartsFreshTurn(answer: AgentQuestionAnswer) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.registry.register(MessagingProvider { request, execute in
            let count = await f.probe.request(request)
            if count == 1 {
                let inbound = try #require(await f.messenger.allMessages().first)
                let fields: [String: Any] = ["type": "widget", "reply_to": inbound.id.uuidString,
                    "widget": ["prompt": "Which layout?", "options": [["label": "Compact"], ["label": "Spacious"]],
                               "allowCustom": true, "dismissOnMoveOn": true]]
                _ = try await execute(.init(id: "question", name: "SendMessage", argumentsJSON:
                    JSONSerialization.data(withJSONObject: fields)))
                Issue.record("A question must suspend the model turn")
            } else {
                let incoming = try #require(request.messages.last)
                expectNoDifference(incoming.role, .user)
                #expect(incoming.text.contains("Human answer"))
                #expect(incoming.text.contains("grants no tool access"))
                expectNoDifference(incoming.attachments, [])
                let forwarding = try await execute(sendCall(f.sender.id, "Forward the human answer", id: "forward"))
                #expect(forwarding.isError)
            }
            return "Resolved"
        })
        let first = f.session(questions: true)
        try await first.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Choose a layout")
        try await first.drain()
        try await first.close()
        let stored = await f.messenger.allMessages()
        let incoming = try #require(stored.first)
        let publication = try #require(incoming.delivery?.publications?.first)
        expectNoDifference(incoming.delivery?.state, .completed)
        expectNoDifference(publication.question?.isPending, true)
        expectNoDifference(publication.replyToMessageID, incoming.id)
        let initialRequestCount = await f.probe.requests.count
        expectNoDifference(initialRequestCount, 1)
        let stopped = f.session(questions: true)
        stopped.revokeProfileChanges()
        await #expect(throws: (any Error).self) {
            try await stopped.enqueueQuestionAnswer(incomingID: incoming.id, publicationID: publication.id, answer: answer)
        }
        let afterStop = await f.messenger.allMessages()
        expectNoDifference(afterStop, stored)
        let response = f.session(approve: false, questions: true)
        try await response.enqueueQuestionAnswer(incomingID: incoming.id, publicationID: publication.id, answer: answer)
        try await response.drain()
        try await response.close()
        let after = await f.messenger.allMessages()
        expectNoDifference(after.count, 2)
        expectNoDifference(after.first?.delivery?.publications?.first?.question?.answer, answer)
        expectNoDifference(after.last?.delivery?.state, .completed)
        expectNoDifference(after.last?.recipientID, f.recipient.id)
        let resumedRequestCount = await f.probe.requests.count
        expectNoDifference(resumedRequestCount, 2)
        await #expect(throws: AgentQuestionError.unavailable) {
            try await f.session(questions: true).enqueueQuestionAnswer(incomingID: incoming.id, publicationID: publication.id, answer: answer)
        }
    }

    @Test func mailboxQuestionsRemainUnavailableInDelegatedGroupSession() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await #expect(throws: AgentQuestionError.unavailable) {
            try await session.enqueueQuestionAnswer(incomingID: UUID(), publicationID: UUID(), answer: .dismissed)
        }
        let saved = await f.messenger.allMessages()
        expectNoDifference(saved, [])
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-messaging-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Engineer", instructions: "ENGINEER_PRIVATE_PERSONA", providerID: "messaging-test", modelID: "test")
        let recipient = try await agents.create(name: "Designer", instructions: "DESIGNER_PRIVATE_PERSONA", providerID: "messaging-test", modelID: "test")
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "messages.json"))
        let registry = ProviderRegistry(), probe = MessagingProbe()
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog([MessagingReadTool(probe: probe)]))
        return .init(root: root, agents: agents, messenger: messenger, sender: sender, recipient: recipient, registry: registry, coordinator: coordinator, probe: probe)
    }

    @Test(arguments: ["group", "room-peer", "mailbox"])
    func recallUsesOnlyCurrentMessageAndNeverMutatesOrSharesPrivateStore(route: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let aurora = "Aurora uses amber accents", zephyr = "Zephyr uses violet accents"
        let facts = [aurora, zephyr] + (3...42).map { "Unrelated record \($0)" }
        for (index, fact) in facts.enumerated() {
            let memory = AgentMemory(accountID: "local", agentID: f.recipient.id, fact: fact,
                createdAt: Date(timeIntervalSince1970: Double(index) * 86_400))
            try await f.agents.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
        }
        for (account, owner, scope, text) in [
            ("local", f.sender.id, AgentMemory.Scope.agent, "Aurora Zephyr PRIVATE_PEER"),
            ("other", f.recipient.id, .user, "Aurora Zephyr OTHER_ACCOUNT"),
            ("local", f.sender.id, .user, "Aurora Zephyr APPROVED_SHARED"),
        ] {
            let memory = AgentMemory(accountID: account, agentID: owner, fact: text, scope: scope,
                                     createdAt: Date(timeIntervalSince1970: 1_000))
            try await f.agents.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
        }
        let before = try Data(contentsOf: f.root.appending(path: "agents.json"))
        let management = AgentManagementSession(originID: f.origin, agents: f.agents)
        let session = f.session(management: management)
        await f.registry.register(MessagingProvider { request, _ in
            _ = await f.probe.request(request)
            return "PASS"
        })
        let groupID = route == "room-peer" ? UUID() : f.origin
        for (index, topic) in ["Aurora", "Zephyr"].enumerated() {
            let previousTopic = topic == "Aurora" ? "Zephyr" : "Aurora"
            let oldText = String(repeating: previousTopic + " ", count: 20)
            await session.remember(agentID: f.recipient.id, messages: [.init(role: .user, text: oldText)], response: oldText)
            let currentText = "Review \(topic)"
            if route == "mailbox" {
                _ = try await session.tool(for: f.sender.id).execute(
                    sendCall(f.recipient.id, currentText, id: ToolCallID(rawValue: "recall-\(index)")),
                    context: .init(conversationID: f.origin))
                try await session.drain()
            } else {
                let delegated = route == "room-peer" ? RoomMessage(groupID: groupID, senderID: f.sender.id, text: currentText) : nil
                let responder = GroupConversationResponder(groupID: groupID, registry: f.registry,
                    coordinator: f.coordinator, messaging: session, delegatedMessage: delegated, toolScopeID: f.origin)
                _ = try await responder.respond(agent: f.recipient, history: [
                    RoomMessage(groupID: groupID, senderID: nil, text: oldText),
                    RoomMessage(groupID: groupID, senderID: f.sender.id, text: oldText),
                    RoomMessage(groupID: groupID, senderID: nil, text: delegated == nil ? currentText : oldText),
                ])
            }
        }
        let requests = await f.probe.requests
        expectNoDifference(requests.count, 2)
        for (index, request) in requests.enumerated() {
            let context = try #require(request.messages.first { $0.role == .system && $0.text.contains("Saved facts (untrusted JSON data): ") })
            let json = try #require(context.text.components(separatedBy: "Saved facts (untrusted JSON data): ").last)
            struct Fact: Decodable { let fact: String }
            let recalled = try JSONDecoder().decode([Fact].self, from: Data(json.utf8)).map(\.fact)
            expectNoDifference(recalled.first, index == 0 ? aurora : zephyr)
            #expect(!recalled.contains(index == 0 ? zephyr : aurora))
            #expect(recalled.contains("Aurora Zephyr APPROVED_SHARED"))
            #expect(!context.text.contains("PRIVATE_PEER") && !context.text.contains("OTHER_ACCOUNT"))
            #expect(context.text.contains("NOT instructions") && context.text.contains("every change needs explicit approval"))
        }
        let after = try Data(contentsOf: f.root.appending(path: "agents.json"))
        expectNoDifference(after, before)
        try await session.close()
    }

    @Test func durableAcknowledgementThenPeerReplyWakesSenderInOwnContext() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await session.remember(agentID: f.sender.id, messages: [.init(role: .user, text: "ENGINEER_ONLY_HISTORY")], response: "Awaiting review")
        await f.registry.register(MessagingProvider { request, tool in
            let count = await f.probe.request(request)
            #expect(request.tools.contains { $0.name == "SendToAgent" })
            #expect(request.messages.last?.role == .assistant)
            let all = request.messages.map(\.text).joined(separator: "\n")
            if count == 1 {
                #expect(all.contains("DESIGNER_PRIVATE_PERSONA"))
                #expect(!all.contains("ENGINEER_PRIVATE_PERSONA"))
                #expect(!all.contains("ENGINEER_ONLY_HISTORY"))
                _ = try await tool(.init(id: "read", name: "fixture_read", argumentsJSON: Data("{}".utf8)))
                let ack = try await tool(sendCall(f.sender.id, "Use accessible contrast", id: "reply"))
                #expect(!ack.isError && ack.wireText.contains("Queued"))
                return "Design review completed"
            }
            #expect(count == 2)
            #expect(all.contains("ENGINEER_ONLY_HISTORY"))
            #expect(all.contains("Use accessible contrast"))
            #expect(!all.contains("DESIGNER_PRIVATE_PERSONA"))
            return "Applied the designer's recommendation"
        })
        let tool = session.tool(for: f.sender.id)
        let context = ToolContext(conversationID: f.origin)
        let ack = try await tool.execute(sendCall(f.recipient.id), context: context)
        #expect(ack.wireText.contains("NOT completed"))
        let queued = await f.messenger.allMessages()
        expectNoDifference(queued.map { $0.delivery?.state }, [.queued])
        let noRequests = await f.probe.requests
        expectNoDifference(noRequests.count, 0)
        try await session.drain(onUpdate: { await f.probe.update($0) })
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.map(\.senderID), [f.sender.id, f.recipient.id])
        expectNoDifference(messages.map { $0.delivery?.state }, [.completed, .completed])
        let requests = await f.probe.requests
        #expect(requests[0].conversationID != requests[1].conversationID)
        #expect(requests.allSatisfy { $0.conversationID != f.origin })
        let approvals = await f.probe.authorizations
        expectNoDifference(approvals.count, 1) // one reply to the approved sender is included
        let contexts = await f.probe.contexts
        expectNoDifference(contexts.map(\.conversationID), [f.origin]) // real tools retain approval scope
        try await session.close()
        let restored = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let durable = await restored.allMessages()
        expectNoDifference(durable.map(\.id), messages.map(\.id))
        expectNoDifference(durable.map(\.delivery), messages.map(\.delivery))
        expectNoDifference(durable.map(\.text), messages.map(\.text))
    }

    @Test func sameCallIsIdempotentButNewCallCannotResendIdenticalMessage() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = ToolContext(conversationID: f.origin)
        let tool = session.tool(for: f.sender.id), call = try sendCall(f.recipient.id)
        let first = try await tool.execute(call, context: context)
        let second = try await tool.execute(call, context: context)
        expectNoDifference(first, second)
        let duplicate = try await tool.execute(sendCall(f.recipient.id, id: "duplicate"), context: context)
        #expect(duplicate.isError && duplicate.wireText.contains("already sent"))
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.count, 1)
        try await session.close()
    }

    @Test func priorityIsApprovedPersistedSortedAndCannotEscalateAnExistingSend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = ToolContext(conversationID: f.origin), tool = session.tool(for: f.sender.id)
        await f.registry.register(MessagingProvider { request, _ in
            _ = await f.probe.request(request); return "PASS"
        })
        let normal = try sendCall(f.recipient.id, "Ordinary review")
        _ = try await tool.execute(normal, context: context)
        let escalation = try await tool.execute(prioritySendCall(f.recipient.id, "Ordinary review", id: normal.id), context: context)
        #expect(escalation.isError)
        let duplicate = try await tool.execute(prioritySendCall(f.recipient.id, "Ordinary review", id: "new-id"), context: context)
        #expect(duplicate.isError)
        let urgent = try prioritySendCall(f.recipient.id, "Urgent result")
        let first = try await tool.execute(urgent, context: context)
        let replay = try await tool.execute(urgent, context: context)
        expectNoDifference(first, replay)
        #expect(first.wireText.contains("when this session drains"))
        let before = await f.messenger.allMessages(), approvals = await f.probe.authorizations
        expectNoDifference(before.map(\.priority), [.normal, .priority])
        expectNoDifference(approvals.count, 2)
        try await session.drain()
        let requests = await f.probe.requests
        expectNoDifference(requests.count, 2)
        #expect(requests[0].messages.last?.text.contains("Urgent result") == true)
        #expect(requests[1].messages.last?.text.contains("Ordinary review") == true)
        try await session.close()
    }

    @Test func priorityReplyDoesNotInheritTheNormalReplyApprovalExemption() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await f.registry.register(MessagingProvider { request, execute in
            let index = await f.probe.request(request)
            if index == 1 {
                let result = try await execute(prioritySendCall(f.sender.id, "Urgent findings"))
                #expect(!result.isError)
            }
            return "PASS"
        })
        _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        try await session.drain()
        let approvals = await f.probe.authorizations, messages = await f.messenger.allMessages()
        expectNoDifference(approvals.count, 2)
        expectNoDifference(messages.map(\.priority), [.normal, .priority])
        try await session.close()
    }

    @Test func malformedAndDeniedPriorityNeverQueue() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(approve: false), tool = session.tool(for: f.sender.id), context = ToolContext(conversationID: f.origin)
        for value in ["null", "1", "\"true\"", "[]"] {
            let payload = "{\"recipientID\":\"\(f.recipient.id)\",\"message\":\"Urgent\",\"priority\":\(value)}"
            let result = try await tool.execute(.init(id: "invalid", name: "SendToAgent", argumentsJSON: Data(payload.utf8)), context: context)
            #expect(result.isError)
        }
        let denied = try await tool.execute(prioritySendCall(f.recipient.id, "Denied urgent task"), context: context)
        #expect(denied.isError)
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages, [])
        try await session.close()
    }

    @Test func deniedUnknownArchivedSelfAndCrossScopeNeverQueue() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(approve: false), context = ToolContext(conversationID: f.origin)
        let tool = session.tool(for: f.sender.id)
        #expect(try await tool.execute(sendCall(f.recipient.id), context: context).isError)
        #expect(try await tool.execute(sendCall(UUID()), context: context).isError)
        #expect(try await tool.execute(sendCall(f.sender.id), context: context).isError)
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(sendCall(f.recipient.id), context: .init(conversationID: UUID())) }
        #expect(try await tool.execute(sendCall(f.recipient.id, " \n "), context: context).isError)
        try await f.agents.archive(id: f.recipient.id)
        #expect(try await tool.execute(sendCall(f.recipient.id), context: context).isError)
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages, [])
    }

    @Test func peerPingPongStopsAtSixWithoutAutomaticallyReplyingToFinalText() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await f.registry.register(MessagingProvider { request, tool in
            let count = await f.probe.request(request)
            let target = count.isMultiple(of: 2) ? f.recipient.id : f.sender.id
            let result = try await tool(sendCall(target, "Useful result \(count)", id: "reply"))
            if count == 6 { #expect(result.isError && result.wireText.contains("six-message")) }
            return "Result \(count)"
        })
        _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        try await session.drain()
        let requests = await f.probe.requests, messages = await f.messenger.allMessages()
        expectNoDifference(requests.count, 6)
        expectNoDifference(messages.count, 6)
        #expect(messages.allSatisfy { $0.delivery?.state == .completed })
        try await session.close()
    }

    @Test func restartCancelsQueuedWorkAndReadMarkerDoesNotExecuteIt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        _ = try await f.messenger.dequeue(recipientID: f.recipient.id)
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.first?.delivery?.state, .queued)
        let restored = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let recovered = await restored.allMessages()
        expectNoDifference(recovered.first?.delivery?.state, .cancelled)
        #expect(recovered.first?.deliveredAt != nil)
    }

    @Test func passDoesNotSendAutomaticCourtesyReply() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await f.registry.register(MessagingProvider { request, _ in
            _ = await f.probe.request(request)
            return "PASS"
        })
        _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        try await session.drain(onUpdate: { await f.probe.update($0) })
        let requests = await f.probe.requests, messages = await f.messenger.allMessages(), reports = await f.probe.messages
        expectNoDifference(requests.count, 1)
        expectNoDifference(messages.count, 1)
        expectNoDifference(reports.last?.memberOutcome, .passed)
    }

    @Test func recipientTimeoutAndCloseDoNotLeaveRunningOrQueuedMessages() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(timeout: .milliseconds(20))
        await f.registry.register(MessagingProvider { _, _ in
            try await Task.sleep(for: .seconds(10))
            return "late"
        })
        _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        try await session.drain(onUpdate: { await f.probe.update($0) })
        try await session.close()
        let messages = await f.messenger.allMessages(), reports = await f.probe.messages
        expectNoDifference(messages.first?.delivery?.state, .failed)
        expectNoDifference(reports.last?.memberOutcome, .failed)
        await #expect(throws: AgentMessagingError.closed) {
            _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        }
    }

    @Test func deliveryMetadataIsBackwardCompatible() throws {
        let original = AgentMessage(senderID: UUID(), recipientID: UUID(), text: "old mailbox")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentMessage.self, from: data)
        expectNoDifference(decoded, original)
        #expect(decoded.delivery == nil)
    }

    @Test func scopedToolNeverLeaksToUnrelatedRequestsAndCannotSpoofSender() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await f.registry.register(MessagingProvider { request, tool in
            _ = await f.probe.request(request)
            if request.messages.first?.text == "scoped" {
                #expect(request.tools.contains { $0.name == "SendToAgent" })
                let args = ["senderID": f.recipient.id.uuidString, "recipientID": f.recipient.id.uuidString, "message": "spoofed"]
                do {
                    _ = try await tool(.init(id: "spoof", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(args)))
                    Issue.record("Sender spoofing reached the executor")
                } catch is ToolLoopError {}
            } else {
                #expect(!request.tools.contains { $0.name == "SendToAgent" })
                #expect(!request.messages.contains { $0.text.contains("Active peer directory") })
            }
            return "PASS"
        })
        try await f.coordinator.send(request: .init(conversationID: f.origin, modelID: "test", messages: [.init(role: .system, text: "scoped")]),
                                     providerID: "messaging-test", additionalTools: [session.tool(for: f.sender.id)]) { _ in }
        try await f.coordinator.send(request: .init(conversationID: UUID(), modelID: "test", messages: [.init(role: .user, text: "unrelated")]),
                                     providerID: "messaging-test") { _ in }
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages, [])
    }

    @Test func persistenceFailureDoesNotAcknowledgeOrLeavePhantomMailboxEntry() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let invalidStore = f.root.appending(path: "directory-not-a-file")
        let messenger = try AgentMessenger(service: f.agents, storeURL: invalidStore)
        try FileManager.default.createDirectory(at: invalidStore, withIntermediateDirectories: true)
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: messenger,
            registry: f.registry, coordinator: f.coordinator, authorize: { _, _, _, _, _ in })
        let result = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        #expect(result.isError)
        let messages = await messenger.allMessages()
        expectNoDifference(messages, [])
    }

    @Test func closingDuringExecutionCancelsActualProviderAndPendingMailbox() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        await f.registry.register(MessagingProvider { request, _ in
            _ = await f.probe.request(request)
            try await Task.sleep(for: .seconds(10))
            return "must never be published"
        })
        _ = try await session.tool(for: f.sender.id).execute(sendCall(f.recipient.id), context: .init(conversationID: f.origin))
        let task = Task { try await session.drain(onUpdate: { await f.probe.update($0) }) }
        for _ in 0..<500 {
            if !(await f.probe.requests.isEmpty) { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        try await session.close()
        do { try await task.value; Issue.record("Cancelled wake succeeded") } catch is CancellationError {}
        let messages = await f.messenger.allMessages(), reports = await f.probe.messages
        expectNoDifference(messages.first?.delivery?.state, .cancelled)
        #expect(!reports.contains { $0.text == "must never be published" })
    }
}
