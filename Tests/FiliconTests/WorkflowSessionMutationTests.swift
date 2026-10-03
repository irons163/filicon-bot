import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices

private actor WorkflowMutationPromptGate: AgentWorkflowPromptExecuting {
    var requests: [AgentWorkflowPromptRequest] = []
    var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    var released = Set<String>()
    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String {
        requests.append(request)
        if request.stepIndex == 0 {
            await withCheckedContinuation { continuation in
                if released.contains(request.workflowID) { continuation.resume() }
                else { waiting[request.workflowID] = continuation }
            }
        }
        return "PUBLISHED_\(request.workflowID)_\(request.stepIndex)"
    }
    func hasStarted(_ id: String) -> Bool { waiting[id] != nil }
    func release(_ id: String) { released.insert(id); waiting.removeValue(forKey: id)?.resume() }
}
private struct WorkflowMutationDeniedAction: AgentWorkflowActionHandling {
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String {
        Issue.record("No action grant exists"); return ""
    }
}

@Suite("Workflow session mutation fences", .timeLimit(.minutes(1)))
struct WorkflowSessionMutationTests {
    @Test(arguments: ["update", "disable", "delete"])
    func transitiveRecipeChangesCancelOnlyDependentRuns(mutation: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workflow-mutation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = WorkflowMutationPromptGate()
        let service = try WorkflowService(store: AgentWorkflowStore(persistenceURL: root.appending(path: "recipes.json")),
            runtime: AgentWorkflowRuntime(executor: AuthorizedAgentWorkflowExecutor(promptExecutor: gate,
                actionHandler: WorkflowMutationDeniedAction())))
        let target = try await service.create(.init(id: "aa-target", name: "Target", steps: [.prompt("REVIEWED_TARGET")]))
        _ = try await service.create(.init(id: "zz-shared", name: "Shared", steps: [.prompt("COMMON_REFERENCE")]))
        _ = try await service.create(.init(id: "left", name: "Left", steps: [.prompt("sand-workflow:aa-target sand-workflow:zz-shared")]))
        _ = try await service.create(.init(id: "right", name: "Right", steps: [.prompt("sand-workflow:zz-shared")]))
        _ = try await service.create(.init(id: "primary", name: "Primary", steps: [.prompt("sand-workflow:left sand-workflow:right"), .prompt("DO_NOT_CONTINUE")]))
        _ = try await service.create(.init(id: "unrelated", name: "Unrelated", steps: [.prompt("UNRELATED")]))
        let dependent = Task { try await service.runNow(id: "primary") }
        let unrelated = Task { try await service.runNow(id: "unrelated") }
        defer {
            dependent.cancel(); unrelated.cancel()
            Task { await gate.release("primary"); await gate.release("unrelated") }
        }
        for id in ["primary", "unrelated"] {
            var started = false
            for _ in 0..<800 {
                if await gate.hasStarted(id) { started = true; break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(started)
        }
        switch mutation {
        case "update":
            var changed = target; changed.steps = [.prompt("UNREVIEWED_TARGET")]
            _ = try await service.update(id: target.id, with: changed)
        case "disable": _ = try await service.setEnabled(false, id: target.id)
        default: try await service.delete(id: target.id)
        }
        // The executor intentionally ignores cancellation. A late return must
        // not start the next step or free/cancel an unrelated workflow.
        await gate.release("primary"); await gate.release("unrelated")
        let stopped = try await dependent.value, completed = try await unrelated.value
        expectNoDifference(stopped.status, .cancelled)
        expectNoDifference(completed.status, .succeeded)
        let prompts = await gate.requests.filter { $0.workflowID == "primary" }.map(\.prompt)
        expectNoDifference(prompts, ["sand-workflow:left sand-workflow:right"])
    }
}
