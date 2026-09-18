import SwiftUI
import UniformTypeIdentifiers
import FiliconAgents
import FiliconDomain
import FiliconAutomations
import FiliconAutoReview

struct GroupWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @State private var showingNewGroup = false
    @State private var drafts = GroupComposerDrafts()
    @State private var imageDrafts = GroupImageDrafts()

    var body: some View {
        let _ = locale.identifier
        Group {
            if let group = model.groups.first(where: { $0.id == model.selectedGroupID }) ?? model.groups.first {
                GroupConversationView(group: group, draft: $drafts[group.id], images: $imageDrafts[group.id])
                    .id(group.id)
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(l10n("Group chat")).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        FiliconIconButton(label: l10n("New Group Chat"), systemName: "plus") { showingNewGroup = true }
                    }.padding(.horizontal, 24).frame(height: 54)
                    Spacer()
                    HStack(alignment: .bottom, spacing: 6) {
                        PetAvatarImage(pet: .seedy).frame(width: 52, height: 58)
                        PetAvatarImage(pet: .codex).frame(width: 74, height: 82)
                        PetAvatarImage(pet: .dewey).frame(width: 50, height: 58)
                    }.padding(.bottom, 20)
                    Text(l10n("A little team. A lot of possibility."))
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text(l10n("Bring your agents together and start a conversation."))
                        .font(.system(size: 13)).foregroundStyle(FiliconTheme.textSecondary)
                        .multilineTextAlignment(.center).padding(.top, 10)
                    Button(l10n("Create your first group")) { showingNewGroup = true }
                        .buttonStyle(FiliconPrimaryButtonStyle()).padding(.top, 22)
                    Spacer()
                    Text(l10n("Filicon")).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FiliconTheme.textTertiary).padding(.bottom, 24)
                }.padding(.horizontal, 24)
            }
        }
        .background(FiliconTheme.canvas)
        .sheet(isPresented: $showingNewGroup) { CreateGroupSheet() }
        .onChange(of: model.settings.accountScope) {
            drafts = GroupComposerDrafts(); imageDrafts = GroupImageDrafts()
        }
    }
}

