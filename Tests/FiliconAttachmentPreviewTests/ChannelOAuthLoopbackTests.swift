import Foundation
import Network
import Testing
import FiliconChannels
@testable import Filicon

@Suite("Channel OAuth loopback callback")
struct ChannelOAuthLoopbackTests {
    @Test @MainActor func appModelBootstrapPublishesTheRegisteredChannelDescriptors() async {
        let model = AppModel()
        for _ in 0..<20_000 where !model.isBootstrapped {
            await Task.yield()
        }

        #expect(model.isBootstrapped)
        #expect(Set(model.channelDescriptors.map(\.id)) == Set(["discord", "slack"]))
    }

    @Test func appChannelOAuthMappingUsesOnlyRegisteredProviderIDs() throws {
        // AppModel selects these configurations from the same connector IDs
        // exposed by the channel UI. Keep the mapping explicit and stable so
        // a renamed descriptor cannot silently send OAuth to another service.
        let configurations: [(id: String, configuration: ChannelOAuthConfiguration)] = [
            ("slack", try .slack(clientID: "client")),
            ("discord", try .discord(clientID: "client")),
        ]

        #expect(configurations.map(\.id) == ["slack", "discord"])
        #expect(configurations.map(\.configuration.providerID) == ["slack", "discord"])
        #expect(configurations.map(\.configuration.authorizationEndpoint.host) == ["slack.com", "discord.com"])
        #expect(configurations.map(\.configuration.tokenEndpoint.host) == ["slack.com", "discord.com"])
        #expect(configurations.allSatisfy { $0.configuration.authorizationEndpoint.scheme == "https" })
        #expect(configurations.allSatisfy { $0.configuration.tokenEndpoint.scheme == "https" })

        #expect(throws: ChannelOAuthError.unsupportedProvider) {
            try ChannelOAuthConfiguration(
                providerID: "not-a-connector",
                clientID: "client",
                authorizationEndpoint: URL(string: "https://slack.com/oauth/v2/authorize")!,
                tokenEndpoint: URL(string: "https://slack.com/api/oauth.v2.access")!,
                scopes: []
            )
        }
    }

    @Test func startsOnIPv4LoopbackWithAnEphemeralPort() async throws {
        let server = ChannelOAuthLoopbackServer()
        defer { server.cancel() }

        let redirect = try await server.start()

        #expect(redirect.scheme == "http")
        #expect(redirect.host == "127.0.0.1")
        #expect((redirect.port ?? 0) > 0)
        #expect(redirect.path == "/oauth/callback")
    }

    @Test func acceptsOneCallbackAndClosesTheListener() async throws {
        let server = ChannelOAuthLoopbackServer()
        defer { server.cancel() }
        let redirect = try await server.start()
        let callback = URL(string: "\(redirect.absoluteString)?code=once&state=test-state")!
        let callbackTask = Task { try await server.waitForCallback(timeout: .seconds(5)) }

        let response = try await RawLoopbackHTTPClient(request: getRequest(for: callback), url: redirect).run()
        #expect(statusCode(in: response) == 200)
        #expect(try await callbackTask.value == callback)
    }

    @Test func rejectsWrongPathAndFailsThePendingCallback() async throws {
        let server = ChannelOAuthLoopbackServer()
        defer { server.cancel() }
        let redirect = try await server.start()
        let wrongPath = URL(string: "http://127.0.0.1:\(redirect.port!)/oauth/other?code=x&state=y")!
        let callbackTask = Task { try await server.waitForCallback(timeout: .seconds(5)) }

        let response = try await RawLoopbackHTTPClient(request: getRequest(for: wrongPath), url: redirect).run()
        #expect(statusCode(in: response) == 400)
        do {
            _ = try await callbackTask.value
            Issue.record("A wrong callback path must not complete OAuth")
        } catch ChannelOAuthBrowserError.malformedCallback {
            // Expected: an unexpected path terminates this single-use listener.
        } catch {
            Issue.record("Unexpected callback error: \(error)")
        }
    }

    @Test func rejectsMalformedHTTPAndFailsThePendingCallback() async throws {
        let server = ChannelOAuthLoopbackServer()
        defer { server.cancel() }
        let redirect = try await server.start()
        let callbackTask = Task { try await server.waitForCallback(timeout: .seconds(5)) }

        let malformed = Data([0xff, 0xfe, 0x0d, 0x0a, 0x0d, 0x0a])
        let response = try await RawLoopbackHTTPClient(request: malformed, url: redirect).run()
        #expect(statusCode(in: response) == 400)
        do {
            _ = try await callbackTask.value
            Issue.record("Malformed HTTP must not complete OAuth")
        } catch ChannelOAuthBrowserError.malformedCallback {
            // Expected.
        } catch {
            Issue.record("Unexpected callback error: \(error)")
        }
    }

    @Test func rejectsOversizedHTTPBeforeAcceptingARequest() async throws {
        let server = ChannelOAuthLoopbackServer()
        defer { server.cancel() }
        let redirect = try await server.start()
        let callbackTask = Task { try await server.waitForCallback(timeout: .seconds(5)) }
        let requestLine = "GET /oauth/callback?payload=\(String(repeating: "x", count: 40_000)) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"

        let response = try await RawLoopbackHTTPClient(request: Data(requestLine.utf8), url: redirect).run()
        #expect(statusCode(in: response) == 413)
        do {
            _ = try await callbackTask.value
            Issue.record("An oversized callback must not complete OAuth")
        } catch ChannelOAuthBrowserError.callbackTooLarge {
            // Expected.
        } catch {
            Issue.record("Unexpected callback error: \(error)")
        }
    }

    private func getRequest(for url: URL) -> Data {
        Data("GET \(url.path)?\(url.query ?? "") HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n".utf8)
    }

    private func statusCode(in response: Data) -> Int? {
        let firstLine = String(decoding: response, as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
        let fields = firstLine.split(separator: " ")
        return fields.count > 1 ? Int(fields[1]) : nil
    }
}

private final class RawLoopbackHTTPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let request: Data
    private let queue = DispatchQueue(label: "filicon.tests.raw-loopback-http")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var response = Data()
    private var finished = false

    init(request: Data, url: URL) throws {
        guard let host = url.host, let rawPort = url.port,
              let port = NWEndpoint.Port(rawValue: UInt16(rawPort)) else {
            throw RawLoopbackHTTPError.invalidEndpoint
        }
        self.request = request
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }

    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
            connection.start(queue: queue)
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection.send(content: request, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(.failure(error))
                } else {
                    self?.receive()
                }
            })
        case .failed(let error):
            finish(.failure(error))
        case .cancelled:
            finish(.failure(RawLoopbackHTTPError.cancelled))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            if let data { self.response.append(data) }
            if self.response.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.finish(.success(self.response))
            } else if complete {
                self.finish(.failure(RawLoopbackHTTPError.noHTTPResponse))
            } else {
                self.receive()
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation?.resume(with: result)
    }
}

private enum RawLoopbackHTTPError: Error {
    case invalidEndpoint
    case noHTTPResponse
    case cancelled
}
