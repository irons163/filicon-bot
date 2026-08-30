import Darwin
import Foundation

struct SafeFileSystem: Sendable {
    static let maximumFileBytes = 10 * 1_024 * 1_024

    func canonicalTarget(root: String, relativePath: String) throws -> String {
        let canonicalRoot = try realPath(root)
        let components = try validatedComponents(relativePath)
        return components.reduce(canonicalRoot) { ($0 as NSString).appendingPathComponent($1) }
    }

    func read(root: String, relativePath: String) throws -> Data {
        let (parent, leaf) = try openParent(root: root, relativePath: relativePath)
        defer { Darwin.close(parent) }
        let fd = openat(parent, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw systemError("open read") }
        defer { Darwin.close(fd) }
        try requireRegularFile(fd)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("fstat") }
        guard info.st_size <= Self.maximumFileBytes else { throw LocalToolError.outputLimitExceeded }
        return try readAll(fd: fd, maximum: Self.maximumFileBytes)
    }

    func write(root: String, relativePath: String, data: Data, replace: Bool) throws {
        guard data.count <= Self.maximumFileBytes else { throw LocalToolError.outputLimitExceeded }
        let (parent, leaf) = try openParent(root: root, relativePath: relativePath)
        defer { Darwin.close(parent) }
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | (replace ? O_TRUNC : O_EXCL)
        let fd = openat(parent, leaf, flags, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw systemError("open write") }
        defer { Darwin.close(fd) }
        try requireRegularFile(fd)
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                guard count > 0 else { throw systemError("write") }
                written += count
            }
        }
        guard fsync(fd) == 0 else { throw systemError("fsync") }
    }

    func list(root: String, relativePath: String) throws -> [String] {
        let fd = try openDirectory(root: root, relativePath: relativePath)
        guard let directory = fdopendir(fd) else {
            Darwin.close(fd)
            throw systemError("fdopendir")
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    func openDirectory(root: String, relativePath: String) throws -> Int32 {
        let canonicalRoot = try realPath(root)
        var fd = open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw systemError("open root") }
        do {
            for component in try validatedComponents(relativePath) {
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw systemError("open directory component") }
                Darwin.close(fd)
                fd = next
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func openParent(root: String, relativePath: String) throws -> (Int32, String) {
        var components = try validatedComponents(relativePath)
        guard let leaf = components.popLast() else { throw LocalToolError.invalidRequest("file path is empty") }
        let parent = try openDirectory(root: root, relativePath: components.joined(separator: "/"))
        return (parent, leaf)
    }

    private func validatedComponents(_ path: String) throws -> [String] {
        guard !path.hasPrefix("/"), !path.utf8.contains(0) else { throw LocalToolError.pathEscape }
        if path.isEmpty || path == "." { return [] }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else { throw LocalToolError.pathEscape }
        return components
    }

    private func realPath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw LocalToolError.pathEscape }
        guard let pointer = Darwin.realpath(path, nil) else { throw systemError("realpath") }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func requireRegularFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw systemError("fstat") }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw LocalToolError.unsupportedFileType }
    }

    private func readAll(fd: Int32, maximum: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { return result }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw systemError("read")
            }
            guard result.count + count <= maximum else { throw LocalToolError.outputLimitExceeded }
            result.append(buffer, count: count)
        }
    }

    private func systemError(_ operation: String) -> LocalToolError {
        if errno == ELOOP || errno == ENOTDIR { return .pathEscape }
        return .ioFailure("\(operation): \(String(cString: strerror(errno)))")
    }
}
