import AppKit
import CryptoKit
import Foundation
import QuickLookUI
import SwiftUI
import FiliconDomain

enum AttachmentPreviewError: LocalizedError, Equatable {
    case invalidFilename(String)
    case integrityMismatch
    case previewFileUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidFilename:
            "This attachment has an invalid filename and cannot be previewed."
        case .integrityMismatch:
            "The attachment bytes do not match their content-addressed identity."
        case .previewFileUnavailable:
            "The attachment preview file could not be created."
        }
    }
}

struct AttachmentPreviewItem: Identifiable, Equatable {
    let id: UUID
    let files: [AttachmentPreviewFile]
    let initialFileID: UUID

    var filename: String { initialFile.filename }
    var fileURL: URL { initialFile.fileURL }
    var metadata: AttachmentMetadata? { initialFile.metadata }

    private var initialFile: AttachmentPreviewFile {
        files.first(where: { $0.id == initialFileID }) ?? files[0]
    }

    init(id: UUID = UUID(), filename: String, fileURL: URL, metadata: AttachmentMetadata? = nil) {
        self.id = id
        let file = AttachmentPreviewFile(filename: filename, fileURL: fileURL, metadata: metadata)
        self.files = [file]
        self.initialFileID = file.id
    }

    init(id: UUID = UUID(), files: [AttachmentPreviewFile], initialFileID: UUID) {
        precondition(!files.isEmpty)
        self.id = id
        self.files = files
        self.initialFileID = files.contains(where: { $0.id == initialFileID }) ? initialFileID : files[0].id
    }
}

struct AttachmentPreviewFile: Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let fileURL: URL
    let metadata: AttachmentMetadata?

    init(id: UUID = UUID(), filename: String, fileURL: URL, metadata: AttachmentMetadata? = nil) {
        self.id = id
        self.filename = filename
        self.fileURL = fileURL
        self.metadata = metadata
    }
}

/// Produces an isolated file with the original extension so Quick Look can
/// select the correct preview generator. Each materialization gets its own
/// directory, which also makes cleanup independent of other open requests.
struct AttachmentPreviewMaterializer {
    let rootURL: URL
    var fileManager: FileManager = .default

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appending(path: "FiliconPreviews", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func materialize(data: Data, metadata: AttachmentMetadata) throws -> AttachmentPreviewItem {
        let filename = metadata.filename
        guard isValidFilename(filename) else {
            throw AttachmentPreviewError.invalidFilename(filename)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.id, Int64(data.count) == metadata.byteCount else {
            throw AttachmentPreviewError.integrityMismatch
        }

        let directory = rootURL.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appending(path: filename, directoryHint: .notDirectory)
            try data.write(to: destination, options: [.atomic])
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                try? fileManager.removeItem(at: directory)
                throw AttachmentPreviewError.previewFileUnavailable
            }
            return AttachmentPreviewItem(filename: filename, fileURL: destination, metadata: metadata)
        } catch let error as AttachmentPreviewError {
            throw error
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func remove(_ item: AttachmentPreviewItem) {
        let root = rootURL.standardizedFileURL
        for file in item.files {
            let directory = file.fileURL.deletingLastPathComponent().standardizedFileURL
            guard directory.deletingLastPathComponent() == root else { continue }
            try? fileManager.removeItem(at: directory)
        }
    }

    private func isValidFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty, filename != ".", filename != "..", !filename.utf8.contains(0) else {
            return false
        }
        return URL(fileURLWithPath: filename).lastPathComponent == filename
            && !filename.contains("/")
    }
}

struct AttachmentQuickLookSheet: View {
    let item: AttachmentPreviewItem
    let onClose: () -> Void

    var body: some View {
        AttachmentMediaViewerSheet(item: item, onClose: onClose)
    }
}

struct AttachmentQuickLookView: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)
        view?.autostarts = true
        view?.previewItem = fileURL as NSURL
        return view ?? QLPreviewView(frame: .zero, style: .normal)!
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != fileURL as NSURL {
            view.previewItem = fileURL as NSURL
            view.refreshPreviewItem()
        }
    }
}
