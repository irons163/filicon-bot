import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FiliconDomain

/// An opaque lookup key for a bearer credential. The secret itself is deliberately not part of
/// cloud-agent configuration, persisted run state, requests, or diagnostics.
public struct CloudAgentBearerReference: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 256 else { return nil }
        self.rawValue = value
    }
}

public protocol CloudAgentBearerProvider: Sendable {
    func bearer(for reference: CloudAgentBearerReference) async throws -> String?
}

public struct CloudAgentEndpoint: Hashable, Sendable {
    public let url: URL

    public init(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.pathComponents.contains("..") else {
            throw CloudAgentError.invalidEndpoint
        }
        self.url = url
    }
}

public struct CloudAgentDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String?
    public let status: CloudAgentAvailability

    public init(id: String, name: String, summary: String? = nil, status: CloudAgentAvailability = .available) {
        self.id = id; self.name = name; self.summary = summary; self.status = status
    }
}

public enum CloudAgentAvailability: String, Codable, Hashable, Sendable {
    case available, busy, offline
}

public enum CloudAgentRemoteStatus: String, Codable, Hashable, Sendable {
    case queued, running, awaitingInput = "awaiting_input", succeeded, failed, cancelled

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
}

public struct CloudAgentRemoteRun: Codable, Hashable, Sendable {
    public let id: String
    public let agentID: String
    public let status: CloudAgentRemoteStatus
    public let revision: UInt64
    public let output: String?
    public let error: String?
    public let usage: Usage?

    public init(id: String, agentID: String, status: CloudAgentRemoteStatus, revision: UInt64,
                output: String? = nil, error: String? = nil, usage: Usage? = nil) {
        self.id = id; self.agentID = agentID; self.status = status; self.revision = revision
        self.output = output; self.error = error; self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case id, agentID = "agent_id", status, revision, output, error, usage
    }
}

public struct CloudAgentHTTPRequest: Sendable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }
    public let method: Method
    public let url: URL
    public let bearerReference: CloudAgentBearerReference?
    public let idempotencyKey: UUID?
    public let body: Data?

    public init(method: Method, url: URL, bearerReference: CloudAgentBearerReference? = nil,
                idempotencyKey: UUID? = nil, body: Data? = nil) {
        self.method = method; self.url = url; self.bearerReference = bearerReference
        self.idempotencyKey = idempotencyKey; self.body = body
    }
}

public struct CloudAgentHTTPResponse: Sendable {
    public let statusCode: Int
    public let body: Data
    public init(statusCode: Int, body: Data) { self.statusCode = statusCode; self.body = body }
}

public protocol CloudAgentTransport: Sendable {
    func send(_ request: CloudAgentHTTPRequest, timeout: TimeInterval, maximumResponseBytes: Int) async throws -> CloudAgentHTTPResponse
}

public enum CloudAgentError: LocalizedError, Equatable, Sendable {
    case unconfigured
    case invalidEndpoint
    case credentialUnavailable(CloudAgentBearerReference)
    case invalidCredential
    case invalidIdentifier
    case invalidSchema
    case responseTooLarge
    case redirectRejected
    case requestTimedOut
    case deadlineExceeded
    case disconnected
    case httpStatus(Int)
    case replayedRevision
    case remoteFailed(String)
    case remoteCancelled

    public var errorDescription: String? {
        switch self {
        case .unconfigured: "Cloud agents are unavailable because no HTTPS endpoint is configured."
        case .invalidEndpoint: "The cloud-agent endpoint must be a credential-free HTTPS URL."
        case .credentialUnavailable: "The referenced cloud-agent credential is unavailable."
        case .invalidCredential: "The cloud-agent bearer credential is invalid."
        case .invalidIdentifier: "The cloud-agent service returned an invalid identifier."
        case .invalidSchema: "The cloud-agent service returned an unsupported response schema."
        case .responseTooLarge: "The cloud-agent response exceeded the configured size limit."
        case .redirectRejected: "The cloud-agent service attempted a cross-origin or insecure redirect."
        case .requestTimedOut: "The cloud-agent request timed out."
        case .deadlineExceeded: "The cloud-agent run exceeded its deadline."
        case .disconnected: "The cloud-agent service is temporarily unavailable."
        case .httpStatus(let code): "The cloud-agent service returned HTTP \(code)."
        case .replayedRevision: "The cloud-agent service replayed an older run state."
        case .remoteFailed(let message): "The cloud agent failed: \(message)"
        case .remoteCancelled: "The cloud-agent run was cancelled."
        }
    }
}

