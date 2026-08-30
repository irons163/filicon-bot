import Foundation
import SwiftUI
import FiliconDomain

enum TranscriptCardPresentationKind: String, CaseIterable, Sendable {
    case widget, draft, autoReview, listener, secretRequest, connector
    case localToolPermission, notice, timeline, cloudAgent, fileOperation, shell, unknown
}

struct TranscriptCardPresentation: Equatable, Sendable {
    let kind: TranscriptCardPresentationKind
    let title: String
    let subtitle: String
    let symbolName: String
    let detail: String
    let fields: [(label: String, value: String)]
    let longTextTitle: String?
    let longText: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle &&
        lhs.symbolName == rhs.symbolName && lhs.detail == rhs.detail &&
        lhs.fields.map { [$0.label, $0.value] } == rhs.fields.map { [$0.label, $0.value] } &&
        lhs.longTextTitle == rhs.longTextTitle && lhs.longText == rhs.longText
    }
}

enum TranscriptCardPresenter {
    static func presentation(for card: TranscriptCard) -> TranscriptCardPresentation {
        let status = humanized(card.lifecycle.rawValue)
        switch card.payload {
        case .widget(let value):
            return .init(kind: .widget, title: value.title, subtitle: "Widget · \(status)", symbolName: "rectangle.grid.2x2", detail: value.body, fields: value.facts.sorted { $0.key < $1.key }.map { (humanized($0.key), $0.value) }, longTextTitle: nil, longText: nil)
        case .draft(let value):
            let channel = humanized(value.channel)
            return .init(kind: .draft, title: "\(channel) Draft", subtitle: "Draft · \(status)", symbolName: value.channel.lowercased() == "email" ? "envelope.badge" : "bubble.left.and.bubble.right", detail: value.subject ?? value.body, fields: value.recipients.isEmpty ? [] : [("Recipients", value.recipients.joined(separator: ", "))], longTextTitle: value.subject == nil ? nil : "Message", longText: value.subject == nil ? nil : value.body)
        case .autoReview(let value):
            return .init(kind: .autoReview, title: value.title, subtitle: "Auto-review · \(status)", symbolName: "checkmark.seal", detail: value.summary, fields: value.findings.enumerated().map { ("Finding \($0.offset + 1)", $0.element) }, longTextTitle: nil, longText: nil)
        case .listener(let value):
            return .init(kind: .listener, title: "Connect \(humanized(value.connector)) Listener", subtitle: "Listener · \(status)", symbolName: "dot.radiowaves.left.and.right", detail: value.event, fields: value.filterSummary.map { [("Filter", $0)] } ?? [], longTextTitle: nil, longText: nil)
        case .secretRequest(let value):
            var fields = [("Service", value.service)]
            if let account = value.account { fields.append(("Account", account)) }
            if let scope = value.scope { fields.append(("Scope", scope)) }
            return .init(kind: .secretRequest, title: "Credential Request", subtitle: "Protected · \(status)", symbolName: "key.horizontal", detail: value.prompt, fields: fields, longTextTitle: nil, longText: nil)
        case .connector(let value):
            return .init(kind: .connector, title: value.title, subtitle: "\(humanized(value.service)) · \(status)", symbolName: "link.badge.plus", detail: value.detail, fields: value.suggestions.enumerated().map { ("Suggestion \($0.offset + 1)", $0.element) }, longTextTitle: nil, longText: nil)
        case .localToolPermission(let value):
            var fields = [("Tool", value.toolName), ("Scope", value.scope)]
            if let notice = value.retiredNotice { fields.append(("Notice", notice)) }
            return .init(kind: .localToolPermission, title: value.retiredNotice == nil ? "Local Tool Permission" : "Retired Permission", subtitle: "Permission · \(status)", symbolName: value.retiredNotice == nil ? "hand.raised.square" : "hand.raised.slash", detail: value.reason, fields: fields, longTextTitle: nil, longText: nil)
        case .notice(let value):
            return .init(kind: .notice, title: value.title, subtitle: "\(humanized(value.severity)) · \(status)", symbolName: noticeSymbol(value.severity), detail: value.message, fields: [], longTextTitle: nil, longText: nil)
        case .timeline(let value):
            var fields: [(String, String)] = []
            if let name = value.name { fields.append(("Name", name)) }
            if let channel = value.channel { fields.append(("Channel", channel)) }
            if let automation = value.automation { fields.append(("Automation", automation)) }
            return .init(kind: .timeline, title: humanized(value.eventKind), subtitle: "Timeline · \(status)", symbolName: "point.3.connected.trianglepath.dotted", detail: value.detail, fields: fields, longTextTitle: nil, longText: nil)
        case .cloudAgent(let value):
            var fields = [("Agent", value.agentID)]
            if let bcID = value.bcID { fields.append(("BC ID", bcID)) }
            if let threadID = value.threadID { fields.append(("Thread", threadID)) }
            return .init(kind: .cloudAgent, title: value.title, subtitle: "Cloud agent · \(status)", symbolName: "cloud", detail: value.detail, fields: fields, longTextTitle: nil, longText: nil)
        case .fileOperation(let value):
            let fields = [("Path", value.path), ("Mode", value.isBackground ? "Background" : "Foreground")]
            return .init(kind: .fileOperation, title: "File \(humanized(value.operation))", subtitle: "File operation · \(status)", symbolName: value.operation.lowercased() == "write" ? "doc.badge.plus" : "doc.badge.ellipsis", detail: value.streamSummary ?? "", fields: fields, longTextTitle: value.diff == nil ? nil : "Diff", longText: value.diff)
        case .shell(let value):
            var fields: [(String, String)] = [("Mode", value.isBackground ? "Background" : "Foreground")]
            if let directory = value.workingDirectory { fields.append(("Directory", directory)) }
            if let exitCode = value.exitCode { fields.append(("Exit code", String(exitCode))) }
            return .init(kind: .shell, title: "Shell", subtitle: "Process · \(status)", symbolName: "terminal", detail: value.commandSummary, fields: fields, longTextTitle: value.streamSummary == nil ? nil : "Stream", longText: value.streamSummary)
        case .unknown(let type, _):
            return .init(kind: .unknown, title: "Unsupported Card", subtitle: "\(humanized(type)) · \(status)", symbolName: "questionmark.app.dashed", detail: "This card was created by a newer Filicon version. Its data is preserved, but it cannot perform actions here.", fields: [], longTextTitle: nil, longText: nil)
        }
    }

