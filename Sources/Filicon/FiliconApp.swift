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
    @StateObject private var launch = FiliconLaunchState()
    @AppStorage(FiliconLocalization.preferenceKey) private var preferredLanguage = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup(id: "main") {
            if let model = launch.model {
                ContentView()
                    .environmentObject(model)
                    .frame(minWidth: 512, minHeight: 520)
                    .preferredColorScheme(model.settings.theme.colorScheme)
                    .environment(\.locale, selectedLanguage.locale)
                    .background(AppWindowAccessor().frame(width: 0, height: 0))
                    .onOpenURL(perform: model.handleDeepLink)
                    .onReceive(NotificationCenter.default.publisher(for: .filiconOpenDeepLink)) { notification in
                        if let url = notification.object as? URL { model.handleDeepLink(url) }
                    }
            } else {
                StartupStorageFailureView(detail: launch.failure ?? "")
                    .environment(\.locale, selectedLanguage.locale)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AboutCommands()
            CommandGroup(after: .newItem) {
                if let model = launch.model {
                    Button(FiliconLocalization.string("New Conversation")) { model.addConversation() }
                        .keyboardShortcut("n")
                        .disabled(!model.isBootstrapped)
                }
            }
            CommandMenu(FiliconLocalization.string("Conversation")) {
                if let model = launch.model {
                    Button(FiliconLocalization.string("Find in Chat")) {
                        NotificationCenter.default.post(name: .filiconFindInChat, object: model.selection)
                    }
                    .keyboardShortcut("f")
                    .disabled(model.selectedConversation == nil)
                }
            }
            CommandMenu(FiliconLocalization.string("Navigate")) {
                if let model = launch.model {
                    Button(FiliconLocalization.string("Search")) { model.focusGlobalSearch() }
                        .keyboardShortcut("k", modifiers: [.command])
                    Divider()
                    Button(FiliconLocalization.string("Back")) { model.goBack() }
                        .keyboardShortcut("[", modifiers: [.command])
                        .disabled(!model.canGoBack)
                    Button(FiliconLocalization.string("Forward")) { model.goForward() }
                        .keyboardShortcut("]", modifiers: [.command])
                        .disabled(!model.canGoForward)
                    Divider()
                    Button(FiliconLocalization.string("Reload Workspace")) { Task { await model.reloadRootWorkspace() } }
                        .keyboardShortcut("r", modifiers: [.command])
                }
            }
        }
        Settings {
            if let model = launch.model {
                SettingsView()
                    .environmentObject(model)
                    .preferredColorScheme(model.settings.theme.colorScheme)
                    .environment(\.locale, selectedLanguage.locale)
                    .frame(width: 660, height: 700)
            } else {
                StartupStorageFailureView(detail: launch.failure ?? "")
                    .environment(\.locale, selectedLanguage.locale)
            }
        }
        Window(l10n("About Filicon"), id: "about") {
            if let model = launch.model {
                AboutView()
                    .environmentObject(model)
                    .preferredColorScheme(model.settings.theme.colorScheme)
                    .environment(\.locale, selectedLanguage.locale)
            }
        }
        .windowResizability(.contentSize)
    }

    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: preferredLanguage) ?? .system
    }
}

/// Do not construct any stores if startup cannot safely use the app's own root.
@MainActor
final class FiliconLaunchState: ObservableObject {
    let model: AppModel?
    let failure: String?

    init(context: () throws -> AppStartupContext = { try AppStartupContext.production() }) {
        do {
            model = AppModel(startupContext: try context())
            failure = nil
        } catch {
            model = nil
            failure = error.localizedDescription
        }
    }
}

private struct StartupStorageFailureView: View {
    @Environment(\.locale) private var locale
    let detail: String

    var body: some View {
        let _ = locale.identifier
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark").font(.system(size: 36))
            Text(l10n("Filicon could not open its data folder.")).font(.title2)
            Text(l10n("No workspace data was opened or moved. Check folder permissions, then restart Filicon."))
                .multilineTextAlignment(.center)
            Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button(l10n("Quit Filicon")) { NSApplication.shared.terminate(nil) }
        }
        .padding(32).frame(width: 520, height: 320)
    }
}

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case french = "fr"
    case spanish = "es"
    case japanese = "ja"
    case korean = "ko"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        LocalizedStringKey(localizationKey)
    }

    var localizationKey: String {
        switch self {
        case .system: "Follow System"
        case .english: "English"
        case .traditionalChinese: "Traditional Chinese"
        case .simplifiedChinese: "Simplified Chinese"
        case .french: "French"
        case .spanish: "Spanish"
        case .japanese: "Japanese"
        case .korean: "Korean"
        }
    }

    var locale: Locale {
        guard self == .system else { return Locale(identifier: rawValue) }
        return Self.systemLocale(preferredLanguages: Locale.preferredLanguages)
    }

    static func systemLocale(preferredLanguages: [String]) -> Locale {
        let preferred = (preferredLanguages.first ?? "en").replacingOccurrences(of: "_", with: "-").lowercased()
        if preferred.hasPrefix("zh-hant") || (!preferred.hasPrefix("zh-hans") && ["zh-tw", "zh-hk", "zh-mo"].contains(where: preferred.hasPrefix)) {
            return Locale(identifier: "zh-Hant")
        }
        if preferred.hasPrefix("zh") { return Locale(identifier: "zh-Hans") }
        let language = preferred.split(separator: "-").first.map(String.init) ?? "en"
        return Locale(identifier: ["en", "fr", "es", "ja", "ko"].contains(language) ? language : "en")
    }
}

struct ContentView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            FiliconWorkspaceShell {
                workspaceDetail
            }
            AccountConnectionBanner()
            PersistenceRecoveryBanner()
            UpdateStatusPill()
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(FiliconTheme.canvas)
        .tint(FiliconTheme.accent)
        .alert(l10n("Filicon"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button(l10n("OK")) { model.errorMessage = nil } } message: { Text(FiliconLocalization.message(model.errorMessage ?? "")) }
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
            else { GroupWorkspaceView() }
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
        case nil: GroupWorkspaceView()
        }
    }
}


private struct UpdateStatusPill: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let _ = uiLocale.identifier
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
                .tint(presentation.isError ? Color.red : FiliconTheme.accent)
                .foregroundStyle(presentation.isError ? Color.red : FiliconTheme.textPrimary)
                .accessibilityIdentifier("update-status-pill")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(FiliconTheme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(FiliconTheme.border).frame(height: 0.7) }
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
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let _ = uiLocale.identifier
        let presentation = RequiredUpdatePresentation.make(state: model.updateState)
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: presentation.isError ? "exclamationmark.triangle.fill" : "arrow.down.app.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(presentation.isError ? Color.red : Color.accentColor)
                Text(l10n("Update Required")).font(.title.bold())
                Text(l10n("This version of Filicon is below the required minimum version\(minimumSuffix)."))
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


private struct HiddenChatsView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let _ = uiLocale.identifier
        List {
            ForEach(model.hiddenConversations) { conversation in
                HStack {
                    VStack(alignment: .leading) {
                        Text(conversation.title)
                        Text(conversation.hiddenAt?.formatted() ?? l10n("Hidden")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n("Restore")) { model.setConversationHidden(id: conversation.id, hidden: false) }
                    Button(l10n("Delete"), role: .destructive) { model.deleteConversation(id: conversation.id) }
                }
            }
        }
        .overlay {
            if model.hiddenConversations.isEmpty { ContentUnavailableView(l10n("No hidden chats"), systemImage: "archivebox") }
        }
        .navigationTitle(l10n("Hidden Chats"))
    }
}

