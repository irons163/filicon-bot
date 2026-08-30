import AppKit
import SwiftUI
import FiliconAutomations

struct AutomationIngressSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var routeName = ""
    @State private var provider: AutomationIngressProvider = .generic
    @State private var secret = ""
    @State private var bindMode: AutomationIngressBindMode = .loopback
    @State private var port = "0"
    @State private var localNetworkOptIn = false
    @State private var endpoints: [UUID: URL] = [:]

    var body: some View {
        Section("Webhook ingress") {
            HStack {
                Label(statusLabel, systemImage: statusSymbol)
                if let boundPort = model.automationIngressStatus.port {
                    Text("Port \(boundPort)").foregroundStyle(.secondary)
                }
                Spacer()
                if model.automationIngressStatus.state == .running {
                    Button("Stop") { Task { await model.stopAutomationIngress() } }
                } else {
                    Button("Start") { Task { await start() } }
                }
            }
            if let error = model.automationIngressStatus.error, !error.isEmpty {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Picker("Bind", selection: $bindMode) {
                Text("This Mac only").tag(AutomationIngressBindMode.loopback)
                Text("Local network").tag(AutomationIngressBindMode.localNetwork)
            }
            TextField("Port (0 chooses an available port)", text: $port)
            if bindMode == .localNetwork {
                Toggle("I understand devices on my local network can reach these signed webhook endpoints", isOn: $localNetworkOptIn)
                Text("Each request still needs the route-specific HMAC secret. Filicon never exposes webhook secrets in this screen or its audit log.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Picker("Provider", selection: $provider) {
                ForEach(AutomationIngressProvider.allCases) { value in
                    Text(providerLabel(value)).tag(value)
                }
            }
            TextField("Route name", text: $routeName)
            SecureField("Signing secret", text: $secret)
            Text(provider.authenticationSemantics)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button("Add signed route") {
                let values = (routeName, provider, secret)
                routeName = ""
                secret = ""
                Task {
                    await model.saveAutomationIngressRoute(name: values.0, provider: values.1, secret: values.2)
                    await refreshEndpoints()
                }
            }
            .disabled(routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || secret.isEmpty)

            ForEach(model.automationIngressRoutes) { route in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(route.name)
                            Text(providerLabel(route.provider)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task {
                                await model.removeAutomationIngressRoute(id: route.id)
                                endpoints.removeValue(forKey: route.id)
                            }
                        }
                    }
                    if let url = endpoints[route.id] {
                        HStack {
                            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            }
                        }
                    } else {
                        Text(route.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }

            if !model.automationIngressAudit.isEmpty {
                DisclosureGroup("Recent ingress audit") {
                    ForEach(model.automationIngressAudit) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: entry.disposition == .accepted ? "checkmark.shield" : "xmark.shield")
                                .foregroundStyle(entry.disposition == .accepted ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(entry.reason).textSelection(.enabled)
                                HStack {
                                    Text(entry.provider.map(providerLabel) ?? "Unknown route")
                                    Text(entry.receivedAt, style: .relative)
                                    if let externalID = entry.externalEventID { Text(externalID).textSelection(.enabled) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task {
            bindMode = model.automationIngressStatus.bindMode
            localNetworkOptIn = UserDefaults.standard.bool(forKey: "FiliconAutomationIngressLANOptIn")
            await refreshEndpoints()
        }
        .onChange(of: model.automationIngressStatus) { _, _ in Task { await refreshEndpoints() } }
    }

    private var statusLabel: String {
        switch model.automationIngressStatus.state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Listening"
        case .failed: "Failed"
        }
    }

    private var statusSymbol: String {
        switch model.automationIngressStatus.state {
        case .running: "antenna.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle"
        case .starting: "hourglass"
        case .stopped: "stop.circle"
        }
    }

    private func start() async {
        guard let requestedPort = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            model.errorMessage = "Enter a port from 0 through 65535."
            return
        }
        await model.startAutomationIngress(
            bindMode: bindMode,
            port: requestedPort,
            lanOptIn: bindMode == .localNetwork && localNetworkOptIn
        )
        await refreshEndpoints()
    }

    @MainActor
    private func refreshEndpoints() async {
        var values: [UUID: URL] = [:]
        for route in model.automationIngressRoutes {
            if let endpoint = await model.automationIngressEndpoint(routeID: route.id) {
                values[route.id] = endpoint
            }
        }
        endpoints = values
    }

    private func providerLabel(_ value: AutomationIngressProvider) -> String {
        switch value {
        case .generic: "Generic HMAC"
        case .slack: "Slack"
        case .github: "GitHub"
        case .microsoftTeams: "Microsoft Teams"
        case .linear: "Linear"
        case .sentry: "Sentry"
        case .pagerDuty: "PagerDuty"
        }
    }
}
