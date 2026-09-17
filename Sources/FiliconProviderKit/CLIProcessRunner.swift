import Foundation

public struct CLIProcessRequest: Sendable, Equatable {
    public var executableURL: URL
    public var arguments: [String]
    public var standardInput: Data
    public var maximumOutputBytes: Int
    public var workingDirectoryURL: URL?

    public init(executableURL: URL, arguments: [String], standardInput: Data,
                maximumOutputBytes: Int = 8 * 1_024 * 1_024, workingDirectoryURL: URL? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.maximumOutputBytes = maximumOutputBytes
        self.workingDirectoryURL = workingDirectoryURL
    }
}

public enum CLIProcessEvent: Sendable, Equatable {
    case standardOutput(Data)
}

public struct CLIProcessFailure: LocalizedError, Sendable, Equatable {
    public var exitCode: Int32
    public var standardError: String
    public var errorDescription: String? {
        let detail = standardError.isEmpty ? "no diagnostic output" : standardError
        return "CLI exited with status \(exitCode): \(detail)"
    }
    public init(exitCode: Int32, standardError: String) {
        self.exitCode = exitCode; self.standardError = standardError
    }
}

public protocol CLIProcessRunning: Sendable {
    func events(for request: CLIProcessRequest) -> AsyncThrowingStream<CLIProcessEvent, Error>
    func events(for request: CLIProcessRequest, input: AsyncStream<Data>) -> AsyncThrowingStream<CLIProcessEvent, Error>
}

public extension CLIProcessRunning {
    func events(for request: CLIProcessRequest, input: AsyncStream<Data>) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.transport("Interactive CLI transport is unavailable.")) }
    }
}

/// Launches an executable directly. It never invokes a shell and never inspects another
/// application's credential files; authentication remains entirely owned by the CLI.
public struct FoundationCLIProcessRunner: CLIProcessRunning {
    public init() {}

    public func events(for request: CLIProcessRequest) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        let input = AsyncStream<Data> { continuation in
            continuation.yield(request.standardInput)
            continuation.finish()
        }
        return events(for: request, input: input)
    }

    public func events(for request: CLIProcessRequest, input: AsyncStream<Data>) -> AsyncThrowingStream<CLIProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            let state = ProcessState(process: process, limit: request.maximumOutputBytes, continuation: continuation)

            process.executableURL = request.executableURL
            process.arguments = request.arguments
            process.currentDirectoryURL = request.workingDirectoryURL
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.streamClosed(stdout: true)
                } else { state.receiveStdout(data) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    state.streamClosed(stdout: false)
                } else { state.receiveStderr(data) }
            }
            process.terminationHandler = { terminated in
                state.processExited(terminated.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                state.fail(error)
            }
            let writer = Task {
                do {
                    for await data in input {
                        try Task.checkCancellation()
                        try stdin.fileHandleForWriting.write(contentsOf: data)
                    }
                    try stdin.fileHandleForWriting.close()
                } catch { state.fail(error) }
            }
            continuation.onTermination = { @Sendable _ in
                writer.cancel()
                state.cancel()
            }
        }
    }
}

private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let limit: Int
    private let continuation: AsyncThrowingStream<CLIProcessEvent, Error>.Continuation
    private var outputCount = 0
    private var errorData = Data()
    private var finished = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exitCode: Int32?

    init(process: Process, limit: Int, continuation: AsyncThrowingStream<CLIProcessEvent, Error>.Continuation) {
        self.process = process; self.limit = max(1, limit); self.continuation = continuation
    }

    func receiveStdout(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        outputCount += data.count
        if outputCount > limit {
            finished = true
            lock.unlock()
            terminate()
            continuation.finish(throwing: ProviderError.transport("CLI output exceeded \(limit) bytes"))
            return
        }
        lock.unlock()
        continuation.yield(.standardOutput(data))
    }

    func receiveStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, errorData.count < 64 * 1_024 else { return }
        errorData.append(data.prefix(64 * 1_024 - errorData.count))
    }

    func streamClosed(stdout: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if stdout { stdoutClosed = true } else { stderrClosed = true }
        let completion = takeCompletionIfReady()
        lock.unlock()
        complete(completion)
    }

    func processExited(_ code: Int32) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        exitCode = code
        let completion = takeCompletionIfReady()
        lock.unlock()
        complete(completion)
    }

    private func takeCompletionIfReady() -> (Int32, String)? {
        guard stdoutClosed, stderrClosed, let exitCode else { return nil }
        finished = true
        let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (exitCode, message)
    }

    private func complete(_ completion: (Int32, String)?) {
        guard let (exitCode, message) = completion else { return }
        if exitCode == 0 { continuation.finish() }
        else { continuation.finish(throwing: CLIProcessFailure(exitCode: exitCode, standardError: message)) }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        terminate()
        continuation.finish(throwing: error)
    }

    func cancel() {
        lock.lock()
        let shouldTerminate = !finished
        finished = true
        lock.unlock()
        if shouldTerminate { terminate() }
    }

    private func terminate() {
        if process.isRunning { process.terminate() }
    }
}

public enum CLIExecutableDiscovery {
    public static func find(_ name: String, knownPaths: [String],
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let manager = FileManager.default
        var candidates = knownPaths
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { String($0) + "/" + name }
        }
        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            if manager.isExecutableFile(atPath: expanded) { return URL(fileURLWithPath: expanded) }
        }
        return nil
    }
}