struct GroupConversationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    let group: AgentGroup
    @Binding var draft: String
    @Binding var images: [AttachmentMetadata]
    @State private var inspectorVisible = true
    @State private var compactInspectorPresented = false
    @State private var composerSelection = NSRange(location: 0, length: 0)
    @State private var composerFocused = false
    @State private var composerComposing = false
    @State private var dismissedMention: GroupMentionCompletion.Query?
    @State private var selectedMention = 0
    @State private var folderPromptHeight: CGFloat = 180
    @State private var importingImages = false
    @State private var posting = false

    private var messages: [RoomMessage] { model.groupMessages[group.id] ?? [] }
    private var isRunning: Bool { model.runningGroups.contains(group.id) }
    private var approvalScopeID: UUID { model.groupApprovalScope(group.id) }
    private var folderRequests: [WorkspaceFolderRequest] {
        model.pendingWorkspaceFolders.filter { $0.conversationID == approvalScopeID }
    }
    private var mentionMemberNames: [String] {
        model.agents.filter { group.memberIDs.contains($0.id) && $0.archivedAt == nil }.map(\.name)
    }
    private var mentionQuery: GroupMentionCompletion.Query? {
        guard composerFocused, !composerComposing,
              let query = GroupMentionCompletion.query(in: draft, selection: composerSelection, memberNames: mentionMemberNames),
              query != dismissedMention else { return nil }
        return query
    }
    private var mentionCandidates: [GroupMentionCompletion.Candidate] {
        guard let query = mentionQuery else { return [] }
        return GroupMentionCompletion.candidates(for: query, memberIDs: group.memberIDs, agents: model.agents)
    }

    var body: some View {
        let _ = locale.identifier
        GeometryReader { geometry in
            let inline = ConversationLayout.showsInlineInspector(detailWidth: geometry.size.width)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(inline: inline)
                    transcript
                    if !folderRequests.isEmpty {
                        // Required input is not transcript history. Keep it
                        // mounted and reachable even while history is scrolled.
                        ScrollView {
                            VStack(spacing: 8) {
                                WorkspaceFolderAccessPanel(conversationID: approvalScopeID)
                            }
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { folderPromptHeight = $0 }
                        }
                        .frame(height: min(folderPromptHeight, 280, geometry.size.height * 0.45))
                        .padding(.horizontal, 24).padding(.top, 8)
                        .accessibilityIdentifier("group-workspace-folder-actions")
                    }
                    composer
                }.frame(maxWidth: .infinity)
                if inline && inspectorVisible {
                    Rectangle().fill(FiliconTheme.border.opacity(0.5)).frame(width: 1)
                    GroupInspector(group: group, onClose: { inspectorVisible = false })
                        .frame(width: ConversationLayout.inspectorWidth)
                }
            }
        }
        .sheet(isPresented: $compactInspectorPresented) {
            GroupInspector(group: group, onClose: { compactInspectorPresented = false })
                .frame(width: 340, height: 650)
        }
        .background(FiliconTheme.canvas)
    }

    private func header(inline: Bool) -> some View {
        HStack(spacing: 9) {
            GroupAvatar(group: group, agents: model.agents, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(l10n("\(group.memberIDs.count) members"))
                    .font(.system(size: 10)).foregroundStyle(FiliconTheme.textTertiary)
            }
            Spacer(minLength: 8)
            FiliconIconButton(label: l10n("Computer"), systemName: "display", size: 28) { model.selectRoute(.computer) }
            FiliconIconButton(label: l10n("Group settings"), systemName: "sidebar.right", size: 28) {
                if inline { inspectorVisible.toggle() } else { compactInspectorPresented = true }
            }.accessibilityIdentifier("group-inspector-toggle")
        }
        .padding(.horizontal, 20).frame(height: 54)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        VStack(spacing: 12) {
                            GroupAvatar(group: group, agents: model.agents, size: 70)
                            Text(group.name).font(.system(size: 22, weight: .semibold, design: .rounded))
                            Text(group.summary.isEmpty ? l10n("Bring your agents together and start a conversation.") : group.summary)
                                .font(.system(size: 13)).foregroundStyle(FiliconTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 80)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if index == 0 || !Calendar.current.isDate(messages[index - 1].createdAt, inSameDayAs: message.createdAt) {
                            Text(message.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.system(size: 10.5)).foregroundStyle(FiliconTheme.textTertiary)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        GroupMessageBubble(
                            message: message,
                            agent: model.agents.first { $0.id == message.senderID },
                            waitingForFolderCallIDs: Set(folderRequests.map { $0.toolCallID.rawValue }),
                            onReaction: { Task { await model.toggleGroupReaction(groupID: group.id, messageID: message.id, emoji: "👍") } }
                        ).id(message.id)
                    }
                    if folderRequests.isEmpty {
                        if let agentID = model.thinkingGroupMembers[group.id],
                           let agent = model.agents.first(where: { $0.id == agentID }) {
                            GroupThinkingIndicator(agentName: agent.name)
                        } else if isRunning {
                            GroupThinkingIndicator(agentName: group.name)
                        }
                    }
                    GroupToolApprovalPanel(groupID: approvalScopeID)
                    MCPApprovalPanel(conversationID: approvalScopeID)
                    Color.clear.frame(height: 1).id("group-bottom")
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 16)
                .frame(maxWidth: 780).frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { scrollToBottom(proxy) }
            .onChange(of: model.thinkingGroupMembers[group.id]) { scrollToBottom(proxy) }
            .onChange(of: model.pendingAutoReviewApprovals) { scrollToBottom(proxy) }
            .onChange(of: model.pendingMCPApprovals.count) { scrollToBottom(proxy) }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(l10n("Tools & connections")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l10n("Integrations are managed in MCP Servers and Plugins. Gmail installation cards are not supported in chat."))
                    Text(l10n("Text-only providers cannot use Filicon tools."))
                    HStack {
                        Button(l10n("MCP Servers")) { model.selectRoute(.mcp) }
                        Button(l10n("Plugins")) { model.selectRoute(.plugins) }
                    }
                }.padding(.top, 6)
            }
            .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            if group.memberIDs.isEmpty {
                Text(l10n("Add members to start chatting."))
                    .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            }
            if !images.isEmpty {
                GroupImageDraftPreview(onRemove: removeImages) {
                    AgentMessageImagePreviews(images: images, compact: true)
                }.disabled(isRunning || posting)
            }
            if mentionQuery != nil { mentionMenu }
            HStack(alignment: .bottom, spacing: 10) {
                FiliconIconButton(label: l10n("Attach images…"), systemName: "photo.badge.plus", size: 30, action: attachImages)
                    .disabled(isRunning || posting || importingImages)
                    .accessibilityIdentifier("group-attach-images")
                GroupComposerEditor(
                    text: $draft, selection: $composerSelection,
                    focused: $composerFocused, composing: $composerComposing,
                    placeholder: l10n("Message the group; @name and @everyone are supported"),
                    onCommand: composerCommand
                )
                if isRunning {
                    FiliconIconButton(label: l10n("Stop"), systemName: "stop.fill", size: 30, isProminent: true, action: stop)
                } else {
                    FiliconIconButton(label: l10n("Send"), systemName: "arrow.up", size: 30, isProminent: true, action: send)
                        .disabled((draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty) || group.memberIDs.isEmpty || posting || importingImages)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
            .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(FiliconTheme.border.opacity(0.6), lineWidth: 1))
        }
        .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 22)
        .disabled(!model.isBootstrapped)
        .onChange(of: mentionQuery) { selectedMention = 0 }
        .onChange(of: mentionCandidates.map(\.id)) { selectedMention = 0 }
    }

    private var mentionMenu: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l10n("Mention a group member")).font(.system(size: 11, weight: .medium))
                .foregroundStyle(FiliconTheme.textSecondary).padding(.horizontal, 10).padding(.vertical, 5)
            if mentionCandidates.isEmpty {
                Text(l10n("No matching group members"))
                    .font(.system(size: 12)).foregroundStyle(FiliconTheme.textSecondary).padding(10)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(mentionCandidates.enumerated()), id: \.element.id) { index, candidate in
                                Button { mentionSelected(candidate) } label: {
                                    HStack(spacing: 9) {
                                        if let agent = candidate.agent {
                                            AgentAvatarIcon(profile: agent, dimension: 25)
                                        } else {
                                            Image(systemName: "person.3.fill").frame(width: 25, height: 25)
                                        }
                                        Text(candidate.agent == nil ? l10n("All group members") : candidate.name)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        if candidate.agent == nil {
                                            Text(verbatim: "@everyone").foregroundStyle(FiliconTheme.textSecondary)
                                        }
                                        if index == selectedMention { Image(systemName: "return").font(.caption) }
                                    }
                                    .font(.system(size: 13)).foregroundStyle(FiliconTheme.textPrimary)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(index == selectedMention ? FiliconTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("group-mention-\(candidate.id)")
                                .accessibilityAddTraits(index == selectedMention ? .isSelected : [])
                                .id(index)
                            }
                        }
                    }.frame(height: CGFloat(min(mentionCandidates.count, 4)) * 39)
                        .onChange(of: selectedMention) { proxy.scrollTo(selectedMention) }
                }
            }
            Text(l10n("↑↓ Select · Enter Insert · Esc Close"))
                .font(.system(size: 10)).foregroundStyle(FiliconTheme.textTertiary).padding(.horizontal, 10).padding(.vertical, 5)
        }
        .padding(6).background(FiliconTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(FiliconTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityIdentifier("group-mention-menu")
    }

    private func mentionSelected(_ candidate: GroupMentionCompletion.Candidate) {
        guard let query = GroupMentionCompletion.query(in: draft, selection: composerSelection, memberNames: mentionMemberNames),
              GroupMentionCompletion.candidates(for: query, memberIDs: group.memberIDs, agents: model.agents).contains(candidate),
              let insertion = GroupMentionCompletion.inserting(candidate, into: draft, query: query) else { return }
        draft = insertion.text
        composerSelection = insertion.selection
        dismissedMention = GroupMentionCompletion.query(in: draft, selection: composerSelection, memberNames: mentionMemberNames)
        composerFocused = true
    }

    private func composerCommand(_ command: GroupComposerCommand, text: String, selection: NSRange) -> Bool {
        // Read the editor's live value, rather than a potentially one-frame-old View.
        draft = text
        composerSelection = selection
        let query = GroupMentionCompletion.query(in: text, selection: selection, memberNames: mentionMemberNames)
        let open = query != nil && query != dismissedMention
        let candidates = query.map { GroupMentionCompletion.candidates(for: $0, memberIDs: group.memberIDs, agents: model.agents) } ?? []
        switch command {
        case .previous, .next:
            guard open, !candidates.isEmpty else { return false }
            selectedMention = GroupMentionCompletion.movedSelection(selectedMention, by: command == .next ? 1 : -1, count: candidates.count)
        case .dismiss:
            guard open else { return false }
            dismissedMention = query
        case .accept, .submit:
            if open {
                if !candidates.isEmpty { mentionSelected(candidates[min(selectedMention, candidates.count - 1)]) }
                // An empty-result menu must not accidentally submit an unknown mention.
            } else if command == .submit { send() }
            else { return false }
        }
        return true
    }

    private func send() {
        guard !isRunning, !posting, !importingImages, !group.memberIDs.isEmpty,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        let members = model.agents.filter { group.memberIDs.contains($0.id) && $0.archivedAt == nil }
        if let unknown = GroupService.unknownMentions(in: draft, members: members).first {
            model.errorMessage = l10n("No group member matches @\(unknown). Add the member or choose an existing name.")
            return
        }
        let value = draft
        let selectedImages = images
        posting = true
        Task {
            defer { posting = false }
            await model.sendGroupMessage(groupID: group.id, text: value, images: selectedImages) {
                // Preserve the draft if validation/persistence failed, and never
                // clear text the user started editing while preflight awaited.
                if draft == value { draft = ""; composerSelection = NSRange(location: 0, length: 0) }
                if images == selectedImages { images = [] }
                dismissedMention = nil
            }
        }
    }

    private func removeImages() { images = [] }

    private func attachImages() { Task { await chooseImages() } }

    private func chooseImages() async {
        importingImages = true
        defer { importingImages = false }
        let account = model.settings.accountScope
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard await panel.begin() == .OK, account == model.settings.accountScope else { return }
        do {
            let selected = try await model.importAgentMessageImages(panel.urls)
            guard account == model.settings.accountScope else { return }
            images = selected
        } catch is CancellationError {} catch { model.errorMessage = FiliconLocalization.string(error.localizedDescription) }
    }

    private func stop() { Task { await model.stopGroup(id: group.id) } }
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("group-bottom", anchor: .bottom) }
    }
}

