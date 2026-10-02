import Foundation
import FiliconDomain
import FiliconPersistence

public enum AttachmentLifecycleFaultPoint: String, Sendable {
    case afterBlobWriteBeforeUploadIndex
    case afterUploadIndex
    case afterCommitDatabase
    case afterAbortDatabase
    case afterRemoveReferenceDatabase
    case afterQuarantineFileMove
    case afterRestoreFileMove
    case afterGarbageCollectionFileDelete
    case afterUnindexedBlobRecord
}

public struct AttachmentLifecycleConfiguration: Sendable {
    public var quarantineGracePeriod: TimeInterval
    public var stagedUploadLifetime: TimeInterval
    public var quotaCheck: (@Sendable (_ usage: AttachmentStorageUsage, _ requestedBytes: Int64) throws -> Void)?

    public init(
        quarantineGracePeriod: TimeInterval = 7 * 24 * 60 * 60,
        stagedUploadLifetime: TimeInterval = 24 * 60 * 60,
        quotaCheck: (@Sendable (AttachmentStorageUsage, Int64) throws -> Void)? = nil
    ) {
        self.quarantineGracePeriod = max(0, quarantineGracePeriod)
        self.stagedUploadLifetime = max(0, stagedUploadLifetime)
        self.quotaCheck = quotaCheck
    }
}

