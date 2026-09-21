import SwiftUI
import UniformTypeIdentifiers
import FiliconDomain
import FiliconAgents

struct AgentsWorkspaceScreen: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var section = Section.roster
    @State private var inspectedAgent: AgentProfile?
    @State private var creatingAgent = false

    private enum Section: String, CaseIterable, Identifiable {
        case roster = "Roster"
        case messages = "Messages"
        case organization = "Org Chart"
        case tasks = "Async Tasks"
        case cloud = "Cloud Catalog"
        var id: Self { self }
        var title: String { agentString(rawValue) }
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack {
                Picker(agentString("Agents workspace"), selection: $section) {
                    ForEach(Section.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                Button { creatingAgent = true } label: { Label(agentString("New Agent"), systemImage: "plus") }
                }
                HStack {
                    Picker(agentString("Agents workspace"), selection: $section) {
                        ForEach(Section.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().pickerStyle(.menu)
                    Spacer()
                    Button { creatingAgent = true } label: { Label(agentString("New Agent"), systemImage: "plus") }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding()
            Divider()
            Group {
            switch section {
            case .roster:
                AgentRosterView(inspectedAgent: $inspectedAgent)
            case .messages:
                AgentMessagingView()
            case .organization:
                AgentOrgChartView(inspectedAgent: $inspectedAgent)
            case .tasks:
                AgentAsyncTasksView()
            case .cloud:
                CloudAgentCatalogView()
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(agentString("Agents"))
        .sheet(item: $inspectedAgent) { profile in
            AgentEditorView(profile: profile, isNew: false)
        }
        .sheet(isPresented: $creatingAgent) {
            AgentEditorView(profile: AgentProfile(name: ""), isNew: true)
        }
        .onAppear(perform: openRequestedAgent)
        .onChange(of: model.requestedAgentInspectionID) { _, _ in openRequestedAgent() }
    }

    private func openRequestedAgent() {
        guard let id = model.requestedAgentInspectionID,
              let profile = model.agents.first(where: { $0.id == id }) else { return }
        section = .roster
        inspectedAgent = profile
        model.requestedAgentInspectionID = nil
        Task { await model.markAgentRead(id: id) }
    }
}

private struct CloudAgentCatalogView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let _ = uiLocale.identifier
        Group {
            if model.cloudAgentEndpoint.isEmpty {
                ContentUnavailableView(
                    agentString("Cloud agents are not configured"),
                    systemImage: "cloud.slash",
                    description: Text(agentString("Add a credential-free HTTPS endpoint and Keychain bearer reference in Settings."))
                )
            } else if model.cloudAgentCatalog.isEmpty && !model.isRefreshingCloudAgents {
                ContentUnavailableView(
                    agentString("No cloud agents"),
                    systemImage: "cloud",
                    description: Text(agentString("Refresh the remote catalog."))
                )
            } else {
                List(model.cloudAgentCatalog) { agent in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(agent.name).fontWeight(.medium)
                            Spacer()
                            Text(agentString(agent.status.rawValue.capitalized)).foregroundStyle(.secondary)
                        }
                        Text(agent.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let summary = agent.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { Task { await model.refreshCloudAgents() } } label: {
                if model.isRefreshingCloudAgents { ProgressView().controlSize(.small) }
                else { Label(agentString("Refresh"), systemImage: "arrow.clockwise") }
            }
            .disabled(model.isRefreshingCloudAgents)
            .padding()
        }
        .task { if model.cloudAgentCatalog.isEmpty && !model.cloudAgentEndpoint.isEmpty { await model.refreshCloudAgents() } }
    }
}

private struct AgentRosterView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Binding var inspectedAgent: AgentProfile?

    var body: some View {
        let _ = uiLocale.identifier
        let sections = AgentRosterSection.build(profiles: model.agents, pinnedIDs: model.pinnedAgentIDs)
        if sections.isEmpty {
            ContentUnavailableView(
                agentString("No agents yet"),
                systemImage: "person.2",
                description: Text(agentString("Create an agent to give it instructions and a model."))
            )
        } else {
            List {
                ForEach(sections) { section in
                    SwiftUI.Section(section.id.title) {
                        ForEach(section.agents) { profile in
                            AgentRosterRow(profile: profile, inspectedAgent: $inspectedAgent)
                        }
                    }
                }
            }
        }
    }
}

private extension AgentRosterSectionID {
    var title: String {
        let key = switch self { case .pinned: l10n("Pinned"); case .active: l10n("Active"); case .archived: l10n("Archived") }
        return agentString(key)
    }
}

private struct AgentRosterRow: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let profile: AgentProfile
    @Binding var inspectedAgent: AgentProfile?

    var body: some View {
        let _ = uiLocale.identifier
        HStack(spacing: 12) {
            AgentAvatarIcon(profile: profile, dimension: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(profile.name).fontWeight(.medium)
                    if !profile.title.isEmpty { Text(profile.title).foregroundStyle(.secondary) }
                }
                Text(profile.summary.isEmpty ? "\(profile.providerID.rawValue) · \(profile.modelID.rawValue)" : profile.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if profile.unreadCount > 0 {
                Text("\(profile.unreadCount)").font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.tint, in: Capsule()).foregroundStyle(.white)
            }
            AgentStatusLabel(status: profile.status)
            Menu {
                Button(agentString("Edit…")) { inspectedAgent = profile }
                Button(agentString(model.pinnedAgentIDs.contains(profile.id) ? l10n("Unpin") : l10n("Pin"))) { model.toggleAgentPinned(id: profile.id) }
                if profile.unreadCount > 0 { Button(agentString("Mark Read")) { Task { await model.markAgentRead(id: profile.id) } } }
                if profile.status == .failed { Button(agentString("Retry")) { Task { await model.retryAgent(id: profile.id) } } }
                Button(agentString("Clone")) { Task { await model.cloneAgent(id: profile.id) } }
                Divider()
                if profile.archivedAt == nil {
                    Button(agentString("Archive"), role: .destructive) { Task { await model.archiveAgent(id: profile.id) } }
                } else {
                    Button(agentString("Restore")) { Task { await model.restoreAgent(id: profile.id) } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture { inspectedAgent = profile }
        .opacity(profile.archivedAt == nil ? 1 : 0.62)
    }
}

private struct AgentStatusLabel: View {
    @Environment(\.locale) private var uiLocale
    let status: AgentAvailabilityStatus
    var body: some View {
        let _ = uiLocale.identifier
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .help(label)
    }
    private var label: String {
        let key = switch status { case .idle: l10n("Idle"); case .running: l10n("Running"); case .awaitingInput: l10n("Awaiting input"); case .failed: l10n("Failed"); case .offline: l10n("Offline") }
        return agentString(key)
    }
    private var color: Color {
        switch status { case .idle: .green; case .running: .blue; case .awaitingInput: .orange; case .failed: .red; case .offline: .gray }
    }
}

struct AgentEditorView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var profile: AgentProfile
    @State private var importingImage = false
    @State private var zoom = 1.0
    @State private var focusX = 0.5
    @State private var focusY = 0.5
    @State private var selectedAvatarKind: AgentAvatarKind
    @State private var characterValue: String
    @State private var colorHexValue: String
    @State private var selectedAvatarShape: AgentAvatarShape
    @State private var selectedPet: AgentPetAvatar
    @State private var saving = false
    @State private var saveError: String?
    let isNew: Bool
    let showsSharedAgentNotice: Bool
    let onSaved: ((AgentProfile) -> Void)?

    init(profile: AgentProfile, isNew: Bool, showsSharedAgentNotice: Bool = false, onSaved: ((AgentProfile) -> Void)? = nil) {
        _profile = State(initialValue: profile)
        _selectedAvatarKind = State(initialValue: profile.avatar?.kind ?? .character)
        _characterValue = State(initialValue: profile.avatar?.character ?? String(profile.name.prefix(2)))
        _colorHexValue = State(initialValue: profile.avatar?.colorHex ?? "#5B6CFF")
        _selectedAvatarShape = State(initialValue: profile.avatar?.shape ?? .circle)
        _selectedPet = State(initialValue: profile.avatar?.petID.flatMap(AgentPetAvatar.init(rawValue:)) ?? .codex)
        self.isNew = isNew
        self.showsSharedAgentNotice = showsSharedAgentNotice
        self.onSaved = onSaved
    }

    var body: some View {
        let _ = uiLocale.identifier
        Form {
            if showsSharedAgentNotice {
                Text(l10n("Changes to this agent apply to every group."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section(agentString("Identity")) {
                HStack(alignment: .top, spacing: 16) {
                    AgentAvatarIcon(profile: profile, dimension: 72)
                    VStack(alignment: .leading) {
                        Picker(agentString("Avatar"), selection: $selectedAvatarKind) {
                            Text(l10n("Built-in pets")).tag(AgentAvatarKind.pet)
                            Text(agentString("Character")).tag(AgentAvatarKind.character)
                            Text(agentString("Image")).tag(AgentAvatarKind.image)
                        }.pickerStyle(.segmented)
                        if selectedAvatarKind == .pet {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84))], spacing: 8) {
                                ForEach(AgentPetAvatar.allCases) { pet in
                                    Button { petButtonTapped(pet) } label: {
                                        VStack(spacing: 4) {
                                            PetAvatarImage(pet: pet).frame(width: 48, height: 52)
                                            Text(pet.name).font(.caption).lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity).padding(6)
                                        .background(selectedPet == pet ? Color.accentColor.opacity(0.16) : Color.clear)
                                        .clipShape(.rect(cornerRadius: 8))
                                        .overlay { RoundedRectangle(cornerRadius: 8).stroke(selectedPet == pet ? Color.accentColor : .clear, lineWidth: 2) }
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(pet.name)
                                    .accessibilityAddTraits(selectedPet == pet ? [.isSelected] : [])
                                    .accessibilityIdentifier("pet-avatar-\(pet.rawValue)")
                                }
                            }
                        } else if selectedAvatarKind == .character {
                            TextField(agentString("Character (up to 2)"), text: $characterValue)
                                .onChange(of: characterValue) { _, _ in updateCharacterPreview() }
                            TextField(agentString("Color (#RRGGBB)"), text: $colorHexValue)
                                .onChange(of: colorHexValue) { _, _ in updateCharacterPreview() }
                        } else {
                            Button(agentString("Choose image…")) { importingImage = true }
                            HStack { Text(agentString("Zoom")); Slider(value: $zoom, in: 1...5); Text(String(format: l10n("%.1f×"), zoom)).monospacedDigit() }
                            HStack { Text(agentString("Horizontal focus")); Slider(value: $focusX, in: 0...1) }
                            HStack { Text(agentString("Vertical focus")); Slider(value: $focusY, in: 0...1) }
                            Text(agentString("Images must be under 25 MB. Filicon safely normalizes to 1024 px and stores a 256 px PNG."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker(agentString("Shape"), selection: $selectedAvatarShape) {
                            ForEach(AgentAvatarShape.allCases, id: \.self) { Text(agentString($0.label)).tag($0) }
                        }
                        .onChange(of: selectedAvatarShape) { _, shape in
                            guard var avatar = profile.avatar else { updateCharacterPreview(); return }
                            avatar.shape = shape; profile.avatar = avatar
                        }
                    }
                }
                TextField(agentString("Name"), text: $profile.name)
                    .accessibilityIdentifier("agent-editor-name")
                TextField(agentString("Title"), text: $profile.title)
                TextField(agentString("Summary"), text: $profile.summary, axis: .vertical).lineLimit(2...4)
            }
            Section(agentString("Behavior")) {
                Picker(agentString("Provider"), selection: $profile.providerID) {
                    ForEach(model.descriptors) { Text($0.displayName).tag($0.id) }
                }
                TextField(agentString("Model ID"), text: $profile.modelID.editorText)
                TextField(agentString("Instructions"), text: $profile.instructions, axis: .vertical).lineLimit(6...14)
                    .accessibilityIdentifier("agent-editor-instructions")
            }
            Section(l10n("Agent update notifications")) {
                Toggle(l10n("Notify when this agent finishes or needs input"), isOn: $profile.notifyOnAgentUpdates)
                    .accessibilityIdentifier("agent-editor-notify-updates")
                AgentNotificationSettingsNotice()
            }
            if let saveError {
                Text(saveError).font(.callout).foregroundStyle(.red)
                    .accessibilityIdentifier("agent-editor-error")
            }
            if !isNew {
                AgentMemorySection(agentID: profile.id, scope: .agent)
                AgentMemorySection(agentID: profile.id, scope: .user)
                AgentMemorySection(agentID: profile.id, scope: .project)
            }
            HStack {
                Button(agentString("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(agentString(isNew ? l10n("Create") : l10n("Save"))) { Task { await saveButtonTapped() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.modelID.rawValue.isEmpty)
                    .accessibilityIdentifier("agent-editor-save")
            }
        }
        .formStyle(.grouped).padding().frame(minWidth: 560, minHeight: 620)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onChange(of: selectedAvatarKind) { _, kind in avatarKindChanged(kind) }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let avatar = model.importAgentAvatar(from: url, crop: .init(focusX: focusX, focusY: focusY, zoom: zoom), shape: selectedAvatarShape) {
                profile.avatar = avatar
            }
        }
    }

    private func updateCharacterPreview() {
        guard selectedAvatarKind == .character else { return }
        profile.avatar = .character(String(characterValue.prefix(2)), colorHex: colorHexValue, shape: selectedAvatarShape)
    }

    private func petButtonTapped(_ pet: AgentPetAvatar) {
        selectedPet = pet
        profile.avatar = .pet(pet, shape: selectedAvatarShape)
    }

    private func avatarKindChanged(_ kind: AgentAvatarKind) {
        switch kind {
        case .character: updateCharacterPreview()
        case .pet: petButtonTapped(selectedPet)
        case .image: importingImage = true
        }
    }

    private func saveButtonTapped() async {
        guard !saving else { return }
        saving = true
        saveError = nil
        defer { saving = false }
        var value = profile
        if selectedAvatarKind == .character {
            value.avatar = .character(String(characterValue.prefix(2)), colorHex: colorHexValue, shape: selectedAvatarShape)
        } else if selectedAvatarKind == .pet {
            value.avatar = .pet(selectedPet, shape: selectedAvatarShape)
        }
        let saved: AgentProfile?
        if isNew {
            saved = await model.createAgent(name: value.name, title: value.title, summary: value.summary, instructions: value.instructions,
                                            providerID: value.providerID, modelID: value.modelID, avatar: value.avatar,
                                            notifyOnAgentUpdates: value.notifyOnAgentUpdates)
        } else if await model.updateAgent(value) {
            saved = model.agents.first { $0.id == value.id }
        } else {
            saved = nil
        }
        guard let saved else { saveError = model.errorMessage; return }
        onSaved?(saved)
        dismiss()
    }
}

private struct AgentMemorySection: View {
    @EnvironmentObject private var model: AppModel
    let agentID: UUID
    let scope: AgentMemory.Scope
    @State private var memories: [AgentMemory] = []
    @State private var pendingRemoval: AgentMemory?
    @State private var confirmsRemoval = false
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        Section(l10n(scope.memoryTitleKey)) {
            Text(l10n(scope.memoryDisclosureKey))
                .font(.caption).foregroundStyle(.secondary)
            if scope == .project {
                Text(l10n("This editor lists all project facts in this account, including departed writers. Agents can read only projects they currently belong to."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(l10n("Only a ranked selection is sent each turn. Low-importance notes rank below equally recent dated facts. Omitted facts remain saved until you forget them."))
                .font(.caption).foregroundStyle(.secondary)
            if memories.isEmpty { Text(l10n("No saved facts.")).foregroundStyle(.secondary) }
            ForEach(memories) { memory in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l10n(memory.tier.memoryTitleKey)).font(.caption).foregroundStyle(.secondary)
                        if let project = memory.project { Text(verbatim: project).font(.caption.monospaced()) }
                        if scope != .agent {
                            Text(String(format: l10n("Recorded by %@"), model.agents.first { $0.id == memory.agentID }?.name ?? memory.agentID.uuidString))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(verbatim: memory.fact).textSelection(.enabled)
                        Text(memory.createdAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n("Forget"), role: .destructive) { forgetButtonTapped(memory) }
                }
            }
            Button(l10n("Refresh")) { Task { await refreshButtonTapped() } }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .disabled(busy)
        .task(id: model.settings.accountScope ?? "local") { await accountChanged() }
        .confirmationDialog(l10n(scope == .project ? "Forget this fact for all project members?" : scope == .user ? "Forget this shared fact for all agents?" : "Forget this fact?"), isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button(l10n("Forget"), role: .destructive) { Task { await confirmForgetButtonTapped() } }
            Button(l10n("Cancel"), role: .cancel) { pendingRemoval = nil }
        } message: {
            Text((pendingRemoval?.fact ?? "") + "\n\n" + l10n("Forgetting stops future memory injection. Existing messages and running requests are not erased."))
        }
    }
    private func accountChanged() async {
        memories = []; pendingRemoval = nil; confirmsRemoval = false; failure = nil
        await refreshButtonTapped()
    }
    private func refreshButtonTapped() async {
        let account = model.settings.accountScope ?? "local"
        do {
            let values = try await model.savedAgentMemories(agentID: agentID, scope: scope)
            try Task.checkCancellation()
            guard account == model.settings.accountScope ?? "local" else { return }
            memories = values; failure = nil
        } catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
    }
    private func forgetButtonTapped(_ memory: AgentMemory) {
        pendingRemoval = memory; confirmsRemoval = true
    }
    private func confirmForgetButtonTapped() async {
        guard let memory = pendingRemoval else { return }
        pendingRemoval = nil; busy = true
        defer { busy = false }
        do { try await model.forgetAgentMemory(memory); await refreshButtonTapped() }
        catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
    }
}

private extension ModelID {
    var editorText: String {
        get { rawValue }
        set { self = ModelID(rawValue: newValue) }
    }
}

private extension AgentAvatarShape {
    var label: String { switch self { case .circle: l10n("Circle"); case .roundedSquare: l10n("Rounded square"); case .hexagon: l10n("Hexagon") } }
}

struct AgentAvatarIcon: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let profile: AgentProfile
    let dimension: CGFloat
    var body: some View {
        let _ = uiLocale.identifier
        Group {
            if profile.avatar?.kind == .pet,
               let petID = profile.avatar?.petID, let pet = AgentPetAvatar(rawValue: petID) {
                PetAvatarImage(pet: pet).padding(dimension * 0.06)
            } else if let url = model.agentAvatarURL(for: profile.avatar), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color(hex: profile.avatar?.colorHex ?? "#5B6CFF")
                    Text(profile.avatar?.character?.isEmpty == false ? profile.avatar!.character! : String(profile.name.prefix(2)).uppercased())
                        .font(.system(size: dimension * 0.38, weight: .semibold)).foregroundStyle(.white)
                }
            }
        }
        .frame(width: dimension, height: dimension).clipShape(AvatarClipShape(shape: profile.avatar?.shape ?? .circle))
    }
}

private struct AvatarClipShape: Shape {
    let shape: AgentAvatarShape
    func path(in rect: CGRect) -> Path {
        switch shape {
        case .circle: return Path(ellipseIn: rect)
        case .roundedSquare: return RoundedRectangle(cornerRadius: rect.width * 0.23).path(in: rect)
        case .hexagon:
            var path = Path()
            for index in 0..<6 {
                let angle = Double(index) * .pi / 3 - .pi / 2
                let point = CGPoint(x: rect.midX + cos(angle) * rect.width / 2, y: rect.midY + sin(angle) * rect.height / 2)
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.closeSubpath(); return path
        }
    }
}

private extension Color {
    init(hex: String) {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(text, radix: 16) ?? 0x5B6CFF
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

private struct AgentAsyncTasksView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var kind = AgentTaskKind.subagent
    @State private var agentID: UUID?
    @State private var title = ""
    @State private var prompt = ""
    var body: some View {
        let _ = uiLocale.identifier
        List {
            Section(agentString("Launch task")) {
                HStack {
                    Picker(agentString("Kind"), selection: $kind) {
                        ForEach(AgentTaskKind.allCases, id: \.self) { Label(agentString($0.label), systemImage: $0.icon).tag($0) }
                    }
                    Picker(agentString("Agent"), selection: $agentID) {
                        Text(agentString("Choose…")).tag(nil as UUID?)
                        ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                TextField(agentString("Task title"), text: $title)
                TextField(agentString(kind == .shell ? l10n("Shell command") : l10n("Task prompt")), text: $prompt, axis: .vertical).lineLimit(2...6)
                HStack {
                    if kind == .shell {
                        Label(agentString("Runs locally with /bin/zsh after you press Launch."), systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(agentString("Launch")) { launch() }.disabled(agentID == nil || title.trimmed.isEmpty || prompt.trimmed.isEmpty)
                }
            }
            Section(agentString("History")) {
            if model.agentAsyncTasks.isEmpty {
                ContentUnavailableView(agentString("No async tasks"), systemImage: "clock.arrow.2.circlepath")
            } else {
                ForEach(model.agentAsyncTasks.sorted { $0.startedAt > $1.startedAt }) { task in
                    HStack(spacing: 12) {
                        Image(systemName: task.kind.icon).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).fontWeight(.medium)
                            Text("\(agentString(task.kind.label)) · \(agentName(task.agentID)) · \(task.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let result = task.result { Text(result).font(.caption).lineLimit(2) }
                        }
                        Spacer()
                        Text(agentString(task.status.label)).font(.caption).foregroundStyle(task.status == .failed ? .red : .secondary)
                        if task.isCancellationAllowed {
                            Button(agentString("Cancel"), role: .destructive) { Task { await model.cancelAgentTask(id: task.id) } }
                        }
                    }.padding(.vertical, 4)
                }
            }
            }
        }
        .task { await model.reloadAgentTasks() }
        .refreshable { await model.reloadAgentTasks() }
    }
    private func agentName(_ id: UUID) -> String { model.agents.first(where: { $0.id == id })?.name ?? agentString("Unknown agent") }
    private func launch() {
        guard let agentID else { return }
        let values = (kind, agentID, title.trimmed, prompt.trimmed)
        title = ""; prompt = ""
        Task { await model.launchAgentTask(kind: values.0, agentID: values.1, title: values.2, prompt: values.3) }
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

private extension AgentTaskKind {
    var label: String { switch self { case .subagent: l10n("Subagent"); case .shell: l10n("Shell"); case .cloud: l10n("Cloud") } }
    var icon: String { switch self { case .subagent: "person.2"; case .shell: "terminal"; case .cloud: "cloud" } }
}
private extension AgentRunStatus {
    var label: String {
        switch self { case .queued: l10n("Queued"); case .running: l10n("Running"); case .awaitingInput: l10n("Awaiting input"); case .succeeded: l10n("Succeeded"); case .failed: l10n("Failed"); case .cancelled: l10n("Cancelled"); case .interrupted: l10n("Interrupted") }
    }
}

private struct AgentOrgChartView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Binding var inspectedAgent: AgentProfile?
    @State private var zoom = 1.0

    var body: some View {
        let _ = uiLocale.identifier
        let layout = AgentOrgChartLayout.make(profiles: model.agents.filter { $0.archivedAt == nil }, tasks: model.agentAsyncTasks)
        VStack(spacing: 0) {
            HStack {
                Button { zoom = max(0.5, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Slider(value: $zoom, in: 0.5...2).frame(width: 150)
                Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button(agentString("Reset")) { zoom = 1 }
                Spacer()
                Text(agentString("Drag the scroll view to pan · click a card to inspect")).font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            if layout.nodes.isEmpty {
                ContentUnavailableView(agentString("No active agents"), systemImage: "point.3.connected.trianglepath.dotted")
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            let points = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, CGPoint(x: $0.position.x, y: $0.position.y)) })
                            for edge in layout.edges {
                                guard let start = points[edge.parentID], let end = points[edge.childID] else { continue }
                                var path = Path(); path.move(to: CGPoint(x: start.x, y: start.y + 35)); path.addLine(to: CGPoint(x: end.x, y: end.y - 35))
                                context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1.5)
                            }
                        }
                        ForEach(layout.nodes) { node in
                            Button { inspectedAgent = node.profile } label: {
                                HStack(spacing: 8) {
                                    AgentAvatarIcon(profile: node.profile, dimension: 34)
                                    VStack(alignment: .leading) {
                                        Text(node.profile.name).fontWeight(.medium).lineLimit(1)
                                        Text(node.profile.title.isEmpty ? FiliconLocalization.string(node.profile.status.rawValue) : node.profile.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.padding(10).frame(width: 190, height: 72, alignment: .leading)
                                    .background(.background, in: RoundedRectangle(cornerRadius: 11)).shadow(radius: 2, y: 1)
                            }.buttonStyle(.plain).position(x: node.position.x, y: node.position.y)
                        }
                    }
                    .frame(width: layout.width, height: layout.height)
                    .scaleEffect(zoom, anchor: .topLeading)
                    .frame(width: layout.width * zoom, height: layout.height * zoom, alignment: .topLeading)
                }
                .gesture(MagnificationGesture().onChanged { zoom = min(2, max(0.5, $0)) })
            }
        }
    }
}

private func agentString(_ key: String) -> String {
    FiliconLocalization.string(key)
}
