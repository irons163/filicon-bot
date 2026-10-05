import Foundation
import Testing
import CustomDump
@testable import FiliconChannels

private func originID(_ value: Int) -> UUID {
    UUID(uuidString: "36000000-0000-0000-0000-" + String(format: "%012x", value))!
}
private actor OriginTransportProbe {
    struct Send: Equatable {
        let outbound: ChannelOutbound
        let address: ChannelAddress
        let key: UUID
    }
    var sends: [Send] = []
    var fails = false
    func failNext() { fails = true }
    func send(_ outbound: ChannelOutbound, address: ChannelAddress, key: UUID) throws {
        sends.append(.init(outbound: outbound, address: address, key: key))
        if fails { fails = false; throw URLError(.timedOut) }
    }
}
private struct OriginConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline origin fixture")
    let probe: OriginTransportProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        try await probe.send(message, address: address, key: idempotencyKey)
    }
}

@Suite("Durable channel publication provenance", .timeLimit(.minutes(1)))
struct ChannelDeliveryOriginTests {
    private let date = Date(timeIntervalSince1970: 2_000)
    private let agent = originID(1), conversation = originID(2), run = originID(3), key = originID(4), deliveryID = originID(5)
    private struct Fixture {
        let root: URL
        let channels: ChannelService
        let connection: ChannelConnection
        let probe: OriginTransportProbe
        var file: URL { root.appending(path: "channels.json") }
    }
    private struct Snapshot: Equatable {
        var connections: [ChannelConnection]
        var deliveries: [ChannelDelivery]
        var failures: [ChannelFailureWake]
        var sends: [OriginTransportProbe.Send]
        init(_ f: Fixture) async {
            connections = await f.channels.connections(); deliveries = await f.channels.deliveries()
            failures = await f.channels.failureWakes(); sends = await f.probe.sends
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-origin-\(UUID())")
        let deliveryID = self.deliveryID
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"), newDeliveryID: { deliveryID })
        let connection = ChannelConnection(id: originID(6), connectorID: "slack", displayName: "Own offline connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: agent, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        let probe = OriginTransportProbe()
        await channels.register(OriginConnector(probe: probe))
        return .init(root: root, channels: channels, connection: connection, probe: probe)
    }
    private func origin(route: ChannelDeliveryOrigin.Route = .groupConversation, senderID: UUID? = nil,
        conversationID: UUID? = nil, senderName: String = "工程師", runID: UUID? = nil,
        callID: String = "external-send", reply: UUID? = originID(7),
        intent: ChannelDeliveryOrigin.Intent = .init(kind: .text, text: "Reviewed caption")) -> ChannelDeliveryOrigin {
        .init(route: route, conversationID: conversationID ?? conversation,
            senderID: senderID ?? (route == .directConversation ? conversation : agent), senderName: senderName,
            runID: runID ?? run, callID: callID, replyToMessageID: reply, intent: intent)
    }
    private func proposal(_ f: Fixture, attachments: Bool = false) async throws -> ChannelPublication {
        try await f.channels.proposePublication(agentID: agent, accountID: "local",
            outbound: .init(text: "Reviewed caption", attachments: attachments ? [
                .init(blobID: String(repeating: "a", count: 64), filename: "captured.png", mimeType: "image/png", byteCount: 42)
            ] : []), to: .init(platform: "slack", channelID: "C_ORIGINAL"))
    }

    @Test(arguments: [ChannelDeliveryOrigin.Route.directConversation, .groupConversation], ["text", "attachment", "gallery"])
    func sourceAndQueueCommitInOneEnvelope(route: ChannelDeliveryOrigin.Route, kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sources: [ChannelDeliveryOrigin.Intent.Source] = kind == "text" ? [] : [
            .init(url: "HTTPS://example.invalid/first?signature=a%2Bb", alt: "First")
        ] + (kind == "gallery" ? [.init(url: "file:///not-read.png", alt: "Not sent"),
                                  .init(url: "https://example.invalid/third", alt: "Also not sent")] : [])
        let source = origin(route: route, intent: .init(kind: kind == "attachment" ? .attachment : .text,
            text: "Reviewed caption", sources: sources))
        let proposal = try await proposal(f, attachments: kind != "text"), lifetime = ChannelPublicationLifetime()
        let expected = ChannelDelivery(id: deliveryID, connectionID: f.connection.id, address: proposal.address,
            outbound: proposal.outbound, idempotencyKey: key, nextAttemptAt: date, createdAt: date,
            authorization: .init(ownerAccountID: "local", agentID: agent, configurationRevision: proposal.configurationRevision), origin: source)
        var state = await Snapshot(f)
        await expectDifference(state) {
            let saved = try await f.channels.enqueueApprovedPublication(proposal, lifetime: lifetime,
                idempotencyKey: key, at: date, origin: source)
            expectNoDifference(saved, expected)
            state = await Snapshot(f)
        } changes: { $0.deliveries.append(expected) }
        let reopened = try ChannelService(storeURL: f.file)
        let restored = await reopened.delivery(id: deliveryID)
        expectNoDifference(restored, expected)
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), expected)
        // This is neither a local transcript receipt nor a remote send.
        expectNoDifference(state.sends, [])
    }

