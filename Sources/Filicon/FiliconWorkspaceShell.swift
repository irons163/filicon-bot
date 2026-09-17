import SwiftUI
import FiliconDomain
import FiliconAgents

enum ConversationLayout {
    static func sidebarWidth(for width: CGFloat) -> CGFloat { width < 1_050 ? 224 : 260 }
    static func showsInlineInspector(detailWidth: CGFloat) -> Bool { detailWidth >= 780 }
    static let inspectorWidth: CGFloat = 280
}

struct FiliconWorkspaceShell<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var showingNewGroup = false
    @ViewBuilder var content: Content

    var body: some View {
        let _ = locale.identifier
        GeometryReader { geometry in
            HStack(spacing: 0) {
                FiliconSidebar(onNewGroup: { showingNewGroup = true })
                    .frame(width: ConversationLayout.sidebarWidth(for: geometry.size.width))
                Rectangle().fill(FiliconTheme.border.opacity(0.5)).frame(width: 1)
                VStack(spacing: 0) {
                    if let title = workspaceTitle {
                        HStack {
                            Text(title).font(.system(size: 14, weight: .semibold))
                            Spacer()
                            FiliconIconButton(label: l10n("Back"), systemName: "arrow.left", action: returnToChat)
                        }
                        .padding(.horizontal, 24).frame(height: 54)
                        .overlay(alignment: .bottom) { Rectangle().fill(FiliconTheme.border.opacity(0.5)).frame(height: 1) }
                    }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(FiliconTheme.canvas)
            }
        }
        .foregroundStyle(FiliconTheme.textPrimary)
        .sheet(isPresented: $showingNewGroup) { CreateGroupSheet() }
    }

    private var workspaceTitle: String? {
        switch model.route {
        case .agents: l10n("Agents")
        case .automations: l10n("Automations")
        case .channels: l10n("Channels")
        case .sharedRooms: l10n("Shared Rooms")
        case .mcp: l10n("MCP Servers")
        case .computer: l10n("Computer")
        case .plugins: l10n("Plugins")
        case .account: l10n("Account")
        case .hiddenChats: l10n("Hidden Chats")
        case .search: l10n("Search")
        default: nil
        }
    }

    private func returnToChat() { model.selectRoute(.groups) }
}

