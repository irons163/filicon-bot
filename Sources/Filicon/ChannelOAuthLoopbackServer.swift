import Foundation
import Network

enum ChannelOAuthBrowserError: LocalizedError {
    case couldNotStartListener
    case couldNotOpenBrowser
    case timedOut
    case malformedCallback
    case callbackTooLarge
    case cancelled

    var errorDescription: String? {
        switch self {
        case .couldNotStartListener: "Could not start the OAuth callback listener on this Mac."
        case .couldNotOpenBrowser: "Could not open the OAuth authorization page."
        case .timedOut: "OAuth did not finish within ten minutes."
        case .malformedCallback: "The OAuth service returned a malformed callback."
        case .callbackTooLarge: "The OAuth callback exceeded the safe size limit."
        case .cancelled: "OAuth was cancelled."
        }
    }
}

/// Single-use callback listener bound explicitly to IPv4 loopback. It accepts
/// one bounded HTTP GET and never records the authorization code or state.
final class ChannelOAuthLoopbackServer: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.filicon.channel-oauth-loopback")
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<URL, Error>?
    private var pendingCallback: URL?
    private var terminalError: Error?
    private var redirectURI: URL?

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard listener == nil, terminalError == nil else {
                lock.unlock()
                continuation.resume(throwing: ChannelOAuthBrowserError.couldNotStartListener)
                return
            }
            readyContinuation = continuation
            lock.unlock()

            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                let listener = try NWListener(using: parameters)
                lock.lock(); self.listener = listener; lock.unlock()
                listener.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
            } catch {
                fail(error)
            }
        }
    }

    func waitForCallback(timeout: Duration) async throws -> URL {
        let timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self?.fail(ChannelOAuthBrowserError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingCallback {
                self.pendingCallback = nil
                lock.unlock()
                continuation.resume(returning: pendingCallback)
            } else if let terminalError {
                lock.unlock()
                continuation.resume(throwing: terminalError)
            } else {
                callbackContinuation = continuation
                lock.unlock()
            }
        }
    }

    func cancel() {
        fail(ChannelOAuthBrowserError.cancelled)
    }

    private func handle(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = lock.withLock({ listener?.port }),
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                fail(ChannelOAuthBrowserError.couldNotStartListener)
                return
            }
            let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
                redirectURI = url
                let value = readyContinuation
                readyContinuation = nil
                return value
            }
            continuation?.resume(returning: url)
        case .failed(let error): fail(error)
        case .cancelled:
            let shouldFail = lock.withLock { terminalError == nil && callbackContinuation != nil }
            if shouldFail { fail(ChannelOAuthBrowserError.cancelled) }
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .ready = state, let connection { self?.receive(connection, buffer: Data()) }
        }
        connection.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            if let error { connection.cancel(); self.fail(error); return }
            var next = buffer
            if let data { next.append(data) }
            guard next.count <= 32_768 else {
                self.respond(connection, status: "413 Payload Too Large")
                self.fail(ChannelOAuthBrowserError.callbackTooLarge)
                return
            }
            if next.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.process(next, connection: connection)
            } else if complete {
                self.respond(connection, status: "400 Bad Request")
                self.fail(ChannelOAuthBrowserError.malformedCallback)
            } else {
                self.receive(connection, buffer: next)
            }
        }
    }

    private func process(_ data: Data, connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            respond(connection, status: "400 Bad Request")
            fail(ChannelOAuthBrowserError.malformedCallback)
            return
        }
        let parts = firstLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET", parts[2] == "HTTP/1.1",
              let base = lock.withLock({ redirectURI }),
              let callback = URL(string: String(parts[1]), relativeTo: base)?.absoluteURL,
              callback.scheme == base.scheme, callback.host == base.host,
              callback.port == base.port, callback.path == base.path,
              callback.user == nil, callback.password == nil, callback.fragment == nil else {
            respond(connection, status: "400 Bad Request")
            fail(ChannelOAuthBrowserError.malformedCallback)
            return
        }
        respond(connection, status: "200 OK", body: "Authorization received. You can return to Filicon.")
        succeed(callback)
    }

    private func respond(_ connection: NWConnection, status: String, body: String = "OAuth callback rejected.") {
        let safeBody = body.replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        let html = "<!doctype html><meta charset=utf-8><title>Filicon</title><p>\(safeBody)</p>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func succeed(_ url: URL) {
        let continuation = lock.withLock { () -> CheckedContinuation<URL, Error>? in
            guard terminalError == nil else { return nil }
            listener?.cancel(); listener = nil
            if callbackContinuation == nil { pendingCallback = url }
            let value = callbackContinuation
            callbackContinuation = nil
            return value
        }
        continuation?.resume(returning: url)
    }

    private func fail(_ error: Error) {
        let continuations = lock.withLock { () -> (CheckedContinuation<URL, Error>?, CheckedContinuation<URL, Error>?) in
            guard terminalError == nil else { return (nil, nil) }
            terminalError = error
            listener?.cancel(); listener = nil
            let values = (readyContinuation, callbackContinuation)
            readyContinuation = nil; callbackContinuation = nil
            return values
        }
        continuations.0?.resume(throwing: error)
        continuations.1?.resume(throwing: error)
    }
}
