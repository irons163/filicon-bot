import AppKit
import SwiftUI
import FiliconComputer

struct RemoteComputerControlsView: View {
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
        Section("Remote computer service") {
            TextField("https://service.example/api/", text: $endpoint)
                .textContentType(.URL)
            HStack {
                TextField("Keychain account", text: $credentialReference)
                TextField("Header", text: $credentialHeader).frame(maxWidth: 180)
                TextField("Scheme", text: $credentialScheme).frame(maxWidth: 120)
            }
            SecureField("New credential (optional)", text: $token)
            DisclosureGroup("Advertised capabilities") {
                capabilityToggle("Lifecycle", .lifecycle)
                capabilityToggle("Recreate", .recreate)
                capabilityToggle("Update preserving data", .update)
                capabilityToggle("Terminal", .terminal)
                capabilityToggle("File transfer", .fileTransfer)
                capabilityToggle("Egress", .egress)
            }
            DisclosureGroup("Isolation trust") {
                TextField("Expected isolation identity (blank to trust on first verified response)", text: $isolationIdentity)
                TextField("Minimum session generation", text: $minimumIsolationGeneration)
            }
            Text("Profiles store only an HTTPS endpoint and opaque Keychain reference. Every lifecycle, terminal, and file response must repeat the same isolation identity, generation, /workspace boundary, and bounded resource declaration. All redirects are rejected; credentials never follow a redirect.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Save and connect") {
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
                Button("Remove configuration", role: .destructive) {
                    Task { await model.clearRemoteComputer(removeCredential: false) }
                }
                Button("Remove configuration and credential", role: .destructive) {
                    Task { await model.clearRemoteComputer(removeCredential: true) }
                }
            }
        }
        .onAppear(perform: restore)

        if !model.remoteComputerEndpoint.isEmpty {
            Section("Remote isolation boundary") {
                HStack {
                    Label(securityStateLabel, systemImage: securityStateIcon)
                        .foregroundStyle(securityStateColor)
                    Spacer()
                    Button("Refresh trust state") { Task { await model.refreshRemoteSecuritySnapshot() } }
                    Button("Reset stored trust", role: .destructive) {
                        Task {
                            await model.resetRemoteIsolationTrust()
                            isolationIdentity = ""
                            minimumIsolationGeneration = "1"
                        }
                    }
                }
                if let declaration = model.remoteSecuritySnapshot.declaration {
                    LabeledContent("Identity", value: declaration.identity).textSelection(.enabled)
                    LabeledContent("Session generation", value: declaration.sessionGeneration.formatted())
                    LabeledContent("Filesystem root", value: declaration.filesystem.root)
                    LabeledContent("Writable roots", value: declaration.filesystem.writableRoots.joined(separator: ", "))
                    LabeledContent("CPU cap", value: "\(declaration.resourceCaps.cpuMillisecondsPerSession.formatted()) ms/session")
                    LabeledContent("Memory cap", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: declaration.resourceCaps.memoryBytes), countStyle: .binary))
                    LabeledContent("Storage cap", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: declaration.resourceCaps.storageBytes), countStyle: .binary))
                    LabeledContent("Maximum sessions", value: declaration.resourceCaps.maximumSessions.formatted())
                }
                if let failure = model.remoteSecuritySnapshot.failure {
                    Text(failure.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                }
                Text("Trust is fail-closed and pinned. Reset only after independently verifying a deliberate server replacement or generation change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Remote lifecycle") {
                if let status = model.remoteComputerStatus {
                    HStack {
                        Label(status.state.rawValue.capitalized, systemImage: statusIcon(status.state))
                        if let percent = status.pullPercent { ProgressView(value: percent, total: 100).frame(width: 120) }
                        if status.imageUpdateAvailable == true { Text("Update available").foregroundStyle(.orange) }
                        Spacer()
                        if status.vncURL != nil {
                            Button("Open remote desktop") { Task { await model.connectRemoteComputerVNC() } }
                        }
                    }
                } else {
                    Text("Status not loaded.").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Refresh") { Task { await model.refreshRemoteComputer() } }
                    Button("Ensure running") { Task { await model.ensureRemoteComputer() } }
                    Button("Update, preserve data") {
                        Task { await model.recreateRemoteComputer(preserveData: true, force: forceOperation) }
                    }
                    Button("Recreate and erase data", role: .destructive) { confirmErase = true }
                    Toggle("Force while busy", isOn: $forceOperation)
                }
                if let operation = model.remoteComputerOperation {
                    HStack {
                        Text("Operation \(operation.id): \(operation.state.rawValue)")
                        if let message = operation.message { Text(message).foregroundStyle(.secondary) }
                        Spacer()
                        if operation.state == .queued || operation.state == .running {
                            Button("Cancel", role: .destructive) { Task { await model.cancelRemoteComputerOperation() } }
                        }
                    }
                    .font(.caption).textSelection(.enabled)
                }
            }
            .confirmationDialog(
                "Recreate this remote computer and erase its data?",
                isPresented: $confirmErase,
                titleVisibility: .visible
            ) {
                Button("Recreate and erase", role: .destructive) {
                    Task { await model.recreateRemoteComputer(preserveData: false, force: forceOperation) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This asks the configured remote service to destroy the remote computer's durable data. This cannot be undone by Filicon.")
            }
        }

        if capabilities.contains(.terminal), !model.remoteComputerEndpoint.isEmpty {
            Section("Remote terminal") {
                TextField("Command as JSON argv", text: $commandJSON, axis: .vertical)
                    .font(.system(.body, design: .monospaced)).lineLimit(1...4)
                HStack {
                    Button("Start") { Task { await model.startRemoteTerminal(commandJSON: commandJSON) } }
                        .disabled(model.remoteTerminalSessionID != nil)
                    if model.remoteTerminalSessionID != nil {
                        Button("Cancel", role: .destructive) { Task { await model.cancelRemoteTerminal() } }
                    }
                    if let code = model.remoteTerminalExitCode { Text("Exited \(code)").foregroundStyle(.secondary) }
                }
                if model.remoteTerminalSessionID != nil {
                    HStack {
                        TextField("Send exact input", text: $terminalInput)
                        Button("Send") {
                            let value = terminalInput
                            terminalInput = ""
                            Task { await model.sendRemoteTerminalInput(value) }
                        }
                        Button("Send line") {
                            let value = terminalInput + "\n"
                            terminalInput = ""
                            Task { await model.sendRemoteTerminalInput(value) }
                        }
                    }
                }
                ScrollView {
                    Text(model.remoteTerminalOutput.isEmpty ? "No output." : model.remoteTerminalOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 100, maxHeight: 260)
            }
        }

        if capabilities.contains(.fileTransfer), !model.remoteComputerEndpoint.isEmpty {
            Section("Remote files") {
                TextField("Absolute remote path", text: $remotePath)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Button("Upload…", action: upload)
                    Button("Download…", action: download)
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
        case .unverified: "Unverified"
        case .trusted: "Isolation declaration trusted"
        case .rejected: "Isolation declaration rejected"
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