struct GroupImageDraftPreview<Previews: View>: View {
    let onRemove: () -> Void
    @ViewBuilder var previews: () -> Previews
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(l10n("Images are saved in this group and sent to the responding members' configured models. @mentions limit this turn's recipients."))
                    .font(.caption).foregroundStyle(FiliconTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(l10n("Remove images"), systemImage: "xmark", action: onRemove).labelStyle(.iconOnly)
            }
            ScrollView { previews() }.frame(maxHeight: 150)
            Text(l10n("Use at most 4 images, 5 MB each and 12 MB total."))
                .font(.caption2).foregroundStyle(FiliconTheme.textTertiary)
        }
        .accessibilityIdentifier("group-image-draft")
    }
}

struct GroupMessageBubble: View {
    let message: RoomMessage
    let agent: AgentProfile?
    var waitingForFolderCallIDs: Set<String> = []
    let onReaction: () -> Void
    @State private var hovering = false
    private var isUser: Bool { message.senderID == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if isUser { Spacer(minLength: 50) }
            VStack(alignment: .leading, spacing: 6) {
                if !isUser {
                    HStack(spacing: 6) {
                        if let agent { AgentAvatarIcon(profile: agent, dimension: 20) }
                        Text(agent?.name ?? FiliconLocalization.string("Agent"))
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(FiliconTheme.textSecondary)
                    }
                }
                if !message.text.isEmpty {
                    Group {
                        if isUser { Text(message.text) }
                        else { RichMarkdownView(source: message.text, fillsWidth: false) }
                    }.font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    .foregroundStyle(isUser ? FiliconTheme.userBubbleText : FiliconTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 13).padding(.vertical, 10)
                    .background(isUser ? FiliconTheme.userBubble : FiliconTheme.incomingBubble, in: RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button(FiliconLocalization.string("Copy"), action: copy)
                        if !isUser { Button("👍", action: onReaction) }
                    }
                }
                if let images = message.images, !images.isEmpty { AgentMessageImagePreviews(images: images) }
                ForEach(message.toolActivities) { tool in
                    let waitingForFolder = tool.status == .pending && waitingForFolderCallIDs.contains(tool.id)
                    HStack(spacing: 7) {
                        if waitingForFolder { Image(systemName: "folder.badge.questionmark") }
                        else if tool.status == .pending { ProgressView().controlSize(.small) }
                        else { Image(systemName: tool.status == .succeeded ? "checkmark.circle" : "xmark.circle") }
                        Text(tool.name).font(.caption.monospaced()).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(waitingForFolder ? l10n("Waiting for folder selection") : toolStatus(tool.status)).font(.caption)
                    }
                    .padding(10)
                    .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier("group-tool-\(tool.id)")
                }
                if let outcome = message.memberOutcome {
                    Label(
                        l10n(outcome == .failed ? "Member response failed. Send a message to retry." : "No new contribution this turn."),
                        systemImage: outcome == .failed ? "exclamationmark.triangle" : "minus.circle"
                    )
                    .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
                    .accessibilityIdentifier("group-member-outcome-\(outcome.rawValue)")
                } else if !isUser && message.toolActivities.isEmpty {
                    Text(l10n("Text reply · no tools used"))
                        .font(.system(size: 10)).foregroundStyle(FiliconTheme.textTertiary)
                }
                HStack(spacing: 8) {
                    Text(message.createdAt, style: .time).font(.system(size: 9))
                    if !isUser && message.memberOutcome == nil { Button("👍", action: onReaction).buttonStyle(.plain).font(.system(size: 10)) }
                }
                .foregroundStyle(FiliconTheme.textTertiary)
                .opacity(hovering ? 1 : 0)
                .accessibilityHidden(!hovering)
            }
            .frame(maxWidth: 500, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 50) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .onHover { hovering = $0 }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }

