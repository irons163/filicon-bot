import AppKit
import SwiftUI
import FiliconAppServices

struct NotificationTrayActionResult: Sendable {
    var succeeded: Bool
    var message: String?
}

struct InAppNotificationStack: View {
    let trays: [InAppNotificationTray]
    let onClear: () -> Void
    let onDismiss: (UUID) -> Void
    let onAction: (NotificationTrayAction) async -> NotificationTrayActionResult

    var body: some View {
        if !trays.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                if trays.count > 1 {
                    Button("Clear All", action: onClear)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                ForEach(trays) { tray in
                    NotificationTrayCard(tray: tray, onDismiss: onDismiss, onAction: onAction)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notifications")
        }
    }
}

private struct NotificationTrayCard: View {
    let tray: InAppNotificationTray
    let onDismiss: (UUID) -> Void
    let onAction: (NotificationTrayAction) async -> NotificationTrayActionResult
    @State private var copiedRequestID = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tray.title).fontWeight(.semibold)
                    if let count = tray.count, count > 1 {
                        Text("×\(count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityLabel("Occurred \(count) times")
                    }
                }
                if !tray.detail.isEmpty {
                    Text(tray.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if tray.errorKind != nil || tray.rawDetail != nil {
                    DisclosureGroup("Details") {
                        VStack(alignment: .leading, spacing: 3) {
                            if let errorKind = tray.errorKind {
                                Text(errorKind)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if let rawDetail = tray.rawDetail, !rawDetail.isEmpty {
                                Text(rawDetail)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 3)
                    }
                    .font(.caption)
                }
                if !tray.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(Array(tray.actions.enumerated()), id: \.offset) { _, action in
                            NotificationTrayActionButton(action: action, onAction: onAction)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                if let requestID = tray.requestID {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        copiedRequestID = pasteboard.setString(requestID, forType: .string)
                    } label: {
                        Image(systemName: copiedRequestID ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help(copiedRequestID ? "Request ID copied" : "Copy request ID")
                    .accessibilityLabel(copiedRequestID ? "Request ID copied" : "Copy request ID")
                }
                Button { onDismiss(tray.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Dismiss notification")
                    .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(12)
        .frame(maxWidth: 720, alignment: .leading)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(.red.opacity(0.28)) }
        .accessibilityElement(children: .contain)
    }
}

private struct NotificationTrayActionButton: View {
    let action: NotificationTrayAction
    let onAction: (NotificationTrayAction) async -> NotificationTrayActionResult
    @State private var isPending = false
    @State private var result: NotificationTrayActionResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(label) {
                guard !isPending else { return }
                isPending = true
                result = nil
                Task {
                    result = await onAction(action)
                    isPending = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isPending)
            if isPending {
                ProgressView().controlSize(.small).accessibilityLabel("Action in progress")
            } else if let message = result?.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(result?.succeeded == true ? Color.secondary : Color.red)
            }
        }
    }

    private var label: String {
        switch action {
        case .openURL(let label, _), .dashboard(let label, _, _, _): label
        }
    }
}