private struct PluginsWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var tab: PluginBrowserTab = .marketplace
    @State private var type: PluginTypeFilter = .all
    @State private var ownership: PluginOwnership?
    @State private var query = ""
    @State private var selectedEntry: PluginCatalogEntry?
    @State private var showingImporter = false
    @State private var catalogURL = ""

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
            HStack {
                Picker(localized("Collection"), selection: $tab) {
                    Text(localized("Marketplace")).tag(PluginBrowserTab.marketplace)
                    Text(localized("Yours")).tag(PluginBrowserTab.yours)
                }.pickerStyle(.segmented).fixedSize()
                TextField(localized("Search plugins"), text: $query).textFieldStyle(.roundedBorder).frame(minWidth: 180)
                Picker(localized("Type"), selection: $type) {
                    Text(localized("All")).tag(PluginTypeFilter.all)
                    Text(localized("Connectors")).tag(PluginTypeFilter.connectors)
                    Text(localized("Skills")).tag(PluginTypeFilter.skills)
                }.fixedSize()
                Picker(localized("Owner"), selection: $ownership) {
                    Text(localized("All owners")).tag(nil as PluginOwnership?)
                    Text(localized("Public")).tag(Optional(PluginOwnership.publicMarketplace))
                    Text(localized("Team")).tag(Optional(PluginOwnership.team))
                    Text(localized("User")).tag(Optional(PluginOwnership.user))
                }.fixedSize()
                Button { Task { await model.reloadPlugins(forceCatalogRefresh: true) } } label: {
                    if model.isRefreshingPlugins { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }.disabled(model.isRefreshingPlugins)
                Button(localized("Import…")) { showingImporter = true }
            }.padding(12)
            }.fixedSize(horizontal: false, vertical: true)
            Divider()
            Group {
            if tab == .marketplace && model.pluginCatalogURLString.isEmpty {
                ContentUnavailableView {
                    Label(localized("Choose a plugin catalog"), systemImage: "puzzlepiece.extension")
                } description: {
                    Text(localized("Filicon accepts a generic HTTPS catalog, so plugin distribution is not tied to one AI vendor."))
                } actions: {
                    VStack(spacing: 12) {
                        TextField(l10n("https://…/catalog.json"), text: $catalogURL)
                            .textFieldStyle(.roundedBorder)
                        Button(localized("Use Catalog"), action: configureCatalog)
                            .buttonStyle(FiliconPrimaryButtonStyle())
                            .disabled(catalogURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.frame(maxWidth: 340).padding(.horizontal, 16)
                }
            } else {
                List {
                    if tab == .marketplace {
                        ForEach(visibleCatalog) { entry in
                            Button { selectedEntry = entry } label: { catalogRow(entry) }.buttonStyle(.plain)
                        }
                        if visibleCatalog.isEmpty { Text(localized("No plugins match these filters.")).foregroundStyle(.secondary) }
                    } else {
                        PrivateSkillsSection()
                        Section(localized("Installed")) {
                            ForEach(visibleInstalled) { plugin in PluginInstalledRow(plugin: plugin) }
                            if visibleInstalled.isEmpty { Text(localized("No installed plugins match.")).foregroundStyle(.secondary) }
                        }
                        Section(localized("Skills")) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(localized("Plugins"))
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

    private func localized(_ key: String) -> String {
        FiliconLocalization.string(key)
    }

    private func configureCatalog() {
        let value = catalogURL
        Task { await model.configurePluginCatalog(value) }
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
                model.errorMessage = l10n("Plugin “\(id)” is not available in the configured catalogs.")
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
                    if !entry.manifest.connectors.isEmpty { Text(l10n("\(entry.manifest.connectors.count) connectors")) }
                    if !entry.manifest.skills.isEmpty { Text(l10n("\(entry.manifest.skills.count) skills")) }
                    Text(entry.ownership == .publicMarketplace ? localized("Public") : localized(entry.ownership.rawValue.capitalized))
                    if entry.policy == .required { Text(localized("Required")).foregroundStyle(.orange) }
                }.font(.caption)
            }
            Spacer()
            Text(model.installedPlugins.contains(where: { $0.id == entry.id }) ? localized("Installed") : localized("View"))
                .foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct PluginInstallSheet: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: PluginCatalogEntry
    @State private var values: [String: String] = [:]
    @State private var installing = false

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.manifest.displayName).font(.title2.bold())
            Text(entry.manifest.description).foregroundStyle(.secondary)
            if let publisher = entry.publisher { LabeledContent(l10n("Publisher"), value: publisher) }
            LabeledContent(l10n("Version"), value: entry.manifest.version)
            if !entry.manifest.connectors.isEmpty {
                GroupBox(l10n("Connectors")) { ForEach(entry.manifest.connectors) { Text($0.name).frame(maxWidth: .infinity, alignment: .leading) } }
            }
            if !entry.manifest.skills.isEmpty {
                GroupBox(l10n("Skills")) { ForEach(entry.manifest.skills) { skill in VStack(alignment: .leading) { Text(skill.name); Text(skill.description).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) } }
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
                Button(l10n("Cancel")) { dismiss() }
                Button(l10n("Install")) {
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
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let plugin: InstalledPlugin
    @State private var toolName = ""

    var body: some View {
        let _ = uiLocale.identifier
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if !plugin.manifest.connectors.isEmpty {
                    Text(l10n("Connectors: \(plugin.manifest.connectors.map(\.name).joined(separator: ", "))"))
                }
                if !plugin.manifest.skills.isEmpty {
                    Text(l10n("Skills: \(plugin.manifest.skills.map(\.name).joined(separator: ", "))"))
                }
                ForEach(plugin.disabledToolNames.sorted(), id: \.self) { name in
                    Toggle(l10n("Disable \(name)"), isOn: Binding(
                        get: { plugin.disabledToolNames.contains(name) },
                        set: { disabled in Task { await model.setPluginToolDisabled(pluginID: plugin.id, toolName: name, disabled: disabled) } }
                    ))
                }
                HStack {
                    TextField(l10n("Tool name to disable"), text: $toolName)
                    Button(l10n("Disable")) {
                        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines); toolName = ""
                        Task { await model.setPluginToolDisabled(pluginID: plugin.id, toolName: name, disabled: true) }
                    }.disabled(toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(plugin.manifest.displayName)
                    Text("\(plugin.manifest.version) · \(FiliconLocalization.string(plugin.policy.rawValue))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n("Remove"), role: .destructive) { Task { await model.uninstallPlugin(id: plugin.id) } }
                    .disabled(!plugin.policy.permitsRemoval)
            }
        }
    }
}

private struct ComputerWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = "http://127.0.0.1:6080/vnc.html"
    @State private var sessionToken = ""

    var body: some View {
        let _ = uiLocale.identifier
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
                        Button(l10n("Give Back")) { Task { await model.giveBackVNCControl() } }
                    } else {
                        Button(l10n("Take Control")) { Task { await model.takeVNCControl() } }
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
                        Label(l10n("VNC renderer stopped repeatedly"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(l10n("The renderer was stopped after four crashes within 60 seconds."))
                    } actions: {
                        Button(l10n("Try again")) { Task { await model.recoverVNCRenderer() } }
                        Button(l10n("Disconnect")) { Task { await model.disconnectVNC() } }
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
                    .accessibilityLabel(l10n("Remote computer viewer"))
                    .overlay(alignment: .topTrailing) {
                        Button(l10n("Disconnect")) { Task { await model.disconnectVNC() } }
                            .padding(8)
                    }
                }
            } else {
                Form {
                    Section(l10n("VNC connection")) {
                        TextField(l10n("http://127.0.0.1:6080/vnc.html or HTTPS URL"), text: $endpoint)
                            .textContentType(.URL)
                        SecureField(l10n("Session token"), text: $sessionToken)
                        Text(l10n("Only loopback HTTP or the exact HTTPS origin entered here is accepted. The top-level VNC page must be /vnc.html and present the same session token."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(l10n("Connect")) {
                            let endpoint = endpoint
                            let token = sessionToken
                            sessionToken = ""
                            Task { await model.connectVNC(endpoint: endpoint, sessionToken: token) }
                        }
                        .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sessionToken.isEmpty)
                    }
                    RemoteComputerControlsView()
                    Section(l10n("Teach recording")) {
                        Text(l10n("Teach records a private ScreenCaptureKit monitor for at most 10 minutes. Incomplete crash artifacts are quarantined at next launch."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(l10n("Open Screen Recording Settings")) {
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
        .navigationTitle(l10n("Computer"))
        .onDisappear { Task { await model.shutdownComputerIntegration() } }
    }

    @ViewBuilder private var teachControls: some View {
        if let policy = model.teachStatus.maskingPolicy {
            Label(l10n("\(model.teachStatus.maskedWindowCount) masked"), systemImage: "eye.slash")
                .font(.caption)
            Label(l10n("\(model.teachStatus.pausedSensitiveWindowCount) paused"), systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(model.teachStatus.pausedSensitiveWindowCount > 0 ? .orange : .secondary)
            Text(l10n("Policy v\(policy.version) · \(policy.failClosed ? "fail closed" : "permissive")"))
                .font(.caption2).foregroundStyle(.secondary)
        }
        switch model.teachStatus.phase {
        case .idle:
            if model.teachStatus.savedVideoURL != nil {
                Button(l10n("Attach recording")) { Task { await model.attachTeachRecording() } }
            }
            Button { Task { await model.startTeachRecording() } } label: {
                Label(l10n("Teach"), systemImage: "record.circle")
            }
        case .starting, .recovering:
            ProgressView().controlSize(.small)
            Text(model.teachStatus.phase == .starting ? l10n("Starting recording…") : l10n("Recovering recordings…"))
                .font(.caption).foregroundStyle(.secondary)
        case .recording:
            Label(l10n("Recording"), systemImage: "record.circle.fill").foregroundStyle(.red)
            Button(l10n("Save")) { Task { await model.stopTeachRecording(save: true) } }
            Button(l10n("Discard"), role: .destructive) { Task { await model.stopTeachRecording(save: false) } }
        case .finalizing:
            ProgressView().controlSize(.small)
            Text(l10n("Finalizing…")).font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label(model.teachStatus.errorMessage ?? l10n("Recording failed"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            Button(l10n("Retry")) { Task { await model.startTeachRecording() } }
        }
    }

    @ViewBuilder private var takeoverStatus: some View {
        if let snapshot = model.vncControlSnapshot {
            Label(snapshot.owner == .agent ? l10n("Agent control") : l10n("User control"),
                  systemImage: snapshot.owner == .agent ? "cpu" : "person.fill")
                .font(.caption)
            if snapshot.userPresent {
                Text(l10n("User present")).font(.caption).foregroundStyle(.orange)
            } else if let deadline = snapshot.lease?.deadlineMilliseconds {
                Text(l10n("Lease until \(Date(timeIntervalSince1970: Double(deadline) / 1_000).formatted(date: .omitted, time: .standard))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusText: String {
        switch model.computerSnapshot.phase {
        case .off: l10n("Off")
        case .starting: l10n("Starting")
        case .sleeping: l10n("Sleeping")
        case .local: l10n("This Mac")
        case .running: l10n("Connected")
        case .pulling: l10n("Downloading computer image")
        case .crashedOut: l10n("Renderer stopped")
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

private struct FiliconChatHeader: View {
    @Environment(\.locale) private var uiLocale
    let title: String
    let providerName: String
    let modelName: String
    let isWorking: Bool
    let isLoadingCatalog: Bool
    let onConfiguration: () -> Void
    let onFind: () -> Void
    let onOutline: () -> Void

    var body: some View {
        let _ = uiLocale.identifier
        HStack(spacing: 11) {
            PetAvatarImage(pet: .codex).frame(width: 28, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FiliconTheme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(providerName).lineLimit(1)
                    Text("·").foregroundStyle(FiliconTheme.textTertiary)
                    Text(modelName).lineLimit(1)
                    if isWorking {
                        Text(l10n("· Working"))
                            .foregroundStyle(FiliconTheme.accent)
                    } else if isLoadingCatalog {
                        ProgressView().controlSize(.mini)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(FiliconTheme.textSecondary)
            }
            Spacer(minLength: 10)
            FiliconIconButton(label: l10n("Model and provider settings"), systemName: "slider.horizontal.3", action: onConfiguration)
            FiliconIconButton(label: l10n("Find in Chat (⌘F)"), systemName: "magnifyingglass", action: onFind)
            FiliconIconButton(label: l10n("Full conversation"), systemName: "list.bullet", action: onOutline)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(FiliconTheme.canvas)
    }
}

private struct ChatConfigurationPopover: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(l10n("Model settings")).font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshModels(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(model.isLoadingModels)
                .help(l10n("Refresh model catalog"))
            }
            Picker(l10n("Provider"), selection: Binding(
                get: { conversation.providerID },
                set: { model.updateRoute(providerID: $0) }
            )) {
                ForEach(model.descriptors) { descriptor in
                    Text(descriptor.displayName).tag(descriptor.id)
                }
            }
            .pickerStyle(.menu)
            Picker(l10n("Model"), selection: Binding(
                get: { conversation.modelID },
                set: { model.updateRoute(providerID: conversation.providerID, modelID: $0) }
            )) {
                ForEach(model.availableModels) { model in
                    Text(ProviderCatalogPresentation.modelLabel(model)).tag(model.id)
                }
            }
            .pickerStyle(.menu)
            Picker(l10n("Reasoning"), selection: Binding(
                get: { conversation.reasoningEffort },
                set: { model.setReasoningEffort($0) }
            )) {
                ForEach(model.supportedReasoningEfforts, id: \.self) { effort in
                    Text(FiliconLocalization.string(effort.rawValue.capitalized)).tag(effort)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.selectedModel == nil)
            HStack(spacing: 5) {
                if model.isLoadingModels { ProgressView().controlSize(.small) }
                Text(model.modelCatalogStatusLabel)
                if let updated = model.modelCatalogLastUpdated {
                    Text(updated, style: .relative)
                }
            }
            .font(.caption)
            .foregroundStyle(model.modelCatalogError == nil && !model.isModelCatalogStale ? FiliconTheme.textTertiary : FiliconTheme.warning)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(l10n("Model catalog status: \(model.modelCatalogStatusLabel)"))
            if let configurationError = model.selectedConversationConfigurationError, !model.isLoadingModels {
                Text(FiliconLocalization.message(configurationError))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let usage = model.selectedProviderUsage, usage.requests > 0 {
                Text(l10n("\(usage.requests.formatted()) requests · \(usage.inputTokens.formatted()) in / \(usage.outputTokens.formatted()) out"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(FiliconTheme.textTertiary)
            }
        }
        .padding(16)
        .frame(width: 310)
        .background(FiliconTheme.surface)
    }
}

struct ChatDetailView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let conversation: Conversation
    @State private var showingImporter = false
    @State private var showingFind = false
    @State private var showingOutline = false
    @State private var showingConfiguration = false
    @State private var transcript: TranscriptPresentationState
    @State private var replyJumpTargetID: UUID?
    @FocusState private var findFieldFocused: Bool

    init(conversation: Conversation) {
        self.conversation = conversation
        _transcript = State(initialValue: TranscriptPresentationState(messages: conversation.messages))
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            FiliconChatHeader(
                title: conversation.title == "New conversation" ? l10n("New Conversation") : conversation.title,
                providerName: model.descriptors.first(where: { $0.id == conversation.providerID })?.displayName ?? conversation.providerID.rawValue,
                modelName: model.availableModels.first(where: { $0.id == conversation.modelID })?.displayName ?? conversation.modelID.rawValue,
                isWorking: model.running.contains(conversation.id),
                isLoadingCatalog: model.isLoadingModels,
                onConfiguration: { showingConfiguration.toggle() },
                onFind: openFind,
                onOutline: { showingOutline = true }
            )
            .popover(isPresented: $showingConfiguration, arrowEdge: .bottom) {
                ChatConfigurationPopover(conversation: conversation)
                    .environmentObject(model)
            }
            if showingFind {
                findBar
            }
            ScrollViewReader { proxy in
                ScrollView {
                    HStack(alignment: .top, spacing: 0) {
                        Spacer(minLength: 16)
                        LazyVStack(alignment: .leading, spacing: 16) {
                        if conversation.messages.isEmpty && !model.loadingMessageHistory.contains(conversation.id) {
                            VStack(spacing: 14) {
                                PetAvatarImage(pet: .codex).frame(width: 72, height: 80)
                                Text(l10n("New Conversation")).font(.system(size: 23, weight: .semibold, design: .rounded))
                                Text(l10n("Message")).font(.system(size: 13)).foregroundStyle(FiliconTheme.textTertiary)
                            }.frame(maxWidth: .infinity).padding(.vertical, 100)
                        }
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
                                    Label(l10n("Load older messages"), systemImage: "arrow.up.circle")
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
                        .frame(maxWidth: 690)
                        Spacer(minLength: 16)
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 28)
                }
                .background(FiliconTheme.canvas)
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
            WorkspaceFolderAccessPanel(conversationID: conversation.id)
                .padding(.horizontal, 24)
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
                        Text(l10n("Replying to \(preview.label)")).font(.caption.bold())
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
                                .accessibilityLabel(l10n("Referenced workflow \(workflow.name)"))
                        }
                    }.padding(.horizontal)
                }.scrollIndicators(.hidden)
            }
            if WorkflowComposerReferences.query(in: model.draft) != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n("Reference a skill")).font(.caption.bold()).foregroundStyle(.secondary)
                    if workflowSuggestions.isEmpty {
                        Text(l10n("No matching enabled manual workflows"))
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
            HStack(alignment: .bottom, spacing: 8) {
                FiliconIconButton(label: l10n("Attach"), systemName: "paperclip", size: 32) { showingImporter = true }
                    .disabled(model.isImportingAttachments || !model.selectedModelSupportsAttachments)
                    .help(model.selectedModelAttachmentError ?? l10n("Attach a file"))
                FiliconIconButton(label: l10n("Paste files"), systemName: "doc.on.clipboard", size: 32) { model.pasteAttachments() }
                    .disabled(!model.selectedModelSupportsAttachments)
                    .help(model.selectedModelAttachmentError ?? l10n("Paste a file or image"))
                TextField(l10n("Message"), text: $model.draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(FiliconTheme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .frame(minHeight: 34, maxHeight: 54)
                    .onSubmit { if !model.running.contains(conversation.id) { model.send() } }
                    .help(l10n("Type / after a space to reference an enabled workflow"))
                VoiceComposerControls(
                    controller: model.voiceComposer,
                    accept: model.acceptVoiceResult,
                    supportsAudio: model.selectedModelSupportsAudio,
                    unsupportedAudioHelp: model.selectedModelAudioError
                )
                if model.running.contains(conversation.id) {
                    FiliconIconButton(label: l10n("Stop"), systemName: "stop.fill", size: 32, isDestructive: true, action: model.cancel)
                } else {
                    FiliconIconButton(
                        label: l10n("Send"),
                        systemName: "arrow.up",
                        size: 32,
                        isProminent: true,
                        action: model.send
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(
                        model.selectedConversationConfigurationError != nil
                            || (model.selectedModelAttachmentError != nil && !model.pendingAttachments.isEmpty)
                    )
                    .help(
                        model.selectedConversationConfigurationError
                            ?? (model.pendingAttachments.isEmpty ? l10n("Send message") : model.selectedModelAttachmentError ?? l10n("Send message"))
                    )
                }
            }
            .padding(9)
            .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(FiliconTheme.borderStrong, lineWidth: 0.8))
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 17)
            .background(FiliconTheme.canvas)
            .disabled(!model.isBootstrapped)
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
            TextField(l10n("Find in this chat"), text: Binding(
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
                Label(l10n("Previous match"), systemImage: "chevron.up")
            }
            .labelStyle(.iconOnly)
            .disabled(transcript.matchIDs.isEmpty)
            Button { _ = transcript.selectNext(messages: conversation.messages) } label: {
                Label(l10n("Next match"), systemImage: "chevron.down")
            }
            .labelStyle(.iconOnly)
            .disabled(transcript.matchIDs.isEmpty)
            Button(action: closeFind) { Label(l10n("Close Find"), systemImage: "xmark") }
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
    @Environment(\.locale) private var uiLocale
    @ObservedObject var controller: VoiceComposerController
    let accept: () -> Void
    let supportsAudio: Bool
    let unsupportedAudioHelp: String?

    var body: some View {
        let _ = uiLocale.identifier
        switch controller.phase {
        case .idle:
            FiliconIconButton(label: l10n("Record voice message"), systemName: "mic", size: 32, action: controller.startRecording)
            .disabled(!supportsAudio)
            .help(unsupportedAudioHelp ?? l10n("Record voice message"))
        case .requestingMicrophonePermission:
            ProgressView().controlSize(.small).help(l10n("Requesting microphone access…"))
            Button(l10n("Cancel"), action: controller.cancel).controlSize(.small)
        case .recording(let elapsed):
            WaveformStrip(samples: controller.waveformSamples)
                .frame(width: 92, height: 25)
                .accessibilityLabel(l10n("Live microphone level"))
            Text(elapsed.formattedVoiceDuration).font(.system(.caption, design: .monospaced))
            Button(action: controller.stopAndTranscribe) {
                Label(l10n("Stop and transcribe"), systemImage: "stop.circle.fill")
            }.labelStyle(.iconOnly).foregroundStyle(.red).help(l10n("Stop and transcribe"))
            Button(action: controller.cancel) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help(l10n("Cancel recording"))
        case .transcribing:
            ProgressView().controlSize(.small)
            Text(l10n("Transcribing…")).font(.caption).foregroundStyle(.secondary)
            Button(l10n("Cancel"), action: controller.cancel).controlSize(.small)
        case .ready:
            WaveformStrip(samples: controller.waveformSamples).frame(width: 70, height: 22)
            Button(l10n("Use Recording"), action: accept).controlSize(.small)
            Button(action: controller.retry) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help(l10n("Record again"))
            Button(action: controller.cancel) { Image(systemName: "trash") }
                .buttonStyle(.plain).help(l10n("Discard recording"))
        case .permissionDenied:
            Label(l10n("Microphone access denied"), systemImage: "mic.slash").font(.caption).foregroundStyle(.red)
            Button(l10n("Settings")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }.controlSize(.small)
            Button(l10n("Retry"), action: controller.retry).controlSize(.small)
        case .tooShort(let minimum):
            Text(l10n("Recording must be at least \(minimum, specifier: "%.1f")s")).font(.caption).foregroundStyle(.orange)
            Button(l10n("Retry"), action: controller.retry).controlSize(.small)
            Button(l10n("Cancel"), action: controller.cancel).controlSize(.small)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help(message)
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
            Button(l10n("Retry"), action: controller.retry).controlSize(.small)
            Button(l10n("Cancel"), action: controller.cancel).controlSize(.small)
        }
    }
}

private struct WaveformStrip: View {
    @Environment(\.locale) private var uiLocale
    let samples: [Float]
    var body: some View {
        let _ = uiLocale.identifier
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
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let message: ChatMessage
    let conversation: Conversation
    var isFindMatch = false
    var isActiveFindMatch = false
    var isReplyJumpTarget = false
    let onJumpToMessage: (UUID) -> Void
    @State private var isHovered = false

    var body: some View {
        let _ = uiLocale.identifier
        let isUser = message.role == .user
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 50) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
                messageBubble
                if !message.reactions.isEmpty {
                    HStack(spacing: 5) {
                        ForEach(groupedReactions, id: \.emoji) { group in
                            Button("\(group.emoji) \(group.count)") {
                                model.toggleReaction(messageID: message.id, emoji: group.emoji)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
                messageActions
            }
            if !isUser { Spacer(minLength: 50) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var messageBubble: some View {
        messageBubbleContent.frame(maxWidth: 520, alignment: message.role == .user ? .trailing : .leading)
    }

    private var messageBubbleContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let replyID = message.replyToMessageID {
                let preview = ReplyPreviewPresentation.make(for: conversation.messages.first(where: { $0.id == replyID }))
                Button { onJumpToMessage(replyID) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: preview.symbolName).foregroundStyle(FiliconTheme.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preview.label).font(.caption2.bold()).foregroundStyle(FiliconTheme.textSecondary)
                            Text(preview.detail).lineLimit(1).font(.caption).foregroundStyle(FiliconTheme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left").font(.caption2).foregroundStyle(FiliconTheme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(l10n("Jump to replied message"))
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FiliconTheme.surfaceRaised.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            }
            if !message.reasoningText.isEmpty {
                DisclosureGroup(l10n("Reasoning")) {
                    MarkdownText(source: message.reasoningText)
                        .foregroundStyle(FiliconTheme.textSecondary)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
            if !message.text.isEmpty {
                if message.role == .user {
                    Text(message.text).textSelection(.enabled)
                        .foregroundStyle(FiliconTheme.userBubbleText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    MarkdownText(source: message.text).foregroundStyle(FiliconTheme.textPrimary)
                }
            } else if message.reasoningText.isEmpty && message.toolActivities.isEmpty && message.transcriptCards.isEmpty {
                Text(message.deliveryStatus == .failed ? l10n("No response was delivered.") : "…")
                    .foregroundStyle(FiliconTheme.textSecondary)
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
                }
                .scrollIndicators(.hidden)
            }
            if message.deliveryStatus != .succeeded {
                HStack(spacing: 5) {
                    Label(statusLabel, systemImage: statusIcon)
                    Text(message.createdAt, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(statusColor)
            }
            if let error = message.deliveryError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(message.role == .user ? FiliconTheme.userBubble : FiliconTheme.incomingBubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            if isReplyJumpTarget {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(FiliconTheme.accent, lineWidth: 3)
            } else if isFindMatch {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isActiveFindMatch ? Color.orange : Color.orange.opacity(0.35), lineWidth: isActiveFindMatch ? 3 : 1)
            }
        }
    }

    private var messageActions: some View {
        HStack(spacing: 3) {
            FiliconIconButton(label: l10n("Reply"), systemName: "arrowshape.turn.up.left", size: 25) { model.beginReply(to: message.id) }
            FiliconIconButton(label: l10n("Copy Message"), systemName: "doc.on.doc", size: 25) {
                TranscriptPasteboard.copy(TranscriptClipboardContent.messageText(message))
            }
            Menu {
                ForEach(["👍", "❤️", "😂", "🎉", "👀"], id: \.self) { emoji in
                    Button(emoji) { model.toggleReaction(messageID: message.id, emoji: emoji) }
                }
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FiliconTheme.textTertiary)
                    .frame(width: 25, height: 25)
            }
            .menuStyle(.borderlessButton)
            if message.role == .assistant && [.failed, .cancelled].contains(message.deliveryStatus) {
                FiliconIconButton(label: l10n("Resend"), systemName: "arrow.clockwise", size: 25) { model.resend(messageID: message.id) }
            }
            Spacer(minLength: 3)
            FiliconIconButton(label: l10n("Delete"), systemName: "trash", size: 25, isDestructive: true) { model.deleteMessage(id: message.id) }
        }
        .opacity(isHovered || message.deliveryStatus != .succeeded ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement(children: .contain)
    }

    private var roleLabel: String { FiliconLocalization.string(message.role == .user ? "You" : message.role == .assistant ? "Assistant" : message.role.rawValue.capitalized) }
    private var statusLabel: String { FiliconLocalization.string(message.deliveryStatus.rawValue.capitalized) }
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
    @Environment(\.locale) private var uiLocale
    let source: String
    var body: some View {
        let _ = uiLocale.identifier
        RichMarkdownView.transcript(source: source, openLink: TranscriptSafeLinkOpener.open)
    }
}

private struct ToolActivityRow: View {
    @Environment(\.locale) private var uiLocale
    let activity: ToolActivity
    private var presentation: ToolCardPresentation { ToolCardClassifier.presentation(for: activity) }
    var body: some View {
        let _ = uiLocale.identifier
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
                    Text(l10n("Arguments")).font(.caption.bold())
                    Text(presentation.redactedArguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                if let result = presentation.redactedResult, !result.isEmpty {
                    Text(l10n("Result")).font(.caption.bold())
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
    @Environment(\.locale) private var uiLocale
    let language: String?
    let source: String
    @State private var copied = false

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : l10n("Code"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    TranscriptPasteboard.copy(source)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Label(copied ? l10n("Copied") : l10n("Copy Code"), systemImage: copied ? "checkmark" : "doc.on.doc")
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
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let attachment: AttachmentMetadata
    var body: some View {
        let _ = uiLocale.identifier
        Button { model.openAttachment(attachment) } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.filename).lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(l10n("Preview attachment"))
    }
    private var icon: String { switch attachment.kind { case .image: "photo"; case .video: "film"; case .audio: "waveform"; case .document: "doc"; case .other: "paperclip" } }
}

private struct SearchWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n("Search")).font(.title2.bold())
            Picker(l10n("Search scope"), selection: $model.globalSearchTab) {
                ForEach(GlobalSearchTab.allCases) { tab in Text(FiliconLocalization.string(tab.rawValue)).tag(tab) }
            }
            .pickerStyle(.segmented)
            HStack {
                TextField(searchPlaceholder, text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFieldFocused)
                    .onSubmit(model.search)
                    .accessibilityIdentifier("global-search-field")
                Button(l10n("Search"), action: model.search)
            }
            searchContent
        }
        .padding()
        .navigationTitle(l10n("Search"))
        .task(id: model.globalSearchFocusRequestID) {
            await Task.yield()
            searchFieldFocused = true
        }
    }

    private var searchPlaceholder: String {
        switch model.globalSearchTab {
        case .conversations: l10n("Conversation title or text")
        case .messages: l10n("Words in messages")
        case .files: l10n("File name or type (leave empty for recent)")
        }
    }

    @ViewBuilder private var searchContent: some View {
        switch model.globalSearchState {
        case .idle:
            ContentUnavailableView(
                model.globalSearchTab == .files ? l10n("Recent files") : l10n("Start searching"),
                systemImage: "magnifyingglass",
                description: Text(model.globalSearchTab == .files ? l10n("Recent attachments appear automatically.") : l10n("Enter a search above."))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { if model.globalSearchTab == .files { await model.performGlobalSearch() } }
        case .loading:
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView.search(text: model.searchQuery)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            searchUnavailable(title: l10n("Search failed"), message: message, symbol: "exclamationmark.triangle")
        case .unavailable(let message):
            searchUnavailable(title: l10n("Search unavailable"), message: message, symbol: "externaldrive.badge.exclamationmark")
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
                        Text(hit.role == .user ? l10n("You") : FiliconLocalization.string(hit.role.rawValue.capitalized))
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
            Button(l10n("Try Again")) { model.search() }
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
    @Environment(\.locale) private var uiLocale
    var body: some View {
        let _ = uiLocale.identifier
        AgentsWorkspaceScreen()
    }
}


struct RoutineAutomationWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var agentID: UUID?
    @State private var name = ""
    @State private var prompt = ""
    @State private var listeners = [AutomationListenerDraft()]
    var body: some View {
        let _ = uiLocale.identifier
        Form {
            Section(l10n("New routine")) {
                Picker(l10n("Agent"), selection: $agentID) { Text(l10n("Choose…")).tag(nil as UUID?); ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) } }
                TextField(l10n("Name"), text: $name); TextField(l10n("Instruction"), text: $prompt, axis: .vertical).lineLimit(2...5)
                ForEach($listeners) { $listener in
                    AutomationListenerEditor(listener: $listener, canRemove: listeners.count > 1) {
                        listeners.removeAll { $0.id == listener.id }
                    }
                }
                HStack {
                    Button(l10n("Add listener")) { listeners.append(AutomationListenerDraft()) }
                        .disabled(listeners.count >= AutomationService.maximumListeners)
                    Text("\(listeners.count)/\(AutomationService.maximumListeners)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(l10n("Create"), action: create)
                        .disabled(agentID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || listeners.contains { $0.validationMessage != nil })
                }
                Text(l10n("Multiple listeners are OR-combined. Schedules support five-field cron, aliases, @every, and IANA time zones; connector filters must be a JSON object."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.automationWakes.isEmpty {
                Section(l10n("Pending results")) {
                    ForEach(model.automationWakes) { wake in
                        HStack {
                            Label(wake.detail.isEmpty ? FiliconLocalization.string(wake.status.rawValue.capitalized) : FiliconLocalization.message(wake.detail), systemImage: wake.status == .ok ? "checkmark.circle" : "exclamationmark.circle")
                                .lineLimit(2)
                            Spacer()
                            Text(wake.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                            Button(l10n("Acknowledge")) { Task { await model.acknowledgeAutomationWake(id: wake.id) } }
                        }
                    }
                }
            }
            if model.automationSpendGuard.nudgedAt != nil || !model.automationSpendGuard.guardPausedAutomationIDs.isEmpty {
                Section(l10n("Automation activity check")) {
                    Text(model.automationSpendGuard.guardPausedAutomationIDs.isEmpty
                         ? l10n("Automations have continued while you were away. Keep them running or pause them.")
                         : l10n("Automations were paused after prolonged unviewed activity."))
                    HStack {
                        if model.automationSpendGuard.guardPausedAutomationIDs.isEmpty {
                            Button(l10n("Keep running")) { Task { await model.answerAutomationSpendGuard(.keep) } }
                            Button(l10n("Pause"), role: .destructive) { Task { await model.answerAutomationSpendGuard(.pause) } }
                            Button(l10n("Never ask")) { Task { await model.answerAutomationSpendGuard(.neverAsk) } }
                        } else {
                            Button(l10n("Resume")) { Task { await model.answerAutomationSpendGuard(.resume) } }
                            Button(l10n("Stay paused")) { Task { await model.answerAutomationSpendGuard(.stayPaused) } }
                        }
                    }
                }
            }
            AutomationIngressSettingsView()
            Section(l10n("Routines")) {
                ForEach(model.automations) { automation in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(automation.prompt).textSelection(.enabled)
                            if let runs = model.automationHistory[automation.id], !runs.isEmpty {
                                Text(l10n("Recent runs")).font(.caption.bold())
                                ForEach(runs) { run in
                                    HStack(alignment: .top) {
                                        Label(FiliconLocalization.string(run.status.rawValue.capitalized), systemImage: run.status == .ok ? "checkmark.circle" : "exclamationmark.circle")
                                        Text(FiliconLocalization.string(run.trigger.rawValue.capitalized)).foregroundStyle(.secondary)
                                        Text(run.startedAt, style: .relative).foregroundStyle(.secondary)
                                        Spacer()
                                        Text(run.detail ?? "").lineLimit(2).foregroundStyle(.secondary)
                                    }.font(.caption)
                                }
                            } else {
                                Text(l10n("No runs yet")).font(.caption).foregroundStyle(.secondary)
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
                            Toggle(l10n("Enabled"), isOn: Binding(get: { automation.enabled }, set: { value in Task { await model.setAutomationEnabled(id: automation.id, enabled: value) } })).labelsHidden()
                            Button(l10n("Run Now")) { Task { await model.runAutomationNow(id: automation.id) } }
                            Button(l10n("Delete"), role: .destructive) { Task { await model.deleteAutomation(id: automation.id) } }
                        }
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle(l10n("Automations"))
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
        case .event(let value): l10n("\(value.kind) connector event")
        case .platform(let value): value.platform
        case .anyOf(let values): l10n("\(values.count) listeners")
        case .unknown(let kind, _): l10n("Unavailable: \(kind)")
        }
    }
}

struct TeamsRoutineAvailabilityNotice: View {
    @Environment(\.locale) private var uiLocale
    nonisolated static let message = "Teams native ingress supports only outgoing channel messages with an explicit text filter. Graph team UUIDs require aadGroupId; Bot team IDs are separate. Signed-in-user matching and root-post classification are unavailable. This editor keeps blockUnauthenticatedUsers enabled, so Teams event conditions do not run. No account, Graph subscription or webhook is installed."

    var body: some View {
        Text(FiliconLocalization.string(Self.message, language: uiLocale.identifier))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

enum AutomationListenerKind: String, CaseIterable, Identifiable {
    case schedule = "Schedule"
    case connector = "Connector event"
    case slack = "Slack"
    case github = "GitHub"
    case teams = "Microsoft Teams"
    case linear = "Linear"
    case sentry = "Sentry"
    case pagerDuty = "PagerDuty"
    var id: String { rawValue }

    func label(language: String) -> String {
        switch self {
        case .schedule, .connector: FiliconLocalization.string(rawValue, language: language)
        default: rawValue // Platform names are brands, e.g. Linear, not "linear" geometry.
        }
    }

    var events: [AutomationListenerEvent] {
        switch self {
        case .linear: [.issueCreated, .statusChanged, .endOfCycle]
        case .sentry: [.issueCreated, .issueResolved, .issueAssigned, .issueArchived, .issueUnresolved, .issueAny]
        case .pagerDuty: [.incidentTriggered, .incidentAcknowledged, .incidentResolved, .incidentEscalated, .incidentAny]
        default: []
        }
    }
}

enum AutomationListenerEvent: String, CaseIterable, Identifiable {
    case issueCreated, statusChanged, endOfCycle
    case issueResolved, issueAssigned, issueArchived, issueUnresolved, issueAny
    case incidentTriggered, incidentAcknowledged, incidentResolved, incidentEscalated, incidentAny
    var id: String { rawValue }
    var label: String {
        switch self {
        case .issueCreated: "Issue created"
        case .statusChanged: "Issue status changed"
        case .endOfCycle: "Cycle completed"
        case .issueResolved: "Issue resolved"
        case .issueAssigned: "Issue assigned"
        case .issueArchived: "Issue archived"
        case .issueUnresolved: "Issue reopened"
        case .issueAny: "Any supported issue event"
        case .incidentTriggered: "Incident triggered"
        case .incidentAcknowledged: "Incident acknowledged"
        case .incidentResolved: "Incident resolved"
        case .incidentEscalated: "Incident escalated"
        case .incidentAny: "Any supported incident event"
        }
    }
}

struct AutomationListenerDraft: Identifiable, Equatable {
    var id = UUID()
    var kind: AutomationListenerKind = .schedule
    var primary = "@daily"
    var secondary = ""
    var tertiary = ""
    var quaternary = ""
    var filtersJSON = "{}"
    var statusIDs = ""
    var cycleIDs = ""

    static func defaults(for kind: AutomationListenerKind, id: UUID) -> Self {
        var value = Self(id: id, kind: kind)
        switch kind {
        case .schedule: value.primary = "@daily"
        case .connector, .teams: value.primary = ""
        case .slack: value.primary = "*"; value.secondary = "mention"
        case .github: value.primary = ""; value.secondary = "pr-opened,pr-pushed"
        case .linear, .sentry: value.primary = "issueCreated"
        case .pagerDuty: value.primary = "incidentTriggered"
        }
        return value
    }

    var validationMessage: String? {
        guard !kind.events.isEmpty else { return nil }
        do { _ = try trigger; return nil }
        catch { return error.localizedDescription }
    }

    // Validate the raw list before deduplication. Empty comma segments must not
    // quietly erase a restriction, and duplicate IDs still count toward 50.
    private func ids(_ text: String, error: AutomationStateChangeError,
                     normalize: (String) -> String?) throws -> Set<String> {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count <= 50 else { throw error }
        return try Set(parts.map { part in
            let token = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = normalize(token) else { throw error }
            return value
        })
    }

    private func linearIDs(_ text: String) throws -> Set<String> {
        try ids(text, error: .invalidLinearTrigger) { token in
            guard token.count == 36, let id = UUID(uuidString: token) else { return nil }
            return id.uuidString.lowercased()
        }
    }

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
            case .linear:
                guard kind.events.contains(where: { $0.rawValue == primary }) else {
                    throw AutomationStateChangeError.invalidLinearTrigger
                }
                let value = try LinearAutomationTrigger(event: primary, allowedEvents: Set(kind.events.map(\.rawValue)),
                    primaryIDs: linearIDs(secondary), secondaryIDs: linearIDs(tertiary),
                    statusIDs: linearIDs(statusIDs), cycleIDs: linearIDs(cycleIDs))
                try value.validateForAgentWrite()
                return .platform(.linear(value))
            case .sentry, .pagerDuty:
                let error: AutomationStateChangeError = kind == .sentry ? .invalidSentryTrigger : .invalidPagerDutyTrigger
                guard kind.events.contains(where: { $0.rawValue == primary }),
                      [tertiary, statusIDs, cycleIDs].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw error
                }
                let values = try ids(secondary, error: error) { token in
                    let valid = kind == .sentry ? CaseAutomationTrigger.isSentryProjectID(token) : CaseAutomationTrigger.isPagerDutyServiceID(token)
                    return valid ? token : nil
                }
                let value = try CaseAutomationTrigger(event: primary, allowedEvents: Set(kind.events.map(\.rawValue)), primaryIDs: values)
                if kind == .sentry {
                    try value.validateForSentryAgentWrite()
                    return .platform(.sentry(value))
                }
                try value.validateForPagerDutyAgentWrite()
                return .platform(.pagerDuty(value))
            }
        }
    }
}

struct AutomationListenerEditor: View {
    @Environment(\.locale) private var uiLocale
    @Binding var listener: AutomationListenerDraft
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        let _ = uiLocale.identifier
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(FiliconLocalization.string("Trigger", language: uiLocale.identifier), selection: $listener.kind) {
                        ForEach(AutomationListenerKind.allCases) { Text($0.label(language: uiLocale.identifier)).tag($0) }
                    }
                    if canRemove { Button(FiliconLocalization.string("Remove", language: uiLocale.identifier), role: .destructive, action: remove) }
                }
                fields
                if let message = listener.validationMessage {
                    Text(FiliconLocalization.string(message, language: uiLocale.identifier))
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(4)
        }
        .onChange(of: listener.kind) { _, kind in changeKind(kind) }
    }

    @ViewBuilder private var fields: some View {
        switch listener.kind {
        case .schedule:
            TextField(l10n("Cron, alias, or @every 30m"), text: $listener.primary)
            Picker(l10n("Time zone"), selection: $listener.secondary) {
                Text(l10n("System (\(TimeZone.current.identifier))")).tag("")
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
        case .connector:
            TextField(l10n("Connector UUID"), text: $listener.primary)
            TextField(l10n("Event kind"), text: $listener.secondary)
            TextField(l10n("JSON filters"), text: $listener.filtersJSON, axis: .vertical).font(.system(.body, design: .monospaced))
        case .slack:
            TextField(l10n("Channel name or *"), text: $listener.primary)
            Picker(l10n("Match"), selection: $listener.secondary) {
                Text(l10n("Message")).tag("message"); Text(l10n("Mention")).tag("mention"); Text(l10n("Keyword")).tag("keyword"); Text(l10n("Reaction")).tag("reaction")
            }
            if ["keyword", "reaction"].contains(listener.secondary) { TextField(listener.secondary == "keyword" ? l10n("Keyword") : l10n("Emoji names, comma-separated"), text: $listener.tertiary) }
        case .github:
            TextField(l10n("owner/repository"), text: $listener.primary)
            TextField(l10n("Events, comma-separated"), text: $listener.secondary)
            TextField(l10n("CI branch (required for CI events)"), text: $listener.tertiary)
            TextField(l10n("Allowed users, comma-separated (optional)"), text: $listener.quaternary)
        case .teams:
            TextField(l10n("Tenant ID"), text: $listener.primary)
            TextField(l10n("Team IDs, comma-separated"), text: $listener.secondary)
            TextField(l10n("Channel IDs, comma-separated (optional)"), text: $listener.tertiary)
            TextField(l10n("Message contains (required)"), text: $listener.quaternary)
            TeamsRoutineAvailabilityNotice()
        case .linear, .sentry, .pagerDuty:
            Picker(FiliconLocalization.string("Event", language: uiLocale.identifier), selection: $listener.primary) {
                ForEach(listener.kind.events) { event in
                    Text(FiliconLocalization.string(event.label, language: uiLocale.identifier)).tag(event.rawValue)
                }
            }
            if listener.kind == .linear {
                idField("Team UUIDs", text: $listener.secondary)
                if listener.primary != "endOfCycle" || !listener.tertiary.isEmpty {
                    idField("Project UUIDs", text: $listener.tertiary)
                }
                if listener.primary == "statusChanged" || !listener.statusIDs.isEmpty {
                    idField("New status UUIDs", text: $listener.statusIDs)
                }
                if listener.primary == "endOfCycle" || !listener.cycleIDs.isEmpty {
                    idField("Cycle UUIDs", text: $listener.cycleIDs)
                }
                notice(Self.linearNotice)
            } else {
                idField(listener.kind == .sentry ? "Project IDs (digits only)" : "Service IDs (case-sensitive)", text: $listener.secondary)
            }
            notice(Self.filterNotice)
            notice(Self.ingressNotice)
        }
    }

    static let filterNotice = "Optional filters: enter up to 50 IDs per field, separated by commas. Empty means any. Use IDs, not names or wildcards."
    static let ingressNotice = "Requires an existing verified event connection. Creating a routine does not connect an account or start a webhook. Future matching events may incur model costs."
    static let linearNotice = "Status filters apply only to status changes. Cycle completion uses team/cycle IDs, not projects, and requires an explicit completion event, not just an elapsed date. Clear incompatible filters when switching events."

    private func idField(_ key: String, text: Binding<String>) -> some View {
        let label = FiliconLocalization.string(key, language: uiLocale.identifier)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).fixedSize(horizontal: false, vertical: true)
            TextField("", text: text).accessibilityLabel(label)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func notice(_ key: String) -> some View {
        Text(FiliconLocalization.string(key, language: uiLocale.identifier))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func changeKind(_ kind: AutomationListenerKind) {
        listener = AutomationListenerDraft.defaults(for: kind, id: listener.id)
    }
}

private struct ChannelWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var connectorID = "slack"
    @State private var displayName = ""
    @State private var channelIDs = ""
    @State private var token = ""
    @State private var clientID = ""
    @State private var authentication = ChannelAuthenticationChoice.botToken
    @State private var agentID: UUID?
    var body: some View {
        let _ = uiLocale.identifier
        Form {
            Section(l10n("Connect a bot")) {
                Picker(l10n("Service"), selection: $connectorID) {
                    ForEach(model.channelDescriptors) { Text($0.displayName).tag($0.id) }
                }
                TextField(l10n("Display name"), text: $displayName)
                TextField(l10n("Channel IDs, comma-separated"), text: $channelIDs)
                Picker(l10n("Authentication"), selection: $authentication) {
                    Text(l10n("Bot token")).tag(ChannelAuthenticationChoice.botToken)
                    Text(l10n("OAuth in browser")).tag(ChannelAuthenticationChoice.oauth)
                }
                if authentication == .botToken {
                    SecureField(l10n("Bot token"), text: $token)
                } else {
                    TextField(l10n("OAuth client ID"), text: $clientID)
                    Text(l10n("Filicon starts a single-use callback on 127.0.0.1, uses PKCE, and stores the resulting token only in macOS Keychain."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker(l10n("Respond as agent"), selection: $agentID) {
                    Text(l10n("Receive only")).tag(nil as UUID?)
                    ForEach(model.agents.filter { $0.archivedAt == nil }) { Text($0.name).tag(Optional($0.id)) }
                }
                Text(FiliconLocalization.string(BuiltInChannelManifests.all.first(where: { $0.id == connectorID })?.connectGuide ?? "Credentials are stored in macOS Keychain."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(model.channelOAuthInProgress ? l10n("Waiting for OAuth…") : l10n("Connect")) {
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
                Section(l10n("Needs attention")) {
                    ForEach(model.channelFailureWakes) { wake in
                        HStack {
                            Label(wake.error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                            Spacer()
                            Button(l10n("Acknowledge")) { Task { await model.acknowledgeChannelFailure(id: wake.id) } }
                        }
                    }
                }
            }
            Section(l10n("Connections")) {
                ForEach(model.channelConnections) { connection in ChannelConnectionRow(connection: connection) }
                if model.channelConnections.isEmpty { Text(l10n("No connected channels.")).foregroundStyle(.secondary) }
            }
            Section(l10n("Recent inbound")) {
                ForEach(model.channelInboundEvents.suffix(100).reversed()) { event in
                    ChannelInboundRow(event: event)
                }
                if model.channelInboundEvents.isEmpty { Text(l10n("No inbound messages yet.")).foregroundStyle(.secondary) }
            }
            Section(l10n("Delivery queue")) {
                ForEach(model.channelDeliveries.suffix(100).reversed()) { delivery in
                    HStack {
                        Text(delivery.outbound.text).lineLimit(1)
                        Spacer()
                        Text(l10n("\(FiliconLocalization.string(delivery.status.rawValue)) · attempt \(delivery.attemptCount)")).font(.caption).foregroundStyle(delivery.status == .deadLetter ? .red : .secondary)
                    }
                }
            }
        }.formStyle(.grouped).navigationTitle(l10n("Channels"))
    }
}

private enum ChannelAuthenticationChoice: String, Hashable {
    case botToken
    case oauth
}

private struct ChannelConnectionRow: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let connection: ChannelConnection
    @State private var target = ""
    @State private var thread = ""
    @State private var text = ""
    @State private var attachments: [URL] = []

    var body: some View {
        let _ = uiLocale.identifier
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(l10n("Listening to: \(connection.accountLabel)")).font(.caption).foregroundStyle(.secondary)
                        if let profile = connection.profile {
                            Text(l10n("Authorized as \(profile.displayName) · \(profile.workspaceID ?? profile.id)"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(l10n("Refresh profile")) { Task { await model.refreshChannelProfile(id: connection.id) } }
                }
                HStack {
                    TextField(l10n("Target channel ID"), text: $target)
                    TextField(l10n("Thread ID (optional)"), text: $thread)
                    TextField(l10n("Message"), text: $text)
                    Button(l10n("Send")) {
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
                    Button(l10n("Attach files…"), action: chooseAttachments)
                    if !attachments.isEmpty {
                        Text(attachments.map(\.lastPathComponent).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Button(l10n("Clear")) { attachments = [] }
                    }
                }
                if let activity = connection.lastActivityAt { Text(l10n("Last activity \(activity.formatted())")).font(.caption).foregroundStyle(.secondary) }
            }.padding(.top, 6)
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(connection.displayName)
                    Text("\(connection.connectorID) · \(connection.agentID.flatMap { id in model.agents.first(where: { $0.id == id })?.name } ?? "receive only")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(l10n("Enabled"), isOn: Binding(
                    get: { connection.enabled },
                    set: { enabled in Task { await model.setChannelConnectionEnabled(id: connection.id, enabled: enabled) } }
                )).labelsHidden()
                Button(l10n("Remove"), role: .destructive) { Task { await model.removeChannelConnection(id: connection.id) } }
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
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let event: ChannelEnvelope
    @State private var emoji = "👍"

    var body: some View {
        let _ = uiLocale.identifier
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
                TextField(l10n("Emoji"), text: $emoji).frame(width: 70)
                Button(l10n("React")) { Task { await model.setChannelReaction(event: event, emoji: emoji, removing: false) } }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(l10n("Remove")) { Task { await model.setChannelReaction(event: event, emoji: emoji, removing: true) } }
                    .disabled(emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
        }
    }
}

private struct MCPWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var identifier = ""
    @State private var name = ""
    @State private var endpoint = "https://"
    @State private var stdioIdentifier = ""
    @State private var stdioName = ""
    @State private var executable = "/usr/bin/"
    @State private var arguments = ""
    var body: some View {
        let _ = uiLocale.identifier
        Form {
            Section(l10n("Add Streamable HTTP server")) {
                TextField(l10n("Identifier"), text: $identifier); TextField(l10n("Display name"), text: $name); TextField(l10n("HTTPS endpoint"), text: $endpoint)
                HStack {
                    Button(l10n("Add")) { let values = (identifier, name, endpoint); identifier = ""; name = ""; endpoint = "https://"; Task { await model.addMCPHTTPServer(identifier: values.0, displayName: values.1, endpoint: values.2) } }
                    Button(l10n("Reconnect All")) { Task { await model.refreshMCP() } }
                }
            }
            Section(l10n("Add local stdio server")) {
                TextField(l10n("Identifier"), text: $stdioIdentifier)
                TextField(l10n("Display name"), text: $stdioName)
                TextField(l10n("Absolute executable path"), text: $executable)
                TextField(l10n("Arguments (one per line)"), text: $arguments, axis: .vertical).lineLimit(2...5)
                Button(l10n("Add Local Server")) {
                    let values = (stdioIdentifier, stdioName, executable, arguments.split(whereSeparator: \.isNewline).map(String.init))
                    stdioIdentifier = ""; stdioName = ""; executable = "/usr/bin/"; arguments = ""
                    Task { await model.addMCPStdioServer(identifier: values.0, displayName: values.1, executable: values.2, arguments: values.3) }
                }
            }
            Section(l10n("Servers")) {
                ForEach(model.mcpConfigs.filter { config in
                    !model.mcpAccountDefinitions.contains { definition in
                        definition.managedReadOnly && definition.accounts.contains { $0.serverIdentifier == config.identifier }
                    }
                }) { config in
                    MCPServerEditor(config: config)
                }
            }
            MCPAccountsView()
            Section(l10n("Discovered tools (\(model.mcpCatalog.tools.count))")) {
                ForEach(model.mcpCatalog.tools) { tool in VStack(alignment: .leading) { Text(tool.name); Text(tool.serverIdentifier).font(.caption).foregroundStyle(.secondary) } }
            }
        }.formStyle(.grouped).navigationTitle(l10n("MCP Servers"))
    }
}

private struct MCPServerEditor: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let config: MCPServerConfig
    @State private var displayName = ""
    @State private var authorization = ""

    var body: some View {
        let _ = uiLocale.identifier
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(l10n("Display name"), text: $displayName)
                    Button(l10n("Rename")) { Task { await model.renameMCPServer(id: config.id, displayName: displayName) } }
                }
                if isHTTP {
                    HStack {
                        SecureField(l10n("Authorization header value"), text: $authorization)
                        Button(l10n("Save Token")) {
                            let token = authorization; authorization = ""
                            Task { await model.saveMCPAuthorization(id: config.id, token: token) }
                        }
                    }
                    Text(l10n("The token is stored in Keychain; configuration contains only its reference."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !toolNames.isEmpty {
                    Text(l10n("Tools")).font(.caption.bold())
                    ForEach(toolNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { !config.disabledTools.contains(name) },
                            set: { enabled in Task { await model.setMCPToolEnabled(serverIdentifier: config.identifier, toolName: name, enabled: enabled) } }
                        ))
                    }
                }
                HStack {
                    Button(l10n("Reconnect")) { Task { await model.refreshMCP() } }
                    Spacer()
                    Button(l10n("Remove"), role: .destructive) { Task { await model.deleteMCPServer(id: config.id) } }
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
                Toggle(l10n("Enabled"), isOn: Binding(
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
        case .disabled: l10n("Disabled")
        case .connecting: l10n("Connecting")
        case .connected: l10n("Connected")
        case .needsAuth: l10n("Needs authentication")
        case .error(let message): message
        case nil: l10n("Not connected")
        }
    }
}

struct SettingsView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @AppStorage(FiliconLocalization.preferenceKey) private var preferredLanguage = AppLanguage.system.rawValue
    @State private var provider: ProviderID = "openai"
    @State private var apiKey = ""
    @State private var status = ""
    @State private var updateFeed = ""
    @State private var updateKey = ""
    @State private var cloudEndpoint = ""
    @State private var cloudCredentialReference = "default"
    @State private var cloudBearer = ""
    var body: some View {
        let _ = uiLocale.identifier
        Form {
            PersistenceRecoverySettingsSection()
            Section(localized("Appearance and locale")) {
                Picker(localized("Language"), selection: $preferredLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(localized(language.localizationKey)).tag(language.rawValue)
                    }
                }
                Picker(localized("Theme"), selection: Binding(
                    get: { model.settings.theme },
                    set: { value in Task { await model.setTheme(value) } }
                )) {
                    Text(localized("System")).tag(ThemePreference.system)
                    Text(localized("Light")).tag(ThemePreference.light)
                    Text(localized("Dark")).tag(ThemePreference.dark)
                }
                Picker(localized("Time zone"), selection: Binding(
                    get: { model.settings.timeZoneIdentifier ?? "" },
                    set: { value in Task { await model.setTimeZone(value.isEmpty ? nil : value) } }
                )) {
                    Text("\(localized("System")) (\(TimeZone.current.identifier))").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { identifier in
                        Text(identifier.replacingOccurrences(of: "_", with: " ")).tag(identifier)
                    }
                }
            }
            Section(localized("Conversation defaults")) {
                if let selected = model.selectedConversation {
                    Button(localized("Use current provider and model as default")) {
                        Task { await model.setDefaultModel(providerID: selected.providerID, modelID: selected.modelID) }
                    }
                }
                if let value = model.settings.defaultModel {
                    HStack {
                        Text(localized("Default"))
                        Spacer()
                        Text("\(value.providerID) / \(value.modelID)").foregroundStyle(.secondary)
                        Button(localized("Clear")) { Task { await model.clearDefaultModel() } }
                    }
                } else {
                    LabeledContent(localized("Default"), value: localized("App default"))
                }
                Picker(localized("If unavailable"), selection: Binding(
                    get: { model.settings.unavailableModelFallback },
                    set: { value in Task { await model.setUnavailableModelFallback(value) } }
                )) {
                    Text(localized("Same provider default")).tag(UnavailableModelFallbackPolicy.providerDefault)
                    Text(localized("First available provider")).tag(UnavailableModelFallbackPolicy.firstAvailable)
                    Text(localized("Do not replace")).tag(UnavailableModelFallbackPolicy.none)
                }
            }
            Section(localized("AI providers")) {
                Picker(localized("Provider"), selection: $provider) {
                    ForEach(model.descriptors.filter(\.requiresAPIKey)) { Text($0.displayName).tag($0.id) }
                }
                SecureField(localized("API key"), text: $apiKey)
                Text(localized("Keys are stored only in the macOS Keychain. Filicon never reads another app's credentials.")).font(.caption).foregroundStyle(.secondary)
                HStack { Button(localized("Save to Keychain")) { Task { do { try await model.saveAPIKey(apiKey, providerID: provider); apiKey = ""; status = localized("Saved") } catch { status = error.localizedDescription } } }; Text(status).foregroundStyle(.secondary) }
                HStack {
                    Button(localized("Refresh Current Model Catalog")) {
                        Task { await model.refreshModels(forceRefresh: true) }
                    }
                    .disabled(model.isLoadingModels || model.selectedConversation == nil)
                    .accessibilityLabel(localized("Refresh current model catalog"))
                    if model.isLoadingModels { ProgressView().controlSize(.small) }
                    Text(localized(model.modelCatalogStatusLabel)).foregroundStyle(.secondary)
                }
            }
            Section(localized("Cloud agents")) {
                TextField(localized("HTTPS endpoint"), text: $cloudEndpoint)
                TextField(localized("Keychain reference"), text: $cloudCredentialReference)
                SecureField(localized("Bearer token (leave blank to keep existing)"), text: $cloudBearer)
                Text(localized("The endpoint is persisted without credentials. Bearer tokens are stored only in macOS Keychain."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(localized("Save and Refresh")) {
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
                    Text(model.cloudAgentCatalog.isEmpty ? localized("Not loaded") : "\(model.cloudAgentCatalog.count) \(localized("available"))")
                        .foregroundStyle(.secondary)
                }
            }
            Section(localized("Notifications")) {
                HStack {
                    Text(localized("Completion notifications"))
                    Spacer()
                    Text(notificationStatusLabel).foregroundStyle(.secondary)
                    Button(localized("Enable")) {
                        Task {
                            do { try await model.systemNotifications.requestAuthorization() }
                            catch { status = error.localizedDescription }
                        }
                    }
                }
            }
            Section(localized("Local tool permissions")) {
                Text(localized("Always still creates a signed, exact-operation receipt. Ask pauses the tool call until you allow it once. Never fails closed."))
                    .font(.caption).foregroundStyle(.secondary)
                Picker(localized("Set all local tools"), selection: Binding(
                    get: { model.settings.effectiveLocalToolPermission },
                    set: { value in Task { await model.setGlobalLocalToolPermission(value) } }
                )) {
                    Text(localized("Always")).tag(LocalToolPermission.always)
                    Text(localized("Ask")).tag(LocalToolPermission.ask)
                    Text(localized("Never")).tag(LocalToolPermission.never)
                }
                ForEach(LocalToolAction.allCases, id: \.self) { action in
                    Picker(localToolActionLabel(action), selection: Binding(
                        get: { model.localToolPermissions[action] ?? .ask },
                        set: { value in Task { await model.setLocalToolPermission(value, for: action) } }
                    )) {
                        Text(localized("Always")).tag(LocalToolPermission.always)
                        Text(localized("Ask")).tag(LocalToolPermission.ask)
                        Text(localized("Never")).tag(LocalToolPermission.never)
                    }
                }
            }
            Section(localized("Security Key")) {
                Toggle(localized("Use hardware security keys"), isOn: Binding(
                    get: { model.securityKeyEnabled && model.securityKeySupported },
                    set: { value in Task { await model.setSecurityKeyEnabled(value) } }
                ))
                .disabled(!model.securityKeySupported)
                Text(localized(model.securityKeySupported
                     ? l10n("Allow a remote Filicon computer to use a hardware security key connected to this Mac. Every request shows its origin and relying-party ID for one-time approval.")
                     : l10n("External hardware security keys require macOS 14.4 or later.")))
                    .font(.caption).foregroundStyle(.secondary)
                Text(securityKeyStatusLabel).font(.caption).foregroundStyle(.secondary)
                Text(localized("Bearer credentials remain in macOS Keychain. Authentication Services owns any PIN or biometric prompt; Filicon never collects a PIN and never falls back to a platform passkey."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            AutoReviewSettingsView()
            Section(localized("Authorized workspace folders")) {
                Text(localized("Local file and process tools can use only these exact folders. Access is stored as macOS security-scoped bookmarks."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.workspaceAuthorizations) { authorization in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(authorization.displayName)
                            Text(authorization.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button(localized("Remove"), role: .destructive) {
                            Task { await model.removeWorkspaceAuthorization(id: authorization.id) }
                        }
                    }
                }
                Button(localized("Authorize Folder…"), action: model.authorizeWorkspaceFolder)
            }
            Section(localized("Updates")) {
                Picker(localized("Release track"), selection: Binding(
                    get: { model.settings.updatePolicy.effectiveTrack },
                    set: { value in Task { await model.setUpdateTrack(value) } }
                )) {
                    ForEach(model.settings.updatePolicy.enabledTracks.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { track in
                        Text(localized(track.rawValue.capitalized)).tag(track)
                    }
                }
                Toggle(localized("Install downloaded updates when idle"), isOn: Binding(
                    get: { model.settings.updatePolicy.installWhenIdle },
                    set: { value in Task { await model.setInstallUpdatesWhenIdle(value) } }
                ))
                Text(localized("Updates are accepted only from HTTPS feeds and verified with the release signing key before installation."))
                    .font(.caption).foregroundStyle(.secondary)
                TextField(localized("HTTPS feed URL"), text: $updateFeed)
                SecureField(localized("Ed25519 public key (Base64)"), text: $updateKey)
                HStack {
                    Button(localized("Save Update Source")) { let values = (updateFeed, updateKey); Task { await model.configureUpdates(feedURL: values.0, publicKeyBase64: values.1) } }
                    Button(localized("Check Now")) { Task { await model.checkForUpdates() } }
                        .disabled(model.updateFeedURLString.isEmpty)
                    if case .available = model.updateState {
                        Button(localized("Download")) { Task { await model.downloadAvailableUpdate() } }
                    }
                    if case .staged = model.updateState {
                        Button(localized("Install and Relaunch")) { Task { await model.installStagedUpdate() } }
                    }
                }
                Label(updateStatusLabel, systemImage: updateStatusIcon)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(localized("Usage")) {
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
                LabeledContent(localized("Requests"), value: total.requests.formatted())
                LabeledContent(localized("Input tokens"), value: total.inputTokens.formatted())
                LabeledContent(localized("Output tokens"), value: total.outputTokens.formatted())
                if model.settings.usageByAccount.isEmpty {
                    Text(localized("No provider usage has been recorded on this Mac."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.settings.usageByAccount.keys.sorted(), id: \.self) { accountID in
                    if let account = model.settings.usageByAccount[accountID] {
                        DisclosureGroup(accountID) {
                            ForEach(account.providers.keys.sorted(), id: \.self) { providerID in
                                if let usage = account.providers[providerID] {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(providerID).font(.caption.bold()).textSelection(.enabled)
                                        Text(l10n("\(usage.requests.formatted()) requests · \(usage.inputTokens.formatted()) input · \(usage.outputTokens.formatted()) output"))
                                            .font(.caption).foregroundStyle(.secondary)
                                        if usage.cacheReadTokens > 0 || usage.cacheWriteTokens > 0 {
                                            Text(l10n("Cache: \(usage.cacheReadTokens.formatted()) read · \(usage.cacheWriteTokens.formatted()) write"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if usage.costMicros > 0 {
                                            Text(l10n("Recorded cost: \(Double(usage.costMicros) / 1_000_000, format: .currency(code: Locale.current.currency?.identifier ?? "USD"))"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                Button(localized("Reset usage"), role: .destructive) { Task { await model.resetUsage() } }
            }
        }
            .formStyle(.grouped)
            .background(WindowTitleAccessor(title: l10n("Filicon \(localized("Settings"))")).frame(width: 0, height: 0))
            .task {
                await model.systemNotifications.refreshAuthorization()
                await model.reloadLocalToolSettings()
                updateFeed = model.updateFeedURLString
                updateKey = model.updatePublicKeyBase64
                cloudEndpoint = model.cloudAgentEndpoint
                cloudCredentialReference = model.cloudAgentCredentialReference
            }
    }

    private func localized(_ key: String) -> String {
        FiliconLocalization.string(key)
    }

    private var notificationStatusLabel: String {
        switch model.systemNotifications.authorizationStatus {
        case .authorized: localized("Enabled")
        case .denied: localized("Denied in System Settings")
        case .provisional: localized("Provisional")
        case .ephemeral: localized("Temporary")
        case .notDetermined: localized("Not enabled")
        @unknown default: localized("Unknown")
        }
    }

    private var securityKeyStatusLabel: String {
        switch model.securityKeyStatus {
        case .disabled: localized("Disabled")
        case .disconnected: localized("Disconnected")
        case .reconnecting(let attempt): "\(localized("Reconnecting")) (\(localized("attempt")) \(attempt))"
        case .connected: localized("Connected")
        case .awaitingConsent(let origin, let rpID): "\(localized("Awaiting approval for")) \(origin) (\(rpID))"
        case .waitingForSystemPIN: localized("Follow the macOS PIN or verification prompt")
        case .waitingForPresence: localized("Touch your hardware security key")
        case .completed: localized("Last request completed")
        case .failed(let message): message
        }
    }

    private var updateStatusLabel: String {
        switch model.updateState {
        case .idle: localized("Update checks are idle")
        case .checking: localized("Checking for updates…")
        case .upToDate(let date): "\(localized("Up to date")) · \(localized("checked")) \(date.formatted(date: .omitted, time: .shortened))"
        case .available(let release): "\(localized("Version")) \(release.version) (\(release.build)) \(localized("is available"))"
        case .downloading(let release): "\(localized("Downloading")) \(release.version)…"
        case .staged(let update, _): "\(localized("Version")) \(update.release.version) \(localized("is verified and ready"))"
        case .installing(let update): "\(localized("Installing version")) \(update.release.version)…"
        case .failed(let message): "\(localized("Update failed")): \(message)"
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
        case .runCommand: localized("Run and manage processes")
        case .sendInput: localized("Send process input")
        case .readFile: localized("Read files")
        case .listDirectory: localized("List directories")
        case .writeFile: localized("Write files")
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
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let request: ToolApprovalRequest

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 18) {
            Label(l10n("Allow this local action?"), systemImage: "exclamationmark.shield")
                .font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text(l10n("Action")).foregroundStyle(.secondary)
                    Text(actionLabel).fontWeight(.semibold)
                }
                GridRow {
                    Text(l10n("Target")).foregroundStyle(.secondary)
                    Text(request.title).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                GridRow {
                    Text(l10n("Reason")).foregroundStyle(.secondary)
                    Text(request.reason).textSelection(.enabled)
                }
            }
            Text(l10n("Allow Once is bound to this exact tool call. Persistent choices apply to this action for every agent and can be changed in Settings."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l10n("Deny")) { model.resolveLocalToolApproval(id: request.id, allowed: false) }
                    .keyboardShortcut(.cancelAction)
                Button(l10n("Never")) { model.persistLocalToolApproval(request, permission: .never) }
                Spacer()
                Button(l10n("Always Allow")) { model.persistLocalToolApproval(request, permission: .always) }
                    .disabled(!model.canPersistAlwaysLocalToolApproval())
                    .help(model.canPersistAlwaysLocalToolApproval()
                          ? l10n("Always allow this local action")
                          : l10n("Managed policy does not allow a persistent Always choice"))
                Button(l10n("Allow Once")) { model.resolveLocalToolApproval(id: request.id, allowed: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 540)
    }

    private var actionLabel: String {
        switch request.action {
        case .runCommand: l10n("Run or manage process")
        case .sendInput: l10n("Send process input")
        case .readFile: l10n("Read file")
        case .listDirectory: l10n("List directory")
        case .writeFile: l10n("Write file")
        }
    }
}
