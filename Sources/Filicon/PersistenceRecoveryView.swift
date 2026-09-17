import SwiftUI

struct PersistenceRecoveryBanner: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let _ = uiLocale.identifier
        if let message = model.startupBanner {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.rootConnection.phase == .unreachable ? "externaldrive.badge.exclamationmark" : "externaldrive.badge.checkmark")
                    .foregroundStyle(FiliconTheme.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(FiliconLocalization.message(message)).font(.caption.weight(.semibold)).foregroundStyle(FiliconTheme.textPrimary)
                    Text("\(FiliconLocalization.string("Data root")): \(model.dataRoot.path)").font(.caption2).foregroundStyle(FiliconTheme.textSecondary).lineLimit(1)
                }
                Spacer()
                if model.rootConnection.phase == .unreachable || model.rootConnection.phase == .reconnecting {
                    Button(FiliconLocalization.string("Retry"), action: model.retryRootConnection).controlSize(.small)
                }
                Button(FiliconLocalization.string("Reload")) { Task { await model.reloadRootWorkspace() } }.controlSize(.small)
                Button(FiliconLocalization.string("Copy Diagnostics"), action: model.copyRootDiagnostics).controlSize(.small)
                Button {
                    model.dismissStartupBanner()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help(FiliconLocalization.string("Dismiss this notice"))
                .accessibilityLabel(FiliconLocalization.string("Dismiss storage notice"))
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(FiliconTheme.warning.opacity(0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(FiliconTheme.warning.opacity(0.24)).frame(height: 0.7) }
            .accessibilityIdentifier("persistence-recovery-banner")
        } else if model.rootConnection.phase == .loading || model.rootConnection.phase == .reconnecting {
            HStack {
                ProgressView().controlSize(.small)
                Text(FiliconLocalization.string(model.rootConnection.phase == .loading ? l10n("Opening workspace…") : l10n("Reconnecting workspace…")))
            }
                .font(.caption).foregroundStyle(FiliconTheme.textSecondary).padding(6).frame(maxWidth: .infinity).background(FiliconTheme.accent.opacity(0.08))
        }
    }
}

struct PersistenceRecoverySettingsSection: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let _ = uiLocale.identifier
        Section(FiliconLocalization.string("Storage and recovery")) {
            LabeledContent(FiliconLocalization.string("Data root")) { Text(model.dataRoot.path).textSelection(.enabled).lineLimit(2) }
            LabeledContent(
                FiliconLocalization.string("Route"),
                value: "\(FiliconLocalization.string(model.startupSettlement.route.rawValue)) · \(FiliconLocalization.string(model.startupSettlement.reason.rawValue))"
            )
            LabeledContent(
                FiliconLocalization.string("Connection"),
                value: FiliconLocalization.string(model.rootConnection.phase.rawValue.capitalized)
            )
            if let usage = model.quotaUsage {
                LabeledContent(
                    FiliconLocalization.string("App state usage"),
                    value: "\(usage.committedBytes.formatted()) \(FiliconLocalization.string("bytes"))"
                )
            }
            if let report = model.persistenceRecoveryReport {
                Text(report.summary).font(.caption).foregroundStyle(.secondary)
                LabeledContent(FiliconLocalization.string("Recovery generation"), value: report.generation.uuidString.lowercased())
                LabeledContent(FiliconLocalization.string("Recovered"), value: "\(report.recoveredConversations) conversations, \(report.recoveredMessages) messages")
                if !report.rejectedRows.isEmpty { LabeledContent(FiliconLocalization.string("Isolated rows"), value: report.rejectedRows.count.formatted()) }
                if report.quarantineDirectory != nil {
                    Button(FiliconLocalization.string("Show Preserved Original in Finder"), action: model.openRecoveryQuarantine)
                    Text(FiliconLocalization.string("Filicon never deletes quarantined original database bytes from this screen.")).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(FiliconLocalization.string("Rebuild Conversation Search Index")) { Task { await model.rebuildConversationSearchIndex() } }
                Button(FiliconLocalization.string("Reload Workspace")) { Task { await model.reloadRootWorkspace() } }
                Button(FiliconLocalization.string("Copy Bounded Diagnostics"), action: model.copyRootDiagnostics)
            }
        }
    }
}
