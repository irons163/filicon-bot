import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FiliconAgents
import FiliconAppServices

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
    @State private var sessionEdit: WorkflowDirectSessionEdit?

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
                            if let binding = model.workflowDirectBindings.first(where: { $0.workflowID == workflow.id }) {
                                let sameAccount = binding.accountID == (model.settings.accountScope ?? "local")
                                Text(sameAccount ? l10n("Workflow agent session") + " · " + binding.conversationTitle
                                    : FiliconLocalization.string(WorkflowDirectSessionError.anotherAccount.rawValue))
                                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                                HStack {
                                    Button(l10n("Review workflow session")) { sessionEdit = model.beginWorkflowDirectSessionEdit(workflow) }
                                    Button(l10n("Open conversation")) { model.selectRoute(.conversation(binding.conversationID)) }
                                        .disabled(!sameAccount)
                                    Button(l10n("Revoke workflow session"), role: .destructive) { Task { await model.revokeWorkflowDirectSession(binding) } }
                                        .disabled(!sameAccount)
                                }
                            } else {
                                Text(l10n("Text-only · no background session consent")).font(.caption).foregroundStyle(.secondary)
                                Button(l10n("Review workflow session")) { sessionEdit = model.beginWorkflowDirectSessionEdit(workflow) }
                                    .disabled(workflow.agentID == nil)
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
                        Label(run.status == .waitingForReply ? l10n("Waiting for reply") : FiliconLocalization.string(run.status.rawValue.capitalized), systemImage: run.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
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
        .sheet(item: $sessionEdit) { edit in WorkflowDirectSessionView(edit: edit) }
    }

    private func triggerSummary(_ trigger: AgentWorkflowTrigger) -> String {
        switch trigger {
        case .manual: l10n("Manual")
        case .event(let event): l10n("Event · \(event)")
        case .schedule(let schedule): l10n("Schedule · \(schedule)")
        }
    }
}

enum WorkflowTriggerDraft: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case event = "Authenticated event"
    case schedule = "Schedule"
    var id: String { rawValue }
}

enum WorkflowEditorStepKind: String, Equatable {
    case prompt, action
}

struct WorkflowEditorStepDraft: Identifiable, Equatable {
    let id: String
    let kind: WorkflowEditorStepKind
    var prompt: String
    var actionName: String
    var actionPayload: String

    init(id: String, step: AgentWorkflowStep) {
        self.id = id
        switch step {
        case .prompt(let text):
            kind = .prompt; prompt = text; actionName = ""; actionPayload = ""
        case .action(let name, let payload):
            kind = .action; prompt = ""; actionName = name; actionPayload = payload
        }
    }

    var step: AgentWorkflowStep {
        switch kind {
        case .prompt: .prompt(prompt)
        case .action: .action(name: actionName, payload: actionPayload)
        }
    }
}

/// The editor changes descriptive values and ordered recipe steps, not execution authority.
/// Fields not edited here remain from the original definition rather than a new workflow default.
struct WorkflowEditorDraft: Identifiable {
    let id = UUID()
    private var original: AgentWorkflow?
    var replacingID: String?
    var workflowID: String
    var agentID: UUID?
    var name: String
    var description: String
    var isEnabled: Bool
    var trigger: WorkflowTriggerDraft
    var triggerValue: String
    var steps: [WorkflowEditorStepDraft]
    var sourceReference: String

    static func new(defaultAgentID: UUID?) -> Self {
        .init(defaultAgentID: defaultAgentID)
    }

    init(workflow: AgentWorkflow) {
        original = workflow
        replacingID = workflow.id; workflowID = workflow.id; agentID = workflow.agentID
        name = workflow.name; description = workflow.description; isEnabled = workflow.isEnabled
        switch workflow.trigger {
        case .manual: trigger = .manual; triggerValue = ""
        case .event(let value): trigger = .event; triggerValue = value
        case .schedule(let value): trigger = .schedule; triggerValue = value
        }
        steps = workflow.steps.enumerated().map { .init(id: "step-\($0.offset)", step: $0.element) }
        sourceReference = workflow.sourceReference ?? ""
    }

