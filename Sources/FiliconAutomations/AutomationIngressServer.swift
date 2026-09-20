import Foundation
import Network

private struct AutomationIngressPersistentState: Codable, Sendable {
    var routes: [AutomationIngressRoute] = []
    var bindMode: AutomationIngressBindMode = .loopback
    var requestedPort: UInt16 = 0
    var shouldRun = false
    var usedNonces: [String: Date] = [:]
}

struct AutomationHTTPResponse: Sendable {
    let status: Int
    let reason: String
    let body: Data
    init(_ status: Int, _ reason: String, json: String) {
        self.status = status; self.reason = reason; self.body = Data(json.utf8)
    }
    var encoded: Data {
        var data = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        data.append(body); return data
    }
}

public actor AutomationIngressController {
    /// True means retained (including an already queued copy). Return false only
    /// when the event was not retained or delivered: the sender may then retry.
    public typealias EventSink = @Sendable (AutomationEvent) async -> Bool
    public static let maximumAuditEntries = 1_000

    private let stateURL: URL
    private let auditURL: URL
    private let secrets: any AutomationIngressSecretProvider
    private let sink: EventSink
    private let limits: AutomationIngressLimits
    private let now: @Sendable () -> Date
    private var persistent: AutomationIngressPersistentState
    private var auditEntries: [AutomationIngressAuditEntry]
    private var listener: NWListener?
    private var runtime = AutomationIngressStatus()
    private var activeRequests = 0
    private var rateBuckets: [UUID: [Date]] = [:]
    private var routeRevisions: [UUID: UInt64] = [:]
    private var listenerGeneration: UInt64 = 0
    private var pendingNonces: Set<String> = []
    private let queue = DispatchQueue(label: "com.filicon.automations.ingress", qos: .utility)

    public init(stateURL: URL, auditURL: URL, secrets: any AutomationIngressSecretProvider,
                limits: AutomationIngressLimits = .init(), now: @escaping @Sendable () -> Date = { Date() },
                sink: @escaping EventSink) throws {
        self.stateURL = stateURL; self.auditURL = auditURL; self.secrets = secrets
        self.limits = limits; self.now = now; self.sink = sink
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if FileManager.default.fileExists(atPath: stateURL.path) {
            persistent = try decoder.decode(AutomationIngressPersistentState.self, from: Data(contentsOf: stateURL))
        } else { persistent = .init() }
        if FileManager.default.fileExists(atPath: auditURL.path) {
            auditEntries = try decoder.decode([AutomationIngressAuditEntry].self, from: Data(contentsOf: auditURL))
        } else { auditEntries = [] }
        runtime.bindMode = persistent.bindMode
        let timestamp = now()
        persistent.usedNonces = persistent.usedNonces.filter { timestamp.timeIntervalSince($0.value) <= limits.replayWindow }
    }

    deinit { listener?.cancel() }

    public func routes() -> [AutomationIngressRoute] { persistent.routes }
    public func audits(limit: Int = 100) -> [AutomationIngressAuditEntry] {
        Array(auditEntries.suffix(max(0, min(limit, Self.maximumAuditEntries))).reversed())
    }
    public func status() -> AutomationIngressStatus { runtime }
    public func shouldRestoreRunningState() -> Bool { persistent.shouldRun }

    @discardableResult
    public func saveRoute(_ proposed: AutomationIngressRoute) throws -> AutomationIngressRoute {
        guard !proposed.name.isEmpty, !proposed.secretReference.isEmpty,
              proposed.secretReference.count <= 300 else { throw AutomationIngressError.invalidRoute }
        let previous = persistent.routes
        if let index = persistent.routes.firstIndex(where: { $0.id == proposed.id }) { persistent.routes[index] = proposed }
        else { persistent.routes.append(proposed) }
        do { try saveState() }
        catch { persistent.routes = previous; throw error }
        routeRevisions[proposed.id, default: 0] &+= 1
        return proposed
    }

    public func removeRoute(id: UUID) throws {
        let previous = persistent.routes
        persistent.routes.removeAll { $0.id == id }
        do { try saveState() }
        catch { persistent.routes = previous; throw error }
        routeRevisions[id, default: 0] &+= 1
        rateBuckets[id] = nil
    }

    public func start(bindMode: AutomationIngressBindMode = .loopback, port: UInt16 = 0,
                      localNetworkOptIn: Bool = false) throws {
        if bindMode == .localNetwork, !localNetworkOptIn { throw AutomationIngressError.localNetworkRequiresOptIn }
        listenerGeneration &+= 1
        let generation = listenerGeneration
        listener?.cancel(); listener = nil
        runtime = .init(state: .starting, bindMode: bindMode)
        let parameters = NWParameters.tcp
        let host = NWEndpoint.Host(bindMode == .loopback ? "127.0.0.1" : "0.0.0.0")
        let requested = NWEndpoint.Port(rawValue: port) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: requested)
        do {
            let newListener = try NWListener(using: parameters)
            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                Task { await self?.listenerChanged(state, port: newListener?.port?.rawValue, generation: generation) }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                ConnectionReader(connection: connection, limits: limits) { request in
                    await self.process(request, expectedGeneration: generation)
                }.start(on: self.queue)
            }
            listener = newListener
            persistent.bindMode = bindMode; persistent.requestedPort = port; persistent.shouldRun = true
            try saveState()
            newListener.start(queue: queue)
        } catch {
            runtime = .init(state: .failed, bindMode: bindMode, error: error.localizedDescription)
            throw AutomationIngressError.network(error.localizedDescription)
        }
    }

    public func stop() throws {
        listenerGeneration &+= 1
        listener?.cancel(); listener = nil
        runtime = .init(state: .stopped, bindMode: persistent.bindMode)
        persistent.shouldRun = false
        try saveState()
    }

    public func restoreIfNeeded(localNetworkOptIn: Bool) throws {
        guard persistent.shouldRun else { return }
        try start(bindMode: persistent.bindMode, port: persistent.requestedPort,
                  localNetworkOptIn: localNetworkOptIn)
    }

    public func endpointURL(for routeID: UUID) -> URL? {
        guard runtime.state == .running, let port = runtime.port,
              let route = persistent.routes.first(where: { $0.id == routeID }) else { return nil }
        let host = runtime.bindMode == .loopback ? "127.0.0.1" : Self.localHostName
        return URL(string: "http://\(host):\(port)\(route.path)")
    }

    public static var tunnelNotice: String {
        "Filicon does not provide a cloud relay. For public webhooks, explicitly run a trusted HTTPS tunnel to the displayed local endpoint and protect that tunnel separately."
    }

    private static var localHostName: String { ProcessInfo.processInfo.hostName }

    private func listenerChanged(_ state: NWListener.State, port: UInt16?, generation: UInt64) {
        guard generation == listenerGeneration else { return }
        switch state {
        case .ready: runtime = .init(state: .running, bindMode: persistent.bindMode, port: port)
        case .failed(let error): runtime = .init(state: .failed, bindMode: persistent.bindMode, error: error.localizedDescription); listener = nil
        case .cancelled where persistent.shouldRun == false: runtime = .init(state: .stopped, bindMode: persistent.bindMode)
        default: break
        }
    }

    func process(_ request: AutomationHTTPRequest, expectedGeneration: UInt64? = nil) async -> AutomationHTTPResponse {
        // Also reject buffered requests from a connection accepted by an old listener.
        if let expectedGeneration, expectedGeneration != listenerGeneration { return response(for: .invalidRoute) }
        guard activeRequests < limits.maximumConcurrentRequests else { return response(for: .busy) }
        activeRequests += 1; defer { activeRequests -= 1 }
        let now = self.now()
        let generation = listenerGeneration
        let routeID = Self.routeID(from: request.path)
        let route = routeID.flatMap { id in persistent.routes.first { $0.id == id && $0.enabled } }
        let revision = routeID.map { routeRevisions[$0, default: 0] }
        do {
            guard request.method == "POST" else { throw AutomationIngressError.unsupportedMethod }
            guard request.headers["transfer-encoding"] == nil else { throw AutomationIngressError.invalidRequest }
            guard request.headers["content-type"]?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json" else {
                throw AutomationIngressError.unsupportedContentType
            }
            guard let route else { throw AutomationIngressError.invalidRoute }
            guard allowRate(route.id, now: now) else { throw AutomationIngressError.rateLimited }
            let secret: Data
            do { secret = try await secrets.secret(for: route.secretReference) }
            catch { throw AutomationIngressError.missingSecret }
            // Keychain may suspend. Revocation, replacement, or disable/re-enable must
            // invalidate the old admission even if the route's values look identical again.
            guard generation == listenerGeneration, revision == routeRevisions[route.id, default: 0],
                  persistent.routes.contains(route), route.enabled else { throw AutomationIngressError.invalidRoute }
            guard !secret.isEmpty else { throw AutomationIngressError.missingSecret }
            let admissionTime = self.now()
            let auth = try AutomationIngressSignatureVerifier.verify(provider: route.provider, request: request,
                                                                      secret: secret, now: admissionTime,
                                                                      replayWindow: limits.replayWindow)
            let nonceKey = "\(route.id.uuidString.lowercased()):\(auth.nonce)"
            pruneNonces(now: admissionTime)
            guard persistent.usedNonces[nonceKey] == nil else { throw AutomationIngressError.replay }
            let event = try AutomationIngressEventNormalizer.event(route: route, request: request,
                                                                    nonce: auth.nonce, now: admissionTime)
            persistent.usedNonces[nonceKey] = admissionTime
            do { try saveState() }
            catch { persistent.usedNonces[nonceKey] = nil; throw error }
            pendingNonces.insert(nonceKey)
            defer { pendingNonces.remove(nonceKey) }
            let queued = await sink(event)
            if !queued {
                // Only a confirmed rejection is safe to release. Unknown outcomes or
                // failures after acceptance must retain their durable replay marker.
                persistent.usedNonces[nonceKey] = nil
                do { try saveState() }
                catch { persistent.usedNonces[nonceKey] = admissionTime; throw error }
                throw AutomationIngressError.busy
            }
            persistent.usedNonces[nonceKey] = max(admissionTime, self.now())
            try saveState()
            try record(.init(routeID: route.id, provider: route.provider, receivedAt: now,
                             disposition: .accepted, reason: "queued", externalEventID: event.externalEventID))
            return route.provider == .linear
                ? .init(200, "OK", json: #"{"accepted":true}"#)
                : .init(202, "Accepted", json: #"{"accepted":true}"#)
        } catch let error as AutomationIngressError {
            try? record(.init(routeID: routeID, provider: route?.provider, receivedAt: now,
                              disposition: .rejected, reason: error.localizedDescription))
            return response(for: error)
        } catch {
            try? record(.init(routeID: routeID, provider: route?.provider, receivedAt: now,
                              disposition: .rejected, reason: "invalid JSON payload"))
            return .init(400, "Bad Request", json: #"{"accepted":false,"error":"invalid_request"}"#)
        }
    }

    private func allowRate(_ id: UUID, now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-60)
        var bucket = (rateBuckets[id] ?? []).filter { $0 >= cutoff }
        guard bucket.count < limits.requestsPerMinutePerRoute else { rateBuckets[id] = bucket; return false }
        bucket.append(now); rateBuckets[id] = bucket; return true
    }
    private func pruneNonces(now: Date) {
        persistent.usedNonces = persistent.usedNonces.filter {
            pendingNonces.contains($0.key) || now.timeIntervalSince($0.value) <= limits.replayWindow
        }
    }
    private func record(_ entry: AutomationIngressAuditEntry) throws {
        let previous = auditEntries
        auditEntries.append(entry)
        if auditEntries.count > Self.maximumAuditEntries { auditEntries.removeFirst(auditEntries.count - Self.maximumAuditEntries) }
        do { try Self.write(auditEntries, to: auditURL) }
        catch {
            auditEntries = previous
            throw AutomationIngressError.persistence("Unable to persist webhook audit log: \(error.localizedDescription)")
        }
    }
    private func saveState() throws {
        do { try Self.write(persistent, to: stateURL) }
        catch { throw AutomationIngressError.persistence(error.localizedDescription) }
    }
    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
    private static func routeID(from path: String) -> UUID? {
        guard path.hasPrefix("/hooks/"), !path.contains("?"), !path.contains("#") else { return nil }
        let raw = String(path.dropFirst("/hooks/".count))
        guard !raw.contains("/"), raw == raw.lowercased() else { return nil }
        return UUID(uuidString: raw)
    }
    private func response(for error: AutomationIngressError) -> AutomationHTTPResponse {
        switch error {
        case .unsupportedMethod: .init(405, "Method Not Allowed", json: #"{"accepted":false,"error":"method"}"#)
        case .unsupportedContentType: .init(415, "Unsupported Media Type", json: #"{"accepted":false,"error":"content_type"}"#)
        case .bodyTooLarge: .init(413, "Content Too Large", json: #"{"accepted":false,"error":"too_large"}"#)
        case .unauthorized, .staleRequest, .replay, .missingSecret: .init(401, "Unauthorized", json: #"{"accepted":false,"error":"unauthorized"}"#)
        case .rateLimited: .init(429, "Too Many Requests", json: #"{"accepted":false,"error":"rate_limited"}"#)
        case .busy: .init(503, "Service Unavailable", json: #"{"accepted":false,"error":"busy"}"#)
        case .invalidRoute: .init(404, "Not Found", json: #"{"accepted":false,"error":"not_found"}"#)
        case .persistence, .network: .init(500, "Internal Server Error", json: #"{"accepted":false,"error":"internal"}"#)
        default: .init(400, "Bad Request", json: #"{"accepted":false,"error":"invalid_request"}"#)
        }
    }
}

private final class ConnectionReader: @unchecked Sendable {
    private let connection: NWConnection
    private let limits: AutomationIngressLimits
    private let handler: @Sendable (AutomationHTTPRequest) async -> AutomationHTTPResponse
    private var buffer = Data()
    init(connection: NWConnection, limits: AutomationIngressLimits,
         handler: @escaping @Sendable (AutomationHTTPRequest) async -> AutomationHTTPResponse) {
        self.connection = connection; self.limits = limits; self.handler = handler
    }
    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [self] state in
            if case .ready = state { receive() }
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            switch AutomationHTTPRequestParser.parse(self.buffer, limits: self.limits) {
            case .complete(let request):
                Task { self.finish(await self.handler(request)) }
            case .rejected(let error):
                let response = error == .bodyTooLarge
                    ? AutomationHTTPResponse(413, "Content Too Large", json: #"{"accepted":false,"error":"too_large"}"#)
                    : AutomationHTTPResponse(400, "Bad Request", json: #"{"accepted":false,"error":"invalid_request"}"#)
                self.finish(response)
            case .incomplete:
                if complete || error != nil { self.connection.cancel() }
                else { self.receive() }
            }
        }
    }
    private func finish(_ response: AutomationHTTPResponse) {
        connection.send(content: response.encoded, completion: .contentProcessed { [connection] _ in
            connection.stateUpdateHandler = nil
            connection.cancel()
        })
    }
}
