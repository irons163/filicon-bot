import SwiftUI
import UniformTypeIdentifiers
import FiliconAgents

struct AutomationWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @State private var selection = 0

    var body: some View {
        let _ = uiLocale.identifier
        TabView(selection: $selection) {
            RoutineAutomationWorkspaceView()
                .tabItem { Label(l10n("Routines"), systemImage: "clock.arrow.circlepath") }
                .tag(0)
            WorkflowWorkspaceView()
                .tabItem { Label(l10n("Workflows"), systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(1)
        }
        .navigationTitle(selection == 0 ? l10n("Automations") : l10n("Workflows"))
    }
}

private struct WorkflowWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var editor: WorkflowEditorDraft?
    @State private var importText = ""
    @State private var importURL = ""
    @State private var showingFileImporter = false

    var body: some View {
        let _ = uiLocale.identifier
        Form {
            if model.workflowIsLoading {
                Section { ProgressView("Loading workflows…").accessibilityIdentifier("workflow-loading") }
            }
            if let error = model.workflowError, !error.isEmpty {
                Section(l10n("Workflow error")) {
                    Text(FiliconLocalization.message(error)).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("workflow-error")
                    Button(l10n("Dismiss")) { model.workflowError = nil }
                }
            }
            Section(l10n("Import")) {
                TextEditor(text: $importText).frame(minHeight: 70)
                    .accessibilityLabel(l10n("SKILL markdown"))
                HStack {
                    Button(l10n("Import text")) {
                        let value = importText
                        Task { if await model.importWorkflowText(value) { importText = "" } }
                    }.disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(l10n("Import file…")) { showingFileImporter = true }
                    Button(l10n("Import private skills")) { Task { await model.importPrivateSkillsAsWorkflows() } }
                }
                HStack {
                    TextField(l10n("Public HTTPS SKILL URL"), text: $importURL)
                        .accessibilityLabel(l10n("Workflow import URL"))
                    Button(l10n("Link source")) {
                        let value = importURL
                        Task { if await model.importWorkflowURL(value) { importURL = "" } }
                    }.disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(l10n("Imports are bounded and accept text, a regular SKILL file, private skills already stored by Filicon, or a live public HTTPS source reference."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button(l10n("New workflow")) { editor = .new(defaultAgentID: model.agents.first(where: { $0.archivedAt == nil })?.id) }
                    .disabled(model.agents.allSatisfy { $0.archivedAt != nil })
            }
            Section(l10n("Workflows")) {
                if model.workflows.isEmpty, !model.workflowIsLoading {
                    ContentUnavailableView(l10n("No workflows"), systemImage: "point.3.connected.trianglepath.dotted", description: Text(l10n("Create or import a workflow to run it here.")))
                        .accessibilityIdentifier("workflow-empty-state")
                }
                ForEach(model.workflows) { workflow in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workflow.description.isEmpty ? l10n("No description") : workflow.description)
                                .foregroundStyle(.secondary)
                            Text(workflow.steps.compactMap { if case .prompt(let text) = $0 { text } else { nil } }.joined(separator: "\n"))
                                .lineLimit(5).textSelection(.enabled)
                            HStack {
                                Button(l10n("Edit")) { editor = .init(workflow: workflow) }
                                Button(l10n("Run Now")) { Task { await model.runWorkflowNow(id: workflow.id) } }
                                    .disabled(workflow.agentID == nil)
                                Button(l10n("Cancel")) { Task { await model.cancelWorkflow(id: workflow.id) } }
                                Button(l10n("Delete"), role: .destructive) { Task { await model.deleteWorkflow(id: workflow.id) } }
                            }
                        }.padding(.top, 4)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(workflow.name)
                                Text(triggerSummary(workflow.trigger)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(l10n("Enabled"), isOn: Binding(
                                get: { workflow.isEnabled },
                                set: { enabled in Task { await model.setWorkflowEnabled(id: workflow.id, enabled: enabled) } }
                            )).labelsHidden().accessibilityLabel(l10n("Enable \(workflow.name)"))
                        }
                    }
                    .accessibilityIdentifier("workflow-row-\(workflow.id)")
                }
            }
            Section(l10n("Run history")) {
                if model.workflowRuns.isEmpty {
                    Text(l10n("No workflow runs yet")).foregroundStyle(.secondary)
                }
                ForEach(model.workflowRuns) { run in
                    HStack(alignment: .top) {
                        Label(FiliconLocalization.string(run.status.rawValue.capitalized), systemImage: run.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                        VStack(alignment: .leading) {
                            Text(model.workflows.first(where: { $0.id == run.workflowID })?.name ?? run.workflowID)
                            Text(run.startedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if let failure = run.failure { Text(FiliconLocalization.message(failure)).font(.caption).foregroundStyle(.red).lineLimit(3) }
                        }
                        Spacer()
                        if run.status == .running {
                            Button(l10n("Cancel")) { Task { await model.cancelWorkflowRun(id: run.id) } }
                        } else {
                            Button(l10n("Replay")) { Task { await model.replayWorkflowRun(id: run.id) } }
                        }
                    }.accessibilityIdentifier("workflow-run-\(run.id.uuidString.lowercased())")
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.reloadWorkflows() }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.plainText], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { _ = await model.importWorkflowFile(url) } }
            case .failure(let error): model.workflowError = error.localizedDescription
            }
        }
        .sheet(item: $editor) { draft in WorkflowEditorView(draft: draft) }
    }

    private func triggerSummary(_ trigger: AgentWorkflowTrigger) -> String {
        switch trigger {
        case .manual: l10n("Manual")
        case .event(let event): l10n("Event · \(event)")
        case .schedule(let schedule): l10n("Schedule · \(schedule)")
        }
    }
}

