import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconChannels
import FiliconDomain
import FiliconPersistence

private func destinationID(_ value: Int) -> UUID {
    UUID(uuidString: "37000000-0000-0000-0000-" + String(format: "%012x", value))!
}
private actor DestinationProbe {
    var reviews: [AgentChannelPublicationTransaction.Review] = []
    var events: [String] = []
    var sent: [ChannelOutbound] = []
    func review(_ value: AgentChannelPublicationTransaction.Review) { reviews.append(value); events.append("human review") }
    func record(_ value: String) { events.append(value) }
    func sent(_ value: ChannelOutbound) { sent.append(value) }
}
private struct DestinationConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline destination fixture", supportsAttachments: true)
    let probe: DestinationProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws { await probe.sent(message) }
}

@Suite("Channel approval and canonical destination isolation", .timeLimit(.minutes(1)))
struct AgentChannelTranscriptDestinationTests {
    private let origin = destinationID(1), destination = destinationID(2), agent = destinationID(3), run = destinationID(4)
    private let date = Date(timeIntervalSince1970: 1_500)
    private struct Fixture {
        let root: URL
        let channels: ChannelService
        let store: ConversationRepository
        let probe: DestinationProbe
        let lease: ConversationBindingLease
        let initial: [Conversation]
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-destination-\(UUID())")
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"), newDeliveryID: { destinationID(5) })
        try await channels.saveConnection(.init(id: destinationID(6), connectorID: "slack", displayName: "Recipient's connection",
            secretReference: "keychain://channels/OFFLINE_ONLY", agentID: agent, ownerAccountID: "local"))
        let probe = DestinationProbe()
        await channels.register(DestinationConnector(probe: probe))
        let store = try ConversationRepository(databaseURL: root.appending(path: "canonical.sqlite"))
        var own = Conversation(id: destination, title: "Recipient chat", messages: [
            .init(id: destinationID(8), role: .user, text: "RECIPIENT_PRIVATE_HISTORY", createdAt: date.addingTimeInterval(-10))
        ], updatedAt: date.addingTimeInterval(-10))
        own.agentBinding = .init(accountID: "local", agentID: agent)
        let initial = [Conversation(id: origin, title: "Approval origin", messages: [
            .init(id: destinationID(9), role: .user, text: "ORIGIN_PRIVATE_HISTORY", createdAt: date.addingTimeInterval(-10))
        ], updatedAt: date.addingTimeInterval(-10)), own]
        try await store.save(initial, activityAt: date.addingTimeInterval(-10))
        let canonical = try await store.load()
        let lease = try await store.leaseUniqueBinding(accountID: "local", agentID: agent, conversationID: destination)
        return .init(root: root, channels: channels, store: store, probe: probe, lease: lease, initial: canonical)
    }
    private func transaction(_ f: Fixture, route: ChannelDeliveryOrigin.Route = .directConversation,
        destinationSender: UUID? = nil, destinationChat: UUID? = nil,
        prepare: AgentChannelPublicationTransaction.Prepare? = nil,
        lifetime: ChannelPublicationLifetime? = nil,
        authorize: AgentChannelPublicationTransaction.Authorize? = nil,
        publish: AgentChannelPublicationTransaction.PublishTranscript? = nil) -> AgentChannelPublicationTransaction {
        let date = self.date
        let lifetime = lifetime ?? ChannelPublicationLifetime(commitGuard: { write in try f.lease.withValidBinding(write) })
        return .init(conversationID: origin, senderID: agent, agentID: agent, accountID: "local", channels: f.channels,
            lifetime: lifetime, validateScope: {
                try f.lease.withValidBinding {}
                let canonical = try await f.store.uniqueBoundConversation(accountID: "local", agentID: f.lease.binding.agentID)
                guard canonical?.id == f.lease.conversationID, canonical?.hiddenAt == nil else { throw CancellationError() }
            }, authorize: authorize ?? { review, _, context in
                expectNoDifference(context.conversationID, review.conversationID)
                await f.probe.review(review)
            }, prepare: prepare, install: prepare.map { _ in { @Sendable value in
                await f.probe.record("install captured bytes"); return value.metadata
            } }, supportsRemoteSources: prepare != nil,
            transcriptSource: .init(route: route, senderName: "Recipient", destination: .init(
                conversationID: destinationChat ?? destination, senderID: destinationSender ?? destination)),
            publishTranscript: publish ?? { value in
                await f.probe.record("canonical save")
                let saved = try await f.store.publishExternalChannel(value, expectedHiddenAt: nil, activityAt: date,
                    commit: { write in try f.lease.withValidBinding(write) })
                let row = try #require(saved.messages.first { $0.id == value.deliveryID })
                var receipt = RoomMessage.externalChannelMessage(value)
                receipt.shortAddress = row.shortAddress
                return receipt
            }, makeID: { destinationID(7) }, now: { date })
    }
    private func tool(_ f: Fixture, transaction: AgentChannelPublicationTransaction,
                      history: [RoomMessage] = []) -> AgentUserMessageTool {
        .init(conversationID: origin, senderID: agent, replyHistory: history, supportsQuestions: true,
            channelPublication: transaction, publishGroup: { _, _, _, _ in
                await f.probe.record("unexpected local publication"); return nil
            })
    }
    private func call(_ object: [String: String]) throws -> NormalizedToolCall { try call("publish", object) }
    private func call(_ id: ToolCallID, _ object: [String: String]) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(object))
    }
    private struct Snapshot: Equatable {
        var conversations: [Conversation]
        var connections: [ChannelConnection]
        var deliveries: [ChannelDelivery]
        var events: [String]
        var reviews: [AgentChannelPublicationTransaction.Review]
        var sent: [ChannelOutbound]
        init(_ f: Fixture) async throws {
            conversations = try await f.store.load(); connections = await f.channels.connections()
            deliveries = await f.channels.deliveries(); events = await f.probe.events
            reviews = await f.probe.reviews; sent = await f.probe.sent
        }
    }

    @Test func approvalStaysInOriginWhileActualReceiptBelongsToRecipientCanonicalChat() async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let tx = transaction(f), publisher = tool(f, transaction: tx)
        let context = ToolContext(conversationID: origin, runID: run)
        let request = try call(["type": "text", "content": "EXACT_PUBLIC_RESULT", "channel": "slack:C_RECIPIENT"])
        let expectedPublication = ExternalChannelTranscriptPublication(deliveryID: destinationID(5), connectionID: destinationID(6),
            owner: .init(accountID: "local", agentID: agent), route: .directConversation, conversationID: destination,
            senderID: destination, senderName: "Recipient", runID: run, callID: "publish", replyToMessageID: nil,
            queuedAt: date, kind: .text, text: "EXACT_PUBLIC_RESULT", sources: [], files: [],
            platform: "slack", channelID: "C_RECIPIENT", threadID: nil,
            delivery: .init(status: .queued, attemptCount: 0, deliveredAt: nil))
        var expectedMessage = expectedPublication.directMessage
        expectedMessage.shortAddress = "t0s0"
        let index = try #require(f.initial.firstIndex { $0.id == destination })
        var saved = f.initial, result: NormalizedToolResult?
        await expectDifference(saved) {
            result = try await publisher.execute(request, context: context)
            saved = try await f.store.load()
        } changes: {
            $0[index].messages.append(expectedMessage)
            // The first canonical publication assigns and reserves existing
            // addresses as well, so they cannot be reused by a later edit.
            $0[index].messages[0].shortAddress = "t0u"
            $0[index].messageAddressReservations[destinationID(8).uuidString] = "t0u"
            $0[index].messageAddressReservations[destinationID(5).uuidString] = "t0s0"
            $0[index].updatedAt = date
        }
        let actualResult = try #require(result)
        #expect(!actualResult.isError)
        let delivery = try #require(await f.channels.deliveries().first)
        let expectedOrigin = ChannelDeliveryOrigin(route: .directConversation, conversationID: destination, senderID: destination,
            senderName: "Recipient", runID: run, callID: "publish", intent: .init(kind: .text, text: "EXACT_PUBLIC_RESULT"))
        expectNoDifference(delivery.origin, expectedOrigin)
        expectNoDifference(delivery.authorization?.agentID, agent)
        expectNoDifference(delivery.authorization?.ownerAccountID, "local")
        expectNoDifference(delivery.status, .queued)
        let review = try #require(await f.probe.reviews.first)
        expectNoDifference(review.conversationID, origin); expectNoDifference(review.senderID, agent)
        expectNoDifference(review.publication.outbound, .init(text: "EXACT_PUBLIC_RESULT"))
        let value = try #require(ChannelTranscriptProjection.publication(for: delivery))
        expectNoDifference(value, expectedPublication)
        let proof = actualResult.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
        #expect(proof.contains(destination.uuidString))
        #expect(proof.contains("NOT a reply target"))
        #expect(!proof.contains("You may use this messageID"))
        let beforeReplay = try await Snapshot(f)
        let replay = try await publisher.execute(request, context: context)
        expectNoDifference(replay, actualResult)
        let afterReplay = try await Snapshot(f)
        expectNoDifference(afterReplay, beforeReplay)
        // Neither the saved UUID nor its short alias is imported into the
        // origin directory, even though the host actually saved both.
        for address in [value.deliveryID.uuidString, "t0s0"] {
            let invalid = try await publisher.execute(call(ToolCallID(rawValue: "quote-\(address)"),
                ["text": "DO_NOT_PUBLISH", "reply_to": address]), context: context)
            #expect(invalid.isError)
        }
        let afterQuotes = try await Snapshot(f)
        expectNoDifference(afterQuotes, beforeReplay)
        let reopened = try ConversationRepository(databaseURL: f.root.appending(path: "canonical.sqlite"))
        let reloaded = try await reopened.load()
        expectNoDifference(reloaded, saved)
    }

    @Test(arguments: ["direct-author", "group-author", "quote", "context", "closed", "binding-ABA"])
    func misboundDestinationOrForeignQuoteCannotReadReviewOrQueue(mode: String) async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let lifetime = ChannelPublicationLifetime(commitGuard: { write in try f.lease.withValidBinding(write) })
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data("PRIVATE_BYTES".utf8), filename: "report.txt"), mimeType: "text/plain")
        let tx = transaction(f, route: mode == "group-author" ? .groupConversation : .directConversation,
            destinationSender: mode.hasSuffix("author") ? destinationID(99) : nil, prepare: { _, _, _, _ in
                await f.probe.record("unexpected source read"); return prepared
            }, lifetime: lifetime)
        var original = RoomMessage(id: destinationID(11), groupID: origin, senderID: nil, text: "Original quote", createdAt: date)
        original.shortAddress = "t0u"
        let publisher = tool(f, transaction: tx, history: [original])
        if mode == "closed" { lifetime.close() }
        if mode == "binding-ABA" {
            var values = try await f.store.load()
            let index = try #require(values.firstIndex { $0.id == destination })
            let before = values
            values[index].agentBinding = .init(accountID: "local", agentID: destinationID(90))
            try await f.store.save(values, activityAt: date)
            try await f.store.save(before, activityAt: date)
        }
        var arguments = ["type": "attachment", "url": "file:///fixture/report.txt", "channel": "slack:C_RECIPIENT"]
        if mode == "quote" { arguments["reply_to"] = "t0u" }
        let before = try await Snapshot(f)
        do {
            let result = try await publisher.execute(call(arguments),
                context: .init(conversationID: mode == "context" ? destination : origin, runID: run))
            #expect(result.isError)
        } catch is CancellationError {
            #expect(mode == "closed" || mode == "binding-ABA")
        } catch let error as AgentMessagingError {
            #expect(mode == "context")
            expectNoDifference(error, .scopeMismatch)
        }
        let after = try await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: ["file:///fixture/report.txt", "https://fixture.example/report.txt?signature=exact"])
    func sourceConsentAndSendReviewUseOriginNotCanonicalDestination(source: String) async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data("CAPTURED_BYTES".utf8), filename: "report.txt"), mimeType: "text/plain")
        let tx = transaction(f, prepare: { input, image, _, context in
            expectNoDifference(context.conversationID, origin); expectNoDifference(image, false)
            let sourceURL: String
            switch input.source { case .localFile(let url): sourceURL = url; case .remote(let reference): sourceURL = reference.url; case .hostImage: sourceURL = "INVALID" }
            expectNoDifference(sourceURL, source)
            await f.probe.record("independent source consent"); return prepared
        })
        let result = try await tool(f, transaction: tx).execute(call(["type": "attachment", "url": source,
            "alt": "Exact caption", "channel": "slack:C_RECIPIENT"]), context: .init(conversationID: origin, runID: run))
        #expect(!result.isError)
        let state = try await Snapshot(f)
        expectNoDifference(state.events, ["independent source consent", "human review", "install captured bytes", "canonical save"])
        expectNoDifference(state.sent, [])
        expectNoDifference(state.deliveries.map(\.outbound), [.init(text: "Exact caption", attachments: [prepared.metadata])])
        expectNoDifference(state.reviews.map(\.conversationID), [origin])
        expectNoDifference(state.deliveries.first?.origin?.conversationID, destination)
    }

    @Test(arguments: ["missing", "forged", "save-failure"])
    func missingOrInvalidCanonicalReceiptNeverInvitesResendOrClaimsLocalDirectoryGrant(mode: String) async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let tx = transaction(f, publish: { value in
            await f.probe.record("failed canonical projection")
            if mode == "save-failure" { throw CancellationError() }
            if mode == "missing" { return nil }
            var forged = RoomMessage.externalChannelMessage(value)
            forged.text = "FORGED_DIFFERENT_PUBLICATION"
            return forged
        })
        let publisher = tool(f, transaction: tx), context = ToolContext(conversationID: origin, runID: run)
        let request = try call(["type": "text", "content": "Already queued", "channel": "slack:C_RECIPIENT"])
        let result = try await publisher.execute(request, context: context)
        #expect(!result.isError)
        let proof = result.content.compactMap { if case .text(let value) = $0 { value } else { nil } }.joined()
        #expect(proof.contains("not confirmed delivered")); #expect(proof.contains("Do not resend"))
        #expect(!proof.contains("Publication saved")); #expect(!proof.contains("Saved message receipt"))
        let before = try await Snapshot(f)
        expectNoDifference(before.conversations, f.initial); expectNoDifference(before.deliveries.count, 1)
        let replay = try await publisher.execute(request, context: context)
        expectNoDifference(replay, result)
        let after = try await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: ["destinationConversationID", "destinationSenderID", "conversationID", "senderID", "transcriptSource", "accountID"])
    func modelCannotSelectCanonicalDestinationOrAuthor(field: String) async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let publisher = tool(f, transaction: transaction(f))
        var arguments = ["type": "text", "content": "Do not publish", "channel": "slack:C_RECIPIENT"]
        arguments[field] = destinationID(99).uuidString
        let before = try await Snapshot(f)
        let result = try await publisher.execute(call(arguments), context: .init(conversationID: origin, runID: run))
        #expect(result.isError)
        let after = try await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: ["review", "install"])
    func lateRevocationStillFencesSeparateCanonicalDestinationBeforeQueue(stage: String) async throws {
        let f = try await fixture(); defer { f.lease.close(); try? FileManager.default.removeItem(at: f.root) }
        let lifetime = ChannelPublicationLifetime(commitGuard: { write in try f.lease.withValidBinding(write) })
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data("CAPTURED_BYTES".utf8), filename: "report.txt"), mimeType: "text/plain")
        let tx = AgentChannelPublicationTransaction(conversationID: origin, senderID: agent, agentID: agent, accountID: "local",
            channels: f.channels, lifetime: lifetime, validateScope: { try f.lease.withValidBinding {} },
            authorize: { review, _, _ in
                await f.probe.review(review)
                if stage == "review" { lifetime.close() }
            }, prepare: { _, _, _, _ in prepared }, install: { value in
                await f.probe.record("install captured bytes"); f.lease.close(); return value.metadata
            }, transcriptSource: .init(route: .directConversation, senderName: "Recipient",
                destination: .init(conversationID: destination, senderID: destination)),
            publishTranscript: { _ in await f.probe.record("unexpected canonical save"); return nil },
            makeID: { destinationID(7) }, now: { date })
        await #expect(throws: CancellationError.self) {
            _ = try await tool(f, transaction: tx).execute(call(["type": "attachment", "url": "file:///fixture/report.txt",
                "channel": "slack:C_RECIPIENT"]), context: .init(conversationID: origin, runID: run))
        }
        let state = try await Snapshot(f)
        expectNoDifference(state.conversations, f.initial)
        expectNoDifference(state.deliveries, []); expectNoDifference(state.sent, [])
        expectNoDifference(state.events, stage == "review" ? ["human review"] : ["human review", "install captured bytes"])
    }
}
