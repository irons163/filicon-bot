import SwiftUI
import FiliconAgents

struct AgentMessagingView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var senderID: UUID?
    @State private var recipientID: UUID?
    @State private var draft = ""
    @State private var priority = AgentMessagePriority.normal
    @State private var mailbox = Mailbox.thread
    @State private var feedback: String?

    private enum Mailbox: String, CaseIterable, Identifiable {
        case thread = "Thread"
        case inbox = "Inbox"
        case outbox = "Outbox"
        var id: Self { self }
        var title: String { agentMessageString(rawValue) }
    }

    private var activeAgents: [AgentProfile] {
        model.agents.filter { $0.archivedAt == nil }
    }

    private var visibleMessages: [AgentMessage] {
        switch mailbox {
        case .thread:
            guard let senderID, let recipientID else { return [] }
            return model.agentThread(between: senderID, and: recipientID)
        case .inbox:
            guard let recipientID else { return [] }
            return model.agentInbox(for: recipientID)
        case .outbox:
            guard let senderID else { return [] }
            return model.agentOutbox(for: senderID)
        }
    }

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 0) {
            controls
            Divider()
            if activeAgents.count < 2 {
                ContentUnavailableView(
                    agentMessageString("Two active agents required"),
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(agentMessageString("Create or restore another agent to exchange messages."))
                )
            } else if visibleMessages.isEmpty {
                ContentUnavailableView(agentMessageString("No messages"), systemImage: "tray", description: Text(emptyDescription))
            } else {
                List(visibleMessages) { message in
                    messageRow(message)
                }
            }
        }
        .task {
            normalizeSelection()
            await model.reloadAgentMessages()
        }
        .onChange(of: model.agents) { _, _ in normalizeSelection() }
        .onChange(of: senderID) { _, _ in normalizeSelection() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(agentMessageString("From"), selection: $senderID) {
                    Text(agentMessageString("Select sender")).tag(Optional<UUID>.none)
                    ForEach(activeAgents) { Text($0.name).tag(Optional($0.id)) }
                }
                Picker(agentMessageString("To"), selection: $recipientID) {
                    Text(agentMessageString("Select recipient")).tag(Optional<UUID>.none)
                    ForEach(activeAgents.filter { $0.id != senderID }) { profile in
                        Text(recipientLabel(profile)).tag(Optional(profile.id))
                    }
                }
                Picker(agentMessageString("Priority"), selection: $priority) {
                    Text(agentMessageString("Normal")).tag(AgentMessagePriority.normal)
                    Text(agentMessageString("Priority")).tag(AgentMessagePriority.priority)
                }
                .frame(width: 150)
            }
            HStack(alignment: .bottom) {
                TextEditor(text: $draft)
                    .font(.body)
                    .frame(minHeight: 54, maxHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                    .onChange(of: draft) { _, value in
                        if value.count > 8_000 { draft = String(value.prefix(8_000)) }
                    }
                VStack(alignment: .trailing) {
                    Text("\(draft.count)/8,000").font(.caption).foregroundStyle(.secondary)
                    Button(agentMessageString("Send")) { send() }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canSend)
                }
            }
            HStack {
                Picker(agentMessageString("Mailbox"), selection: $mailbox) {
                    ForEach(Mailbox.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
                if let recipientID, model.agentMessageUnreadCounts[recipientID, default: 0] > 0 {
                    Button(agentMessageString("Mark Inbox Read")) {
                        Task { await model.markAgentMessagesRead(recipientID: recipientID) }
                    }
                }
                Spacer()
                if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding()
    }

    private func messageRow(_ message: AgentMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: message.deliveredAt == nil ? "envelope.badge" : "envelope.open")
                .foregroundStyle(message.deliveredAt == nil ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(agentName(message.senderID)) → \(agentName(message.recipientID))").fontWeight(.medium)
                    if message.priority == .priority { Label(agentMessageString("Priority"), systemImage: "exclamationmark").font(.caption).foregroundStyle(.orange) }
                    Spacer()
                    Text(message.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                Text(message.text).textSelection(.enabled)
                if let delivery = message.delivery {
                    Text(deliveryTitle(delivery.state)).font(.caption).foregroundStyle(.secondary)
                    if let response = delivery.response, !response.isEmpty, response.uppercased() != "PASS" {
                        Text(response).font(.callout).textSelection(.enabled)
                    }
                }
            }
            Button(agentMessageString("Reply")) {
                senderID = message.recipientID
                recipientID = message.senderID
                mailbox = .thread
                feedback = l10n("\(agentMessageString("Replying as")) \(agentName(message.recipientID)).")
            }
            .buttonStyle(.borderless)
            .disabled(!activeAgents.contains(where: { $0.id == message.senderID })
                      || !activeAgents.contains(where: { $0.id == message.recipientID }))
        }
        .padding(.vertical, 3)
    }

    private var canSend: Bool {
        guard let senderID, let recipientID else { return false }
        return senderID != recipientID && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func deliveryTitle(_ state: AgentMessageDelivery.State) -> String {
        switch state {
        case .queued: agentMessageString("Queued")
        case .running: agentMessageString("Running")
        case .completed: agentMessageString("Completed")
        case .failed: agentMessageString("Failed")
        case .cancelled: agentMessageString("Cancelled")
        }
    }

    private var emptyDescription: String {
        switch mailbox {
        case .thread: agentMessageString("Send the first message between the selected agents.")
        case .inbox: agentMessageString("The selected recipient has no messages.")
        case .outbox: agentMessageString("The selected sender has not sent any messages.")
        }
    }

    private func recipientLabel(_ profile: AgentProfile) -> String {
        let unread = model.agentMessageUnreadCounts[profile.id, default: 0]
        return unread == 0 ? profile.name : "\(profile.name) (\(unread) \(agentMessageString("unread")))"
    }

    private func agentName(_ id: UUID) -> String {
        model.agents.first(where: { $0.id == id })?.name ?? agentMessageString("Unknown agent")
    }

    private func normalizeSelection() {
        let ids = Set(activeAgents.map(\.id))
        if senderID.map({ !ids.contains($0) }) ?? true { senderID = activeAgents.first?.id }
        if recipientID.map({ !ids.contains($0) || $0 == senderID }) ?? true {
            recipientID = activeAgents.first(where: { $0.id != senderID })?.id
        }
    }

    private func send() {
        guard let senderID, let recipientID else { return }
        let message = draft
        feedback = nil
        Task {
            if await model.sendAgentMessage(senderID: senderID, recipientID: recipientID, text: message, priority: priority) {
                draft = ""
                feedback = agentMessageString("Message sent.")
                mailbox = .thread
            } else {
                feedback = agentMessageString("Not sent. You can edit and retry.")
            }
        }
    }
}

private func agentMessageString(_ key: String) -> String {
    FiliconLocalization.string(key)
}
