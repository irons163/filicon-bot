import SwiftUI
import UniformTypeIdentifiers
import FiliconAgents

struct AutomationWorkspaceView: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            RoutineAutomationWorkspaceView()
                .tabItem { Label("Routines", systemImage: "clock.arrow.circlepath") }
                .tag(0)
            WorkflowWorkspaceView()
                .tabItem { Label("Workflows", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(1)
        }
        .navigationTitle(selection == 0 ? "Automations" : "Workflows")
    }
}

private struct WorkflowWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: WorkflowEditorDraft?
    @State private var importText = ""
    @State private var importURL = ""
    @State private var showingFileImporter = false

    var body: some View {
        Form {
            if model.workflowIsLoading {
                Section { ProgressView("Loading workflows…").accessibilityIdentifier("workflow-loading") }
            }
            if let error = model.workflowError, !error.isEmpty {
                Section("Workflow error") {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                        .accessibilityIdentifier("workflow-error")
                    Button("Dismiss") { model.workflowError = nil }
                }
            }
            Section("Import") {
                TextEditor(text: $importText).frame(minHeight: 70)
                    .accessibilityLabel("SKILL markdown")
                HStack {
                    Button("Import text") {
                        let value = importText
                        Task { if await model.importWorkflowText(value) { importText = "" } }
                    }.disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Import file…") { showingFileImporter = true }
                    Button("Import private skills") { Task { await model.importPrivateSkillsAsWorkflows() } }
                }
                HStack {
                    TextField("Public HTTPS SKILL URL", text: $importURL)
                        .accessibilityLabel("Workflow import URL")
                    Button("Link source") {
                        let value = importURL
                        Task { if await model.importWorkflowURL(value) { importURL = "" } }
                    }.disabled(importURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Imports are bounded and accept text, a regular SKILL file, private skills already stored by Filicon, or a live public HTTPS source reference.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("New workflow") { editor = .new(defaultAgentID: model.agents.first(where: { $0.archivedAt == nil })?.id) }
                    .disabled(model.agents.allSatisfy { $0.archivedAt != nil })
            }
            Section("Workflows") {
                if model.workflows.isEmpty, !model.workflowIsLoading {
                    ContentUnavailableView("No workflows", systemImage: "point.3.connected.trianglepath.dotted", description: Text("Create or import a workflow to run it here."))
                        .accessibilityIdentifier("workflow-empty-state")
                }
                ForEach(model.workflows) { workflow in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workflow.description.isEmpty ? "No description" : workflow.description)
                                .foregroundStyle(.secondary)
                            Text(workflow.steps.compactMap { if case .prompt(let text) = $0 { text } else { nil } }.joined(separator: "\n"))
                                .lineLimit(5).textSelection(.enabled)
                            HStack {
                                Button("Edit") { editor = .init(workflow: workflow) }
                                Button("Run Now") { Task { await model.runWorkflowNow(id: workflow.id) } }
                                    .disabled(workflow.agentID == nil)
                                Button("Cancel") { Task { await model.cancelWorkflow(id: workflow.id) } }
                                Button("Delete", role: .destructive) { Task { await model.deleteWorkflow(id: workflow.id) } }
                            }
                        }.padding(.top, 4)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(workflow.name)
                                Text(triggerSummary(workflow.trigger)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { workflow.isEnabled },
                                set: { enabled in Task { await model.setWorkflowEnabled(id: workflow.id, enabled: enabled) } }
                            )).labelsHidden().accessibilityLabel("Enable \(workflow.name)")
                        }
                    }
                    .accessibilityIdentifier("workflow-row-\(workflow.id)")
                }
            }
            Section("Run history") {
                if model.workflowRuns.isEmpty {
                    Text("No workflow runs yet").foregroundStyle(.secondary)
                }
                ForEach(model.workflowRuns) { run in
                    HStack(alignment: .top) {
                        Label(run.status.rawValue.capitalized, systemImage: run.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                        VStack(alignment: .leading) {
                            Text(model.workflows.first(where: { $0.id == run.workflowID })?.name ?? run.workflowID)
                            Text(run.startedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            if let failure = run.failure { Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3) }
                        }
                        Spacer()
                        if run.status == .running {
                            Button("Cancel") { Task { await model.cancelWorkflowRun(id: run.id) } }
                        } else {
                            Button("Replay") { Task { await model.replayWorkflowRun(id: run.id) } }
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
        case .manual: "Manual"
        case .event(let event): "Event · \(event)"
        case .schedule(let schedule): "Schedule · \(schedule)"
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
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: WorkflowEditorDraft

    var body: some View {
        Form {
            Picker("Agent", selection: $draft.agentID) {
                Text("Choose…").tag(nil as UUID?)
                ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField("Workflow ID", text: $draft.workflowID).disabled(draft.replacingID != nil)
            TextField("Name", text: $draft.name)
            TextField("Description", text: $draft.description, axis: .vertical)
            Picker("Trigger", selection: $draft.trigger) {
                ForEach(WorkflowTriggerDraft.allCases) { Text($0.rawValue).tag($0) }
            }
            if draft.trigger != .manual {
                TextField(draft.trigger == .schedule ? "Cron or @every expression" : "connector:<uuid>:<kind>", text: $draft.triggerValue)
                    .accessibilityLabel("Workflow trigger value")
            }
            TextEditor(text: $draft.prompt).frame(minHeight: 150).accessibilityLabel("Workflow prompt")
            Text("Prompt steps use only the selected agent's provider, model, and instructions. User-effect actions are denied until per-run consent is available.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(!isValid)
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
