import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import FiliconDomain
@testable import FiliconAgents

private actor QueuedCloudTransport: CloudAgentTransport {
    enum Step: Sendable {
        case response(Int, String)
        case failure(CloudAgentError)
        case timeout
    }

    private var steps: [Step]
    private(set) var requests: [CloudAgentHTTPRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: CloudAgentHTTPRequest, timeout: TimeInterval,
              maximumResponseBytes: Int) async throws -> CloudAgentHTTPResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw CloudAgentError.disconnected }
        switch steps.removeFirst() {
        case .response(let status, let body):
            return .init(statusCode: status, body: Data(body.utf8))
        case .failure(let error):
            throw error
        case .timeout:
            throw URLError(.timedOut)
        }
    }

    func capturedRequests() -> [CloudAgentHTTPRequest] { requests }
}

private actor ImmediateCloudSleeper: CloudAgentSleeper {
    private(set) var delays: [TimeInterval] = []
    func sleep(seconds: TimeInterval) async throws { delays.append(seconds) }
    func capturedDelays() -> [TimeInterval] { delays }
}

private struct DelayedCloudSleeper: CloudAgentSleeper {
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

private actor BlockingStartCloudTransport: CloudAgentTransport {
    private var startContinuation: CheckedContinuation<CloudAgentHTTPResponse, Never>?
    private(set) var requests: [CloudAgentHTTPRequest] = []

    func send(_ request: CloudAgentHTTPRequest, timeout: TimeInterval,
              maximumResponseBytes: Int) async throws -> CloudAgentHTTPResponse {
        requests.append(request)
        if request.url.path.hasSuffix("/cancel") {
            return .init(statusCode: 200, body: Data(Self.run(status: "cancelled", revision: 2).utf8))
        }
        return await withCheckedContinuation { startContinuation = $0 }
    }

    func waitUntilStartIsPending() async {
        while startContinuation == nil { await Task.yield() }
    }

    func releaseStart() {
        startContinuation?.resume(returning: .init(
            statusCode: 202,
            body: Data(Self.run(status: "running", revision: 1).utf8)
        ))
        startContinuation = nil
    }

    func capturedRequests() -> [CloudAgentHTTPRequest] { requests }

    private static func run(status: String, revision: UInt64) -> String {
        "{\"id\":\"run-1\",\"agent_id\":\"agent-1\",\"status\":\"\(status)\",\"revision\":\(revision)}"
    }
}

private actor StaticBearerProvider: CloudAgentBearerProvider {
    let value: String?
    private(set) var references: [CloudAgentBearerReference] = []
    init(_ value: String?) { self.value = value }
    func bearer(for reference: CloudAgentBearerReference) async throws -> String? {
        references.append(reference)
        return value
    }
    func capturedReferences() -> [CloudAgentBearerReference] { references }
}

private final class CloudAgentURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var request: URLRequest?

    static func reset() { lock.withLock { request = nil } }
    static func capturedRequest() -> URLRequest? { lock.withLock { request } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.request = request }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Cloud agent runtime")
struct CloudAgentRuntimeTests {
    private let endpoint = try! CloudAgentEndpoint(URL(string: "https://cloud.example.test/v1")!)