    @Test(arguments: ["route", "conversation", "sender", "name", "run", "call", "reply", "intent", "missing"])
    func cachedAndRestoredIdempotencyCannotRelabelAQueuedMessage(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let proposal = try await proposal(f), lifetime = ChannelPublicationLifetime(), source = origin()
        let saved = try await f.channels.enqueueApprovedPublication(proposal, lifetime: lifetime, idempotencyKey: key, at: date, origin: source)
        let changed: ChannelDeliveryOrigin? = change == "missing" ? nil : origin(
            route: change == "route" || change == "sender" ? .directConversation : .groupConversation,
            conversationID: change == "conversation" ? originID(8) : nil,
            senderName: change == "name" ? "Other name" : "工程師", runID: change == "run" ? originID(8) : nil,
            callID: change == "call" ? "other-call" : "external-send", reply: change == "reply" ? nil : originID(7),
            intent: .init(kind: .text, text: change == "intent" ? "Different" : "Reviewed caption"))
        let before = await Snapshot(f), bytes = try Data(contentsOf: f.file)
        for fence in [lifetime, ChannelPublicationLifetime()] {
            await #expect(throws: (any Error).self) {
                _ = try await f.channels.enqueueApprovedPublication(proposal, lifetime: fence, idempotencyKey: key, at: date, origin: changed)
            }
        }
        let reopened = try ChannelService(storeURL: f.file)
        await reopened.register(OriginConnector(probe: f.probe))
        let newProposal = try await reopened.proposePublication(agentID: agent, accountID: "local", outbound: proposal.outbound, to: proposal.address)
        await #expect(throws: (any Error).self) {
            _ = try await reopened.enqueueApprovedPublication(newProposal, lifetime: .init(), idempotencyKey: key, at: date, origin: changed)
        }
        let after = await Snapshot(f), afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(after, before); expectNoDifference(afterBytes, bytes)
        let exactReplay = try await f.channels.enqueueApprovedPublication(proposal, lifetime: lifetime, idempotencyKey: key, at: date, origin: source)
        expectNoDifference(exactReplay, saved)
    }

    @Test(arguments: ["group-author", "direct-author", "empty-name", "control-name", "large-name", "empty-call", "control-call", "large-call", "text", "source-count", "source-size", "source-total", "source-scheme", "source-control", "alt", "attachment-count"])
    func inconsistentOrUnboundedSourceCannotBeSaved(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sourceURLs: [ChannelDeliveryOrigin.Intent.Source]
        switch change {
        case "source-size": sourceURLs = [.init(url: "https://example.invalid/" + String(repeating: "a", count: 16_384))]
        case "source-total": sourceURLs = Array(repeating: .init(url: "https://example.invalid/" + String(repeating: "a", count: 16_000)), count: 5)
        case "source-scheme": sourceURLs = [.init(url: "http://example.invalid/private")]
        case "source-control": sourceURLs = [.init(url: "https://example.invalid/\nprivate")]
        case "alt": sourceURLs = [.init(url: "https://example.invalid/file", alt: "\nPrivate")]
        case "source-count": sourceURLs = Array(repeating: .init(url: "https://example.invalid/file"), count: 65)
        default: sourceURLs = []
        }
        let proposal = try await proposal(f, attachments: !sourceURLs.isEmpty)
        let source = origin(route: change == "direct-author" ? .directConversation : .groupConversation,
            senderID: ["group-author", "direct-author"].contains(change) ? originID(8) : nil,
            senderName: change == "empty-name" ? " " : change == "control-name" ? "Name\nInjected" : change == "large-name" ? String(repeating: "a", count: 8_001) : "工程師",
            callID: change == "empty-call" ? "" : change == "control-call" ? "call\nID" : change == "large-call" ? String(repeating: "a", count: 2_049) : "external-send",
            intent: .init(kind: change == "attachment-count" ? .attachment : .text,
                text: change == "text" ? "Different caption" : "Reviewed caption", sources: sourceURLs))
        let before = await Snapshot(f), bytes = try Data(contentsOf: f.file), lifetime = ChannelPublicationLifetime()
        await #expect(throws: ChannelPublicationError.invalid) {
            _ = try await f.channels.enqueueApprovedPublication(proposal, lifetime: lifetime, idempotencyKey: key, at: date, origin: source)
        }
        let after = await Snapshot(f), afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(after, before); expectNoDifference(afterBytes, bytes)
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), nil)
    }

    @Test(arguments: ["closed", "cancelled", "save-failure"])
    func refusedOrFailedQueueWriteCannotLeaveOrphanProvenance(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let proposal = try await proposal(f), source = origin(), lifetime = ChannelPublicationLifetime()
        let before = await Snapshot(f), bytes = try Data(contentsOf: f.file), backup = f.root.appending(path: "backup.json")
        if mode == "closed" { lifetime.close() }
        if mode == "save-failure" {
            try FileManager.default.moveItem(at: f.file, to: backup)
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        let attempt = Task { () throws -> ChannelDelivery in
            if mode == "cancelled" { withUnsafeCurrentTask { $0?.cancel() } }
            return try await f.channels.enqueueApprovedPublication(proposal, lifetime: lifetime, idempotencyKey: key, at: date, origin: source)
        }
        await #expect(throws: (any Error).self) { _ = try await attempt.value }
        let after = await Snapshot(f)
        expectNoDifference(after, before); expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), nil)
        if mode == "save-failure" {
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.moveItem(at: backup, to: f.file)
        }
        let afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(afterBytes, bytes)
        let reopened = try ChannelService(storeURL: f.file), deliveries = await reopened.deliveries()
        expectNoDifference(deliveries, [])
    }

    @Test func restartRetryAndTerminalFailureRetainTheOriginalSourceOnly() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let proposal = try await proposal(f), source = origin(), lifetime = ChannelPublicationLifetime()
        let queued = try await f.channels.enqueueApprovedPublication(proposal, lifetime: lifetime, idempotencyKey: key, at: date, origin: source)
        lifetime.close()
        await f.probe.failNext(); await f.channels.flush(now: date)
        let reopened = try ChannelService(storeURL: f.file)
        await reopened.register(OriginConnector(probe: f.probe))
        for time in [date.addingTimeInterval(10), date.addingTimeInterval(20)] {
            await f.probe.failNext(); await reopened.flush(now: time)
        }
        var expected = queued
        expected.status = .deadLetter; expected.attemptCount = 3
        expected.nextAttemptAt = date.addingTimeInterval(12)
        expected.lastError = URLError(.timedOut).localizedDescription
        let terminal = try #require(await reopened.delivery(id: queued.id))
        expectNoDifference(terminal, expected)
        let failures = await reopened.failureWakes(), sends = await f.probe.sends
        expectNoDifference(failures.map(\.deliveryID), [queued.id])
        expectNoDifference(sends, Array(repeating: .init(outbound: proposal.outbound, address: proposal.address, key: key), count: 3))
        let final = try ChannelService(storeURL: f.file), restored = await final.delivery(id: queued.id)
        expectNoDifference(restored, terminal)
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), queued)
    }

    @Test(arguments: ["sender", "caption", "no-authorization", "kind"])
    func corruptedRestoredProvenanceFailsBeforeRewritingTheEnvelope(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let proposal = try await proposal(f)
        _ = try await f.channels.enqueueApprovedPublication(proposal, lifetime: .init(), idempotencyKey: key, at: date, origin: origin())
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        var deliveries = try #require(object["deliveries"] as? [[String: Any]])
        var source = try #require(deliveries[0]["origin"] as? [String: Any])
        if change == "sender" { source["senderID"] = originID(8).uuidString }
        if change == "no-authorization" { deliveries[0].removeValue(forKey: "authorization") }
        if change == "caption" || change == "kind" {
            var intent = try #require(source["intent"] as? [String: Any])
            intent[change == "caption" ? "text" : "kind"] = change == "caption" ? "Different" : "unsupported"
            source["intent"] = intent
        }
        deliveries[0]["origin"] = source; object["deliveries"] = deliveries
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try bytes.write(to: f.file, options: .atomic)
        #expect(throws: (any Error).self) { _ = try ChannelService(storeURL: f.file) }
        let after = try Data(contentsOf: f.file), sends = await f.probe.sends
        expectNoDifference(after, bytes); expectNoDifference(sends, [])
    }

    @Test(arguments: [false, true])
    func legacyHumanAndLegacyScopedRowsDoNotAcquireAConversationSource(human: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let proposal = try await proposal(f)
        let saved: ChannelDelivery
        if human {
            saved = try await f.channels.enqueue(proposal.outbound, to: proposal.address, connectionID: f.connection.id,
                idempotencyKey: key, at: date)
        } else {
            saved = try await f.channels.enqueueApprovedPublication(proposal, lifetime: .init(), idempotencyKey: key, at: date)
        }
        expectNoDifference(saved.origin, nil)
        let restored = try ChannelService(storeURL: f.file), legacy = await restored.delivery(id: saved.id)
        expectNoDifference(legacy, saved)
        await restored.register(OriginConnector(probe: f.probe))
        let source = origin(), newProposal = try await restored.proposePublication(agentID: agent, accountID: "local", outbound: proposal.outbound, to: proposal.address)
        let before = try Data(contentsOf: f.file)
        await #expect(throws: ChannelPublicationError.idempotencyConflict) {
            _ = try await restored.enqueueApprovedPublication(newProposal, lifetime: .init(), idempotencyKey: key, at: date, origin: source)
        }
        let unchanged = await restored.delivery(id: saved.id), after = try Data(contentsOf: f.file)
        expectNoDifference(unchanged, saved); expectNoDifference(after, before)
    }
}
