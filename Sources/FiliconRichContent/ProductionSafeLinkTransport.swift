#if os(macOS)
import Darwin
import Foundation

/// DNS resolver used by the production link-preview client. The lookup has a hard deadline and
/// cancellation returns immediately even though the system `getaddrinfo` call itself is blocking.
public struct MacOSSafeLinkResolver: SafeLinkResolving, Sendable {
    public var timeout: Duration

    public init(timeout: Duration = .seconds(3)) { self.timeout = timeout }

    public func resolve(host: String) async throws -> [ResolvedAddress] {
        guard timeout > .zero else { throw SafeLinkError.invalidPolicy }
        let cancellation = ResolutionCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = ResolutionGate(continuation)
                cancellation.install(gate)
                Task.detached(priority: .utility) {
                    do { gate.resume(with: .success(try Self.lookup(host))) }
                    catch { gate.resume(with: .failure(error)) }
                }
                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                        gate.resume(with: .failure(SafeLinkError.timeout))
                    } catch {}
                }
                if Task.isCancelled { gate.resume(with: .failure(CancellationError())) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func lookup(_ host: String) throws -> [ResolvedAddress] {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var head: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &head) == 0, let head else { throw SafeLinkError.resolutionFailed }
        defer { freeaddrinfo(head) }
        var result: [ResolvedAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor?.pointee {
            if entry.ai_family == AF_INET, let pointer = entry.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
                var address = pointer.pointee.sin_addr
                result.append(.init(family: .ipv4, bytes: withUnsafeBytes(of: &address) { Array($0) }))
            } else if entry.ai_family == AF_INET6, let pointer = entry.ai_addr?.withMemoryRebound(to: sockaddr_in6.self, capacity: 1, { $0 }) {
                var address = pointer.pointee.sin6_addr
                result.append(.init(family: .ipv6, bytes: withUnsafeBytes(of: &address) { Array($0) }))
            }
            cursor = entry.ai_next
        }
        guard !result.isEmpty else { throw SafeLinkError.resolutionFailed }
        // Match the reconstructed production behavior: prefer an IPv4 pin, then IPv6.
        return result.filter { $0.family == .ipv4 } + result.filter { $0.family == .ipv6 }
    }
}

private final class ResolutionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var gate: ResolutionGate?
    private var cancelled = false
    func install(_ value: ResolutionGate) {
        lock.lock()
        gate = value
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { value.resume(with: .failure(CancellationError())) }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let value = gate
        lock.unlock()
        value?.resume(with: .failure(CancellationError()))
    }
}

private final class ResolutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[ResolvedAddress], Error>?

    init(_ continuation: CheckedContinuation<[ResolvedAddress], Error>) { self.continuation = continuation }
    func resume(with result: Result<[ResolvedAddress], Error>) {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        value?.resume(with: result)
    }
}

public struct SafeLinkProcessInvocation: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let maximumStandardOutputBytes: Int
    public let maximumStandardErrorBytes: Int
    public let timeout: Duration

    public init(executableURL: URL, arguments: [String], environment: [String: String], maximumStandardOutputBytes: Int,
                maximumStandardErrorBytes: Int, timeout: Duration) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.maximumStandardOutputBytes = maximumStandardOutputBytes
        self.maximumStandardErrorBytes = maximumStandardErrorBytes
        self.timeout = timeout
    }
}

public struct SafeLinkProcessResult: Sendable, Equatable {
    public let standardOutput: Data
    public let standardError: Data
    public let terminationStatus: Int32

    public init(standardOutput: Data, standardError: Data, terminationStatus: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.terminationStatus = terminationStatus
    }
}

public protocol SafeLinkProcessRunning: Sendable {
    func run(_ invocation: SafeLinkProcessInvocation) async throws -> SafeLinkProcessResult
}

/// Foundation process runner with bounded pipes, timeout, and cooperative task cancellation.
public struct FoundationSafeLinkProcessRunner: SafeLinkProcessRunning, Sendable {
    public init() {}

