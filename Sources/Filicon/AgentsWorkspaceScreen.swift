import SwiftUI
import UniformTypeIdentifiers
import FiliconDomain
import FiliconAgents

struct AgentsWorkspaceScreen: View {
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
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Agents workspace", selection: $section) {
                    ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 480)
                Spacer()
                Button { creatingAgent = true } label: { Label("New Agent", systemImage: "plus") }
            }
            .padding()
            Divider()
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
        .navigationTitle("Agents")
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
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.cloudAgentEndpoint.isEmpty {
                ContentUnavailableView(
                    "Cloud agents are not configured",
                    systemImage: "cloud.slash",
                    description: Text("Add a credential-free HTTPS endpoint and Keychain bearer reference in Settings.")
                )
            } else if model.cloudAgentCatalog.isEmpty && !model.isRefreshingCloudAgents {
                ContentUnavailableView("No cloud agents", systemImage: "cloud", description: Text("Refresh the remote catalog."))
            } else {
                List(model.cloudAgentCatalog) { agent in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(agent.name).fontWeight(.medium); Spacer(); Text(agent.status.rawValue.capitalized).foregroundStyle(.secondary) }
                        Text(agent.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let summary = agent.summary { Text(summary).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { Task { await model.refreshCloudAgents() } } label: {
                if model.isRefreshingCloudAgents { ProgressView().controlSize(.small) }
                else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .disabled(model.isRefreshingCloudAgents)
            .padding()
        }
        .task { if model.cloudAgentCatalog.isEmpty && !model.cloudAgentEndpoint.isEmpty { await model.refreshCloudAgents() } }
    }
}

private struct AgentRosterView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var inspectedAgent: AgentProfile?

    var body: some View {
        let sections = AgentRosterSection.build(profiles: model.agents, pinnedIDs: model.pinnedAgentIDs)
        if sections.isEmpty {
            ContentUnavailableView("No agents yet", systemImage: "person.2", description: Text("Create an agent to give it instructions and a model."))
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
        switch self { case .pinned: "Pinned"; case .active: "Active"; case .archived: "Archived" }
    }
}

private struct AgentRosterRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: AgentProfile
    @Binding var inspectedAgent: AgentProfile?

    var body: some View {
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
                Button("Edit…") { inspectedAgent = profile }
                Button(model.pinnedAgentIDs.contains(profile.id) ? "Unpin" : "Pin") { model.toggleAgentPinned(id: profile.id) }
                if profile.unreadCount > 0 { Button("Mark Read") { Task { await model.markAgentRead(id: profile.id) } } }
                if profile.status == .failed { Button("Retry") { Task { await model.retryAgent(id: profile.id) } } }
                Button("Clone") { Task { await model.cloneAgent(id: profile.id) } }
                Divider()
                if profile.archivedAt == nil {
                    Button("Archive", role: .destructive) { Task { await model.archiveAgent(id: profile.id) } }
                } else {
                    Button("Restore") { Task { await model.restoreAgent(id: profile.id) } }
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
    let status: AgentAvailabilityStatus
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .help(label)
    }
    private var label: String {
        switch status { case .idle: "Idle"; case .running: "Running"; case .awaitingInput: "Awaiting input"; case .failed: "Failed"; case .offline: "Offline" }
    }
    private var color: Color {
        switch status { case .idle: .green; case .running: .blue; case .awaitingInput: .orange; case .failed: .red; case .offline: .gray }
    }
}

private struct AgentEditorView: View {
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
    let isNew: Bool

    init(profile: AgentProfile, isNew: Bool) {
        _profile = State(initialValue: profile)
        _selectedAvatarKind = State(initialValue: profile.avatar?.kind ?? .character)
        _characterValue = State(initialValue: profile.avatar?.character ?? String(profile.name.prefix(2)))
        _colorHexValue = State(initialValue: profile.avatar?.colorHex ?? "#5B6CFF")
        _selectedAvatarShape = State(initialValue: profile.avatar?.shape ?? .circle)
        self.isNew = isNew
    }

    var body: some View {
        Form {
            Section("Identity") {
                HStack(alignment: .top, spacing: 16) {
                    AgentAvatarIcon(profile: profile, dimension: 72)
                    VStack(alignment: .leading) {
                        Picker("Avatar", selection: $selectedAvatarKind) {
                            Text("Character").tag(AgentAvatarKind.character)
                            Text("Image").tag(AgentAvatarKind.image)
                        }.pickerStyle(.segmented)
                        if selectedAvatarKind != .image {
                            TextField("Character (up to 2)", text: $characterValue)
                                .onChange(of: characterValue) { _, _ in updateCharacterPreview() }
                            TextField("Color (#RRGGBB)", text: $colorHexValue)
                                .onChange(of: colorHexValue) { _, _ in updateCharacterPreview() }
                        } else {
                            Button("Choose image…") { importingImage = true }
                            HStack { Text("Zoom"); Slider(value: $zoom, in: 1...5); Text(String(format: "%.1f×", zoom)).monospacedDigit() }
                            HStack { Text("Horizontal focus"); Slider(value: $focusX, in: 0...1) }
                            HStack { Text("Vertical focus"); Slider(value: $focusY, in: 0...1) }
                            Text("Images must be under 25 MB. Filicon safely normalizes to 1024 px and stores a 256 px PNG.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Shape", selection: $selectedAvatarShape) {
                            ForEach(AgentAvatarShape.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .onChange(of: selectedAvatarShape) { _, shape in
                            guard var avatar = profile.avatar else { updateCharacterPreview(); return }
                            avatar.shape = shape; profile.avatar = avatar
                        }
                    }
                }
                TextField("Name", text: $profile.name)
                TextField("Title", text: $profile.title)
                TextField("Summary", text: $profile.summary, axis: .vertical).lineLimit(2...4)
            }
            Section("Behavior") {
                Picker("Provider", selection: $profile.providerID) {
                    ForEach(model.descriptors) { Text($0.displayName).tag($0.id) }
                }
                TextField("Model ID", text: Binding(get: { profile.modelID.rawValue }, set: { profile.modelID = ModelID(rawValue: $0) }))
                TextField("Instructions", text: $profile.instructions, axis: .vertical).lineLimit(6...14)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.modelID.rawValue.isEmpty)
            }
        }
        .formStyle(.grouped).padding().frame(minWidth: 560, minHeight: 620)
        .onChange(of: selectedAvatarKind) { _, kind in
            if kind == .character { updateCharacterPreview() } else { importingImage = true }
        }
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

    private func save() {
        var value = profile
        if selectedAvatarKind == .character {
            value.avatar = .character(String(characterValue.prefix(2)), colorHex: colorHexValue, shape: selectedAvatarShape)
        }
        Task {
            if isNew {
                await model.createAgent(name: value.name, title: value.title, summary: value.summary, instructions: value.instructions,
                                        providerID: value.providerID, modelID: value.modelID, avatar: value.avatar)
            } else { await model.updateAgent(value) }
            if model.errorMessage == nil { dismiss() }
        }
    }
}

private extension AgentAvatarShape {
    var label: String { switch self { case .circle: "Circle"; case .roundedSquare: "Rounded square"; case .hexagon: "Hexagon" } }
}

private struct AgentAvatarIcon: View {
    @EnvironmentObject private var model: AppModel
    let profile: AgentProfile
    let dimension: CGFloat
    var body: some View {
        Group {
            if let url = model.agentAvatarURL(for: profile.avatar), let image = NSImage(contentsOf: url) {
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
    @EnvironmentObject private var model: AppModel
    @State private var kind = AgentTaskKind.subagent
    @State private var agentID: UUID?
    @State private var title = ""
    @State private var prompt = ""
    var body: some View {
        List {
            Section("Launch task") {
                HStack {
                    Picker("Kind", selection: $kind) {
                        ForEach(AgentTaskKind.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                    }
                    Picker("Agent", selection: $agentID) {
                        Text("Choose…").tag(nil as UUID?)
                        ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                TextField("Title", text: $title)
                TextField(kind == .shell ? "Shell command" : "Task prompt", text: $prompt, axis: .vertical).lineLimit(2...6)
                HStack {
                    if kind == .shell {
                        Label("Runs locally with /bin/zsh after you press Launch.", systemImage: "exclamationmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Launch") { launch() }.disabled(agentID == nil || title.trimmed.isEmpty || prompt.trimmed.isEmpty)
                }
            }
            Section("History") {
            if model.agentAsyncTasks.isEmpty {
                ContentUnavailableView("No async tasks", systemImage: "clock.arrow.2.circlepath")
            } else {
                ForEach(model.agentAsyncTasks.sorted { $0.startedAt > $1.startedAt }) { task in
                    HStack(spacing: 12) {
                        Image(systemName: task.kind.icon).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title).fontWeight(.medium)
                            Text("\(task.kind.label) · \(agentName(task.agentID)) · \(task.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            if let result = task.result { Text(result).font(.caption).lineLimit(2) }
                        }
                        Spacer()
                        Text(task.status.label).font(.caption).foregroundStyle(task.status == .failed ? .red : .secondary)
                        if task.isCancellationAllowed {
                            Button("Cancel", role: .destructive) { Task { await model.cancelAgentTask(id: task.id) } }
                        }
                    }.padding(.vertical, 4)
                }
            }
            }
        }
        .task { await model.reloadAgentTasks() }
        .refreshable { await model.reloadAgentTasks() }
    }
    private func agentName(_ id: UUID) -> String { model.agents.first(where: { $0.id == id })?.name ?? "Unknown agent" }
    private func launch() {
        guard let agentID else { return }
        let values = (kind, agentID, title.trimmed, prompt.trimmed)
        title = ""; prompt = ""
        Task { await model.launchAgentTask(kind: values.0, agentID: values.1, title: values.2, prompt: values.3) }
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

private extension AgentTaskKind {
    var label: String { switch self { case .subagent: "Subagent"; case .shell: "Shell"; case .cloud: "Cloud" } }
    var icon: String { switch self { case .subagent: "person.2"; case .shell: "terminal"; case .cloud: "cloud" } }
}
private extension AgentRunStatus {
    var label: String {
        switch self { case .queued: "Queued"; case .running: "Running"; case .awaitingInput: "Awaiting input"; case .succeeded: "Succeeded"; case .failed: "Failed"; case .cancelled: "Cancelled"; case .interrupted: "Interrupted" }
    }
}

private struct AgentOrgChartView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var inspectedAgent: AgentProfile?
    @State private var zoom = 1.0

    var body: some View {
        let layout = AgentOrgChartLayout.make(profiles: model.agents.filter { $0.archivedAt == nil }, tasks: model.agentAsyncTasks)
        VStack(spacing: 0) {
            HStack {
                Button { zoom = max(0.5, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                Slider(value: $zoom, in: 0.5...2).frame(width: 150)
                Button { zoom = min(2, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                Button("Reset") { zoom = 1 }
                Spacer()
                Text("Drag the scroll view to pan · click a card to inspect").font(.caption).foregroundStyle(.secondary)
            }.padding(10)
            Divider()
            if layout.nodes.isEmpty {
                ContentUnavailableView("No active agents", systemImage: "point.3.connected.trianglepath.dotted")
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
                                        Text(node.profile.title.isEmpty ? node.profile.status.rawValue : node.profile.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
