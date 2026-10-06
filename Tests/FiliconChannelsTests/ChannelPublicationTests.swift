import Foundation
import Testing
import CustomDump
@testable import FiliconChannels

private actor PublicationProbe {
    struct Send: Equatable {
        let message: ChannelOutbound
        let address: ChannelAddress
        let connectionID: UUID
        let key: UUID
    }
    var sends: [Send] = []
    var failuresRemaining = 0
    func failNext() { failuresRemaining = 1 }
    func record(_ message: ChannelOutbound, address: ChannelAddress, connectionID: UUID, key: UUID) throws {
        sends.append(.init(message: message, address: address, connectionID: connectionID, key: key))
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw URLError(.timedOut)
        }
    }
}
private final class PublicationIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    func next() -> UUID {
        lock.withLock {
            value += 1
            return UUID(uuidString: "20000000-0000-0000-0000-" + String(format: "%012llx", value))!
        }
    }
}
private final class CredentialWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}
private final class PublicationCommitFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var checks = 0
    var count: Int { lock.withLock { checks } }
    func revoke() { lock.withLock { active = false } }
    func commit(_ operation: () throws -> ChannelDelivery) throws -> ChannelDelivery {
        try lock.withLock {
            checks += 1
            guard active else { throw CancellationError() }
            return try operation()
        }
    }
}
private struct PublicationConnector: ChannelConnector {
    var descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Fixture")
    let probe: PublicationProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        try await probe.record(message, address: address, connectionID: connection.id, key: idempotencyKey)
    }
}

@Suite("Scoped channel publication", .timeLimit(.minutes(1)))
struct ChannelPublicationTests {
    private let date = Date(timeIntervalSince1970: 1_000)
    private let owner = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let key = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
    private let firstDeliveryID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    private struct Snapshot: Equatable {
        var connections: [ChannelConnection]
        var inbound: [ChannelEnvelope]
        var deliveries: [ChannelDelivery]
        var failures: [ChannelFailureWake]
        init(_ service: ChannelService) async {
            connections = await service.connections()
            inbound = await service.inboundEvents()
            deliveries = await service.deliveries()
            failures = await service.failureWakes()
        }
    }
    private struct Fixture {
        let root: URL
        let service: ChannelService
        let first: ChannelConnection
        let second: ChannelConnection
        let probe: PublicationProbe
        var file: URL { root.appending(path: "channels.json") }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-publication-\(UUID())")
        let ids = PublicationIDs()
        let service = try ChannelService(storeURL: root.appending(path: "channels.json"), newDeliveryID: { ids.next() })
        let first = ChannelConnection(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            connectorID: "slack", displayName: "Own", accountLabel: "C_ONE",
            secretReference: "keychain://channels/PRIVATE-one", agentID: owner, ownerAccountID: "local")
        let second = ChannelConnection(id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            connectorID: "slack", displayName: "Other", accountLabel: "C_TWO",
            secretReference: "keychain://channels/PRIVATE-two", agentID: owner, ownerAccountID: "other-account")
        for connection in [first, second] { try await service.saveConnection(connection) }
        let probe = PublicationProbe()
        await service.register(PublicationConnector(probe: probe))
        return .init(root: root, service: service, first: first, second: second, probe: probe)
    }

