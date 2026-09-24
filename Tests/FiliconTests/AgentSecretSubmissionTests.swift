import CustomDump
import Foundation
import Testing
import FiliconChannels
@testable import FiliconAppServices

private final class SecretWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var references: [CredentialRef] = []
    private var values: [String] = []
    func write(_ value: AgentSecretValue, _ reference: CredentialRef) {
        lock.withLock { references.append(reference); values.append(value.rawValue) }
    }
    var count: Int { lock.withLock { values.count } }
    func matches(_ value: String, reference: CredentialRef) -> Bool {
        lock.withLock { values == [value] && references == [reference] }
    }
}

private final class SecretSnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private let releaseSignal = DispatchSemaphore(value: 0)
    var isEntered: Bool { lock.withLock { entered } }
    func hold() {
        lock.withLock { entered = true }
        _ = releaseSignal.wait(timeout: .now() + 10)
    }
    func release() { releaseSignal.signal() }
}

@Suite("Secure credential submission", .timeLimit(.minutes(1)))
struct AgentSecretSubmissionTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let sentinel = "FAKE-ONLY-credential-sentinel"
    private struct Fixture {
        let root: URL
        let channels: ChannelService
        let connection: ChannelConnection
        let submission: AgentSecretSubmission
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "secret-submission-\(UUID())")
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let connection = ChannelConnection(id: connectionID, connectorID: "slack", displayName: "Fixture",
            secretReference: "keychain://channels/\(connectionID)", agentID: owner, authKind: .botToken, accountID: "remote", ownerAccountID: "A")
        try await channels.saveConnection(connection)
        let request = try AgentSecretRequest.parse(Data(#"{"label":"Bot token","connector":"slack","field":"token"}"#.utf8))
        let destination = try AgentSecretRequestDestination.resolve(request, accountID: "A", agentID: owner,
            conversationID: scope, connections: [connection])
        return .init(root: root, channels: channels, connection: connection,
            submission: .init(id: requestID, destination: destination))
    }

    @Test func onlyWriterSeesValueAndRetriesCannotOverwriteIt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = SecretWriteProbe()
        let value = try AgentSecretValue(sentinel)
        let receipt = try await f.submission.submit(value, accountID: "A", agentID: owner,
            conversationID: scope, channels: f.channels, write: probe.write)
        let replay = try await f.submission.submit(AgentSecretValue("different value"), accountID: "A", agentID: owner,
            conversationID: scope, channels: f.channels, write: probe.write)
        expectNoDifference(replay, receipt)
        expectNoDifference(probe.count, 1)
        #expect(probe.matches(sentinel, reference: .init(providerID: .init(rawValue: "channel.\(connectionID)"))))
        expectNoDifference(f.submission.state, .stored(receipt))
        expectNoDifference(receipt.requestID, requestID)
        #expect(receipt.acknowledgement.contains("does not confirm remote authentication"))
        let publicOutputs = [String(describing: value), String(reflecting: value), String(customDumping: value),
            String(describing: f.submission.state), receipt.acknowledgement,
            String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self),
            String(decoding: try Data(contentsOf: f.root.appending(path: "channels.json")), as: UTF8.self)]
        #expect(publicOutputs.allSatisfy { !$0.contains(sentinel) })
        f.submission.close()
        expectNoDifference(f.submission.state, .stored(receipt))
    }

    @Test(arguments: ["closed", "dismissed", "account", "owner", "scope", "changed"])
    func invalidatedSubmissionNeverCallsWriter(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = SecretWriteProbe()
        if mode == "closed" { f.submission.close() }
        if mode == "dismissed" { try f.submission.dismiss() }
        if mode == "changed" {
            var connection = f.connection; connection.displayName = "Another destination"
            try await f.channels.saveConnection(connection)
        }
        await #expect(throws: (any Error).self) {
            try await f.submission.submit(AgentSecretValue(sentinel), accountID: mode == "account" ? "B" : "A",
                agentID: mode == "owner" ? requestID : owner, conversationID: mode == "scope" ? requestID : scope,
                channels: f.channels, write: probe.write)
        }
        expectNoDifference(probe.count, 0)
    }

    @Test func writerErrorsAreSanitizedAndExplicitRetryIsPossible() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: AgentSecretSubmissionError.writeFailed) {
            try await f.submission.submit(AgentSecretValue(sentinel), accountID: "A", agentID: owner,
                conversationID: scope, channels: f.channels) { _, _ in
                    throw NSError(domain: "FAKE-ONLY-credential-sentinel", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "FAKE-ONLY-credential-sentinel"])
                }
        }
        expectNoDifference(f.submission.state, .pending)
        let probe = SecretWriteProbe()
        _ = try await f.submission.submit(AgentSecretValue(sentinel), accountID: "A", agentID: owner,
            conversationID: scope, channels: f.channels, write: probe.write)
        expectNoDifference(probe.count, 1)
    }

    @Test func concurrentSubmissionsCommitOnlyOnce() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = SecretWriteProbe(), value = try AgentSecretValue(sentinel)
        let receipts = try await withThrowingTaskGroup(of: AgentSecretReceipt.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await f.submission.submit(value, accountID: "A", agentID: owner,
                        conversationID: scope, channels: f.channels, write: probe.write)
                }
            }
            var receipts: [AgentSecretReceipt] = []
            for try await receipt in group { receipts.append(receipt) }
            return receipts
        }
        expectNoDifference(probe.count, 1)
        expectNoDifference(receipts.count, 8)
        #expect(receipts.allSatisfy { $0.requestID == requestID })
    }

    @Test(arguments: [false, true])
    func queuedWriteCannotOutliveStopOrTaskCancellation(cancelTask: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = SecretSnapshotGate(), probe = SecretWriteProbe()
        let holder = Task { await f.channels.withCredentialSnapshot { _ in gate.hold() } }
        defer { gate.release() }
        for _ in 0..<400 where !gate.isEntered { try await Task.sleep(for: .milliseconds(5)) }
        try #require(gate.isEntered)
        let submission = Task {
            try await f.submission.submit(AgentSecretValue(sentinel), accountID: "A", agentID: owner,
                conversationID: scope, channels: f.channels, write: probe.write)
        }
        // The channel actor is occupied, so even if submit has reached its hop,
        // its destination validation and writer cannot yet have executed.
        if cancelTask { submission.cancel() } else { f.submission.close() }
        gate.release()
        await holder.value
        await #expect(throws: (any Error).self) { try await submission.value }
        expectNoDifference(probe.count, 0)
        if !cancelTask { expectNoDifference(f.submission.state, .cancelled) }
    }

    @Test(arguments: ["", "   ", "a\u{0}b", "a\nb", String(repeating: "a", count: 16_385)])
    func invalidInputIsNotRetained(value: String) {
        #expect(throws: AgentSecretSubmissionError.invalidValue) { try AgentSecretValue(value) }
    }
}
