import Foundation
import XCTest
@testable import FiliconComputer

final class RemoteComputerCoreTests: XCTestCase {
    func testProfileRequiresHTTPSAndCapabilities() throws {
        XCTAssertThrowsError(try RemoteComputerProfile(endpoint: URL(string: "http://box.example")!, capabilities: .lifecycle))
        let profile = try RemoteComputerProfile(endpoint: URL(string: "https://box.example/api/")!, capabilities: .lifecycle)
        XCTAssertNoThrow(try profile.require(.lifecycle))
        XCTAssertThrowsError(try profile.require(.terminal))
    }

    func testHTTPBackendUsesExactOriginAndCredentialReference() async throws {
        let transport = RecordingTransport(data: try JSONEncoder().encode(RemoteComputerStatus(state: .running)), status: 200)
        let resolver = CredentialResolver()
        let profile = try RemoteComputerProfile(endpoint: URL(string: "https://box.example/api/")!, credentialReference: "keychain:item", capabilities: .lifecycle)
        let backend = HTTPSRemoteComputerBackend(profile: profile, credentials: resolver, transport: transport)
        let result = try await backend.status(agentID: "agent/one")
        XCTAssertEqual(result.state, .running)
        let captured = await transport.captured()
        XCTAssertEqual(captured?.url?.absoluteString, "https://box.example/api/agents/agent%2Fone/status")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let references = await resolver.references()
        XCTAssertEqual(references, ["keychain:item"])
    }

    func testHTTPBackendDecodesMinimumAppVersionFromLifecycleStatus() async throws {
        let response = RemoteComputerStatus(state: .running, minimumAppVersion: "2.4.0")
        let transport = RecordingTransport(data: try JSONEncoder().encode(response), status: 200)
        let profile = try RemoteComputerProfile(
            endpoint: URL(string: "https://box.example/api/")!,
            capabilities: .lifecycle
        )
        let decoded = try await HTTPSRemoteComputerBackend(profile: profile, transport: transport).status(agentID: "agent")
        XCTAssertEqual(decoded.minimumAppVersion, "2.4.0")
    }

    func testLifecycleGenerationCancelAndPreserveSemantics() async throws {
        let backend = LifecycleBackend()
        let lifecycle = RemoteComputerLifecycle(backend: backend)
        let update = try await lifecycle.update(agentID: "a")
        XCTAssertEqual(update.state, .running)
        await backend.configure(operation: .init(id: update.id, state: .succeeded))
        let settled = try await lifecycle.poll(agentID: "a", operationID: update.id, intervalMilliseconds: 0)
        XCTAssertEqual(settled.state, .succeeded)
        let requests = await backend.requests()
        XCTAssertEqual(requests, [.init(preserveData: true, force: false)])

        _ = try await lifecycle.reset(agentID: "a", force: true)
        try await lifecycle.cancel(agentID: "a")
        let cancelCount = await backend.cancelCount()
        XCTAssertEqual(cancelCount, 1)
    }

    func testTerminalOwnershipCursorUTF8BoundsAndIdempotentCancel() async throws {
        let backend = TerminalBackend()
        let controller = RemoteTerminalController(backend: backend)
        let session = try await controller.start(agentID: "a", ownerID: "owner", request: .init(command: ["/bin/sh"]))
        try await controller.input(agentID: "a", sessionID: session.id, ownerID: "owner", text: "hello")
        let output = try await controller.output(agentID: "a", sessionID: session.id, ownerID: "owner")
        XCTAssertEqual(String(data: output.data, encoding: .utf8), "ok")
        await XCTAssertThrowsAsyncError { try await controller.output(agentID: "a", sessionID: session.id, ownerID: "other") }
        try await controller.cancel(agentID: "a", sessionID: session.id, ownerID: "owner")
        try await controller.cancel(agentID: "a", sessionID: session.id, ownerID: "owner")
        let cancelCount = await backend.cancelCount()
        XCTAssertEqual(cancelCount, 1)
    }

    func testFileTransferChecksPathSizeAndDigest() async throws {
        let backend = FileBackend()
        let transfer = RemoteFileTransfer(backend: backend, maximumBytes: 10)
        let descriptor = try await transfer.upload(agentID: "a", path: "/work/a.txt", data: Data("hello".utf8))
        XCTAssertEqual(descriptor.size, 5)
        let downloaded = try await transfer.download(agentID: "a", path: "/work/a.txt")
        XCTAssertEqual(downloaded, Data("hello".utf8))
        await XCTAssertThrowsAsyncError { try await transfer.upload(agentID: "a", path: "/../secret", data: Data()) }
    }

    func testEgressRequiresAllowlistAndRejectsPrivateDNSAndStripsAuthOnRedirect() async throws {
        let publicPolicy = EgressPolicy(allowedHosts: ["*.example.com"], resolver: FixedDNS(["93.184.216.34"]))
        _ = try await publicPolicy.validate(.init(url: URL(string: "https://api.example.com/v1")!, method: "POST", body: Data("x".utf8)))
        let cleaned = publicPolicy.headersForRedirect(["Authorization": "secret", "X-Test": "ok"], from: URL(string: "https://api.example.com")!, to: URL(string: "https://other.example.com")!)
        XCTAssertNil(cleaned["Authorization"])
        XCTAssertEqual(cleaned["X-Test"], "ok")
        let privatePolicy = EgressPolicy(allowedHosts: ["internal.example.com"], resolver: FixedDNS(["127.0.0.1"]))
        await XCTAssertThrowsAsyncError { try await privatePolicy.validate(.init(url: URL(string: "https://internal.example.com")!)) }
        XCTAssertTrue(EgressPolicy.isBlockedAddress("::1"))
        XCTAssertTrue(EgressPolicy.isBlockedAddress("::ffff:127.0.0.1"))
    }

