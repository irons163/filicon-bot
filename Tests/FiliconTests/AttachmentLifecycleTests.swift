import CryptoKit
import Foundation
import Testing
import FiliconAppServices
import FiliconDomain
import FiliconPersistence

private enum InjectedAttachmentFailure: Error { case crash }

@Suite("Attachment lifecycle and reference index")
struct AttachmentLifecycleTests {
    private func fixture(
        at sandbox: URL,
        now: Date,
        grace: TimeInterval = 60,
        fault: AttachmentLifecycleFaultPoint? = nil
    ) throws -> (AttachmentStore, AttachmentReferenceRepository, AttachmentLifecycle) {
        let store = AttachmentStore(rootURL: sandbox.appending(path: "attachments", directoryHint: .isDirectory))
        let repository = try AttachmentReferenceRepository(databaseURL: sandbox.appending(path: "attachments.sqlite"))
        let lifecycle = AttachmentLifecycle(
            store: store,
            references: repository,
            configuration: .init(quarantineGracePeriod: grace, stagedUploadLifetime: 60),
            clock: { now },
            faultInjector: { point in if point == fault { throw InjectedAttachmentFailure.crash } }
        )
        return (store, repository, lifecycle)
    }

    @Test func sharedBlobIsQuarantinedOnlyAfterLastMessageReference() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let now = Date(timeIntervalSince1970: 10_000)
        let (store, repository, lifecycle) = try fixture(at: sandbox, now: now)
        let firstOwner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let secondOwner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let bytes = Data("shared".utf8)

        let upload = try await lifecycle.stage(data: bytes, filename: "shared.txt", declaredMIMEType: "text/plain")
        let metadata = try await lifecycle.commit(upload, to: firstOwner)
        try await lifecycle.addReference(metadata, owner: secondOwner)
        #expect(try await repository.referenceCount(blobID: metadata.id) == 2)

        try await lifecycle.removeReference(blobID: metadata.id, owner: firstOwner)
        #expect(try await store.containsActive(id: metadata.id))
        #expect(try await repository.blob(id: metadata.id)?.state == .active)

