import Foundation
import Testing
import CustomDump
@testable import FiliconChannels

private func failureID(_ value: Int) -> UUID {
    UUID(uuidString: "39000000-0000-0000-0000-" + String(format: "%012x", value))!
}
private actor FailureSendProbe {
    var sends: [ChannelOutbound] = []
    func send(_ value: ChannelOutbound) throws {
        sends.append(value); throw ChannelServiceError.authExpired("PRIVATE_RAW_TOKEN")
    }
}
private struct FailureFixtureConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline failure")
    let probe: FailureSendProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection,
              idempotencyKey: UUID) async throws { try await probe.send(message) }
}

@Suite("Durable original channel failure follow-ups", .timeLimit(.minutes(1)))
struct ChannelFailureFollowUpTests {
    private let date = Date(timeIntervalSince1970: 2_000)
    private let agentID = failureID(1), chatID = failureID(2)
    private struct Fixture {
        let root: URL
        let service: ChannelService
        let probe: FailureSendProbe
        let queued: ChannelDelivery
        var file: URL { root.appending(path: "channels.json") }
    }
    private struct State: Equatable {
        var connections: [ChannelConnection]
        var deliveries: [ChannelDelivery]
        var wakes: [ChannelFailureWake]
        var followUps: [ChannelFailureFollowUp]
        var sends: [ChannelOutbound]
        init(_ f: Fixture) async {
            connections = await f.service.connections(); deliveries = await f.service.deliveries()
            wakes = await f.service.failureWakes(); followUps = await f.service.failureFollowUps()
            sends = await f.probe.sends
        }
    }
    private func fixture(route: ChannelDeliveryOrigin.Route? = .directConversation, terminal: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-failure-\(UUID())")
        let service = try ChannelService(storeURL: root.appending(path: "channels.json"), newDeliveryID: { failureID(3) })
        let connection = ChannelConnection(id: failureID(4), connectorID: "slack", displayName: "Owned",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: agentID, ownerAccountID: "local")
        try await service.saveConnection(connection)
        let probe = FailureSendProbe(); await service.register(FailureFixtureConnector(probe: probe))
        let publication = try await service.proposePublication(agentID: agentID, accountID: "local",
            outbound: .init(text: "Reviewed send"), to: .init(platform: "slack", channelID: "C_ORIGINAL"))
        let origin = route.map { ChannelDeliveryOrigin(route: $0, conversationID: chatID,
            senderID: $0 == .directConversation ? chatID : agentID, senderName: "Owner", runID: failureID(5),
            callID: "actual-send", intent: .init(kind: .text, text: publication.outbound.text)) }
        let queued: ChannelDelivery
        if route != nil {
            queued = try await service.enqueueApprovedPublication(publication, lifetime: .init(),
                idempotencyKey: failureID(6), at: date, origin: origin)
        } else {
            queued = try await service.enqueue(publication.outbound, to: publication.address,
                connectionID: connection.id, idempotencyKey: failureID(6), at: date)
        }
        if terminal { await service.flush(now: date) }
        return .init(root: root, service: service, probe: probe, queued: queued)
    }
    private func claim(_ f: Fixture, at: Date? = nil) async throws -> ChannelFailureFollowUp? {
        let wake = try #require(await f.service.failureWakes().first)
        return try await f.service.claimFailureFollowUp(wakeID: wake.id, accountID: "local", agentID: agentID,
            conversationID: chatID, at: at ?? date)
    }