    @Test func endpointIsCredentialFreeHTTPSAndRedirectsStayOnOrigin() throws {
        #expect(throws: CloudAgentError.invalidEndpoint) {
            try CloudAgentEndpoint(URL(string: "http://cloud.example.test")!)
        }
        #expect(throws: CloudAgentError.invalidEndpoint) {
            try CloudAgentEndpoint(URL(string: "https://user:secret@cloud.example.test")!)
        }
        let source = URL(string: "https://CLOUD.example.test/runs/1")!
        #expect(URLSessionCloudAgentTransport.allowsRedirect(
            from: source, to: URL(string: "https://cloud.example.test/other")!, redirectCount: 5
        ))
        #expect(!URLSessionCloudAgentTransport.allowsRedirect(
            from: source, to: URL(string: "https://evil.example.test/other")!, redirectCount: 1
        ))
        #expect(!URLSessionCloudAgentTransport.allowsRedirect(
            from: source, to: URL(string: "http://cloud.example.test/other")!, redirectCount: 1
        ))
        #expect(!URLSessionCloudAgentTransport.allowsRedirect(
            from: source, to: URL(string: "https://cloud.example.test/other")!, redirectCount: 6
        ))
    }

    @Test func backendImplementsListGetStartPollAndCancelContract() async throws {
        let transport = QueuedCloudTransport([
            .response(200, "{\"agents\":[{\"id\":\"agent-1\",\"name\":\"Builder\",\"status\":\"available\"}]}"),
            .response(200, "{\"id\":\"agent-1\",\"name\":\"Builder\",\"status\":\"available\"}"),
            .response(202, Self.run(status: "queued", revision: 1)),
            .response(200, Self.run(status: "running", revision: 2)),
            .response(200, Self.run(status: "cancelled", revision: 3)),
        ])
        let backend = CloudAgentBackend(
            configuration: .init(endpoint: endpoint, requestTimeout: 4, maximumResponseBytes: 4_096),
            transport: transport
        )
        #expect(try await backend.list().map(\.id) == ["agent-1"])
        #expect(try await backend.get(agentID: "agent-1").name == "Builder")
        let startKey = UUID(), cancelKey = UUID()
        #expect(try await backend.start(agentID: "agent-1", prompt: "build", scope: .init(
            allowedToolNames: ["read"], readableRoots: ["/repo"]
        ), idempotencyKey: startKey).status == .queued)
        #expect(try await backend.poll(runID: "run-1").status == .running)
        #expect(try await backend.cancel(runID: "run-1", idempotencyKey: cancelKey).status == .cancelled)

        let requests = await transport.capturedRequests()
        #expect(requests.map(\.method) == [.get, .get, .post, .get, .post])
        #expect(requests.map { $0.url.path } == [
            "/v1/agents", "/v1/agents/agent-1", "/v1/agents/agent-1/runs",
            "/v1/runs/run-1", "/v1/runs/run-1/cancel",
        ])
        #expect(requests[2].idempotencyKey == startKey && requests[4].idempotencyKey == cancelKey)
        let body = try #require(requests[2].body)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["prompt"] as? String == "build")
        #expect(((json["scope"] as? [String: Any])?["allowedToolNames"] as? [String]) == ["read"])
    }

    @Test func backendFailsClosedAndBoundsSchemaStatusSizeAndTimeout() async throws {
        let unused = QueuedCloudTransport([])
        let unconfigured = CloudAgentBackend(configuration: nil, transport: unused)
        await #expect(throws: CloudAgentError.unconfigured) { try await unconfigured.list() }
        #expect(await unused.capturedRequests().isEmpty)

        let invalidSchema = CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: QueuedCloudTransport([
            .response(200, "{\"agents\":[{\"id\":\"bad/id\",\"name\":\"Bad\",\"status\":\"available\"}]}")
        ]))
        await #expect(throws: CloudAgentError.invalidSchema) { try await invalidSchema.list() }

        let status = CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: QueuedCloudTransport([
            .response(401, "{\"error\":\"no\"}")
        ]))
        await #expect(throws: CloudAgentError.httpStatus(401)) { try await status.list() }

        let tooLarge = CloudAgentBackend(
            configuration: .init(endpoint: endpoint, maximumResponseBytes: 1_024),
            transport: QueuedCloudTransport([.response(200, String(repeating: "x", count: 1_025))])
        )
        await #expect(throws: CloudAgentError.responseTooLarge) { try await tooLarge.list() }

        let timedOut = CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: QueuedCloudTransport([.timeout]))
        await #expect(throws: CloudAgentError.requestTimedOut) { try await timedOut.list() }
    }

    @Test func bearerIsResolvedOnlyInsideLiveTransport() async throws {
        CloudAgentURLProtocol.reset()
        let reference = try #require(CloudAgentBearerReference(rawValue: "keychain.cloud"))
        let provider = StaticBearerProvider("very-secret-token")
        let transport = URLSessionCloudAgentTransport(bearerProvider: provider) {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CloudAgentURLProtocol.self]
            return configuration
        }
        let request = CloudAgentHTTPRequest(
            method: .get, url: URL(string: "https://cloud.example.test/v1/agents")!,
            bearerReference: reference
        )
        _ = try await transport.send(request, timeout: 1, maximumResponseBytes: 1_024)
        #expect(request.bearerReference == reference)
        #expect(await provider.capturedReferences() == [reference])
        #expect(CloudAgentURLProtocol.capturedRequest()?.value(forHTTPHeaderField: "Authorization") == "Bearer very-secret-token")
    }

    @Test func coordinatorBacksOffAfterDisconnectAndAllowsIdenticalRevision() async throws {
        let transport = QueuedCloudTransport([
            .response(202, Self.run(status: "running", revision: 1)),
            .failure(.disconnected),
            .response(200, Self.run(status: "running", revision: 1)),
            .response(200, Self.run(status: "succeeded", revision: 2, output: "done")),
        ])
        let sleeper = ImmediateCloudSleeper()
        let coordinator = CloudAgentRunCoordinator(
            backend: CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: transport),
            agentID: "agent-1",
            policy: .init(deadline: 5, initialDelay: 0.25, maximumDelay: 1, maximumConsecutiveDisconnects: 2),
            sleeper: sleeper
        )
        #expect(try await coordinator.run(prompt: "build", scope: .init()) == .completed(text: "done", usage: .init()))
        #expect(await coordinator.state().remoteRunID == "run-1")
        #expect(await coordinator.state().isDisconnected == false)
        #expect(await sleeper.capturedDelays() == [0.25, 0.5, 0.25])
    }

    @Test func coordinatorRejectsStaleAndMutatedRevisions() async throws {
        let stale = QueuedCloudTransport([
            .response(202, Self.run(status: "running", revision: 2)),
            .response(200, Self.run(status: "running", revision: 1)),
        ])
        let first = CloudAgentRunCoordinator(
            backend: CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: stale),
            agentID: "agent-1", policy: .init(initialDelay: 0), sleeper: ImmediateCloudSleeper()
        )
        await #expect(throws: CloudAgentError.replayedRevision) { try await first.run(prompt: "x", scope: .init()) }

        let mutated = QueuedCloudTransport([
            .response(202, Self.run(status: "running", revision: 1)),
            .response(200, Self.run(status: "queued", revision: 1)),
        ])
        let second = CloudAgentRunCoordinator(
            backend: CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: mutated),
            agentID: "agent-1", policy: .init(initialDelay: 0), sleeper: ImmediateCloudSleeper()
        )
        await #expect(throws: CloudAgentError.replayedRevision) { try await second.run(prompt: "x", scope: .init()) }
    }

    @Test func deadlineCancelsRemoteRunBeforeAnotherPoll() async throws {
        let transport = QueuedCloudTransport([
            .response(202, Self.run(status: "running", revision: 1)),
            .response(200, Self.run(status: "cancelled", revision: 2)),
        ])
        let coordinator = CloudAgentRunCoordinator(
            backend: CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: transport),
            agentID: "agent-1",
            policy: .init(deadline: 0.1, initialDelay: 0.12, maximumDelay: 0.12),
            sleeper: DelayedCloudSleeper()
        )
        await #expect(throws: CloudAgentError.deadlineExceeded) {
            try await coordinator.run(prompt: "build", scope: .init())
        }
        let requests = await transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests[0].url.path.hasSuffix("/agents/agent-1/runs"))
        #expect(requests[1].url.path.hasSuffix("/runs/run-1/cancel"))
    }

    @Test func cancellationDuringStartCancelsLateRemoteRunAndDoesNotCompleteIt() async throws {
        let transport = BlockingStartCloudTransport()
        let coordinator = CloudAgentRunCoordinator(
            backend: CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: transport),
            agentID: "agent-1", policy: .init(initialDelay: 0), sleeper: ImmediateCloudSleeper()
        )
        let task = Task { try await coordinator.run(prompt: "build", scope: .init()) }
        await transport.waitUntilStartIsPending()
        await coordinator.cancel()
        await transport.releaseStart()
        #expect(try await task.value == .interrupted)
        let requests = await transport.capturedRequests()
        #expect(requests.count == 2)
        #expect(requests.last?.url.path.hasSuffix("/runs/run-1/cancel") == true)
    }

    @Test func resumeRetriesTransientDisconnectWithoutStartingANewRun() async throws {
        let transport = QueuedCloudTransport([
            .timeout,
            .response(200, Self.run(status: "succeeded", revision: 9, output: "resumed")),
        ])
        let coordinator = CloudAgentRunCoordinator(
            backend: CloudAgentBackend(configuration: .init(endpoint: endpoint), transport: transport),
            agentID: "agent-1",
            policy: .init(deadline: 5, initialDelay: 0, maximumDelay: 0, maximumConsecutiveDisconnects: 2),
            sleeper: ImmediateCloudSleeper()
        )
        #expect(try await coordinator.resume(remoteRunID: "run-1") == .completed(text: "resumed", usage: .init()))
        let requests = await transport.capturedRequests()
        #expect(requests.count == 2 && requests.allSatisfy { $0.method == .get })
        #expect(requests.allSatisfy { $0.url.path.hasSuffix("/runs/run-1") })
    }

    private static func run(status: String, revision: UInt64, output: String? = nil) -> String {
        let outputJSON = output.map { ",\"output\":\"\($0)\"" } ?? ""
        return "{\"id\":\"run-1\",\"agent_id\":\"agent-1\",\"status\":\"\(status)\",\"revision\":\(revision)\(outputJSON)}"
    }
}