    private func toolStatus(_ status: RoomToolActivity.Status) -> String {
        switch status {
        case .pending: l10n("Awaiting approval or result")
        case .succeeded: l10n("Completed")
        case .failed: l10n("Failed")
        case .cancelled: l10n("Cancelled")
        }
    }
}

struct GroupToolApprovalPanel: View {
    @EnvironmentObject private var model: AppModel
    let groupID: UUID

    var body: some View {
        ForEach(model.pendingAutoReviewApprovals.filter { $0.action.context.conversationID == groupID }) { approval in
            VStack(alignment: .leading, spacing: 8) {
                Label(l10n("Approval required"), systemImage: "checkmark.shield")
                    .font(.headline)
                Text(approval.action.summary).font(.callout).textSelection(.enabled)
                if let members = approval.action.context.metadata["agentGroupMembers"] {
                    AgentGroupApprovalDetails(members: members, isImagePublication: approval.action.context.metadata["agentImagePublication"] == "true")
                }
                if approval.action.context.metadata["agentMessagePriority"] == "priority" {
                    AgentPriorityMessageNotice()
                }
                if let encoded = approval.action.context.metadata["agentImages"],
                   let images = try? JSONDecoder().decode([AttachmentMetadata].self, from: Data(encoded.utf8)) {
                    Text(l10n(approval.action.context.metadata["agentImagePublication"] == "true"
                              ? "Publish these images in this conversation?"
                              : "Forward these images to the recipient model?")).font(.callout.weight(.semibold))
                    AgentMessageImagePreviews(images: images)
                }
                if ["SendToAgent", "SendMessage"].contains(approval.action.context.metadata["tool"] ?? ""),
                   let text = approval.action.context.metadata["agentMessage"] {
                    // The summary is bounded to 2,000 characters; the actual
                    // outgoing payload must be visible in full before approval.
                    Text(verbatim: text).font(.callout).textSelection(.enabled)
                }
                if approval.action.context.metadata["agentStateTarget"] == "memory" {
                    AgentMemoryApprovalDetails(metadata: approval.action.context.metadata)
                } else if approval.action.context.metadata["agentStateTarget"] == "avatar" {
                    AgentAvatarApprovalDetails(metadata: approval.action.context.metadata)
                } else if approval.action.context.metadata["agentStateTarget"] == "routine" {
                    AgentRoutineApprovalDetails(metadata: approval.action.context.metadata)
                } else if ["CreateAgent", "UpdateAgent", "update_state"].contains(approval.action.context.metadata["tool"] ?? "") {
                    AgentProfileApprovalDetails(metadata: approval.action.context.metadata)
                }
                Text(FiliconLocalization.string(approval.reason)).font(.caption).foregroundStyle(FiliconTheme.textSecondary)
                HStack {
                    Button(l10n("Approve")) { Task { await resolve(approval, approve: true) } }
                        .accessibilityIdentifier("group-tool-approve")
                    Button(l10n("Reject"), role: .destructive) { Task { await resolve(approval, approve: false) } }
                        .accessibilityIdentifier("group-tool-reject")
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(FiliconTheme.input, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func resolve(_ approval: PendingApproval, approve: Bool) async {
        await model.resolveGroupApproval(approval, groupID: groupID, approve: approve)
    }
}

struct AgentPriorityMessageNotice: View {
    var body: some View {
        Label(l10n("Priority messages may stop background work after the current response ends. User turns are protected; interrupted work is not automatically resumed."), systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentGroupApprovalDetails: View {
    let members: String
    var isImagePublication = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n("Group audience")).font(.callout.weight(.semibold))
            Text(verbatim: members).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(l10n(isImagePublication
                      ? "This saves the reply and images in this group. It does not add responders or automatically resend images to other models."
                      : "This posts to the shared room and wakes its other active members. Replies appear there. Tool actions still need approval."))
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AgentMemoryApprovalDetails: View {
    let metadata: [String: String]
    private var scope: AgentMemory.Scope { AgentMemory.Scope(rawValue: metadata["agentMemoryScope"] ?? "agent") ?? .agent }
    private var title: LocalizedText {
        if scope == .user { return metadata["agentMemoryAction"] == "forget" ? "Forget shared user memory" : "Save shared user memory" }
        return metadata["agentMemoryAction"] == "forget" ? "Forget agent memory" : "Save agent memory"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n(title)).font(.headline)
            Text(verbatim: metadata["agentMemoryOwner"] ?? "").font(.callout.weight(.semibold))
            Text(l10n(scope.memoryTitleKey)).font(.callout.weight(.semibold))
            Text(l10n((AgentMemory.Tier(rawValue: metadata["agentMemoryTier"] ?? "log") ?? .log).memoryTitleKey)).font(.caption)
            Text(verbatim: metadata["agentMemoryFact"] ?? "").fixedSize(horizontal: false, vertical: true)
            Text(l10n(scope.memoryDisclosureKey))
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            Text(l10n("Only a ranked selection is sent each turn. Low-importance notes rank below equally recent dated facts. Omitted facts remain saved until you forget them."))
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            if metadata["agentMemoryAction"] == "forget" {
                Text(l10n("Forgetting stops future memory injection. Existing messages and running requests are not erased."))
                    .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            }
        }.textSelection(.enabled)
    }
}

extension AgentMemory.Tier {
    var memoryTitleKey: LocalizedText {
        switch self {
        case .profile: "Foundational fact"
        case .log: "Dated fact"
        case .note: "Low-importance note"
        }
    }
}

extension AgentMemory.Scope {
    var memoryTitleKey: LocalizedText { self == .user ? "Shared user memory" : "Agent memory" }
    var memoryDisclosureKey: LocalizedText {
        self == .user
            ? "Shared facts are sent to every current and future agent's configured model in this account during group and mailbox turns, including agents outside this group. Sharing does not grant tool permissions."
            : "Saved facts are sent to this agent's configured model in future group and mailbox turns in this account. They are not shared with other agents or used as tool permissions."
    }
}

struct AgentRoutineApprovalDetails: View {
    let metadata: [String: String]
    private var title: LocalizedText {
        switch metadata["agentRoutineAction"] {
        case "delete": "Delete own routine"
        case "resume": "Resume own routine"
        default: "Pause own routine"
        }
    }
    private var disclosure: LocalizedText {
        switch metadata["agentRoutineAction"] {
        case "delete": "Delete removes this routine and prevents future triggers. There is no undo. Execution history stays in storage; already started or queued runs are not cancelled."
        case "resume": "Resume enables future triggers and may incur model costs. It does not run immediately or replay missed runs. Task, trigger and history stay unchanged."
        default: "Pause disables future triggers. Already started or queued runs are not cancelled. Task, trigger and history stay unchanged."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n(title)).font(.headline)
            Text(verbatim: metadata["agentName"] ?? "").font(.callout.weight(.semibold))
            Text(verbatim: metadata["agentRoutineName"] ?? "").font(.callout.weight(.semibold))
            Text(l10n("Routine ID")).font(.caption.weight(.semibold))
            Text(verbatim: metadata["agentRoutineID"] ?? "").font(.caption.monospaced())
            Text(l10n("Task and trigger")).font(.caption.weight(.semibold))
            Text(verbatim: metadata["agentRoutinePrompt"] ?? "")
            Text(verbatim: metadata["agentRoutineTrigger"] ?? "").font(.caption.monospaced())
            Text(l10n(disclosure))
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
        }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

struct AgentAvatarApprovalDetails: View {
    let metadata: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n(metadata["agentAvatarAction"] == "clear" ? "Reset own avatar" : "Change own avatar"))
                .font(.headline)
            Text(verbatim: metadata["agentName"] ?? "").font(.callout.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                avatarColumn("Current avatar", petID: metadata["previousAgentAvatarPet"])
                Image(systemName: "arrow.right").padding(.top, 44).accessibilityHidden(true)
                avatarColumn("New avatar", petID: metadata["agentAvatarPet"])
            }
            Text(l10n("Only this agent's avatar changes. Names, private instructions, models and permissions stay unchanged. Reset restores Codex; no image files are deleted."))
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func avatarColumn(_ title: String, petID: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(FiliconLocalization.string(title)).font(.caption)
            if let petID, let pet = AgentPetAvatar(rawValue: petID) {
                PetAvatarImage(pet: pet).frame(width: 64, height: 70)
                Text(verbatim: pet.name).font(.callout)
            } else {
                Image(systemName: "person.crop.square").font(.largeTitle).frame(width: 64, height: 70)
                Text(l10n("Custom or default avatar")).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AgentProfileApprovalDetails: View {
    let metadata: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if metadata["tool"] == "update_state" {
                Text(l10n("Update own profile")).font(.callout.weight(.semibold))
            }
            field("Name", before: metadata["previousAgentName"], after: metadata["agentName"])
            field("Description", before: metadata["previousAgentDescription"], after: metadata["agentDescription"])
            if metadata["tool"] == "CreateAgent" {
                field("Provider", after: metadata["agentProvider"])
                field("Model", after: metadata["agentModel"])
                Text(l10n("New agents use this description as their initial instructions. Group membership and permissions are unchanged."))
                    .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            } else {
                Text(l10n("Only the name and public description change. Private instructions, model and permissions are unchanged."))
                    .font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            }
        }
        .textSelection(.enabled)
    }
    private func field(_ label: String, before: String? = nil, after: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(FiliconLocalization.string(label)).font(.caption).foregroundStyle(FiliconTheme.textSecondary)
            if let before, before != after {
                Text(verbatim: before).font(.callout)
                Image(systemName: "arrow.down").font(.caption)
            }
            if let after, !after.isEmpty {
                Text(verbatim: after).font(.callout).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(l10n("Empty")).font(.callout).foregroundStyle(FiliconTheme.textSecondary)
            }
        }
    }
}

struct GroupThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let agentName: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.3, paused: reduceMotion)) { context in
            HStack(spacing: 8) {
                Text(agentName).font(.system(size: 11, weight: .medium))
                Text(l10n("Thinking")).font(.system(size: 11)).foregroundStyle(FiliconTheme.textTertiary)
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle().frame(width: 4, height: 4)
                            .opacity(reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 3) % 3 == index ? 1 : 0.2)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(FiliconTheme.incomingBubble, in: Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(l10n("\(agentName) Thinking"))
    }
}

struct FiliconPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(FiliconTheme.accentText)
            .background(FiliconTheme.accent.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

struct GroupComposerDrafts {
    private var values: [UUID: String] = [:]
    subscript(groupID: UUID) -> String {
        get { values[groupID] ?? "" }
        set { values[groupID] = newValue }
    }
}

struct GroupImageDrafts {
    private var values: [UUID: [AttachmentMetadata]] = [:]
    subscript(groupID: UUID) -> [AttachmentMetadata] {
        get { values[groupID] ?? [] }
        set { values[groupID] = newValue }
    }
}

struct GroupSettingsDraft: Equatable {
    var name = ""
    var summary = ""
    var memberIDs: Set<UUID> = []

    init(group: AgentGroup? = nil) {
        name = group?.name ?? ""
        summary = group?.summary ?? ""
        memberIDs = Set(group?.memberIDs ?? [])
    }

    var isValid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && memberIDs.count <= GroupService.maximumMembers }
    func orderedMembers(agents: [AgentProfile], preserving existing: [UUID] = []) -> [UUID] {
        let retained = existing.filter(memberIDs.contains)
        return retained + agents.map(\.id).filter { memberIDs.contains($0) && !retained.contains($0) }
    }
}

extension Set {
    subscript(includes element: Element) -> Bool {
        get { contains(element) }
        set { if newValue { insert(element) } else { remove(element) } }
    }
}

struct GroupInspector: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    let group: AgentGroup
    let onClose: () -> Void
    @State private var draft: GroupSettingsDraft
    @State private var saving = false

    init(group: AgentGroup, onClose: @escaping () -> Void) {
        self.group = group
        self.onClose = onClose
        _draft = State(initialValue: GroupSettingsDraft(group: group))
    }

    var body: some View {
        let _ = locale.identifier
        VStack(spacing: 0) {
            HStack {
                FiliconIconButton(label: l10n("Back"), systemName: "chevron.left", size: 24, action: onClose)
                Spacer()
                Text(l10n("Settings")).font(.system(size: 12, weight: .semibold))
                Spacer()
                FiliconIconButton(label: l10n("Close"), systemName: "xmark", size: 24, action: onClose)
            }.padding(.horizontal, 14).frame(height: 54)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    GroupAvatar(group: group, agents: model.agents, size: 76)
                        .frame(maxWidth: .infinity).padding(.top, 22).padding(.bottom, 12)
                    VStack(alignment: .leading, spacing: 14) {
                        inspectorField(l10n("Name"), text: $draft.name)
                        inspectorField(l10n("Description"), text: $draft.summary, multiline: true)
                    }
                    GroupMembersEditor(selection: $draft.memberIDs, showsSaveHint: true)
                        .disabled(saving)
                    Button(action: save) {
                        HStack { Spacer(); if saving { ProgressView().controlSize(.mini) }; Text(l10n("Save")); Spacer() }
                    }
                    .buttonStyle(FiliconPrimaryButtonStyle())
                    .disabled(saving || !draft.isValid || draft == GroupSettingsDraft(group: group))
                    .accessibilityIdentifier("save-group-settings")
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            caption(l10n("Automations"))
                            Spacer()
                            FiliconIconButton(label: l10n("New routine"), systemName: "plus", size: 22) { model.selectRoute(.automations) }
                        }
                        let routines = model.automations.filter { group.memberIDs.contains($0.agentID) }
                        if routines.isEmpty {
                            Text(l10n("No routines for this group yet."))
                                .font(.system(size: 11)).foregroundStyle(FiliconTheme.textTertiary)
                        }
                        ForEach(routines) { routine in
                            Button { model.selectRoute(.automations) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: routine.enabled && !routine.guardPaused ? "clock" : "pause.circle")
                                        .foregroundStyle(routine.enabled && !routine.guardPaused ? Color.green : FiliconTheme.textTertiary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(routine.name).font(.system(size: 12))
                                        if let next = routine.nextRunAt, routine.enabled && !routine.guardPaused {
                                            Text(next, format: .dateTime.weekday().hour().minute()).font(.system(size: 10))
                                        } else {
                                            Text(routine.enabled && !routine.guardPaused ? l10n("Enabled") : l10n("Paused")).font(.system(size: 10))
                                        }
                                    }
                                }.foregroundStyle(FiliconTheme.textSecondary)
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)
            }.scrollIndicators(.hidden)
        }
        .background(FiliconTheme.canvas)
        .onChange(of: group) { _, value in draft = GroupSettingsDraft(group: value) }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(FiliconTheme.textTertiary)
    }

