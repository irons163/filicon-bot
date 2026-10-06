import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconChannels
import FiliconDomain
import FiliconPersistence
import FiliconProviderKit

private func mailboxChannelID(_ value: Int) -> UUID {
    UUID(uuidString: "38000000-0000-0000-0000-" + String(format: "%012x", value))!
}

private actor MailboxChannelProbe {
    struct Projection: Equatable, Sendable {
        let source: AgentMessageSource
        let message: RoomMessage
    }
    var requests: [InferenceRequest] = []
    var results: [NormalizedToolResult] = []
    var reviews: [AgentChannelPublicationTransaction.Review] = []
    var reviewContexts: [ToolContext] = []
    var updates: [RoomMessage] = []
    var projections: [Projection] = []
    var events: [String] = []
    var sent: [ChannelOutbound] = []
    var session: AgentMessagingSession?
    func bind(_ value: AgentMessagingSession) { session = value }
    func request(_ value: InferenceRequest) { requests.append(value) }
    func result(_ value: NormalizedToolResult) { results.append(value) }
    func review(_ value: AgentChannelPublicationTransaction.Review, context: ToolContext) {
        reviews.append(value); reviewContexts.append(context); events.append("send review")
    }
    func update(_ value: RoomMessage) { updates.append(value) }
    func project(_ source: AgentMessageSource, _ value: RoomMessage) { projections.append(.init(source: source, message: value)) }
    func event(_ value: String) { events.append(value) }
    func send(_ value: ChannelOutbound) { sent.append(value) }
    func stop() { session?.revokeProfileChanges() }
}

private struct MailboxChannelConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline mailbox fixture", supportsAttachments: true)
    let probe: MailboxChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws { await probe.send(message) }
}

