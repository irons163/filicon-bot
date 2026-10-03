import SwiftUI
import FiliconAgents
import FiliconAppServices
import FiliconDomain

struct WorkflowDirectSessionEdit: Identifiable {
    let id = UUID()
    let workflow: AgentWorkflow
    let references: [AgentWorkflow]
    let accountID: String
    let generation: UInt64
    let lease: AgentWorkflowExecutionScope.Lease
    let binding: WorkflowDirectSessionBinding?
    let profile: AgentProfile
    let conversations: [Conversation]
}

struct WorkflowDirectSessionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let edit: WorkflowDirectSessionEdit
    @State private var conversationID: UUID?
    @State private var allowsSavedFacts: Bool
    @State private var isSaving = false

    init(edit: WorkflowDirectSessionEdit) {
        self.edit = edit
        let current = edit.binding?.accountID == edit.accountID ? edit.binding : nil
        _conversationID = State(initialValue: edit.conversations.first { $0.id == current?.conversationID }?.id)
        _allowsSavedFacts = State(initialValue: current?.memoryAccess == .savedFacts)
    }

    var body: some View {
        let _ = locale.identifier
        Form {
            Section(l10n("Workflow agent session")) {
                if belongsToAnotherAccount {
                    Text(FiliconLocalization.string(WorkflowDirectSessionError.anotherAccount.rawValue))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Picker(l10n("Conversation"), selection: $conversationID) {
                    Text(l10n("Choose…")).tag(nil as UUID?)
                    ForEach(edit.conversations) { conversation in Text(conversation.title).tag(Optional(conversation.id)) }
                }
                .disabled(belongsToAnotherAccount)
                Text(verbatim: "\(edit.profile.name) · \(edit.profile.providerID.rawValue) · \(edit.profile.modelID.rawValue)")
                    .font(.caption).textSelection(.enabled)
                Text(l10n("Manual, scheduled, event and replay runs may use this exact conversation and its shared tool runner. Its text history will be sent to the reviewed provider; old attachments are not automatically forwarded. Each step uses current tool and peer-message approvals. Busy chats and pending questions are not interrupted or retried. Changing the recipe, any reference, account, binding, persona or model requires another review."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(l10n("A published question stops the remaining workflow steps. Reply in the conversation; later steps are not automatically resumed. Workflow action steps remain denied; this approval does not grant them authority."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(l10n("Runs may incur model costs; no price or whole-group budget guarantee is provided."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(l10n("Background memory consent")) {
                Toggle(l10n("Allow saved facts for this background agent"), isOn: $allowsSavedFacts)
                    .disabled(belongsToAnotherAccount)
                Text(l10n("Independent workflow consent: only this agent may send its permitted saved facts to its configured model provider during these runs. Delegated agents do not inherit this consent. No memory suggestions, episodes or synthesis are collected from workflow wakes. Off disables memory recall, search and changes for the run."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(l10n("Workflow recipe")) { WorkflowReviewedRecipeView(workflow: edit.workflow) }
            if !edit.references.isEmpty {
                Section(l10n("Referenced recipes")) {
                    ForEach(edit.references) { WorkflowReviewedRecipeView(workflow: $0) }
                }
            }
            HStack {
                Button(l10n("Cancel"), role: .cancel) { dismiss() }.disabled(isSaving)
                Spacer()
                Button(l10n("Approve workflow session")) { Task { await approve() } }
                    .disabled(conversationID == nil || isSaving || belongsToAnotherAccount)
                    .accessibilityIdentifier("workflow-direct-session-approve")
            }
        }
        .formStyle(.grouped).padding()
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 640, minHeight: 460, idealHeight: 740)
        .interactiveDismissDisabled(isSaving)
    }

    private var belongsToAnotherAccount: Bool { edit.binding.map { $0.accountID != edit.accountID } ?? false }

    private func approve() async {
        guard let conversationID, !belongsToAnotherAccount else { return }
        isSaving = true
        defer { isSaving = false }
        if await model.saveWorkflowDirectSession(edit, conversationID: conversationID,
            memoryAccess: allowsSavedFacts ? .savedFacts : .none) { dismiss() }
    }
}

private struct WorkflowReviewedRecipeView: View {
    let workflow: AgentWorkflow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(workflow.name).font(.headline)
            if !workflow.description.isEmpty { Text(workflow.description).foregroundStyle(.secondary) }
            if let source = workflow.sourceReference { Text(verbatim: source).font(.caption) }
            ForEach(workflow.steps.indices, id: \.self) { index in
                switch workflow.steps[index] {
                case .prompt(let text):
                    Text(l10n("Prompt step \(index + 1)")).font(.caption).foregroundStyle(.secondary)
                    Text(text)
                case .action(let name, let payload):
                    Text(l10n("Action step \(index + 1) · \(name)")).font(.caption).foregroundStyle(.secondary)
                    Text(payload)
                }
            }
        }.textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}
