import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

@Suite("Workflow direct consent", .timeLimit(.minutes(1)))
struct WorkflowDirectBindingTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
    private let date = Date(timeIntervalSince1970: 1_000)
    private func values() throws -> (AgentWorkflow, AgentWorkflow, AgentProfile, Conversation, WorkflowDirectSessionBinding) {
        let profile = AgentProfile(id: owner, name: "Owner", instructions: "PERSONA")
        let reference = AgentWorkflow(id: "referenced", name: "Reference", steps: [.prompt("REFERENCE_RECIPE")], createdAt: date)
        let workflow = AgentWorkflow(id: "primary", agentID: owner, name: "Primary",
            steps: [.prompt("sand-workflow:referenced"), .prompt("SECOND_STEP")], createdAt: date)
        var conversation = Conversation(title: "Reviewed")
        conversation.agentBinding = .init(accountID: "local", agentID: owner)
        let binding = try WorkflowDirectSessionBinding(workflow: workflow, references: [reference], accountID: "local",
            conversation: conversation, profile: profile, reviewedAt: date)
        return (workflow, reference, profile, conversation, binding)
    }
    @Test(arguments: ["step", "reference", "description", "enabled", "account", "persona", "binding", "model", "reasoning"])
    func reviewCoversRecipeReferencesAndIdentity(change: String) throws {
        var (workflow, reference, profile, conversation, binding) = try values()
        #expect(binding.matches(workflow: workflow, references: [reference], accountID: "local", conversation: conversation, profile: profile))
        var account = "local"
        switch change {
        case "step": workflow.steps[1] = .prompt("UNREVIEWED_STEP")
        case "reference": reference.steps = [.prompt("UNREVIEWED_REFERENCE")]
        case "description": workflow.description = "NEW_DESCRIPTION"
        case "enabled": workflow.isEnabled = false
        case "account": account = "other"
        case "persona": profile.instructions = "OTHER_PERSONA"
        case "binding": conversation.agentBinding = .init(accountID: "local", agentID: UUID())
        case "model": conversation.modelID = "other"
        default: conversation.reasoningEffort = .high
        }
        #expect(!binding.matches(workflow: workflow, references: [reference], accountID: account, conversation: conversation, profile: profile))
    }
    @Test func consentIsPrivateDurableCASAndLeaseFenced() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workflow-consent-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "consent.json"), (_, _, _, _, binding) = try values()
        let first = try WorkflowDirectSessionBindingStore(url: url), second = try WorkflowDirectSessionBindingStore(url: url)
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture()
        try await first.save(binding, replacing: nil, lease: lease)
        let readBySecond = try await second.list()
        expectNoDifference(readBySecond, [binding])
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        expectNoDifference(permissions?.intValue, 0o600)
        await #expect(throws: WorkflowDirectSessionError.reviewRequired) { try await second.save(binding, replacing: nil, lease: lease) }
        scope.invalidate()
        await #expect(throws: CancellationError.self) { try await first.revoke(binding, lease: lease) }
        let preserved = try await first.list()
        expectNoDifference(preserved, [binding])
        try await second.revoke(binding, lease: scope.capture())
        let revoked = try await first.list()
        expectNoDifference(revoked, [])
    }
    @Test func replacingConsentFileWithSymlinkIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workflow-consent-link-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "consent.json"), target = root.appending(path: "untouched.json")
        let store = try WorkflowDirectSessionBindingStore(url: url), (_, _, _, _, binding) = try values()
        try Data("[]".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        await #expect(throws: WorkflowDirectSessionError.unavailable) { try await store.save(binding, replacing: nil, lease: AgentWorkflowExecutionScope().capture()) }
        expectNoDifference(try String(contentsOf: target, encoding: .utf8), "[]")
    }
    @Test func combiningOriginalLeasesNeverRecapturesRevokedAuthority() throws {
        let host = AgentWorkflowExecutionScope(), run = AgentWorkflowExecutionScope()
        let hostLease = try host.capture(), runLease = try run.capture()
        let combined = try hostLease.inheriting(runLease)
        run.invalidate()
        #expect(throws: CancellationError.self) { try combined.check() }
        #expect(throws: CancellationError.self) { try hostLease.inheriting(runLease) }
        let fresh = try host.capture().inheriting(run.capture())
        host.suspend(); host.resume()
        #expect(throws: CancellationError.self) { try fresh.commit { Issue.record("A stale combined lease cannot commit") } }
    }
    @Test func aNewAccountCannotOverwriteAnExistingWorkflowGrant() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "workflow-consent-account-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (workflow, reference, profile, conversation, binding) = try values()
        let store = try WorkflowDirectSessionBindingStore(url: root.appending(path: "consent.json"))
        let lease = try AgentWorkflowExecutionScope().capture()
        try await store.save(binding, replacing: nil, lease: lease)
        var otherConversation = conversation
        otherConversation.agentBinding = .init(accountID: "other", agentID: profile.id)
        let other = try WorkflowDirectSessionBinding(workflow: workflow, references: [reference], accountID: "other",
            conversation: otherConversation, profile: profile)
        await #expect(throws: WorkflowDirectSessionError.anotherAccount) { try await store.save(other, replacing: binding, lease: lease) }
        let unchanged = try await store.list()
        expectNoDifference(unchanged, [binding])
    }
}
