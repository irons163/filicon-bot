import SwiftUI
import FiliconDomain
import FiliconAgents
import FiliconChannels
import FiliconAutomations
import FiliconMCP
import FiliconVoice
import FiliconSettings
import FiliconComputer
import FiliconPlugins
import FiliconUpdater
import UniformTypeIdentifiers
import FiliconAccount
import FiliconRichContent
import FiliconSecurityKey

@main
struct FiliconApp: App {
    @NSApplicationDelegateAdaptor(FiliconApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model: AppModel

    init() {
        let startup = AppStartupContext.production()
        _model = StateObject(wrappedValue: AppModel(startupContext: startup))
    }
    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 512, minHeight: 520)
                .preferredColorScheme(model.settings.theme.colorScheme)
                .background(AppWindowAccessor().frame(width: 0, height: 0))
                .onOpenURL(perform: model.handleDeepLink)
                .onReceive(NotificationCenter.default.publisher(for: .filiconOpenDeepLink)) { notification in
                    if let url = notification.object as? URL { model.handleDeepLink(url) }
                }
        }
        .commands {
            AboutCommands()
            CommandGroup(after: .newItem) {
                Button("New Conversation") { model.addConversation() }
                    .keyboardShortcut("n")
                    .disabled(!model.isBootstrapped)
            }
            CommandMenu("Conversation") {
                Button("Find in Chat") {
                    NotificationCenter.default.post(name: .filiconFindInChat, object: model.selection)
                }
                .keyboardShortcut("f")
                .disabled(model.selectedConversation == nil)
            }
            CommandMenu("Navigate") {
                Button("Search") { model.focusGlobalSearch() }
                    .keyboardShortcut("k", modifiers: [.command])
                Divider()
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: [.command])
                    .disabled(!model.canGoBack)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: [.command])
                    .disabled(!model.canGoForward)
                Divider()
                Button("Reload Workspace") { Task { await model.reloadRootWorkspace() } }
                    .keyboardShortcut("r", modifiers: [.command])
            }
        }
        Settings {
            SettingsView()
                .environmentObject(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
                .frame(width: 660, height: 700)
        }
        Window("About Filicon", id: "about") {
            AboutView()
                .environmentObject(model)
                .preferredColorScheme(model.settings.theme.colorScheme)
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 0) {
            AccountConnectionBanner()
            PersistenceRecoveryBanner()
            UpdateStatusPill()
        NavigationSplitView {
            List(selection: Binding<WorkspaceRoute?>(
                get: { model.route },
                set: { value in model.selectRoute(value) }
            )) {
                Section("Chats") {
                    Label("Search", systemImage: "magnifyingglass").tag(WorkspaceRoute.search)
                    ForEach(model.visibleConversations) { conversation in
                        ConversationSidebarRow(conversation: conversation).tag(WorkspaceRoute.conversation(conversation.id))
                    }
                    if model.hasMoreConversations {
                        Button {
                            Task { await model.loadMoreConversations() }
                        } label: {
                            if model.isLoadingMoreConversations {
                                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                            } else {
                                Label("Load more chats", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.isLoadingMoreConversations)
                    }
                    Label("Hidden Chats", systemImage: "archivebox").tag(WorkspaceRoute.hiddenChats)
                }
                Section("Workspace") {
                    Label("Agents", systemImage: "person.2").tag(WorkspaceRoute.agents)
                    Label("Groups", systemImage: "person.3").tag(WorkspaceRoute.groups)
                    Label("Automations", systemImage: "clock.arrow.circlepath").tag(WorkspaceRoute.automations)
                    Label("Channels", systemImage: "number").tag(WorkspaceRoute.channels)
                    Label("Shared Rooms", systemImage: "person.3.sequence").tag(WorkspaceRoute.sharedRooms)
                    Label("MCP Servers", systemImage: "server.rack").tag(WorkspaceRoute.mcp)
                    Label("Computer", systemImage: "display").tag(WorkspaceRoute.computer)
                    Label("Plugins", systemImage: "puzzlepiece.extension").tag(WorkspaceRoute.plugins)
                    Label("Account", systemImage: "person.crop.circle").tag(WorkspaceRoute.account)
                }
            }
            .navigationTitle("Filicon")
            .toolbar {
                ToolbarItemGroup {
                    Button(action: model.goBack) { Label("Back", systemImage: "chevron.left") }
                        .disabled(!model.canGoBack)
                        .accessibilityIdentifier("workspace-back")
                    Button(action: model.goForward) { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!model.canGoForward)
                        .accessibilityIdentifier("workspace-forward")
                    Button(action: model.addConversation) { Label("New Conversation", systemImage: "square.and.pencil") }
                        .disabled(!model.isBootstrapped)
                }
            }
        } detail: {
            workspaceDetail
        }
        }
        .alert("Filicon", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .sheet(item: Binding(
            get: { model.pendingToolApprovals.first },
            set: { _ in }
        )) { request in
            LocalToolApprovalView(request: request)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        .sheet(item: Binding(
            get: { model.attachmentPreview },
            set: { if $0 == nil { model.dismissAttachmentPreview() } }
        ), onDismiss: model.dismissAttachmentPreview) { item in
            AttachmentQuickLookSheet(item: item, onClose: model.dismissAttachmentPreview)
        }
        .sheet(isPresented: $model.showingFeedback) { FeedbackView().environmentObject(model) }
        .sheet(isPresented: $model.showingOnboarding) { OnboardingView().environmentObject(model) }
        .overlay(alignment: .topTrailing) {
            InAppNotificationStack(
                trays: model.notificationTrays,
                onClear: { Task { await model.clearNotifications() } },
                onDismiss: { id in Task { await model.dismissNotification(id: id) } },
                onAction: { action in await model.performNotificationAction(action) }
            )
            .padding(16)
        }
        .background(SecurityKeyConsentHost(presenter: model.securityKeyConsentPresenter))
        .overlay { AccountAccessCover() }
        .overlay {
            if model.isUpdateRequired { RequiredUpdateOverlay() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.systemNotifications.markAllViewed() }
            Task {
                await model.setAutomationRuntimeActive(phase == .active)
                model.setWorkflowRuntimeActive(phase == .active)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            Task { await model.shutdownComputerIntegration() }
        }
    }

    @ViewBuilder private var workspaceDetail: some View {
        switch model.route {
        case .conversation:
            if let conversation = model.selectedConversation { ChatDetailView(conversation: conversation) }
            else { ContentUnavailableView("Conversation unavailable", systemImage: "exclamationmark.bubble") }
        case .search: SearchWorkspaceView()
        case .agents: AgentWorkspaceView()
        case .groups: GroupWorkspaceView()
        case .automations: AutomationWorkspaceView()
        case .channels: ChannelWorkspaceView()
        case .sharedRooms: SharedRoomsWorkspaceView()
        case .mcp: MCPWorkspaceView()
        case .computer: ComputerWorkspaceView()
        case .plugins: PluginsWorkspaceView()
        case .account: AccountWorkspaceView()
        case .hiddenChats: HiddenChatsView()
        case nil: ContentUnavailableView("Choose a workspace", systemImage: "sidebar.left")
        }
    }
}

private struct UpdateStatusPill: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if !model.isUpdateRequired, let presentation = UpdatePillPresentation.make(state: model.updateState) {
            HStack {
                Spacer()
                Button {
                    perform(presentation.action)
                } label: {
                    Label(presentation.label, systemImage: presentation.symbolName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(presentation.action == nil)
                .foregroundStyle(presentation.isError ? Color.red : Color.primary)
                .accessibilityIdentifier("update-status-pill")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func perform(_ action: UpdatePresentationAction?) {
        switch action {
        case .check: Task { await model.checkForUpdates() }
        case .download: Task { await model.downloadAvailableUpdate() }
        case .install: Task { await model.installStagedUpdate() }
        case nil: break
        }
    }
}

private struct RequiredUpdateOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let presentation = RequiredUpdatePresentation.make(state: model.updateState)
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: presentation.isError ? "exclamationmark.triangle.fill" : "arrow.down.app.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(presentation.isError ? Color.red : Color.accentColor)
                Text("Update Required").font(.title.bold())
                Text("This version of Filicon is below the required minimum version\(minimumSuffix).")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text(presentation.status).multilineTextAlignment(.center)
                if presentation.action == nil {
                    ProgressView().controlSize(.small)
                } else if let label = presentation.actionLabel {
                    Button(label) { perform(presentation.action) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                if case .failed(let detail) = model.updateState {
                    Text(detail).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(32)
            .frame(maxWidth: 440)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("required-update-overlay")
    }

    private var minimumSuffix: String {
        model.minimumRequiredVersion.map { " (\($0))" } ?? ""
    }

    private func perform(_ action: UpdatePresentationAction?) {
        switch action {
        case .check: Task { await model.checkForUpdates() }
        case .download: Task { await model.downloadAvailableUpdate() }
        case .install: Task { await model.installStagedUpdate() }
        case nil: break
        }
    }
}

private struct ConversationSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @State private var showingRename = false
    @State private var title = ""

    var body: some View {
        HStack {
            Label(conversation.title, systemImage: "bubble.left")
            Spacer()
            Menu {
                Button("Rename…") { title = conversation.title; showingRename = true }
                Button("Hide") { model.setConversationHidden(id: conversation.id, hidden: true) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteConversation(id: conversation.id) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
        }
        .sheet(isPresented: $showingRename) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename Conversation").font(.headline)
                TextField("Title", text: $title).onSubmit(rename)
                HStack { Spacer(); Button("Cancel") { showingRename = false }; Button("Rename", action: rename).keyboardShortcut(.defaultAction) }
            }.padding(20).frame(width: 420)
        }
    }

    private func rename() {
        model.renameConversation(id: conversation.id, title: title)
        showingRename = false
    }
}

private struct HiddenChatsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            ForEach(model.hiddenConversations) { conversation in
                HStack {
                    VStack(alignment: .leading) {
                        Text(conversation.title)
                        Text(conversation.hiddenAt?.formatted() ?? "Hidden").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { model.setConversationHidden(id: conversation.id, hidden: false) }
                    Button("Delete", role: .destructive) { model.deleteConversation(id: conversation.id) }
                }
            }
        }
        .overlay {
            if model.hiddenConversations.isEmpty { ContentUnavailableView("No hidden chats", systemImage: "archivebox") }
        }
        .navigationTitle("Hidden Chats")
    }
}

private struct PluginsWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var tab: PluginBrowserTab = .marketplace
    @State private var type: PluginTypeFilter = .all
    @State private var ownership: PluginOwnership?
    @State private var query = ""
    @State private var selectedEntry: PluginCatalogEntry?
    @State private var showingImporter = false
    @State private var catalogURL = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Collection", selection: $tab) {
                    Text("Marketplace").tag(PluginBrowserTab.marketplace)
                    Text("Yours").tag(PluginBrowserTab.yours)
                }.pickerStyle(.segmented).frame(width: 220)
                TextField("Search plugins", text: $query).textFieldStyle(.roundedBorder)
                Picker("Type", selection: $type) {
                    Text("All").tag(PluginTypeFilter.all)
                    Text("Connectors").tag(PluginTypeFilter.connectors)
                    Text("Skills").tag(PluginTypeFilter.skills)
                }.frame(width: 140)
                Picker("Owner", selection: $ownership) {
                    Text("All owners").tag(nil as PluginOwnership?)
                    Text("Public").tag(Optional(PluginOwnership.publicMarketplace))
                    Text("Team").tag(Optional(PluginOwnership.team))
                    Text("User").tag(Optional(PluginOwnership.user))
                }.frame(width: 140)
                Button { Task { await model.reloadPlugins(forceCatalogRefresh: true) } } label: {
                    if model.isRefreshingPlugins { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }.disabled(model.isRefreshingPlugins)
                Button("Import…") { showingImporter = true }
            }.padding(12)
            Divider()
            if tab == .marketplace && model.pluginCatalogURLString.isEmpty {
                ContentUnavailableView {
                    Label("Choose a plugin catalog", systemImage: "puzzlepiece.extension")
                } description: {
                    Text("Filicon accepts a generic HTTPS catalog, so plugin distribution is not tied to one AI vendor.")
                } actions: {
                    HStack {
                        TextField("https://…/catalog.json", text: $catalogURL).frame(width: 360)
                        Button("Use Catalog") { let value = catalogURL; Task { await model.configurePluginCatalog(value) } }
                    }
                }
            } else {
                List {
                    if tab == .marketplace {
                        ForEach(visibleCatalog) { entry in
                            Button { selectedEntry = entry } label: { catalogRow(entry) }.buttonStyle(.plain)
                        }
                        if visibleCatalog.isEmpty { Text("No plugins match these filters.").foregroundStyle(.secondary) }
                    } else {
                        PrivateSkillsSection()
                        Section("Installed") {
                            ForEach(visibleInstalled) { plugin in PluginInstalledRow(plugin: plugin) }
                            if visibleInstalled.isEmpty { Text("No installed plugins match.").foregroundStyle(.secondary) }
                        }
                        Section("Skills") {
                            ForEach(model.indexedPluginSkills) { skill in
                                VStack(alignment: .leading) {
                                    Text(skill.name)
                                    Text("\(skill.pluginName) · \(skill.description)").font(.caption).foregroundStyle(.secondary)
                                    Text(skill.filePath).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Plugins")
        .task {
            catalogURL = model.pluginCatalogURLString
            await model.reloadPlugins(forceCatalogRefresh: false)
            consumeRequestedPlugin()
        }
        .onChange(of: model.requestedPluginID) { _, _ in consumeRequestedPlugin() }
        .sheet(item: $selectedEntry) { entry in PluginInstallSheet(entry: entry) }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await model.importPlugin(from: url) } }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
    }

    private var visibleCatalog: [PluginCatalogEntry] {
        let installed = Set(model.installedPlugins.map(\.id))
        let filter = PluginCatalogFilter(tab: tab, type: type, ownership: ownership, query: query)
        return model.pluginCatalogEntries.filter { $0.matches(filter, installedIDs: installed) }
    }

    private var visibleInstalled: [InstalledPlugin] {
        model.installedPlugins.filter { plugin in
            if type == .connectors && plugin.manifest.connectors.isEmpty { return false }
            if type == .skills && plugin.manifest.skills.isEmpty { return false }
            if let ownership, plugin.ownership != ownership { return false }
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return needle.isEmpty || "\(plugin.manifest.name) \(plugin.manifest.description)".lowercased().contains(needle)
        }
    }

    private func consumeRequestedPlugin() {
        guard let id = model.requestedPluginID else { return }
        guard let entry = model.pluginCatalogEntries.first(where: { $0.id == id || $0.manifest.id == id }) else {
            if !model.isRefreshingPlugins {
                model.requestedPluginID = nil
                model.errorMessage = "Plugin “\(id)” is not available in the configured catalogs."
            }
            return
        }
        tab = .marketplace
        type = .all
        ownership = nil
        query = id
        selectedEntry = entry
        model.requestedPluginID = nil
    }

    private func catalogRow(_ entry: PluginCatalogEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.manifest.connectors.isEmpty ? "bolt" : "puzzlepiece.extension").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.manifest.displayName).fontWeight(.semibold)
                Text(entry.manifest.description).lineLimit(2).foregroundStyle(.secondary)
                HStack {
                    if !entry.manifest.connectors.isEmpty { Text("\(entry.manifest.connectors.count) connectors") }
                    if !entry.manifest.skills.isEmpty { Text("\(entry.manifest.skills.count) skills") }
                    Text(entry.ownership == .publicMarketplace ? "Public" : entry.ownership.rawValue.capitalized)
                    if entry.policy == .required { Text("Required").foregroundStyle(.orange) }
                }.font(.caption)
            }
            Spacer()
            Text(model.installedPlugins.contains(where: { $0.id == entry.id }) ? "Installed" : "View")
                .foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct PluginInstallSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: PluginCatalogEntry
    @State private var values: [String: String] = [:]
    @State private var installing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.manifest.displayName).font(.title2.bold())
            Text(entry.manifest.description).foregroundStyle(.secondary)
            if let publisher = entry.publisher { LabeledContent("Publisher", value: publisher) }
            LabeledContent("Version", value: entry.manifest.version)
            if !entry.manifest.connectors.isEmpty {
                GroupBox("Connectors") { ForEach(entry.manifest.connectors) { Text($0.name).frame(maxWidth: .infinity, alignment: .leading) } }
            }
            if !entry.manifest.skills.isEmpty {
                GroupBox("Skills") { ForEach(entry.manifest.skills) { skill in VStack(alignment: .leading) { Text(skill.name); Text(skill.description).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) } }
            }
            ForEach(entry.manifest.variables) { field in
                if field.kind == .secret {
                    SecureField(field.displayName + (field.required ? " *" : ""), text: valueBinding(field.name))
                } else {
                    TextField(field.displayName + (field.required ? " *" : ""), text: valueBinding(field.name))
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Install") {
                    installing = true
                    Task {
                        await model.installPlugin(entry, setupValues: values)
                        installing = false
                        if model.installedPlugins.contains(where: { $0.id == entry.id }) { dismiss() }
                    }
                }
                .disabled(installing || entry.downloadURL == nil || !entry.policy.permitsInstall || missingRequiredValue)
            }
        }.padding(24).frame(width: 560)
    }

    private var missingRequiredValue: Bool {
        entry.manifest.variables.contains { $0.required && values[$0.name]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
    }
    private func valueBinding(_ name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }
}

private struct PluginInstalledRow: View {
    @EnvironmentObject private var model: AppModel
    let plugin: InstalledPlugin
    @State private var toolName = ""

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !plugin.manifest.connectors.isEmpty {
                    Text("Connectors: \(plugin.manifest.connectors.map(\.name).joined(separator: ", "))")
                }
                if !plugin.manifest.skills.isEmpty {
                    Text("Skills: \(plugin.manifest.skills.map(\.name).joined(separator: ", "))")
                }
                ForEach(plugin.disabledToolNames.sorted(), id: \.self) { name in
                    Toggle("Disable \(name)", isOn: Binding(
                        get: { plugin.disabledToolNames.contains(name) },
                        set: { disabled in Task { await model.setPluginToolDisabled(pluginID: plugin.id, toolName: name, disabled: disabled) } }
                    ))
                }
                HStack {
                    TextField("Tool name to disable", text: $toolName)
                    Button("Disable") {
                        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines); toolName = ""
                        Task { await model.setPluginToolDisabled(pluginID: plugin.id, toolName: name, disabled: true) }
                    }.disabled(toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(plugin.manifest.displayName)
                    Text("\(plugin.manifest.version) · \(plugin.policy.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", role: .destructive) { Task { await model.uninstallPlugin(id: plugin.id) } }
                    .disabled(!plugin.policy.permitsRemoval)
            }
        }
    }
}

