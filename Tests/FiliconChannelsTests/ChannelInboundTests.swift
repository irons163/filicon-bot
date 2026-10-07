import Foundation
import Testing
import CustomDump
@testable import FiliconChannels

private func inboundID(_ n: Int) -> UUID { UUID(uuidString: String(format: "43000000-0000-0000-0000-%012d", n))! }
private final class InboundInvalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}
private struct InboundOfflineConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline inbound fixture")
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> { .init { $0.finish() } }
    func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws {
        Issue.record("Inbound admission must never send a message")
    }
}

@Suite("Host-bound durable channel inbound admission", .timeLimit(.minutes(1)))
struct ChannelInboundTests {
    private let date = Date(timeIntervalSince1970: 2_000)
    private struct Fixture {
        let root: URL
        let service: ChannelService
        let connection: ChannelConnection
        let envelope: ChannelEnvelope
        var file: URL { root.appending(path: "channels.json") }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-inbound-admission-\(UUID())")
        let service = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let connection = ChannelConnection(id: inboundID(1), connectorID: "slack", displayName: "Original owner",
            secretReference: "keychain://channels/TEST-only-not-read", agentID: inboundID(2), ownerAccountID: "fixture")
        try await service.saveConnection(connection); await service.register(InboundOfflineConnector())
        let envelope = ChannelEnvelope(connectionID: connection.id, externalEventID: "exact-event",
            address: .init(platform: "slack", channelID: "C_EXACT", threadID: "T_EXACT"),
            senderID: "U_EXACT", senderDisplayName: "Remote human", text: "Remote untrusted request", timestamp: date)
        try #require(await service.ingest(envelope))
        return .init(root: root, service: service, connection: connection, envelope: envelope)
    }
    private func claim(_ f: Fixture, _ admission: ChannelInboundAdmission) async throws -> ChannelInboundRun {
        try await f.service.claimInbound(admission, conversationID: inboundID(3), runID: inboundID(4), messageID: inboundID(5), at: date)
    }
    private func anotherEnvelope(_ f: Fixture) -> ChannelEnvelope {
        .init(connectionID: f.connection.id, externalEventID: "another-event", address: f.envelope.address,
            senderID: f.envelope.senderID, senderDisplayName: f.envelope.senderDisplayName,
            text: "Another remote request", timestamp: date.addingTimeInterval(1))
    }
    @Test(arguments: [ChannelInboundRun.Status.completed, .cancelled, .failed, .interrupted])
    func cardSourceResolutionIsReadOnlyAndRequiresCompletedOwnReceipt(status: ChannelInboundRun.Status) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        let run = try await claim(f, admission)
        await #expect(throws: CancellationError.self) {
            try await f.service.inboundCardEnvelope(runID: run.id, messageID: run.messageID, conversationID: run.conversationID,
                accountID: "fixture", agentID: run.receipt.agentID)
        }
        try await f.service.finishInbound(run, status: status, at: date.addingTimeInterval(1))
        let records = await f.service.inboundRuns(), bytes = try Data(contentsOf: f.file)
        if status == .completed {
            let source = try await f.service.inboundCardEnvelope(runID: run.id, messageID: run.messageID, conversationID: run.conversationID,
                accountID: "fixture", agentID: run.receipt.agentID)
            expectNoDifference(source, f.envelope)
        } else {
            await #expect(throws: CancellationError.self) {
                try await f.service.inboundCardEnvelope(runID: run.id, messageID: run.messageID, conversationID: run.conversationID,
                    accountID: "fixture", agentID: run.receipt.agentID)
            }
        }
        for mutation in ["run", "message", "conversation", "account", "agent"] {
            await #expect(throws: CancellationError.self) {
                try await f.service.inboundCardEnvelope(runID: mutation == "run" ? inboundID(10) : run.id,
                    messageID: mutation == "message" ? inboundID(11) : run.messageID,
                    conversationID: mutation == "conversation" ? inboundID(12) : run.conversationID,
                    accountID: mutation == "account" ? "foreign" : "fixture",
                    agentID: mutation == "agent" ? inboundID(13) : run.receipt.agentID)
            }
        }
        let after = await f.service.inboundRuns(), deliveries = await f.service.deliveries()
        expectNoDifference(after, records); expectNoDifference(deliveries, []); expectNoDifference(try Data(contentsOf: f.file), bytes)
        let reopened = try ChannelService(storeURL: f.file); await reopened.register(InboundOfflineConnector())
        if status == .completed {
            let source = try await reopened.inboundCardEnvelope(runID: run.id, messageID: run.messageID, conversationID: run.conversationID,
                accountID: "fixture", agentID: run.receipt.agentID)
            expectNoDifference(source, f.envelope)
        }
        let loaded = await reopened.inboundRuns(); expectNoDifference(loaded, records)
        expectNoDifference(try Data(contentsOf: f.file), bytes)
    }
    @Test(arguments: ["disable-enable", "remove-recreate", "same-save"])
    func savedCardLocatorCannotFollowReplacementConfiguration(mutation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        let run = try await claim(f, admission)
        try await f.service.finishInbound(run, status: .completed, at: date.addingTimeInterval(1))
        if mutation == "disable-enable" {
            try await f.service.setConnectionEnabled(id: f.connection.id, enabled: false)
            try await f.service.setConnectionEnabled(id: f.connection.id, enabled: true)
        } else if mutation == "remove-recreate" {
            _ = try await f.service.removeConnection(id: f.connection.id); try await f.service.saveConnection(f.connection)
        } else { try await f.service.saveConnection(f.connection) }
        let bytes = try Data(contentsOf: f.file)
        await #expect(throws: CancellationError.self) {
            try await f.service.inboundCardEnvelope(runID: run.id, messageID: run.messageID, conversationID: run.conversationID,
                accountID: "fixture", agentID: run.receipt.agentID)
        }
        expectNoDifference(try Data(contentsOf: f.file), bytes)
        let queued = await f.service.deliveries(); expectNoDifference(queued, [])
    }
    @Test func admissionIsExactlyOnceAndNeverDeliveryConsent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cancellations = InboundInvalidations()
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: { cancellations.increment() })
        let run = try await claim(f, admission)
        expectNoDifference(run.receipt, admission.receipt)
        expectNoDifference(run.conversationID, inboundID(3)); expectNoDifference(run.messageID, inboundID(5))
        let records = await f.service.inboundRuns(), pending = await f.service.pendingInbound(accountID: "fixture")
        let deliveries = await f.service.deliveries(), wakes = await f.service.failureWakes()
        expectNoDifference(records, [run]); expectNoDifference(pending, [])
        expectNoDifference(deliveries, []); expectNoDifference(wakes, [])
        await #expect(throws: CancellationError.self) { try await claim(f, admission) }
        #expect(await f.service.isInboundCurrent(admission, run: run))
        admission.close(); admission.close(); expectNoDifference(cancellations.count, 1)
        #expect(await f.service.isInboundCurrent(admission, run: run) == false)
    }
    @Test(arguments: ["disable-enable", "remove-recreate", "same-save", "connector", "credentials", "stop"])
    func changedConfigurationCannotReviveSuspendedAdmission(kind: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let cancellations = InboundInvalidations()
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: { cancellations.increment() })
        switch kind {
        case "disable-enable": try await f.service.setConnectionEnabled(id: f.connection.id, enabled: false); try await f.service.setConnectionEnabled(id: f.connection.id, enabled: true)
        case "remove-recreate": _ = try await f.service.removeConnection(id: f.connection.id); try await f.service.saveConnection(f.connection)
        case "same-save": try await f.service.saveConnection(f.connection)
        case "connector": await f.service.register(InboundOfflineConnector())
        case "credentials": _ = try await f.service.commitCredential(connectionID: f.connection.id) { _ in (result: true, changed: true) }
        default: await f.service.stop(connectionID: f.connection.id)
        }
        expectNoDifference(cancellations.count, 1)
        #expect(throws: CancellationError.self) { try admission.check() }
        await #expect(throws: CancellationError.self) { try await claim(f, admission) }
        let records = await f.service.inboundRuns(), deliveries = await f.service.deliveries()
        expectNoDifference(records, []); expectNoDifference(deliveries, [])
    }
    @Test(arguments: [ChannelInboundRun.Status.completed, .cancelled, .failed])
    func finishedRunAndCrashNeverReplay(status: ChannelInboundRun.Status) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        let run = try await claim(f, admission), finish = date.addingTimeInterval(2)
        var records = await f.service.inboundRuns()
        await expectDifference(records) {
            try await f.service.finishInbound(run, status: status, at: finish); records = await f.service.inboundRuns()
        } changes: { $0[0].status = status; $0[0].finishedAt = finish }
        let restored = try ChannelService(storeURL: f.file, now: { finish })
        await restored.register(InboundOfflineConnector())
        let loaded = await restored.inboundRuns(), pending = await restored.pendingInbound(accountID: "fixture")
        expectNoDifference(loaded, records); expectNoDifference(pending, [])
        try await f.service.finishInbound(run, status: .completed, at: finish.addingTimeInterval(2))
        let unchanged = await f.service.inboundRuns(); expectNoDifference(unchanged, records)
    }
    @Test func restoredRunningRunIsInterruptedNotSpinnerOrResend() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        var run = try await claim(f, admission)
        let finish = date.addingTimeInterval(3)
        run.status = .interrupted; run.finishedAt = finish
        let restored = try ChannelService(storeURL: f.file, now: { finish })
        await restored.register(InboundOfflineConnector())
        let records = await restored.inboundRuns(), pending = await restored.pendingInbound(accountID: "fixture")
        let deliveries = await restored.deliveries()
        expectNoDifference(records, [run]); expectNoDifference(pending, []); expectNoDifference(deliveries, [])
    }
    @Test func foreignAccountAndChangedEnvelopeCannotAcquireHostFence() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: CancellationError.self) { try await f.service.prepareInbound(f.envelope, accountID: "foreign", invalidate: {}) }
        let forged = ChannelEnvelope(connectionID: f.connection.id, externalEventID: f.envelope.externalEventID,
            address: f.envelope.address, senderID: f.envelope.senderID, senderDisplayName: f.envelope.senderDisplayName,
            text: "Forged text under existing event ID", timestamp: date)
        await #expect(throws: CancellationError.self) { try await f.service.prepareInbound(forged, accountID: "fixture", invalidate: {}) }
        let pending = await f.service.pendingInbound(accountID: "foreign"), records = await f.service.inboundRuns()
        expectNoDifference(pending, []); expectNoDifference(records, [])
    }

    @Test(arguments: ["message", "run-matches-message", "message-matches-run"])
    func anotherEventCannotClaimAnExistingTranscriptIdentifier(collision: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let firstAdmission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        let first = try await claim(f, firstAdmission)
        try await f.service.finishInbound(first, status: .completed, at: date.addingTimeInterval(1))
        let next = anotherEnvelope(f)
        try #require(await f.service.ingest(next))
        let admission = try await f.service.prepareInbound(next, accountID: "fixture", invalidate: {})
        let original = await f.service.inboundRuns(), originalBytes = try Data(contentsOf: f.file)
        let runID = collision == "run-matches-message" ? first.messageID : inboundID(6)
        let messageID = collision == "message" ? first.messageID : collision == "message-matches-run" ? first.id : inboundID(7)
        await #expect(throws: CancellationError.self) {
            try await f.service.claimInbound(admission, conversationID: inboundID(3), runID: runID,
                messageID: messageID, at: date.addingTimeInterval(1))
        }
        let unchanged = await f.service.inboundRuns(), pending = await f.service.pendingInbound(accountID: "fixture")
        expectNoDifference(unchanged, original); expectNoDifference(pending, [next])
        expectNoDifference(try Data(contentsOf: f.file), originalBytes)
        let reopened = try ChannelService(storeURL: f.file)
        let loaded = await reopened.inboundRuns(); expectNoDifference(loaded, original)
        let deliveries = await f.service.deliveries(); expectNoDifference(deliveries, [])
    }

    @Test(arguments: ["message", "run-matches-message", "message-matches-run"])
    func malformedRestoredTranscriptIdentifiersFailBeforeRewriting(collision: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let firstAdmission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        let first = try await claim(f, firstAdmission)
        try await f.service.finishInbound(first, status: .completed, at: date.addingTimeInterval(1))
        let next = anotherEnvelope(f)
        try #require(await f.service.ingest(next))
        let admission = try await f.service.prepareInbound(next, accountID: "fixture", invalidate: {})
        let second = try await f.service.claimInbound(admission, conversationID: inboundID(3), runID: inboundID(6),
            messageID: inboundID(7), at: date.addingTimeInterval(1))
        try await f.service.finishInbound(second, status: .completed, at: date.addingTimeInterval(2))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        var runs = try #require(json["inboundRuns"] as? [[String: Any]])
        if collision == "run-matches-message" { runs[1]["id"] = first.messageID.uuidString }
        else { runs[1]["messageID"] = (collision == "message" ? first.messageID : first.id).uuidString }
        json["inboundRuns"] = runs
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        try corrupt.write(to: f.file, options: .atomic)
        #expect(throws: ChannelServiceError.invalidEnvelope) { _ = try ChannelService(storeURL: f.file) }
        expectNoDifference(try Data(contentsOf: f.file), corrupt)
    }

    @Test(arguments: ["duplicate-receipt", "connection", "missing-envelope", "finished-running", "unfinished-terminal", "backward-finish"])
    func malformedDurableInboundCannotBecomeFreshExecution(fault: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let admission = try await f.service.prepareInbound(f.envelope, accountID: "fixture", invalidate: {})
        _ = try await claim(f, admission)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        var receipts = try #require(json["inboundReceipts"] as? [[String: Any]])
        var runs = try #require(json["inboundRuns"] as? [[String: Any]])
        switch fault {
        case "duplicate-receipt": receipts.append(receipts[0])
        case "connection": receipts[0]["connectionID"] = inboundID(99).uuidString; runs[0]["receipt"] = receipts[0]
        case "missing-envelope": json["inbound"] = []
        case "finished-running": runs[0]["finishedAt"] = date.addingTimeInterval(1).timeIntervalSince1970 * 1_000
        case "unfinished-terminal": runs[0]["status"] = "completed"
        default: runs[0]["status"] = "completed"; runs[0]["finishedAt"] = date.addingTimeInterval(-1).timeIntervalSince1970 * 1_000
        }
        json["inboundReceipts"] = receipts; json["inboundRuns"] = runs
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        try corrupt.write(to: f.file, options: .atomic)
        #expect(throws: ChannelServiceError.invalidEnvelope) { _ = try ChannelService(storeURL: f.file) }
        expectNoDifference(try Data(contentsOf: f.file), corrupt)
    }

    @Test func legacyInboundHistoryNeverManufacturesAnExecutionGrant() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        json.removeValue(forKey: "inboundReceipts"); json.removeValue(forKey: "inboundRuns")
        try JSONSerialization.data(withJSONObject: json).write(to: f.file, options: .atomic)
        let reopened = try ChannelService(storeURL: f.file)
        await reopened.register(InboundOfflineConnector())
        let history = await reopened.inboundEvents(), pending = await reopened.pendingInbound(accountID: "fixture")
        expectNoDifference(history, [f.envelope]); expectNoDifference(pending, [])
        await #expect(throws: CancellationError.self) { try await reopened.prepareInbound(f.envelope, accountID: "fixture", invalidate: {}) }
    }
}
