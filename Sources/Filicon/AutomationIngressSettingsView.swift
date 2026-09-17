import AppKit
import SwiftUI
import FiliconAutomations

struct AutomationIngressSettingsView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var routeName = ""
    @State private var provider: AutomationIngressProvider = .generic
    @State private var secret = ""
    @State private var bindMode: AutomationIngressBindMode = .loopback
    @State private var port = "0"
    @State private var localNetworkOptIn = false
    @State private var endpoints: [UUID: URL] = [:]

    var body: some View {
        let _ = uiLocale.identifier
        Section(l10n("Webhook ingress")) {
            HStack {
                Label(statusLabel, systemImage: statusSymbol)
                if let boundPort = model.automationIngressStatus.port {
                    Text(l10n("Port \(boundPort)")).foregroundStyle(.secondary)
                }
                Spacer()
                if model.automationIngressStatus.state == .running {
                    Button(l10n("Stop")) { Task { await model.stopAutomationIngress() } }
                } else {
                    Button(l10n("Start")) { Task { await start() } }
                }
            }
            if let error = model.automationIngressStatus.error, !error.isEmpty {
                Text(FiliconLocalization.message(error)).foregroundStyle(.red).textSelection(.enabled)
            }
            Picker(l10n("Bind"), selection: $bindMode) {
                Text(l10n("This Mac only")).tag(AutomationIngressBindMode.loopback)
                Text(l10n("Local network")).tag(AutomationIngressBindMode.localNetwork)
            }
            TextField(l10n("Port (0 chooses an available port)"), text: $port)
            if bindMode == .localNetwork {
                Toggle(l10n("I understand devices on my local network can reach these signed webhook endpoints"), isOn: $localNetworkOptIn)
                Text(l10n("Each request still needs the route-specific HMAC secret. Filicon never exposes webhook secrets in this screen or its audit log."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            Picker(l10n("Provider"), selection: $provider) {
                ForEach(AutomationIngressProvider.allCases) { value in
                    Text(providerLabel(value)).tag(value)
                }
            }
            TextField(l10n("Route name"), text: $routeName)
            SecureField(l10n("Signing secret"), text: $secret)
            Text(provider.authenticationSemantics)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Button(l10n("Add signed route")) {
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
                        Button(l10n("Remove"), role: .destructive) {
                            Task {
                                await model.removeAutomationIngressRoute(id: route.id)
                                endpoints.removeValue(forKey: route.id)
                            }
                        }
                    }
                    if let url = endpoints[route.id] {
                        HStack {
                            Text(url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                            Button(l10n("Copy")) {
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
                DisclosureGroup(l10n("Recent ingress audit")) {
                    ForEach(model.automationIngressAudit) { entry in
                        HStack(alignment: .top) {
                            Image(systemName: entry.disposition == .accepted ? "checkmark.shield" : "xmark.shield")
                                .foregroundStyle(entry.disposition == .accepted ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(entry.reason).textSelection(.enabled)
                                HStack {
                                    Text(entry.provider.map(providerLabel) ?? l10n("Unknown route"))
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
        case .stopped: l10n("Stopped")
        case .starting: l10n("Starting")
        case .running: l10n("Listening")
        case .failed: l10n("Failed")
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
            model.errorMessage = l10n("Enter a port from 0 through 65535.")
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
        case .generic: l10n("Generic HMAC")
        case .slack: l10n("Slack")
        case .github: l10n("GitHub")
        case .microsoftTeams: l10n("Microsoft Teams")
        case .linear: l10n("Linear")
        case .sentry: l10n("Sentry")
        case .pagerDuty: l10n("PagerDuty")
        }
    }
}
