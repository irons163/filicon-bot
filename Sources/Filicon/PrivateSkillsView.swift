import AppKit
import SwiftUI
import FiliconPlugins

struct PrivateSkillsSection: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var editor: Editor?
    @State private var removeCandidate: PrivateSkillRecord?
    @State private var importID = ""
    @State private var showingImportID = false

    var body: some View {
        let _ = uiLocale.identifier
        Group {
            SkillPublishingSection()
            Section(l10n("Private Skills")) {
            HStack {
                Button(l10n("New Skill")) { editor = .create }
                Button(l10n("Import…")) { importID = ""; showingImportID = true }
                Spacer()
                Text(l10n("Stored locally on this Mac")).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.privateSkills) { skill in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                        Text(skill.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n("Edit")) {
                        Task { if let value = await model.privateSkillDocument(id: skill.id) { editor = .edit(value) } }
                    }
                    Button(l10n("Export…")) { export(skill) }
                    Button(l10n("Delete"), role: .destructive) { removeCandidate = skill }
                }
            }
            if model.privateSkills.isEmpty {
                Text(l10n("Create or import a SKILL.md directory to add reusable private instructions."))
                    .foregroundStyle(.secondary)
            }
            }
        }
        .sheet(item: $editor) { value in
            PrivateSkillEditor(editor: value)
        }
        .sheet(isPresented: $showingImportID) {
            VStack(alignment: .leading, spacing: 14) {
                Text(l10n("Import Private Skill")).font(.headline)
                TextField(l10n("New skill identifier"), text: $importID)
                Text(l10n("Use lowercase letters, numbers, periods, underscores, or hyphens.")).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(l10n("Cancel")) { showingImportID = false }
                    Button(l10n("Choose Source…")) {
                        let id = importID
                        showingImportID = false
                        chooseImport(id: id)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 440)
        }
        .confirmationDialog(
            l10n("Delete “\(removeCandidate?.name ?? "")”?"),
            isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } })
        ) {
            Button(l10n("Delete Skill"), role: .destructive) {
                guard let id = removeCandidate?.id else { return }
                removeCandidate = nil
                Task { await model.removePrivateSkill(id: id) }
            }
            Button(l10n("Cancel"), role: .cancel) { removeCandidate = nil }
        } message: {
            Text(l10n("This removes the local skill directory. This action cannot be undone in Filicon."))
        }
    }

    private func chooseImport(id: String) {
        let panel = NSOpenPanel()
        panel.title = l10n("Choose a SKILL.md directory or archive")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importPrivateSkill(from: url, id: id) }
    }

    private func export(_ skill: PrivateSkillRecord) {
        let panel = NSOpenPanel()
        panel.title = l10n("Choose an export folder")
        panel.prompt = l10n("Export")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.exportPrivateSkill(id: skill.id, to: url) }
    }

    enum Editor: Identifiable {
        case create
        case edit(PrivateSkillDocument)
        var id: String { switch self { case .create: "create"; case .edit(let value): value.record.id } }
    }
}

private struct PrivateSkillEditor: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let editor: PrivateSkillsSection.Editor
    @State private var id: String
    @State private var name: String
    @State private var description: String
    @State private var bodyText: String
    @State private var saving = false

    init(editor: PrivateSkillsSection.Editor) {
        self.editor = editor
        switch editor {
        case .create:
            _id = State(initialValue: "")
            _name = State(initialValue: "")
            _description = State(initialValue: "")
            _bodyText = State(initialValue: "")
        case .edit(let document):
            _id = State(initialValue: document.record.id)
            _name = State(initialValue: document.record.name)
            _description = State(initialValue: document.record.description)
            _bodyText = State(initialValue: document.body)
        }
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 12) {
            Text(replacing ? l10n("Edit Private Skill") : l10n("New Private Skill")).font(.headline)
            TextField(l10n("Identifier"), text: $id).disabled(replacing)
            TextField(l10n("Name"), text: $name)
            TextField(l10n("Description"), text: $description)
            Text(l10n("Instructions")).font(.caption.bold())
            TextEditor(text: $bodyText).font(.system(.body, design: .monospaced)).border(.quaternary).frame(minHeight: 260)
            HStack {
                Spacer()
                Button(l10n("Cancel")) { dismiss() }.disabled(saving)
                Button(saving ? l10n("Saving…") : l10n("Save")) {
                    saving = true
                    Task {
                        if await model.savePrivateSkill(id: id, name: name, description: description, body: bodyText, replacing: replacing) { dismiss() }
                        saving = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(20).frame(minWidth: 620, minHeight: 480)
    }

    private var replacing: Bool { if case .edit = editor { true } else { false } }
}
