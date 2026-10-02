import SwiftUI
import FiliconAgents
import FiliconAppServices
import FiliconAutomations

struct RoutineGroupSessionEdit: Identifiable {
    let id = UUID()
    let automation: Automation
    let accountID: String
    let generation: UInt64
    let binding: AutomationGroupSessionBinding?
    let groups: [AgentGroup]
}

/// This sheet is an explicit human consent surface, not part of the model's
/// routine-definition API. Existing scopes are not silently inherited.
struct RoutineGroupSessionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let edit: RoutineGroupSessionEdit
    @State private var groupID: UUID?
    @State private var allowsSavedFacts = false
    @State private var isSaving = false

    init(edit: RoutineGroupSessionEdit) {
        self.edit = edit
        _groupID = State(initialValue: edit.binding?.accountID == edit.accountID ? edit.binding?.groupID : nil)
        _allowsSavedFacts = State(initialValue: edit.binding?.accountID == edit.accountID && edit.binding?.memoryAccess == .savedFacts)
    }

    var body: some View {
        let _ = locale.identifier
        Form {
            Section(l10n("Background group session")) {
                Text(edit.automation.name).font(.headline)
                Text(edit.automation.prompt).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Picker(l10n("Group"), selection: $groupID) {
                    Text(l10n("Choose…")).tag(nil as UUID?)
                    ForEach(edit.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }
                if let group = edit.groups.first(where: { $0.id == groupID }) {
                    Text(group.memberIDs.compactMap { id in model.agents.first { $0.id == id }?.name }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                    if !group.summary.isEmpty {
                        Text(group.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(l10n("Scheduled, event and manual runs will use this exact group's shared runner and transcript. Each member uses its own model and persona. Tools retain their existing approval gates; this does not grant file, browser, connection or action permissions. Busy groups are not interrupted or retried. Changes to the routine, group or members require another review."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(l10n("Runs may incur model costs; no price or whole-group budget guarantee is provided."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(l10n("Background memory consent")) {
                Toggle(l10n("Allow saved facts for this background group"), isOn: $allowsSavedFacts)
                Text(l10n("New, independent consent: each reviewed member may send its own permitted private facts, shared user facts and joined-project facts to its configured model provider during this routine. Existing scope and project membership restrictions still apply. Delegation outside this group does not extend memory consent. This does not authorize publishing unrelated private facts or collecting suggestions, episodes or synthesis from routine seeds. Off disables memory recall, search and changes for this run."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(l10n("Cancel"), role: .cancel) {
                    dismiss()
                }
                .disabled(isSaving)
                Spacer()
                Button(l10n("Approve group session")) {
                    Task { await approveGroupSession() }
                }
                .disabled(groupID == nil || isSaving)
                .accessibilityIdentifier("routine-group-session-approve")
            }
        }
        .formStyle(.grouped).padding()
        .frame(minWidth: 560, idealWidth: 600, maxWidth: 640, minHeight: 460, idealHeight: 640)
        .interactiveDismissDisabled(isSaving)
    }

    private func approveGroupSession() async {
        guard let groupID else { return }
        isSaving = true
        defer { isSaving = false }
        if await model.saveRoutineGroupSession(edit, groupID: groupID,
            memoryAccess: allowsSavedFacts ? .savedFacts : .none) {
            dismiss()
        }
    }
}