private enum WorkflowTriggerDraft: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case event = "Authenticated event"
    case schedule = "Schedule"
    var id: String { rawValue }
}

private struct WorkflowEditorDraft: Identifiable {
    let id = UUID()
    var replacingID: String?
    var workflowID: String
    var agentID: UUID?
    var name: String
    var description: String
    var trigger: WorkflowTriggerDraft
    var triggerValue: String
    var prompt: String

    static func new(defaultAgentID: UUID?) -> Self {
        .init(replacingID: nil, workflowID: "", agentID: defaultAgentID, name: "", description: "", trigger: .manual, triggerValue: "", prompt: "")
    }

    init(workflow: AgentWorkflow) {
        replacingID = workflow.id; workflowID = workflow.id; agentID = workflow.agentID
        name = workflow.name; description = workflow.description
        switch workflow.trigger {
        case .manual: trigger = .manual; triggerValue = ""
        case .event(let value): trigger = .event; triggerValue = value
        case .schedule(let value): trigger = .schedule; triggerValue = value
        }
        prompt = workflow.steps.compactMap { if case .prompt(let value) = $0 { value } else { nil } }.joined(separator: "\n\n")
    }

    private init(replacingID: String?, workflowID: String, agentID: UUID?, name: String, description: String,
                 trigger: WorkflowTriggerDraft, triggerValue: String, prompt: String) {
        self.replacingID = replacingID; self.workflowID = workflowID; self.agentID = agentID
        self.name = name; self.description = description; self.trigger = trigger
        self.triggerValue = triggerValue; self.prompt = prompt
    }
}

private struct WorkflowEditorView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: WorkflowEditorDraft

    var body: some View {
        let _ = uiLocale.identifier
        Form {
            Picker(l10n("Agent"), selection: $draft.agentID) {
                Text(l10n("Choose…")).tag(nil as UUID?)
                ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField(l10n("Workflow ID"), text: $draft.workflowID).disabled(draft.replacingID != nil)
            TextField(l10n("Name"), text: $draft.name)
            TextField(l10n("Description"), text: $draft.description, axis: .vertical)
            Picker(l10n("Trigger"), selection: $draft.trigger) {
                ForEach(WorkflowTriggerDraft.allCases) { Text(FiliconLocalization.string($0.rawValue)).tag($0) }
            }
            if draft.trigger != .manual {
                TextField(draft.trigger == .schedule ? l10n("Cron or @every expression") : l10n("connector:<uuid>:<kind>"), text: $draft.triggerValue)
                    .accessibilityLabel(l10n("Workflow trigger value"))
            }
            TextEditor(text: $draft.prompt).frame(minHeight: 150).accessibilityLabel(l10n("Workflow prompt"))
            Text(l10n("Prompt steps use only the selected agent's provider, model, and instructions. User-effect actions are denied until per-run consent is available."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l10n("Cancel"), role: .cancel) { dismiss() }
                Spacer()
                Button(l10n("Save")) { save() }.keyboardShortcut(.defaultAction).disabled(!isValid)
            }
        }.padding().frame(minWidth: 520, minHeight: 480)
    }

    private var isValid: Bool {
        draft.agentID != nil && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (draft.trigger == .manual || !draft.triggerValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func save() {
        guard let agentID = draft.agentID else { return }
        let trigger: AgentWorkflowTrigger = switch draft.trigger {
        case .manual: .manual
        case .event: .event(draft.triggerValue)
        case .schedule: .schedule(draft.triggerValue)
        }
        let identifier = draft.replacingID ?? (draft.workflowID.isEmpty ? AgentWorkflow.slug(draft.name) : draft.workflowID)
        let workflow = AgentWorkflow(
            id: identifier, agentID: agentID, name: draft.name, description: draft.description,
            trigger: trigger, steps: [.prompt(draft.prompt)]
        )
        Task { if await model.saveWorkflow(workflow, replacingID: draft.replacingID) { dismiss() } }
    }
}
