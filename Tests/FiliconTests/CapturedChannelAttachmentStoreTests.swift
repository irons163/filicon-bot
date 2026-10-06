import CryptoKit
import CustomDump
import Darwin
import Foundation
import Testing
import FiliconAppServices
import FiliconDomain

@Suite("Captured channel attachment reads", .timeLimit(.minutes(1)))
struct CapturedChannelAttachmentStoreTests {
    @Test(arguments: [Data(), Data("Exact captured report".utf8)])
    func readsOnlyCapturedIdentityWithoutReopeningTheSource(bytes: Data) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "captured-channel-cas-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(rootURL: root.appending(path: "blobs"))
        let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
        let metadata = try await store.ingest(prepared: prepared, createdAt: Date(timeIntervalSince1970: 100))
        let source = root.appending(path: "report.txt")
        try Data("Not approved, never read".utf8).write(to: source)
        let inventory = try await store.inventory()
        let captured = try await store.channelPublicationData(for: metadata), after = try await store.inventory()
        expectNoDifference(captured, bytes)
        expectNoDifference(after, inventory)
        expectNoDifference(try Data(contentsOf: source), Data("Not approved, never read".utf8))
    }

    @Test(arguments: ["invalid-id", "uppercase-id", "unsafe-name", "negative-size", "oversize", "wrong-size", "wrong-hash", "root-link", "shard-link", "blob-link", "fifo", "directory", "missing"])
    func rejectsMalformedMetadataAndUnsafeCapturedPaths(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "captured-channel-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("Immutable captured bytes".utf8)
        let storeRoot = root.appending(path: "blobs"), store = AttachmentStore(rootURL: storeRoot)
        let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
        let original = try await store.ingest(prepared: prepared, createdAt: Date(timeIntervalSince1970: 100))
        let metadata = AttachmentMetadata(
            id: mode == "invalid-id" ? "../escape" : mode == "uppercase-id" ? original.id.uppercased() : original.id,
            filename: mode == "unsafe-name" ? "../report.txt" : original.filename,
            mimeType: original.mimeType,
            byteCount: mode == "negative-size" ? -1 : mode == "oversize" ? 25 * 1_024 * 1_024 + 1
                : mode == "wrong-size" ? original.byteCount + 1 : original.byteCount,
            kind: original.kind, createdAt: original.createdAt)
        let shard = storeRoot.appending(path: String(original.id.prefix(2))), blob = shard.appending(path: original.id)
        let outside = root.appending(path: "outside.txt")
        try bytes.write(to: outside)
        if mode == "root-link" || mode == "shard-link" {
            let target = mode == "root-link" ? storeRoot : shard
            let retained = root.appending(path: "retained")
            try FileManager.default.moveItem(at: target, to: retained)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: retained)
        }
        if ["blob-link", "fifo", "directory", "missing"].contains(mode) {
            try FileManager.default.removeItem(at: blob)
            if mode == "blob-link" { try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: outside) }
            if mode == "fifo" { #expect(mkfifo(blob.path, 0o600) == 0) }
            if mode == "directory" { try FileManager.default.createDirectory(at: blob, withIntermediateDirectories: false) }
        }
        if mode == "wrong-hash" { try Data(repeating: 120, count: bytes.count).write(to: blob) }
        await #expect(throws: AttachmentStoreError.self) { _ = try await store.channelPublicationData(for: metadata) }
        expectNoDifference(try Data(contentsOf: outside), bytes)
    }
}
