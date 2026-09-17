import AppKit
import SwiftUI
import FiliconAgents
import FiliconSharedRooms

struct SharedRoomsWorkspaceView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var displayName = ""
    @State private var transportMode = "local"
    @State private var serverURL = ""
    @State private var credentialReference = "default"
    @State private var serverToken = ""
    @State private var newRoomName = ""
    @State private var inviteText = ""

    var body: some View {
        let _ = uiLocale.identifier
        Form {
            Section(l10n("Shared Rooms")) {
                Toggle(l10n("Enable shared rooms"), isOn: Binding(
                    get: { model.sharedRoomsEnabled },
                    set: { enabled in Task { await saveConfiguration(enabled: enabled) } }
                ))
                TextField(l10n("Your display name"), text: $displayName)
                Picker(l10n("Transport"), selection: $transportMode) {
                    Text(l10n("This Mac")).tag("local")
                    Text(l10n("HTTPS server")).tag("https")
                }
                if transportMode == "https" {
                    TextField(l10n("Server URL"), text: $serverURL)
                    TextField(l10n("Keychain account"), text: $credentialReference)
                    SecureField(l10n("New access token (optional)"), text: $serverToken)
                }
                HStack {
                    Button(l10n("Save")) { Task { await saveConfiguration(enabled: model.sharedRoomsEnabled) } }
                    Button(l10n("Reset identity")) {
                        Task { await model.resetSharedRoomIdentity(displayName: displayName) }
                    }
                    Spacer()
                    Text(l10n("Session \(model.sharedRoomIdentity.accountGeneration)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(l10n("Join a room")) {
                TextField(l10n("Paste a filicon://shared-room/join invite"), text: $inviteText)
                Button(l10n("Request to join")) {
                    let value = inviteText
                    inviteText = ""
                    Task { await model.requestSharedRoomJoin(invite: value) }
                }
                .disabled(inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.sharedRoomsEnabled)
            }

            Section(l10n("Create a room")) {
                HStack {
                    TextField(l10n("Room name"), text: $newRoomName)
                    Button(l10n("Create")) {
                        let value = newRoomName
                        newRoomName = ""
                        Task { await model.createSharedRoom(name: value) }
                    }
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.sharedRoomsEnabled)
                }
            }

            Section(l10n("Rooms")) {
                if model.sharedRooms.isEmpty {
                    ContentUnavailableView(
                        model.sharedRoomsEnabled ? l10n("No shared rooms") : l10n("Shared Rooms are disabled"),
                        systemImage: "person.3.sequence"
                    )
                } else {
                    ForEach(model.sharedRooms) { room in
                        SharedRoomRow(room: room)
                    }
                }
            }

            if let invite = model.lastSharedRoomInvite {
                Section(l10n("Latest invite")) {
                    Text(invite.url.absoluteString).textSelection(.enabled)
                    Text(l10n("Expires \(invite.expiresAt.formatted(.dateTime.locale(uiLocale)))"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(l10n("Copy invite")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(l10n("Shared Rooms"))
        .toolbar {
            Button { Task { await model.refreshSharedRooms() } } label: {
                Label(l10n("Refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(!model.sharedRoomsEnabled)
        }
        .task {
            displayName = model.sharedRoomIdentity.displayName
            transportMode = model.sharedRoomTransportMode
            serverURL = model.sharedRoomServerURL
            credentialReference = model.sharedRoomCredentialReference
            await model.refreshSharedRooms()
        }
    }

    private func saveConfiguration(enabled: Bool) async {
        let token = serverToken
        serverToken = ""
        await model.configureSharedRooms(
            enabled: enabled,
            displayName: displayName,
            transportMode: transportMode,
            serverURL: serverURL,
            credentialReference: credentialReference,
            token: token
        )
    }
}

private struct SharedRoomRow: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let room: SharedRoomSnapshot

    private var isHost: Bool { room.hostPersonID == model.sharedRoomIdentity.id }

    var body: some View {
        let _ = uiLocale.identifier
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(l10n("Copy invite")) { Task { await model.createSharedRoomInvite(roomID: room.id) } }
                        .disabled(!isHost)
                    Button(l10n("Leave"), role: .destructive) { Task { await model.leaveSharedRoom(roomID: room.id) } }
                    Spacer()
                    Toggle(l10n("Typing"), isOn: Binding(
                        get: { room.typingUsers.contains { $0.personID == model.sharedRoomIdentity.id } },
                        set: { value in Task { await model.setSharedRoomTyping(roomID: room.id, isTyping: value) } }
                    ))
                    .toggleStyle(.switch)
                }

                if !room.pendingJoinRequests.isEmpty {
                    GroupBox(l10n("Join requests")) {
                        ForEach(room.pendingJoinRequests) { request in
                            HStack {
                                Text(request.identity.displayName)
                                Spacer()
                                Button(l10n("Approve")) {
                                    Task { await model.decideSharedRoomJoin(roomID: room.id, requestID: request.id, approve: true) }
                                }
                                Button(l10n("Deny"), role: .destructive) {
                                    Task { await model.decideSharedRoomJoin(roomID: room.id, requestID: request.id, approve: false) }
                                }
                            }
                        }
                    }
                    .disabled(!isHost)
                }

                GroupBox(l10n("Members")) {
                    ForEach(room.members) { member in
                        HStack {
                            Image(systemName: member.kind == .agent ? "cpu" : "person")
                            VStack(alignment: .leading) {
                                Text(member.displayName)
                                Text(member.kind == .agent ? l10n("Agent") : member.id == room.hostPersonID ? l10n("Host") : l10n("Person"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isHost && member.id != room.hostPersonID {
                                Button(l10n("Remove"), role: .destructive) {
                                    Task { await model.removeSharedRoomMember(roomID: room.id, memberID: member.id) }
                                }
                            }
                        }
                    }
                    if isHost {
                        Menu(l10n("Add agent")) {
                            ForEach(availableAgents) { agent in
                                Button(agent.name) { Task { await model.addAgentToSharedRoom(roomID: room.id, agent: agent) } }
                            }
                        }
                        .disabled(availableAgents.isEmpty)
                    }
                }

                if !room.typingUsers.isEmpty {
                    Text(room.typingUsers.map(\.displayName).joined(separator: ", ") + l10n(" typing…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading) {
                Text(room.name)
                Text(l10n("\(room.members.count) members"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var availableAgents: [AgentProfile] {
        let present = Set(room.members.filter { $0.kind == .agent }.map(\.id))
        return model.agents.filter { $0.archivedAt == nil && !present.contains($0.id) }
    }
}
