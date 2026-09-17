import SwiftUI
import FiliconMCP

struct MCPAccountsView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let _ = uiLocale.identifier
        Section(l10n("Server accounts")) {
            if model.mcpAccountDefinitions.isEmpty {
                Text(l10n("Add an MCP server to create its first account."))
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
                        Text(l10n("Accounts: \(definition.accounts.count)"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(l10n("HTTP accounts support OAuth 2.0 with PKCE or a manually supplied bearer token. Secrets are stored only in macOS Keychain."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MCPAddAccountRow: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    let definition: MCPServerDefinition
    let source: MCPAccountSlot
    @State private var accountKey = ""
    @State private var displayName = ""

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading) {
            Text(l10n("Add account")).font(.caption.bold())
            HStack {
                TextField(l10n("Account key"), text: $accountKey)
                TextField(l10n("Display name"), text: $displayName)
                Button(l10n("Add")) {
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
    @Environment(\.locale) private var uiLocale
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
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading) {
                    Text(slot.displayName).font(.headline)
                    Text(l10n("\(slot.serverIdentifier) · \(authLabel) · \(runtimeStatus) · exact account: \(slot.accountKey)"))
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Text(definition.managedReadOnly ? l10n("Managed by team policy") : l10n("User-owned"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !definition.managedReadOnly {
                Picker(l10n("Tool approval"), selection: Binding(
                    get: { model.mcpPermissionMode(serverIdentifier: slot.serverIdentifier) },
                    set: { value in Task { await model.setMCPPermissionMode(value, serverIdentifier: slot.serverIdentifier) } }
                )) {
                    Text(l10n("Always allow safe local reads")).tag(MCPPermissionMode.always)
                    Text(l10n("Ask every time")).tag(MCPPermissionMode.ask)
                    Text(l10n("Never")).tag(MCPPermissionMode.never)
                }
                Text(l10n("Always grants remain scoped to this server account and conversation. Managed policy can only make this more restrictive."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField(l10n("Account key"), text: $accountKey)
                    TextField(l10n("Display name"), text: $displayName)
                    Button(l10n("Rename")) {
                        Task {
                            await model.renameMCPAccount(
                                serverID: definition.id, accountKey: slot.accountKey,
                                newAccountKey: accountKey, displayName: displayName
                            )
                        }
                    }
                }
                if isHTTPAccount {
                    DisclosureGroup(l10n("OAuth 2.0 (PKCE)")) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField(l10n("Authorization endpoint (https://…)"), text: $authorizationEndpoint)
                                .textContentType(.URL)
                            TextField(l10n("Token endpoint (https://…)"), text: $tokenEndpoint)
                                .textContentType(.URL)
                            TextField(l10n("Public client ID"), text: $oauthClientID)
                            TextField(l10n("Scopes (space or comma separated)"), text: $oauthScopes)
                            TextField(l10n("Audience (optional)"), text: $oauthAudience)
                            HStack {
                                Button(model.mcpOAuthInProgressSlotIDs.contains(slot.id) ? l10n("Waiting for Browser…") : l10n("Sign In with OAuth")) {
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
                                Text(l10n("Uses a single-use IPv4 loopback callback. Refresh tokens are not retained."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 6)
                    }
                    HStack {
                        SecureField(l10n("Bearer token (manual alternative)"), text: $bearerToken)
                        Button(l10n("Use Token")) {
                            let token = bearerToken; bearerToken = ""
                            Task { await model.authenticateMCPAccount(serverID: definition.id, accountKey: slot.accountKey, bearerToken: token) }
                        }
                        .disabled(bearerToken.isEmpty)
                        Button(slot.authStatus == .pending ? l10n("Cancel") : l10n("Log Out")) {
                            Task { await model.logoutMCPAccount(serverID: definition.id, accountKey: slot.accountKey) }
                        }
                        .disabled(slot.authStatus == .signedOut)
                    }
                }
                TextField(l10n("Disabled tools (comma separated)"), text: $disabledTools)
                TextEditor(text: $customInstructions).frame(minHeight: 54, maxHeight: 100)
                HStack {
                    Button(l10n("Save Preferences")) {
                        let disabled = Set(disabledTools.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                        Task {
                            await model.saveMCPAccountPreferences(
                                serverID: definition.id, accountKey: slot.accountKey,
                                disabledTools: disabled, customInstructions: customInstructions
                            )
                        }
                    }
                    Spacer()
                    Button(l10n("Remove Account"), role: .destructive) {
                        Task { await model.removeMCPAccount(serverID: definition.id, accountKey: slot.accountKey) }
                    }
                }
            }
            if definition.managedReadOnly {
                LabeledContent(l10n("Tool approval"), value: "Managed ceiling: Ask or deny")
                    .font(.caption)
            }
        }
        .onAppear { load() }
        .onChange(of: slot) { _, _ in load() }
    }

    private var authLabel: String {
        switch slot.authStatus {
        case .signedOut: l10n("Signed out")
        case .pending: l10n("Authentication pending")
        case .authenticated: l10n("Authenticated")
        case .expired: l10n("Token expired")
        case .failed: l10n("Authentication failed")
        }
    }

    private var runtimeStatus: String {
        switch model.mcpCatalog.statuses[slot.serverIdentifier] {
        case .disabled: l10n("Disabled")
        case .connecting: l10n("Connecting")
        case .connected: l10n("Connected")
        case .needsAuth: l10n("Needs authentication")
        case .error(let message): message
        case nil: l10n("Not connected")
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