    private init(defaultAgentID: UUID?) {
        replacingID = nil; workflowID = ""; agentID = defaultAgentID
        name = ""; description = ""; isEnabled = true; trigger = .manual; triggerValue = ""
        steps = [.init(id: "step-0", step: .prompt(""))]; sourceReference = ""
    }

    func workflow(at date: Date) throws -> AgentWorkflow {
        let identifier = replacingID ?? (workflowID.isEmpty ? AgentWorkflow.slug(name) : workflowID)
        var result = original ?? AgentWorkflow(id: identifier, name: name, steps: [], createdAt: date)
        result.id = identifier; result.agentID = agentID; result.name = name; result.description = description
        result.isEnabled = isEnabled; result.updatedAt = date
        result.trigger = switch trigger {
        case .manual: .manual
        case .event: .event(triggerValue)
        case .schedule: .schedule(triggerValue)
        }
        result.steps = steps.map(\.step)
        result.sourceReference = sourceReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : sourceReference
        return try result.validated()
    }

    var isValid: Bool { agentID != nil && (try? workflow(at: .distantPast)) != nil }

    mutating func addStep(_ kind: WorkflowEditorStepKind, id: String = UUID().uuidString.lowercased()) {
        guard steps.count < AgentWorkflowLimits.maximumSteps, !steps.contains(where: { $0.id == id }) else { return }
        steps.append(.init(id: id, step: kind == .prompt ? .prompt("") : .action(name: "", payload: "")))
    }

    mutating func moveStep(id: String, offset: Int) {
        guard offset == -1 || offset == 1, let index = steps.firstIndex(where: { $0.id == id }),
              steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
    }

    mutating func removeStep(id: String) {
        guard steps.count > 1 else { return }
        steps.removeAll { $0.id == id }
    }
}

struct WorkflowEditorView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var draft: WorkflowEditorDraft
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
        Form {
          Section(l10n("Workflow")) {
            Picker(l10n("Agent"), selection: $draft.agentID) {
                Text(l10n("Choose…")).tag(nil as UUID?)
                ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
            }
            TextField(l10n("Workflow ID"), text: $draft.workflowID).disabled(draft.replacingID != nil)
            TextField(l10n("Name"), text: $draft.name)
            TextField(l10n("Description"), text: $draft.description, axis: .vertical)
            Toggle(l10n("Enabled"), isOn: $draft.isEnabled)
            Picker(l10n("Trigger"), selection: $draft.trigger) {
                ForEach(WorkflowTriggerDraft.allCases) { Text(FiliconLocalization.string($0.rawValue)).tag($0) }
            }
            if draft.trigger != .manual {
                TextField(draft.trigger == .schedule ? l10n("Cron or @every expression") : l10n("connector:<uuid>:<kind>"), text: $draft.triggerValue)
                    .accessibilityLabel(l10n("Workflow trigger value"))
            }
          }
          ForEach($draft.steps) { $step in
            let number = (draft.steps.firstIndex { $0.id == step.id } ?? 0) + 1
            Section(step.kind == .prompt ? l10n("Prompt step \(number)") : l10n("Action step \(number) · \(step.actionName)")) {
                if step.kind == .prompt {
                    TextEditor(text: $step.prompt).frame(minHeight: 110)
                        .accessibilityLabel(l10n("Workflow prompt"))
                } else {
                    TextField(l10n("Action name"), text: $step.actionName)
                    TextEditor(text: $step.actionPayload).frame(minHeight: 110)
                        .accessibilityLabel(l10n("Action payload"))
                }
                HStack {
                    Button { draft.moveStep(id: step.id, offset: -1) } label: { Image(systemName: "arrow.up") }
                        .accessibilityLabel(l10n("Move step up")).help(l10n("Move step up")).disabled(number == 1)
                    Button { draft.moveStep(id: step.id, offset: 1) } label: { Image(systemName: "arrow.down") }
                        .accessibilityLabel(l10n("Move step down")).help(l10n("Move step down")).disabled(number == draft.steps.count)
                    Spacer()
                    Button(l10n("Remove step"), role: .destructive) { draft.removeStep(id: step.id) }
                        .disabled(draft.steps.count == 1)
                }
            }.accessibilityIdentifier("workflow-editor-\(step.id)")
          }
          Section {
            HStack {
                Button(l10n("Add prompt step")) { draft.addStep(.prompt) }
                Button(l10n("Add action step")) { draft.addStep(.action) }
            }.disabled(draft.steps.count >= AgentWorkflowLimits.maximumSteps)
            TextField(l10n("Source reference"), text: $draft.sourceReference, axis: .vertical)
            Text(l10n("Editing preserves the ordered steps, source and enabled state. Changing the recipe requires reviewing its session consent again."))
                .font(.caption).foregroundStyle(.secondary)
            Text(l10n("Without reviewed session consent, prompt steps are text-only. A reviewed session enables the existing conversation runner with its current tool approvals; workflow action steps remain denied."))
                .font(.caption).foregroundStyle(.secondary)
          }
          if let saveError {
            Section { Text(FiliconLocalization.message(saveError)).foregroundStyle(.red).textSelection(.enabled) }
          }
        }.formStyle(.grouped).disabled(isSaving)
        Divider()
        WorkflowEditorFooter(isSaving: isSaving, canSave: draft.isValid,
            saveButtonTapped: { Task { await saveButtonTapped() } }, cancelButtonTapped: { dismiss() })
            .frame(height: 56)
        }.frame(minWidth: 600, idealWidth: 640, maxWidth: 640, minHeight: 560, idealHeight: 760)
            .interactiveDismissDisabled(isSaving)
    }

    private func saveButtonTapped() async {
        guard draft.isValid, !isSaving else { return }
        isSaving = true; saveError = nil
        defer { isSaving = false }
        do {
            let workflow = try draft.workflow(at: .now)
            if await model.saveWorkflow(workflow, replacingID: draft.replacingID) { dismiss() }
            else { saveError = model.workflowError ?? AgentWorkflowError.notFound.localizedDescription }
        } catch { saveError = error.localizedDescription }
    }
}

