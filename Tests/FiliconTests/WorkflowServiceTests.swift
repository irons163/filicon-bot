import Foundation
import Testing
import FiliconAgents
@testable import FiliconAppServices

@Suite("Workflow app service")
struct WorkflowServiceTests {
    @Test func eventScheduleManualAndRestartDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "workflow-service-\(UUID().uuidString)")
        let prompt = WorkflowPromptStub()
        let service = try WorkflowService.persistent(
            workflowsURL: directory.appending(path: "workflows.json"),
            runHistoryURL: directory.appending(path: "runs.json"),
            promptExecutor: prompt,
            actionHandler: WorkflowActionStub()
        )
        _ = try await service.create(.init(id: "event", name: "Event", trigger: .event("push"), steps: [.prompt("event")]))
        _ = try await service.create(.init(id: "schedule", name: "Schedule", trigger: .schedule("0 9 * * *"), steps: [.prompt("schedule")]))
        _ = try await service.create(.init(id: "manual", name: "Manual", steps: [.prompt("manual")]))

        #expect(try await service.dispatchEvent(" push ").map(\.workflowID) == ["event"])
        #expect(try await service.dispatchSchedule("0  9 * * *").map(\.workflowID) == ["schedule"])
        #expect(try await service.runNow(id: "manual").status == .succeeded)
        await #expect(throws: AgentWorkflowError.malformed("empty event")) {
            try await service.dispatchEvent("  ")
        }

        let restored = try WorkflowService.persistent(
            workflowsURL: directory.appending(path: "workflows.json"),
            runHistoryURL: directory.appending(path: "runs.json"),
            promptExecutor: prompt,
            actionHandler: WorkflowActionStub()
        )
        #expect(await restored.workflows().count == 3)
        #expect(await restored.runs().count == 3)
    }

    @Test func eventDispatchUsesWorkflowCanonicalization() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "workflow-service-\(UUID().uuidString)")
        let service = try WorkflowService.persistent(
            workflowsURL: directory.appending(path: "workflows.json"),
            runHistoryURL: directory.appending(path: "runs.json"),
            promptExecutor: WorkflowPromptStub(),
            actionHandler: WorkflowActionStub()
        )
        _ = try await service.create(.init(
            id: "event-lines",
            name: "Event Lines",
            trigger: .event("pull request"),
            steps: [.prompt("event")]
        ))
        #expect(try await service.dispatchEvent(" pull\nrequest ").map(\.workflowID) == ["event-lines"])
    }

    @Test func learningWorkflowIsCreatedOnceAndReenabledWithoutReplacingItsBody() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "workflow-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try WorkflowService.persistent(
            workflowsURL: directory.appending(path: "workflows.json"),
            runHistoryURL: directory.appending(path: "runs.json"),
            promptExecutor: WorkflowPromptStub(),
            actionHandler: WorkflowActionStub()
        )
        let agentID = UUID()
        let created = try await service.ensureLearningWorkflow(agentID: agentID)
        #expect(created.id == "learn-from-demonstration")
        #expect(created.agentID == agentID)
        _ = try await service.setEnabled(false, id: created.id)
        let restored = try await service.ensureLearningWorkflow(agentID: UUID())
        #expect(restored.isEnabled)
        #expect(restored.agentID == agentID)
        #expect(await service.workflows().filter { $0.id == created.id }.count == 1)
    }
}

private actor WorkflowPromptStub: AgentWorkflowPromptExecuting {
    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String { request.prompt }
}

private struct WorkflowActionStub: AgentWorkflowActionHandling {
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String { request.payload }
}
