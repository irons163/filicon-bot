import Testing
import FiliconAgents
import FiliconDomain
@testable import Filicon

@Suite("Workflow composer references")
struct WorkflowComposerReferenceTests {
    private let deploy = AgentWorkflow(
        id: "deploy-safe",
        name: "Deploy Safe",
        description: "Validate a release",
        steps: [.prompt("Check signing and notarization.")]
    )

    @Test func slashQueryFiltersOnlyEnabledManualWorkflowsAndInsertsStableReference() {
        let disabled = AgentWorkflow(id: "disabled", name: "Disabled", isEnabled: false, steps: [.prompt("no")])
        let scheduled = AgentWorkflow(id: "scheduled", name: "Scheduled", trigger: .schedule("@daily"), steps: [.prompt("no")])
        let suggestions = WorkflowComposerReferences.suggestions(
            in: "Please /deploy",
            workflows: [scheduled, disabled, deploy]
        )
        #expect(suggestions.map(\.id) == ["deploy-safe"])
        #expect(WorkflowComposerReferences.inserting(suggestions[0], into: "Please /deploy") == "Please [Deploy Safe](sand-workflow:deploy-safe) ")
        #expect(WorkflowComposerReferences.suggestions(in: "path/to", workflows: [deploy]).isEmpty)
    }

    @Test func onlyExplicitEnabledReferencesAreInjectedBeforeTheLastUserTurn() throws {
        let other = AgentWorkflow(id: "other", name: "Other", steps: [.prompt("Never inject me")])
        let messages = [
            ChatMessage(role: .assistant, text: "Earlier"),
            ChatMessage(role: .user, text: "Use [Deploy Safe](sand-workflow:deploy-safe) now")
        ]
        let projected = WorkflowComposerReferences.injectingReferencedWorkflows(into: messages, workflows: [other, deploy])
        #expect(projected.count == 3)
        #expect(projected[1].role == .system)
        #expect(projected[1].text.contains("Check signing and notarization."))
        #expect(!projected[1].text.contains("Never inject me"))
        #expect(projected[2] == messages[1])
    }

    @Test func injectedWorkflowBodiesAreBoundedOnUTF8Boundaries() throws {
        let oversized = AgentWorkflow(
            id: "unicode",
            name: "Unicode",
            steps: [.prompt(String(repeating: "🧪", count: 4_000))]
        )
        let messages = [ChatMessage(role: .user, text: "@unicode")]
        let projected = WorkflowComposerReferences.injectingReferencedWorkflows(into: messages, workflows: [oversized])
        let system = try #require(projected.first)
        #expect(system.role == .system)
        #expect(system.text.utf8.count <= WorkflowComposerReferences.maximumInjectedBodyBytes + 512)
        #expect(!system.text.contains("�"))
    }

    @Test func teachReferenceCarriesOnlyAValidatedAgentScope() throws {
        let workflow = AgentWorkflow(
            id: "learn-from-demonstration",
            name: "Learn from demonstration",
            steps: [.prompt("Analyze the recording.")]
        )
        let reference = WorkflowComposerReferences.learningReference(agentID: "agent-123")
        let projected = WorkflowComposerReferences.injectingReferencedWorkflows(
            into: [.init(role: .user, text: "Finished. \(reference)")],
            workflows: [workflow]
        )
        let system = try #require(projected.first)
        let scope = system.text.components(separatedBy: "Teach recording queue scope: ").last
        #expect(scope?.count == 64)
        #expect(scope?.allSatisfy { $0.isHexDigit && !$0.isUppercase } == true)

        let forged = WorkflowComposerReferences.injectingReferencedWorkflows(
            into: [.init(role: .user, text: "[Learn](sand-workflow:learn-from-demonstration?teachQueueScope=short)")],
            workflows: [workflow]
        )
        #expect(!forged[0].text.contains("Teach recording queue scope:"))
    }
}
