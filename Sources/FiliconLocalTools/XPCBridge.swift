import Foundation

public enum LocalToolXPC {
    public static let serviceName = "com.filicon.app.LocalToolService"
}

@objc(FiliconLocalToolXPCProtocol)
public protocol FiliconLocalToolXPCProtocol {
    func establishSession(generation: String, sessionKey: Data, withReply reply: @escaping (Bool) -> Void)
    func perform(request: Data, withReply reply: @escaping (Data) -> Void)
    func cancel(runID: String, generation: String, withReply reply: @escaping () -> Void)
}

public final class LocalToolXPCClient: @unchecked Sendable, LocalToolHelperProtocol {
    private let generation: UUID
    private let authenticator: LocalSessionAuthenticator
    private let sessionKey: Data
    private let lock = NSLock()
    private var connection: XPCConnectionBox?

    public init(generation: UUID = UUID(), sessionKey: Data) {
        self.generation = generation
        self.sessionKey = sessionKey
        authenticator = LocalSessionAuthenticator(sessionKey: sessionKey)
    }

    deinit { connectionSnapshot()?.value.invalidate() }

    public func connect() async throws {
        if connectionSnapshot() != nil { return }
        let candidate = XPCConnectionBox(NSXPCConnection(serviceName: LocalToolXPC.serviceName))
        candidate.value.remoteObjectInterface = NSXPCInterface(with: FiliconLocalToolXPCProtocol.self)
        candidate.value.resume()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let gate = XPCReplyGate(continuation)
                let proxy = candidate.value.remoteObjectProxyWithErrorHandler { error in gate.fail(error) }
                guard let remote = proxy as? FiliconLocalToolXPCProtocol else {
                    gate.fail(LocalToolError.ioFailure("invalid XPC proxy"))
                    return
                }
                remote.establishSession(generation: generation.uuidString, sessionKey: sessionKey) { accepted in
                    if accepted { gate.succeed(()) }
                    else { gate.fail(LocalToolError.invalidRequest("XPC service rejected session")) }
                }
            }
            let installed = lock.withLock {
                if connection == nil { connection = candidate }
                return connection === candidate
            }
            if !installed { candidate.value.invalidate() }
        } catch {
            candidate.value.invalidate()
            throw error
        }
    }

    public func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        do {
            try await connect()
            guard request.scope.generation == generation else { throw LocalToolError.staleGeneration }
            var authenticated = LocalToolWireRequest(
                scope: request.scope,
                operation: request.operation,
                authenticationTag: Data()
            )
            authenticated = LocalToolWireRequest(
                scope: authenticated.scope,
                operation: authenticated.operation,
                authenticationTag: try authenticator.tag(for: authenticated)
            )
            let payload = try Self.makeEncoder().encode(authenticated)
            let responseData: Data = try await call { remote, reply in
                remote.perform(request: payload, withReply: reply)
            }
            return try Self.makeDecoder().decode(LocalToolWireResponse.self, from: responseData)
        } catch let error as LocalToolError {
            return .init(requestID: request.scope.requestID, result: nil, error: error)
        } catch {
            return .init(requestID: request.scope.requestID, result: nil, error: .ioFailure(error.localizedDescription))
        }
    }

    public func cancel(runID: UUID, generation: UUID) async {
        guard self.generation == generation, let connection = connectionSnapshot() else { return }
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate(continuation)
            let proxy = connection.value.remoteObjectProxyWithErrorHandler { error in gate.fail(error) }
            guard let remote = proxy as? FiliconLocalToolXPCProtocol else {
                gate.fail(LocalToolError.ioFailure("invalid XPC proxy"))
                return
            }
            remote.cancel(runID: runID.uuidString, generation: generation.uuidString) {
                gate.succeed(())
            }
        }
    }

    public func invalidate() {
        let previous = lock.withLock {
            let value = connection
            connection = nil
            return value
        }
        previous?.value.invalidate()
    }

    private func call<T: Sendable>(
        _ body: @escaping (FiliconLocalToolXPCProtocol, @escaping (T) -> Void) -> Void
    ) async throws -> T {
        guard let connection = connectionSnapshot() else { throw LocalToolError.ioFailure("XPC connection is unavailable") }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = XPCReplyGate(continuation)
            let proxy = connection.value.remoteObjectProxyWithErrorHandler { error in gate.fail(error) }
            guard let remote = proxy as? FiliconLocalToolXPCProtocol else {
                gate.fail(LocalToolError.ioFailure("invalid XPC proxy"))
                return
            }
            body(remote) { value in gate.succeed(value) }
        }
    }

    private func connectionSnapshot() -> XPCConnectionBox? {
        lock.withLock { connection }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private final class XPCConnectionBox: @unchecked Sendable {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) { self.value = value }
}

private final class XPCReplyGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: Value) {
        take()?.resume(returning: value)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }
}