/// Native controls keep the persistent footer keyboard-accessible while the recipe scrolls.
/// The parent still validates and saves the complete draft through AppModel.
struct WorkflowEditorFooter: NSViewRepresentable {
    var isSaving: Bool
    var canSave: Bool
    var saveButtonTapped: () -> Void
    var cancelButtonTapped: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSView {
        let view = WorkflowEditorFooterControls()
        view.save.target = context.coordinator; view.save.action = #selector(Coordinator.saveButtonTapped)
        view.cancel.target = context.coordinator; view.cancel.action = #selector(Coordinator.cancelButtonTapped)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let view = view as? WorkflowEditorFooterControls else { return }
        context.coordinator.parent = self
        view.save.title = l10n("Save"); view.cancel.title = l10n("Cancel")
        view.save.isEnabled = canSave && !isSaving; view.cancel.isEnabled = !isSaving
        view.progress.isHidden = !isSaving
        if isSaving { view.progress.startAnimation(nil) } else { view.progress.stopAnimation(nil) }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: WorkflowEditorFooter
        init(_ parent: WorkflowEditorFooter) { self.parent = parent }
        @objc func saveButtonTapped() { if parent.canSave && !parent.isSaving { parent.saveButtonTapped() } }
        @objc func cancelButtonTapped() { if !parent.isSaving { parent.cancelButtonTapped() } }
    }
}

@MainActor private final class WorkflowEditorFooterControls: NSView {
    let save = NSButton(title: "", target: nil, action: nil)
    let cancel = NSButton(title: "", target: nil, action: nil)
    let progress = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        save.bezelStyle = .rounded; save.keyEquivalent = "\r"
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        for child in [save, cancel, progress] {
            child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child)
        }
        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            cancel.centerYAnchor.constraint(equalTo: centerYAnchor),
            save.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            save.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.trailingAnchor.constraint(equalTo: save.leadingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 56) }

    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.intersection(bounds).fill() }
}