public struct CloudAgentBackendConfiguration: Sendable {
    public let endpoint: CloudAgentEndpoint
    public let bearerReference: CloudAgentBearerReference?
    public var requestTimeout: TimeInterval
    public var maximumResponseBytes: Int

    public init(endpoint: CloudAgentEndpoint, bearerReference: CloudAgentBearerReference? = nil,
                requestTimeout: TimeInterval = 30, maximumResponseBytes: Int = 1_048_576) {
        self.endpoint = endpoint; self.bearerReference = bearerReference
        self.requestTimeout = max(0.05, min(requestTimeout, 120))
        self.maximumResponseBytes = max(1_024, min(maximumResponseBytes, 8 * 1_048_576))
    }
}

/// Provider-neutral REST backend. Contract:
/// GET agents, GET agents/{id}, POST agents/{id}/runs, GET runs/{id}, POST runs/{id}/cancel.
public actor CloudAgentBackend {
    private let configuration: CloudAgentBackendConfiguration?
    private let transport: any CloudAgentTransport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configuration: CloudAgentBackendConfiguration?, transport: any CloudAgentTransport) {
        self.configuration = configuration
        self.transport = transport
    }

    /// Production integration entry point. A `nil` configuration remains fail-closed: every
    /// operation throws `CloudAgentError.unconfigured` and no local runtime is substituted.
    public init(configuration: CloudAgentBackendConfiguration?, bearerProvider: any CloudAgentBearerProvider) {
        self.configuration = configuration
        self.transport = URLSessionCloudAgentTransport(bearerProvider: bearerProvider)
    }

    public func list() async throws -> [CloudAgentDescriptor] {
        struct Envelope: Decodable { let agents: [CloudAgentDescriptor] }
        let value: Envelope = try await request(.get, components: ["agents"])
        guard value.agents.count <= 1_000,
              value.agents.allSatisfy({
                  Self.validID($0.id) && !$0.name.isEmpty && $0.name.count <= 512
                      && ($0.summary?.count ?? 0) <= 16_000
              }) else {
            throw CloudAgentError.invalidSchema
        }
        return value.agents
    }

    public func get(agentID: String) async throws -> CloudAgentDescriptor {
        guard Self.validID(agentID) else { throw CloudAgentError.invalidIdentifier }
        let agent: CloudAgentDescriptor = try await request(.get, components: ["agents", agentID])
        guard agent.id == agentID, !agent.name.isEmpty, agent.name.count <= 512,
              (agent.summary?.count ?? 0) <= 16_000 else { throw CloudAgentError.invalidSchema }
        return agent
    }

    public func start(agentID: String, prompt: String, scope: SubagentExecutionScope,
                      idempotencyKey: UUID) async throws -> CloudAgentRemoteRun {
        struct StartBody: Encodable {
            let prompt: String
            let scope: SubagentExecutionScope
        }
        guard Self.validID(agentID) else { throw CloudAgentError.invalidIdentifier }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.count <= SubagentService.maximumPromptCharacters else {
            throw CloudAgentError.invalidSchema
        }
        let body = try encoder.encode(StartBody(prompt: prompt, scope: scope))
        let run: CloudAgentRemoteRun = try await request(.post, components: ["agents", agentID, "runs"],
                                                          idempotencyKey: idempotencyKey, body: body)
        return try validate(run, expectedAgentID: agentID)
    }

    public func poll(runID: String) async throws -> CloudAgentRemoteRun {
        guard Self.validID(runID) else { throw CloudAgentError.invalidIdentifier }
        let run: CloudAgentRemoteRun = try await request(.get, components: ["runs", runID])
        guard run.id == runID else { throw CloudAgentError.invalidSchema }
        return try validate(run, expectedAgentID: nil)
    }

    public func cancel(runID: String, idempotencyKey: UUID) async throws -> CloudAgentRemoteRun {
        guard Self.validID(runID) else { throw CloudAgentError.invalidIdentifier }
        let run: CloudAgentRemoteRun = try await request(.post, components: ["runs", runID, "cancel"],
                                                          idempotencyKey: idempotencyKey, body: Data("{}".utf8))
        guard run.id == runID else { throw CloudAgentError.invalidSchema }
        return try validate(run, expectedAgentID: nil)
    }

    private func request<T: Decodable>(_ method: CloudAgentHTTPRequest.Method, components: [String],
                                       idempotencyKey: UUID? = nil, body: Data? = nil) async throws -> T {
        guard let configuration else { throw CloudAgentError.unconfigured }
        let url = components.reduce(configuration.endpoint.url) { $0.appendingPathComponent($1) }
        do {
            let response = try await transport.send(
                .init(method: method, url: url, bearerReference: configuration.bearerReference,
                      idempotencyKey: idempotencyKey, body: body),
                timeout: configuration.requestTimeout,
                maximumResponseBytes: configuration.maximumResponseBytes
            )
            guard response.body.count <= configuration.maximumResponseBytes else { throw CloudAgentError.responseTooLarge }
            guard (200..<300).contains(response.statusCode) else { throw CloudAgentError.httpStatus(response.statusCode) }
            do { return try decoder.decode(T.self, from: response.body) }
            catch { throw CloudAgentError.invalidSchema }
        } catch let error as CloudAgentError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .timedOut { throw CloudAgentError.requestTimedOut }
        catch { throw CloudAgentError.disconnected }
    }

    private func validate(_ run: CloudAgentRemoteRun, expectedAgentID: String?) throws -> CloudAgentRemoteRun {
        guard Self.validID(run.id), Self.validID(run.agentID),
              expectedAgentID == nil || run.agentID == expectedAgentID,
              (run.output?.count ?? 0) <= 1_000_000, (run.error?.count ?? 0) <= 16_000,
              run.usage.map({ $0.inputTokens >= 0 && $0.outputTokens >= 0 }) ?? true else {
            throw CloudAgentError.invalidSchema
        }
        return run
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.:")).contains($0)
        }
    }
}

