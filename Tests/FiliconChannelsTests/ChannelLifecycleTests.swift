import Foundation
import Testing
import CustomDump
@testable import FiliconChannels

@Suite("Transactional channel lifecycle", .timeLimit(.minutes(1)))
struct ChannelLifecycleTests {
    private struct Snapshot: Equatable {
        var connections: [ChannelConnection]
        var inbound: [ChannelEnvelope]
        var deliveries: [ChannelDelivery]
        var wakes: [ChannelFailureWake]
        init(_ service: ChannelService) async {
            connections = await service.connections()
            inbound = await service.inboundEvents()
            deliveries = await service.deliveries()
            wakes = await service.failureWakes()
        }
    }
    private struct Fixture {
        let root: URL
        let service: ChannelService
        let first: ChannelConnection
        let second: ChannelConnection
        var file: URL { root.appending(path: "channels.json") }
        func blockWrites() throws {
            try FileManager.default.moveItem(at: file, to: root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        func restoreWrites() throws {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: root.appending(path: "backup.json"), to: file)
        }
    }
    private let date = Date(timeIntervalSince1970: 1_000)
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-lifecycle-\(UUID())")
        let service = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let first = ChannelConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            connectorID: "probe", displayName: "First", secretReference: "keychain://channels/first")
        let second = ChannelConnection(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            connectorID: "probe", displayName: "Second", secretReference: "keychain://channels/second")
        try await service.saveConnection(first)
        try await service.saveConnection(second)
        return .init(root: root, service: service, first: first, second: second)
    }
    private func envelope(_ connection: ChannelConnection, event: String = "event") -> ChannelEnvelope {
        .init(connectionID: connection.id, externalEventID: event,
              address: .init(platform: "probe", channelID: "general"), senderID: "sender", senderDisplayName: "Sender",
              text: "fixture", timestamp: date, cursor: "new-cursor")
    }

    @Test(arguments: ["success", "replay", "failure", "stopped"])
    func credentialCommitRebuildsOnlyAnActiveListener(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = CredentialListenerProbe(), inbox = LifecycleInbox()
        await f.service.register(probe)
        try await f.service.start(connectionID: f.first.id) { await inbox.receive($0) }
        for _ in 0..<200 where probe.count < 1 { try await Task.sleep(for: .milliseconds(5)) }
        expectNoDifference(probe.count, 1)
        if mode == "stopped" { await f.service.stop(connectionID: f.first.id) }
        if mode == "failure" {
            await #expect(throws: URLError.self) {
                _ = try await f.service.commitCredential(connectionID: f.first.id) { _ -> (Int, Bool) in
                    throw URLError(.cannotWriteToFile)
                }
            }
        } else {
            let result = await f.service.commitCredential(connectionID: f.first.id) { _ in
                (42, mode != "replay")
            }
            expectNoDifference(result, 42)
        }
        if mode == "success" {
            for _ in 0..<200 where probe.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
            expectNoDifference(probe.count, 2)
        }
        if mode != "stopped" {
            probe.yield(envelope(f.first, event: "current"))
            await inbox.waitForCount(1)
            let events = await inbox.events
            expectNoDifference(events, [envelope(f.first, event: "current")])
        }
        expectNoDifference(probe.count, mode == "success" ? 2 : 1)
        let connections = await f.service.connections()
        var expected = f.first
        if mode != "stopped" {
            expected.cursor = "new-cursor"
            expected.lastActivityAt = date
        }
        expectNoDifference(connections, [expected, f.second])
        await f.service.stop(connectionID: f.first.id)
    }

    @Test func credentialCommitInvalidatesInFlightProfile() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate()
        await f.service.register(LifecycleConnector(profileGate: gate))
        let task = Task { try await f.service.refreshProfile(connectionID: f.first.id) }
        await gate.waitForEntry()
        _ = await f.service.commitCredential(connectionID: f.first.id) { _ in (true, true) }
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let connections = await f.service.connections()
        expectNoDifference(connections, [f.first, f.second])
    }

    @Test func failedRemovalPreservesAllDurableState() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.service.ingest(envelope(f.first))
        _ = try await f.service.enqueue(.init(text: "pending"), to: .init(platform: "probe", channelID: "general"),
            connectionID: f.first.id, at: date)
        try await f.service.setConnectionEnabled(id: f.first.id, enabled: false)
        await f.service.flush(now: date) // A retained delivery and failure wake must also survive.
        let before = await Snapshot(f.service)
        #expect(!before.wakes.isEmpty)
        try f.blockWrites()
        await #expect(throws: (any Error).self) { _ = try await f.service.removeConnection(id: f.first.id) }
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
        try f.restoreWrites()
        let reopened = try ChannelService(storeURL: f.file)
        let durable = await Snapshot(reopened)
        expectNoDifference(durable, before)
    }

    @Test func removedConnectionProfileCannotOverwriteItsFormerArrayNeighbor() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate()
        await f.service.register(LifecycleConnector(profileGate: gate))
        let task = Task { try await f.service.refreshProfile(connectionID: f.first.id) }
        await gate.waitForEntry()
        try await f.service.removeConnection(id: f.first.id)
        let before = await Snapshot(f.service)
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
        expectNoDifference(after.connections, [f.second])
    }

    @Test(arguments: ["replace", "recreate", "disable-enable", "cancel"])
    func staleProfileResultsCannotOverwriteNewConfiguration(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate()
        await f.service.register(LifecycleConnector(profileGate: gate))
        let task = Task { try await f.service.refreshProfile(connectionID: f.first.id) }
        await gate.waitForEntry()
        switch mode {
        case "replace":
            var changed = f.first; changed.secretReference = "keychain://channels/new-credential"
            try await f.service.saveConnection(changed)
        case "recreate":
            try await f.service.removeConnection(id: f.first.id)
            try await f.service.saveConnection(f.first) // Identical fields, different incarnation.
        case "disable-enable":
            try await f.service.setConnectionEnabled(id: f.first.id, enabled: false)
            try await f.service.setConnectionEnabled(id: f.first.id, enabled: true)
        default: task.cancel()
        }
        let before = await Snapshot(f.service)
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
    }

    @Test func newerProfileRequestWinsButAcceptedActivityIsPreserved() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate()
        await f.service.register(LifecycleConnector(profileGate: gate))
        let old = Task { try await f.service.refreshProfile(connectionID: f.first.id) }
        await gate.waitForEntry()
        let newerProfile = ChannelProfile(id: "newer", displayName: "Newer profile", workspaceID: "workspace-new")
        await f.service.register(LifecycleConnector(profileValue: newerProfile))
        try await f.service.ingest(envelope(f.first))
        var state = await Snapshot(f.service)
        await expectDifference(state) {
            _ = try await f.service.refreshProfile(connectionID: f.first.id)
            state = await Snapshot(f.service)
        } changes: {
            $0.connections[0].profile = newerProfile
            $0.connections[0].accountID = "workspace-new"
        }
        await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await old.value }
        let after = await Snapshot(f.service)
        expectNoDifference(after, state)
        expectNoDifference(after.connections[0].cursor, "new-cursor")
        expectNoDifference(after.connections[0].lastActivityAt, date)
    }

    @Test func profileRefreshMergesActivityWithoutInvalidatingTheRequest() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate()
        let profile = ChannelProfile(id: "remote", displayName: "Remote")
        await f.service.register(LifecycleConnector(profileGate: gate, profileValue: profile))
        let task = Task { try await f.service.refreshProfile(connectionID: f.first.id) }
        await gate.waitForEntry()
        try await f.service.ingest(envelope(f.first))
        var state = await Snapshot(f.service)
        await expectDifference(state) {
            await gate.release()
            _ = try await task.value
            state = await Snapshot(f.service)
        } changes: {
            $0.connections[0].profile = profile
            $0.connections[0].accountID = "remote"
        }
    }

    @Test(arguments: ["save", "enable", "ingest", "enqueue", "profile", "acknowledge"])
    func failedWritesDoNotLeakIntoLaterSuccessfulSaves(operation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.service.enqueue(.init(text: "pending"), to: .init(platform: "probe", channelID: "general"),
            connectionID: f.first.id, at: date)
        try await f.service.setConnectionEnabled(id: f.first.id, enabled: false)
        await f.service.flush(now: date)
        await f.service.register(LifecycleConnector())
        let before = await Snapshot(f.service)
        let wake = try #require(before.wakes.first)
        try f.blockWrites()
        await #expect(throws: (any Error).self) {
            switch operation {
            case "save":
                var changed = f.first; changed.displayName = "Failed rename"
                try await f.service.saveConnection(changed)
            case "enable": try await f.service.setConnectionEnabled(id: f.first.id, enabled: true)
            case "ingest": _ = try await f.service.ingest(envelope(f.second))
            case "enqueue":
                _ = try await f.service.enqueue(.init(text: "must not leak"), to: .init(platform: "probe", channelID: "general"),
                    connectionID: f.second.id, at: date)
            case "profile": _ = try await f.service.refreshProfile(connectionID: f.second.id)
            default: try await f.service.acknowledgeFailureWake(id: wake.id)
            }
        }
        let failed = await Snapshot(f.service)
        expectNoDifference(failed, before)
        try f.restoreWrites()
        // Unrelated successful persistence must not flush a previously failed mutation.
        try await f.service.saveConnection(f.second)
        let reopened = try ChannelService(storeURL: f.file)
        let durable = await Snapshot(reopened)
        expectNoDifference(durable, before)
    }

    @Test func failedRemovalAndDisableLeaveTheLiveListenerUsable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let stream = LifecycleStream()
        let inbox = LifecycleInbox()
        await f.service.register(LifecycleConnector(stream: stream))
        try await f.service.start(connectionID: f.first.id) { await inbox.receive($0) }
        stream.continuation.yield(envelope(f.first, event: "before"))
        await inbox.waitForCount(1)
        try f.blockWrites()
        await #expect(throws: (any Error).self) { _ = try await f.service.removeConnection(id: f.first.id) }
        await #expect(throws: (any Error).self) { try await f.service.setConnectionEnabled(id: f.first.id, enabled: false) }
        try f.restoreWrites()
        stream.continuation.yield(envelope(f.first, event: "after"))
        await inbox.waitForCount(2)
        let received = await inbox.events, saved = await f.service.inboundEvents()
        expectNoDifference(received, [envelope(f.first, event: "before"), envelope(f.first, event: "after")])
        expectNoDifference(saved, received)
        await f.service.stop(connectionID: f.first.id)
        stream.continuation.finish()
    }

    @Test func listenerRejectsAnotherConnectionOrPlatformBeforeAcceptingItsOwnEvent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let stream = LifecycleStream(), inbox = LifecycleInbox()
        await f.service.register(LifecycleConnector(stream: stream))
        try await f.service.start(connectionID: f.first.id) { await inbox.receive($0) }
        stream.continuation.yield(envelope(f.second, event: "wrong-owner"))
        stream.continuation.yield(.init(connectionID: f.first.id, externalEventID: "wrong-platform",
            address: .init(platform: "slack", channelID: "general"), senderID: "sender", senderDisplayName: "Sender", text: "wrong"))
        stream.continuation.yield(envelope(f.first, event: "valid"))
        await inbox.waitForEvent("valid")
        let received = await inbox.events, saved = await f.service.inboundEvents()
        expectNoDifference(received, [envelope(f.first, event: "valid")])
        expectNoDifference(saved, received)
        await f.service.stop(connectionID: f.first.id)
        stream.continuation.finish()
    }

    @Test func overlappingFlushesDoNotResendAlreadyProcessedEntries() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate(), probe = LifecycleSendProbe()
        await f.service.register(LifecycleConnector(sendGate: gate, sendProbe: probe))
        for text in ["first", "second"] {
            _ = try await f.service.enqueue(.init(text: text), to: .init(platform: "probe", channelID: "general"),
                connectionID: f.first.id, at: date)
        }
        let firstFlush = Task { await f.service.flush(now: date) }
        await gate.waitForEntry()
        await f.service.flush(now: date) // Sends second while first is suspended.
        await gate.release()
        await firstFlush.value
        let calls = await probe.messages
        expectNoDifference(calls, ["first", "second"])
        let deliveries = await f.service.deliveries()
        expectNoDifference(deliveries.map(\.status), [.delivered, .delivered])
        expectNoDifference(deliveries.map(\.attemptCount), [1, 1])
    }

    @Test func failedSendingCheckpointPreventsExternalSendAndCanRetryAfterRecovery() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = LifecycleSendProbe()
        await f.service.register(LifecycleConnector(sendProbe: probe))
        let queued = try await f.service.enqueue(.init(text: "pending"), to: .init(platform: "probe", channelID: "general"),
            connectionID: f.first.id, at: date)
        let before = await Snapshot(f.service)
        try f.blockWrites()
        await f.service.flush(now: date)
        let calls = await probe.messages, failed = await Snapshot(f.service)
        expectNoDifference(calls, [])
        expectNoDifference(failed, before)
        try f.restoreWrites()
        await f.service.flush(now: date)
        let after = try #require(await f.service.delivery(id: queued.id))
        expectNoDifference(after.status, .delivered)
        expectNoDifference(after.attemptCount, 1)
        let sent = await probe.messages
        expectNoDifference(sent, ["pending"])
    }

    @Test(arguments: [false, true]) func lateSendCompletionDoesNotResurrectDeletedRecords(fail: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate(), probe = LifecycleSendProbe()
        await f.service.register(LifecycleConnector(sendGate: gate, sendProbe: probe, failSend: fail))
        try await f.service.ingest(envelope(f.first))
        _ = try await f.service.enqueue(.init(text: "first"), to: .init(platform: "probe", channelID: "general"),
            connectionID: f.first.id, at: date)
        let task = Task { await f.service.flush(now: date) }
        await gate.waitForEntry()
        var state = await Snapshot(f.service)
        await expectDifference(state) {
            try await f.service.removeConnection(id: f.first.id)
            state = await Snapshot(f.service)
        } changes: {
            $0.connections.remove(at: 0)
            $0.inbound.removeAll()
            $0.deliveries.removeAll()
        }
        await gate.release()
        await task.value
        let after = await Snapshot(f.service)
        expectNoDifference(after, state)
        let reopened = try ChannelService(storeURL: f.file)
        let durable = await Snapshot(reopened)
        expectNoDifference(durable, state)
        let sent = await probe.messages
        expectNoDifference(sent, ["first"]) // Already-started network sends cannot be recalled.
    }

    @Test func successfulRemovalDeletesOnlyTheChosenConnectionsRecords() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for connection in [f.first, f.second] {
            try await f.service.ingest(envelope(connection))
            _ = try await f.service.enqueue(.init(text: "queued"), to: .init(platform: "probe", channelID: "general"),
                connectionID: connection.id, at: date)
            try await f.service.setConnectionEnabled(id: connection.id, enabled: false)
        }
        await f.service.flush(now: date)
        var state = await Snapshot(f.service)
        expectNoDifference(state.wakes.count, 2)
        await expectDifference(state) {
            try await f.service.removeConnection(id: f.first.id)
            state = await Snapshot(f.service)
        } changes: {
            $0.connections.remove(at: 0)
            $0.inbound.remove(at: 0)
            $0.deliveries.remove(at: 0)
            $0.wakes.remove(at: 0)
        }
        let reopened = try ChannelService(storeURL: f.file)
        let durable = await Snapshot(reopened)
        expectNoDifference(durable, state)
    }

    @Test(arguments: [false, true])
    func completionSaveFailureDoesNotClaimDeliveryOrImmediatelyResend(fail: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate(), probe = LifecycleSendProbe()
        await f.service.register(LifecycleConnector(sendGate: gate, sendProbe: probe, failSend: fail))
        let queued = try await f.service.enqueue(.init(text: "first"), to: .init(platform: "probe", channelID: "general"),
            connectionID: f.first.id, at: date)
        let task = Task { await f.service.flush(now: date) }
        await gate.waitForEntry()
        let checkpoint = await Snapshot(f.service)
        expectNoDifference(checkpoint.deliveries[0].status, .sending)
        try f.blockWrites()
        await gate.release()
        await task.value
        let after = await Snapshot(f.service)
        expectNoDifference(after, checkpoint)
        try f.restoreWrites()
        await f.service.flush(now: date.addingTimeInterval(100))
        let sent = await probe.messages
        expectNoDifference(sent, ["first"])
        // Existing restart recovery retries an indeterminate send with the same
        // idempotency key. This is not an exactly-once transport guarantee.
        let reopened = try ChannelService(storeURL: f.file)
        let recovered = try #require(await reopened.delivery(id: queued.id))
        expectNoDifference(recovered.status, .retrying)
        expectNoDifference(recovered.idempotencyKey, queued.idempotencyKey)
        expectNoDifference(recovered.attemptCount, 1)
    }

    @Test func failedConfigurationSaveDoesNotInvalidatePendingProfile() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelLifecycleGate()
        await f.service.register(LifecycleConnector(profileGate: gate))
        let task = Task { try await f.service.refreshProfile(connectionID: f.first.id) }
        await gate.waitForEntry()
        try f.blockWrites()
        var changed = f.first; changed.secretReference = "keychain://channels/failed"
        await #expect(throws: (any Error).self) { try await f.service.saveConnection(changed) }
        try f.restoreWrites()
        await gate.release()
        let profile = try #require(try await task.value)
        let connections = await f.service.connections()
        expectNoDifference(connections[0].profile, profile)
        expectNoDifference(connections[0].secretReference, f.first.secretReference)
        expectNoDifference(connections[1], f.second)
    }
}

