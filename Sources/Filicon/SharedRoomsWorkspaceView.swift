import AppKit
import SwiftUI
import FiliconAgents
import FiliconSharedRooms

struct SharedRoomsWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var displayName = ""
    @State private var transportMode = "local"
    @State private var serverURL = ""
    @State private var credentialReference = "default"
    @State private var serverToken = ""
    @State private var newRoomName = ""
    @State private var inviteText = ""

    var body: some View {
        Form {
            Section("Shared Rooms") {
                Toggle("Enable shared rooms", isOn: Binding(
                    get: { model.sharedRoomsEnabled },
                    set: { enabled in Task { await saveConfiguration(enabled: enabled) } }
                ))
                TextField("Your display name", text: $displayName)
                Picker("Transport", selection: $transportMode) {
                    Text("This Mac").tag("local")
                    Text("HTTPS server").tag("https")
                }
                if transportMode == "https" {
                    TextField("Server URL", text: $serverURL)
                    TextField("Keychain account", text: $credentialReference)
                    SecureField("New access token (optional)", text: $serverToken)
                }
                HStack {
                    Button("Save") { Task { await saveConfiguration(enabled: model.sharedRoomsEnabled) } }
                    Button("Reset identity") {
                        Task { await model.resetSharedRoomIdentity(displayName: displayName) }
                    }
                    Spacer()
                    Text("Session \(model.sharedRoomIdentity.accountGeneration)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Join a room") {
                TextField("Paste a filicon://shared-room/join invite", text: $inviteText)
                Button("Request to join") {
                    let value = inviteText
                    inviteText = ""
                    Task { await model.requestSharedRoomJoin(invite: value) }
                }
                .disabled(inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.sharedRoomsEnabled)
            }

            Section("Create a room") {
                HStack {
                    TextField("Room name", text: $newRoomName)
                    Button("Create") {
                        let value = newRoomName
                        newRoomName = ""
                        Task { await model.createSharedRoom(name: value) }
                    }
                    .disabled(newRoomName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.sharedRoomsEnabled)
                }
            }

            Section("Rooms") {
                if model.sharedRooms.isEmpty {
                    ContentUnavailableView(
                        model.sharedRoomsEnabled ? "No shared rooms" : "Shared Rooms are disabled",
                        systemImage: "person.3.sequence"
                    )
                } else {
                    ForEach(model.sharedRooms) { room in
                        SharedRoomRow(room: room)
                    }
                }
            }

            if let invite = model.lastSharedRoomInvite {
                Section("Latest invite") {
                    Text(invite.url.absoluteString).textSelection(.enabled)
                    Text("Expires (invite.expiresAt, style: .relative)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Copy invite") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shared Rooms")
        .toolbar {
            Button { Task { await model.refreshSharedRooms() } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
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
    @EnvironmentObject private var model: AppModel
    let room: SharedRoomSnapshot

    private var isHost: Bool { room.hostPersonID == model.sharedRoomIdentity.id }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Copy invite") { Task { await model.createSharedRoomInvite(roomID: room.id) } }
                        .disabled(!isHost)
                    Button("Leave", role: .destructive) { Task { await model.leaveSharedRoom(roomID: room.id) } }
                    Spacer()
                    Toggle("Typing", isOn: Binding(
                        get: { room.typingUsers.contains { $0.personID == model.sharedRoomIdentity.id } },
                        set: { value in Task { await model.setSharedRoomTyping(roomID: room.id, isTyping: value) } }
                    ))
                    .toggleStyle(.switch)
                }

                if !room.pendingJoinRequests.isEmpty {
                    GroupBox("Join requests") {
                        ForEach(room.pendingJoinRequests) { request in
                            HStack {
                                Text(request.identity.displayName)
                                Spacer()
                                Button("Approve") {
                                    Task { await model.decideSharedRoomJoin(roomID: room.id, requestID: request.id, approve: true) }
                                }
                                Button("Deny", role: .destructive) {
                                    Task { await model.decideSharedRoomJoin(roomID: room.id, requestID: request.id, approve: false) }
                                }
                            }
                        }
                    }
                    .disabled(!isHost)
                }

                GroupBox("Members") {
                    ForEach(room.members) { member in
                        HStack {
                            Image(systemName: member.kind == .agent ? "cpu" : "person")
                            VStack(alignment: .leading) {
                                Text(member.displayName)
                                Text(member.kind == .agent ? "Agent" : member.id == room.hostPersonID ? "Host" : "Person")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isHost && member.id != room.hostPersonID {
                                Button("Remove", role: .destructive) {
                                    Task { await model.removeSharedRoomMember(roomID: room.id, memberID: member.id) }
                                }
                            }
                        }
                    }
                    if isHost {
                        Menu("Add agent") {
                            ForEach(availableAgents) { agent in
                                Button(agent.name) { Task { await model.addAgentToSharedRoom(roomID: room.id, agent: agent) } }
                            }
                        }
                        .disabled(availableAgents.isEmpty)
                    }
                }

                if !room.typingUsers.isEmpty {
                    Text(room.typingUsers.map(\.displayName).joined(separator: ", ") + " typing…")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
        } label: {
            VStack(alignment: .leading) {
                Text(room.name)
                Text("\(room.members.count) members")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var availableAgents: [AgentProfile] {
        let present = Set(room.members.filter { $0.kind == .agent }.map(\.id))
        return model.agents.filter { $0.archivedAt == nil && !present.contains($0.id) }
    }
}