    @Test(arguments: ["text", "address", "thread", "connection", "attachments"])
    func idempotencyNeverConfirmsADifferentPublication(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let address = ChannelAddress(platform: "slack", channelID: "C_ONE")
        let original = try await f.service.enqueue(.init(text: "Reviewed"), to: address,
            connectionID: f.first.id, idempotencyKey: key, at: date)
        let before = await Snapshot(f.service)
        let changedAddress = ChannelAddress(platform: "slack", channelID: change == "address" ? "C_OTHER" : "C_ONE",
            threadID: change == "thread" ? "thread" : nil)
        let attachments: [ChannelAttachment] = change == "attachments"
            ? [.init(blobID: String(repeating: "a", count: 64), filename: "review.txt", mimeType: "text/plain", byteCount: 1)] : []
        await #expect(throws: (any Error).self) {
            _ = try await f.service.enqueue(.init(text: change == "text" ? "Unreviewed" : "Reviewed", attachments: attachments),
                to: changedAddress, connectionID: change == "connection" ? f.second.id : f.first.id,
                idempotencyKey: key, at: date)
        }
        let afterConflict = await Snapshot(f.service)
        expectNoDifference(afterConflict, before)
        let replay = try await f.service.enqueue(.init(text: " Reviewed \n"), to: address,
            connectionID: f.first.id, idempotencyKey: key, at: date.addingTimeInterval(5))
        expectNoDifference(replay, original)
        let afterReplay = await Snapshot(f.service)
        expectNoDifference(afterReplay, before)
    }

    @Test(arguments: ["platform", "blank-thread", "control", "blob", "filename", "size", "mime"])
    func invalidDestinationOrAttachmentCannotEnterTheQueue(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = await Snapshot(f.service)
        let address = ChannelAddress(platform: change == "platform" ? "discord" : "slack",
            channelID: change == "control" ? "C_ONE\nC_TWO" : "C_ONE",
            threadID: change == "blank-thread" ? " \n " : nil)
        let attachment: [ChannelAttachment] = ["blob", "filename", "size", "mime"].contains(change)
            ? [.init(blobID: change == "blob" ? "file:///PRIVATE" : String(repeating: "a", count: 64),
                filename: change == "filename" ? "../PRIVATE.txt" : "result.txt",
                mimeType: change == "mime" ? "text/plain\r\nHeader: injected" : "text/plain",
                byteCount: change == "size" ? 25 * 1_024 * 1_024 + 1 : 1)] : []
        await #expect(throws: (any Error).self) {
            _ = try await f.service.enqueue(.init(text: "Reviewed", attachments: attachment), to: address,
                connectionID: f.first.id, idempotencyKey: key, at: date)
        }
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
    }

    private func proposal(_ f: Fixture, attachments: [ChannelAttachment] = []) async throws -> ChannelPublication {
        try await f.service.proposePublication(agentID: owner, accountID: "local",
            outbound: .init(text: " Reviewed \n", attachments: attachments),
            to: .init(platform: " slack ", channelID: " C_ONE ", threadID: " thread "))
    }
    private func expectedDelivery(_ publication: ChannelPublication) -> ChannelDelivery {
        .init(id: firstDeliveryID, connectionID: publication.connectionID, address: publication.address,
            outbound: publication.outbound, idempotencyKey: key, nextAttemptAt: date, createdAt: date,
            authorization: .init(ownerAccountID: "local", agentID: owner,
                configurationRevision: publication.configurationRevision))
    }

    @Test(arguments: ["dispatch", "binding", "parent"])
    func capturedHostFencesRemainValidThroughTheFinalQueueSave(revoked: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let dispatch = PublicationCommitFence(), binding = PublicationCommitFence()
        let parent = ChannelPublicationLifetime(commitGuard: { try dispatch.commit($0) })
        let child = ChannelPublicationLifetime(parent: parent, commitGuard: { try binding.commit($0) })
        let publication = try await proposal(f)
        let before = await Snapshot(f.service), bytes = try Data(contentsOf: f.file)
        // Revocation after async validation/proposal but before the actor's final
        // enqueue cannot be defeated by creating a child or refreshing a route.
        if revoked == "dispatch" { dispatch.revoke() }
        if revoked == "binding" { binding.revoke() }
        if revoked == "parent" { parent.close() }
        await #expect(throws: CancellationError.self) {
            _ = try await f.service.enqueueApprovedPublication(publication, lifetime: child, idempotencyKey: key, at: date)
        }
        let after = await Snapshot(f.service), savedBytes = try Data(contentsOf: f.file)
        expectNoDifference(after, before)
        expectNoDifference(savedBytes, bytes)
        expectNoDifference(child.queuedReceipt(idempotencyKey: key), nil)
    }

    @Test func childCommitRetainsAllHostGuardsAndKeepsAnAlreadyQueuedReceiptTruthful() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let dispatch = PublicationCommitFence(), binding = PublicationCommitFence()
        let parent = ChannelPublicationLifetime(commitGuard: { try dispatch.commit($0) })
        let child = ChannelPublicationLifetime(parent: parent, commitGuard: { try binding.commit($0) })
        let publication = try await proposal(f)
        let receipt = try await f.service.enqueueApprovedPublication(publication, lifetime: child, idempotencyKey: key, at: date)
        expectNoDifference(receipt, expectedDelivery(publication))
        expectNoDifference(dispatch.count, 1)
        expectNoDifference(binding.count, 1)
        let committed = await Snapshot(f.service)
        dispatch.revoke(); binding.revoke(); parent.close()
        expectNoDifference(child.queuedReceipt(idempotencyKey: key), receipt)
        await #expect(throws: CancellationError.self) {
            _ = try await f.service.enqueueApprovedPublication(publication, lifetime: child, idempotencyKey: key, at: date)
        }
        let after = await Snapshot(f.service)
        expectNoDifference(after, committed)
    }

    @Test(arguments: [false, true])
    func preparationIsReadOnlyAndCommitQueuesExactlyTheReviewedPayload(withFile: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = ChannelAttachment(blobID: String(repeating: "a", count: 64), filename: "review.txt",
            mimeType: "text/plain", byteCount: 12)
        var state = await Snapshot(f.service)
        let originalBytes = try Data(contentsOf: f.file)
        let publication = try await proposal(f, attachments: withFile ? [file] : [])
        let prepared = await Snapshot(f.service)
        expectNoDifference(prepared, state)
        let preparedBytes = try Data(contentsOf: f.file)
        expectNoDifference(preparedBytes, originalBytes)
        expectNoDifference(publication.connectionID, f.first.id)
        expectNoDifference(publication.outbound, .init(text: "Reviewed", attachments: withFile ? [file] : []))
        expectNoDifference(publication.address, .init(platform: "slack", channelID: "C_ONE", threadID: "thread"))
        let preview = String(decoding: try JSONEncoder().encode(publication), as: UTF8.self)
        #expect(!preview.contains("PRIVATE") && !preview.contains("secret") && !String(reflecting: publication).contains("PRIVATE"))
        let lifetime = ChannelPublicationLifetime()
        let expected = expectedDelivery(publication)
        var receipt: ChannelDelivery?
        await expectDifference(state) {
            receipt = try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
            state = await Snapshot(f.service)
        } changes: {
            $0.deliveries.append(expected)
        }
        expectNoDifference(receipt, expected)
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), expected)
        let sends = await f.probe.sends
        expectNoDifference(sends, [])
        let reopened = try ChannelService(storeURL: f.file)
        let restored = await Snapshot(reopened)
        expectNoDifference(restored, state)
        let replay = try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
        expectNoDifference(replay, expected)
        let afterReplay = await Snapshot(f.service)
        expectNoDifference(afterReplay, state)
    }

    @Test(arguments: ["other-account", "peer", "unowned", "disabled", "unregistered", "ambiguous"])
    func preparationDoesNotBorrowAnotherIdentity(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var own = f.first
        switch mode {
        case "other-account": own.ownerAccountID = "other-account"
        case "peer": own.agentID = f.second.id
        case "unowned": own.agentID = nil
        case "disabled": own.enabled = false
        case "unregistered":
            own = .init(id: own.id, connectorID: "discord", displayName: own.displayName,
                secretReference: own.secretReference, agentID: own.agentID, ownerAccountID: own.ownerAccountID)
        default:
            var duplicate = f.second; duplicate.ownerAccountID = "local"
            try await f.service.saveConnection(duplicate)
        }
        if mode != "ambiguous" { try await f.service.saveConnection(own) }
        let before = await Snapshot(f.service)
        await #expect(throws: mode == "ambiguous" ? ChannelPublicationError.ambiguous : .unavailable) {
            _ = try await f.service.proposePublication(agentID: owner, accountID: "local",
                outbound: .init(text: "Reviewed"), to: .init(platform: mode == "unregistered" ? "discord" : "slack", channelID: "C_ONE"))
        }
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
    }

    @Test(arguments: ["metadata", "owner", "agent", "disabled", "credential", "credential-failure", "credential-noop", "ABA", "recreate", "profile", "descriptor", "same-descriptor"])
    func approvalCannotOutliveItsExactConfiguration(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let publication = try await proposal(f)
        var changed = f.first
        switch mode {
        case "metadata": changed.displayName = "Changed"
        case "owner": changed.ownerAccountID = "other-account"
        case "agent": changed.agentID = f.second.id
        case "disabled": try await f.service.setConnectionEnabled(id: changed.id, enabled: false)
        case "credential": _ = try await f.service.commitCredential(connectionID: changed.id) { _ in (true, true) }
        case "credential-noop": _ = try await f.service.commitCredential(connectionID: changed.id) { _ in (false, false) }
        case "credential-failure":
            await #expect(throws: URLError.self) {
                _ = try await f.service.commitCredential(connectionID: changed.id) { _ -> (Bool, Bool) in
                    throw URLError(.cannotWriteToFile)
                }
            }
        case "ABA":
            changed.displayName = "Changed"; try await f.service.saveConnection(changed)
            try await f.service.saveConnection(f.first)
        case "recreate":
            try await f.service.removeConnection(id: changed.id)
            try await f.service.saveConnection(f.first)
        case "profile": _ = try await f.service.refreshProfile(connectionID: changed.id)
        case "descriptor":
            await f.service.register(PublicationConnector(descriptor: .init(id: "slack", displayName: "Changed"), probe: f.probe))
        case "same-descriptor":
            await f.service.register(PublicationConnector(probe: f.probe))
        default: break
        }
        if ["metadata", "owner", "agent"].contains(mode) { try await f.service.saveConnection(changed) }
        let before = await Snapshot(f.service)
        let bytes = try Data(contentsOf: f.file)
        let lifetime = ChannelPublicationLifetime()
        await #expect(throws: ChannelPublicationError.stale) {
            _ = try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
        }
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
        let afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(afterBytes, bytes)
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), nil)
    }

    @Test(arguments: ["closed", "cancelled", "other-service", "write-failure"])
    func lifetimeIssuerAndSaveFailureLeaveNoReceipt(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let publication = try await proposal(f), lifetime = ChannelPublicationLifetime()
        if mode == "closed" { lifetime.close() }
        let before = await Snapshot(f.service)
        let original = try Data(contentsOf: f.file)
        if mode == "write-failure" {
            try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        if mode == "cancelled" {
            let task = Task { () throws -> ChannelDelivery in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
            }
            await #expect(throws: CancellationError.self) { _ = try await task.value }
        } else if mode == "other-service" {
            let other = try ChannelService(storeURL: f.file)
            await other.register(PublicationConnector(probe: f.probe))
            await #expect(throws: ChannelPublicationError.stale) {
                _ = try await other.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
            }
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
            }
        }
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), nil)
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
        if mode == "write-failure" {
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.moveItem(at: f.root.appending(path: "backup.json"), to: f.file)
            let receipt = try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
            expectNoDifference(receipt.outbound, publication.outbound)
            let restored = await Snapshot(try ChannelService(storeURL: f.file))
            expectNoDifference(restored.deliveries, [receipt])
        } else {
            let afterBytes = try Data(contentsOf: f.file)
            expectNoDifference(afterBytes, original)
        }
    }

    @Test func unrelatedInboundDoesNotRetireConsentAndOnlyFlushProvesDelivery() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let publication = try await proposal(f)
        try await f.service.ingest(.init(connectionID: f.first.id, externalEventID: "incoming",
            address: .init(platform: "slack", channelID: "C_ONE"), senderID: "peer", senderDisplayName: "Peer",
            text: "Unrelated", timestamp: date))
        let lifetime = ChannelPublicationLifetime()
        let queued = try await f.service.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
        expectNoDifference(queued.status, .queued)
        var state = await Snapshot(f.service)
        await expectDifference(state) {
            await f.service.flush(now: date)
            state = await Snapshot(f.service)
        } changes: {
            $0.deliveries[0].status = .delivered
            $0.deliveries[0].attemptCount = 1
            $0.deliveries[0].deliveredAt = date
        }
        let sends = await f.probe.sends
        expectNoDifference(sends, [.init(message: publication.outbound, address: publication.address,
            connectionID: f.first.id, key: key)])
        lifetime.close()
        let actual = await f.service.delivery(id: queued.id)
        expectNoDifference(actual, state.deliveries[0])
        // The saved queue receipt deliberately does not impersonate a live
        // delivery-status query after the turn has closed.
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key)?.status, .queued)
    }

    @Test(arguments: ["unchanged", "ABA", "owner", "agent", "credential", "credential-failure", "credential-noop"])
    func restoredQueueDoesNotFollowAChangedIdentity(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let publication = try await proposal(f)
        let queued = try await f.service.enqueueApprovedPublication(publication, lifetime: .init(), idempotencyKey: key, at: date)
        var changed = f.first
        if mode == "ABA" {
            changed.displayName = "Changed"; try await f.service.saveConnection(changed)
            try await f.service.saveConnection(f.first)
        } else if mode == "owner" || mode == "agent" {
            if mode == "owner" { changed.ownerAccountID = "other-account" } else { changed.agentID = f.second.id }
            try await f.service.saveConnection(changed)
        } else if mode.hasPrefix("credential") {
            if mode == "credential-failure" {
                await #expect(throws: URLError.self) {
                    _ = try await f.service.commitCredential(connectionID: f.first.id) { _ -> (Bool, Bool) in
                        throw URLError(.cannotWriteToFile)
                    }
                }
            } else {
                _ = try await f.service.commitCredential(connectionID: f.first.id) { _ in (true, mode != "credential-noop") }
            }
        }
        let reopened = try ChannelService(storeURL: f.file)
        await reopened.register(PublicationConnector(probe: f.probe))
        await reopened.flush(now: date)
        let delivery = try #require(await reopened.delivery(id: queued.id))
        let sends = await f.probe.sends, failures = await reopened.failureWakes()
        expectNoDifference(delivery.idempotencyKey, key)
        expectNoDifference(delivery.status, mode == "unchanged" ? .delivered : .deadLetter)
        expectNoDifference(delivery.attemptCount, mode == "unchanged" ? 1 : 0)
        expectNoDifference(sends.count, mode == "unchanged" ? 1 : 0)
        expectNoDifference(failures.count, mode == "unchanged" ? 0 : 1)
        if let failure = failures.first {
            expectNoDifference(failure.deliveryID, queued.id)
            #expect(!failure.error.contains("PRIVATE"))
        }
    }

    @Test func durableRetryUsesTheSameReviewedAddressAndKey() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let publication = try await proposal(f)
        let queued = try await f.service.enqueueApprovedPublication(publication, lifetime: .init(), idempotencyKey: key, at: date)
        await f.probe.failNext()
        await f.service.flush(now: date)
        let failed = try #require(await f.service.delivery(id: queued.id))
        expectNoDifference(failed.status, .retrying)
        let restored = try ChannelService(storeURL: f.file)
        await restored.register(PublicationConnector(probe: f.probe))
        await restored.flush(now: date.addingTimeInterval(1))
        let delivered = try #require(await restored.delivery(id: queued.id))
        expectNoDifference(delivered.status, .delivered)
        expectNoDifference(delivered.attemptCount, 2)
        let sends = await f.probe.sends
        let expected = PublicationProbe.Send(message: publication.outbound, address: publication.address,
            connectionID: f.first.id, key: key)
        expectNoDifference(sends, [expected, expected])
    }

    @Test func credentialFenceSaveFailureNeverCallsTheWriter() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let publication = try await proposal(f)
        let queued = try await f.service.enqueueApprovedPublication(publication, lifetime: .init(), idempotencyKey: key, at: date)
        let before = await Snapshot(f.service)
        let bytes = try Data(contentsOf: f.file)
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        let writer = CredentialWriteProbe()
        await #expect(throws: (any Error).self) {
            _ = try await f.service.commitCredential(connectionID: f.first.id) { _ in
                writer.record()
                return (true, true)
            }
        }
        expectNoDifference(writer.count, 0)
        let after = await Snapshot(f.service)
        expectNoDifference(after, before)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.moveItem(at: backup, to: f.file)
        let afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(afterBytes, bytes)
        // The failed fence did not revoke unchanged, durably queued authority.
        let restored = try ChannelService(storeURL: f.file)
        await restored.register(PublicationConnector(probe: f.probe))
        await restored.flush(now: date)
        let delivered = try #require(await restored.delivery(id: queued.id))
        expectNoDifference(delivered.status, .delivered)
    }

    @Test func collidingLegacyIdentityDoesNotPersistNewAuthority() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.service.enqueue(.init(text: "Reviewed"),
            to: .init(platform: "slack", channelID: "C_ONE", threadID: "thread"),
            connectionID: f.first.id, idempotencyKey: key, at: date)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        object.removeValue(forKey: "publicationRevisions")
        try JSONSerialization.data(withJSONObject: object).write(to: f.file, options: .atomic)
        let restored = try ChannelService(storeURL: f.file)
        await restored.register(PublicationConnector(probe: f.probe))
        let publication = try await restored.proposePublication(agentID: owner, accountID: "local",
            outbound: .init(text: "Reviewed"), to: .init(platform: "slack", channelID: "C_ONE", threadID: "thread"))
        let before = await Snapshot(restored), bytes = try Data(contentsOf: f.file)
        let lifetime = ChannelPublicationLifetime()
        await #expect(throws: ChannelPublicationError.idempotencyConflict) {
            _ = try await restored.enqueueApprovedPublication(publication, lifetime: lifetime, idempotencyKey: key, at: date)
        }
        let after = await Snapshot(restored), afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(after, before)
        expectNoDifference(afterBytes, bytes)
        expectNoDifference(lifetime.queuedReceipt(idempotencyKey: key), nil)
        // A subsequent preparation must also see the original in-memory fence.
        let afterProposal = try await restored.proposePublication(agentID: owner, accountID: "local",
            outbound: publication.outbound, to: publication.address)
        expectNoDifference(afterProposal, publication)
    }

    @Test(arguments: ["text", "channel", "thread", "count", "total"])
    func publicationBoundsAcceptTheLimitAndRejectItsSuccessor(bound: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        func values(overLimit: Bool) -> (ChannelOutbound, ChannelAddress) {
            let file = ChannelAttachment(blobID: String(repeating: "a", count: 64), filename: "review.txt",
                mimeType: "text/plain", byteCount: bound == "total" ? 25 * 1_024 * 1_024 : 1)
            var files = [ChannelAttachment]()
            if bound == "count" { files = Array(repeating: file, count: 64 + (overLimit ? 1 : 0)) }
            if bound == "total" {
                files = Array(repeating: file, count: 4)
                if overLimit { files.append(.init(blobID: file.blobID, filename: "extra.txt", mimeType: "text/plain", byteCount: 1)) }
            }
            let outbound = ChannelOutbound(text: bound == "text" ? String(repeating: "a", count: 8_000 + (overLimit ? 1 : 0)) : "Reviewed",
                attachments: files)
            let address = ChannelAddress(platform: "slack", channelID: bound == "channel" ? String(repeating: "a", count: 512 + (overLimit ? 1 : 0)) : "C_ONE",
                threadID: bound == "thread" ? String(repeating: "a", count: 512 + (overLimit ? 1 : 0)) : nil)
            return (outbound, address)
        }
        let before = await Snapshot(f.service), bytes = try Data(contentsOf: f.file)
        let accepted = values(overLimit: false)
        let publication = try await f.service.proposePublication(agentID: owner, accountID: "local", outbound: accepted.0, to: accepted.1)
        expectNoDifference(publication.outbound, accepted.0)
        expectNoDifference(publication.address, accepted.1)
        let rejected = values(overLimit: true)
        await #expect(throws: (any Error).self) {
            _ = try await f.service.proposePublication(agentID: owner, accountID: "local", outbound: rejected.0, to: rejected.1)
        }
        let after = await Snapshot(f.service), afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(after, before)
        expectNoDifference(afterBytes, bytes)
        let sends = await f.probe.sends
        expectNoDifference(sends, [])
    }

    @Test(arguments: ["threads", "attachments"])
    func unsupportedTransportCapabilityCannotBecomeApproval(capability: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.service.register(PublicationConnector(descriptor: .init(id: "slack", displayName: "Fixture",
            supportsThreads: capability != "threads", supportsAttachments: capability != "attachments"), probe: f.probe))
        let file = ChannelAttachment(blobID: String(repeating: "a", count: 64), filename: "review.txt", mimeType: "text/plain", byteCount: 1)
        let before = await Snapshot(f.service), bytes = try Data(contentsOf: f.file)
        await #expect(throws: (any Error).self) {
            _ = try await f.service.proposePublication(agentID: owner, accountID: "local",
                outbound: .init(text: "Reviewed", attachments: capability == "attachments" ? [file] : []),
                to: .init(platform: "slack", channelID: "C_ONE", threadID: capability == "threads" ? "thread" : nil))
        }
        let after = await Snapshot(f.service), afterBytes = try Data(contentsOf: f.file)
        expectNoDifference(after, before)
        expectNoDifference(afterBytes, bytes)
    }

    @Test func legacyQueueRestoresWithoutInventingAgentAuthority() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let queued = try await f.service.enqueue(.init(text: "Legacy"), to: .init(platform: "slack", channelID: "C_ONE"),
            connectionID: f.first.id, idempotencyKey: key, at: date)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        object.removeValue(forKey: "publicationRevisions")
        var deliveries = try #require(object["deliveries"] as? [[String: Any]])
        deliveries[0].removeValue(forKey: "authorization")
        object["deliveries"] = deliveries
        try JSONSerialization.data(withJSONObject: object).write(to: f.file, options: .atomic)
        let restored = try ChannelService(storeURL: f.file)
        let legacy = try #require(await restored.delivery(id: queued.id))
        expectNoDifference(legacy, queued)
        expectNoDifference(legacy.authorization, nil)
        await restored.register(PublicationConnector(probe: f.probe))
        await restored.flush(now: date)
        let delivered = try #require(await restored.delivery(id: queued.id))
        expectNoDifference(delivered.status, .delivered)
    }
}
