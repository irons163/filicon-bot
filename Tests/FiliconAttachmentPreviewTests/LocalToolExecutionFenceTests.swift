import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconLocalTools
@testable import Filicon

@Suite("Local tool execution retirement", .timeLimit(.minutes(1)))
struct LocalToolExecutionFenceTests {
    private let conversationID = UUID(uuidString: "C0F00000-0000-4000-8000-000000000001")!
    private let runID = UUID(uuidString: "C0F00000-0000-4000-8000-000000000002")!

    private func fixture() async throws -> (URL, LocalToolRuntime, LocalFenceHelper, ToolApprovalBroker, NormalizedToolCall) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-local-fence-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json"))
        try await store.authorize(root)
        let helper = LocalFenceHelper()
        let runtime = LocalToolRuntime(workspaceStore: store,
            generation: UUID(uuidString: "C0F00000-0000-4000-8000-000000000003")!,
            sessionKey: Data(repeating: 42, count: 32), helper: helper)
        let call = try NormalizedToolCall(id: "retired-write", name: "local__write_file",
            argumentsJSON: JSONEncoder().encode(["root": root.path, "path": "result.txt", "content": "reviewed bytes"]))
        return (root, runtime, helper, ToolApprovalBroker(), call)
    }

    @Test(arguments: ["late-allow", "late-deny", "new-generation"])
    func anApprovalCannotReviveTheCapturedRunAfterStop(mode: String) async throws {
        let (root, runtime, helper, approvals, call) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        let executor = LocalAppToolExecutor(kind: .writeFile, runtime: runtime,
            policy: ToolPermissionPolicy(choices: [.writeFile: .ask]), approvals: approvals,
            captureExecutionCheck: { _ in { try lease.check() } })
        let context = ToolContext(conversationID: conversationID, runID: runID)
        // Retire the host lifetime WITHOUT cancelling the Swift task. This
        // forces the race in which broker approval arrives before cancellation.
        let task = Task { try await executor.execute(call, context: context) }
        defer { task.cancel() }
        let request = try await pending(approvals)
        scope.invalidate()
        if mode == "new-generation" { try scope.capture().check() }
        await approvals.resolve(id: request.id, allowed: mode != "late-deny")
        await #expect(throws: CancellationError.self) { try await task.value }
        let operations = await helper.operations, pending = await approvals.requests()
        expectNoDifference(operations, [])
        expectNoDifference(pending, [])
    }

    @Test func aLiveCapturedRunStillRequiresAndHonorsItsOwnApproval() async throws {
        let (root, runtime, helper, approvals, call) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let lease = try AgentWorkflowExecutionScope().capture()
        let executor = LocalAppToolExecutor(kind: .writeFile, runtime: runtime,
            policy: ToolPermissionPolicy(choices: [.writeFile: .ask]), approvals: approvals,
            captureExecutionCheck: { _ in { try lease.check() } })
        let task = Task { try await executor.execute(call, context: .init(conversationID: conversationID, runID: runID)) }
        defer { task.cancel() }
        let request = try await pending(approvals)
        let before = await helper.operations
        expectNoDifference(before, [])
        expectNoDifference(request.conversationID, conversationID)
        expectNoDifference(request.toolCallID, call.id.rawValue)
        expectNoDifference(request.action, .writeFile)
        await approvals.resolve(id: request.id, allowed: true)
        let result = try await task.value, operations = await helper.operations, pending = await approvals.requests()
        expectNoDifference(result, .init(callID: call.id, content: [.text("OK")], isError: false))
        expectNoDifference(operations, [.writeFile(root: root.path, relativePath: "result.txt",
            data: Data("reviewed bytes".utf8), replace: false)])
        expectNoDifference(pending, [])
    }

    @Test func alwaysPermissionCannotReplaceARetiredInheritedHostLifetime() async throws {
        let (root, runtime, helper, approvals, call) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AgentWorkflowExecutionScope(), run = AgentWorkflowExecutionScope()
        let lease = try run.capture(inheriting: account.capture())
        let executor = LocalAppToolExecutor(kind: .writeFile, runtime: runtime,
            policy: ToolPermissionPolicy(choices: [.writeFile: .always]), approvals: approvals,
            captureExecutionCheck: { _ in
                account.invalidate()
                try account.capture().check()
                return { try lease.check() }
            })
        await #expect(throws: CancellationError.self) {
            try await executor.execute(call, context: .init(conversationID: conversationID, runID: runID))
        }
        let operations = await helper.operations, pending = await approvals.requests()
        expectNoDifference(operations, [])
        expectNoDifference(pending, [])
    }

    @Test(arguments: [1, 2, 3])
    func runtimeChecksTheOriginalScopeBeforeAndAfterBookmarksAndBeforeHelperDispatch(stopAt: Int) async throws {
        let (root, runtime, helper, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoint = LocalFenceCheckpoint(stopAt: stopAt)
        await #expect(throws: CancellationError.self) {
            try await runtime.perform(operation: .writeFile(root: root.path, relativePath: "result.txt",
                data: Data("reviewed bytes".utf8), replace: false), conversationID: conversationID,
                agentID: conversationID, runID: runID, toolCallID: "runtime-write",
                now: Date(timeIntervalSince1970: 1_000), validateScope: { try checkpoint.check() })
        }
        let operations = await helper.operations
        expectNoDifference(operations, [])
        expectNoDifference(checkpoint.count, stopAt)
    }

    @Test func discardingALateResultDoesNotClaimToRecallAlreadyAdmittedHelperWork() async throws {
        let (root, runtime, helper, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        await helper.retireWhenAdmitted(scope)
        let operation = LocalOperation.writeFile(root: root.path, relativePath: "result.txt",
            data: Data("reviewed bytes".utf8), replace: false)
        await #expect(throws: CancellationError.self) {
            try await runtime.perform(operation: operation, conversationID: conversationID,
                agentID: conversationID, runID: runID, toolCallID: "already-admitted-write",
                now: Date(timeIntervalSince1970: 1_000), validateScope: { try lease.check() })
        }
        let operations = await helper.operations
        expectNoDifference(operations, [operation])
    }

    private func pending(_ approvals: ToolApprovalBroker) async throws -> ToolApprovalRequest {
        let deadline = ContinuousClock.now + .seconds(5)
        while await approvals.requests().isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return try #require(await approvals.requests().first)
    }
}

private actor LocalFenceHelper: LocalToolHelperProtocol {
    var operations: [LocalOperation] = []
    private var retirementScope: AgentWorkflowExecutionScope?
    func retireWhenAdmitted(_ scope: AgentWorkflowExecutionScope) { retirementScope = scope }
    func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        operations.append(request.operation)
        retirementScope?.invalidate()
        return .init(requestID: request.scope.requestID, result: .acknowledged, error: nil)
    }
    func cancel(runID: UUID, generation: UUID) async {}
}

private final class LocalFenceCheckpoint: @unchecked Sendable {
    private let lock = NSLock()
    private let stopAt: Int
    private var checks = 0
    init(stopAt: Int) { self.stopAt = stopAt }
    var count: Int { lock.withLock { checks } }
    func check() throws {
        try lock.withLock {
            checks += 1
            if checks == stopAt { throw CancellationError() }
        }
    }
}