    @Test func claimIsDurableExactlyOnceWithoutAnotherSend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let wake = try #require(await f.service.failureWakes().first)
        expectNoDifference(wake.reason, .authorizationExpired)
        let authorization = try #require(f.queued.authorization), origin = try #require(f.queued.origin)
        let expected = ChannelFailureFollowUp(wake: wake, authorization: authorization, origin: origin, at: date)
        var state = await State(f)
        await expectDifference(state) {
            let actual = try await claim(f); expectNoDifference(actual, expected)
            state = await State(f)
        } changes: { $0.followUps.append(expected) }
        #expect(await f.service.isFailureFollowUpCurrent(expected))
        let bytes = try Data(contentsOf: f.file)
        let duplicate = try await claim(f), afterDuplicate = await State(f)
        expectNoDifference(duplicate, nil)
        expectNoDifference(afterDuplicate, state); expectNoDifference(try Data(contentsOf: f.file), bytes)
        await f.service.flush(now: date.addingTimeInterval(100))
        let afterFlush = await State(f); expectNoDifference(afterFlush, state)
    }

    @Test(arguments: [ChannelFailureFollowUp.Status.completed, .failed, .cancelled])
    func terminalFollowUpCannotBeReplayedOrRelabelled(status: ChannelFailureFollowUp.Status) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try #require(try await claim(f)), finish = date.addingTimeInterval(3)
        var state = await State(f)
        await expectDifference(state) {
            try await f.service.finishFailureFollowUp(record, status: status, at: finish)
            state = await State(f)
        } changes: { $0.followUps[0].status = status; $0.followUps[0].finishedAt = finish }
        #expect(await f.service.isFailureFollowUpCurrent(record) == false)
        try await f.service.finishFailureFollowUp(record, status: .completed, at: finish.addingTimeInterval(1))
        let afterReplay = await State(f); expectNoDifference(afterReplay, state)
        let restored = try ChannelService(storeURL: f.file, now: { finish })
        let restoredRecords = await restored.failureFollowUps(); expectNoDifference(restoredRecords, state.followUps)
        let next = try await restored.claimFailureFollowUp(wakeID: record.id, accountID: "local",
            agentID: agentID, conversationID: chatID, at: finish)
        expectNoDifference(next, nil)
    }

    @Test func restoredRunningWakeBecomesInterruptedWithoutSilentReplay() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try #require(try await claim(f)), finish = date.addingTimeInterval(7)
        var expected = record; expected.status = .interrupted; expected.finishedAt = finish
        let restored = try ChannelService(storeURL: f.file, now: { finish })
        let restoredRecords = await restored.failureFollowUps(); expectNoDifference(restoredRecords, [expected])
        #expect(await restored.isFailureFollowUpCurrent(record) == false)
        let duplicate = try await restored.claimFailureFollowUp(wakeID: record.id, accountID: "local",
            agentID: agentID, conversationID: chatID, at: finish)
        let restoredDeliveries = await restored.deliveries(), originalDeliveries = await f.service.deliveries()
        let restoredWakes = await restored.failureWakes(), originalWakes = await f.service.failureWakes()
        let sends = await f.probe.sends
        expectNoDifference(duplicate, nil)
        expectNoDifference(restoredDeliveries, originalDeliveries); expectNoDifference(restoredWakes, originalWakes)
        expectNoDifference(sends, [f.queued.outbound])
    }

    @Test func humanAcknowledgmentRetiresOnlyItsOriginalRunningWake() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try #require(try await claim(f)), finish = date.addingTimeInterval(1)
        var state = await State(f)
        await expectDifference(state) {
            try await f.service.acknowledgeFailureWake(id: record.id, at: finish); state = await State(f)
        } changes: {
            $0.wakes.removeAll(); $0.followUps[0].status = .cancelled; $0.followUps[0].finishedAt = finish
        }
        try await f.service.finishFailureFollowUp(record, status: .completed, at: finish)
        let afterFinish = await State(f); expectNoDifference(afterFinish, state)
        let restored = try ChannelService(storeURL: f.file, now: { finish })
        let restoredRecords = await restored.failureFollowUps(); expectNoDifference(restoredRecords, state.followUps)
    }

    @Test(arguments: ["account", "agent", "conversation", "unknown", "revoked", "save-failure"])
    func refusedAdmissionLeavesNoRunOrNewSend(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let state = await State(f), wake = try #require(state.wakes.first), bytes = try Data(contentsOf: f.file)
        if mode == "save-failure" {
            try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        await #expect(throws: (any Error).self) {
            _ = try await f.service.claimFailureFollowUp(wakeID: mode == "unknown" ? failureID(99) : wake.id,
                accountID: mode == "account" ? "foreign" : "local", agentID: mode == "agent" ? failureID(99) : agentID,
                conversationID: mode == "conversation" ? failureID(99) : chatID, at: date,
                commit: { write in if mode == "revoked" { throw CancellationError() }; try write() })
        }
        let afterRefusal = await State(f); expectNoDifference(afterRefusal, state)
        if mode != "save-failure" { expectNoDifference(try Data(contentsOf: f.file), bytes) }
    }

    @Test(arguments: ["group", "legacy", "listener"])
    func nonDirectOrUnprovenOriginDoesNotAdmitModelWork(mode: String) async throws {
        let f = try await fixture(route: mode == "group" ? .groupConversation : nil)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let state = await State(f), wake = try #require(state.wakes.first)
        let id: UUID
        if mode == "listener" {
            var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
            let fake = ChannelFailureWake(id: failureID(90), connectionID: wake.connectionID,
                deliveryID: failureID(91), error: "Listener transport", createdAt: date)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            json["failureWakes"] = [try JSONSerialization.jsonObject(with: encoder.encode(fake))]
            try JSONSerialization.data(withJSONObject: json).write(to: f.file)
            id = fake.id
        } else { id = wake.id }
        let restored = try ChannelService(storeURL: f.file)
        await #expect(throws: ChannelServiceError.invalidEnvelope) {
            _ = try await restored.claimFailureFollowUp(wakeID: id, accountID: "local", agentID: agentID,
                conversationID: chatID, at: date)
        }
        let restoredRecords = await restored.failureFollowUps(), sends = await f.probe.sends
        expectNoDifference(restoredRecords, []); expectNoDifference(sends, state.sends)
    }

    @Test(arguments: ["id", "account", "agent", "conversation", "delivery", "connection", "duplicate", "finished-running", "missing-wake", "before-start"])
    func corruptFollowUpIsRejectedBeforeRewritingTheStore(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await claim(f)
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        var records = try #require(json["failureFollowUps"] as? [[String: Any]])
        switch mode {
        case "id": records[0]["id"] = failureID(99).uuidString
        case "account": records[0]["accountID"] = "foreign"
        case "agent": records[0]["agentID"] = failureID(99).uuidString
        case "conversation": records[0]["conversationID"] = failureID(99).uuidString
        case "delivery": records[0]["deliveryID"] = failureID(99).uuidString
        case "connection": records[0]["connectionID"] = failureID(99).uuidString
        case "duplicate": records.append(records[0])
        case "finished-running": records[0]["finishedAt"] = 2_001_000
        case "missing-wake": json["failureWakes"] = []
        case "before-start": records[0]["status"] = "completed"; records[0]["finishedAt"] = 1_999_000
        default: break
        }
        json["failureFollowUps"] = records
        let corrupt = try JSONSerialization.data(withJSONObject: json); try corrupt.write(to: f.file)
        #expect(throws: ChannelServiceError.invalidEnvelope) { _ = try ChannelService(storeURL: f.file) }
        expectNoDifference(try Data(contentsOf: f.file), corrupt)
    }

    @Test(arguments: ["finish", "acknowledge"])
    func failedTerminalWriteRollsBackTheEntireClaimAndWake(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try #require(try await claim(f)), before = await State(f)
        let backup = f.root.appending(path: "before-terminal-write.json")
        let bytes = try Data(contentsOf: f.file)
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            if mode == "finish" {
                try await f.service.finishFailureFollowUp(record, status: .completed, at: date)
            } else { try await f.service.acknowledgeFailureWake(id: record.id, at: date) }
        }
        let afterFailure = await State(f); expectNoDifference(afterFailure, before)
        expectNoDifference(try Data(contentsOf: backup), bytes)
        #expect(await f.service.isFailureFollowUpCurrent(record))
        let restored = try ChannelService(storeURL: backup, now: { Date(timeIntervalSince1970: 2_001) })
        let restoredRecords = await restored.failureFollowUps()
        var interrupted = record; interrupted.status = .interrupted
        interrupted.finishedAt = date.addingTimeInterval(1)
        expectNoDifference(restoredRecords, [interrupted])
    }

    @Test(arguments: ["claim", "finish", "acknowledge", "restore"])
    func nonfiniteClockCannotCreateOrRewriteFollowUpState(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record: ChannelFailureFollowUp?
        if mode == "claim" { record = nil } else { record = try #require(try await claim(f)) }
        let before = await State(f), bytes = try Data(contentsOf: f.file)
        for seconds in [Double.nan, .infinity, -.infinity] {
            let invalid = Date(timeIntervalSince1970: seconds)
            switch mode {
            case "claim":
                await #expect(throws: ChannelServiceError.invalidEnvelope) { _ = try await claim(f, at: invalid) }
            case "finish":
                try await f.service.finishFailureFollowUp(try #require(record), status: .completed, at: invalid)
            case "acknowledge":
                await #expect(throws: ChannelServiceError.invalidEnvelope) {
                    try await f.service.acknowledgeFailureWake(id: try #require(record).id, at: invalid)
                }
            default:
                #expect(throws: ChannelServiceError.invalidEnvelope) { _ = try ChannelService(storeURL: f.file, now: { invalid }) }
            }
            let afterInvalidClock = await State(f); expectNoDifference(afterInvalidClock, before)
            expectNoDifference(try Data(contentsOf: f.file), bytes)
        }
    }

    @Test func removingConnectionRemovesItsBookkeepingAndClockCannotReverseCompletion() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let record = try #require(try await claim(f))
        try await f.service.finishFailureFollowUp(record, status: .completed, at: date.addingTimeInterval(-10))
        let finished = await f.service.failureFollowUps().first?.finishedAt
        expectNoDifference(finished, date)
        var state = await State(f)
        await expectDifference(state) {
            _ = try await f.service.removeConnection(id: f.queued.connectionID); state = await State(f)
        } changes: { $0.connections.removeAll(); $0.deliveries.removeAll(); $0.wakes.removeAll(); $0.followUps.removeAll() }
        let restored = try ChannelService(storeURL: f.file)
        let restoredRecords = await restored.failureFollowUps(); expectNoDifference(restoredRecords, [])
    }
}