public final class URLSessionCloudAgentTransport: NSObject, CloudAgentTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let bearerProvider: any CloudAgentBearerProvider
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init(bearerProvider: any CloudAgentBearerProvider) {
        self.bearerProvider = bearerProvider
        self.makeConfiguration = { .ephemeral }
    }

    /// The configuration factory exists for integration tests (for example, an injected
    /// `URLProtocol`). Production callers should use `init(bearerProvider:)`.
    public init(
        bearerProvider: any CloudAgentBearerProvider,
        configuration: @escaping @Sendable () -> URLSessionConfiguration
    ) {
        self.bearerProvider = bearerProvider
        self.makeConfiguration = configuration
    }

    public func send(_ request: CloudAgentHTTPRequest, timeout: TimeInterval,
                     maximumResponseBytes: Int) async throws -> CloudAgentHTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: timeout)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.body != nil { urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let key = request.idempotencyKey {
            urlRequest.setValue(key.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }
        if let reference = request.bearerReference {
            guard let bearer = try await bearerProvider.bearer(for: reference) else {
                throw CloudAgentError.credentialUnavailable(reference)
            }
            guard !bearer.isEmpty, bearer.count <= 16_384,
                  !bearer.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
                throw CloudAgentError.invalidCredential
            }
            urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        let configuration = makeConfiguration()
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let redirectDelegate = RedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        if redirectDelegate.wasRejected { throw CloudAgentError.redirectRejected }
        guard data.count <= maximumResponseBytes else { throw CloudAgentError.responseTooLarge }
        guard let http = response as? HTTPURLResponse else { throw CloudAgentError.invalidSchema }
        return .init(statusCode: http.statusCode, body: data)
    }

    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var redirectCount = 0
        private var rejected = false

        var wasRejected: Bool { lock.withLock { rejected } }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = lock.withLock { () -> Bool in
                redirectCount += 1
                guard redirectCount <= 5,
                      let source = task.currentRequest?.url, let target = request.url,
                      URLSessionCloudAgentTransport.allowsRedirect(
                          from: source, to: target, redirectCount: redirectCount
                      ) else {
                    rejected = true
                    return false
                }
                return true
            }
            completionHandler(allowed ? request : nil)
        }
    }

    static func allowsRedirect(from source: URL, to target: URL, redirectCount: Int) -> Bool {
        redirectCount <= 5 && target.scheme?.lowercased() == "https" && origin(source) == origin(target)
    }

    private static func origin(_ url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(url.host?.lowercased() ?? ""):\(port)"
    }
}

public struct CloudAgentPollingPolicy: Sendable {
    public var deadline: TimeInterval
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var maximumConsecutiveDisconnects: Int

    public init(deadline: TimeInterval = 15 * 60, initialDelay: TimeInterval = 0.5,
                maximumDelay: TimeInterval = 10, maximumConsecutiveDisconnects: Int = 8) {
        self.deadline = max(0.1, min(deadline, 24 * 60 * 60))
        self.initialDelay = max(0, min(initialDelay, 60))
        self.maximumDelay = max(self.initialDelay, min(maximumDelay, 120))
        self.maximumConsecutiveDisconnects = max(0, min(maximumConsecutiveDisconnects, 100))
    }
}

