import Foundation

public struct RemoteSecurityKeySession: Sendable {
    public let frames: AsyncThrowingStream<RemoteSecurityKeyRequestFrame, Error>
    private let sender: @Sendable ([RemoteSecurityKeyResponseFrame], String?) async throws -> Void
    private let canceller: @Sendable () async -> Void

    public init(
        frames: AsyncThrowingStream<RemoteSecurityKeyRequestFrame, Error>,
        send: @escaping @Sendable ([RemoteSecurityKeyResponseFrame], String?) async throws -> Void,
        cancel: @escaping @Sendable () async -> Void = {}
    ) {
        self.frames = frames
        self.sender = send
        self.canceller = cancel
    }

    public func send(_ frames: [RemoteSecurityKeyResponseFrame], providerID: String?) async throws {
        try await sender(frames, providerID)
    }

    public func cancel() async { await canceller() }
}

public protocol RemoteSecurityKeyBackend: Sendable {
    func connect() async throws -> RemoteSecurityKeySession
}

/// HTTPS/SSE transport matching the provider-neutral remote WebAuthn gateway.
/// The bearer closure is intentionally the only authentication input so callers can resolve it
/// from Keychain for each connection/POST without retaining the secret in settings or this type.
public struct HTTPSRemoteSecurityKeyBackend: RemoteSecurityKeyBackend, Sendable {
    public static let requestsPath = "webauthn/requests"
    public static let responsesPath = "webauthn/responses"

    private let baseURL: URL
    private let session: URLSession
    private let keychainBearerToken: @Sendable () async throws -> String

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        keychainBearerToken: @escaping @Sendable () async throws -> String
    ) throws {
        guard let scheme = baseURL.scheme?.lowercased(), scheme == "https",
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else { throw SecurityKeyError.backendUnavailable }
        self.baseURL = baseURL
        self.session = session
        self.keychainBearerToken = keychainBearerToken
    }

    public func connect() async throws -> RemoteSecurityKeySession {
        var request = URLRequest(url: baseURL.appending(path: Self.requestsPath))
        request.httpMethod = "GET"
        request.timeoutInterval = 0
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(try await authorizationValue(), forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)

        let (stream, continuation) = AsyncThrowingStream<RemoteSecurityKeyRequestFrame, Error>.makeStream()
        let producer = Task {
            do {
                var eventBytes = 0
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    eventBytes += line.utf8.count + 1
                    guard eventBytes <= SecurityKeyValidation.maximumRequestBytes else {
                        throw SecurityKeyError.requestTooLarge(limit: SecurityKeyValidation.maximumRequestBytes)
                    }
                    if line.isEmpty { eventBytes = 0; continue }
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    guard let data = payload.data(using: .utf8), data.count <= SecurityKeyValidation.maximumRequestBytes else {
                        throw SecurityKeyError.requestTooLarge(limit: SecurityKeyValidation.maximumRequestBytes)
                    }
                    continuation.yield(try JSONDecoder().decode(RemoteSecurityKeyRequestFrame.self, from: data))
                }
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in producer.cancel() }

        return RemoteSecurityKeySession(
            frames: stream,
            send: { [baseURL, session, keychainBearerToken] frames, providerID in
                let token = try Self.checkedToken(try await keychainBearerToken())
                let body = ResponseBatch(providerID: providerID, frames: frames)
                let data = try JSONEncoder().encode(body)
                guard data.count <= SecurityKeyValidation.maximumRequestBytes else {
                    throw SecurityKeyError.requestTooLarge(limit: SecurityKeyValidation.maximumRequestBytes)
                }
                var post = URLRequest(url: baseURL.appending(path: Self.responsesPath))
                post.httpMethod = "POST"
                post.timeoutInterval = 30
                post.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                post.setValue("application/json", forHTTPHeaderField: "Content-Type")
                post.httpBody = data
                let (_, response) = try await session.data(for: post)
                try Self.validate(response)
            },
            cancel: { producer.cancel() }
        )
    }

    private func authorizationValue() async throws -> String {
        "Bearer \(try Self.checkedToken(try await keychainBearerToken()))"
    }

    private static func checkedToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token.utf8.count <= 8_192,
              !token.contains(where: { $0 == "\r" || $0 == "\n" }) else { throw SecurityKeyError.backendUnavailable }
        return token
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw SecurityKeyError.backendUnavailable
        }
    }
}

private struct ResponseBatch: Encodable, Sendable {
    let providerID: String?
    let frames: [RemoteSecurityKeyResponseFrame]

    enum CodingKeys: String, CodingKey { case providerID = "providerId", frames }
}

