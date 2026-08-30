import CryptoKit
import Foundation
import Testing
import FiliconDomain
import FiliconAppServices

@Suite("Attachment store")
struct AttachmentTests {
    @Test func contentAddressedRoundTripAndDeduplication() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let source = sandbox.appending(path: "notes.txt")
        let bytes = Data("native Swift attachment".utf8)
        try bytes.write(to: source)
        let store = AttachmentStore(rootURL: sandbox.appending(path: "blobs", directoryHint: .isDirectory))

        let first = try await store.ingest(fileURL: source)
        let second = try await store.ingest(fileURL: source)

        #expect(first.id == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect(first.id == second.id)
        #expect(first.mimeType == "text/plain")
        #expect(first.kind == .document)
        #expect(try await store.data(for: first) == bytes)
    }

    @Test func rejectsOversizedRegularAttachmentBeforeCopying() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let source = sandbox.appending(path: "large.txt")
        let handle = FileHandle(forWritingAtPath: source.path) ?? {
            FileManager.default.createFile(atPath: source.path, contents: nil)
            return FileHandle(forWritingAtPath: source.path)!
        }()
        try handle.truncate(atOffset: UInt64(AttachmentLimits.regularBytes + 1))
        try handle.close()
        let store = AttachmentStore(rootURL: sandbox.appending(path: "blobs"))

        await #expect(throws: AttachmentStoreError.self) {
            _ = try await store.ingest(fileURL: source)
        }
    }

    @Test func rejectsSymlinkAndCorruptIdentifier() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let source = sandbox.appending(path: "source.txt")
        let link = sandbox.appending(path: "link.txt")
        try Data("x".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let store = AttachmentStore(rootURL: sandbox.appending(path: "blobs"))

        await #expect(throws: AttachmentStoreError.self) {
            _ = try await store.ingest(fileURL: link)
        }
        let invalid = AttachmentMetadata(id: "../escape", filename: "x", mimeType: "text/plain", byteCount: 1, kind: .document)
        await #expect(throws: AttachmentStoreError.self) {
            _ = try await store.data(for: invalid)
        }
    }

    @Test func ingestsReceivedDataWithTrimmedMetadataAndContentAddressedDeduplication() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let bytes = Data("downloaded channel attachment".utf8)
        let store = AttachmentStore(rootURL: sandbox.appending(path: "blobs", directoryHint: .isDirectory))

        let first = try await store.ingest(
            data: bytes,
            filename: "  photo.PNG  ",
            declaredMIMEType: "  image/png  "
        )
        let second = try await store.ingest(
            data: bytes,
            filename: "photo.PNG",
            declaredMIMEType: "image/png"
        )

        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(first.id == digest)
        #expect(second.id == first.id)
        #expect(second.filename == first.filename)
        #expect(second.mimeType == first.mimeType)
        #expect(second.byteCount == first.byteCount)
        #expect(second.kind == first.kind)
        #expect(first.filename == "photo.PNG")
        #expect(first.mimeType == "image/png")
        #expect(first.byteCount == Int64(bytes.count))
        #expect(first.kind == .image)
        #expect(try await store.data(for: first) == bytes)

        let entries = try FileManager.default.contentsOfDirectory(atPath: sandbox.appending(path: "blobs").path)
        #expect(entries == [String(digest.prefix(2))])
        let blobs = try FileManager.default.contentsOfDirectory(
            atPath: sandbox.appending(path: "blobs").appending(path: String(digest.prefix(2))).path
        )
        #expect(blobs == [digest])
    }

    @Test func receivedDataRejectsUnsafeNamesMissingMIMEAndOversizePayloads() async throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let store = AttachmentStore(rootURL: sandbox.appending(path: "blobs"))

        for filename in ["", "../escape.txt", "/absolute.txt", "folder/child.txt", "C:\\absolute.txt", "line\u{0000}break.txt"] {
            await #expect(throws: AttachmentStoreError.invalidFilename) {
                _ = try await store.ingest(data: Data("x".utf8), filename: filename, declaredMIMEType: "text/plain")
            }
        }

        await #expect(throws: AttachmentStoreError.corrupt("missing-mime-type")) {
            _ = try await store.ingest(data: Data("x".utf8), filename: "note.txt", declaredMIMEType: "  \n")
        }

        let oversized = Data(repeating: 0, count: Int(AttachmentLimits.regularBytes + 1))
        await #expect(throws: AttachmentStoreError.tooLarge(
            filename: "large.txt", limitBytes: AttachmentLimits.regularBytes
        )) {
            _ = try await store.ingest(data: oversized, filename: "large.txt", declaredMIMEType: "text/plain")
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.appending(path: "blobs").path))
    }
}