    private func inspectorField(_ title: String, text: Binding<String>, multiline: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            caption(title)
            TextField(title, text: text, axis: multiline ? .vertical : .horizontal)
                .lineLimit(multiline ? 3...6 : 1...1).labelsHidden().textFieldStyle(.plain)
                .font(.system(size: 12)).padding(9)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(FiliconTheme.border.opacity(0.8), lineWidth: 1))
        }
    }

    private func save() {
        saving = true
        Task {
            _ = await model.saveGroupSettings(groupID: group.id, name: draft.name, summary: draft.summary, memberIDs: draft.orderedMembers(agents: model.agents, preserving: group.memberIDs))
            saving = false
        }
    }
}

struct GroupMemberPicker: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: Set<UUID>
    var onEdit: ((AgentProfile) -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.agents.filter { $0.archivedAt == nil || selection.contains($0.id) }) { agent in
                HStack(spacing: 8) {
                    Toggle(isOn: $selection[includes: agent.id]) {
                        HStack(spacing: 8) {
                            AgentAvatarIcon(profile: agent, dimension: 28)
                            Text(agent.name).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!selection.contains(agent.id) && selection.count >= GroupService.maximumMembers)
                    .accessibilityIdentifier("group-member-\(agent.id)")
                    Spacer(minLength: 0)
                    if let onEdit {
                        Button { onEdit(agent) } label: {
                            Image(systemName: "pencil").frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(FiliconTheme.textSecondary)
                        .help(l10n("Edit \(agent.name)"))
                        .accessibilityLabel(l10n("Edit \(agent.name)"))
                        .accessibilityIdentifier("edit-group-member-\(agent.id)")
                    }
                }
            }
        }
    }
}

