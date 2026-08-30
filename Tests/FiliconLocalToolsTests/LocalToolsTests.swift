import Darwin
import Foundation
import Testing
@testable import FiliconLocalTools

@Suite(.serialized)
struct LocalToolsTests {
    let generation = UUID()

    @Test func requestGuardRejectsReplayExpiryAndOldGeneration() async throws {
        let guardState = LocalRequestGuard(generation: generation)
        let scope = makeScope()
        try await guardState.consume(scope)
        await #expect(throws: LocalToolError.replayedRequest) { try await guardState.consume(scope) }
        await #expect(throws: LocalToolError.expiredRequest) { try await guardState.consume(makeScope(expiresAt: .distantPast)) }
        await #expect(throws: LocalToolError.staleGeneration) { try await guardState.consume(makeScope(generation: UUID())) }
    }

    @Test func traversalAndSymlinkEscapeAreRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        let host = trustedHost()

        let traversal = await host.perform(request(.readFile(root: root.path, relativePath: "../\(outside.lastPathComponent)")))
        #expect(traversal.error == .pathEscape)
        let symlink = await host.perform(request(.readFile(root: root.path, relativePath: "escape")))
        #expect(symlink.error == .pathEscape)
    }

    @Test func secureReadWriteAndDirectoryListing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        let host = trustedHost()
        let bytes = Data("hello".utf8)
        #expect((await host.perform(request(.writeFile(root: root.path, relativePath: "nested/a.txt", data: bytes, replace: false)))).error == nil)
        let read = await host.perform(request(.readFile(root: root.path, relativePath: "nested/a.txt")))
        #expect(read.result == .file(bytes))
        let listed = await host.perform(request(.listDirectory(root: root.path, relativePath: "nested")))
        #expect(listed.result == .directory(["a.txt"]))
    }

    @Test func shellMetacharactersAreLiteralArgv() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = trustedHost()
        let marker = root.appendingPathComponent("must-not-exist").path
        let literal = "; touch \(marker); $(echo expanded)"
        let started = await host.perform(request(.runCommand(.init(executable: "/bin/echo", arguments: [literal], workingDirectoryRoot: root.path))))
        let session = try process(started)
        let finished = try await waitForExit(host, sessionID: session.sessionID)
        #expect(String(decoding: finished.output, as: UTF8.self) == literal + "\n")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test func stdinCanBeSentAndIsRejectedAfterExit() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = trustedHost()
        let session = try process(await host.perform(request(.runCommand(.init(executable: "/bin/cat", workingDirectoryRoot: root.path)))))
        let input = Data("through stdin\n".utf8)
        #expect((await host.perform(request(.sendInput(sessionID: session.sessionID, data: input, closeAfterWrite: true)))).error == nil)
        let finished = try await waitForExit(host, sessionID: session.sessionID)
        #expect(finished.output == input)
        let late = await host.perform(request(.sendInput(sessionID: session.sessionID, data: input, closeAfterWrite: false)))
        #expect(late.error == .processExited)
    }

    @Test func outputIsBoundedAndProducerIsTerminated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = trustedHost()
        let session = try process(await host.perform(request(.runCommand(.init(executable: "/usr/bin/yes", workingDirectoryRoot: root.path, timeoutMilliseconds: 10_000)))))
        let finished = try await waitForExit(host, sessionID: session.sessionID, attempts: 300)
        #expect(finished.truncated)
        #expect(finished.output.count == 10 * 1_024 * 1_024)
        #expect(finished.terminationError == .outputLimitExceeded)
    }

    @Test func timeoutTerminatesTheProcessGroup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = trustedHost()
        let session = try process(await host.perform(request(.runCommand(.init(executable: "/bin/sleep", arguments: ["30"], workingDirectoryRoot: root.path, timeoutMilliseconds: 25)))))
        let finished = try await waitForExit(host, sessionID: session.sessionID)
        #expect(finished.terminationError == .timedOut)
        #expect(finished.exitStatus.map { $0 < 0 } == true)
    }

    @Test func terminateKillsProcessGroupIncludingGrandchild() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = trustedHost()
        let script = "sleep 30 & echo $! > child.pid; wait"
        let session = try process(await host.perform(request(.runCommand(.init(executable: "/bin/sh", arguments: ["-c", script], workingDirectoryRoot: root.path, timeoutMilliseconds: 30_000)))))
        let childFile = root.appendingPathComponent("child.pid")
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: childFile.path) { try await Task.sleep(for: .milliseconds(20)) }
        let childPID = Int32((try String(contentsOf: childFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
        #expect((await host.perform(request(.terminate(sessionID: session.sessionID)))).error == nil)
        _ = try await waitForExit(host, sessionID: session.sessionID)
        for _ in 0..<100 where kill(childPID, 0) == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(childPID, 0) != 0)
    }

    @Test func receiptMustMatchExactActionAndCanonicalTarget() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = LocalPermissionReceipt(approvalID: UUID(), action: .writeFile, canonicalTarget: root.appendingPathComponent("other").path, directionEpoch: 1, expiresAt: .distantFuture, signedReceipt: Data([1]))
        let result = await trustedHost().perform(request(.writeFile(root: root.path, relativePath: "actual", data: Data(), replace: false), receipt: receipt))
        #expect(result.error == .permissionMismatch)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("actual").path))
    }

    @Test func receiptCannotReplayAndNewDirectionRetiresIt() async throws {
        let target = "/tmp/example"
        let receipt = LocalPermissionReceipt(approvalID: UUID(), action: .readFile, canonicalTarget: target, directionEpoch: 4, expiresAt: .distantFuture, signedReceipt: Data([1]))
        let guardState = LocalRequestGuard(generation: generation)
        try await guardState.consume(makeScope(receipt: receipt))
        await #expect(throws: LocalToolError.replayedRequest) { try await guardState.consume(makeScope(receipt: receipt)) }

        let older = LocalPermissionReceipt(approvalID: UUID(), action: .readFile, canonicalTarget: target, directionEpoch: 4, expiresAt: .distantFuture, signedReceipt: Data([2]))
        await guardState.advanceDirectionEpoch(to: 5)
        await #expect(throws: LocalToolError.expiredRequest) { try await guardState.consume(makeScope(receipt: older)) }
    }

    @Test func shippingHostRequiresSignedExactReceipt() async throws {
        let key = Data(repeating: 7, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let host = LocalToolProcessHost(
            generation: generation,
            requiresPermissionReceipts: true,
            authenticate: { _ in true },
            verifyReceipt: { authenticator.verify($0) }
        )
        let session = UUID()
        let operation = LocalOperation.terminate(sessionID: session)
        #expect((await host.perform(request(operation))).error == .permissionMismatch)

        let unsigned = LocalPermissionReceipt(
            approvalID: UUID(), action: .runCommand,
            canonicalTarget: "process:\(session.uuidString.lowercased())",
            directionEpoch: 1, expiresAt: .distantFuture, signedReceipt: Data()
        )
        let invalid = LocalPermissionReceipt(
            approvalID: unsigned.approvalID, action: unsigned.action,
            canonicalTarget: unsigned.canonicalTarget, directionEpoch: unsigned.directionEpoch,
            expiresAt: unsigned.expiresAt, signedReceipt: Data(repeating: 1, count: 32)
        )
        #expect((await host.perform(request(operation, receipt: invalid))).error == .permissionMismatch)

        let validUnsigned = LocalPermissionReceipt(
            approvalID: UUID(), action: unsigned.action,
            canonicalTarget: unsigned.canonicalTarget, directionEpoch: unsigned.directionEpoch,
            expiresAt: unsigned.expiresAt, signedReceipt: Data()
        )
        let valid = LocalPermissionReceipt(
            approvalID: validUnsigned.approvalID, action: validUnsigned.action,
            canonicalTarget: validUnsigned.canonicalTarget, directionEpoch: validUnsigned.directionEpoch,
            expiresAt: validUnsigned.expiresAt, signedReceipt: try authenticator.tag(for: validUnsigned)
        )
        #expect((await host.perform(request(operation, receipt: valid))).error == .processNotFound)
    }

    @Test func runtimeBindsReceiptBookmarkAndCancellationToFreshSession() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("bookmarks.json")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let store = WorkspaceAuthorizationStore(fileURL: storage)
        _ = try await store.registerBookmarkData(Data([4, 2]), url: workspace)
        let helper = RecordingHelper()
        let key = Data(repeating: 9, count: 32)
        let first = LocalToolRuntime(workspaceStore: store, sessionKey: key, helper: helper)
        let second = LocalToolRuntime(workspaceStore: store, sessionKey: Data(repeating: 8, count: 32), helper: RecordingHelper())
        #expect(await first.generation != second.generation)

        let conversation = UUID(), run = UUID()
        let result = try await first.perform(
            operation: .readFile(root: workspace.path, relativePath: "README.md"),
            conversationID: conversation,
            agentID: UUID(),
            runID: run,
            toolCallID: "read-1"
        )
        #expect(result == .file(Data("fixture".utf8)))
        let captured = await helper.lastRequest
        #expect(captured?.scope.securityScopedBookmarks == [Data([4, 2])])
        #expect(captured?.scope.permissionReceipt?.canonicalTarget.hasSuffix("/workspace/README.md") == true)
        if let receipt = captured?.scope.permissionReceipt {
            #expect(LocalSessionAuthenticator(sessionKey: key).verify(receipt))
        } else { Issue.record("runtime must issue a signed receipt") }

        await first.cancel(conversationID: conversation)
        #expect(await helper.cancelled.count == 1)
        #expect(await helper.cancelled.first?.0 == run)
        #expect(await helper.cancelled.first?.1 == first.generation)

        #expect(await first.cancel(runID: run, conversationID: conversation) == false)

        let ownedRun = UUID()
        _ = try await first.perform(
            operation: .readFile(root: workspace.path, relativePath: "README.md"),
            conversationID: conversation, agentID: UUID(), runID: ownedRun, toolCallID: "read-3"
        )
        #expect(await first.cancel(runID: ownedRun, conversationID: UUID()) == false)
        #expect(await first.cancel(runID: ownedRun, conversationID: conversation) == false)

        let shellHelper = RecordingHelper(result: .process(.init(
            sessionID: UUID(), processID: 123, output: Data(), nextOffset: 0,
            isRunning: true, exitStatus: nil, truncated: false
        )))
        let shellRuntime = LocalToolRuntime(workspaceStore: store, sessionKey: key, helper: shellHelper)
        let shellRun = UUID()
        _ = try await shellRuntime.perform(
            operation: .runCommand(.init(
                executable: "/usr/bin/true", workingDirectoryRoot: workspace.path
            )),
            conversationID: conversation, agentID: UUID(), runID: shellRun, toolCallID: "shell-1"
        )
        #expect(await shellRuntime.cancel(runID: shellRun, conversationID: UUID()) == false)
        #expect(await shellRuntime.cancel(runID: shellRun, conversationID: conversation))
        #expect(await shellHelper.cancelled.map(\.0) == [shellRun])

        await #expect(throws: LocalToolError.permissionMismatch) {
            try await first.perform(
                operation: .readFile(root: root.path, relativePath: "outside"),
                conversationID: conversation, agentID: UUID(), runID: UUID(), toolCallID: "read-2"
            )
        }
    }

    private func trustedHost() -> LocalToolProcessHost {
        LocalToolProcessHost(generation: generation, authenticate: { _ in true })
    }

    private func request(_ operation: LocalOperation, receipt: LocalPermissionReceipt? = nil) -> LocalToolWireRequest {
        LocalToolWireRequest(scope: makeScope(receipt: receipt), operation: operation)
    }

    private func makeScope(generation: UUID? = nil, expiresAt: Date = .distantFuture, receipt: LocalPermissionReceipt? = nil) -> LocalRequestScope {
        LocalRequestScope(generation: generation ?? self.generation, agentID: UUID(), runID: UUID(), toolCallID: UUID().uuidString, expiresAt: expiresAt, permissionReceipt: receipt)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-local-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func process(_ response: LocalToolWireResponse) throws -> LocalProcessSnapshot {
        if let error = response.error { throw error }
        guard case .process(let snapshot) = response.result else { throw LocalToolError.invalidRequest("expected process") }
        return snapshot
    }

    private func waitForExit(_ host: LocalToolProcessHost, sessionID: UUID, attempts: Int = 150) async throws -> LocalProcessSnapshot {
        var last = LocalProcessSnapshot(sessionID: sessionID, processID: 0, output: Data(), nextOffset: 0, isRunning: true, exitStatus: nil, truncated: false)
        for _ in 0..<attempts {
            last = try process(await host.perform(request(.readProcess(sessionID: sessionID, offset: 0))))
            if !last.isRunning { return last }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw LocalToolError.timedOut
    }
}

private actor RecordingHelper: LocalToolHelperProtocol {
    private(set) var lastRequest: LocalToolWireRequest?
    private(set) var cancelled: [(UUID, UUID)] = []
    private let result: LocalOperationResult

    init(result: LocalOperationResult = .file(Data("fixture".utf8))) {
        self.result = result
    }

    func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        lastRequest = request
        return .init(requestID: request.scope.requestID, result: result, error: nil)
    }

    func cancel(runID: UUID, generation: UUID) async {
        cancelled.append((runID, generation))
    }
}
