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
    func request(_ value: InferenceRequest) -> Int { requests.append(value); return requests.count }
    func authorize(_ sender: AgentProfile, _ recipient: AgentProfile, _ text: String) { authorizations.append((sender.id, recipient.id, text)) }
    func update(_ message: RoomMessage) { messages.append(message) }
    func context(_ value: ToolContext) { contexts.append(value) }
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

@Suite("SendToAgent messaging session", .timeLimit(.minutes(1)))
struct AgentMessagingSessionTests {
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
        func session(approve: Bool = true, timeout: Duration = .seconds(10)) -> AgentMessagingSession {
            AgentMessagingSession(originConversationID: origin, agents: agents, messenger: messenger,
                registry: registry, coordinator: coordinator, turnTimeout: timeout,
                authorize: { sender, recipient, text, _, _ in
                    await probe.authorize(sender, recipient, text)
                    if !approve { throw AgentMessagingError.approvalRequired }
                })
        }
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