private struct MailboxChannelProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "mailbox-channel-fixture", displayName: "Offline mailbox inference", requiresAPIKey: false)
    let probe: MailboxChannelProbe
    let arguments: [String: String]
    var replyFromAgentID: UUID? = nil
    var replyRecipientID: UUID? = nil
    var failAfterPublication = false
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await probe.request(request)
                    if let replyFromAgentID, let replyRecipientID,
                       request.messages.contains(where: { $0.role == .system && $0.text.contains("agent:\(replyFromAgentID.uuidString)") }) {
                        let reply = try NormalizedToolCall(id: "peer-reply", name: "SendToAgent", argumentsJSON: JSONEncoder().encode([
                            "recipientID": replyRecipientID.uuidString, "message": "EXACT_SHARED_TASK"
                        ]))
                        let result = try await executeTool(reply)
                        #expect(!result.isError)
                        continuation.yield(.textDelta("PASS"))
                        continuation.yield(.completed(.stop)); continuation.finish()
                        return
                    }
                    let tool = try #require(request.tools.first { $0.name == "SendMessage" })
                    let schema = try #require(JSONSerialization.jsonObject(with: tool.inputSchema) as? [String: Any])
                    let properties = try #require(schema["properties"] as? [String: Any])
                    if properties["channel"] != nil {
                        let call = try NormalizedToolCall(id: "external", name: "SendMessage", argumentsJSON: JSONEncoder().encode(arguments))
                        let first = try await executeTool(call)
                        await probe.result(first)
                        // The real ToolLoop rejects duplicate interactive call
                        // IDs before the executor; lower-level exact replay is
                        // covered by AgentChannelTranscriptDestinationTests.
                        do {
                            _ = try await executeTool(call)
                            Issue.record("Duplicate interactive call ID was accepted")
                        } catch { expectNoDifference(error as? ToolLoopError, .duplicateCallID(call.id)) }
                    } else { await probe.event("no mailbox channel capability") }
                    if failAfterPublication { throw ProviderError.transport("OFFLINE_PROVIDER_FAILED_AFTER_REAL_RECEIPT") }
                    continuation.yield(.textDelta("PRIVATE_FINAL_DRAFT_DO_NOT_PUBLISH"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Explicit mailbox channel publication", .timeLimit(.minutes(1)))
struct MailboxChannelPublicationTests {
    private let origin = mailboxChannelID(1), run = mailboxChannelID(2), otherID = mailboxChannelID(3)
    private let date = Date(timeIntervalSince1970: 1_500)
    private struct Fixture: Sendable {
        let root: URL
        let profiles: AgentService
        let messenger: AgentMessenger
        let contexts: AgentConversationStore
        let repository: ConversationRepository
        let channels: ChannelService
        let registry: ProviderRegistry
        let coordinator: TurnCoordinator
        let probe: MailboxChannelProbe
        let sender: AgentProfile
        let recipient: AgentProfile
        let destination: UUID
        let initial: [Conversation]
        let lease: ConversationBindingLease
        let direct: Bool
        let ownerRecipient: Bool
    }

    private func fixture(direct: Bool = true, ownerRecipient: Bool = false, attachment: Bool = false,
                         failAfterPublication: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-mailbox-channel-\(UUID())")
        let profiles = try AgentService(storeURL: root.appending(path: "agents.json"))
        let engineer = try await profiles.create(name: "Engineer", instructions: "ENGINEER_PRIVATE_PERSONA",
            providerID: "mailbox-channel-fixture", modelID: "fixture")
        let designer = try await profiles.create(name: "Designer", instructions: "DESIGNER_PRIVATE_PERSONA",
            providerID: "mailbox-channel-fixture", modelID: "fixture")
        let sender = ownerRecipient ? designer : engineer, recipient = ownerRecipient ? engineer : designer
        let messenger = try AgentMessenger(service: profiles, storeURL: root.appending(path: "messages.json"))
        let contexts = try AgentConversationStore(url: root.appending(path: "contexts.json"))
        let own = try await contexts.context(accountID: "local", originID: origin, agentID: recipient.id)
        try await contexts.appendExchange(accountID: "local", originID: origin, agentID: recipient.id,
            incoming: .init(id: mailboxChannelID(4), role: .assistant, text: "RECIPIENT_CONTEXT_ONLY", createdAt: date), response: "RECIPIENT_OWN_REPLY")
        try await contexts.appendExchange(accountID: "local", originID: otherID, agentID: recipient.id,
            incoming: .init(id: mailboxChannelID(5), role: .assistant, text: "UNRELATED_CONTEXT_PRIVATE", createdAt: date), response: "UNRELATED_REPLY_PRIVATE")
        let destination = direct && ownerRecipient ? origin : own.conversationID
        let repository = try ConversationRepository(databaseURL: root.appending(path: "canonical.sqlite"))
        var target = Conversation(id: destination, title: "Actual recipient", messages: [
            .init(id: mailboxChannelID(6), role: .user, text: "CANONICAL_RECIPIENT_HISTORY_NOT_IN_INFERENCE", createdAt: date)
        ], updatedAt: date)
        target.agentBinding = .init(accountID: "local", agentID: recipient.id)
        var initial = [target, Conversation(id: otherID, title: "Unrelated chat", messages: [
            .init(id: mailboxChannelID(7), role: .user, text: "OTHER_CHAT_PRIVATE", createdAt: date)
        ], updatedAt: date)]
        if destination != origin { initial.append(Conversation(id: origin, title: "Approval origin", messages: [
            .init(id: mailboxChannelID(8), role: .user, text: "SOURCE_HUMAN_PRIVATE", createdAt: date)
        ], updatedAt: date)) }
        try await repository.save(initial, activityAt: date)
        initial = try await repository.load()
        let lease = try await repository.leaseUniqueBinding(accountID: "local", agentID: recipient.id, conversationID: destination)
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"), newDeliveryID: { mailboxChannelID(9) })
        let probe = MailboxChannelProbe(), registry = ProviderRegistry()
        await channels.register(MailboxChannelConnector(probe: probe))
        try await channels.saveConnection(.init(id: mailboxChannelID(10), connectorID: "slack", displayName: "Recipient only",
            secretReference: "keychain://channels/OFFLINE_NEVER_READ", agentID: recipient.id, ownerAccountID: "local"))
        let arguments = attachment
            ? ["type": "attachment", "url": "file:///isolated/captured.html", "alt": "EXACT_CAPTION", "channel": "slack:C_RECIPIENT"]
            : ["type": "text", "content": "EXACT_EXTERNAL_RESULT", "channel": "slack:C_RECIPIENT"]
        await registry.register(MailboxChannelProvider(probe: probe, arguments: arguments,
            replyFromAgentID: direct && ownerRecipient ? sender.id : nil,
            replyRecipientID: direct && ownerRecipient ? recipient.id : nil, failAfterPublication: failAfterPublication))
        let coordinator = TurnCoordinator(registry: registry, toolCatalog: ToolCatalog([]))
        return .init(root: root, profiles: profiles, messenger: messenger, contexts: contexts, repository: repository,
            channels: channels, registry: registry, coordinator: coordinator, probe: probe, sender: sender, recipient: recipient,
            destination: destination, initial: initial, lease: lease, direct: direct, ownerRecipient: ownerRecipient)
    }

    private func session(_ f: Fixture, mode: String = "approve", attachment: Bool = false) -> AgentMessagingSession {
        let origin = self.origin, date = self.date
        let factory: AgentMessagingSession.MailboxChannelPublisherFactory = { incoming, sender, lifetime in
            guard sender.id == f.recipient.id else { return nil }
            await f.probe.event("mailbox factory")
            expectNoDifference(incoming.recipientID, sender.id)
            let guarded = ChannelPublicationLifetime(parent: lifetime, commitGuard: { write in try f.lease.withValidBinding(write) })
            let prepare: AgentChannelPublicationTransaction.Prepare?
            if attachment {
                prepare = { _, _, _, context in
                    expectNoDifference(context.conversationID, origin)
                    await f.probe.event("source review")
                    if mode == "deny-source" { throw CancellationError() }
                    return try .init(file: .init(bytes: Data("EXACT_CAPTURED_BYTES".utf8), filename: "captured.html"), mimeType: "application/octet-stream")
                }
            } else {
                prepare = nil
            }
            return AgentChannelPublicationTransaction(conversationID: mode == "origin" ? UUID() : origin,
                senderID: mode == "sender" ? UUID() : sender.id, agentID: mode == "agent" ? UUID() : sender.id,
                accountID: mode == "account" ? "foreign-account" : "local", channels: f.channels, lifetime: guarded,
                validateScope: { try guarded.check(); try f.lease.withValidBinding {} }, authorize: { review, _, context in
                    await f.probe.review(review, context: context)
                    if mode == "deny-send" { throw CancellationError() }
                    if mode == "stop-review" { await f.probe.stop() }
                }, prepare: prepare, install: prepare.map { _ in { @Sendable value in
                    await f.probe.event("install captured bytes")
                    expectNoDifference(value.file.bytes, Data("EXACT_CAPTURED_BYTES".utf8))
                    return value.metadata
                } }, transcriptSource: mode == "missing-transcript" ? nil : .init(
                    route: mode == "group-route" ? .groupConversation : .directConversation,
                    senderName: sender.name, destination: .init(conversationID: mode == "destination" ? UUID() : f.destination,
                        senderID: mode == "author" ? UUID() : f.destination),
                    replyDirectoryConversationID: mode == "directory" ? f.destination : origin), publishTranscript: { value in
                    await f.probe.event("canonical save")
                    if mode == "missing-save" { return nil }
                    if mode == "throw-save" { throw CancellationError() }
                    if mode == "forged-save" { return .init(groupID: value.conversationID, senderID: value.senderID, text: "FAKE_UNSAVED") }
                    let saved = try await f.repository.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date,
                        commit: { write in try f.lease.withValidBinding(write) })
                    let row = try #require(saved.messages.first { $0.id == value.deliveryID })
                    var receipt = RoomMessage.externalChannelMessage(value); receipt.shortAddress = row.shortAddress
                    return receipt
                }, makeID: { mailboxChannelID(11) }, now: { date })
        }
        return AgentMessagingSession(id: mailboxChannelID(12), originConversationID: origin, agents: f.profiles,
            messenger: f.messenger, registry: f.registry, coordinator: f.coordinator,
            conversations: mode == "no-store" ? nil : f.contexts, accountID: "local",
            directOriginBinding: f.direct ? .init(accountID: "local", agentID: f.ownerRecipient ? f.recipient.id : f.sender.id) : nil,
            supportsMailboxQuestions: mode != "no-receipts",
            channelPublisherFactory: { _, _, _ in await f.probe.event("WRONG_FOREGROUND_FACTORY"); return nil },
            mailboxChannelPublisherFactory: mode == "no-factory" ? nil : factory,
            authorize: { sender, recipient, _, _, context in
                expectNoDifference(sender.id, f.direct && f.ownerRecipient ? f.recipient.id : f.sender.id)
                expectNoDifference(recipient.id, f.direct && f.ownerRecipient ? f.sender.id : f.recipient.id)
                expectNoDifference(context.conversationID, origin); await f.probe.event("delegation review")
            })
    }

    private func enqueue(_ f: Fixture, _ session: AgentMessagingSession) async throws {
        await f.probe.bind(session)
        let seedReturn = f.direct && f.ownerRecipient
        let call = try NormalizedToolCall(id: "delegate", name: "SendToAgent", argumentsJSON: JSONEncoder().encode([
            "recipientID": (seedReturn ? f.sender.id : f.recipient.id).uuidString,
            "message": seedReturn ? "RETURN_PATH_SEED_NOT_USER_PERMISSION" : "EXACT_SHARED_TASK"
        ]))
        let result = try await session.tool(for: seedReturn ? f.recipient.id : f.sender.id).execute(call, context: .init(conversationID: origin, runID: run))
        #expect(!result.isError)
    }

    private func drain(_ f: Fixture, _ session: AgentMessagingSession) async throws {
        try await session.drain(onUpdate: { await f.probe.update($0) }, onPeerMessage: { await f.probe.project($0, $1) })
    }

    private struct ExplicitHostCase: Sendable {
        let direct: Bool
        let ownerRecipient: Bool
        let localReceipts: Bool
    }
    @Test(arguments: [
        ExplicitHostCase(direct: false, ownerRecipient: false, localReceipts: true),
        ExplicitHostCase(direct: false, ownerRecipient: true, localReceipts: true),
        ExplicitHostCase(direct: true, ownerRecipient: false, localReceipts: true),
        ExplicitHostCase(direct: true, ownerRecipient: true, localReceipts: true),
        ExplicitHostCase(direct: false, ownerRecipient: false, localReceipts: false),
        ExplicitHostCase(direct: false, ownerRecipient: true, localReceipts: false)
    ])
    private func explicitSavedOutputBelongsOnlyToTheActualRecipient(test: ExplicitHostCase) async throws {
        let direct = test.direct, ownerRecipient = test.ownerRecipient
        let f = try await fixture(direct: direct, ownerRecipient: ownerRecipient)
        defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let session = session(f, mode: test.localReceipts ? "approve" : "no-receipts")
        try await enqueue(f, session)
        try await drain(f, session)
        let reviews = await f.probe.reviews, contexts = await f.probe.reviewContexts
        expectNoDifference(reviews.count, 1); expectNoDifference(contexts.map(\.conversationID), [origin])
        let context = try #require(contexts.first)
        let expected = ExternalChannelTranscriptPublication(deliveryID: mailboxChannelID(9), connectionID: mailboxChannelID(10),
            owner: .init(accountID: "local", agentID: f.recipient.id), route: .directConversation,
            conversationID: f.destination, senderID: f.destination, senderName: f.recipient.name,
            runID: context.runID, callID: "external", replyToMessageID: nil, queuedAt: date, kind: .text,
            text: "EXACT_EXTERNAL_RESULT", sources: [], files: [], platform: "slack", channelID: "C_RECIPIENT", threadID: nil,
            delivery: .init(status: .queued, attemptCount: 0, deliveredAt: nil))
        var expectedRow = expected.directMessage; expectedRow.shortAddress = "t0s0"
        var chats = f.initial
        let index = try #require(chats.firstIndex { $0.id == f.destination })
        await expectDifference(chats) {
            chats = try await f.repository.load()
        } changes: {
            $0[index].messages[0].shortAddress = "t0u"
            $0[index].messages.append(expectedRow)
            $0[index].messageAddressReservations[mailboxChannelID(6).uuidString] = "t0u"
            $0[index].messageAddressReservations[mailboxChannelID(9).uuidString] = "t0s0"
        }
        let delivery = try #require(await f.channels.deliveries().first)
        expectNoDifference(ChannelTranscriptProjection.publication(for: delivery), expected)
        let results = await f.probe.results
        expectNoDifference(results.count, 1); #expect(results.allSatisfy { !$0.isError })
        let incoming = try #require(await f.messenger.allMessages().first { $0.recipientID == f.recipient.id })
        expectNoDifference(incoming.delivery?.state, .completed)
        expectNoDifference(incoming.delivery?.publications, nil)
        expectNoDifference(incoming.delivery?.finalPublication, nil)
        #expect(incoming.delivery?.response?.contains("queue status: queued") == true)
        #expect(incoming.delivery?.response?.contains("PRIVATE_FINAL_DRAFT") == false)
        let updates = await f.probe.updates, projections = await f.probe.projections
        #expect(updates.allSatisfy { $0.externalPublication == nil && $0.text.isEmpty })
        expectNoDifference(projections.map(\.source.kind), direct && ownerRecipient ? [.incoming, .incoming] : [.incoming])
        expectNoDifference(projections.map(\.message.text), direct && ownerRecipient
            ? ["RETURN_PATH_SEED_NOT_USER_PERMISSION", "EXACT_SHARED_TASK"] : ["EXACT_SHARED_TASK"])
        let request = try #require(await f.probe.requests.first { request in
            request.messages.contains { $0.role == .system && $0.text.contains("agent:\(f.recipient.id.uuidString)") }
        })
        #expect(request.messages.contains { $0.text.contains("RECIPIENT_CONTEXT_ONLY") })
        #expect(!request.messages.contains { $0.text.contains("UNRELATED_CONTEXT_PRIVATE") || $0.text.contains("SOURCE_HUMAN_PRIVATE") || $0.text.contains("CANONICAL_RECIPIENT_HISTORY") })
        let events = await f.probe.events
        expectNoDifference(events, ["delegation review", "mailbox factory", "send review", "canonical save"])
        let sent = await f.probe.sent; expectNoDifference(sent, [])
        let own = try await f.contexts.context(accountID: "local", originID: origin, agentID: f.recipient.id)
        #expect(own.messages.last?.text.contains("queue status: queued") == true)
        let reopened = try ConversationRepository(databaseURL: f.root.appending(path: "canonical.sqlite"))
        let saved = try await reopened.load(); expectNoDifference(saved, chats)
        let reopenedContexts = try AgentConversationStore(url: f.root.appending(path: "contexts.json"))
        let restored = try await reopenedContexts.context(accountID: "local", originID: origin, agentID: f.recipient.id)
        expectNoDifference(restored, own)
        try await session.close()
    }

    @Test(arguments: ["account", "origin", "sender", "agent", "destination", "author", "directory", "group-route", "missing-transcript", "no-factory", "no-store"])
    func wrongOrAbsentHostAcquisitionNeverBorrowsForegroundCapability(mode: String) async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let session = session(f, mode: mode)
        try await enqueue(f, session)
        try await drain(f, session)
        let queues = await f.channels.deliveries(), chats = try await f.repository.load()
        expectNoDifference(queues, []); expectNoDifference(chats, f.initial)
        let reviews = await f.probe.reviews, sent = await f.probe.sent
        expectNoDifference(reviews, []); expectNoDifference(sent, [])
        let events = await f.probe.events
        #expect(!events.contains("WRONG_FOREGROUND_FACTORY"))
        let requests = await f.probe.requests
        expectNoDifference(requests.count, mode.hasPrefix("no-") ? 1 : 0)
        let incoming = try #require(await f.messenger.allMessages().first)
        expectNoDifference(incoming.delivery?.state, mode.hasPrefix("no-") ? .completed : .failed)
        expectNoDifference(incoming.delivery?.publications, nil)
        try await session.close()
    }

    @Test(arguments: ["approve", "deny-source", "deny-send", "stop-review", "missing-save", "throw-save", "forged-save"])
    func capturedSourceAndQueueReceiptDoNotBecomeFakeMailboxPublications(mode: String) async throws {
        let f = try await fixture(attachment: true)
        defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let session = session(f, mode: mode, attachment: true)
        try await enqueue(f, session)
        do { try await drain(f, session) } catch is CancellationError {
            #expect(["deny-source", "deny-send", "stop-review"].contains(mode))
        }
        let allowedQueue = ["approve", "missing-save", "throw-save", "forged-save"].contains(mode)
        let queue = await f.channels.deliveries(), chats = try await f.repository.load()
        expectNoDifference(queue.count, allowedQueue ? 1 : 0)
        let report = try #require(await f.messenger.allMessages().first)
        expectNoDifference(report.delivery?.publications, nil); expectNoDifference(report.delivery?.finalPublication, nil)
        if mode == "approve" {
            let review = try #require(await f.probe.reviews.first)
            expectNoDifference(review.attachment?.file.bytes, Data("EXACT_CAPTURED_BYTES".utf8))
            let row = try #require(chats.first { $0.id == f.destination }?.messages.last?.externalChannelPublication)
            expectNoDifference(row.sources, [.init(url: "file:///isolated/captured.html", alt: "EXACT_CAPTION")])
            let attachment = try #require(review.attachment)
            expectNoDifference(row.files, [.init(digest: attachment.metadata.blobID, filename: "captured.html",
                mimeType: "application/octet-stream", byteCount: Int64(Data("EXACT_CAPTURED_BYTES".utf8).count))])
            #expect(report.delivery?.response?.contains("queue status: queued") == true)
        } else {
            expectNoDifference(chats, f.initial)
            #expect(report.delivery?.response?.contains("saved in recipient chat") != true)
        }
        let updates = await f.probe.updates, projections = await f.probe.projections, sent = await f.probe.sent
        #expect(updates.allSatisfy { $0.externalPublication == nil && $0.text.isEmpty })
        #expect(projections.allSatisfy { $0.source.kind == .incoming })
        expectNoDifference(sent, [])
        try await session.close()
    }

    @Test func providerFailureAfterCanonicalReceiptRetainsTheExplicitSavedFact() async throws {
        let f = try await fixture(failAfterPublication: true)
        defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let session = session(f)
        try await enqueue(f, session); try await drain(f, session)
        let delivery = try #require(await f.channels.deliveries().first)
        let canonical = try #require(try await f.repository.conversation(id: f.destination)?.messages.last?.externalChannelPublication)
        expectNoDifference(canonical, ChannelTranscriptProjection.publication(for: delivery))
        let incoming = try #require(await f.messenger.allMessages().first)
        expectNoDifference(incoming.delivery?.state, .failed)
        expectNoDifference(incoming.delivery?.publications, nil); expectNoDifference(incoming.delivery?.finalPublication, nil)
        #expect(incoming.delivery?.response?.contains("saved in recipient chat \(f.destination.uuidString)") == true)
        #expect(incoming.delivery?.response?.contains("NOT a local mailbox message or proof of remote delivery") == true)
        let updates = await f.probe.updates, sent = await f.probe.sent
        #expect(updates.allSatisfy { $0.externalPublication == nil && $0.text.isEmpty })
        expectNoDifference(sent, [])
        try await session.close()
    }
}