    static func searchableText(for card: TranscriptCard) -> String {
        let value = presentation(for: card)
        return ([value.title, value.subtitle, value.detail] + value.fields.flatMap { [$0.label, $0.value] } + [value.longText ?? ""]).joined(separator: "\n")
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ").capitalized
    }

    private static func noticeSymbol(_ severity: String) -> String {
        switch severity.lowercased() {
        case "error": "xmark.octagon"
        case "warning": "exclamationmark.triangle"
        default: "info.circle"
        }
    }
}

struct TranscriptCardRow: View {
    let card: TranscriptCard
    let onAction: (TranscriptCardActionIntent) -> Void
    private var presentation: TranscriptCardPresentation { TranscriptCardPresenter.presentation(for: card) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: presentation.symbolName).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title).font(.callout.bold())
                    Text(presentation.subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                lifecycleAccessory
            }
            if !presentation.detail.isEmpty {
                Text(presentation.detail).font(.callout).textSelection(.enabled)
            }
            ForEach(Array(presentation.fields.enumerated()), id: \.offset) { _, field in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(field.label).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(field.value).font(.caption).textSelection(.enabled)
                }
            }
            if let title = presentation.longTextTitle, let value = presentation.longText, !value.isEmpty {
                DisclosureGroup(title) {
                    ScrollView(.horizontal) {
                        Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(.top, 4)
                    }
                }.font(.caption)
            }
            let safeActions = card.actions.filter { $0.intent.isRendererSafe }
            if !safeActions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(safeActions) { action in
                        if action.role == "destructive" {
                            Button(action.label, role: .destructive) { onAction(action.intent) }
                        } else {
                            Button(action.label) { onAction(action.intent) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(borderColor.opacity(0.35)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(presentation.title), \(presentation.subtitle)")
    }

    @ViewBuilder private var lifecycleAccessory: some View {
        switch card.lifecycle {
        case .running, .waiting: ProgressView().controlSize(.small)
        case .failed, .denied: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .succeeded, .sent, .provided, .connected, .approved: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .retired: Image(systemName: "archivebox.fill").foregroundStyle(.secondary)
        default: Image(systemName: "clock").foregroundStyle(.secondary)
        }
    }

    private var borderColor: Color {
        switch card.lifecycle {
        case .failed, .denied: .red
        case .succeeded, .sent, .provided, .connected, .approved: .green
        default: .secondary
        }
    }
}