private struct ComputerWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = "http://127.0.0.1:6080/vnc.html"
    @State private var sessionToken = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(statusText, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                if model.computerSnapshot.phase == .pulling, let percent = model.computerSnapshot.pullPercent {
                    ProgressView(value: percent, total: 100).frame(width: 120)
                }
                Spacer()
                if model.activeVNCURL != nil {
                    if model.vncControlSnapshot?.owner == .agent {
                        Button("Give Back") { Task { await model.giveBackVNCControl() } }
                    } else {
                        Button("Take Control") { Task { await model.takeVNCControl() } }
                            .disabled(model.vncControlSnapshot?.userPresent == true)
                    }
                }
                takeoverStatus
                teachControls
            }
            .padding(12)
            Divider()
            if let url = model.activeVNCURL, let token = model.activeVNCToken {
                if model.computerSnapshot.phase == .crashedOut {
                    ContentUnavailableView {
                        Label("VNC renderer stopped repeatedly", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The renderer was stopped after four crashes within 60 seconds.")
                    } actions: {
                        Button("Try again") { Task { await model.recoverVNCRenderer() } }
                        Button("Disconnect") { Task { await model.disconnectVNC() } }
                    }
                } else {
                    VNCWebView(
                        url: url,
                        sessionToken: token,
                        accountID: model.activeVNCAccountID ?? model.vncAccountID,
                        computerID: model.activeVNCComputerID ?? model.vncComputerID,
                        onRendererCrash: { Task { await model.noteVNCRendererCrash() } },
                        onVisible: { Task { await model.recoverVNCRenderer() } },
                        onUserPresence: { present in
                            Task { await model.reportVNCUserPresence(present) }
                        }
                    )
                    .accessibilityLabel("Remote computer viewer")
                    .overlay(alignment: .topTrailing) {
                        Button("Disconnect") { Task { await model.disconnectVNC() } }
                            .padding(8)
                    }
                }
            } else {
                Form {
                    Section("VNC connection") {
                        TextField("http://127.0.0.1:6080/vnc.html or HTTPS URL", text: $endpoint)
                            .textContentType(.URL)
                        SecureField("Session token", text: $sessionToken)
                        Text("Only loopback HTTP or the exact HTTPS origin entered here is accepted. The top-level VNC page must be /vnc.html and present the same session token.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Connect") {
                            let endpoint = endpoint
                            let token = sessionToken
                            sessionToken = ""
                            Task { await model.connectVNC(endpoint: endpoint, sessionToken: token) }
                        }
                        .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionToken.isEmpty)
                    }
                    RemoteComputerControlsView()
                    Section("Teach recording") {
                        Text("Teach records a private ScreenCaptureKit monitor for at most 10 minutes. Incomplete crash artifacts are quarantined at next launch.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Screen Recording Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: 720)
            }
        }
        .navigationTitle("Computer")
        .onDisappear { Task { await model.shutdownComputerIntegration() } }
    }

    @ViewBuilder private var teachControls: some View {
        if let policy = model.teachStatus.maskingPolicy {
            Label("\(model.teachStatus.maskedWindowCount) masked", systemImage: "eye.slash")
                .font(.caption)
            Label("\(model.teachStatus.pausedSensitiveWindowCount) paused", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(model.teachStatus.pausedSensitiveWindowCount > 0 ? .orange : .secondary)
            Text("Policy v\(policy.version) · \(policy.failClosed ? "fail closed" : "permissive")")
                .font(.caption2).foregroundStyle(.secondary)
        }
        switch model.teachStatus.phase {
        case .idle:
            if model.teachStatus.savedVideoURL != nil {
                Button("Attach recording") { Task { await model.attachTeachRecording() } }
            }
            Button { Task { await model.startTeachRecording() } } label: {
                Label("Teach", systemImage: "record.circle")
            }
        case .starting, .recovering:
            ProgressView().controlSize(.small)
            Text(model.teachStatus.phase == .starting ? "Starting recording…" : "Recovering recordings…")
                .font(.caption).foregroundStyle(.secondary)
        case .recording:
            Label("Recording", systemImage: "record.circle.fill").foregroundStyle(.red)
            Button("Save") { Task { await model.stopTeachRecording(save: true) } }
            Button("Discard", role: .destructive) { Task { await model.stopTeachRecording(save: false) } }
        case .finalizing:
            ProgressView().controlSize(.small)
            Text("Finalizing…").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label(model.teachStatus.errorMessage ?? "Recording failed", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button("Retry") { Task { await model.startTeachRecording() } }
        }
    }

    @ViewBuilder private var takeoverStatus: some View {
        if let snapshot = model.vncControlSnapshot {
            Label(snapshot.owner == .agent ? "Agent control" : "User control",
                  systemImage: snapshot.owner == .agent ? "cpu" : "person.fill")
                .font(.caption)
            if snapshot.userPresent {
                Text("User present").font(.caption).foregroundStyle(.orange)
            } else if let deadline = snapshot.lease?.deadlineMilliseconds {
                Text("Lease until \(Date(timeIntervalSince1970: Double(deadline) / 1_000).formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch model.computerSnapshot.phase {
        case .off: "Off"
        case .starting: "Starting"
        case .sleeping: "Sleeping"
        case .local: "This Mac"
        case .running: "Connected"
        case .pulling: "Downloading computer image"
        case .crashedOut: "Renderer stopped"
        }
    }

    private var statusIcon: String {
        switch model.computerSnapshot.phase {
        case .running, .local: "checkmark.circle.fill"
        case .pulling, .starting: "arrow.triangle.2.circlepath"
        case .crashedOut: "exclamationmark.triangle.fill"
        case .off, .sleeping: "moon.zzz"
        }
    }

    private var statusColor: Color {
        switch model.computerSnapshot.phase {
        case .running, .local: .green
        case .crashedOut: .red
        default: .secondary
        }
    }
}

private struct ChatDetailView: View {
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @State private var showingImporter = false
    @State private var showingFind = false
    @State private var showingOutline = false
    @State private var transcript: TranscriptPresentationState
    @State private var replyJumpTargetID: UUID?
    @FocusState private var findFieldFocused: Bool

    init(conversation: Conversation) {
        self.conversation = conversation
        _transcript = State(initialValue: TranscriptPresentationState(messages: conversation.messages))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Picker("Provider", selection: Binding(get: { conversation.providerID }, set: { model.updateRoute(providerID: $0) })) {
                        ForEach(model.descriptors) { Text($0.displayName).tag($0.id) }
                    }.frame(maxWidth: 220)
                    Picker("Model", selection: Binding(get: { conversation.modelID }, set: { model.updateRoute(providerID: conversation.providerID, modelID: $0) })) {
                        ForEach(model.availableModels) {
                            Text(ProviderCatalogPresentation.modelLabel($0)).tag($0.id)
                        }
                    }.frame(maxWidth: 320)
                    Picker("Reasoning", selection: Binding(
                        get: { conversation.reasoningEffort },
                        set: { model.setReasoningEffort($0) }
                    )) {
                        ForEach(model.supportedReasoningEfforts, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .frame(maxWidth: 170)
                    .disabled(model.selectedModel == nil)
                    Button { Task { await model.refreshModels(forceRefresh: true) } } label: {
                        Label("Refresh model catalog", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(model.isLoadingModels)
                    .help("Refresh model catalog")
                    .accessibilityLabel("Refresh model catalog")
                    Spacer()
                    Button { openFind() } label: { Label("Find in Chat", systemImage: "magnifyingglass") }
                        .labelStyle(.iconOnly)
                        .help("Find in Chat (⌘F)")
                    Button { showingOutline = true } label: { Label("Full conversation", systemImage: "list.bullet") }
                        .labelStyle(.iconOnly)
                        .help("Full conversation")
                }
                HStack(spacing: 6) {
                    if model.isLoadingModels { ProgressView().controlSize(.small) }
                    Text(model.modelCatalogStatusLabel)
                        .font(.caption)
                        .foregroundStyle(model.modelCatalogError == nil && !model.isModelCatalogStale ? Color.secondary : Color.orange)
                    if let updated = model.modelCatalogLastUpdated {
                        Text(updated, style: .relative).font(.caption).foregroundStyle(.tertiary)
                    }
                    if let usage = model.selectedProviderUsage, usage.requests > 0 {
                        Text("\(usage.requests.formatted()) requests · \(usage.inputTokens.formatted()) in / \(usage.outputTokens.formatted()) out")
                            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            .accessibilityLabel("Provider usage: \(usage.requests) requests, \(usage.inputTokens) input tokens, \(usage.outputTokens) output tokens")
                    }
                    if let configurationError = model.selectedConversationConfigurationError, !model.isLoadingModels {
                        Text(configurationError).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Model catalog status: \(model.modelCatalogStatusLabel)")
            }.padding(10)
            Divider()
            if showingFind {
                findBar
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if conversation.messages.isEmpty && model.loadingMessageHistory.contains(conversation.id) {
                            ProgressView("Loading messages…")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        }
                        if model.selectedConversationHasOlderMessages {
                            Button {
                                Task { await model.loadOlderMessages() }
                            } label: {
                                if model.loadingMessageHistory.contains(conversation.id) {
                                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                                } else {
                                    Label("Load older messages", systemImage: "arrow.up.circle")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.loadingMessageHistory.contains(conversation.id))
                            .padding(.bottom, 4)
                        }
                        ForEach(transcript.visibleMessages(from: conversation.messages)) { message in
                            TranscriptMessageView(
                                message: message,
                                conversation: conversation,
                                isFindMatch: transcript.isMatch(message.id),
                                isActiveFindMatch: transcript.activeMatchID == message.id,
                                isReplyJumpTarget: replyJumpTargetID == message.id,
                                onJumpToMessage: { id in
                                    guard transcript.exposeMessage(id: id, in: conversation.messages) else { return }
                                    replyJumpTargetID = id
                                    DispatchQueue.main.async {
                                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                        guard replyJumpTargetID == id else { return }
                                        withAnimation { replyJumpTargetID = nil }
                                    }
                                }
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: transcript.activeMatchID) { _, id in
                    guard let id else { return }
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onAppear {
                    if let id = model.requestedMessageJumpID { performGlobalJump(id, proxy: proxy) }
                }
                .onChange(of: model.requestedMessageJumpID) { _, id in
                    guard let id else { return }
                    performGlobalJump(id, proxy: proxy)
                }
            }
            Divider()
            MCPApprovalPanel()
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(model.pendingAttachments) { attachment in
                            HStack { AttachmentCard(attachment: attachment); Button { model.removePendingAttachment(id: attachment.id) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                        }
                    }.padding(.horizontal).padding(.top, 8)
                }.scrollIndicators(.hidden)
            }
            if let replyID = model.replyingToMessageID,
               let reply = conversation.messages.first(where: { $0.id == replyID }) {
                let preview = ReplyPreviewPresentation.make(for: reply)
                HStack(spacing: 8) {
                    Image(systemName: preview.symbolName)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(preview.label)").font(.caption.bold())
                        Text(preview.detail).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.cancelReply() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }.padding(.horizontal).padding(.top, 8)
            }
            if !referencedWorkflows.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(referencedWorkflows) { workflow in
                            Label(workflow.name, systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(.quaternary, in: Capsule())
                                .accessibilityLabel("Referenced workflow \(workflow.name)")
                        }
                    }.padding(.horizontal)
                }.scrollIndicators(.hidden)
            }
            if WorkflowComposerReferences.query(in: model.draft) != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reference a skill").font(.caption.bold()).foregroundStyle(.secondary)
                    if workflowSuggestions.isEmpty {
                        Text("No matching enabled manual workflows")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(workflowSuggestions) { suggestion in
                                    Button {
                                        model.draft = WorkflowComposerReferences.inserting(suggestion, into: model.draft)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(suggestion.name).fontWeight(.semibold)
                                            if !suggestion.description.isEmpty {
                                                Text(suggestion.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }.padding(.horizontal, 8).padding(.vertical, 5)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityIdentifier("workflow-suggestion-\(suggestion.id)")
                                }
                            }
                        }.scrollIndicators(.hidden)
                    }
                }.padding(.horizontal).padding(.top, 6)
            }
            HStack(alignment: .bottom) {
                Button { showingImporter = true } label: { Label("Attach", systemImage: "paperclip") }
                    .labelStyle(.iconOnly)
                    .disabled(model.isImportingAttachments || !model.selectedModelSupportsAttachments)
                    .help(model.selectedModelAttachmentError ?? "Attach a file")
                Button { model.pasteAttachments() } label: { Label("Paste files", systemImage: "doc.on.clipboard") }
                    .labelStyle(.iconOnly)
                    .disabled(!model.selectedModelSupportsAttachments)
                    .help(model.selectedModelAttachmentError ?? "Paste a file or image")
                TextField("Message", text: $model.draft, axis: .vertical).lineLimit(1...8).textFieldStyle(.roundedBorder)
                    .onSubmit { if !model.running.contains(conversation.id) { model.send() } }
                    .help("Type / after a space to reference an enabled workflow")
                VoiceComposerControls(
                    controller: model.voiceComposer,
                    accept: model.acceptVoiceResult,
                    supportsAudio: model.selectedModelSupportsAudio,
                    unsupportedAudioHelp: model.selectedModelAudioError
                )
                if model.running.contains(conversation.id) { Button("Stop", action: model.cancel) }
                else {
                    Button("Send", action: model.send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(
                            model.selectedConversationConfigurationError != nil
                                || (model.selectedModelAttachmentError != nil && !model.pendingAttachments.isEmpty)
                        )
                        .help(
                            model.selectedConversationConfigurationError
                                ?? (model.pendingAttachments.isEmpty ? "Send message" : model.selectedModelAttachmentError ?? "Send message")
                        )
                }
            }.padding().disabled(!model.isBootstrapped)
        }.navigationTitle(conversation.title).task(id: conversation.id) { await model.refreshModels() }
            .onChange(of: conversation.id) { _, _ in
                transcript.reset(messages: conversation.messages)
                showingFind = false
            }
            .onChange(of: conversation.messages) { _, messages in
                transcript.synchronize(messages: messages)
            }
            .onReceive(NotificationCenter.default.publisher(for: .filiconFindInChat)) { notification in
                guard (notification.object as? UUID) == conversation.id else { return }
                openFind()
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.importAttachments(urls)
                return !urls.isEmpty
            } isTargeted: { _ in }
            .onDisappear { model.voiceComposer.cancel() }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): model.importAttachments(urls); case .failure(let error): model.errorMessage = error.localizedDescription }
            }
            .sheet(isPresented: $showingOutline) {
                ConversationOutlineView(
                    title: conversation.title,
                    items: ConversationOutlineProjection.make(messages: conversation.messages)
                ) { id in
                    guard transcript.exposeMessage(id: id, in: conversation.messages) else { return }
                    replyJumpTargetID = id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                        guard replyJumpTargetID == id else { return }
                        withAnimation { replyJumpTargetID = nil }
                    }
                }
            }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this chat", text: Binding(
                get: { transcript.query },
                set: { transcript.setQuery($0, messages: conversation.messages) }
            ))
            .textFieldStyle(.plain)
            .focused($findFieldFocused)
            .onSubmit { _ = transcript.selectNext(messages: conversation.messages) }
            Text(transcript.matchPositionLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .trailing)
            Button { _ = transcript.selectPrevious(messages: conversation.messages) } label: {
                Label("Previous match", systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(transcript.matchIDs.isEmpty)
            Button { _ = transcript.selectNext(messages: conversation.messages) } label: {
                Label("Next match", systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(transcript.matchIDs.isEmpty)
            Button(action: closeFind) { Label("Close Find", systemImage: "xmark") }
                .labelStyle(.iconOnly)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func openFind() {
        showingFind = true
        DispatchQueue.main.async { findFieldFocused = true }
        if model.selectedConversationHasOlderMessages {
            Task {
                do { try await model.loadAllMessages(for: conversation.id) }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private func closeFind() {
        showingFind = false
        transcript.setQuery("", messages: conversation.messages)
    }

    private var workflowSuggestions: [WorkflowComposerSuggestion] {
        WorkflowComposerReferences.suggestions(in: model.draft, workflows: model.workflows)
    }

    private var referencedWorkflows: [AgentWorkflow] {
        WorkflowComposerReferences.referencedWorkflows(in: model.draft, workflows: model.workflows)
    }

    private func performGlobalJump(_ id: UUID, proxy: ScrollViewProxy) {
        guard transcript.exposeMessage(id: id, in: conversation.messages) else { return }
        replyJumpTargetID = id
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            model.consumeRequestedMessageJump(id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard replyJumpTargetID == id else { return }
            withAnimation { replyJumpTargetID = nil }
        }
    }
}

private struct VoiceComposerControls: View {
    @ObservedObject var controller: VoiceComposerController
    let accept: () -> Void
    let supportsAudio: Bool
    let unsupportedAudioHelp: String?

    var body: some View {
        switch controller.phase {
        case .idle:
            Button(action: controller.startRecording) {
                Label("Record voice message", systemImage: "mic")
            }
            .labelStyle(.iconOnly)
            .disabled(!supportsAudio)
            .help(unsupportedAudioHelp ?? "Record voice message")
        case .requestingMicrophonePermission:
            ProgressView().controlSize(.small).help("Requesting microphone access…")
            Button("Cancel", action: controller.cancel).controlSize(.small)
        case .recording(let elapsed):
            WaveformStrip(samples: controller.waveformSamples)
                .frame(width: 92, height: 25)
                .accessibilityLabel("Live microphone level")
            Text(elapsed.formattedVoiceDuration).font(.system(.caption, design: .monospaced))
            Button(action: controller.stopAndTranscribe) {
                Label("Stop and transcribe", systemImage: "stop.circle.fill")
            }.labelStyle(.iconOnly).foregroundStyle(.red).help("Stop and transcribe")
            Button(action: controller.cancel) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Cancel recording")
        case .transcribing:
            ProgressView().controlSize(.small)
            Text("Transcribing…").font(.caption).foregroundStyle(.secondary)
            Button("Cancel", action: controller.cancel).controlSize(.small)
        case .ready:
            WaveformStrip(samples: controller.waveformSamples).frame(width: 70, height: 22)
            Button("Use Recording", action: accept).controlSize(.small)
            Button(action: controller.retry) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Record again")
            Button(action: controller.cancel) { Image(systemName: "trash") }
                .buttonStyle(.plain).help("Discard recording")
        case .permissionDenied:
            Label("Microphone access denied", systemImage: "mic.slash").font(.caption).foregroundStyle(.red)
            Button("Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }.controlSize(.small)
            Button("Retry", action: controller.retry).controlSize(.small)
        case .tooShort(let minimum):
            Text("Recording must be at least \(minimum, specifier: "%.1f")s").font(.caption).foregroundStyle(.orange)
            Button("Retry", action: controller.retry).controlSize(.small)
            Button("Cancel", action: controller.cancel).controlSize(.small)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            Button("Retry", action: controller.retry).controlSize(.small)
            Button("Cancel", action: controller.cancel).controlSize(.small)
        }
    }
}

private struct WaveformStrip: View {
    let samples: [Float]
    var body: some View {
        GeometryReader { proxy in
            let values = Array(samples.suffix(36))
            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, sample in
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(maxWidth: .infinity, minHeight: 2, maxHeight: max(2, proxy.size.height * CGFloat(sample)))
                }
            }.frame(maxHeight: .infinity)
        }
    }
}

private extension TimeInterval {
    var formattedVoiceDuration: String {
        let value = max(0, Int(self.rounded(.down)))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct TranscriptMessageView: View {
    @EnvironmentObject private var model: AppModel
    let message: ChatMessage
    let conversation: Conversation
    var isFindMatch = false
    var isActiveFindMatch = false
    var isReplyJumpTarget = false
    let onJumpToMessage: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(roleLabel).font(.caption).foregroundStyle(.secondary)
                if message.deliveryStatus != .succeeded {
                    Label(statusLabel, systemImage: statusIcon).font(.caption2).foregroundStyle(statusColor)
                }
                Spacer()
                Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            if let replyID = message.replyToMessageID {
                let preview = ReplyPreviewPresentation.make(for: conversation.messages.first(where: { $0.id == replyID }))
                Button { onJumpToMessage(replyID) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: preview.symbolName).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preview.label).font(.caption2.bold()).foregroundStyle(.secondary)
                            Text(preview.detail).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Jump to replied message")
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            if !message.reasoningText.isEmpty {
                DisclosureGroup("Reasoning") {
                    MarkdownText(source: message.reasoningText)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }.font(.callout)
            }
            if !message.text.isEmpty {
                MarkdownText(source: message.text)
            } else if message.reasoningText.isEmpty && message.toolActivities.isEmpty && message.transcriptCards.isEmpty {
                Text(message.deliveryStatus == .failed ? "No response was delivered." : "…").foregroundStyle(.secondary)
            }
            ForEach(message.toolActivities) { activity in
                ToolActivityRow(activity: activity)
            }
            ForEach(message.transcriptCards) { card in
                TranscriptCardRow(card: card) { model.handleTranscriptCardIntent($0) }
            }
            if !message.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack { ForEach(message.attachments) { attachment in AttachmentCard(attachment: attachment) } }
                }.scrollIndicators(.hidden)
            }
            if let error = message.deliveryError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if !message.reactions.isEmpty {
                HStack(spacing: 5) {
                    ForEach(groupedReactions, id: \.emoji) { group in
                        Button("\(group.emoji) \(group.count)") {
                            model.toggleReaction(messageID: message.id, emoji: group.emoji)
                        }
                        .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            HStack(spacing: 10) {
                Button { model.beginReply(to: message.id) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                Button { TranscriptPasteboard.copy(TranscriptClipboardContent.messageText(message)) } label: { Label("Copy Message", systemImage: "doc.on.doc") }
                Menu { ForEach(["👍", "❤️", "😂", "🎉", "👀"], id: \.self) { emoji in Button(emoji) { model.toggleReaction(messageID: message.id, emoji: emoji) } } } label: { Label("React", systemImage: "face.smiling") }
                if message.role == .assistant && [.failed, .cancelled].contains(message.deliveryStatus) {
                    Button { model.resend(messageID: message.id) } label: { Label("Resend", systemImage: "arrow.clockwise") }
                }
                Spacer()
                Button(role: .destructive) { model.deleteMessage(id: message.id) } label: { Label("Delete", systemImage: "trash") }
            }
            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(message.role == .user ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if isReplyJumpTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
            } else if isFindMatch {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isActiveFindMatch ? Color.orange : Color.orange.opacity(0.35), lineWidth: isActiveFindMatch ? 3 : 1)
            }
        }
    }

    private var roleLabel: String { message.role == .user ? "You" : message.role == .assistant ? "Assistant" : message.role.rawValue.capitalized }
    private var statusLabel: String { message.deliveryStatus.rawValue.capitalized }
    private var statusIcon: String {
        switch message.deliveryStatus {
        case .queued: "clock"
        case .streaming: "ellipsis"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .cancelled: "stop.circle"
        }
    }
    private var statusColor: Color { message.deliveryStatus == .failed ? .red : .secondary }
    private var groupedReactions: [(emoji: String, count: Int)] {
        Dictionary(grouping: message.reactions, by: \.emoji)
            .map { (emoji: $0.key, count: $0.value.count) }
            .sorted { $0.emoji < $1.emoji }
    }
}

struct MarkdownText: View {
    let source: String
    var body: some View {
        RichMarkdownView.transcript(source: source, openLink: TranscriptSafeLinkOpener.open)
    }
}

private struct ToolActivityRow: View {
    let activity: ToolActivity
    private var presentation: ToolCardPresentation { ToolCardClassifier.presentation(for: activity) }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(presentation.fields.enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline) {
                        Text(field.label).font(.caption.bold()).foregroundStyle(.secondary)
                        Text(field.value).font(.caption).textSelection(.enabled)
                    }
                }
                ForEach(presentation.links, id: \.absoluteString) { url in
                    Button { _ = TranscriptSafeLinkOpener.open(url) } label: {
                        Label(url.absoluteString, systemImage: "arrow.up.right.square")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
                if !presentation.redactedArguments.isEmpty {
                    Text("Arguments").font(.caption.bold())
                    Text(presentation.redactedArguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let result = presentation.redactedResult, !result.isEmpty {
                    Text("Result").font(.caption.bold())
                    Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }.padding(.top, 5)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: presentation.symbolName)
                VStack(alignment: .leading, spacing: 1) {
                    Text(presentation.title)
                    Text("\(activity.name.rawValue) · \(presentation.subtitle)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if activity.status == .running { ProgressView().controlSize(.small) }
                else { Image(systemName: icon) }
            }
                .foregroundStyle(activity.status == .failed ? .red : .secondary)
        }
        .font(.callout).padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
    private var icon: String {
        switch activity.status { case .running: "gearshape.2"; case .succeeded: "checkmark.circle"; case .failed: "xmark.circle" }
    }
}

private struct TranscriptCodeBlock: View {
    let language: String?
    let source: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : "Code")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    TranscriptPasteboard.copy(source)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).controlSize(.small)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(source)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(9)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.18)))
    }
}

private enum TranscriptPasteboard {
    static func copy(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private enum TranscriptSafeLinkOpener {
    @discardableResult
    static func open(_ url: URL) -> Bool {
        guard case .allowed(let safeURL) = TranscriptLinkPolicy.decision(for: url) else {
            NSSound.beep()
            return false
        }
        return NSWorkspace.shared.open(safeURL)
    }
}

private struct AttachmentCard: View {
    @EnvironmentObject private var model: AppModel
    let attachment: AttachmentMetadata
    var body: some View {
        Button { model.openAttachment(attachment) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help("Preview attachment")
    }
    private var icon: String { switch attachment.kind { case .image: "photo"; case .video: "film"; case .audio: "waveform"; case .document: "doc"; case .other: "paperclip" } }
}

private struct SearchWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search").font(.title2.bold())
            Picker("Search scope", selection: $model.globalSearchTab) {
                ForEach(GlobalSearchTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField(searchPlaceholder, text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFieldFocused)
                    .onSubmit(model.search)
                    .accessibilityIdentifier("global-search-field")
                Button("Search", action: model.search)
            }
            searchContent
        }
        .padding()
        .navigationTitle("Search")
        .task(id: model.globalSearchFocusRequestID) {
            await Task.yield()
            searchFieldFocused = true
        }
    }

    private var searchPlaceholder: String {
        switch model.globalSearchTab {
        case .conversations: "Conversation title or text"
        case .messages: "Words in messages"
        case .files: "File name or type (leave empty for recent)"
        }
    }

    @ViewBuilder private var searchContent: some View {
        switch model.globalSearchState {
        case .idle:
            ContentUnavailableView(
                model.globalSearchTab == .files ? "Recent files" : "Start searching",
                systemImage: "magnifyingglass",
                description: Text(model.globalSearchTab == .files ? "Recent attachments appear automatically." : "Enter a search above.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { if model.globalSearchTab == .files { await model.performGlobalSearch() } }
        case .loading:
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView.search(text: model.searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            searchUnavailable(title: "Search failed", message: message, symbol: "exclamationmark.triangle")
        case .unavailable(let message):
            searchUnavailable(title: "Search unavailable", message: message, symbol: "externaldrive.badge.exclamationmark")
        case .results:
            resultsList
        }
    }

    @ViewBuilder private var resultsList: some View {
        switch model.globalSearchTab {
        case .conversations:
            List(model.searchResults) { conversation in
                Button { model.openSearchResult(conversation) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title)
                        Text(conversation.updatedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        case .messages:
            List(model.globalMessageSearchResults, id: \.self) { hit in
                Button { Task { await model.openGlobalMessageSearchHit(hit) } } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.conversationTitle(for: hit.conversationID)).fontWeight(.semibold)
                            Spacer()
                            Text(hit.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(hit.snippet).lineLimit(3).foregroundStyle(.primary)
                        Text(hit.role == .user ? "You" : hit.role.rawValue.capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.buttonStyle(.plain)
            }
        case .files:
            List(model.globalMediaSearchResults, id: \.self) { hit in
                Button { Task { await model.openGlobalMediaSearchHit(hit) } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: searchFileIcon(hit.kind)).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.name).fontWeight(.semibold)
                            Text("\(model.conversationTitle(for: hit.conversationID)) · \(hit.mimeType)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(hit.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3)
                }.buttonStyle(.plain)
            }
        }
    }

    private func searchUnavailable(title: String, message: String, symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        } actions: {
            Button("Try Again") { model.search() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func searchFileIcon(_ kind: AttachmentKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc"
        case .other: "paperclip"
        }
    }
}

private struct AgentWorkspaceView: View {
    var body: some View {
        AgentsWorkspaceScreen()
    }
}

private struct GroupWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var summary = ""
    @State private var selected: Set<UUID> = []
    var body: some View {
        Form {
            Section("Create group") {
                TextField("Name", text: $name); TextField("Summary", text: $summary)
                ForEach(model.agents.filter { $0.archivedAt == nil }) { agent in
                    Toggle(agent.name, isOn: Binding(get: { selected.contains(agent.id) }, set: { if $0 { selected.insert(agent.id) } else { selected.remove(agent.id) } })).disabled(!selected.contains(agent.id) && selected.count >= GroupService.maximumMembers)
                }
                Button("Create group") { let ids = model.agents.map(\.id).filter(selected.contains); let values = (name, summary); name = ""; summary = ""; selected.removeAll(); Task { await model.createGroup(name: values.0, summary: values.1, memberIDs: ids) } }
            }
            Section("Groups") {
                ForEach(model.groups) { group in
                    GroupChatRow(group: group)
                }
            }
        }.formStyle(.grouped).navigationTitle("Groups")
    }
}

private struct GroupChatRow: View {
    @EnvironmentObject private var model: AppModel
    let group: AgentGroup
    @State private var draft = ""
    @State private var members: Set<UUID> = []

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text(group.summary).foregroundStyle(.secondary)
                GroupBox("Members") {
                    ForEach(model.agents.filter { $0.archivedAt == nil }) { agent in
                        Toggle(agent.name, isOn: Binding(
                            get: { members.contains(agent.id) },
                            set: { selected in
                                if selected { members.insert(agent.id) } else { members.remove(agent.id) }
                            }
                        )).disabled(!members.contains(agent.id) && members.count >= GroupService.maximumMembers)
                    }
                    Button("Update Members") { Task { await model.updateGroupMembers(groupID: group.id, memberIDs: Array(members)) } }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.groupMessages[group.id] ?? []) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(senderName(message)).font(.caption.bold())
                                    Spacer(); Text(message.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(message.text).textSelection(.enabled)
                                if message.senderID != nil {
                                    Button("👍") { Task { await model.toggleGroupReaction(groupID: group.id, messageID: message.id, emoji: "👍") } }
                                        .buttonStyle(.plain).controlSize(.mini)
                                }
                            }
                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }.frame(minHeight: 120, maxHeight: 320)
                HStack {
                    TextField("Message the group; @name and @everyone are supported", text: $draft)
                        .onSubmit(send)
                    if model.runningGroups.contains(group.id) {
                        Button("Stop") { Task { await model.stopGroup(id: group.id) } }
                    } else {
                        Button("Send", action: send).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.padding(.top, 8)
        } label: {
            VStack(alignment: .leading) {
                Text(group.name)
                Text("\(group.memberIDs.count) members · up to \(GroupService.maximumRounds) response rounds")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { members = Set(group.memberIDs) }
        .onChange(of: group.memberIDs) { _, value in members = Set(value) }
    }

    private func send() {
        let value = draft; draft = ""
        Task { await model.sendGroupMessage(groupID: group.id, text: value) }
    }

    private func senderName(_ message: RoomMessage) -> String {
        guard let id = message.senderID else { return "You" }
        return model.agents.first(where: { $0.id == id })?.name ?? "Agent"
    }
}

struct RoutineAutomationWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var agentID: UUID?
    @State private var name = ""
    @State private var prompt = ""
    @State private var listeners = [AutomationListenerDraft()]
    var body: some View {
        Form {
            Section("New routine") {
                Picker("Agent", selection: $agentID) { Text("Choose…").tag(nil as UUID?); ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) } }
                TextField("Name", text: $name); TextField("Instruction", text: $prompt, axis: .vertical).lineLimit(2...5)
                ForEach($listeners) { $listener in
                    AutomationListenerEditor(listener: $listener, canRemove: listeners.count > 1) {
                        listeners.removeAll { $0.id == listener.id }
                    }
                }
                HStack {
                    Button("Add listener") { listeners.append(AutomationListenerDraft()) }
                        .disabled(listeners.count >= AutomationService.maximumListeners)
                    Text("\(listeners.count)/\(AutomationService.maximumListeners)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Create", action: create)
                        .disabled(agentID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Multiple listeners are OR-combined. Schedules support five-field cron, aliases, @every, and IANA time zones; connector filters must be a JSON object.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.automationWakes.isEmpty {
                Section("Pending results") {
                    ForEach(model.automationWakes) { wake in
                        HStack {
                            Label(wake.detail.isEmpty ? wake.status.rawValue.capitalized : wake.detail, systemImage: wake.status == .ok ? "checkmark.circle" : "exclamationmark.circle")
                                .lineLimit(2)
                            Spacer()
                            Text(wake.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            Button("Acknowledge") { Task { await model.acknowledgeAutomationWake(id: wake.id) } }
                        }
                    }
                }
            }
            if model.automationSpendGuard.nudgedAt != nil || !model.automationSpendGuard.guardPausedAutomationIDs.isEmpty {
                Section("Automation activity check") {
                    Text(model.automationSpendGuard.guardPausedAutomationIDs.isEmpty
                         ? "Automations have continued while you were away. Keep them running or pause them."
                         : "Automations were paused after prolonged unviewed activity.")
                    HStack {
                        if model.automationSpendGuard.guardPausedAutomationIDs.isEmpty {
                            Button("Keep running") { Task { await model.answerAutomationSpendGuard(.keep) } }
                            Button("Pause", role: .destructive) { Task { await model.answerAutomationSpendGuard(.pause) } }
                            Button("Never ask") { Task { await model.answerAutomationSpendGuard(.neverAsk) } }
                        } else {
                            Button("Resume") { Task { await model.answerAutomationSpendGuard(.resume) } }
                            Button("Stay paused") { Task { await model.answerAutomationSpendGuard(.stayPaused) } }
                        }
                    }
                }
            }
            AutomationIngressSettingsView()
            Section("Routines") {
                ForEach(model.automations) { automation in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(automation.prompt).textSelection(.enabled)
                            if let runs = model.automationHistory[automation.id], !runs.isEmpty {
                                Text("Recent runs").font(.caption.bold())
                                ForEach(runs) { run in
                                    HStack(alignment: .top) {
                                        Label(run.status.rawValue.capitalized, systemImage: run.status == .ok ? "checkmark.circle" : "exclamationmark.circle")
                                        Text(run.trigger.rawValue.capitalized).foregroundStyle(.secondary)
                                        Text(run.startedAt, style: .relative).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(run.detail ?? "").lineLimit(2).foregroundStyle(.secondary)
                                    }.font(.caption)
                                }
                            } else {
                                Text("No runs yet").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 6)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(automation.name)
                                Text("\(triggerSummary(automation.trigger)) · \(automation.nextRunAt.map { "Next \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Event-based or paused")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(get: { automation.enabled }, set: { value in Task { await model.setAutomationEnabled(id: automation.id, enabled: value) } })).labelsHidden()
                            Button("Run Now") { Task { await model.runAutomationNow(id: automation.id) } }
                            Button("Delete", role: .destructive) { Task { await model.deleteAutomation(id: automation.id) } }
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Automations")
            .task { await model.reloadAutomationDetails(markViewed: true) }
    }

    private func create() {
        guard let agentID else { return }
        do {
            let triggers = try listeners.map { try $0.trigger }
            let trigger: AutomationTrigger = triggers.count == 1 ? triggers[0] : .anyOf(triggers)
            let values = (name, prompt, trigger)
            name = ""; prompt = ""; listeners = [AutomationListenerDraft()]
            Task { await model.createAutomation(agentID: agentID, name: values.0, prompt: values.1, trigger: values.2) }
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func triggerSummary(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .cron(let expression, let zone): "\(expression) · \(zone ?? "system time")"
        case .event(let value): "\(value.kind) connector event"
        case .platform(let value): value.platform
        case .anyOf(let values): "\(values.count) listeners"
        case .unknown(let kind, _): "Unavailable: \(kind)"
        }
    }
}

private enum AutomationListenerKind: String, CaseIterable, Identifiable {
    case schedule = "Schedule"
    case connector = "Connector event"
    case slack = "Slack"
    case github = "GitHub"
    case teams = "Microsoft Teams"
    case linear = "Linear"
    case sentry = "Sentry"
    case pagerDuty = "PagerDuty"
    var id: String { rawValue }
}

private struct AutomationListenerDraft: Identifiable {
    var id = UUID()
    var kind: AutomationListenerKind = .schedule
    var primary = "@daily"
    var secondary = ""
    var tertiary = ""
    var quaternary = ""
    var filtersJSON = "{}"

    var trigger: AutomationTrigger {
        get throws {
            switch kind {
            case .schedule:
                return .cron(expression: primary, timeZoneIdentifier: secondary.isEmpty ? TimeZone.current.identifier : secondary)
            case .connector:
                guard let connectorID = UUID(uuidString: primary),
                      let data = filtersJSON.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw AutomationServiceError.invalidDefinition
                }
                return .event(.init(connectorID: connectorID, kind: secondary, filtersJSON: data))
            case .slack:
                let match: SlackMatch = switch secondary.lowercased() {
                case "mention": .mention
                case "keyword": .keyword(tertiary)
                case "reaction": .reaction(emoji: tertiary.split(separator: ",").map(String.init), bySelf: false)
                default: .message
                }
                return .platform(.slack(try SlackAutomationTrigger(channel: primary, match: match)))
            case .github:
                return .platform(.github(try GitHubAutomationTrigger(
                    repo: primary,
                    events: secondary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                    ciBranch: tertiary.isEmpty ? nil : tertiary,
                    userAllowlist: quaternary.split(separator: ",").map(String.init)
                )))
            case .teams:
                return .platform(.microsoftTeams(try TeamsAutomationTrigger(
                    tenantID: primary,
                    teamIDs: Set(secondary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }),
                    channelIDs: Set(tertiary.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }),
                    messageContains: quaternary.isEmpty ? nil : quaternary
                )))
            case .linear, .sentry, .pagerDuty:
                let value = try CaseAutomationTrigger(
                    event: primary,
                    allowedEvents: [primary],
                    primaryIDs: Set(secondary.split(separator: ",").map(String.init)),
                    secondaryIDs: Set(tertiary.split(separator: ",").map(String.init))
                )
                let platform: PlatformAutomationTrigger
                switch kind {
                case .linear: platform = .linear(value)
                case .sentry: platform = .sentry(value)
                default: platform = .pagerDuty(value)
                }
                return .platform(platform)
            }
        }
    }
}

private struct AutomationListenerEditor: View {
    @Binding var listener: AutomationListenerDraft
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Trigger", selection: $listener.kind) {
                        ForEach(AutomationListenerKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if canRemove { Button("Remove", role: .destructive, action: remove) }
                }
                fields
            }.padding(4)
        }
        .onChange(of: listener.kind) { _, kind in listener = Self.defaults(for: kind, id: listener.id) }
    }

    @ViewBuilder private var fields: some View {
        switch listener.kind {
        case .schedule:
            TextField("Cron, alias, or @every 30m", text: $listener.primary)
            Picker("Time zone", selection: $listener.secondary) {
                Text("System (\(TimeZone.current.identifier))").tag("")
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
        case .connector:
            TextField("Connector UUID", text: $listener.primary)
            TextField("Event kind", text: $listener.secondary)
            TextField("JSON filters", text: $listener.filtersJSON, axis: .vertical).font(.system(.body, design: .monospaced))
        case .slack:
            TextField("Channel name or *", text: $listener.primary)
            Picker("Match", selection: $listener.secondary) {
                Text("Message").tag("message"); Text("Mention").tag("mention"); Text("Keyword").tag("keyword"); Text("Reaction").tag("reaction")
            }
            if ["keyword", "reaction"].contains(listener.secondary) { TextField(listener.secondary == "keyword" ? "Keyword" : "Emoji names, comma-separated", text: $listener.tertiary) }
        case .github:
            TextField("owner/repository", text: $listener.primary)
            TextField("Events, comma-separated", text: $listener.secondary)
            TextField("CI branch (required for CI events)", text: $listener.tertiary)
            TextField("Allowed users, comma-separated (optional)", text: $listener.quaternary)
        case .teams:
            TextField("Tenant ID", text: $listener.primary)
            TextField("Team IDs, comma-separated", text: $listener.secondary)
            TextField("Channel IDs, comma-separated (optional)", text: $listener.tertiary)
            TextField("Message contains (optional)", text: $listener.quaternary)
        case .linear, .sentry, .pagerDuty:
            TextField("Event", text: $listener.primary)
            TextField("Primary IDs, comma-separated (optional)", text: $listener.secondary)
            TextField("Secondary IDs, comma-separated (optional)", text: $listener.tertiary)
        }
    }

    private static func defaults(for kind: AutomationListenerKind, id: UUID) -> AutomationListenerDraft {
        var value = AutomationListenerDraft(id: id, kind: kind)
        switch kind {
        case .schedule: value.primary = "@daily"
        case .connector: value.primary = ""; value.secondary = ""
        case .slack: value.primary = "*"; value.secondary = "mention"
        case .github: value.primary = ""; value.secondary = "pr-opened,pr-pushed"
        case .teams: value.primary = ""; value.secondary = ""
        case .linear: value.primary = "issue-updated"
        case .sentry: value.primary = "issue-created"
        case .pagerDuty: value.primary = "incident-triggered"
        }
        return value
    }
}

private struct ChannelWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var connectorID = "slack"
    @State private var displayName = ""
    @State private var channelIDs = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var authentication = ChannelAuthenticationChoice.botToken
    @State private var agentID: UUID?
    var body: some View {
        Form {
            Section("Connect a bot") {
                Picker("Service", selection: $connectorID) {
                    ForEach(model.channelDescriptors) { Text($0.displayName).tag($0.id) }
                }
                TextField("Display name", text: $displayName)
                TextField("Channel IDs, comma-separated", text: $channelIDs)
                Picker("Authentication", selection: $authentication) {
                    Text("Bot token").tag(ChannelAuthenticationChoice.botToken)
                    Text("OAuth in browser").tag(ChannelAuthenticationChoice.oauth)
                }
                if authentication == .botToken {
                    SecureField("Bot token", text: $token)
                } else {
                    TextField("OAuth client ID", text: $clientID)
                    Text("Filicon starts a single-use callback on 127.0.0.1, uses PKCE, and stores the resulting token only in macOS Keychain.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Respond as agent", selection: $agentID) {
                    Text("Receive only").tag(nil as UUID?)
                    ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
                }
                Text(BuiltInChannelManifests.all.first(where: { $0.id == connectorID })?.connectGuide ?? "Credentials are stored in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.channelOAuthInProgress ? "Waiting for OAuth…" : "Connect") {
                    let values = (connectorID, displayName, channelIDs, token, clientID, agentID, authentication)
                    displayName = ""; channelIDs = ""; token = ""; clientID = ""
                    Task {
                        if values.6 == .oauth {
                            await model.connectChannelOAuth(
                                connectorID: values.0, clientID: values.4, displayName: values.1,
                                channelIDs: values.2, agentID: values.5
                            )
                        } else {
                            await model.createChannelConnection(
                                connectorID: values.0, displayName: values.1,
                                channelIDs: values.2, token: values.3, agentID: values.5
                            )
                        }
                    }
                }
                .disabled(
                    model.channelOAuthInProgress || channelIDs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    (authentication == .botToken ? token.isEmpty : clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                )
            }
            if !model.channelFailureWakes.isEmpty {
                Section("Needs attention") {
                    ForEach(model.channelFailureWakes) { wake in
                        HStack {
                            Label(wake.error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Spacer()
                            Button("Acknowledge") { Task { await model.acknowledgeChannelFailure(id: wake.id) } }
                        }
                    }
                }
            }
            Section("Connections") {
                ForEach(model.channelConnections) { connection in ChannelConnectionRow(connection: connection) }
                if model.channelConnections.isEmpty { Text("No connected channels.").foregroundStyle(.secondary) }
            }
            Section("Recent inbound") {
                ForEach(model.channelInboundEvents.suffix(100).reversed()) { event in
                    ChannelInboundRow(event: event)
                }
                if model.channelInboundEvents.isEmpty { Text("No inbound messages yet.").foregroundStyle(.secondary) }
            }
            Section("Delivery queue") {
                ForEach(model.channelDeliveries.suffix(100).reversed()) { delivery in
                    HStack {
                        Text(delivery.outbound.text).lineLimit(1)
                        Spacer()
                        Text("\(delivery.status.rawValue) · attempt \(delivery.attemptCount)").font(.caption).foregroundStyle(delivery.status == .deadLetter ? .red : .secondary)
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle("Channels")
    }
}

private enum ChannelAuthenticationChoice: String, Hashable {
    case botToken
    case oauth
}

private struct ChannelConnectionRow: View {
    @EnvironmentObject private var model: AppModel
    let connection: ChannelConnection
    @State private var target = ""
    @State private var thread = ""
    @State private var text = ""
    @State private var attachments: [URL] = []

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Listening to: \(connection.accountLabel)").font(.caption).foregroundStyle(.secondary)
                        if let profile = connection.profile {
                            Text("Authorized as \(profile.displayName) · \(profile.workspaceID ?? profile.id)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Refresh profile") { Task { await model.refreshChannelProfile(id: connection.id) } }
                }
                HStack {
                    TextField("Target channel ID", text: $target)
                    TextField("Thread ID (optional)", text: $thread)
                    TextField("Message", text: $text)
                    Button("Send") {
                        let values = (target, thread, text, attachments)
                        text = ""; attachments = []
                        Task {
                            await model.sendChannelMessage(
                                connectionID: connection.id, channelID: values.0,
                                threadID: values.1, text: values.2, attachmentURLs: values.3
                            )
                        }
                    }.disabled(target.isEmpty || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                }
                HStack {
                    Button("Attach files…", action: chooseAttachments)
                    if !attachments.isEmpty {
                        Text(attachments.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Button("Clear") { attachments = [] }
                    }
                }
                if let activity = connection.lastActivityAt { Text("Last activity \(activity.formatted())").font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(connection.displayName)
                    Text("\(connection.connectorID) · \(connection.agentID.flatMap { id in model.agents.first(where: { $0.id == id })?.name } ?? "receive only")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { connection.enabled },
                    set: { enabled in Task { await model.setChannelConnectionEnabled(id: connection.id, enabled: enabled) } }
                )).labelsHidden()
                Button("Remove", role: .destructive) { Task { await model.removeChannelConnection(id: connection.id) } }
            }
        }
        .onAppear { target = connection.accountLabel.split(separator: ",").first.map(String.init) ?? "" }
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        attachments = Array(panel.urls.prefix(10))
    }
}

private struct ChannelInboundRow: View {
    @EnvironmentObject private var model: AppModel
    let event: ChannelEnvelope
    @State private var emoji = "👍"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(event.senderDisplayName).fontWeight(.semibold)
                Text("\(event.address.platform) · \(event.address.channelID)\(event.address.threadID.map { " · thread \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(event.timestamp, style: .relative).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.text).textSelection(.enabled)
            if !event.attachments.isEmpty {
                ForEach(event.attachments, id: \.blobID) { attachment in
                    Label("\(attachment.filename) · \(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))", systemImage: "paperclip")
                        .font(.caption).textSelection(.enabled)
                }
            }
            HStack {
                ForEach(event.reactions, id: \.emoji) { reaction in
                    Text("\(reaction.emoji) \(reaction.count)")
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                TextField("Emoji", text: $emoji).frame(width: 70)
                Button("React") { Task { await model.setChannelReaction(event: event, emoji: emoji, removing: false) } }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") { Task { await model.setChannelReaction(event: event, emoji: emoji, removing: true) } }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }
}

private struct MCPWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var identifier = ""
    @State private var name = ""
    @State private var endpoint = "https://"
    @State private var stdioIdentifier = ""
    @State private var stdioName = ""
    @State private var executable = "/usr/bin/"
    @State private var arguments = ""
    var body: some View {
        Form {
            Section("Add Streamable HTTP server") {
                TextField("Identifier", text: $identifier); TextField("Display name", text: $name); TextField("HTTPS endpoint", text: $endpoint)
                HStack {
                    Button("Add") { let values = (identifier, name, endpoint); identifier = ""; name = ""; endpoint = "https://"; Task { await model.addMCPHTTPServer(identifier: values.0, displayName: values.1, endpoint: values.2) } }
                    Button("Reconnect All") { Task { await model.refreshMCP() } }
                }
            }
            Section("Add local stdio server") {
                TextField("Identifier", text: $stdioIdentifier)
                TextField("Display name", text: $stdioName)
                TextField("Absolute executable path", text: $executable)
                TextField("Arguments (one per line)", text: $arguments, axis: .vertical).lineLimit(2...5)
                Button("Add Local Server") {
                    let values = (stdioIdentifier, stdioName, executable, arguments.split(whereSeparator: \.isNewline).map(String.init))
                    stdioIdentifier = ""; stdioName = ""; executable = "/usr/bin/"; arguments = ""
                    Task { await model.addMCPStdioServer(identifier: values.0, displayName: values.1, executable: values.2, arguments: values.3) }
                }
            }
            Section("Servers") {
                ForEach(model.mcpConfigs.filter { config in
                    !model.mcpAccountDefinitions.contains { definition in
                        definition.managedReadOnly && definition.accounts.contains { $0.serverIdentifier == config.identifier }
                    }
                }) { config in
                    MCPServerEditor(config: config)
                }
            }
            MCPAccountsView()
            Section("Discovered tools (\(model.mcpCatalog.tools.count))") {
                ForEach(model.mcpCatalog.tools) { tool in VStack(alignment: .leading) { Text(tool.name); Text(tool.serverIdentifier).font(.caption).foregroundStyle(.secondary) } }
            }
        }.formStyle(.grouped).navigationTitle("MCP Servers")
    }
}

private struct MCPServerEditor: View {
    @EnvironmentObject private var model: AppModel
    let config: MCPServerConfig
    @State private var displayName = ""
    @State private var authorization = ""

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Display name", text: $displayName)
                    Button("Rename") { Task { await model.renameMCPServer(id: config.id, displayName: displayName) } }
                }
                if isHTTP {
                    HStack {
                        SecureField("Authorization header value", text: $authorization)
                        Button("Save Token") {
                            let token = authorization; authorization = ""
                            Task { await model.saveMCPAuthorization(id: config.id, token: token) }
                        }
                    }
                    Text("The token is stored in Keychain; configuration contains only its reference.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !toolNames.isEmpty {
                    Text("Tools").font(.caption.bold())
                    ForEach(toolNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { !config.disabledTools.contains(name) },
                            set: { enabled in Task { await model.setMCPToolEnabled(serverIdentifier: config.identifier, toolName: name, enabled: enabled) } }
                        ))
                    }
                }
                HStack {
                    Button("Reconnect") { Task { await model.refreshMCP() } }
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await model.deleteMCPServer(id: config.id) } }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(config.displayName)
                    Text("\(config.identifier) · \(statusLabel)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enabled", isOn: Binding(
                    get: { config.enabled },
                    set: { enabled in Task { await model.setMCPServerEnabled(id: config.id, enabled: enabled) } }
                )).labelsHidden()
            }
        }
        .onAppear { displayName = config.displayName }
        .onChange(of: config.displayName) { _, value in displayName = value }
    }

    private var isHTTP: Bool {
        switch config.transport { case .streamableHTTP, .legacySSE: true; case .stdio: false }
    }

    private var toolNames: [String] {
        let discovered = model.mcpCatalog.tools
            .filter { $0.serverIdentifier == config.identifier }
            .map(\.name)
        return Array(Set(discovered).union(config.disabledTools)).sorted()
    }

    private var statusLabel: String {
        switch model.mcpCatalog.statuses[config.identifier] {
        case .disabled: "Disabled"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .needsAuth: "Needs authentication"
        case .error(let message): message
        case nil: "Not connected"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var provider: ProviderID = "openai"
    @State private var apiKey = ""
    @State private var status = ""
    @State private var updateFeed = ""
    @State private var updateKey = ""
    @State private var cloudEndpoint = ""
    @State private var cloudCredentialReference = "default"
    @State private var cloudBearer = ""
    var body: some View {
        Form {
            PersistenceRecoverySettingsSection()
            Section("Appearance and locale") {
                Picker("Theme", selection: Binding(
                    get: { model.settings.theme },
                    set: { value in Task { await model.setTheme(value) } }
                )) {
                    Text("System").tag(ThemePreference.system)
                    Text("Light").tag(ThemePreference.light)
                    Text("Dark").tag(ThemePreference.dark)
                }
                Picker("Time zone", selection: Binding(
                    get: { model.settings.timeZoneIdentifier ?? "" },
                    set: { value in Task { await model.setTimeZone(value.isEmpty ? nil : value) } }
                )) {
                    Text("System (\(TimeZone.current.identifier))").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                        Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                    }
                }
            }
            Section("Conversation defaults") {
                if let selected = model.selectedConversation {
                    Button("Use current provider and model as default") {
                        Task { await model.setDefaultModel(providerID: selected.providerID, modelID: selected.modelID) }
                    }
                }
                if let value = model.settings.defaultModel {
                    HStack {
                        Text("Default")
                        Spacer()
                        Text("\(value.providerID) / \(value.modelID)").foregroundStyle(.secondary)
                        Button("Clear") { Task { await model.clearDefaultModel() } }
                    }
                } else {
                    LabeledContent("Default", value: "App default")
                }
                Picker("If unavailable", selection: Binding(
                    get: { model.settings.unavailableModelFallback },
                    set: { value in Task { await model.setUnavailableModelFallback(value) } }
                )) {
                    Text("Same provider default").tag(UnavailableModelFallbackPolicy.providerDefault)
                    Text("First available provider").tag(UnavailableModelFallbackPolicy.firstAvailable)
                    Text("Do not replace").tag(UnavailableModelFallbackPolicy.none)
                }
            }
            Section("AI providers") {
                Picker("Provider", selection: $provider) {
                    ForEach(model.descriptors.filter(\.requiresAPIKey)) { Text($0.displayName).tag($0.id) }
                }
                SecureField("API key", text: $apiKey)
                Text("Keys are stored only in the macOS Keychain. Filicon never reads another app's credentials.").font(.caption).foregroundStyle(.secondary)
                HStack { Button("Save to Keychain") { Task { do { try await model.saveAPIKey(apiKey, providerID: provider); apiKey = ""; status = "Saved" } catch { status = error.localizedDescription } } }; Text(status).foregroundStyle(.secondary) }
                HStack {
                    Button("Refresh Current Model Catalog") {
                        Task { await model.refreshModels(forceRefresh: true) }
                    }
                    .disabled(model.isLoadingModels || model.selectedConversation == nil)
                    .accessibilityLabel("Refresh current model catalog")
                    if model.isLoadingModels { ProgressView().controlSize(.small) }
                    Text(model.modelCatalogStatusLabel).foregroundStyle(.secondary)
                }
            }
            Section("Cloud agents") {
                TextField("HTTPS endpoint", text: $cloudEndpoint)
                TextField("Keychain reference", text: $cloudCredentialReference)
                SecureField("Bearer token (leave blank to keep existing)", text: $cloudBearer)
                Text("The endpoint is persisted without credentials. Bearer tokens are stored only in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save and Refresh") {
                        Task {
                            await model.configureCloudAgents(
                                endpoint: cloudEndpoint,
                                credentialReference: cloudCredentialReference,
                                bearer: cloudBearer
                            )
                            cloudBearer = ""
                        }
                    }
                    .disabled(cloudEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.isRefreshingCloudAgents { ProgressView().controlSize(.small) }
                    Text(model.cloudAgentCatalog.isEmpty ? "Not loaded" : "\(model.cloudAgentCatalog.count) available")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Notifications") {
                HStack {
                    Text("Completion notifications")
                    Spacer()
                    Text(notificationStatusLabel).foregroundStyle(.secondary)
                    Button("Enable") {
                        Task {
                            do { try await model.systemNotifications.requestAuthorization() }
                            catch { status = error.localizedDescription }
                        }
                    }
                }
            }
            Section("Local tool permissions") {
                Text("Always still creates a signed, exact-operation receipt. Ask pauses the tool call until you allow it once. Never fails closed.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Set all local tools", selection: Binding(
                    get: { model.settings.effectiveLocalToolPermission },
                    set: { value in Task { await model.setGlobalLocalToolPermission(value) } }
                )) {
                    Text("Always").tag(LocalToolPermission.always)
                    Text("Ask").tag(LocalToolPermission.ask)
                    Text("Never").tag(LocalToolPermission.never)
                }
                ForEach(LocalToolAction.allCases, id: \.self) { action in
                    Picker(localToolActionLabel(action), selection: Binding(
                        get: { model.localToolPermissions[action] ?? .ask },
                        set: { value in Task { await model.setLocalToolPermission(value, for: action) } }
                    )) {
                        Text("Always").tag(LocalToolPermission.always)
                        Text("Ask").tag(LocalToolPermission.ask)
                        Text("Never").tag(LocalToolPermission.never)
                    }
                }
            }
            Section("Security Key") {
                Toggle("Use hardware security keys", isOn: Binding(
                    get: { model.securityKeyEnabled && model.securityKeySupported },
                    set: { value in Task { await model.setSecurityKeyEnabled(value) } }
                ))
                .disabled(!model.securityKeySupported)
                Text(model.securityKeySupported
                     ? "Allow a remote Filicon computer to use a hardware security key connected to this Mac. Every request shows its origin and relying-party ID for one-time approval."
                     : "External hardware security keys require macOS 14.4 or later.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(securityKeyStatusLabel).font(.caption).foregroundStyle(.secondary)
                Text("Bearer credentials remain in macOS Keychain. Authentication Services owns any PIN or biometric prompt; Filicon never collects a PIN and never falls back to a platform passkey.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            AutoReviewSettingsView()
            Section("Authorized workspace folders") {
                Text("Local file and process tools can use only these exact folders. Access is stored as macOS security-scoped bookmarks.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.workspaceAuthorizations) { authorization in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(authorization.displayName)
                            Text(authorization.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await model.removeWorkspaceAuthorization(id: authorization.id) }
                        }
                    }
                }
                Button("Authorize Folder…", action: model.authorizeWorkspaceFolder)
            }
            Section("Updates") {
                Picker("Release track", selection: Binding(
                    get: { model.settings.updatePolicy.effectiveTrack },
                    set: { value in Task { await model.setUpdateTrack(value) } }
                )) {
                    ForEach(model.settings.updatePolicy.enabledTracks.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { track in
                        Text(track.rawValue.capitalized).tag(track)
                    }
                }
                Toggle("Install downloaded updates when idle", isOn: Binding(
                    get: { model.settings.updatePolicy.installWhenIdle },
                    set: { value in Task { await model.setInstallUpdatesWhenIdle(value) } }
                ))
                Text("Updates are accepted only from HTTPS feeds and verified with the release signing key before installation.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("HTTPS feed URL", text: $updateFeed)
                SecureField("Ed25519 public key (Base64)", text: $updateKey)
                HStack {
                    Button("Save Update Source") { let values = (updateFeed, updateKey); Task { await model.configureUpdates(feedURL: values.0, publicKeyBase64: values.1) } }
                    Button("Check Now") { Task { await model.checkForUpdates() } }
                        .disabled(model.updateFeedURLString.isEmpty)
                    if case .available = model.updateState {
                        Button("Download") { Task { await model.downloadAvailableUpdate() } }
                    }
                    if case .staged = model.updateState {
                        Button("Install and Relaunch") { Task { await model.installStagedUpdate() } }
                    }
                }
                Label(updateStatusLabel, systemImage: updateStatusIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Usage") {
                let total = model.settings.usageByAccount.values.reduce(into: UsageCounters()) { partial, account in
                    let value = account.total
                    partial = UsageCounters(
                        requests: partial.requests + value.requests,
                        inputTokens: partial.inputTokens + value.inputTokens,
                        outputTokens: partial.outputTokens + value.outputTokens,
                        cacheReadTokens: partial.cacheReadTokens + value.cacheReadTokens,
                        cacheWriteTokens: partial.cacheWriteTokens + value.cacheWriteTokens,
                        costMicros: partial.costMicros + value.costMicros
                    )
                }
                LabeledContent("Requests", value: total.requests.formatted())
                LabeledContent("Input tokens", value: total.inputTokens.formatted())
                LabeledContent("Output tokens", value: total.outputTokens.formatted())
                if model.settings.usageByAccount.isEmpty {
                    Text("No provider usage has been recorded on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.settings.usageByAccount.keys.sorted(), id: \.self) { accountID in
                    if let account = model.settings.usageByAccount[accountID] {
                        DisclosureGroup(accountID) {
                            ForEach(account.providers.keys.sorted(), id: \.self) { providerID in
                                if let usage = account.providers[providerID] {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(providerID).font(.caption.bold()).textSelection(.enabled)
                                        Text("\(usage.requests.formatted()) requests · \(usage.inputTokens.formatted()) input · \(usage.outputTokens.formatted()) output")
                                            .font(.caption).foregroundStyle(.secondary)
                                        if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
                                            Text("Cache: \(usage.cacheReadTokens.formatted()) read · \(usage.cacheWriteTokens.formatted()) write")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if usage.costMicros > 0 {
                                            Text("Recorded cost: \(Double(usage.costMicros) / 1_000_000, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Button("Reset usage", role: .destructive) { Task { await model.resetUsage() } }
            }
        }.formStyle(.grouped)
            .task {
                await model.systemNotifications.refreshAuthorization()
                await model.reloadLocalToolSettings()
                updateFeed = model.updateFeedURLString
                updateKey = model.updatePublicKeyBase64
                cloudEndpoint = model.cloudAgentEndpoint
                cloudCredentialReference = model.cloudAgentCredentialReference
            }
    }

    private var notificationStatusLabel: String {
        switch model.systemNotifications.authorizationStatus {
        case .authorized: "Enabled"
        case .denied: "Denied in System Settings"
        case .provisional: "Provisional"
        case .ephemeral: "Temporary"
        case .notDetermined: "Not enabled"
        @unknown default: "Unknown"
        }
    }

    private var securityKeyStatusLabel: String {
        switch model.securityKeyStatus {
        case .disabled: "Disabled"
        case .disconnected: "Disconnected"
        case .reconnecting(let attempt): "Reconnecting (attempt \(attempt))"
        case .connected: "Connected"
        case .awaitingConsent(let origin, let rpID): "Awaiting approval for \(origin) (\(rpID))"
        case .waitingForSystemPIN: "Follow the macOS PIN or verification prompt"
        case .waitingForPresence: "Touch your hardware security key"
        case .completed: "Last request completed"
        case .failed(let message): message
        }
    }

    private var updateStatusLabel: String {
        switch model.updateState {
        case .idle: "Update checks are idle"
        case .checking: "Checking for updates…"
        case .upToDate(let date): "Up to date · checked \(date.formatted(date: .omitted, time: .shortened))"
        case .available(let release): "Version \(release.version) (\(release.build)) is available"
        case .downloading(let release): "Downloading \(release.version)…"
        case .staged(let update, _): "Version \(update.release.version) is verified and ready"
        case .installing(let update): "Installing version \(update.release.version)…"
        case .failed(let message): "Update failed: \(message)"
        }
    }

    private var updateStatusIcon: String {
        switch model.updateState {
        case .available, .staged: "arrow.down.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .checking, .downloading, .installing: "arrow.triangle.2.circlepath"
        case .idle, .upToDate: "checkmark.shield"
        }
    }

    private func localToolActionLabel(_ action: LocalToolAction) -> String {
        switch action {
        case .runCommand: "Run and manage processes"
        case .sendInput: "Send process input"
        case .readFile: "Read files"
        case .listDirectory: "List directories"
        case .writeFile: "Write files"
        }
    }
}

private extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

private struct LocalToolApprovalView: View {
    @EnvironmentObject private var model: AppModel
    let request: ToolApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Allow this local action?", systemImage: "exclamationmark.shield")
                .font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Action").foregroundStyle(.secondary)
                    Text(actionLabel).fontWeight(.semibold)
                }
                GridRow {
                    Text("Target").foregroundStyle(.secondary)
                    Text(request.title).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text("Reason").foregroundStyle(.secondary)
                    Text(request.reason).textSelection(.enabled)
                }
            }
            Text("Allow Once is bound to this exact tool call. Persistent choices apply to this action for every agent and can be changed in Settings.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Deny") { model.resolveLocalToolApproval(id: request.id, allowed: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Never") { model.persistLocalToolApproval(request, permission: .never) }
                Spacer()
                Button("Always Allow") { model.persistLocalToolApproval(request, permission: .always) }
                    .disabled(!model.canPersistAlwaysLocalToolApproval())
                    .help(model.canPersistAlwaysLocalToolApproval()
                          ? "Always allow this local action"
                          : "Managed policy does not allow a persistent Always choice")
                Button("Allow Once") { model.resolveLocalToolApproval(id: request.id, allowed: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 540)
    }

    private var actionLabel: String {
        switch request.action {
        case .runCommand: "Run or manage process"
        case .sendInput: "Send process input"
        case .readFile: "Read file"
        case .listDirectory: "List directory"
        case .writeFile: "Write file"
        }
    }
}