    func testDiskPressureHysteresisMigrationTTLBusyGuardAndBackoff() async throws {
        let classifier = DiskPressureClassifier()
        let gib = DiskPressureClassifier.gib
        XCTAssertEqual(classifier.classify(.init(deviceID: "d", totalBytes: 100 * gib, availableBytes: gib)), .hard)
        XCTAssertEqual(classifier.classify(.init(deviceID: "d", totalBytes: 100 * gib, availableBytes: 7 * gib), previous: .hard), .hard)
        XCTAssertEqual(classifier.classify(.init(deviceID: "d", totalBytes: 100 * gib, availableBytes: 21 * gib), previous: .soft), .healthy)
        let clock = TestComputerClock()
        let lease = MigrationLease(clock: clock, ttlMilliseconds: 100)
        await lease.setMigrating(true)
        let initiallyMigrating = await lease.isMigrating()
        XCTAssertTrue(initiallyMigrating)
        await clock.advance(by: 100)
        let expired = await lease.isMigrating()
        XCTAssertFalse(expired)
        let guarder = ComputerBusyGuard()
        try await guarder.acquire(owner: "terminal")
        await XCTAssertThrowsAsyncError { try await guarder.requireIdle() }
        try await guarder.requireIdle(force: true)
        XCTAssertEqual(ComputerRetryPolicy(initialDelayMilliseconds: 100, maximumDelayMilliseconds: 250).delay(forAttempt: 3), 250)
    }
}

private actor RecordingTransport: RemoteHTTPTransport {
    let responseData: Data; let status: Int; var request: URLRequest?
    init(data: Data, status: Int) { responseData = data; self.status = status }
    func data(for request: URLRequest, exactOrigin: String, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        self.request = request
        return (responseData, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: isolationHeaders())!)
    }
    func captured() -> URLRequest? { request }
}
private actor CredentialResolver: RemoteComputerCredentialResolver {
    var values: [String] = []
    func resolve(reference: String) async throws -> RemoteComputerCredential { values.append(reference); return .init(value: "Bearer secret") }
    func references() -> [String] { values }
}
private actor LifecycleBackend: RemoteComputerBackend {
    var recreateRequests: [RemoteRecreateRequest] = []; var current = RemoteOperation(id: "op", state: .running); var cancels = 0
    func configure(operation: RemoteOperation) { current = operation }
    func status(agentID: String) async throws -> RemoteComputerStatus { .init(state: .running) }
    func ensure(agentID: String) async throws -> RemoteComputerStatus { .init(state: .running) }
    func recreate(agentID: String, request: RemoteRecreateRequest) async throws -> RemoteOperation { recreateRequests.append(request); current = .init(id: "op-\(recreateRequests.count)", state: .running); return current }
    func operation(agentID: String, operationID: String) async throws -> RemoteOperation { current }
    func cancel(agentID: String, operationID: String) async throws { cancels += 1 }
    func requests() -> [RemoteRecreateRequest] { recreateRequests }
    func cancelCount() -> Int { cancels }
}
private actor TerminalBackend: RemoteTerminalBackend {
    var cancels = 0
    func start(agentID: String, ownerID: String, request: RemoteTerminalStart) async throws -> RemoteTerminalSession { .init(id: "s", ownerID: ownerID) }
    func input(agentID: String, sessionID: String, data: Data) async throws {}
    func resize(agentID: String, sessionID: String, columns: Int, rows: Int) async throws {}
    func output(agentID: String, sessionID: String, cursor: UInt64, limit: Int) async throws -> RemoteTerminalOutput { let data = Data("ok".utf8); return .init(data: data, nextCursor: cursor + UInt64(data.count)) }
    func cancel(agentID: String, sessionID: String) async throws { cancels += 1 }
    func cancelCount() -> Int { cancels }
}
private actor FileBackend: RemoteFileBackend {
    var data = Data(); var descriptor = RemoteFileDescriptor(size: 0, sha256: RemoteFileTransfer.sha256(Data()))
    func upload(agentID: String, path: String, data: Data, descriptor: RemoteFileDescriptor) async throws { self.data = data; self.descriptor = descriptor }
    func download(agentID: String, path: String, maximumBytes: Int) async throws -> (Data, RemoteFileDescriptor) { (data, descriptor) }
}
private struct FixedDNS: EgressDNSResolver {
    let values: [String]; init(_ values: [String]) { self.values = values }
    func addresses(for host: String) async throws -> [String] { values }
}

private extension XCTestCase {
    func XCTAssertThrowsAsyncError(_ expression: () async throws -> Any, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await expression(); XCTFail("Expected error", file: file, line: line) } catch {}
    }
}
