import Darwin
import Foundation

public protocol AutoReviewInstructionsStore: Sendable {
    func load() throws -> AutoReviewInstructions
    func save(_ instructions: AutoReviewInstructions) throws
}

public enum AutoReviewInstructionsStoreError: LocalizedError, Equatable, Sendable {
    case unsafePath
    case io(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsafePath: "The auto-review settings path is not a regular file."
        case .io(let code): "Auto-review settings I/O failed with errno \(code)."
        }
    }
}

/// JSON persistence with same-directory atomic rename, fsync, and owner-only
/// permissions. Existing legacy keys are migrated by `AutoReviewInstructions`.
public struct AtomicAutoReviewInstructionsStore: AutoReviewInstructionsStore {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL.standardizedFileURL }

    public func load() throws -> AutoReviewInstructions {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        try validateRegularFileIfPresent()
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return try JSONDecoder().decode(AutoReviewInstructions.self, from: data)
    }

    public func save(_ instructions: AutoReviewInstructions) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try validateRegularFileIfPresent()

        let data = try JSONEncoder().encode(instructions)
        let temporary = directory.appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw AutoReviewInstructionsStoreError.io(errno) }
        var shouldRemove = true
        defer {
            Darwin.close(fd)
            if shouldRemove { Darwin.unlink(temporary.path) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                guard count >= 0 else {
                    if errno == EINTR { continue }
                    throw AutoReviewInstructionsStoreError.io(errno)
                }
                written += count
            }
        }
        guard Darwin.fsync(fd) == 0 else { throw AutoReviewInstructionsStoreError.io(errno) }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw AutoReviewInstructionsStoreError.io(errno)
        }
        shouldRemove = false
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let directoryFD = Darwin.open(directory.path, O_RDONLY)
        if directoryFD >= 0 { _ = Darwin.fsync(directoryFD); Darwin.close(directoryFD) }
    }

    private func validateRegularFileIfPresent() throws {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw AutoReviewInstructionsStoreError.io(errno)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AutoReviewInstructionsStoreError.unsafePath
        }
    }
}
