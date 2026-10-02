import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers
import FiliconDomain

public enum AttachmentStoreError: LocalizedError, Equatable, Sendable {
    case notRegularFile
    case invalidFilename
    case tooLarge(filename: String, limitBytes: Int64)
    case missing(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile:
            "Only direct regular files can be attached."
        case .invalidFilename:
            "The attachment filename is invalid."
        case .tooLarge(let filename, let limit):
            "\(filename) is too large to attach (maximum \(limit / 1_024 / 1_024) MB)."
        case .missing(let id):
            "Attachment \(id) is missing."
        case .corrupt(let id):
            "Attachment \(id) failed its integrity check."
        }
    }
}

public struct AttachmentStoreInventory: Sendable, Equatable {
    public let active: [String: Int64]
    public let quarantined: [String: Int64]
    public let temporaryFiles: [URL]

    public init(active: [String: Int64], quarantined: [String: Int64], temporaryFiles: [URL]) {
        self.active = active
        self.quarantined = quarantined
        self.temporaryFiles = temporaryFiles
    }
}

/// Content-addressed attachment storage rooted in Application Support.
///
/// Callers retain only `AttachmentMetadata`; source paths never enter a
/// transcript. Bytes are copied and hashed in one pass into a same-volume
/// temporary file, then atomically renamed to their SHA-256 identity.
public actor AttachmentStore {
    private let rootURL: URL
    private let fileManager: FileManager

    public init(rootURL: URL, fileManager: FileManager = .default) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Filicon", directoryHint: .isDirectory)
            .appending(path: "attachments", directoryHint: .isDirectory)
    }

    public func ingest(fileURL: URL, declaredMIMEType: String? = nil) throws -> AttachmentMetadata {
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AttachmentStoreError.notRegularFile
        }

        let filename = fileURL.lastPathComponent
        guard Self.isSafeFilename(filename) else { throw AttachmentStoreError.invalidFilename }
        let cleanMIME = try Self.validatedMIMEType(declaredMIMEType)
        let limit = AttachmentLimits.byteLimit(filename: filename, mimeType: cleanMIME)
        if let size = values.fileSize, Int64(size) > limit {
            throw AttachmentStoreError.tooLarge(filename: filename, limitBytes: limit)
        }

        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try validateRootDirectory()
        let temporaryURL = rootURL.appending(path: ".ingest-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var shouldRemoveTemporary = true
        defer { if shouldRemoveTemporary { try? fileManager.removeItem(at: temporaryURL) } }

        let input = try FileHandle(forReadingFrom: fileURL)
        let output = try FileHandle(forWritingTo: temporaryURL)
        defer {
            try? input.close()
            try? output.close()
        }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            let chunk = try input.read(upToCount: 256 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            byteCount += Int64(chunk.count)
            guard byteCount <= limit else {
                throw AttachmentStoreError.tooLarge(filename: filename, limitBytes: limit)
            }
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let directory = rootURL.appending(path: String(digest.prefix(2)), directoryHint: .isDirectory)
        let destination = directory.appending(path: digest)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard try isSafeRegularFile(destination) else { throw AttachmentStoreError.corrupt(digest) }
            try fileManager.removeItem(at: temporaryURL)
            shouldRemoveTemporary = false
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
            shouldRemoveTemporary = false
        }

        let mimeType = cleanMIME
            ?? UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return AttachmentMetadata(
            id: digest,
            filename: filename,
            mimeType: mimeType,
            byteCount: byteCount,
            kind: Self.kind(for: mimeType)
        )
    }

    /// Stores already-received bytes using the same content-addressed layout.
    /// This is used by authenticated channel downloads after the connector has
    /// applied its own origin, type, and 25 MB transport limits.
    public func ingest(data: Data, filename: String, declaredMIMEType: String) throws -> AttachmentMetadata {
        let cleanName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeFilename(cleanName) else {
            throw AttachmentStoreError.invalidFilename
        }
        let mimeType = try Self.validatedMIMEType(declaredMIMEType)
        guard let mimeType else { throw AttachmentStoreError.corrupt("missing-mime-type") }
        let limit = AttachmentLimits.byteLimit(filename: cleanName, mimeType: mimeType)
        guard Int64(data.count) <= limit else {
            throw AttachmentStoreError.tooLarge(filename: cleanName, limitBytes: limit)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try validateRootDirectory()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = rootURL.appending(path: String(digest.prefix(2)), directoryHint: .isDirectory)
        let destination = directory.appending(path: digest)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            guard try isSafeRegularFile(destination) else { throw AttachmentStoreError.corrupt(digest) }
        } else {
            let temporary = rootURL.appending(path: ".ingest-data-\(UUID().uuidString)")
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: [.atomic, .completeFileProtectionUnlessOpen])
            do { try fileManager.moveItem(at: temporary, to: destination) }
            catch where fileManager.fileExists(atPath: destination.path) { /* another ingest won the CAS race */ }
        }
        return AttachmentMetadata(
            id: digest,
            filename: cleanName,
            mimeType: mimeType,
            byteCount: Int64(data.count),
            kind: Self.kind(for: mimeType)
        )
    }

    public func data(for metadata: AttachmentMetadata) throws -> Data {
        try validateIdentifier(metadata.id)
        let url = blobURL(id: metadata.id)
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) }
        catch { throw AttachmentStoreError.missing(metadata.id) }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AttachmentStoreError.corrupt(metadata.id) }
        let limit = AttachmentLimits.byteLimit(filename: metadata.filename, mimeType: metadata.mimeType)
        guard metadata.byteCount >= 0, metadata.byteCount <= limit,
              values.fileSize.map(Int64.init) == metadata.byteCount else { throw AttachmentStoreError.corrupt(metadata.id) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == metadata.id, Int64(data.count) == metadata.byteCount else {
            throw AttachmentStoreError.corrupt(metadata.id)
        }
        return data
    }

    /// Installs the exact reviewed snapshot. Descriptor-relative creation never
    /// follows a shard/blob symlink and never overwrites an existing CAS entry.
    /// The caller must reserve quota before entering this synchronous operation.
    public func ingest(prepared: PreparedAgentPublicationFile, createdAt: Date,
        verifiedImageMIMEType: String? = nil) throws -> AttachmentMetadata {
        try Task.checkCancellation()
        let ext = (prepared.filename as NSString).pathExtension.lowercased()
        let inferred = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        // Never promote active document formats or unverified image bytes into
        // an inline renderer merely because their filename has an extension.
        let mime: String
        if let verifiedImageMIMEType {
            guard try AgentImageStore.validatePublishedImage(prepared.bytes) == verifiedImageMIMEType else {
                throw AttachmentStoreError.corrupt("invalid-image-type")
            }
            mime = verifiedImageMIMEType
        } else if inferred.hasPrefix("image/") || ["avif", "ico", "svg"].contains(ext) {
            do {
                mime = try RemoteAttachmentImagePreparation.metadata(for: prepared.bytes,
                    filename: prepared.filename, createdAt: createdAt).mimeType
            } catch is RemoteAttachmentImageError { mime = "application/octet-stream" }
        } else if ["text/html", "application/xhtml+xml"].contains(inferred) {
            mime = "application/octet-stream"
        } else { mime = inferred }
        try Task.checkCancellation()
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let root = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw AttachmentStoreError.corrupt("unsafe-root-directory") }
        defer { Darwin.close(root) }
        let shard = String(prepared.digest.prefix(2))
        guard mkdirat(root, shard, 0o700) == 0 || errno == EEXIST else {
            throw AttachmentStoreError.corrupt("cannot-create-shard")
        }
        let directory = openat(root, shard, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw AttachmentStoreError.corrupt("unsafe-prefix-directory") }
        defer { Darwin.close(directory) }

        func verifyExisting() throws {
            let descriptor = openat(directory, prepared.digest, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw AttachmentStoreError.corrupt(prepared.digest) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_size == prepared.bytes.count else { throw AttachmentStoreError.corrupt(prepared.digest) }
            let bytes = try handle.read(upToCount: prepared.bytes.count + 1) ?? Data()
            guard bytes == prepared.bytes else { throw AttachmentStoreError.corrupt(prepared.digest) }
        }
        var info = stat()
        if fstatat(directory, prepared.digest, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            try verifyExisting()
        } else {
            guard errno == ENOENT else { throw AttachmentStoreError.corrupt(prepared.digest) }
            let name = ".ingest-publication-\(UUID().uuidString)"
            let descriptor = openat(root, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw AttachmentStoreError.corrupt("cannot-create-temporary") }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close(); unlinkat(root, name, 0) }
            try handle.write(contentsOf: prepared.bytes)
            try handle.synchronize()
            try Task.checkCancellation()
            // linkat is exclusive, unlike rename which could replace a winner.
            if linkat(root, name, directory, prepared.digest, 0) != 0 {
                guard errno == EEXIST else { throw AttachmentStoreError.corrupt("cannot-install-blob") }
                try verifyExisting()
            }
            guard fsync(directory) == 0, fsync(root) == 0 else { throw AttachmentStoreError.corrupt("cannot-sync-shard") }
        }
        return .init(id: prepared.digest, filename: prepared.filename, mimeType: mime,
            byteCount: Int64(prepared.bytes.count), kind: Self.kind(for: mime), createdAt: createdAt)
    }

    public func remove(id: String) throws {
        try validateIdentifier(id)
        let url = blobURL(id: id)
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    public func containsActive(id: String) throws -> Bool {
        try validateIdentifier(id)
        return try isSafeRegularFile(blobURL(id: id))
    }

    public func containsQuarantined(id: String) throws -> Bool {
        try validateIdentifier(id)
        return try isSafeRegularFile(quarantineURL(id: id))
    }

    /// Idempotently moves a blob out of the readable CAS namespace.
    public func quarantine(id: String) throws {
        try validateIdentifier(id)
        let source = blobURL(id: id)
        let destination = quarantineURL(id: id)
        if try isSafeRegularFile(destination) {
            if fileManager.fileExists(atPath: source.path) { try fileManager.removeItem(at: source) }
            return
        }
        guard try isSafeRegularFile(source) else { throw AttachmentStoreError.missing(id) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    /// Idempotently restores a quarantined blob when a reference reappears.
    public func restore(id: String) throws {
        try validateIdentifier(id)
        let source = quarantineURL(id: id)
        let destination = blobURL(id: id)
        if try isSafeRegularFile(destination) {
            if fileManager.fileExists(atPath: source.path) { try fileManager.removeItem(at: source) }
            return
        }
        guard try isSafeRegularFile(source) else { throw AttachmentStoreError.missing(id) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    public func deleteQuarantined(id: String) throws {
        try validateIdentifier(id)
        let url = quarantineURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard try isSafeRegularFile(url) else { throw AttachmentStoreError.corrupt(id) }
        try fileManager.removeItem(at: url)
    }

    public func inventory() throws -> AttachmentStoreInventory {
        var active: [String: Int64] = [:]
        var quarantined: [String: Int64] = [:]
        var temporary: [URL] = []
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return .init(active: active, quarantined: quarantined, temporaryFiles: temporary)
        }
        try validateRootDirectory()
        let rootEntries = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        for entry in rootEntries {
            if entry.lastPathComponent.hasPrefix(".ingest-") || entry.lastPathComponent.hasPrefix(".ingest-data-") {
                temporary.append(entry); continue
            }
            if entry.lastPathComponent == "quarantine" {
                try scanCASDirectory(entry, into: &quarantined)
            } else if entry.lastPathComponent.count == 2 {
                try scanPrefixDirectory(entry, into: &active)
            }
        }
        return .init(active: active, quarantined: quarantined, temporaryFiles: temporary)
    }

    public func removeTemporaryFile(_ url: URL) throws {
        let standardizedRoot = rootURL.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(standardizedRoot),
              (url.lastPathComponent.hasPrefix(".ingest-") || url.lastPathComponent.hasPrefix(".ingest-data-")) else {
            throw AttachmentStoreError.corrupt("unsafe-temporary-path")
        }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private func blobURL(id: String) -> URL {
        rootURL.appending(path: String(id.prefix(2)), directoryHint: .isDirectory).appending(path: id)
    }

    private func quarantineURL(id: String) -> URL {
        rootURL.appending(path: "quarantine", directoryHint: .isDirectory)
            .appending(path: String(id.prefix(2)), directoryHint: .isDirectory)
            .appending(path: id)
    }

    private func isSafeRegularFile(_ url: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw AttachmentStoreError.corrupt(url.lastPathComponent) }
        return values.isRegularFile == true
    }

    private func scanCASDirectory(_ directory: URL, into result: inout [String: Int64]) throws {
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw AttachmentStoreError.corrupt("unsafe-quarantine-directory")
        }
        let prefixes = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for prefix in prefixes where prefix.lastPathComponent.count == 2 { try scanPrefixDirectory(prefix, into: &result) }
    }

    private func scanPrefixDirectory(_ directory: URL, into result: inout [String: Int64]) throws {
        let directoryValues = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            throw AttachmentStoreError.corrupt("unsafe-prefix-directory")
        }
        let entries = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        for entry in entries {
            let id = entry.lastPathComponent
            guard id.count == 64, id.hasPrefix(directory.lastPathComponent),
                  id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { continue }
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw AttachmentStoreError.corrupt(id) }
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            result[id] = Int64(size)
        }
    }

    private func validateIdentifier(_ id: String) throws {
        let valid = id.count == 64 && id.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
        if !valid { throw AttachmentStoreError.corrupt(id) }
    }

    private static func kind(for mimeType: String) -> AttachmentKind {
        if mimeType.hasPrefix("image/") { return .image }
        if mimeType.hasPrefix("video/") { return .video }
        if mimeType.hasPrefix("audio/") { return .audio }
        if mimeType.hasPrefix("text/") || mimeType == "application/pdf" { return .document }
        return .other
    }


    private static func isSafeFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.utf8.count <= 255 && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/") && !value.contains("\\")
            && value.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
    }

    private static func validatedMIMEType(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return nil }
        guard clean.utf8.count <= 255, clean.contains("/"),
              clean.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7f }) else {
            throw AttachmentStoreError.corrupt("invalid-mime-type")
        }
        return clean
    }

    private func validateRootDirectory() throws {
        let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw AttachmentStoreError.corrupt("unsafe-root-directory")
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
