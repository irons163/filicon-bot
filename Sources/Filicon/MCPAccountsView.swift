import SwiftUI
import FiliconMCP

struct MCPAccountsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Server accounts") {
            if model.mcpAccountDefinitions.isEmpty {
                Text("Add an MCP server to create its first account.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.mcpAccountDefinitions) { definition in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(definition.accounts) { slot in
                            MCPAccountEditor(definition: definition, slot: slot)
                            if slot.id != definition.accounts.last?.id { Divider() }
                        }
                        if !definition.managedReadOnly, let source = definition.accounts.first {
                            MCPAddAccountRow(definition: definition, source: source)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(definition.displayName)
                            Text("\(definition.ownership == .team ? "Team" : "User") · \(definition.managedReadOnly ? "Managed, read-only" : "Locally managed")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(definition.accounts.count) account\(definition.accounts.count == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("HTTP accounts support OAuth 2.0 with PKCE or a manually supplied bearer token. Secrets are stored only in macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MCPAddAccountRow: View {
    @EnvironmentObject private var model: AppModel
    let definition: MCPServerDefinition
    let source: MCPAccountSlot
    @State private var accountKey = ""
    @State private var displayName = ""

    var body: some View {
        VStack(alignment: .leading) {
            Text("Add account").font(.caption.bold())
            HStack {
                TextField("Account key", text: $accountKey)
                TextField("Display name", text: $displayName)
                Button("Add") {
                    let values = (accountKey, displayName)
                    accountKey = ""; displayName = ""
                    Task {
                        await model.addMCPAccount(
                            serverID: definition.id,
                            sourceServerIdentifier: source.serverIdentifier,
                            accountKey: values.0, displayName: values.1
                        )
                    }
                }
                .disabled(accountKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct MCPAccountEditor: View {
    @EnvironmentObject private var model: AppModel
    let definition: MCPServerDefinition
    let slot: MCPAccountSlot
    @State private var accountKey = ""
    @State private var displayName = ""
    @State private var bearerToken = ""
    @State private var authorizationEndpoint = ""
    @State private var tokenEndpoint = ""
    @State private var oauthClientID = ""
    @State private var oauthScopes = ""
    @State private var oauthAudience = ""
    @State private var disabledTools = ""
    @State private var customInstructions = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(slot.displayName).font(.headline)
                    Text("\(slot.serverIdentifier) · \(authLabel) · \(runtimeStatus) · exact account: \(slot.accountKey)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(definition.managedReadOnly ? "Managed by team policy" : "User-owned")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !definition.managedReadOnly {
                Picker("Tool approval", selection: Binding(
                    get: { model.mcpPermissionMode(serverIdentifier: slot.serverIdentifier) },
                    set: { value in Task { await model.setMCPPermissionMode(value, serverIdentifier: slot.serverIdentifier) } }
                )) {
                    Text("Always allow safe local reads").tag(MCPPermissionMode.always)
                    Text("Ask every time").tag(MCPPermissionMode.ask)
                    Text("Never").tag(MCPPermissionMode.never)
                }
                Text("Always grants remain scoped to this server account and conversation. Managed policy can only make this more restrictive.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Account key", text: $accountKey)
                    TextField("Display name", text: $displayName)
                    Button("Rename") {
                        Task {
                            await model.renameMCPAccount(
                                serverID: definition.id, accountKey: slot.accountKey,
                                newAccountKey: accountKey, displayName: displayName
                            )
                        }
                    }
                }
                if isHTTPAccount {
                    DisclosureGroup("OAuth 2.0 (PKCE)") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Authorization endpoint (https://…)", text: $authorizationEndpoint)
                                .textContentType(.URL)
                            TextField("Token endpoint (https://…)", text: $tokenEndpoint)
                                .textContentType(.URL)
                            TextField("Public client ID", text: $oauthClientID)
                            TextField("Scopes (space or comma separated)", text: $oauthScopes)
                            TextField("Audience (optional)", text: $oauthAudience)
                            HStack {
                                Button(model.mcpOAuthInProgressSlotIDs.contains(slot.id) ? "Waiting for Browser…" : "Sign In with OAuth") {
                                    Task {
                                        await model.authenticateMCPAccountOAuth(
                                            serverID: definition.id,
                                            accountKey: slot.accountKey,
                                            authorizationEndpoint: authorizationEndpoint,
                                            tokenEndpoint: tokenEndpoint,
                                            clientID: oauthClientID,
                                            scopes: oauthScopes,
                                            audience: oauthAudience
                                        )
                                    }
                                }
                                .disabled(
                                    model.mcpOAuthInProgressSlotIDs.contains(slot.id)
                                    || authorizationEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || tokenEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                )
                                Text("Uses a single-use IPv4 loopback callback. Refresh tokens are not retained.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                    HStack {
                        SecureField("Bearer token (manual alternative)", text: $bearerToken)
                        Button("Use Token") {
                            let token = bearerToken; bearerToken = ""
                            Task { await model.authenticateMCPAccount(serverID: definition.id, accountKey: slot.accountKey, bearerToken: token) }
                        }
                        .disabled(bearerToken.isEmpty)
                        Button(slot.authStatus == .pending ? "Cancel" : "Log Out") {
                            Task { await model.logoutMCPAccount(serverID: definition.id, accountKey: slot.accountKey) }
                        }
                        .disabled(slot.authStatus == .signedOut)
                    }
                }
                TextField("Disabled tools (comma separated)", text: $disabledTools)
                TextEditor(text: $customInstructions).frame(minHeight: 54, maxHeight: 100)
                HStack {
                    Button("Save Preferences") {
                        let disabled = Set(disabledTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                        Task {
                            await model.saveMCPAccountPreferences(
                                serverID: definition.id, accountKey: slot.accountKey,
                                disabledTools: disabled, customInstructions: customInstructions
                            )
                        }
                    }
                    Spacer()
                    Button("Remove Account", role: .destructive) {
                        Task { await model.removeMCPAccount(serverID: definition.id, accountKey: slot.accountKey) }
                    }
                }
            }
            if definition.managedReadOnly {
                LabeledContent("Tool approval", value: "Managed ceiling: Ask or deny")
                    .font(.caption)
            }
        }
        .onAppear { load() }
        .onChange(of: slot) { _, _ in load() }
    }

    private var authLabel: String {
        switch slot.authStatus {
        case .signedOut: "Signed out"
        case .pending: "Authentication pending"
        case .authenticated: "Authenticated"
        case .expired: "Token expired"
        case .failed: "Authentication failed"
        }
    }

    private var runtimeStatus: String {
        switch model.mcpCatalog.statuses[slot.serverIdentifier] {
        case .disabled: "Disabled"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .needsAuth: "Needs authentication"
        case .error(let message): message
        case nil: "Not connected"
        }
    }

    private var isHTTPAccount: Bool {
        guard let config = model.mcpConfigs.first(where: { $0.identifier == slot.serverIdentifier }) else {
            return false
        }
        return switch config.transport {
        case .streamableHTTP, .legacySSE: true
        case .stdio: false
        }
    }

    private func load() {
        accountKey = slot.accountKey
        displayName = slot.displayName
        disabledTools = slot.disabledTools.sorted().joined(separator: ", ")
        customInstructions = slot.customInstructions
    }
}
