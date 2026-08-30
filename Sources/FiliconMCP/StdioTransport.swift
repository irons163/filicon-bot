import Foundation

public typealias MCPSecretResolver = @Sendable (String) async throws -> String

public actor MCPStdioTransport: MCPTransport {
    public static let maximumMessageBytes = 4 * 1_024 * 1_024
    public static let maximumStderrBytes = 64 * 1_024

    private struct Pending {
        let continuation: CheckedContinuation<MCPRPCResponse, any Error>
        let timeout: Task<Void, Never>
    }

    private let executable: String
    private let arguments: [String]
    private let environmentReferences: [String: String]
    private let workingDirectory: String?
    private let resolver: MCPSecretResolver
    private var process: Process?
    private var input: FileHandle?
    private var stdout = Data()
    private var stderr = Data()
    private var pending: [Int: Pending] = [:]
    private var closed = false

    public init(executable: String, arguments: [String] = [], environmentReferences: [String: String] = [:], workingDirectory: String? = nil, secretResolver: @escaping MCPSecretResolver = { _ in throw MCPError.unavailable("Secret resolver is not configured.") }) {
        self.executable = executable; self.arguments = arguments; self.environmentReferences = environmentReferences; self.workingDirectory = workingDirectory; self.resolver = secretResolver
    }

    public func request(_ request: MCPRPCRequest, timeout: Duration = .seconds(30)) async throws -> MCPRPCResponse {
        try Task.checkCancellation()
        try await startIfNeeded()
        let line = try encodeLine(request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPRPCResponse, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: MCPError.cancelled); return }
                guard pending[request.id] == nil else { continuation.resume(throwing: MCPError.malformedMessage("duplicate request id")); return }
                let timer = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.failRequest(request.id, error: .timeout, terminate: true)
                }
                pending[request.id] = Pending(continuation: continuation, timeout: timer)
                do { try input?.write(contentsOf: line + Data([0x0A])) }
                catch { failRequest(request.id, error: .unavailable(error.localizedDescription), terminate: true) }
            }
        } onCancel: {
            Task { await self.cancelRequest(request.id) }
        }
    }

    public func notify(_ notification: MCPRPCNotification) async throws {
        try await startIfNeeded(); let line = try encodeLine(notification)
        try input?.write(contentsOf: line + Data([0x0A]))
    }

    public func close() async { terminate(error: .cancelled) }
    public func boundedStderr() -> String { String(decoding: stderr, as: UTF8.self) }

    private func startIfNeeded() async throws {
        if process?.isRunning == true { return }
        guard !closed else { throw MCPError.unavailable("MCP transport is closed.") }
        var environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        for (name, reference) in environmentReferences { environment[name] = try await resolver(reference) }
        let process = Process(), stdin = Pipe(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true) }
        process.standardInput = stdin; process.standardOutput = out; process.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await self?.consumeStdout(data) } }
        }
        err.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await self?.consumeStderr(data) } }
        }
        process.terminationHandler = { [weak self] process in Task { await self?.processEnded(process.terminationStatus) } }
        do { try process.run() } catch { throw MCPError.unavailable(error.localizedDescription) }
        self.process = process; input = stdin.fileHandleForWriting
    }

    private func consumeStdout(_ data: Data) {
        stdout.append(data)
        if stdout.count > Self.maximumMessageBytes { terminate(error: .outputLimitExceeded); return }
        while let newline = stdout.firstIndex(of: 0x0A) {
            var line = stdout[..<newline]; stdout.removeSubrange(...newline)
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            do {
                let response = try JSONDecoder().decode(MCPRPCResponse.self, from: Data(line))
                guard response.jsonrpc == "2.0", let id = response.id, (response.result == nil) != (response.error == nil), let item = pending.removeValue(forKey: id) else { throw MCPError.malformedMessage("invalid or uncorrelated JSON-RPC response") }
                item.timeout.cancel(); item.continuation.resume(returning: response)
            } catch let error as MCPError { terminate(error: error); return }
            catch { terminate(error: .malformedMessage(error.localizedDescription)); return }
        }
    }

    private func consumeStderr(_ data: Data) {
        if data.count >= Self.maximumStderrBytes { stderr = data.suffix(Self.maximumStderrBytes) }
        else { stderr.append(data); if stderr.count > Self.maximumStderrBytes { stderr.removeFirst(stderr.count - Self.maximumStderrBytes) } }
    }

    private func cancelRequest(_ id: Int) {
        guard pending[id] != nil else { return }
        let notification = MCPRPCNotification(method: "notifications/cancelled", params: .object(["requestId": .number(Double(id)), "reason": .string("Client cancelled request")]))
        if let line = try? encodeLine(notification) { try? input?.write(contentsOf: line + Data([0x0A])) }
        failRequest(id, error: .cancelled, terminate: true)
    }

    private func failRequest(_ id: Int, error: MCPError, terminate shouldTerminate: Bool) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.timeout.cancel(); item.continuation.resume(throwing: error)
        if shouldTerminate { terminate(error: error) }
    }

    private func processEnded(_ status: Int32) { if process != nil { terminate(error: .processExited(status)) } }

    private func terminate(error: MCPError) {
        let items = pending.values; pending.removeAll()
        for item in items { item.timeout.cancel(); item.continuation.resume(throwing: error) }
        input?.closeFile(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; stdout.removeAll(); closed = true
    }
}
