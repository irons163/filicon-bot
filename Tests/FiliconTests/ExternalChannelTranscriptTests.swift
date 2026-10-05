import Foundation
import Testing
import CustomDump
import CSQLite
import FiliconDomain
import FiliconPersistence
import FiliconAgents
import FiliconChannels
import FiliconAppServices

private func externalID(_ n: Int) -> UUID { UUID(uuidString: String(format: "38000000-0000-0000-0000-%012d", n))! }
private final class ExternalTranscriptClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_900_000_000)
    func next() -> Date {
        lock.withLock { date = date.addingTimeInterval(1); return date }
    }
}
private actor ExternalTranscriptProbe {
    var saves = 0
    var sends = 0
    func save() { saves += 1 }
    func send() { sends += 1 }
}
private struct ExternalTranscriptConnector: ChannelConnector {
    let probe: ExternalTranscriptProbe
    var descriptor: ChannelConnectorDescriptor { .init(id: "slack", displayName: "Offline transcript fixture") }
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> { .init { $0.finish() } }
    func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws { await probe.send() }
}

private struct ExternalFixtureResponder: GroupAgentResponder {
    let publish: @Sendable (AgentProfile, @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] { Issue.record("A saved publication callback is required"); return [] }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
        onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
        onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        try await publish(agent, onSavedPublication)
    }
}