/// The exact saved profile is returned by the editor; names are not unique identifiers.
struct GroupMemberEditorDestination: Identifiable {
    let profile: AgentProfile
    let isNew: Bool
    var id: UUID { profile.id }

    func memberSaved(_ saved: AgentProfile, selection: inout Set<UUID>) {
        guard isNew, selection.count < GroupService.maximumMembers else { return }
        selection.insert(saved.id)
    }
}

struct GroupMembersEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.locale) private var locale
    @Binding var selection: Set<UUID>
    var showsSaveHint = false
    @State private var editor: GroupMemberEditorDestination?

    private var isFull: Bool { selection.count >= GroupService.maximumMembers }

    var body: some View {
        let _ = locale.identifier
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(l10n("Members")).font(.system(size: 10.5)).foregroundStyle(FiliconTheme.textTertiary)
                Spacer(minLength: 8)
                Button { editor = GroupMemberEditorDestination(profile: AgentProfile(name: "", avatar: .pet(.codex)), isNew: true) } label: {
                    Label(l10n("New member"), systemImage: "plus").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .disabled(isFull)
                .accessibilityIdentifier("new-group-member")
            }
            GroupMemberPicker(selection: $selection) { agent in
                editor = GroupMemberEditorDestination(profile: agent, isNew: false)
            }
            if model.agents.allSatisfy({ $0.archivedAt != nil }) && selection.isEmpty {
                Text(l10n("Create an agent to give it instructions and a model."))
                    .font(.system(size: 11)).foregroundStyle(FiliconTheme.textSecondary)
            }
            if isFull {
                Text(l10n("Groups can have up to \(GroupService.maximumMembers) members."))
                    .font(.system(size: 10.5)).foregroundStyle(FiliconTheme.textSecondary)
            }
            if showsSaveHint {
                Text(l10n("New members are selected automatically. Save to apply membership changes."))
                    .font(.system(size: 10.5)).foregroundStyle(FiliconTheme.textTertiary)
            }
        }
        .sheet(item: $editor) { destination in
            AgentEditorView(profile: destination.profile, isNew: destination.isNew, showsSharedAgentNotice: !destination.isNew) { saved in
                destination.memberSaved(saved, selection: &selection)
            }
        }
    }
}

struct CreateGroupSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = GroupSettingsDraft()
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(l10n("New Group Chat")).font(.system(size: 20, weight: .semibold, design: .rounded))
                Spacer()
                FiliconIconButton(label: l10n("Close"), systemName: "xmark") { dismiss() }
            }
            TextField(l10n("Name"), text: $draft.name).textFieldStyle(.roundedBorder)
            TextField(l10n("Summary"), text: $draft.summary, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            ScrollView { GroupMembersEditor(selection: $draft.memberIDs).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 70, maxHeight: 200)
            HStack {
                Spacer()
                Button(l10n("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(l10n("Create group"), action: create)
                    .buttonStyle(FiliconPrimaryButtonStyle())
                    .disabled(!draft.isValid || draft.memberIDs.isEmpty || creating)
            }
        }
        .padding(28).frame(width: 420)
        .background(FiliconTheme.canvas)
    }

    private func create() {
        creating = true
        Task {
            let success = await model.createGroup(name: draft.name, summary: draft.summary, memberIDs: draft.orderedMembers(agents: model.agents))
            creating = false
            if success { dismiss() }
        }
    }
}
