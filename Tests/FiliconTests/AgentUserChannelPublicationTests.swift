import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconChannels
import FiliconDomain

private func channelTestID(_ value: Int) -> UUID {
    UUID(uuidString: "31000000-0000-0000-0000-" + String(format: "%012x", value))!
}
private final class ChannelMessageIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 100
    func next() -> UUID { lock.withLock { nextValue += 1; return channelTestID(nextValue) } }
}
private actor ChannelMessageProbe {
    var events: [String] = []
    var reviews: [AgentChannelPublicationTransaction.Review] = []
    var sends: [ChannelOutbound] = []
    func record(_ value: String) { events.append(value) }
    func review(_ value: AgentChannelPublicationTransaction.Review) { reviews.append(value); events.append("review") }
    func send(_ value: ChannelOutbound) { sends.append(value) }
}
private struct MessageTestConnector: ChannelConnector {
    var supportsAttachments = true
    var descriptor: ChannelConnectorDescriptor {
        .init(id: "slack", displayName: "Offline test", supportsAttachments: supportsAttachments)
    }
    let probe: ChannelMessageProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws { await probe.send(message) }
}

@Suite("SendMessage scoped channel adapter", .timeLimit(.minutes(1)))
struct AgentUserChannelPublicationTests {
    private let origin = channelTestID(1), sender = channelTestID(2), agent = channelTestID(3)
    private let date = Date(timeIntervalSince1970: 1_500)
    private struct Fixture {
        let root: URL
        let channels: ChannelService
        let connection: ChannelConnection
        let probe: ChannelMessageProbe
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-message-\(UUID())")
        let ids = ChannelMessageIDs()
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"), newDeliveryID: { ids.next() })
        let connection = ChannelConnection(id: channelTestID(4), connectorID: "slack", displayName: "Own test connection",
            secretReference: "keychain://channels/TEST-only", agentID: agent, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        let probe = ChannelMessageProbe()
        await channels.register(MessageTestConnector(probe: probe))
        return .init(root: root, channels: channels, connection: connection, probe: probe)
    }
    private func transaction(_ f: Fixture, prepare: AgentChannelPublicationTransaction.Prepare? = nil,
        install: AgentChannelPublicationTransaction.Install? = nil,
        authorize: AgentChannelPublicationTransaction.Authorize? = nil,
        lifetime: ChannelPublicationLifetime = .init(), scope: UUID? = nil, author: UUID? = nil,
        transcriptSource: AgentChannelPublicationTransaction.TranscriptSource? = nil,
        inboundReplyAddress: ChannelAddress? = nil,
        remote: Bool = false, makeID: (@Sendable () -> UUID)? = nil,
        validate: @escaping @Sendable () async throws -> Void = {}) -> AgentChannelPublicationTransaction {
        let ids = ChannelMessageIDs(), date = self.date
        return .init(conversationID: scope ?? origin, senderID: author ?? sender, agentID: agent, accountID: "local",
            channels: f.channels, lifetime: lifetime, validateScope: validate,
            authorize: authorize ?? { review, _, _ in await f.probe.review(review) },
            prepare: prepare, install: install, supportsRemoteSources: remote, transcriptSource: transcriptSource,
            inboundReplyAddress: inboundReplyAddress,
            makeID: makeID ?? { ids.next() }, now: { date })
    }
    private func tool(_ f: Fixture, transaction: AgentChannelPublicationTransaction?) -> AgentUserMessageTool {
        .init(conversationID: origin, senderID: sender, replyHistory: [], supportsQuestions: true,
            channelPublication: transaction, publishGroup: { _, _, _, _ in await f.probe.record("local publication"); return nil })
    }
    private func call(_ id: ToolCallID, _ json: String) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: Data(json.utf8))
    }
    private func properties(_ tool: AgentUserMessageTool) throws -> [String: Any] {
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        return try #require(schema["properties"] as? [String: Any])
    }

    @Test func boundTextToolReviewsAndQueuesWithoutLocalOrNetworkSend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = tool(f, transaction: transaction(f))
        #expect(try properties(tool)["channel"] != nil)
        let request = try call("send", #"{"type":"text","content":"Reviewed result","channel":" slack:C_SAFE "}"#)
        let context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let receipt = try await tool.execute(request, context: context)
        #expect(!receipt.isError)
        let deliveries = await f.channels.deliveries()
        #expect(deliveries.count == 1)
        if let delivery = deliveries.first {
            expectNoDifference(delivery.address, .init(platform: "slack", channelID: "C_SAFE"))
            expectNoDifference(delivery.outbound, .init(text: "Reviewed result"))
            expectNoDifference(delivery.status, .queued)
            expectNoDifference(delivery.attemptCount, 0)
            expectNoDifference(delivery.createdAt, date)
            expectNoDifference(delivery.authorization?.agentID, agent)
        }
        let replay = try await tool.execute(request, context: context)
        expectNoDifference(replay, receipt)
        let events = await f.probe.events, sends = await f.probe.sends
        expectNoDifference(events, ["review"])
        expectNoDifference(sends, [])
    }

    @Test func attachmentToolQueuesTheCapturedBytesAndCaptionOnlyAfterReview() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data("fixed bytes".utf8), filename: "report.txt"), mimeType: "text/plain")
        let transaction = transaction(f, prepare: { input, image, _, _ in
            expectNoDifference(input.source, .localFile("file:///workspace/report.txt"))
            expectNoDifference(image, false)
            await f.probe.record("read approved source")
            return prepared
        }, install: { value in
            expectNoDifference(value, prepared)
            await f.probe.record("install reviewed bytes")
            return value.metadata
        })
        let tool = tool(f, transaction: transaction)
        let result = try await tool.execute(call("attachment", #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///workspace/report.txt","alt":"Report caption"}"#),
            context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(!result.isError)
        let events = await f.probe.events, deliveries = await f.channels.deliveries(), sends = await f.probe.sends
        expectNoDifference(events, ["read approved source", "review", "install reviewed bytes"])
        expectNoDifference(deliveries.map(\.outbound), [.init(text: "Report caption", attachments: [prepared.metadata])])
        expectNoDifference(sends, [])
    }

    @Test(arguments: [false, true], ["C_SAFE:THREAD", "C_OTHER:THREAD"])
    func onlyAnAdmittedInboundHostResolvesItsExactTypedReplyThread(admitted: Bool, chat: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = ChannelAddress(platform: "slack", channelID: "C_SAFE", threadID: "THREAD")
        let request = try NormalizedToolCall(id: "reply", name: "SendMessage", argumentsJSON:
            JSONEncoder().encode(["type": "text", "content": "Exact reply", "channel": "slack:\(chat)"]))
        let context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let parsed = try AgentChannelMessage.parse(try #require(JSONSerialization.jsonObject(with: request.argumentsJSON) as? [String: Any]))
        expectNoDifference(parsed.address, .init(platform: "slack", channelID: chat))
        let tx = transaction(f, authorize: { review, _, _ in
                let before = await f.channels.deliveries()
                expectNoDifference(before, [])
                await f.probe.review(review)
            }, inboundReplyAddress: admitted ? source : nil)
        let tool = tool(f, transaction: tx)
        let result = try await tool.execute(request, context: context)
        #expect(!result.isError)
        let expected = admitted && chat == "C_SAFE:THREAD" ? source : parsed.address
        let reviews = await f.probe.reviews, deliveries = await f.channels.deliveries(), sends = await f.probe.sends
        expectNoDifference(reviews.count, 1); expectNoDifference(deliveries.count, 1)
        expectNoDifference(reviews.first?.message.address, expected)
        expectNoDifference(reviews.first?.publication.address, expected)
        expectNoDifference(deliveries.first?.address, expected)
        expectNoDifference(sends, [])
        let replay = try await tool.execute(request, context: context)
        expectNoDifference(replay, result)
        let unchanged = await f.channels.deliveries(); expectNoDifference(unchanged, deliveries)
    }

    @Test func textOnlyDestinationRejectsAttachmentIntentBeforeSourceAccess() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.channels.register(MessageTestConnector(supportsAttachments: false, probe: f.probe))
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data("Private".utf8), filename: "report.txt"), mimeType: "text/plain")
        let tx = transaction(f, prepare: { _, _, _, _ in
            await f.probe.record("unexpected source read"); return prepared
        }, install: { value in
            await f.probe.record("unexpected install"); return value.metadata
        })
        let before = await Snapshot(f)
        let result = try await tool(f, transaction: tx).execute(call("attachment", #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///workspace/report.txt"}"#),
            context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(result.isError)
        let after = await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: [false, true])
    func channelCapabilityRetainsTheUnmodifiedLocalSchema(attachments: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let captured = try PreparedAgentChannelAttachment(file: .init(bytes: Data([1]), filename: "fixture.dat"),
            mimeType: "application/octet-stream")
        let prepare: AgentChannelPublicationTransaction.Prepare? = attachments ? { @Sendable _, _, _, _ in captured } : nil
        let install: AgentChannelPublicationTransaction.Install? = attachments ? { @Sendable in $0.metadata } : nil
        let bound = tool(f, transaction: transaction(f, prepare: prepare, install: install))
        let local = tool(f, transaction: nil)
        let schema = try #require(JSONSerialization.jsonObject(with: bound.descriptor.inputSchema) as? [String: Any])
        let condition = try #require((schema["allOf"] as? [[String: Any]])?.first)
        let original = try JSONSerialization.jsonObject(with: local.descriptor.inputSchema)
        let preserved = try #require(condition["else"] as? [String: Any])
        expectNoDifference(try JSONSerialization.data(withJSONObject: preserved, options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]))
        let before = await Snapshot(f)
        let result = try await bound.execute(call("not-an-external-route",
            #"{"type":"text","content":"No local gallery capability","images":[{"url":"file:///fixture.dat"}]}"#),
            context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(result.isError)
        let after = await Snapshot(f)
        expectNoDifference(after, before)
    }

    private struct Snapshot: Equatable {
        var connections: [ChannelConnection]
        var deliveries: [ChannelDelivery]
        var failures: [ChannelFailureWake]
        var events: [String]
        var reviews: [AgentChannelPublicationTransaction.Review]
        var sends: [ChannelOutbound]
        init(_ f: Fixture) async {
            connections = await f.channels.connections(); deliveries = await f.channels.deliveries()
            failures = await f.channels.failureWakes(); events = await f.probe.events
            reviews = await f.probe.reviews; sends = await f.probe.sends
        }
    }

    @Test(arguments: ["missing", "scope", "sender"])
    func unavailableOrMisboundCapabilityNeverAdvertisesOrPublishes(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let candidate = transaction(f, scope: mode == "scope" ? channelTestID(9) : nil,
                                    author: mode == "sender" ? channelTestID(9) : nil)
        let tool = tool(f, transaction: mode == "missing" ? nil : candidate)
        #expect(try properties(tool)["channel"] == nil)
        let before = await Snapshot(f)
        let result = try await tool.execute(call("send", #"{"type":"text","content":"Private","channel":"slack:C_OTHER"}"#), context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(result.isError)
        let after = await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: [
        #"{"type":"widget","widget":{"prompt":"Approve?","options":[{"label":"Yes"}]},"channel":"slack:C_SAFE"}"#,
        #"{"type":"secret-request","secret":{"label":"Token","connector":"slack","field":"token"},"channel":"slack:C_SAFE"}"#,
        #"{"type":"cursor-agent","bcId":"bc-existing","channel":"slack:C_SAFE"}"#,
        #"{"text":"Legacy","channel":"slack:C_SAFE"}"#,
        #"{"type":"text","content":"X","channel":null}"#,
        #"{"type":"text","content":"X","channel":"slack:"}"#,
        #"{"type":"text","content":"X","channel":"email:C_SAFE"}"#,
        #"{"type":"text","content":"X","channel":"slack:C\n_OTHER"}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","images":["private-id"]}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","images":[{"image_id":"private-id"}]}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","images":[{"url":"http://example.test/image"}]}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","url":"file:///private"}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","connectionID":"chosen-by-model"}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","origin":{"route":"groupConversation","senderID":"chosen-by-model"}}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","senderID":"chosen-by-model"}"#,
        #"{"type":"text","content":"X","channel":"slack:C_SAFE","runID":"chosen-by-model"}"#,
        #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a","image_id":"private-id"}"#,
        #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a","content":"mixed"}"#,
        #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a","images":[]}"#,
        #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a","alt":false}"#,
        #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a","reply_to":"invented"}"#
    ])
    func malformedAndMixedFieldsNeverFallBackToLocalPublication(json: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = tool(f, transaction: transaction(f))
        let before = await Snapshot(f)
        let result = try await tool.execute(call("bad", json), context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(result.isError)
        let after = await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: ["peer", "foreign-account", "disabled", "ambiguous"])
    func resolvesOwnedUniqueRouteBeforeReadingAnySource(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var connection = f.connection
        if mode == "peer" { connection.agentID = channelTestID(9) }
        if mode == "foreign-account" { connection.ownerAccountID = "other" }
        if mode == "disabled" { connection.enabled = false }
        try await f.channels.saveConnection(connection)
        if mode == "ambiguous" {
            try await f.channels.saveConnection(.init(id: channelTestID(9), connectorID: "slack", displayName: "Second",
                secretReference: "keychain://channels/TEST-second", agentID: agent, ownerAccountID: "local"))
        }
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data([1]), filename: "a.dat"), mimeType: "application/octet-stream")
        let tx = transaction(f, prepare: { _, _, _, _ in await f.probe.record("read"); return prepared }, install: { $0.metadata })
        let before = await Snapshot(f)
        let result = try await tool(f, transaction: tx).execute(call("send", #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a"}"#), context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(result.isError)
        let after = await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test func firstImageContractKeepsCaptionAndDisclosesOmissions() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: png, filename: "first.png"), mimeType: "image/png")
        let tx = transaction(f, prepare: { input, image, _, _ in
            expectNoDifference(input.source, .remote(try .init(url: "https://example.test/first", alt: "First")))
            expectNoDifference(image, true)
            await f.probe.record("capture first only")
            return prepared
        }, install: { $0.metadata }, remote: true)
        let tool = tool(f, transaction: tx)
        let request = try call("images", #"{"type":"text","content":"Caption","channel":"slack:C_SAFE","images":[{"url":"https://example.test/first","alt":"First"},{"url":"file:///unused.png","alt":"Not sent"}]}"#)
        let result = try await tool.execute(request, context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(!result.isError)
        let reviews = await f.probe.reviews, deliveries = await f.channels.deliveries()
        expectNoDifference(reviews.first?.message.discardedImageCount, 1)
        expectNoDifference(reviews.first?.attachment, prepared)
        expectNoDifference(deliveries.map(\.outbound), [.init(text: "Caption", attachments: [prepared.metadata])])
        let context = try await tool.runtimeContext(for: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(context.contains("Only the first image is sent"))
    }

    @Test(arguments: [ChannelDeliveryOrigin.Route.directConversation, .groupConversation], ["text", "attachment", "gallery"])
    func hostSourceRetainsExactParsedIntentWithoutNewSourceReadsOrLocalReceipts(route: ChannelDeliveryOrigin.Route, kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: png, filename: "captured.png"), mimeType: "image/png")
        let author = route == .directConversation ? origin : agent
        let tx = transaction(f, prepare: { input, isImage, _, _ in
            expectNoDifference(input.source, .remote(try .init(url: "https://example.test/first?signature=a%2Bb", alt: "First")))
            expectNoDifference(isImage, kind == "gallery")
            await f.probe.record("capture first only")
            return prepared
        }, install: { $0.metadata }, author: author,
            transcriptSource: .init(route: route, senderName: "真實成員"), remote: true)
        let inputs: [[String: String]] = kind == "text" ? [] : [
            ["url": "https://example.test/first?signature=a%2Bb", "alt": "First"]
        ] + (kind == "gallery" ? [["url": "file:///not-read.png", "alt": "Not sent"],
                                 ["url": "https://example.test/not-downloaded", "alt": "Also not sent"]] : [])
        var object: [String: Any] = ["type": kind == "attachment" ? "attachment" : "text", "channel": "slack:C_SAFE"]
        if kind == "attachment" { object["url"] = inputs[0]["url"]; object["alt"] = "First" }
        else { object["content"] = "Caption"; object["images"] = inputs }
        let call = try NormalizedToolCall(id: "origin-proof", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: object))
        let message = try AgentChannelMessage.parse(object), context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let receipt = try await tx.publish(message, replyTo: channelTestID(9), call: call, context: context)
        let expected = ChannelDeliveryOrigin(route: route, conversationID: origin, senderID: author, senderName: "真實成員",
            runID: context.runID, callID: call.id.rawValue, replyToMessageID: channelTestID(9),
            intent: .init(kind: kind == "attachment" ? .attachment : .text, text: kind == "attachment" ? "First" : "Caption",
                sources: inputs.map { .init(url: $0["url"]!, alt: $0["alt"]) }))
        expectNoDifference(receipt.delivery.origin, expected)
        expectNoDifference(receipt.delivery.address, .init(platform: "slack", channelID: "C_SAFE"))
        expectNoDifference(receipt.delivery.outbound, .init(text: expected.intent.text, attachments: kind == "text" ? [] : [prepared.metadata]))
        let reopened = try ChannelService(storeURL: f.root.appending(path: "channels.json"))
        let restored = await reopened.delivery(id: receipt.delivery.id)
        expectNoDifference(restored, receipt.delivery)
        tx.close()
        let replay = try await tx.publish(message, replyTo: channelTestID(9), call: call, context: context)
        expectNoDifference(replay, receipt)
        let events = await f.probe.events, sends = await f.probe.sends
        expectNoDifference(events, kind == "text" ? ["review"] : ["capture first only", "review"])
        expectNoDifference(sends, [])
    }

    @Test(arguments: ["text-only", "no-install", "https-without-grant", "corrupt-image", "wrong-installed-bytes", "deny"])
    func absentSourceGrantInvalidBytesOrRejectionNeverQueues(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data([1]), filename: "a.dat"), mimeType: "application/octet-stream")
        let prepare: AgentChannelPublicationTransaction.Prepare? = mode == "text-only" ? nil : { @Sendable _, _, _, _ in await f.probe.record("read"); return prepared }
        let install: AgentChannelPublicationTransaction.Install? = mode == "no-install" ? nil : { @Sendable value in
            await f.probe.record("install")
            return mode == "wrong-installed-bytes" ? .init(blobID: String(repeating: "a", count: 64), filename: value.file.filename, mimeType: value.mimeType, byteCount: value.metadata.byteCount) : value.metadata
        }
        let tx = transaction(f, prepare: prepare, install: install, authorize: { review, _, _ in
            await f.probe.review(review)
            if mode == "deny" { throw AgentMessagingError.approvalRequired }
        })
        let json = mode == "https-without-grant" ? #"{"type":"attachment","channel":"slack:C_SAFE","url":"https://example.test/file"}"#
            : mode == "corrupt-image" ? #"{"type":"text","content":"Caption","channel":"slack:C_SAFE","images":[{"url":"file:///a.dat"}]}"#
            : #"{"type":"attachment","channel":"slack:C_SAFE","url":"file:///a.dat"}"#
        let result = try await tool(f, transaction: tx).execute(call("send", json), context: .init(conversationID: origin, runID: channelTestID(5)))
        #expect(result.isError)
        let deliveries = await f.channels.deliveries(), sends = await f.probe.sends
        expectNoDifference(deliveries, []); expectNoDifference(sends, [])
        let events = await f.probe.events
        expectNoDifference(events, ["text-only", "no-install", "https-without-grant"].contains(mode) ? []
            : mode == "corrupt-image" ? ["read"] : mode == "deny" ? ["read", "review"] : ["read", "review", "install"])
    }

    @Test func channelAndLocalPublicationsShareBudgetAndCallIdentity() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = tool(f, transaction: transaction(f))
        let context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let external = try call("external", #"{"type":"text","content":"First","channel":"slack:C_SAFE"}"#)
        #expect(!(try await tool.execute(external, context: context)).isError)
        #expect(try await tool.execute(call("external", #"{"text":"Cannot repurpose"}"#), context: context).isError)
        #expect(try await tool.execute(call("external", #"{"type":"widget","widget":{"prompt":"Cannot repurpose?","options":[{"label":"Yes"}]}}"#), context: context).isError)
        #expect(try await tool.execute(call("external", #"{"type":"text","content":"Changed","channel":"slack:C_SAFE"}"#), context: context).isError)
        #expect(!(try await tool.execute(call("local", #"{"text":"Second"}"#), context: context)).isError)
        #expect(try await tool.execute(call("local", #"{"type":"text","content":"Cannot repurpose","channel":"slack:C_SAFE"}"#), context: context).isError)
        #expect(try await tool.execute(call("third", #"{"type":"text","content":"Third","channel":"slack:C_SAFE"}"#), context: context).isError)
        #expect(!(try await tool.execute(external, context: context)).isError)
        let events = await f.probe.events, deliveries = await f.channels.deliveries()
        expectNoDifference(events, ["review", "local publication"])
        #expect(deliveries.count == 1)
    }

    @Test(arguments: ["close", "parent-close", "connection", "connector"])
    func revocationDuringApprovalCannotCommit(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let parent = ChannelPublicationLifetime(), lifetime = ChannelPublicationLifetime(parent: parent)
        let tx = transaction(f, authorize: { review, _, _ in
            await f.probe.review(review)
            if mode == "close" { lifetime.close() }
            if mode == "parent-close" { parent.close() }
            if mode == "connection" { try await f.channels.setConnectionEnabled(id: f.connection.id, enabled: false) }
            if mode == "connector" { await f.channels.register(MessageTestConnector(probe: f.probe)) }
        }, lifetime: lifetime)
        let request = try call("send", #"{"type":"text","content":"Reviewed","channel":"slack:C_SAFE"}"#)
        if mode.contains("close") {
            await #expect(throws: CancellationError.self) { _ = try await tool(f, transaction: tx).execute(request, context: .init(conversationID: origin, runID: channelTestID(5))) }
        } else {
            #expect(try await tool(f, transaction: tx).execute(request, context: .init(conversationID: origin, runID: channelTestID(5))).isError)
        }
        let deliveries = await f.channels.deliveries(), sends = await f.probe.sends
        expectNoDifference(deliveries, []); expectNoDifference(sends, [])
    }

    @Test func closingAChildDoesNotCloseSiblingsButParentRevokesAll() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let parent = ChannelPublicationLifetime()
        let first = transaction(f, lifetime: .init(parent: parent), makeID: { channelTestID(201) })
        let second = transaction(f, lifetime: .init(parent: parent), makeID: { channelTestID(202) })
        let third = transaction(f, lifetime: .init(parent: parent), makeID: { channelTestID(203) })
        let call = try call("send", #"{"type":"text","content":"Reviewed","channel":"slack:C_SAFE"}"#)
        let message = try AgentChannelMessage.parse(["type": "text", "content": "Reviewed", "channel": "slack:C_SAFE"])
        let context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let receipt = try await first.publish(message, replyTo: nil, call: call, context: context)
        first.close()
        let replay = try await first.publish(message, replyTo: nil, call: call, context: context)
        expectNoDifference(replay, receipt)
        #expect(try await second.publish(message, replyTo: nil, call: call, context: context).delivery.status == .queued)
        parent.close()
        await #expect(throws: CancellationError.self) { _ = try await third.publish(message, replyTo: nil, call: call, context: context) }
        let deliveries = await f.channels.deliveries(), events = await f.probe.events
        #expect(deliveries.count == 2); expectNoDifference(events, ["review", "review"])
    }

    @Test func saveFailureDoesNotCreateAReceiptOrAutomaticallyRetry() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appending(path: "channels.json"), backup = f.root.appending(path: "before.json")
        let original = try Data(contentsOf: file)
        let tx = transaction(f, authorize: { review, _, _ in
            await f.probe.review(review)
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        })
        let tool = tool(f, transaction: tx), context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let request = try call("failed-save", #"{"type":"text","content":"Reviewed","channel":"slack:C_SAFE"}"#)
        let result = try await tool.execute(request, context: context)
        #expect(result.isError)
        #expect(!result.wireText.contains("durably queued"))
        let failed = await Snapshot(f)
        expectNoDifference(failed.deliveries, []); expectNoDifference(failed.failures, [])
        expectNoDifference(failed.events, ["review"]); expectNoDifference(failed.sends, [])
        // Only the exact isolated test path is restored. A repeated model call
        // still cannot quietly turn the failed attempt into another enqueue.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        #expect(try await tool.execute(request, context: context).isError)
        let afterReplay = await Snapshot(f), savedBytes = try Data(contentsOf: file)
        expectNoDifference(afterReplay, failed)
        expectNoDifference(savedBytes, original)
    }

    @Test func localQuotesAndQueueIDsNeverSelectAnExternalThreadOrNewLocalReplyTarget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prior = RoomMessage(id: channelTestID(9), groupID: origin, senderID: nil, text: "Local quoted context", createdAt: date)
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [prior], supportsQuestions: false,
            channelPublication: transaction(f), publishGroup: { _, _, _, _ in
                await f.probe.record("unexpected local publication"); return nil
            })
        let context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let request = try NormalizedToolCall(id: "quoted", name: "SendMessage", argumentsJSON: JSONEncoder().encode([
            "type": "text", "content": "External result", "channel": "slack:C_SAFE", "reply_to": prior.id.uuidString]))
        let result = try await tool.execute(request, context: context)
        #expect(!result.isError)
        let reviews = await f.probe.reviews, deliveries = await f.channels.deliveries()
        expectNoDifference(reviews.first?.replyTo, prior.id)
        expectNoDifference(deliveries.map(\.address), [.init(platform: "slack", channelID: "C_SAFE")])
        let queued = try #require(deliveries.first)
        let runtime = try await tool.runtimeContext(for: context)
        #expect(!runtime.contains(queued.id.uuidString))
        let forgedReply = try NormalizedToolCall(id: "forged", name: "SendMessage", argumentsJSON: JSONEncoder().encode([
            "type": "text", "content": "Must not become a local thread", "channel": "slack:C_SAFE", "reply_to": queued.id.uuidString]))
        let before = await Snapshot(f)
        #expect(try await tool.execute(forgedReply, context: context).isError)
        let after = await Snapshot(f)
        expectNoDifference(after, before)
    }

    @Test(arguments: ["source", "installation"])
    func revocationDuringSourceOrInstallationNeverReachesQueue(stage: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let lifetime = ChannelPublicationLifetime()
        let prepared = try PreparedAgentChannelAttachment(file: .init(bytes: Data([1]), filename: "reviewed.dat"), mimeType: "application/octet-stream")
        let tx = transaction(f, prepare: { _, _, _, _ in
            await f.probe.record("source")
            if stage == "source" { lifetime.close() }
            return prepared
        }, install: { value in
            await f.probe.record("installation")
            lifetime.close()
            return value.metadata
        }, lifetime: lifetime)
        let tool = tool(f, transaction: tx), request = try call("send", #"{"type":"attachment","url":"file:///reviewed.dat","channel":"slack:C_SAFE"}"#)
        await #expect(throws: CancellationError.self) {
            _ = try await tool.execute(request, context: .init(conversationID: origin, runID: channelTestID(5)))
        }
        let state = await Snapshot(f)
        expectNoDifference(state.events, stage == "source" ? ["source"] : ["source", "review", "installation"])
        expectNoDifference(state.deliveries, []); expectNoDifference(state.sends, [])
    }

    @Test func duplicatePayloadIsDestinationSpecificAndReusedDeliveryIDCannotQueueAgain() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tx = transaction(f, makeID: { channelTestID(201) }), tool = tool(f, transaction: tx)
        let context = ToolContext(conversationID: origin, runID: channelTestID(5))
        let first = try call("first", #"{"type":"text","content":"Reviewed","channel":"slack:C_SAFE"}"#)
        let receipt = try await tool.execute(first, context: context)
        #expect(!receipt.isError)
        let before = await Snapshot(f)
        #expect(try await tool.execute(call("duplicate", #"{"type":"text","content":"Reviewed","channel":"slack:C_SAFE"}"#), context: context).isError)
        let afterDuplicate = await Snapshot(f)
        expectNoDifference(afterDuplicate, before)
        // Different address needs a new review, but a broken host ID generator
        // must not confirm that different payload using the first queue row.
        #expect(try await tool.execute(call("other", #"{"type":"text","content":"Reviewed","channel":"slack:C_OTHER"}"#), context: context).isError)
        let afterCollision = await Snapshot(f)
        expectNoDifference(afterCollision.deliveries, before.deliveries)
        expectNoDifference(afterCollision.sends, before.sends)
        expectNoDifference(afterCollision.reviews.map(\.publication.address.channelID), ["C_SAFE", "C_OTHER"])
    }
}