struct FiliconSidebar: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Environment(\.openSettings) private var openSettings
    @State private var showingWorkspace = false
    let onNewGroup: () -> Void

    var body: some View {
        let _ = locale.identifier
        VStack(spacing: 0) {
            HStack {
                // Leave room for the native macOS window controls.
                Spacer(minLength: 76)
                Text(l10n("Filicon")).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FiliconTheme.textTertiary)
                Spacer(minLength: 8)
                Menu {
                    Button(l10n("New Group Chat"), action: onNewGroup)
                    Button(l10n("New Conversation"), action: model.addConversation)
                } label: {
                    Image(systemName: "plus").font(.system(size: 16, weight: .regular)).frame(width: 26, height: 28)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(l10n("New Group Chat"))
                .accessibilityIdentifier("new-chat-menu")
                .disabled(!model.isBootstrapped)
            }
            .padding(.horizontal, 14).frame(height: 54)

            Button(action: model.focusGlobalSearch) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12))
                    Text(l10n("Search"))
                    Spacer()
                    Text(l10n("⌘K")).font(.system(size: 10))
                }
                .font(.system(size: 12))
                .foregroundStyle(FiliconTheme.textTertiary)
                .padding(.horizontal, 10).frame(height: 32)
                .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    sidebarCaption(l10n("Group Chats"))
                    ForEach(model.groups) { group in
                        Button { model.selectGroup(id: group.id) } label: {
                            ChatListRow(
                                title: group.name,
                                subtitle: model.groupMessages[group.id]?.last?.text ?? group.summary,
                                date: model.groupMessages[group.id]?.last?.createdAt,
                                selected: model.route == .groups && (model.selectedGroupID == group.id || model.selectedGroupID == nil && model.groups.first?.id == group.id),
                                isWorking: model.runningGroups.contains(group.id)
                            ) {
                                GroupAvatar(group: group, agents: model.agents, size: 36)
                            }
                        }.buttonStyle(.plain)
                    }
                    if model.groups.isEmpty {
                        Button(l10n("Create your first group"), action: onNewGroup)
                            .font(.system(size: 12)).foregroundStyle(FiliconTheme.textSecondary)
                            .buttonStyle(.plain).padding(.horizontal, 12).padding(.vertical, 12)
                    }
                    sidebarCaption(l10n("Direct Chats")).padding(.top, 14)
                    ForEach(model.visibleConversations) { conversation in
                        ConversationSidebarRow(conversation: conversation)
                    }
                    if model.hasMoreConversations {
                        Button(l10n("Load more chats"), action: loadMore)
                            .buttonStyle(.plain).font(.caption).padding(12)
                            .disabled(model.isLoadingMoreConversations)
                    }
                }.padding(.horizontal, 8)
            }.scrollIndicators(.hidden)

            VStack(spacing: 2) {
                FiliconSidebarRow(title: l10n("Agents"), systemName: "person.2", selected: model.route == .agents) { model.selectRoute(.agents) }
                FiliconSidebarRow(title: l10n("Automations"), systemName: "clock", selected: model.route == .automations) { model.selectRoute(.automations) }
                Button { showingWorkspace.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2").frame(width: 18)
                        Text(l10n("Workspace"))
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                    }
                    .font(.system(size: 13)).padding(.horizontal, 11).frame(height: 34)
                    .foregroundStyle(FiliconTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("workspace-menu")
                .popover(isPresented: $showingWorkspace, arrowEdge: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        routeButton("Channels", "number", .channels)
                        routeButton("Shared Rooms", "person.3", .sharedRooms)
                        routeButton("MCP Servers", "server.rack", .mcp)
                        routeButton("Computer", "display", .computer)
                        routeButton("Plugins", "puzzlepiece.extension", .plugins)
                        routeButton("Account", "person.crop.circle", .account)
                        Divider().padding(.vertical, 5)
                        routeButton("Hidden Chats", "archivebox", .hiddenChats)
                        Divider().padding(.vertical, 5)
                        HStack {
                            FiliconIconButton(label: l10n("Back"), systemName: "arrow.left", action: model.goBack).disabled(!model.canGoBack)
                            FiliconIconButton(label: l10n("Forward"), systemName: "arrow.right", action: model.goForward).disabled(!model.canGoForward)
                        }
                    }.padding(10).frame(width: 210).background(FiliconTheme.canvas)
                }
            }.padding(8)

            HStack(spacing: 8) {
                PetAvatarImage(pet: .codex).frame(width: 27, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n("Local workspace")).font(.system(size: 11, weight: .medium))
                    Text(model.dataRoot.lastPathComponent).font(.system(size: 10)).foregroundStyle(FiliconTheme.textTertiary)
                }.lineLimit(1)
                Spacer(minLength: 0)
                FiliconIconButton(label: l10n("Settings"), systemName: "gearshape", size: 28) { openSettings() }
                    .accessibilityIdentifier("workspace-settings")
            }
            .padding(14)
            .overlay(alignment: .top) { Rectangle().fill(FiliconTheme.border.opacity(0.5)).frame(height: 1) }
        }.background(FiliconTheme.sidebar)
    }

    private func sidebarCaption(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .medium))
            .foregroundStyle(FiliconTheme.textTertiary).padding(.horizontal, 12).padding(.bottom, 4)
    }

    private func routeButton(_ key: String, _ symbol: String, _ route: WorkspaceRoute) -> some View {
        Button { selectWorkspace(route) } label: {
            Label(FiliconLocalization.string(key), systemImage: symbol)
                .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func selectWorkspace(_ route: WorkspaceRoute) {
        showingWorkspace = false
        model.selectRoute(route)
    }

    private func loadMore() { Task { await model.loadMoreConversations() } }
}

struct ChatListRow<Avatar: View>: View {
    let title: String
    let subtitle: String
    var date: Date?
    var selected = false
    var isWorking = false
    @ViewBuilder var avatar: Avatar

    var body: some View {
        HStack(spacing: 10) {
            avatar.frame(width: 36, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if let date {
                        Text(date, style: .time).font(.system(size: 9.5)).foregroundStyle(FiliconTheme.textTertiary).lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    Text(subtitle.isEmpty ? FiliconLocalization.string("No messages") : subtitle)
                        .font(.system(size: 11.5)).foregroundStyle(FiliconTheme.textTertiary).lineLimit(1)
                    Spacer(minLength: 0)
                    if isWorking { ProgressView().controlSize(.mini) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(selected ? FiliconTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }
}

struct ConversationSidebarRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    let conversation: Conversation
    @State private var showingRename = false
    @State private var title = ""

    var body: some View {
        let _ = locale.identifier
        Button { model.selectRoute(.conversation(conversation.id)) } label: {
            ChatListRow(
                title: conversation.title == "New conversation" ? l10n("New Conversation") : conversation.title,
                subtitle: conversation.messages.last?.text ?? "",
                date: conversation.messages.last?.createdAt,
                selected: model.route == .conversation(conversation.id),
                isWorking: model.running.contains(conversation.id)
            ) { PetAvatarImage(pet: .codex).padding(1) }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(l10n("Rename…"), action: beginRename)
            Button(l10n("Hide")) { model.setConversationHidden(id: conversation.id, hidden: true) }
            Divider()
            Button(l10n("Delete"), role: .destructive) { model.deleteConversation(id: conversation.id) }
        }
        .sheet(isPresented: $showingRename) {
            VStack(alignment: .leading, spacing: 16) {
                Text(l10n("Rename Conversation")).font(.headline)
                TextField(l10n("Title"), text: $title).onSubmit(rename)
                HStack {
                    Spacer()
                    Button(l10n("Cancel")) { showingRename = false }
                    Button(l10n("Rename"), action: rename).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 380)
        }
    }

    private func beginRename() { title = conversation.title; showingRename = true }
    private func rename() { model.renameConversation(id: conversation.id, title: title); showingRename = false }
}

struct GroupAvatar: View {
    let group: AgentGroup
    let agents: [AgentProfile]
    var size: CGFloat = 36

    private var members: [AgentProfile] {
        Array(group.memberIDs.compactMap { id in agents.first { $0.id == id } }.prefix(2))
    }

    var body: some View {
        ZStack {
            if let first = members.first {
                AgentAvatarIcon(profile: first, dimension: members.count == 1 ? size : size * 0.76)
                    .offset(x: members.count == 1 ? 0 : -size * 0.15, y: members.count == 1 ? 0 : -size * 0.10)
                if members.count > 1 {
                    AgentAvatarIcon(profile: members[1], dimension: size * 0.61)
                        .offset(x: size * 0.22, y: size * 0.22)
                }
            } else {
                PetAvatarImage(pet: .seedy)
            }
        }.frame(width: size, height: size).accessibilityLabel(group.name)
    }
}
