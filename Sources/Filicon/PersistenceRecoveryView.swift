import SwiftUI

struct PersistenceRecoveryBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let message = model.startupBanner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.rootConnection.phase == .unreachable ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark")
                    .foregroundStyle(FiliconTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).font(.caption.weight(.semibold)).foregroundStyle(FiliconTheme.textPrimary)
                    Text("Data root: \(model.dataRoot.path)").font(.caption2).foregroundStyle(FiliconTheme.textSecondary).lineLimit(1)
                }
                Spacer()
                if model.rootConnection.phase == .unreachable || model.rootConnection.phase == .reconnecting {
                    Button("Retry", action: model.retryRootConnection).controlSize(.small)
                }
                Button("Reload") { Task { await model.reloadRootWorkspace() } }.controlSize(.small)
                Button("Copy Diagnostics", action: model.copyRootDiagnostics).controlSize(.small)
                Button {
                    model.dismissStartupBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Dismiss this notice")
                .accessibilityLabel("Dismiss storage notice")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(FiliconTheme.warning.opacity(0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(FiliconTheme.warning.opacity(0.24)).frame(height: 0.7) }
            .accessibilityIdentifier("persistence-recovery-banner")
        } else if model.rootConnection.phase == .loading || model.rootConnection.phase == .reconnecting {
            HStack { ProgressView().controlSize(.small); Text(model.rootConnection.phase == .loading ? "Opening workspace…" : "Reconnecting workspace…") }
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary).padding(6).frame(maxWidth: .infinity).background(FiliconTheme.accent.opacity(0.08))
        }
    }
}

struct PersistenceRecoverySettingsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Storage and recovery") {
            LabeledContent("Data root") { Text(model.dataRoot.path).textSelection(.enabled).lineLimit(2) }
            LabeledContent("Route", value: "\(model.startupSettlement.route.rawValue) · \(model.startupSettlement.reason.rawValue)")
            LabeledContent("Connection", value: model.rootConnection.phase.rawValue.capitalized)
            if let usage = model.quotaUsage {
                LabeledContent("App state usage", value: ByteCountFormatter.string(fromByteCount: usage.committedBytes, countStyle: .file))
            }
            if let report = model.persistenceRecoveryReport {
                Text(report.summary).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Recovery generation", value: report.generation.uuidString.lowercased())
                LabeledContent("Recovered", value: "\(report.recoveredConversations) conversations, \(report.recoveredMessages) messages")
                if !report.rejectedRows.isEmpty { LabeledContent("Isolated rows", value: report.rejectedRows.count.formatted()) }
                if report.quarantineDirectory != nil {
                    Button("Show Preserved Original in Finder", action: model.openRecoveryQuarantine)
                    Text("Filicon never deletes quarantined original database bytes from this screen.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Rebuild Conversation Search Index") { Task { await model.rebuildConversationSearchIndex() } }
                Button("Reload Workspace") { Task { await model.reloadRootWorkspace() } }
                Button("Copy Bounded Diagnostics", action: model.copyRootDiagnostics)
            }
        }
    }
}