    public func run(_ invocation: SafeLinkProcessInvocation) async throws -> SafeLinkProcessResult {
        guard !Task.isCancelled else { throw SafeLinkError.cancelled }
        guard invocation.maximumStandardOutputBytes >= 0,
              invocation.maximumStandardErrorBytes >= 0,
              invocation.timeout > .zero else { throw SafeLinkError.transportFailure }
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardOutput = stdout
        process.standardError = stderr
        // Register before launch: a short-lived process may exit before any task starts
        // awaiting its status. AsyncStream buffers that exit without blocking a Swift
        // cooperative worker in Foundation's waitUntilExit run loop.
        let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { terminated in
            exitContinuation.yield(terminated.terminationStatus)
            exitContinuation.finish()
        }
        let state = ProcessState(process)
        defer { exitContinuation.finish() }
        do { try process.run() } catch { throw SafeLinkError.transportFailure }

        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: ProcessPart.self) { group in
                    group.addTask {
                        do { return .stdout(try await Self.readPipe(stdout.fileHandleForReading, limit: invocation.maximumStandardOutputBytes)) }
                        catch { state.terminate(); throw error }
                    }
                    group.addTask {
                        do { return .stderr(try await Self.readPipe(stderr.fileHandleForReading, limit: invocation.maximumStandardErrorBytes)) }
                        catch { state.terminate(); throw error }
                    }
                    group.addTask {
                        try await Task.sleep(for: invocation.timeout)
                        state.terminate()
                        throw SafeLinkError.timeout
                    }
                    group.addTask {
                        for await status in exits { return .status(status) }
                        throw CancellationError()
                    }
                    var output: Data?, errorOutput: Data?, status: Int32?
                    while let part = try await group.next() {
                        switch part {
                        case .stdout(let data): output = data
                        case .stderr(let data): errorOutput = data
                        case .status(let value): status = value
                        }
                        if output != nil, errorOutput != nil, status != nil {
                            group.cancelAll()
                            return .init(standardOutput: output!, standardError: errorOutput!, terminationStatus: status!)
                        }
                    }
                    throw SafeLinkError.transportFailure
                }
            } catch {
                state.terminate()
                if error is CancellationError { throw SafeLinkError.cancelled }
                throw error
            }
        } onCancel: { state.terminate() }
    }

    private static func readPipe(_ handle: FileHandle, limit: Int) async throws -> Data {
        // Pipe reads are blocking syscalls, not asynchronous Swift work. Keep both
        // drains off the cooperative executor so exit and timeout tasks can run.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try read(handle, limit: limit)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func read(_ handle: FileHandle, limit: Int) throws -> Data {
        defer { try? handle.close() }
        var data = Data()
        while true {
            let chunk = try handle.read(upToCount: min(16_383, limit - data.count) + 1) ?? Data()
            if chunk.isEmpty { return data }
            data.append(chunk)
            if data.count > limit { throw SafeLinkError.responseTooLarge }
        }
    }
}

private enum ProcessPart: @unchecked Sendable {
    case stdout(Data), stderr(Data), status(Int32)
}

private final class ProcessState: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    init(_ process: Process) { self.process = process }
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        if process.isRunning { process.terminate() }
    }
}

public struct CurlSafeLinkTransportPolicy: Sendable, Equatable {
    public var connectTimeout: Duration = .seconds(3)
    public var requestTimeout: Duration = .seconds(8)
    public var maximumHeaderBytes = 64 * 1024
    public var maximumMetadataBytes = 16 * 1024
    public var userAgent = "Filicon-LinkPreview/1.0"
    public init() {}
}

/// A single-hop transport backed by the system curl. Each attempt is pinned with `--resolve`,
/// proxy discovery and curl config are disabled, redirects are not followed, and curl's actual
/// remote peer is checked against the selected pin before any response is accepted.
public struct CurlSafeLinkTransport: SafeLinkTransporting, Sendable {
    public let supportsAddressPinning = true
    private let runner: any SafeLinkProcessRunning
    private let policy: CurlSafeLinkTransportPolicy
    private let executableURL: URL
    private static let marker = "FILICON_CURL_WRITE_OUT_V1:"

    public init(runner: any SafeLinkProcessRunning = FoundationSafeLinkProcessRunner(),
                policy: CurlSafeLinkTransportPolicy = .init(), executableURL: URL = URL(fileURLWithPath: "/usr/bin/curl")) {
        self.runner = runner
        self.policy = policy
        self.executableURL = executableURL
    }

