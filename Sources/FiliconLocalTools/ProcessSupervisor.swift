import Darwin
import Foundation

actor LocalProcessSupervisor {
    static let maximumOutputBytes = 10 * 1_024 * 1_024

    private struct Session {
        let id: UUID
        let pid: pid_t
        let generation: UUID
        let runID: UUID
        let stdinFD: Int32
        let stdout: FileHandle
        let stderr: FileHandle
        var output = Data()
        var exitStatus: Int32?
        var truncated = false
        var terminationError: LocalToolError?
        var timeout: Task<Void, Never>?
    }

    private var sessions: [UUID: Session] = [:]
    private let fileSystem = SafeFileSystem()

    func start(_ command: LocalCommand, scope: LocalRequestScope) throws -> LocalProcessSnapshot {
        guard !command.executable.isEmpty, command.timeoutMilliseconds > 0 else {
            throw LocalToolError.invalidRequest("invalid command or timeout")
        }
        let executable = try executableRealPath(command.executable)
        let cwdFD = try fileSystem.openDirectory(root: command.workingDirectoryRoot, relativePath: command.workingDirectory)
        defer { Darwin.close(cwdFD) }
        let cwd = try pathForFD(cwdFD)

        var stdinPipe = [Int32](repeating: -1, count: 2)
        var stdoutPipe = [Int32](repeating: -1, count: 2)
        var stderrPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            closePipes([stdinPipe, stdoutPipe, stderrPipe]); throw systemError("pipe")
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdinPipe[1])
        posix_spawn_file_actions_addclose(&actions, stdoutPipe[0])
        posix_spawn_file_actions_addclose(&actions, stderrPipe[0])
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)

        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        for (key, value) in command.environment {
            guard !key.isEmpty, !key.contains("="), !key.utf8.contains(0), !value.utf8.contains(0) else {
                closePipes([stdinPipe, stdoutPipe, stderrPipe]); throw LocalToolError.invalidRequest("invalid environment")
            }
            environment[key] = value
        }
        let argv = [executable] + command.arguments
        guard argv.allSatisfy({ !$0.utf8.contains(0) }) else {
            closePipes([stdinPipe, stdoutPipe, stderrPipe]); throw LocalToolError.invalidRequest("NUL in argv")
        }
        let env = environment.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawnResult = withCStringArray(argv) { argvPointer in
            withCStringArray(env) { envPointer in
                posix_spawn(&pid, executable, &actions, &attributes, argvPointer, envPointer)
            }
        }
        Darwin.close(stdinPipe[0]); Darwin.close(stdoutPipe[1]); Darwin.close(stderrPipe[1])
        guard spawnResult == 0 else {
            Darwin.close(stdinPipe[1]); Darwin.close(stdoutPipe[0]); Darwin.close(stderrPipe[0])
            throw LocalToolError.ioFailure("posix_spawn: \(String(cString: strerror(spawnResult)))")
        }

        let id = UUID()
        let stdout = FileHandle(fileDescriptor: stdoutPipe[0], closeOnDealloc: true)
        let stderr = FileHandle(fileDescriptor: stderrPipe[0], closeOnDealloc: true)
        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await self?.append(data, sessionID: id) } }
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await self?.append(data, sessionID: id) } }
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(command.timeoutMilliseconds))
            guard !Task.isCancelled else { return }
            await self?.timeout(sessionID: id)
        }
        sessions[id] = Session(id: id, pid: pid, generation: scope.generation, runID: scope.runID, stdinFD: stdinPipe[1], stdout: stdout, stderr: stderr, timeout: timeout)
        Task.detached { [weak self] in
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            await self?.didExit(sessionID: id, status: status)
        }
        return snapshot(sessions[id]!, offset: 0)
    }

    func read(sessionID: UUID, offset: Int, generation: UUID) throws -> LocalProcessSnapshot {
        guard let session = sessions[sessionID] else { throw LocalToolError.processNotFound }
        guard session.generation == generation else { throw LocalToolError.staleGeneration }
        guard offset >= 0, offset <= session.output.count else { throw LocalToolError.invalidRequest("invalid output offset") }
        return snapshot(session, offset: offset)
    }

    func sendInput(sessionID: UUID, data: Data, closeAfterWrite: Bool, generation: UUID) throws {
        guard var session = sessions[sessionID] else { throw LocalToolError.processNotFound }
        guard session.generation == generation else { throw LocalToolError.staleGeneration }
        guard session.exitStatus == nil, session.stdinFD >= 0 else { throw LocalToolError.processExited }
        var failure: LocalToolError?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(session.stdinFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    failure = systemError("stdin write"); return
                }
                offset += count
            }
        }
        if let failure { throw failure }
        if closeAfterWrite {
            Darwin.close(session.stdinFD)
            session = Session(id: session.id, pid: session.pid, generation: session.generation, runID: session.runID, stdinFD: -1, stdout: session.stdout, stderr: session.stderr, output: session.output, exitStatus: session.exitStatus, truncated: session.truncated, terminationError: session.terminationError, timeout: session.timeout)
            sessions[sessionID] = session
        }
    }

    func terminate(sessionID: UUID, generation: UUID) throws {
        guard let session = sessions[sessionID] else { throw LocalToolError.processNotFound }
        guard session.generation == generation else { throw LocalToolError.staleGeneration }
        terminateGroup(session.pid, sessionID: session.id)
    }

    func cancel(runID: UUID, generation: UUID) {
        for session in sessions.values where session.runID == runID && session.generation == generation && session.exitStatus == nil {
            terminateGroup(session.pid, sessionID: session.id)
        }
    }

    private func append(_ data: Data, sessionID: UUID) {
        guard var session = sessions[sessionID], !session.truncated else { return }
        let remaining = Self.maximumOutputBytes - session.output.count
        if data.count > remaining {
            session.output.append(data.prefix(max(0, remaining)))
            session.truncated = true
            session.terminationError = .outputLimitExceeded
            sessions[sessionID] = session
            terminateGroup(session.pid, sessionID: session.id)
        } else {
            session.output.append(data)
            sessions[sessionID] = session
        }
    }

    private func timeout(sessionID: UUID) {
        guard var session = sessions[sessionID], session.exitStatus == nil else { return }
        session.terminationError = .timedOut
        sessions[sessionID] = session
        terminateGroup(session.pid, sessionID: session.id)
    }

    private func didExit(sessionID: UUID, status: Int32) {
        guard var session = sessions[sessionID] else { return }
        session.timeout?.cancel()
        session.stdout.readabilityHandler = nil
        session.stderr.readabilityHandler = nil
        if session.stdinFD >= 0 { Darwin.close(session.stdinFD) }
        let signal = status & 0x7f
        session.exitStatus = signal == 0 ? ((status >> 8) & 0xff) : -signal
        session.timeout = nil
        sessions[sessionID] = session
    }

    private func terminateGroup(_ pid: pid_t, sessionID: UUID) {
        guard pid > 0 else { return }
        _ = kill(-pid, SIGTERM)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await self?.forceKill(sessionID: sessionID, expectedPID: pid)
        }
    }

    private func forceKill(sessionID: UUID, expectedPID: pid_t) {
        guard let session = sessions[sessionID], session.pid == expectedPID, session.exitStatus == nil else { return }
        _ = kill(-expectedPID, SIGKILL)
    }

    private func snapshot(_ session: Session, offset: Int) -> LocalProcessSnapshot {
        LocalProcessSnapshot(sessionID: session.id, processID: session.pid, output: session.output.suffix(from: offset), nextOffset: session.output.count, isRunning: session.exitStatus == nil, exitStatus: session.exitStatus, truncated: session.truncated, terminationError: session.terminationError)
    }

    private func executableRealPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), let pointer = realpath(path, nil) else { throw LocalToolError.pathEscape }
        defer { free(pointer) }
        let resolved = String(cString: pointer)
        var info = stat()
        guard lstat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(resolved, X_OK) == 0 else { throw LocalToolError.unsupportedFileType }
        return resolved
    }

    private func pathForFD(_ fd: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { throw systemError("F_GETPATH") }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private func closePipes(_ pipes: [[Int32]]) {
        for fd in pipes.flatMap({ $0 }) where fd >= 0 { Darwin.close(fd) }
    }

    private func systemError(_ operation: String) -> LocalToolError {
        .ioFailure("\(operation): \(String(cString: strerror(errno)))")
    }
}

private func withCStringArray<R>(_ strings: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    let storage = strings.map { strdup($0) }
    defer { storage.forEach { free($0) } }
    var pointers = storage + [nil]
    return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
}
