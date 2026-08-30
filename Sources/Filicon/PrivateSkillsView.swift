import AppKit
import SwiftUI
import FiliconPlugins

struct PrivateSkillsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var editor: Editor?
    @State private var removeCandidate: PrivateSkillRecord?
    @State private var importID = ""
    @State private var showingImportID = false

    var body: some View {
        Group {
            SkillPublishingSection()
            Section("Private Skills") {
            HStack {
                Button("New Skill") { editor = .create }
                Button("Import…") { importID = ""; showingImportID = true }
                Spacer()
                Text("Stored locally on this Mac").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.privateSkills) { skill in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                        Text(skill.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        Task { if let value = await model.privateSkillDocument(id: skill.id) { editor = .edit(value) } }
                    }
                    Button("Export…") { export(skill) }
                    Button("Delete", role: .destructive) { removeCandidate = skill }
                }
            }
            if model.privateSkills.isEmpty {
                Text("Create or import a SKILL.md directory to add reusable private instructions.")
                    .foregroundStyle(.secondary)
            }
            }
        }
        .sheet(item: $editor) { value in
            PrivateSkillEditor(editor: value)
        }
        .sheet(isPresented: $showingImportID) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Import Private Skill").font(.headline)
                TextField("New skill identifier", text: $importID)
                Text("Use lowercase letters, numbers, periods, underscores, or hyphens.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showingImportID = false }
                    Button("Choose Source…") {
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
            "Delete “\(removeCandidate?.name ?? "")”?",
            isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } })
        ) {
            Button("Delete Skill", role: .destructive) {
                guard let id = removeCandidate?.id else { return }
                removeCandidate = nil
                Task { await model.removePrivateSkill(id: id) }
            }
            Button("Cancel", role: .cancel) { removeCandidate = nil }
        } message: {
            Text("This removes the local skill directory. This action cannot be undone in Filicon.")
        }
    }

    private func chooseImport(id: String) {
        let panel = NSOpenPanel()
        panel.title = "Choose a SKILL.md directory or archive"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.importPrivateSkill(from: url, id: id) }
    }

    private func export(_ skill: PrivateSkillRecord) {
        let panel = NSOpenPanel()
        panel.title = "Choose an export folder"
        panel.prompt = "Export"
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
        VStack(alignment: .leading, spacing: 12) {
            Text(replacing ? "Edit Private Skill" : "New Private Skill").font(.headline)
            TextField("Identifier", text: $id).disabled(replacing)
            TextField("Name", text: $name)
            TextField("Description", text: $description)
            Text("Instructions").font(.caption.bold())
            TextEditor(text: $bodyText).font(.system(.body, design: .monospaced)).border(.quaternary).frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.disabled(saving)
                Button(saving ? "Saving…" : "Save") {
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
