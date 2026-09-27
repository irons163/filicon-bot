import CustomDump
import Darwin
import Foundation
import Testing
import FiliconAppServices
import FiliconDomain
import FiliconPersistence

@Suite("Reviewed file snapshot storage", .timeLimit(.minutes(1)))
struct PreparedPublicationStorageTests {
    @Test func concurrentStoresReuseOneVerifiedBlob() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "publication-storage-race-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try PreparedAgentPublicationFile(bytes: Data(repeating: 42, count: 1024 * 1024), filename: "binary.dat")
        let first = AttachmentStore(rootURL: root), second = AttachmentStore(rootURL: root)
        let now = Date(timeIntervalSince1970: 1000)
        async let left = first.ingest(prepared: file, createdAt: now)
        async let right = second.ingest(prepared: file, createdAt: now)
        let (a, b) = try await (left, right)
        expectNoDifference(a, b)
        let inventory = try await first.inventory()
        expectNoDifference(inventory.active, [file.digest: Int64(file.bytes.count)])
        expectNoDifference(inventory.temporaryFiles, [])
        let bytes = try await second.data(for: a)
        expectNoDifference(bytes, file.bytes)
    }

    @Test func interruptedStagingUsesExistingRecoveryWithoutLosingBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "publication-storage-recovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootURL: root.appending(path: "blobs"))
        let references = try AttachmentReferenceRepository(databaseURL: root.appending(path: "references.sqlite"))
        let now = Date(timeIntervalSince1970: 1000)
        let file = try PreparedAgentPublicationFile(bytes: Data("not yet indexed".utf8), filename: "report.txt")
        let interrupted = AttachmentLifecycle(store: store, references: references, clock: { now }, faultInjector: {
            if $0 == .afterBlobWriteBeforeUploadIndex { throw AgentFilePublicationError.uncertainCommit }
        })
        await #expect(throws: AgentFilePublicationError.uncertainCommit) { _ = try await interrupted.stage(prepared: file) }
        let recovered = AttachmentLifecycle(store: store, references: references, clock: { now })
        let report = try await recovered.reconcile()
        expectNoDifference(report.quarantinedUnindexedBlobs, 1)
        let quarantined = try await store.containsQuarantined(id: file.digest)
        expectNoDifference(quarantined, true)
        // Re-stage and commit through the ordinary reference authority, which
        // restores quarantined content; no global cleanup or real data touched.
        let upload = try await recovered.stage(prepared: file)
        let owner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let metadata = try await recovered.commit(upload, to: owner)
        let bytes = try await recovered.data(for: metadata, owner: owner)
        expectNoDifference(bytes, file.bytes)
    }

    @Test(arguments: ["report.txt", "empty.txt", "page.html", "image.svg", "fake.png"])
    func storesExactSnapshotAndReopens(name: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "publication-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try PreparedAgentPublicationFile(bytes: name == "empty.txt" ? Data() : Data("immutable content".utf8), filename: name)
        let store = AttachmentStore(rootURL: root.appending(path: "blobs"))
        let database = root.appending(path: "references.sqlite")
        let references = try AttachmentReferenceRepository(databaseURL: database)
        let now = Date(timeIntervalSince1970: 1_000)
        let lifecycle = AttachmentLifecycle(store: store, references: references, clock: { now })
        let upload = try await lifecycle.stage(prepared: file)
        let owner = AttachmentReferenceOwner(conversationID: UUID(), messageID: UUID())
        let saved = try await lifecycle.commit(upload, to: owner)
        expectNoDifference(saved.id, file.digest)
        expectNoDifference(saved.filename, name)
        expectNoDifference(saved.createdAt, now)
        expectNoDifference(saved.byteCount, Int64(file.bytes.count))
        expectNoDifference(saved.mimeType, name.hasSuffix(".txt") ? "text/plain" : "application/octet-stream")
        let reopened = AttachmentStore(rootURL: root.appending(path: "blobs"))
        let bytes = try await reopened.data(for: saved)
        expectNoDifference(bytes, file.bytes)
        let again = try await reopened.ingest(prepared: file, createdAt: now)
        expectNoDifference(again, saved)
        let inventory = try await reopened.inventory()
        expectNoDifference(inventory.active, [file.digest: Int64(file.bytes.count)])
        expectNoDifference(inventory.temporaryFiles, [])
        let reopenedReferences = try AttachmentReferenceRepository(databaseURL: database)
        let referenced = try await reopenedReferences.isReferenced(blobID: saved.id, owner: owner)
        expectNoDifference(referenced, true)
    }

    @Test(arguments: ["corrupt", "shard-link", "blob-link", "fifo", "directory", "quota"])
    func refusesUnsafeOrUnfundedStorage(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "publication-storage-reject-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = root.appending(path: "blobs"), outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = try PreparedAgentPublicationFile(bytes: Data("approved".utf8), filename: "report.txt")
        let shard = blobs.appending(path: String(file.digest.prefix(2)))
        let destination = shard.appending(path: file.digest)
        if mode == "shard-link" {
            try FileManager.default.createSymbolicLink(at: shard, withDestinationURL: outside)
        } else {
            try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
            switch mode {
            case "corrupt": try Data("tampered".utf8).write(to: destination)
            case "blob-link":
                let target = outside.appending(path: "private")
                try file.bytes.write(to: target)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
            case "fifo": expectNoDifference(mkfifo(destination.path, 0o600), 0)
            case "directory": try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            default: break
            }
        }
        let store = AttachmentStore(rootURL: blobs)
        let references = try AttachmentReferenceRepository(databaseURL: root.appending(path: "references.sqlite"))
        let lifecycle = AttachmentLifecycle(store: store, references: references,
            configuration: .init(quotaCheck: { _, requested in
                expectNoDifference(requested, Int64(file.bytes.count))
                if mode == "quota" { throw AgentFilePublicationError.unavailable }
            }))
        await #expect(throws: (any Error).self) { _ = try await lifecycle.stage(prepared: file) }
        let outsideNames = try FileManager.default.contentsOfDirectory(atPath: outside.path)
        expectNoDifference(outsideNames, mode == "blob-link" ? ["private"] : [])
        if mode == "corrupt" { expectNoDifference(try Data(contentsOf: destination), Data("tampered".utf8)) }
        if mode == "quota" { #expect(!FileManager.default.fileExists(atPath: destination.path)) }
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        #expect(!rootNames.contains { $0.hasPrefix(".ingest-") })
    }
}