    public func send(_ request: SafeLinkRequest) async throws -> SafeLinkResponse {
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        guard request.maximumBodyBytes > 0, policy.maximumHeaderBytes > 0, policy.maximumMetadataBytes > 0,
              policy.connectTimeout > .zero, policy.requestTimeout > .zero,
              let scheme = components?.scheme?.lowercased(), scheme == "https",
              components?.user == nil, components?.password == nil,
              let host = request.url.host(percentEncoded: false), !host.isEmpty, let port = Self.port(for: request.url),
              let address = request.approvedAddresses.first, SafeLinkMetadataClient.isPublic(address),
              policy.userAgent.utf8.count <= 256,
              !policy.userAgent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw SafeLinkError.invalidPolicy }
        do {
            try Task.checkCancellation()
            guard let textAddress = Self.text(address) else { throw SafeLinkError.malformedResponse }
            let pinned = address.family == .ipv6 ? "[\(textAddress)]" : textAddress
            let resolve = "\(host):\(port):\(pinned)"
            // The wildcard connect mapping prevents a hostname-normalization mismatch in --resolve
            // from ever falling back to curl's own DNS. There is one URL and redirects are disabled.
            let connectTo = "::\(pinned):\(port)"
            let seconds = Self.seconds(policy.requestTimeout)
            let connectSeconds = Self.seconds(policy.connectTimeout)
            let arguments = [
                "--disable", "--silent", "--show-error", "--request", "GET",
                "--noproxy", "*", "--max-redirs", "0", "--proto", "=https",
                "--connect-timeout", connectSeconds, "--max-time", seconds,
                "--max-filesize", String(request.maximumBodyBytes),
                "--header", "Accept: text/html,application/xhtml+xml;q=0.9",
                "--header", "Accept-Encoding: identity", "--header", "Connection: close",
                "--user-agent", policy.userAgent, "--resolve", resolve, "--connect-to", connectTo,
                "--write-out", "%{stderr}\(Self.marker)%{http_code}\\n%{remote_ip}\\n%{content_type}\\n%{redirect_url}\\n%{size_download}\\n%{size_header}",
                "--", request.url.absoluteString,
            ]
            let invocation = SafeLinkProcessInvocation(
                executableURL: executableURL, arguments: arguments, environment: ["LC_ALL": "C"],
                maximumStandardOutputBytes: request.maximumBodyBytes,
                maximumStandardErrorBytes: policy.maximumMetadataBytes, timeout: policy.requestTimeout + .seconds(1)
            )
            let result = try await runner.run(invocation)
            // curl 63 means its max-filesize guard fired. Curl 28 is its own transfer deadline.
            if result.terminationStatus == 63 { throw SafeLinkError.responseTooLarge }
            if result.terminationStatus == 28 { throw SafeLinkError.timeout }
            guard result.terminationStatus == 0 else { throw SafeLinkError.transportFailure }
            let metadata = try Self.parseMetadata(result.standardError)
            guard let peer = SafeLinkMetadataClient.parseIPAddress(metadata.remoteIP), peer == address else {
                throw SafeLinkError.connectedAddressMismatch
            }
            if result.standardOutput.count > request.maximumBodyBytes || metadata.sizeDownload > Int64(request.maximumBodyBytes) {
                throw SafeLinkError.responseTooLarge
            }
            guard metadata.sizeHeader <= Int64(policy.maximumHeaderBytes) else { throw SafeLinkError.responseTooLarge }
            var headers: [String: String] = [:]
            if !metadata.contentType.isEmpty { headers["Content-Type"] = metadata.contentType }
            if !metadata.redirectURL.isEmpty { headers["Location"] = metadata.redirectURL }
            guard (100...599).contains(metadata.httpCode) else { throw SafeLinkError.malformedResponse }
            return .init(statusCode: metadata.httpCode, headers: headers, body: result.standardOutput, connectedAddress: peer)
        } catch is CancellationError { throw SafeLinkError.cancelled }
        catch let error as SafeLinkError { throw error }
        catch { throw SafeLinkError.transportFailure }
    }

    private struct WriteOut {
        let httpCode: Int
        let remoteIP: String
        let contentType: String
        let redirectURL: String
        let sizeDownload: Int64
        let sizeHeader: Int64
    }

    private static func parseMetadata(_ data: Data) throws -> WriteOut {
        guard data.count <= 16 * 1024 * 1024, let markerData = marker.data(using: .utf8),
              let range = data.range(of: markerData, options: .backwards), range.upperBound < data.endIndex else {
            throw SafeLinkError.malformedResponse
        }
        let payload = data[range.upperBound...]
        guard let text = String(data: payload, encoding: .utf8) else { throw SafeLinkError.malformedResponse }
        let fields = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6, let status = Int(fields[0]), let size = Int64(fields[4]), size >= 0,
              let headerSize = Int64(fields[5]), headerSize >= 0,
              !fields[1].isEmpty, fields[2].utf8.count <= 1_024, fields[3].utf8.count <= 8_192 else {
            throw SafeLinkError.malformedResponse
        }
        return WriteOut(httpCode: status, remoteIP: fields[1], contentType: fields[2], redirectURL: fields[3], sizeDownload: size, sizeHeader: headerSize)
    }

    private static func port(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() { case "http": return 80; case "https": return 443; default: return nil }
    }

    private static func text(_ address: ResolvedAddress) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch address.family {
        case .ipv4:
            guard address.bytes.count == 4 else { return nil }
            var value = in_addr()
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: address.bytes) }
            guard inet_ntop(AF_INET, &value, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        case .ipv6:
            guard address.bytes.count == 16 else { return nil }
            var value = in6_addr()
            withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: address.bytes) }
            guard inet_ntop(AF_INET6, &value, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }

    private static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.3f", max(value, 0.001))
    }
}

public extension SafeLinkMetadataClient {
    static func production(policy: SafeLinkPolicy = .init(), resolverTimeout: Duration = .seconds(3),
                           transportPolicy: CurlSafeLinkTransportPolicy = .init()) -> SafeLinkMetadataClient {
        SafeLinkMetadataClient(resolver: MacOSSafeLinkResolver(timeout: resolverTimeout),
                               transport: CurlSafeLinkTransport(policy: transportPolicy), policy: policy)
    }
}
#endif
