import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

private actor WorkflowStepCapture: AgentWorkflowPromptExecuting {
    var requests: [AgentWorkflowPromptRequest] = []
    let suspend: Bool
    init(suspend: Bool = false) { self.suspend = suspend }
    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String {
        requests.append(request)
        if suspend { throw AgentWorkflowPromptSuspension(output: "PUBLISHED_QUESTION") }
        return "PUBLISHED_STEP_\(request.stepIndex)"
    }
    func values() -> [AgentWorkflowPromptRequest] { requests }
}
private struct WorkflowForbiddenAction: AgentWorkflowActionHandling {
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String { Issue.record("No action grant exists"); return "" }
}
@Suite("Workflow shared step context", .timeLimit(.minutes(1)))
struct WorkflowSharedStepTests {
    @Test func snapshotOriginIndexRunAndPriorOutputsReachEveryPromptStep() async throws {
        let capture = WorkflowStepCapture()
        let runtime = AgentWorkflowRuntime(executor: AuthorizedAgentWorkflowExecutor(promptExecutor: capture, actionHandler: WorkflowForbiddenAction()))
        let reference = AgentWorkflow(id: "reference", name: "Reference", steps: [.prompt("RECIPE")], createdAt: Date(timeIntervalSince1970: 1_000))
        let workflow = AgentWorkflow(id: "workflow", agentID: UUID(), name: "Workflow", trigger: .event("trusted-event"),
            steps: [.prompt("sand-workflow:reference"), .prompt("SECOND")], createdAt: reference.createdAt)
        let run = try #require(await runtime.fire(event: "trusted-event", workflows: [workflow, reference]).first)
        expectNoDifference(run.status, .succeeded)
        let requests = await capture.values()
        expectNoDifference(requests.map(\.workflow), [workflow, workflow])
        expectNoDifference(requests.map(\.origin), [.trigger("trusted-event"), .trigger("trusted-event")])
        expectNoDifference(requests.map(\.stepIndex), [0, 1])
        expectNoDifference(requests.map(\.runID), [run.id, run.id])
        expectNoDifference(requests.map(\.referencedWorkflows), [[reference], [reference]])
        expectNoDifference(requests.map(\.priorOutputs), [[], ["PUBLISHED_STEP_0"]])
        #expect(requests.allSatisfy { $0.executionLease != nil })
    }
    @Test func publishedQuestionStopsRemainingStepsAndSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workflow-question-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = WorkflowStepCapture(suspend: true)
        let executor = AuthorizedAgentWorkflowExecutor(promptExecutor: capture, actionHandler: WorkflowForbiddenAction())
        let url = root.appending(path: "runs.json")
        let runtime = try AgentWorkflowRuntime(executor: executor, historyURL: url)
        let workflow = AgentWorkflow(id: "workflow", name: "Workflow", steps: [.prompt("FIRST"), .prompt("DO_NOT_RUN")])
        let run = await runtime.runManual(workflow)
        expectNoDifference(run.status, .waitingForReply)
        expectNoDifference(run.outputs, ["PUBLISHED_QUESTION"])
        let prompts = await capture.values().map(\.prompt)
        expectNoDifference(prompts, ["FIRST"])
        expectNoDifference(run.failure, nil)
        let restored = try AgentWorkflowRuntime(executor: executor, historyURL: url)
        let restoredStatus = await restored.runs().first?.status, count = await capture.values().count
        expectNoDifference(restoredStatus, .waitingForReply)
        expectNoDifference(count, 1)
    }
}
