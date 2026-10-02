import SwiftUI
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
import FiliconDomain

struct RoutineDirectSessionEdit: Identifiable {
    let id = UUID()
    let automation: Automation
    let accountID: String
    let generation: UInt64
    let binding: AutomationDirectSessionBinding?
    let profile: AgentProfile
    let conversations: [Conversation]
}

struct RoutineDirectSessionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let edit: RoutineDirectSessionEdit
    @State private var conversationID: UUID?
    @State private var allowsSavedFacts: Bool
    @State private var isSaving = false

    init(edit: RoutineDirectSessionEdit) {
        self.edit = edit
        let current = edit.binding?.accountID == edit.accountID ? edit.binding : nil
        _conversationID = State(initialValue: edit.conversations.first { $0.id == current?.conversationID }?.id)
        _allowsSavedFacts = State(initialValue: current?.memoryAccess == .savedFacts)
    }

    var body: some View {
        let _ = locale.identifier
        Form {
            Section(l10n("Background agent session")) {
                Text(edit.automation.name).font(.headline)
                Text(edit.automation.prompt).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Picker(l10n("Conversation"), selection: $conversationID) {
                    Text(l10n("Choose…")).tag(nil as UUID?)
                    ForEach(edit.conversations) { conversation in
                        Text(conversation.title).tag(Optional(conversation.id))
                    }
                }
                Text(verbatim: "\(edit.profile.name) · \(edit.profile.providerID.rawValue) · \(edit.profile.modelID.rawValue)")
                    .font(.caption).textSelection(.enabled)
                Text(l10n("Scheduled, event and manual runs will use this exact agent conversation and shared tool runner. Its text history will be sent to the reviewed model provider; attachments are not automatically forwarded. Tools and peer messages still require their existing approvals. Busy conversations and pending questions are not interrupted or retried. Changes to the routine, account, binding, persona or model require another review."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(l10n("Runs may incur model costs; no price or whole-group budget guarantee is provided."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(l10n("Background memory consent")) {
                Toggle(l10n("Allow saved facts for this background agent"), isOn: $allowsSavedFacts)
                Text(l10n("Independent consent: this agent may send its permitted private, shared user and joined-project facts to its configured model provider during this routine. Delegated agents do not inherit memory consent. This does not authorize publishing unrelated facts or collecting memory suggestions, episodes or synthesis from routine wakes. Off disables memory recall, search and changes for this run."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(l10n("Cancel"), role: .cancel) { dismiss() }.disabled(isSaving)
                Spacer()
                Button(l10n("Approve agent session")) {
                    Task { await approve() }
                }
                .disabled(conversationID == nil || isSaving)
                .accessibilityIdentifier("routine-direct-session-approve")
            }
        }
        .formStyle(.grouped).padding()
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 640, minHeight: 460, idealHeight: 640)
        .interactiveDismissDisabled(isSaving)
    }

    private func approve() async {
        guard let conversationID else { return }
        isSaving = true
        defer { isSaving = false }
        if await model.saveRoutineDirectSession(edit, conversationID: conversationID,
            memoryAccess: allowsSavedFacts ? .savedFacts : .none) { dismiss() }
    }
}
