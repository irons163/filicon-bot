import Foundation
import XCTest
@testable import FiliconComputer

final class RemoteIsolationTests: XCTestCase {
    func testMissingDeclarationFailsClosedAndPublishesRejectedSnapshot() async throws {
        let transport = IsolationSequenceTransport([.init(data: try JSONEncoder().encode(RemoteComputerStatus(state: .running)), declaration: nil)])
        let backend = HTTPSRemoteComputerBackend(profile: try profile(.lifecycle), transport: transport)

        await assertRemoteError(.missingIsolationDeclaration) { try await backend.status(agentID: "agent") }
        let snapshot = await backend.securitySnapshot(agentID: "agent")
        XCTAssertEqual(snapshot.state, .rejected)
        XCTAssertEqual(snapshot.failure, .missingIsolationDeclaration)
    }

    func testLifecycleTerminalAndFileTransferShareOneLatchedPolicy() async throws {
        let valid = declaration(generation: 9)
        let changed = declaration(generation: 10)
        let responses: [IsolationResponse] = [
            .init(data: try JSONEncoder().encode(RemoteComputerStatus(state: .running)), declaration: valid),
            .init(data: try JSONEncoder().encode(RemoteTerminalSession(id: "s", ownerID: "owner")), declaration: changed),
        ]
        let transport = IsolationSequenceTransport(responses)
        let backend = HTTPSRemoteComputerBackend(
            profile: try profile([.lifecycle, .terminal, .fileTransfer], identity: "host/workload"),
            transport: transport
        )

        _ = try await backend.status(agentID: "agent")
        await assertRemoteError(.isolationGenerationChanged(expected: 9, actual: 10)) {
            try await backend.start(agentID: "agent", ownerID: "owner", request: .init(command: ["/bin/sh"]))
        }
        let transfer = RemoteFileTransfer(backend: backend, maximumBytes: 32)
        await assertRemoteError(.isolationGenerationChanged(expected: 9, actual: 10)) {
            try await transfer.upload(agentID: "agent", path: "/workspace/a", data: Data())
        }
        let requestCount = await transport.requestCount()
        let snapshot = await backend.securitySnapshot(agentID: "agent")
        XCTAssertEqual(requestCount, 2, "rejected state must fail before another network request")
        XCTAssertEqual(snapshot.state, .rejected)
    }

    func testIdentityBoundaryCapsAndPersistedGenerationAreRejected() async throws {
        let strict = policy(identity: "expected", minimumGeneration: 8)

        let wrongIdentity = RemoteIsolationVerifier(policy: strict)
        await assertRemoteError(.isolationIdentityMismatch) {
            try await wrongIdentity.validate(declaration(identity: "other", generation: 8), agentID: "a")
        }

        let rollback = RemoteIsolationVerifier(policy: strict)
        await assertRemoteError(.isolationGenerationRollback(expected: 8, actual: 7)) {
            try await rollback.validate(declaration(identity: "expected", generation: 7), agentID: "a")
        }

        let escapedFilesystem = RemoteIsolationVerifier(policy: strict)
        var escaped = declaration(identity: "expected", generation: 8)
        escaped.filesystem.writableRoots = ["/workspace/../secret"]
        await assertRemoteError(.invalidIsolationDeclaration) {
            try await escapedFilesystem.validate(escaped, agentID: "a")
        }

        let excessiveCaps = RemoteIsolationVerifier(policy: strict)
        var excessive = declaration(identity: "expected", generation: 8)
        excessive.resourceCaps.memoryBytes += 1
        await assertRemoteError(.isolationResourceCapsExceeded) {
            try await excessiveCaps.validate(excessive, agentID: "a")
        }
    }

    func testPinnedIdentityBoundaryAndCapsCannotChange() async throws {
        let identityVerifier = RemoteIsolationVerifier(policy: policy())
        try await identityVerifier.validate(declaration(generation: 4), agentID: "a")
        await assertRemoteError(.isolationIdentityMismatch) {
            try await identityVerifier.validate(declaration(identity: "replacement", generation: 4), agentID: "a")
        }

        let boundaryVerifier = RemoteIsolationVerifier(policy: policy())
        try await boundaryVerifier.validate(declaration(generation: 4), agentID: "a")
        var narrowed = declaration(generation: 4)
        narrowed.filesystem.writableRoots = []
        await assertRemoteError(.isolationBoundaryChanged) {
            try await boundaryVerifier.validate(narrowed, agentID: "a")
        }

        let capsVerifier = RemoteIsolationVerifier(policy: policy())
        try await capsVerifier.validate(declaration(generation: 4), agentID: "a")
        var changed = declaration(generation: 4)
        changed.resourceCaps.maximumSessions = 1
        await assertRemoteError(.isolationResourceCapsChanged) {
            try await capsVerifier.validate(changed, agentID: "a")
        }
    }

    func testConcurrentFirstDeclarationsCannotCreateSplitTrust() async throws {
        let verifier = RemoteIsolationVerifier(policy: policy(identity: "host/workload"))
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for generation in [UInt64(20), 21] {
                group.addTask {
                    do {
                        try await verifier.validate(declaration(generation: generation), agentID: "agent")
                        return true
                    } catch { return false }
                }
            }
            var values: [Bool] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let snapshot = await verifier.snapshot(agentID: "agent")
        XCTAssertEqual(snapshot.state, .rejected)
    }
}

private struct IsolationResponse: Sendable {
    var data: Data
    var declaration: RemoteIsolationDeclaration?
}

private actor IsolationSequenceTransport: RemoteHTTPTransport {
    private var responses: [IsolationResponse]
    private var count = 0
    init(_ responses: [IsolationResponse]) { self.responses = responses }

    func data(for request: URLRequest, exactOrigin: String, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard !responses.isEmpty else { throw RemoteComputerError.invalidResponse }
        count += 1
        let response = responses.removeFirst()
        return (response.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: isolationHeaders(response.declaration))!)
    }
    func requestCount() -> Int { count }
}

func declaration(identity: String = "host/workload", generation: UInt64) -> RemoteIsolationDeclaration {
    .init(
        identity: identity,
        sessionGeneration: generation,
        filesystem: .init(root: "/workspace", writableRoots: ["/workspace"]),
        resourceCaps: .init(cpuMillisecondsPerSession: 10_000, memoryBytes: 1_024, storageBytes: 2_048, maximumSessions: 2)
    )
}

private func policy(identity: String? = nil, minimumGeneration: UInt64 = 1) -> RemoteIsolationPolicy {
    .init(
        requiredIdentity: identity,
        requiredFilesystemRoot: "/workspace",
        minimumSessionGeneration: minimumGeneration,
        maximumResourceCaps: .init(cpuMillisecondsPerSession: 10_000, memoryBytes: 1_024, storageBytes: 2_048, maximumSessions: 2)
    )
}

private func profile(_ capabilities: RemoteComputerCapabilities, identity: String? = nil) throws -> RemoteComputerProfile {
    try .init(endpoint: URL(string: "https://box.example/api/")!, capabilities: capabilities, isolationPolicy: policy(identity: identity))
}

func isolationHeaders(_ declaration: RemoteIsolationDeclaration? = declaration(generation: 1)) -> [String: String]? {
    guard let declaration, let encoded = try? JSONEncoder().encode(declaration) else { return nil }
    return [HTTPSRemoteComputerBackend.isolationDeclarationHeader: encoded.base64EncodedString()]
}

private func assertRemoteError<T>(_ expected: RemoteComputerError, _ operation: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch let error as RemoteComputerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}
