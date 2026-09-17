import AppKit
import SwiftUI
import FiliconComputer

struct RemoteComputerControlsView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var endpoint = ""
    @State private var credentialReference = "default"
    @State private var credentialHeader = "Authorization"
    @State private var credentialScheme = "Bearer"
    @State private var token = ""
    @State private var capabilities: RemoteComputerCapabilities = []
    @State private var isolationIdentity = ""
    @State private var minimumIsolationGeneration = "1"
    @State private var forceOperation = false
    @State private var confirmErase = false
    @State private var commandJSON = "[\"/usr/bin/env\",\"pwd\"]"
    @State private var terminalInput = ""
    @State private var remotePath = "/workspace/file.dat"

    var body: some View {
        let _ = uiLocale.identifier
        Section(l10n("Remote computer service")) {
            TextField(l10n("https://service.example/api/"), text: $endpoint)
                .textContentType(.URL)
            HStack {
                TextField(l10n("Keychain account"), text: $credentialReference)
                TextField(l10n("Header"), text: $credentialHeader).frame(maxWidth: 180)
                TextField(l10n("Scheme"), text: $credentialScheme).frame(maxWidth: 120)
            }
            SecureField(l10n("New credential (optional)"), text: $token)
            DisclosureGroup(l10n("Advertised capabilities")) {
                capabilityToggle("Lifecycle", .lifecycle)
                capabilityToggle("Recreate", .recreate)
                capabilityToggle("Update preserving data", .update)
                capabilityToggle("Terminal", .terminal)
                capabilityToggle("File transfer", .fileTransfer)
                capabilityToggle("Egress", .egress)
            }
            DisclosureGroup(l10n("Isolation trust")) {
                TextField(l10n("Expected isolation identity (blank to trust on first verified response)"), text: $isolationIdentity)
                TextField(l10n("Minimum session generation"), text: $minimumIsolationGeneration)
            }
            Text(l10n("Profiles store only an HTTPS endpoint and opaque Keychain reference. Every lifecycle, terminal, and file response must repeat the same isolation identity, generation, /workspace boundary, and bounded resource declaration. All redirects are rejected; credentials never follow a redirect."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(l10n("Save and connect")) {
                    let newToken = token
                    token = ""
                    Task {
                        await model.configureRemoteComputer(
                            endpoint: endpoint, credentialReference: credentialReference,
                            credentialHeader: credentialHeader, credentialScheme: credentialScheme,
                            token: newToken, capabilities: capabilities,
                            isolationIdentity: isolationIdentity,
                            minimumIsolationGeneration: UInt64(minimumIsolationGeneration) ?? 0
                        )
                    }
                }
                .disabled(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(l10n("Remove configuration"), role: .destructive) {
                    Task { await model.clearRemoteComputer(removeCredential: false) }
                }
                Button(l10n("Remove configuration and credential"), role: .destructive) {
                    Task { await model.clearRemoteComputer(removeCredential: true) }
                }
            }
        }
        .onAppear(perform: restore)

        if !model.remoteComputerEndpoint.isEmpty {
            Section(l10n("Remote isolation boundary")) {
                HStack {
                    Label(securityStateLabel, systemImage: securityStateIcon)
                        .foregroundStyle(securityStateColor)
                    Spacer()
                    Button(l10n("Refresh trust state")) { Task { await model.refreshRemoteSecuritySnapshot() } }
                    Button(l10n("Reset stored trust"), role: .destructive) {
                        Task {
                            await model.resetRemoteIsolationTrust()
                            isolationIdentity = ""
                            minimumIsolationGeneration = "1"
                        }
                    }
                }
                if let declaration = model.remoteSecuritySnapshot.declaration {
                    LabeledContent(l10n("Identity"), value: declaration.identity).textSelection(.enabled)
                    LabeledContent(l10n("Session generation"), value: declaration.sessionGeneration.formatted())
                    LabeledContent(l10n("Filesystem root"), value: declaration.filesystem.root)
                    LabeledContent(l10n("Writable roots"), value: declaration.filesystem.writableRoots.joined(separator: ", "))
                    LabeledContent(l10n("CPU cap"), value: "\(declaration.resourceCaps.cpuMillisecondsPerSession.formatted()) ms/session")
                    LabeledContent(l10n("Memory cap"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: declaration.resourceCaps.memoryBytes), countStyle: .binary))
                    LabeledContent(l10n("Storage cap"), value: ByteCountFormatter.string(fromByteCount: Int64(clamping: declaration.resourceCaps.storageBytes), countStyle: .binary))
                    LabeledContent(l10n("Maximum sessions"), value: declaration.resourceCaps.maximumSessions.formatted())
                }
                if let failure = model.remoteSecuritySnapshot.failure {
                    Text(FiliconLocalization.message(failure.localizedDescription)).foregroundStyle(.red).textSelection(.enabled)
                }
                Text(l10n("Trust is fail-closed and pinned. Reset only after independently verifying a deliberate server replacement or generation change."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(l10n("Remote lifecycle")) {
                if let status = model.remoteComputerStatus {
                    HStack {
                        Label(FiliconLocalization.string(status.state.rawValue.capitalized), systemImage: statusIcon(status.state))
                        if let percent = status.pullPercent { ProgressView(value: percent, total: 100).frame(width: 120) }
                        if status.imageUpdateAvailable == true { Text(l10n("Update available")).foregroundStyle(.orange) }
                        Spacer()
                        if status.vncURL != nil {
                            Button(l10n("Open remote desktop")) { Task { await model.connectRemoteComputerVNC() } }
                        }
                    }
                } else {
                    Text(l10n("Status not loaded.")).foregroundStyle(.secondary)
                }
                HStack {
                    Button(l10n("Refresh")) { Task { await model.refreshRemoteComputer() } }
                    Button(l10n("Ensure running")) { Task { await model.ensureRemoteComputer() } }
                    Button(l10n("Update, preserve data")) {
                        Task { await model.recreateRemoteComputer(preserveData: true, force: forceOperation) }
                    }
                    Button(l10n("Recreate and erase data"), role: .destructive) { confirmErase = true }
                    Toggle(l10n("Force while busy"), isOn: $forceOperation)
                }
                if let operation = model.remoteComputerOperation {
                    HStack {
                        Text(l10n("Operation \(operation.id): \(operation.state.rawValue)"))
                        if let message = operation.message { Text(message).foregroundStyle(.secondary) }
                        Spacer()
                        if operation.state == .queued || operation.state == .running {
                            Button(l10n("Cancel"), role: .destructive) { Task { await model.cancelRemoteComputerOperation() } }
                        }
                    }
                    .font(.caption).textSelection(.enabled)
                }
            }
            .confirmationDialog(
                l10n("Recreate this remote computer and erase its data?"),
                isPresented: $confirmErase,
                titleVisibility: .visible
            ) {
                Button(l10n("Recreate and erase"), role: .destructive) {
                    Task { await model.recreateRemoteComputer(preserveData: false, force: forceOperation) }
                }
                Button(l10n("Cancel"), role: .cancel) {}
            } message: {
                Text(l10n("This asks the configured remote service to destroy the remote computer's durable data. This cannot be undone by Filicon."))
            }
        }

        if capabilities.contains(.terminal), !model.remoteComputerEndpoint.isEmpty {
            Section(l10n("Remote terminal")) {
                TextField(l10n("Command as JSON argv"), text: $commandJSON, axis: .vertical)
                    .font(.system(.body, design: .monospaced)).lineLimit(1...4)
                HStack {
                    Button(l10n("Start")) { Task { await model.startRemoteTerminal(commandJSON: commandJSON) } }
                        .disabled(model.remoteTerminalSessionID != nil)
                    if model.remoteTerminalSessionID != nil {
                        Button(l10n("Cancel"), role: .destructive) { Task { await model.cancelRemoteTerminal() } }
                    }
                    if let code = model.remoteTerminalExitCode { Text(l10n("Exited \(code)")).foregroundStyle(.secondary) }
                }
                if model.remoteTerminalSessionID != nil {
                    HStack {
                        TextField(l10n("Send exact input"), text: $terminalInput)
                        Button(l10n("Send")) {
                            let value = terminalInput
                            terminalInput = ""
                            Task { await model.sendRemoteTerminalInput(value) }
                        }
                        Button(l10n("Send line")) {
                            let value = terminalInput + "\n"
                            terminalInput = ""
                            Task { await model.sendRemoteTerminalInput(value) }
                        }
                    }
                }
                ScrollView {
                    Text(model.remoteTerminalOutput.isEmpty ? l10n("No output.") : model.remoteTerminalOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 260)
            }
        }

        if capabilities.contains(.fileTransfer), !model.remoteComputerEndpoint.isEmpty {
            Section(l10n("Remote files")) {
                TextField(l10n("Absolute remote path"), text: $remotePath)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button(l10n("Upload…"), action: upload)
                    Button(l10n("Download…"), action: download)
                    if let status = model.remoteFileTransferStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func capabilityToggle(_ label: String, _ capability: RemoteComputerCapabilities) -> some View {
        Toggle(label, isOn: Binding(
            get: { capabilities.contains(capability) },
            set: { enabled in
                if enabled { capabilities.insert(capability) }
                else { capabilities.remove(capability) }
            }
        ))
    }

    private func statusIcon(_ state: RemoteComputerState) -> String {
        switch state {
        case .running: "checkmark.circle.fill"
        case .pulling: "arrow.down.circle"
        case .hibernated: "moon.zzz"
        case .off: "power"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.uploadRemoteFile(localURL: url, remotePath: remotePath) }
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: remotePath).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.downloadRemoteFile(remotePath: remotePath, localURL: url) }
    }

    private func restore() {
        endpoint = model.remoteComputerEndpoint
        credentialReference = model.remoteComputerCredentialReference
        credentialHeader = model.remoteComputerCredentialHeader
        credentialScheme = model.remoteComputerCredentialScheme
        capabilities = model.remoteComputerCapabilities
        isolationIdentity = model.remoteIsolationRequiredIdentity
        minimumIsolationGeneration = model.remoteIsolationMinimumGeneration.formatted(.number.grouping(.never))
    }

    private var securityStateLabel: String {
        switch model.remoteSecuritySnapshot.state {
        case .unverified: l10n("Unverified")
        case .trusted: l10n("Isolation declaration trusted")
        case .rejected: l10n("Isolation declaration rejected")
        }
    }

    private var securityStateIcon: String {
        switch model.remoteSecuritySnapshot.state {
        case .unverified: "questionmark.shield"
        case .trusted: "checkmark.shield.fill"
        case .rejected: "xmark.shield.fill"
        }
    }

    private var securityStateColor: Color {
        switch model.remoteSecuritySnapshot.state {
        case .unverified: .secondary
        case .trusted: .green
        case .rejected: .red
        }
    }
}