        try await lifecycle.removeReference(blobID: metadata.id, owner: secondOwner)
        #expect(try await store.containsQuarantined(id: metadata.id))
        #expect(try await repository.blob(id: metadata.id)?.state == .quarantined)
    }

    @Test func repositoryPersistsStagingAndMessageReferenceSchemaAcrossReopen() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let now = Date(timeIntervalSince1970: 20_000)
        let (_, repository, lifecycle) = try fixture(at: sandbox, now: now)
        let owner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let upload = try await lifecycle.stage(data: Data("durable".utf8), filename: "d.txt", declaredMIMEType: "text/plain")
        #expect(try await repository.upload(token: upload.id) != nil)
        _ = try await lifecycle.commit(upload, to: owner)

        let reopened = try AttachmentReferenceRepository(databaseURL: sandbox.appending(path: "attachments.sqlite"))
        #expect(try await reopened.upload(token: upload.id) == nil)
        #expect(try await reopened.isReferenced(blobID: upload.metadata.id, owner: owner))
        #expect(try await reopened.blob(id: upload.metadata.id)?.state == .active)
    }

    @Test func reconcileAdoptsBlobLeftBeforeUploadDatabaseWrite() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let now = Date(timeIntervalSince1970: 30_000)
        let (_, _, crashing) = try fixture(at: sandbox, now: now, fault: .afterBlobWriteBeforeUploadIndex)
        await #expect(throws: InjectedAttachmentFailure.self) {
            _ = try await crashing.stage(data: Data("orphan".utf8), filename: "o.txt", declaredMIMEType: "text/plain")
        }

        let (store, repository, recovered) = try fixture(at: sandbox, now: now)
        let report = try await recovered.reconcile()
        let id = digest(Data("orphan".utf8))
        #expect(report.quarantinedUnindexedBlobs == 1)
        #expect(try await store.containsQuarantined(id: id))
        #expect(try await repository.blob(id: id)?.state == .quarantined)
    }

    @Test func reconcileFinishesAbortAndRestoresReferenceAfterDatabaseFileCrashes() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let now = Date(timeIntervalSince1970: 40_000)
        let (_, _, normal) = try fixture(at: sandbox, now: now)
        let upload = try await normal.stage(data: Data("recover".utf8), filename: "r.txt", declaredMIMEType: "text/plain")

        let (_, repository, abortCrash) = try fixture(at: sandbox, now: now, fault: .afterAbortDatabase)
        await #expect(throws: InjectedAttachmentFailure.self) { try await abortCrash.abort(upload) }
        #expect(try await repository.blob(id: upload.metadata.id)?.state == .quarantinePending)

        let (store, _, recovered) = try fixture(at: sandbox, now: now)
        _ = try await recovered.reconcile()
        #expect(try await store.containsQuarantined(id: upload.metadata.id))

        let owner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let (_, _, restoreCrash) = try fixture(at: sandbox, now: now, fault: .afterCommitDatabase)
        await #expect(throws: InjectedAttachmentFailure.self) {
            try await restoreCrash.addReference(upload.metadata, owner: owner)
        }
        #expect(try await store.containsQuarantined(id: upload.metadata.id))
        _ = try await recovered.reconcile()
        #expect(try await store.containsActive(id: upload.metadata.id))
        #expect(try await recovered.data(for: upload.metadata, owner: owner) == Data("recover".utf8))
    }

    @Test func graceGarbageCollectionRecoversAfterFileDeleteBeforeDatabaseDelete() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let start = Date(timeIntervalSince1970: 50_000)
        let (_, _, initial) = try fixture(at: sandbox, now: start, grace: 10)
        let owner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let upload = try await initial.stage(data: Data("garbage".utf8), filename: "g.txt", declaredMIMEType: "text/plain")
        _ = try await initial.commit(upload, to: owner)
        try await initial.removeReference(blobID: upload.metadata.id, owner: owner)

        let (_, repository, crashingGC) = try fixture(at: sandbox, now: start.addingTimeInterval(11), grace: 10, fault: .afterGarbageCollectionFileDelete)
        await #expect(throws: InjectedAttachmentFailure.self) { _ = try await crashingGC.collectGarbage() }
        #expect(try await repository.blob(id: upload.metadata.id) != nil)

        let (_, _, recovered) = try fixture(at: sandbox, now: start.addingTimeInterval(11), grace: 10)
        let report = try await recovered.reconcile()
        #expect(report.removedMissingRecords == 1)
        #expect(try await repository.blob(id: upload.metadata.id) == nil)
    }

    @Test func quotaHookRunsBeforeBytesAreWrittenAndCASStillDeduplicates() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let (store, repository, _) = try fixture(at: sandbox, now: .init(timeIntervalSince1970: 60_000))
        let rejecting = AttachmentLifecycle(
            store: store,
            references: repository,
            configuration: .init(quotaCheck: { _, requested in if requested > 3 { throw InjectedAttachmentFailure.crash } }),
            clock: { Date(timeIntervalSince1970: 60_000) }
        )
        await #expect(throws: InjectedAttachmentFailure.self) {
            _ = try await rejecting.stage(data: Data("four".utf8), filename: "q.txt", declaredMIMEType: "text/plain")
        }
        #expect(!(try await store.containsActive(id: digest(Data("four".utf8)))))

        let (_, _, normal) = try fixture(at: sandbox, now: .init(timeIntervalSince1970: 60_000))
        let first = try await normal.stage(data: Data("same".utf8), filename: "a.txt", declaredMIMEType: "text/plain")
        let second = try await normal.stage(data: Data("same".utf8), filename: "b.txt", declaredMIMEType: "text/plain")
        #expect(first.metadata.id == second.metadata.id)
        let inventory = try await store.inventory()
        #expect(inventory.active.count == 1)
    }

    @Test func internalCASDestinationSymlinkIsRejected() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let bytes = Data("link-target".utf8)
        let id = digest(bytes)
        let target = sandbox.appending(path: "outside")
        try bytes.write(to: target)
        let prefix = sandbox.appending(path: "attachments").appending(path: String(id.prefix(2)))
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: prefix.appending(path: id), withDestinationURL: target)
        let store = AttachmentStore(rootURL: sandbox.appending(path: "attachments"))
        await #expect(throws: AttachmentStoreError.self) {
            _ = try await store.ingest(data: bytes, filename: "safe.txt", declaredMIMEType: "text/plain")
        }
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