/// App-facing attachment coordinator. It owns the ordering contract between
/// the content-addressed files and the SQLite reference authority.
public actor AttachmentLifecycle {
    public typealias Clock = @Sendable () -> Date
    public typealias FaultInjector = @Sendable (AttachmentLifecycleFaultPoint) throws -> Void

    private let store: AttachmentStore
    private let references: AttachmentReferenceRepository
    private let configuration: AttachmentLifecycleConfiguration
    private let clock: Clock
    private let injectFault: FaultInjector

    public init(
        store: AttachmentStore,
        references: AttachmentReferenceRepository,
        configuration: AttachmentLifecycleConfiguration = .init(),
        clock: @escaping Clock = Date.init,
        faultInjector: @escaping FaultInjector = { _ in }
    ) {
        self.store = store
        self.references = references
        self.configuration = configuration
        self.clock = clock
        self.injectFault = faultInjector
    }

    /// Convenience construction point for AppModel integration. The app can
    /// retain one lifecycle, call `reconcile()` during startup, and route all
    /// transcript attachment mutations through the methods below.
    public static func live(
        applicationSupportDirectory: URL? = nil,
        configuration: AttachmentLifecycleConfiguration = .init(),
        clock: @escaping Clock = Date.init,
        faultInjector: @escaping FaultInjector = { _ in }
    ) throws -> AttachmentLifecycle {
        let base = applicationSupportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Filicon", directoryHint: .isDirectory)
        return try AttachmentLifecycle(
            store: AttachmentStore(rootURL: base.appending(path: "attachments", directoryHint: .isDirectory)),
            references: AttachmentReferenceRepository(databaseURL: base.appending(path: "attachment-index.sqlite")),
            configuration: configuration,
            clock: clock,
            faultInjector: faultInjector
        )
    }

    public func stage(fileURL: URL, declaredMIMEType: String? = nil) async throws -> StagedAttachment {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        try await checkQuota(requestedBytes: Int64(values.fileSize ?? 0))
        let metadata = try await store.ingest(fileURL: fileURL, declaredMIMEType: declaredMIMEType)
        try injectFault(.afterBlobWriteBeforeUploadIndex)
        let upload = StagedAttachment(id: UUID(), metadata: metadata)
        try await references.registerUpload(upload, stagedAt: clock())
        try injectFault(.afterUploadIndex)
        return upload
    }

    public func stage(data: Data, filename: String, declaredMIMEType: String) async throws -> StagedAttachment {
        try await checkQuota(requestedBytes: Int64(data.count))
        let metadata = try await store.ingest(data: data, filename: filename, declaredMIMEType: declaredMIMEType)
        try injectFault(.afterBlobWriteBeforeUploadIndex)
        let upload = StagedAttachment(id: UUID(), metadata: metadata)
        try await references.registerUpload(upload, stagedAt: clock())
        try injectFault(.afterUploadIndex)
        return upload
    }

    /// Stages only the captured reviewed bytes; never reopens a source URL.
    /// App-level quota reservation must encompass this operation as well.
    public func stage(prepared: PreparedAgentPublicationFile, verifiedImageMIMEType: String? = nil) async throws -> StagedAttachment {
        try Task.checkCancellation()
        try await checkQuota(requestedBytes: Int64(prepared.bytes.count))
        try Task.checkCancellation()
        let metadata = try await store.ingest(prepared: prepared, createdAt: clock(), verifiedImageMIMEType: verifiedImageMIMEType)
        try injectFault(.afterBlobWriteBeforeUploadIndex)
        let upload = StagedAttachment(id: UUID(), metadata: metadata)
        try await references.registerUpload(upload, stagedAt: clock())
        try injectFault(.afterUploadIndex)
        return upload
    }

    /// DB-first makes a committed message durable even if restoring a file is
    /// interrupted; startup reconciliation can replay the restore.
    public func commit(_ upload: StagedAttachment, to owner: AttachmentReferenceOwner) async throws -> AttachmentMetadata {
        let metadata = try await references.commitUpload(token: upload.id, owner: owner, now: clock())
        try injectFault(.afterCommitDatabase)
        try await store.restore(id: metadata.id)
        try injectFault(.afterRestoreFileMove)
        return metadata
    }

    public func abort(_ upload: StagedAttachment) async throws {
        guard let metadata = try await references.abortUpload(token: upload.id, now: clock()) else { return }
        try injectFault(.afterAbortDatabase)
        if try await references.blob(id: metadata.id)?.state == .quarantinePending {
            try await finishQuarantine(id: metadata.id)
        }
    }

    /// Adds reachability for imported/received transcript metadata after
    /// verifying that matching CAS bytes actually exist.
    public func addReference(_ metadata: AttachmentMetadata, owner: AttachmentReferenceOwner) async throws {
        let hasActive = try await store.containsActive(id: metadata.id)
        let hasQuarantined = try await store.containsQuarantined(id: metadata.id)
        guard hasActive || hasQuarantined else {
            throw AttachmentStoreError.missing(metadata.id)
        }
        try await references.addReference(metadata: metadata, owner: owner, now: clock())
        try injectFault(.afterCommitDatabase)
        try await store.restore(id: metadata.id)
        try injectFault(.afterRestoreFileMove)
    }

    public func removeReference(blobID: String, owner: AttachmentReferenceOwner) async throws {
        let becameUnreachable = try await references.removeReference(blobID: blobID, owner: owner, now: clock())
        try injectFault(.afterRemoveReferenceDatabase)
        if becameUnreachable { try await finishQuarantine(id: blobID) }
    }

    public func removeReferences(owner: AttachmentReferenceOwner) async throws {
        let ids = try await references.removeReferences(owner: owner, now: clock())
        try injectFault(.afterRemoveReferenceDatabase)
        for id in ids { try await finishQuarantine(id: id) }
    }

    public func removeReferences(conversationID: UUID) async throws {
        let ids = try await references.removeReferences(conversationID: conversationID, now: clock())
        try injectFault(.afterRemoveReferenceDatabase)
        for id in ids { try await finishQuarantine(id: id) }
    }

    public func data(for metadata: AttachmentMetadata, owner: AttachmentReferenceOwner) async throws -> Data {
        guard try await references.isReferenced(blobID: metadata.id, owner: owner) else {
            throw AttachmentStoreError.missing(metadata.id)
        }
        return try await store.data(for: metadata)
    }

    public func usage() async throws -> AttachmentStorageUsage { try await references.usage() }

    /// Replays every cross-resource transition and adopts unindexed CAS files
    /// into quarantine. Safe to run repeatedly at every startup.
    public func reconcile() async throws -> AttachmentReconciliationReport {
        let now = clock()
        var report = AttachmentReconciliationReport()
        var inventory = try await store.inventory()

        for temporary in inventory.temporaryFiles {
            try await store.removeTemporaryFile(temporary)
            report.removedTemporaryFiles += 1
        }

        for upload in try await references.uploads()
        where upload.stagedAt <= now.addingTimeInterval(-configuration.stagedUploadLifetime) {
            if let metadata = try await references.abortUpload(token: upload.token, now: now),
               try await references.blob(id: metadata.id)?.state == .quarantinePending {
                try await finishQuarantine(id: metadata.id)
                report.repairedTransitions += 1
            }
        }

        let indexed = try await references.blobs()
        let indexedIDs = Set(indexed.map(\.id))
        let unindexedIDs = Set(inventory.active.keys).union(inventory.quarantined.keys).subtracting(indexedIDs)
        for id in unindexedIDs.sorted() {
            let byteCount = inventory.active[id] ?? inventory.quarantined[id] ?? 0
            try await references.recordUnindexedBlob(id: id, byteCount: byteCount, at: now)
            try injectFault(.afterUnindexedBlobRecord)
            if inventory.active[id] != nil { try await store.quarantine(id: id) }
            try await references.markQuarantined(id: id, at: now)
            report.quarantinedUnindexedBlobs += 1
        }

        inventory = try await store.inventory()
        for blob in try await references.blobs() {
            let hasActive = inventory.active[blob.id] != nil
            let hasQuarantine = inventory.quarantined[blob.id] != nil
            if !hasActive && !hasQuarantine {
                if try await references.referenceCount(blobID: blob.id) == 0 {
                    try await references.deleteBlobRecord(id: blob.id)
                    report.removedMissingRecords += 1
                }
                continue
            }
            let reachable = try await references.referenceCount(blobID: blob.id) > 0
            if reachable || blob.state == .active {
                if hasQuarantine || !hasActive {
                    try await store.restore(id: blob.id)
                    try await references.markActive(id: blob.id)
                    report.repairedTransitions += 1
                }
            } else if hasActive || blob.state == .quarantinePending {
                try await store.quarantine(id: blob.id)
                try await references.markQuarantined(id: blob.id, at: blob.quarantineAt ?? now)
                report.repairedTransitions += 1
            }
        }
        return report
    }

    public func collectGarbage() async throws -> AttachmentGarbageCollectionReport {
        let now = clock()
        let cutoff = now.addingTimeInterval(-configuration.quarantineGracePeriod)
        var quarantined = 0
        var restored = 0
        var deleted = 0
        for blob in try await references.blobs() {
            let reachable = try await references.referenceCount(blobID: blob.id) > 0
            if reachable {
                if blob.state != .active {
                    try await store.restore(id: blob.id)
                    try injectFault(.afterRestoreFileMove)
                    try await references.markActive(id: blob.id)
                    restored += 1
                }
                continue
            }
            if blob.state == .quarantinePending {
                try await finishQuarantine(id: blob.id)
                quarantined += 1
                continue
            }
            if blob.state == .quarantined, let date = blob.quarantineAt, date <= cutoff {
                try await store.deleteQuarantined(id: blob.id)
                try injectFault(.afterGarbageCollectionFileDelete)
                try await references.deleteBlobRecord(id: blob.id)
                deleted += 1
            }
        }
        return .init(quarantined: quarantined, restored: restored, deleted: deleted)
    }

    private func finishQuarantine(id: String) async throws {
        do { try await store.quarantine(id: id) }
        catch AttachmentStoreError.missing { /* reconciliation will clean the stale index */ }
        try injectFault(.afterQuarantineFileMove)
        try await references.markQuarantined(id: id, at: clock())
    }

    private func checkQuota(requestedBytes: Int64) async throws {
        if let check = configuration.quotaCheck {
            try check(try await references.usage(), max(0, requestedBytes))
        }
    }
}