@Suite("Canonical external channel transcript", .timeLimit(.minutes(1)))
struct ExternalChannelTranscriptTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)
    private let owner = DirectConversationAgentBinding(accountID: "fixture", agentID: externalID(1))
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-external-transcript-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func publication(route: ExternalChannelTranscriptPublication.Route = .directConversation,
        chat: UUID = externalID(2), sender: UUID? = nil, id: UUID = externalID(3),
        binding: DirectConversationAgentBinding? = nil, kind: ExternalChannelTranscriptPublication.Kind = .text,
        text: String = "Exact outgoing caption",
        sources: [ExternalChannelTranscriptPublication.Source] = [], files: [ExternalChannelTranscriptPublication.File] = []) -> ExternalChannelTranscriptPublication {
        let owner = binding ?? self.owner
        return .init(deliveryID: id, connectionID: externalID(4), owner: owner, route: route, conversationID: chat,
            senderID: sender ?? (route == .directConversation ? chat : owner.agentID), senderName: "Original member",
            runID: externalID(5), callID: "original-call", replyToMessageID: nil, queuedAt: date,
            kind: kind, text: text, sources: sources, files: files,
            platform: "slack", channelID: "C_ORIGINAL", threadID: "platform-thread",
            delivery: .init(status: .queued, attemptCount: 0, deliveredAt: nil))
    }
    private func chat() -> Conversation {
        var value = Conversation(id: externalID(2), title: "Original chat", messages: [
            .init(id: externalID(10), role: .user, text: "Preserve this old human message", createdAt: date.addingTimeInterval(-1))
        ], updatedAt: date)
        value.agentBinding = owner
        return value
    }
    private func sql(_ statement: String, at url: URL) throws {
        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
    }

    @Test(arguments: [ExternalChannelTranscriptPublication.Status.delivered, .deadLetter])
    func canonicalDirectStatusReplaysPreserveHistoryIdentityReactionsAndUnread(terminal: ExternalChannelTranscriptPublication.Status) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "canonical.sqlite"), repo = try ConversationRepository(databaseURL: file)
        try await repo.save([chat()], activityAt: date)
        let queued = publication()
        var saved = try await repo.publishExternalChannel(queued, expectedHiddenAt: nil, activityAt: date)
        let row = try #require(saved.messages.firstIndex { $0.id == queued.deliveryID })
        #expect(saved.messages[row].matchesExternalPublication(queued))
        saved.messages[row].reactions = [.init(emoji: "👍", actorID: "human")]
        try await repo.save([saved], activityAt: date)
        let unread = try await repo.unreadState(conversationID: saved.id)
        var advanced = queued
        advanced.delivery = .init(status: .retrying, attemptCount: 1, deliveredAt: nil)
        _ = try await repo.publishExternalChannel(advanced, expectedHiddenAt: nil, activityAt: date)
        advanced.delivery = .init(status: terminal, attemptCount: 2, deliveredAt: terminal == .delivered ? date.addingTimeInterval(1) : nil)
        let finished = try await repo.publishExternalChannel(advanced, expectedHiddenAt: nil, activityAt: date)
        let reopened = try ConversationRepository(databaseURL: file)
        let replay = try await reopened.publishExternalChannel(queued, expectedHiddenAt: nil, activityAt: date)
        expectNoDifference(replay, finished)
        expectNoDifference(replay.messages.map(\.id), saved.messages.map(\.id))
        expectNoDifference(replay.messages.first, saved.messages.first)
        expectNoDifference(replay.messages[row].reactions, saved.messages[row].reactions)
        expectNoDifference(replay.messages[row].shortAddress, saved.messages[row].shortAddress)
        let reopenedUnread = try await reopened.unreadState(conversationID: saved.id)
        expectNoDifference(reopenedUnread, unread)
        #expect(replay.messages[row].matchesExternalPublication(advanced))
    }

    @Test(arguments: ["foreign-owner", "wrong-chat", "ambiguous", "hidden", "deleted", "human-collision", "other-chat-collision", "forged-card"])
    func projectionRejectsRetargetsAndCollisionsWithoutChangingAnyHistory(mode: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "canonical.sqlite"))
        var original = chat(), values: [Conversation] = []
        let record = publication()
        switch mode {
        case "foreign-owner": original.agentBinding = .init(accountID: "other", agentID: owner.agentID)
        case "wrong-chat": original = Conversation(id: externalID(8), title: "Other original", messages: [], updatedAt: date); original.agentBinding = owner
        case "ambiguous": var another = Conversation(id: externalID(8), title: "Ambiguous", messages: [], updatedAt: date); another.agentBinding = owner; values.append(another)
        case "hidden": original.hiddenAt = date
        case "human-collision": original.messages.append(.init(id: record.deliveryID, role: .user, text: record.text, createdAt: date))
        case "other-chat-collision": values.append(.init(id: externalID(8), title: "Foreign row", messages: [record.directMessage], updatedAt: date))
        case "forged-card": var forged = record.directMessage; forged.transcriptCards[0].actions = [.init(id: "retry", label: "Retry", intent: .retry(cardID: record.deliveryID))]; original.messages.append(forged)
        default: break
        }
        if mode != "deleted" { values.append(original) }
        try await repo.save(values, activityAt: date)
        let before = try await repo.load()
        await #expect(throws: (any Error).self) { try await repo.publishExternalChannel(record, expectedHiddenAt: nil, activityAt: date) }
        let after = try await repo.load()
        expectNoDifference(after, before)
    }

    @Test func canonicalSaveFailureRollsBackAndLaterRepairUsesTheSameID() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "canonical.sqlite"), repo = try ConversationRepository(databaseURL: file)
        try await repo.save([chat()], activityAt: date)
        let before = try await repo.load(), unread = try await repo.unreadState(conversationID: externalID(2))
        try sql("CREATE TRIGGER reject_external BEFORE INSERT ON messages WHEN NEW.role='assistant' BEGIN SELECT RAISE(ABORT,'isolated external transcript failure'); END", at: file)
        await #expect(throws: (any Error).self) { try await repo.publishExternalChannel(publication(), expectedHiddenAt: nil, activityAt: date) }
        let after = try await repo.load(), afterUnread = try await repo.unreadState(conversationID: externalID(2))
        expectNoDifference(after, before)
        expectNoDifference(afterUnread, unread)
        try sql("DROP TRIGGER reject_external", at: file)
        let repaired = try await repo.publishExternalChannel(publication(), expectedHiddenAt: nil, activityAt: date)
        expectNoDifference(repaired.messages.filter { $0.externalChannelPublication != nil }.map(\.id), [externalID(3)])
    }

    @Test func revokedHostFenceCannotPublishOrRepair() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "canonical.sqlite"))
        try await repo.save([chat()], activityAt: date)
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        scope.invalidate()
        let before = try await repo.load()
        await #expect(throws: CancellationError.self) {
            try await repo.publishExternalChannel(publication(), expectedHiddenAt: nil, activityAt: date,
                commit: { write in try lease.commit(write) })
        }
        let after = try await repo.load()
        expectNoDifference(after, before)
    }

    @Test func staleTurnUpsertCannotDowngradeTheDeliveryCard() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "canonical.sqlite"))
        try await repo.save([chat()], activityAt: date)
        let queued = publication()
        var stale = try await repo.publishExternalChannel(queued, expectedHiddenAt: nil, activityAt: date)
        var delivered = queued; delivered.delivery = .init(status: .delivered, attemptCount: 1, deliveredAt: date.addingTimeInterval(1))
        _ = try await repo.publishExternalChannel(delivered, expectedHiddenAt: nil, activityAt: date)
        let index = try #require(stale.messages.firstIndex { $0.id == queued.deliveryID })
        stale.messages[index].reactions = [.init(emoji: "👍", actorID: "human")]
        try await repo.upsert(stale, activityAt: date)
        let after = try #require(try await repo.conversation(id: stale.id))
        expectNoDifference(after.messages[index].externalChannelPublication, delivered)
        expectNoDifference(after.messages[index].reactions, stale.messages[index].reactions)
        stale.messages[index].text = "Attempt to relabel the old receipt"
        await #expect(throws: CancellationError.self) { try await repo.upsert(stale, activityAt: date) }
        let unchanged = try await repo.conversation(id: stale.id)
        expectNoDifference(unchanged, after)
    }

    @Test(arguments: [false, true])
    func aReceiptArrivingAfterTheLoadedSnapshotCannotBeErased(historyComplete: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        var stale = chat()
        let loaded = Set(stale.messages.map(\.id))
        try await store.upsert(stale, replacingLoadedMessageIDs: loaded, historyComplete: true, activityAt: date.addingTimeInterval(-1))
        let value = publication()
        let queued = try await store.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date)
        stale.messages.append(.init(id: externalID(11), role: .user, text: "A newer local turn", createdAt: date.addingTimeInterval(1)))
        try await store.upsert(stale, replacingLoadedMessageIDs: loaded, historyComplete: historyComplete, activityAt: date.addingTimeInterval(1))
        let after = try #require(try await store.conversation(id: stale.id))
        expectNoDifference(after.messages.map(\.id), [externalID(10), value.deliveryID, externalID(11)])
        expectNoDifference(after.messages[1], queued.messages[1])
        let unread = try #require(try await store.unreadState(conversationID: stale.id))
        expectNoDifference(unread.unreadCount, 3)
    }

    @Test func recoveryDoesNotRestoreANativelyDeletedExternalRow() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "canonical.sqlite"), repo = try ConversationRepository(databaseURL: file)
        try await repo.save([chat()], activityAt: date)
        let value = publication()
        var saved = try await repo.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date)
        let loaded = Set(saved.messages.map(\.id))
        saved.messages.removeAll { $0.id == value.deliveryID }
        try await repo.upsert(saved, activityAt: date, replacingLoadedMessageIDs: loaded)
        let before = try await repo.conversation(id: saved.id), unread = try await repo.unreadState(conversationID: saved.id)
        let reopened = try ConversationRepository(databaseURL: file)
        await #expect(throws: CancellationError.self) { try await reopened.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date) }
        let after = try await reopened.conversation(id: saved.id), afterUnread = try await reopened.unreadState(conversationID: saved.id)
        expectNoDifference(after, before)
        expectNoDifference(afterUnread, unread)
    }

    @Test(arguments: [ExternalChannelTranscriptPublication.Route.directConversation, .groupConversation])
    func anAttachmentWithoutAltTextIsStillOneVisiblePublication(route: ExternalChannelTranscriptPublication.Route) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let sources: [ExternalChannelTranscriptPublication.Source] = [.init(url: "file:///never-read/report.pdf", alt: nil)]
        let files: [ExternalChannelTranscriptPublication.File] = [.init(digest: String(repeating: "a", count: 64), filename: "report.pdf", mimeType: "application/pdf", byteCount: 17)]
        if route == .directConversation {
            let repo = try ConversationRepository(databaseURL: root.appending(path: "canonical.sqlite"))
            try await repo.save([chat()], activityAt: date.addingTimeInterval(-1))
            let value = publication(kind: .attachment, text: "", sources: sources, files: files)
            let first = try await repo.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date)
            let row = try #require(first.messages.last)
            #expect(row.shortAddress != nil && row.matchesExternalPublication(value))
            expectNoDifference(row.text, "")
            let unread = try #require(try await repo.unreadState(conversationID: first.id))
            expectNoDifference(unread.unreadCount, 2)
            _ = try await repo.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date)
            let replayUnread = try await repo.unreadState(conversationID: first.id)
            expectNoDifference(replayUnread, unread)
            var navigation = first
            navigation.messages.append(.init(id: externalID(11), role: .user, text: "A later visible reply", createdAt: date.addingTimeInterval(1)))
            DirectMessageAddressing.assignMissing(in: &navigation)
            let address = try #require(row.shortAddress)
            let link = try #require(URL(string: "sand-msg:" + address))
            expectNoDifference(DirectMessageReferenceDirectory(conversation: navigation, historyComplete: true)
                .target(for: link, from: externalID(11), in: first.id), value.deliveryID)
        } else {
            let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
            let sender = try await agents.create(name: "Original member", providerID: "fixture", modelID: "fixture")
            let clock = ExternalTranscriptClock()
            let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"), activityDate: { clock.next() })
            let group = try await groups.create(name: "Original group", memberIDs: [sender.id])
            let value = publication(route: .groupConversation, chat: group.id, sender: sender.id,
                binding: .init(accountID: "fixture", agentID: sender.id), kind: .attachment, text: "", sources: sources, files: files)
            let first = try await groups.projectExternalChannel(value)
            #expect(first.shortAddress != nil && first.matchesExternalPublication(value))
            #expect(GroupThreadProjection(history: [first], groupID: group.id).canReply(to: first.id))
            expectNoDifference(first.text, "")
            let unread = try await groups.unreadState(groupID: group.id)
            expectNoDifference(unread.unreadCount, 1)
            _ = try await groups.projectExternalChannel(value)
            let replayUnread = try await groups.unreadState(groupID: group.id)
            expectNoDifference(replayUnread, unread)
            let later = try await groups.postUserMessage("A later visible reply", groupID: group.id)
            let history = await groups.messages(groupID: group.id)
            let address = try #require(first.shortAddress)
            let link = try #require(URL(string: "sand-msg:" + address))
            expectNoDifference(GroupMessageReferenceDirectory(history: history, groupID: group.id)
                .target(for: link, from: later.id), value.deliveryID)
        }
    }

    @Test(arguments: [false, true])
    func externalGroupPublicationsUseRealReceiptsAndTheSameTwoMessageBudget(recoveryWinsFirst: Bool) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Original member", providerID: "fixture", modelID: "fixture")
        let clock = ExternalTranscriptClock()
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"), activityDate: { clock.next() })
        let group = try await groups.create(name: "Original group", memberIDs: [sender.id])
        _ = try await groups.postUserMessage("Publish reviewed external messages", groupID: group.id)
        let date = self.date
        let values = [1, 2, 3].map { n in
            ExternalChannelTranscriptPublication(deliveryID: externalID(100 + n), connectionID: externalID(4),
                owner: .init(accountID: "fixture", agentID: sender.id), route: .groupConversation, conversationID: group.id,
                senderID: sender.id, senderName: sender.name, runID: externalID(5), callID: "call-\(n)", replyToMessageID: nil,
                queuedAt: date, kind: .text, text: "Identical reviewed caption", sources: [], files: [],
                platform: "slack", channelID: "C_\(n)", threadID: nil, delivery: .init(status: .queued, attemptCount: 0, deliveredAt: nil))
        }
        let result = try await groups.run(groupID: group.id, responder: ExternalFixtureResponder { _, publish in
            let lifetime = AgentPublicationLifetime()
            for value in values.prefix(2) {
                if recoveryWinsFirst { _ = try await groups.projectExternalChannel(value) }
                let receipt = try #require(try await publish(.init(text: value.text, lifetime: lifetime, externalPublication: value)))
                #expect(receipt.matchesExternalPublication(value))
                #expect(receipt.shortAddress != nil)
            }
            await #expect(throws: (any Error).self) {
                try await publish(.init(text: values[2].text, lifetime: lifetime, externalPublication: values[2]))
            }
            return ["PASS"]
        })
        expectNoDifference(result.map(\.id), values.prefix(2).map(\.deliveryID))
        let history = await groups.messages(groupID: group.id)
        expectNoDifference(history.compactMap(\.externalPublication), Array(values.prefix(2)))
        let unread = try await groups.unreadState(groupID: group.id)
        expectNoDifference(unread.unreadCount, 3)
    }

    @Test(arguments: ["sender", "chat", "text", "id", "date", "image", "tool", "questionReply", "quote"])
    func damagedGroupMetadataIsRejectedRatherThanRelabelingASavedReceipt(field: String) throws {
        let value = publication(route: .groupConversation)
        let message = RoomMessage.externalChannelMessage(value)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        switch field {
        case "sender": object["senderID"] = externalID(90).uuidString
        case "chat": object["groupID"] = externalID(90).uuidString
        case "text": object["text"] = "Changed caption"
        case "id": object["id"] = externalID(90).uuidString
        case "date": object["createdAt"] = 0
        case "image": object["images"] = [["invalid": "data"]]
        case "tool": object["memberOutcome"] = "failed"
        case "questionReply": object["questionReplyTo"] = externalID(90).uuidString
        case "quote": object["replyToMessageID"] = externalID(90).uuidString
        default: break
        }
        let json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RoomMessage.self, from: json) }
    }

    @Test func groupRecoveryIsStableAndDoesNotInvokeAResponder() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Original member", providerID: "fixture", modelID: "fixture")
        let clock = ExternalTranscriptClock()
        let file = root.appending(path: "groups.json"), groups = try GroupService(agents: agents, storeURL: file, activityDate: { clock.next() })
        let group = try await groups.create(name: "Original group", memberIDs: [sender.id])
        var value = publication(route: .groupConversation, chat: group.id, sender: sender.id,
            binding: .init(accountID: "fixture", agentID: sender.id))
        let queued = value
        let first = try await groups.projectExternalChannel(value)
        let unread = try await groups.unreadState(groupID: group.id)
        value.delivery = .init(status: .delivered, attemptCount: 1, deliveredAt: date.addingTimeInterval(1))
        let delivered = try await groups.projectExternalChannel(value)
        expectNoDifference(delivered.shortAddress, first.shortAddress)
        let reopened = try GroupService(agents: agents, storeURL: file, activityDate: { clock.next() })
        let replay = try await reopened.projectExternalChannel(queued)
        let history = await reopened.messages(groupID: group.id), afterUnread = try await reopened.unreadState(groupID: group.id)
        expectNoDifference(replay, delivered)
        expectNoDifference(history, [delivered])
        expectNoDifference(afterUnread, unread)
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture(); scope.invalidate()
        let before = try Data(contentsOf: file)
        await #expect(throws: CancellationError.self) { try await reopened.projectExternalChannel(queued, commit: { try lease.commit($0) }) }
        expectNoDifference(try Data(contentsOf: file), before)
    }

    @Test(arguments: ["save", "failure", "cancelled", "forged"])
    func durableQueueReceiptSurvivesTranscriptFailureAndCannotResend(mode: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        try await channels.saveConnection(.init(connectorID: "slack", displayName: "Isolated connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: owner.agentID, ownerAccountID: owner.accountID))
        let probe = ExternalTranscriptProbe(), date = self.date
        await channels.register(ExternalTranscriptConnector(probe: probe))
        let transaction = AgentChannelPublicationTransaction(conversationID: externalID(2), senderID: externalID(2),
            agentID: owner.agentID, accountID: owner.accountID, channels: channels, validateScope: {}, authorize: { _, _, _ in },
            transcriptSource: .init(route: .directConversation, senderName: "Original member"), publishTranscript: { value in
                await probe.save()
                if mode == "failure" { throw CocoaError(.fileWriteNoPermission) }
                if mode == "cancelled" { throw CancellationError() }
                if mode == "forged" { return RoomMessage(groupID: value.conversationID, senderID: value.senderID, text: value.text) }
                return .externalChannelMessage(value)
            }, makeID: { externalID(3) }, now: { date })
        let call = try NormalizedToolCall(id: "original-call", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let context = ToolContext(conversationID: externalID(2), runID: externalID(5))
        let message = try AgentChannelMessage.parse(["type": "text", "content": "Exact outgoing caption", "channel": "slack:C_ORIGINAL"])
        let first = try await transaction.publish(message, replyTo: nil, call: call, context: context)
        transaction.close()
        let replay = try await transaction.publish(message, replyTo: nil, call: call, context: context)
        expectNoDifference(first, replay)
        expectNoDifference(first.savedMessage != nil, mode == "save")
        let deliveries = await channels.deliveries(), saves = await probe.saves, sends = await probe.sends
        expectNoDifference(deliveries.map(\.id), [first.delivery.id])
        expectNoDifference(deliveries.map(\.idempotencyKey), [externalID(3)])
        expectNoDifference(saves, 1)
        expectNoDifference(sends, 0)
        #expect(ChannelTranscriptProjection.publication(for: first.delivery) != nil)
        var legacy = first.delivery
        legacy = .init(id: legacy.id, connectionID: legacy.connectionID, address: legacy.address, outbound: legacy.outbound)
        #expect(ChannelTranscriptProjection.publication(for: legacy) == nil)
    }

    @Test func allSourceLocatorsAndUnsentImagesRemainExactAndInert() throws {
        let sources: [ExternalChannelTranscriptPublication.Source] = [
            .init(url: "https://source.invalid/image.png?signature=a%2Bb&literal={0}", alt: "First original description"),
            .init(url: "file:///never-read/second.png", alt: "Second original description")]
        let files: [ExternalChannelTranscriptPublication.File] = [.init(digest: String(repeating: "a", count: 64), filename: "image.png", mimeType: "image/png", byteCount: 7)]
        let value = publication(sources: sources, files: files)
        #expect(value.isValid)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        expectNoDifference(try decoder.decode(ChatMessage.self, from: encoder.encode(value.directMessage)), value.directMessage)
        expectNoDifference(value.directMessage.externalChannelPublication?.sources, sources)
        expectNoDifference(value.transcriptCard.actions, [])
        expectNoDifference(value.directMessage.attachments, [])
        #expect(value.directMessage.remoteAttachment == nil && value.directMessage.remoteImages == nil)
    }
}
