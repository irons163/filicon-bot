import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
import FiliconLocalTools
@testable import Filicon

@Suite("Process result error presentation", .timeLimit(.minutes(1)))
struct ProcessResultPresentationTests {
    @Test(arguments: [nil, LocalToolError.ioFailure("Output may be incomplete."), .timedOut, .outputLimitExceeded])
    func processErrorsKeepPartialOutputButDoNotBecomeSuccessfulToolCards(error: LocalToolError?) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-process-result-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = LocalProcessSnapshot(sessionID: UUID(), processID: 123,
            output: Data("partial result\n".utf8), nextOffset: 15, isRunning: false,
            exitStatus: 0, truncated: error == .outputLimitExceeded, terminationError: error)
        let helper = ProcessResultHelper(snapshot: snapshot)
        let runtime = LocalToolRuntime(workspaceStore: WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json")),
                                       sessionKey: Data(repeating: 42, count: 32), helper: helper)
        let executor = LocalAppToolExecutor(kind: .readProcess, runtime: runtime,
            policy: ToolPermissionPolicy(choices: [.runCommand: .always]), approvals: ToolApprovalBroker())
        let call = try NormalizedToolCall(id: "read-output", name: "local__read_process",
            argumentsJSON: JSONEncoder().encode(["session_id": snapshot.sessionID.uuidString]))
        let result = try await executor.execute(call, context: .init(conversationID: UUID()))
        expectNoDifference(result.isError, error != nil)
        let decoded = try JSONDecoder().decode(LocalProcessSnapshot.self, from: Data(result.wireText.utf8))
        expectNoDifference(decoded, snapshot)
        expectNoDifference(result.callID, call.id)
    }
}

private actor ProcessResultHelper: LocalToolHelperProtocol {
    let snapshot: LocalProcessSnapshot
    init(snapshot: LocalProcessSnapshot) { self.snapshot = snapshot }
    func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        .init(requestID: request.scope.requestID, result: .process(snapshot), error: nil)
    }
    func cancel(runID: UUID, generation: UUID) async {}
}