public protocol CloudAgentSleeper: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct SystemCloudAgentSleeper: CloudAgentSleeper {
    public init() {}
    public func sleep(seconds: TimeInterval) async throws {
        if seconds > 0 { try await Task.sleep(for: .seconds(seconds)) }
    }
}

public struct CloudAgentRunState: Hashable, Sendable {
    public let remoteRunID: String?
    public let status: CloudAgentRemoteStatus?
    public let revision: UInt64?
    public let generation: UInt64
    public let isDisconnected: Bool
}

/// Owns exactly one active remote run. Generation and revision fences prevent late responses from
/// an interrupted generation, or replayed server snapshots, from completing a newer invocation.
public actor CloudAgentRunCoordinator {
    private let backend: CloudAgentBackend
    private let agentID: String
    private let policy: CloudAgentPollingPolicy
    private let sleeper: any CloudAgentSleeper
    private var generation: UInt64 = 0
    private var remoteRunID: String?
    private var status: CloudAgentRemoteStatus?
    private var revision: UInt64?
    private var lastSnapshot: CloudAgentRemoteRun?
    private var disconnected = false
    private var cancellationRequested = false

    public init(backend: CloudAgentBackend, agentID: String, policy: CloudAgentPollingPolicy = .init(),
                sleeper: any CloudAgentSleeper = SystemCloudAgentSleeper()) {
        self.backend = backend; self.agentID = agentID; self.policy = policy; self.sleeper = sleeper
    }

    public func state() -> CloudAgentRunState {
        .init(remoteRunID: remoteRunID, status: status, revision: revision,
              generation: generation, isDisconnected: disconnected)
    }

    public func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        let supersededRunID = status?.isTerminal == true ? nil : remoteRunID
        generation &+= 1
        let currentGeneration = generation
        remoteRunID = nil; status = nil; revision = nil; lastSnapshot = nil
        disconnected = false; cancellationRequested = false
        if let supersededRunID {
            _ = try? await backend.cancel(runID: supersededRunID, idempotencyKey: UUID())
            guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
        }
        let deadline = Date().addingTimeInterval(policy.deadline)
        let key = UUID()
        var delay = policy.initialDelay
        var disconnects = 0
        var initial: CloudAgentRemoteRun?
        while initial == nil {
            try Task.checkCancellation()
            guard Date() < deadline else { throw CloudAgentError.deadlineExceeded }
            do {
                let started = try await backend.start(agentID: agentID, prompt: prompt, scope: scope, idempotencyKey: key)
                guard generation == currentGeneration, !cancellationRequested else {
                    _ = try? await backend.cancel(runID: started.id, idempotencyKey: UUID())
                    return .interrupted
                }
                initial = started
                disconnected = false
            } catch let error as CloudAgentError where Self.transient(error) {
                disconnects += 1; disconnected = true
                guard disconnects <= policy.maximumConsecutiveDisconnects else { throw CloudAgentError.disconnected }
                try await sleeper.sleep(seconds: delay); delay = min(policy.maximumDelay, max(0.01, delay * 2))
            }
        }
        return try await observe(try requireCurrent(initial!, generation: currentGeneration),
                                 generation: currentGeneration, deadline: deadline)
    }

    /// Reattaches to a known remote run after local disconnection/restart. It never starts local work.
    public func resume(remoteRunID: String) async throws -> SubagentTurnOutcome {
        let supersededRunID = self.remoteRunID != remoteRunID && status?.isTerminal != true ? self.remoteRunID : nil
        generation &+= 1
        let currentGeneration = generation
        self.remoteRunID = remoteRunID; status = nil; revision = nil; lastSnapshot = nil
        disconnected = true; cancellationRequested = false
        if let supersededRunID {
            _ = try? await backend.cancel(runID: supersededRunID, idempotencyKey: UUID())
            guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
        }
        let deadline = Date().addingTimeInterval(policy.deadline)
        var delay = policy.initialDelay
        var disconnects = 0
        while true {
            try Task.checkCancellation()
            guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
            guard Date() < deadline else { throw CloudAgentError.deadlineExceeded }
            do {
                let first = try await backend.poll(runID: remoteRunID)
                guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
                disconnected = false
                return try await observe(first, generation: currentGeneration, deadline: deadline)
            } catch let error as CloudAgentError where Self.transient(error) {
                disconnects += 1; disconnected = true
                guard disconnects <= policy.maximumConsecutiveDisconnects else { throw CloudAgentError.disconnected }
                try await sleeper.sleep(seconds: delay)
                delay = min(policy.maximumDelay, max(0.01, delay * 2))
            }
        }
    }

    public func cancel() async {
        cancellationRequested = true
        generation &+= 1
        guard let remoteRunID else { return }
        if let cancelled = try? await backend.cancel(runID: remoteRunID, idempotencyKey: UUID()),
           cancelled.id == remoteRunID {
            status = cancelled.status
            revision = max(revision ?? 0, cancelled.revision)
            lastSnapshot = cancelled
            disconnected = false
        }
    }

    private func observe(_ initial: CloudAgentRemoteRun, generation currentGeneration: UInt64,
                         deadline: Date) async throws -> SubagentTurnOutcome {
        var snapshot = initial
        var delay = policy.initialDelay
        var disconnects = 0
        while true {
            try Task.checkCancellation()
            guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
            try accept(snapshot)
            switch snapshot.status {
            case .succeeded:
                return .completed(text: snapshot.output ?? "", usage: snapshot.usage ?? .init())
            case .failed:
                throw CloudAgentError.remoteFailed(snapshot.error ?? "The remote service did not provide an error message.")
            case .cancelled:
                throw CloudAgentError.remoteCancelled
            case .queued, .running, .awaitingInput:
                break
            }
            guard Date() < deadline else {
                _ = try? await backend.cancel(runID: snapshot.id, idempotencyKey: UUID())
                throw CloudAgentError.deadlineExceeded
            }
            try await sleeper.sleep(seconds: delay)
            guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
            guard Date() < deadline else {
                _ = try? await backend.cancel(runID: snapshot.id, idempotencyKey: UUID())
                throw CloudAgentError.deadlineExceeded
            }
            do {
                let polled = try await backend.poll(runID: snapshot.id)
                guard generation == currentGeneration, !cancellationRequested else { return .interrupted }
                snapshot = polled
                disconnects = 0; disconnected = false
                delay = policy.initialDelay
            } catch let error as CloudAgentError where Self.transient(error) {
                disconnects += 1; disconnected = true
                guard disconnects <= policy.maximumConsecutiveDisconnects else { throw CloudAgentError.disconnected }
                delay = min(policy.maximumDelay, max(0.01, delay * 2))
            }
        }
    }

    private func requireCurrent(_ snapshot: CloudAgentRemoteRun, generation expected: UInt64) throws -> CloudAgentRemoteRun {
        guard generation == expected, !cancellationRequested else { throw CancellationError() }
        return snapshot
    }

    private func accept(_ snapshot: CloudAgentRemoteRun) throws {
        if let currentID = remoteRunID, currentID != snapshot.id { throw CloudAgentError.invalidSchema }
        if let revision, snapshot.revision < revision { throw CloudAgentError.replayedRevision }
        if let revision, snapshot.revision == revision {
            guard snapshot == lastSnapshot else { throw CloudAgentError.replayedRevision }
            return
        }
        if let status, status.isTerminal && status != snapshot.status { throw CloudAgentError.replayedRevision }
        remoteRunID = snapshot.id; status = snapshot.status; revision = snapshot.revision
        lastSnapshot = snapshot
    }

    private static func transient(_ error: CloudAgentError) -> Bool {
        error == .disconnected || error == .requestTimedOut || {
            if case .httpStatus(let code) = error { return code == 408 || code == 429 || code >= 500 }
            return false
        }()
    }
}

public actor CloudAgentRuntime: AgentAsyncTaskRuntime {
    public nonisolated let taskKind: AgentTaskKind = .cloud
    private let coordinator: CloudAgentRunCoordinator
    private let resumeRunID: String?
    private var didRun = false

    public init(coordinator: CloudAgentRunCoordinator, resumeRemoteRunID: String? = nil) {
        self.coordinator = coordinator; self.resumeRunID = resumeRemoteRunID
    }

    public func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        guard !didRun else { throw CloudAgentError.replayedRevision }
        didRun = true
        if let resumeRunID { return try await coordinator.resume(remoteRunID: resumeRunID) }
        return try await coordinator.run(prompt: prompt, scope: scope)
    }

    public func interrupt(reason: String) async { await coordinator.cancel() }
    public func state() async -> CloudAgentRunState { await coordinator.state() }
}
