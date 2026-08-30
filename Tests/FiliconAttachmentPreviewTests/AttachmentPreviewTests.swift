import CryptoKit
import Foundation
import Testing
import FiliconDomain
import FiliconAppServices
@testable import Filicon

@Suite("Attachment Quick Look preview")
struct AttachmentPreviewTests {
    @Test func materializesUsingOriginalFilenameAndCleansUp() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let bytes = Data("preview contents".utf8)
        let metadata = AttachmentMetadata(
            id: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            filename: "notes.txt",
            mimeType: "text/plain",
            byteCount: Int64(bytes.count),
            kind: .document
        )
        let materializer = AttachmentPreviewMaterializer(rootURL: sandbox)

        let item = try materializer.materialize(data: bytes, metadata: metadata)

        #expect(item.filename == "notes.txt")
        #expect(item.fileURL.lastPathComponent == "notes.txt")
        #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
        #expect(try Data(contentsOf: item.fileURL) == bytes)

        materializer.remove(item)
        #expect(!FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    @Test func rejectsFilenameThatCouldEscapePreviewDirectory() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let metadata = AttachmentMetadata(
            id: String(repeating: "b", count: 64),
            filename: "../outside.txt",
            mimeType: "text/plain",
            byteCount: 1,
            kind: .document
        )
        let materializer = AttachmentPreviewMaterializer(rootURL: sandbox)

        #expect(throws: AttachmentPreviewError.invalidFilename("../outside.txt")) {
            _ = try materializer.materialize(data: Data("x".utf8), metadata: metadata)
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.path))
    }

    @Test func cleanupCannotDeleteDirectoryOutsidePreviewRoot() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let outside = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appending(path: "keep.txt")
        try Data("keep".utf8).write(to: file)
        let materializer = AttachmentPreviewMaterializer(rootURL: sandbox)
        let forged = AttachmentPreviewItem(filename: "keep.txt", fileURL: file)

        materializer.remove(forged)

        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func missingStoredAttachmentFailsExplicitly() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let identifier = String(repeating: "c", count: 64)
        let metadata = AttachmentMetadata(
            id: identifier,
            filename: "missing.pdf",
            mimeType: "application/pdf",
            byteCount: 10,
            kind: .document
        )
        let store = AttachmentStore(rootURL: sandbox)

        await #expect(throws: AttachmentStoreError.missing(identifier)) {
            _ = try await store.data(for: metadata)
        }
    }
}