private actor ChannelLifecycleGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private struct LifecycleConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "probe", displayName: "Probe")
    var profileGate: ChannelLifecycleGate?
    var profileValue = ChannelProfile(id: "remote-first", displayName: "First remote profile", workspaceID: "remote-workspace")
    var stream: LifecycleStream?
    var sendGate: ChannelLifecycleGate?
    var sendProbe: LifecycleSendProbe?
    var failSend = false
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        if let stream { return stream.stream }
        return AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await sendProbe?.record(message.text)
        if message.text == "first" { await sendGate?.hold() }
        if failSend { throw URLError(.networkConnectionLost) }
    }
    func profile(connection: ChannelConnection) async throws -> ChannelProfile? {
        await profileGate?.hold()
        return profileValue
    }
}

private final class CredentialListenerProbe: ChannelConnector, @unchecked Sendable {
    let descriptor = ChannelConnectorDescriptor(id: "probe", displayName: "Probe")
    private let lock = NSLock()
    private var streams: [LifecycleStream] = []
    var count: Int { lock.withLock { streams.count } }
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        lock.withLock {
            let stream = LifecycleStream()
            streams.append(stream)
            return stream.stream
        }
    }
    func yield(_ event: ChannelEnvelope) {
        lock.withLock { _ = streams.last?.continuation.yield(event) }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress, connection: ChannelConnection, idempotencyKey: UUID) async throws {}
}

private struct LifecycleStream: Sendable {
    let stream: AsyncThrowingStream<ChannelEnvelope, Error>
    let continuation: AsyncThrowingStream<ChannelEnvelope, Error>.Continuation
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
}

private actor LifecycleInbox {
    var events: [ChannelEnvelope] = []
    private var waiters: [(Int?, String?, CheckedContinuation<Void, Never>)] = []
    func receive(_ event: ChannelEnvelope) {
        events.append(event)
        waiters.removeAll { count, id, continuation in
            if count.map({ events.count >= $0 }) == true || id == event.externalEventID {
                continuation.resume(); return true
            }
            return false
        }
    }
    func waitForCount(_ count: Int) async {
        if events.count < count { await withCheckedContinuation { waiters.append((count, nil, $0)) } }
    }
    func waitForEvent(_ id: String) async {
        if !events.contains(where: { $0.externalEventID == id }) {
            await withCheckedContinuation { waiters.append((nil, id, $0)) }
        }
    }
}

private actor LifecycleSendProbe {
    var messages: [String] = []
    func record(_ text: String) { messages.append(text) }
}