public actor RemoteSecurityKeyProxy {
    public static let heartbeatMilliseconds: Int64 = 10_000
    public static let reconnectMaximumMilliseconds: Int64 = 30_000

    private let backend: any RemoteSecurityKeyBackend
    private let coordinator: SecurityKeyCoordinator
    private let clock: any SecurityKeyClock
    private let computerID: String?
    private let label: String?
    private let status: @Sendable (SecurityKeyStatus) async -> Void
    private var enabled: Bool
    private var lifetime: Task<Void, Never>?
    private var attempts: [String: Task<Void, Never>] = [:]
    private var activeSession: RemoteSecurityKeySession?
    private var providerID: String?

    public init(
        enabled: Bool,
        backend: any RemoteSecurityKeyBackend,
        coordinator: SecurityKeyCoordinator,
        clock: any SecurityKeyClock = SystemSecurityKeyClock(),
        computerID: String? = nil,
        label: String? = nil,
        status: @escaping @Sendable (SecurityKeyStatus) async -> Void = { _ in }
    ) {
        self.enabled = enabled
        self.backend = backend
        self.coordinator = coordinator
        self.clock = clock
        self.computerID = computerID
        self.label = label
        self.status = status
    }

    public func start() {
        guard enabled, lifetime == nil else { return }
        lifetime = Task { [weak self] in await self?.connectionLoop() }
    }

    public func setEnabled(_ value: Bool) async {
        guard enabled != value else { return }
        enabled = value
        await coordinator.setEnabled(value)
        if value { start() } else { await stop(reason: .disabled) }
    }

    /// Used for logout, account handback, remote reconfiguration, and application shutdown.
    public func handback() async { await stop(reason: .disconnected) }

    public func stop(reason: SecurityKeyStatus = .disconnected) async {
        lifetime?.cancel()
        lifetime = nil
        await cancelActive(reason: reason)
    }

    private func connectionLoop() async {
        var reconnectAttempt = 0
        while enabled, !Task.isCancelled {
            do {
                if reconnectAttempt > 0 { await status(.reconnecting(attempt: reconnectAttempt)) }
                let session = try await backend.connect()
                guard enabled, !Task.isCancelled else { await session.cancel(); return }
                activeSession = session
                providerID = nil
                reconnectAttempt = 0
                await coordinator.invalidate(reason: .connected)
                await status(.connected)
                try await consume(session)
                if !Task.isCancelled { throw SecurityKeyError.backendUnavailable }
            } catch is CancellationError {
                return
            } catch {
                await cancelActive(reason: .disconnected)
                guard enabled, !Task.isCancelled else { return }
                reconnectAttempt += 1
                await status(.reconnecting(attempt: reconnectAttempt))
                let shift = min(reconnectAttempt - 1, 5)
                let delay = min(Self.reconnectMaximumMilliseconds, Int64(1_000) << shift)
                do { try await clock.sleep(milliseconds: delay) } catch { return }
            }
        }
    }

    private func consume(_ session: RemoteSecurityKeySession) async throws {
        let heartbeat = Task { [clock] in
            while !Task.isCancelled {
                try await clock.sleep(milliseconds: Self.heartbeatMilliseconds)
                try Task.checkCancellation()
                try await session.send([.ping], providerID: self.providerID)
            }
        }
        defer { heartbeat.cancel() }
        do {
            for try await frame in session.frames {
                try Task.checkCancellation()
                await handle(frame, session: session)
            }
        } catch {
            heartbeat.cancel()
            _ = await heartbeat.result
            throw error
        }
        heartbeat.cancel()
        _ = await heartbeat.result
    }

    private func handle(_ frame: RemoteSecurityKeyRequestFrame, session: RemoteSecurityKeySession) async {
        switch frame {
        case .welcome(let value):
            guard !value.isEmpty, value.utf8.count <= 256 else { return }
            providerID = value
            try? await session.send([.hello(computerID: computerID, label: label)], providerID: value)
        case .ceremony(let requestID, let ceremony):
            guard attempts[requestID] == nil else {
                let frames = await coordinator.run(requestID: requestID, ceremony: ceremony)
                try? await session.send(frames, providerID: providerID)
                return
            }
            let bytes = (try? JSONEncoder().encode(frame).count) ?? SecurityKeyValidation.maximumRequestBytes + 1
            attempts[requestID] = Task { [weak self] in
                guard let self else { return }
                let frames = await coordinator.run(requestID: requestID, ceremony: ceremony, encodedBytes: bytes)
                guard !Task.isCancelled else { return }
                try? await session.send(frames, providerID: await self.providerID)
                await self.finished(requestID)
            }
        case .cancel(let requestID):
            attempts.removeValue(forKey: requestID)?.cancel()
            await coordinator.cancel(requestID: requestID)
        }
    }

    private func finished(_ requestID: String) { attempts.removeValue(forKey: requestID) }

    private func cancelActive(reason: SecurityKeyStatus) async {
        for attempt in attempts.values { attempt.cancel() }
        attempts.removeAll()
        await activeSession?.cancel()
        activeSession = nil
        providerID = nil
        await coordinator.invalidate(reason: reason)
        await status(reason)
    }
}
