import SwiftUI
import FiliconDomain

enum ConversationOutlineKind: String, Sendable {
    case user, thinking, assistantText, toolCall, card
}

struct ConversationOutlineItem: Identifiable, Equatable, Sendable {
    let id: String
    let messageID: UUID
    let kind: ConversationOutlineKind
    let label: String
    let preview: String
    let detail: String
    let status: String?
}

enum ConversationOutlineProjection {
    static func make(messages: [ChatMessage]) -> [ConversationOutlineItem] {
        messages.flatMap { message in
            var result: [ConversationOutlineItem] = []
            let roleLabel = message.role == .user ? "You" : message.role == .assistant ? "Agent" : message.role.rawValue.capitalized
            if message.role == .user || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(item(
                    id: "\(message.id.uuidString):message", messageID: message.id,
                    kind: message.role == .user ? .user : .assistantText,
                    label: roleLabel, detail: message.text,
                    status: message.deliveryStatus == .succeeded ? nil : message.deliveryStatus.rawValue
                ))
            }
            if !message.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(item(
                    id: "\(message.id.uuidString):thinking", messageID: message.id,
                    kind: .thinking, label: "Thinking", detail: message.reasoningText, status: nil
                ))
            }
            for tool in message.toolActivities {
                let detail = [tool.argumentsJSON, tool.result].compactMap { $0 }.joined(separator: "\n\n")
                result.append(item(
                    id: "\(message.id.uuidString):tool:\(tool.id)", messageID: message.id,
                    kind: .toolCall, label: humanized(tool.name.rawValue), detail: detail,
                    status: tool.status.rawValue
                ))
            }
            for card in message.transcriptCards {
                let presentation = TranscriptCardPresenter.presentation(for: card)
                result.append(item(
                    id: "\(message.id.uuidString):card:\(card.id.uuidString)", messageID: message.id,
                    kind: .card, label: presentation.title,
                    detail: TranscriptCardPresenter.searchableText(for: card), status: card.lifecycle.rawValue
                ))
            }
            return result
        }
    }

    private static func item(
        id: String, messageID: UUID, kind: ConversationOutlineKind,
        label: String, detail: String, status: String?
    ) -> ConversationOutlineItem {
        let clean = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = String(clean.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(240) ?? "")
        return .init(id: id, messageID: messageID, kind: kind, label: label, preview: preview, detail: String(clean.prefix(20_000)), status: status)
    }

    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
    }
}

struct ConversationOutlineView: View {
    let title: String
    let items: [ConversationOutlineItem]
    let onSelect: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var expanded = Set<String>()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Full conversation", systemImage: "list.bullet")
                    .font(.headline)
                Text(title).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            if items.isEmpty {
                ContentUnavailableView("No conversation activity yet", systemImage: "text.bubble")
            } else {
                List(items) { item in
                    DisclosureGroup(isExpanded: Binding(
                        get: { expanded.contains(item.id) },
                        set: { value in if value { expanded.insert(item.id) } else { expanded.remove(item.id) } }
                    )) {
                        if item.detail.isEmpty {
                            Text("No additional details.").foregroundStyle(.secondary)
                        } else {
                            Text(item.detail).font(.system(.caption, design: item.kind == .toolCall ? .monospaced : .default)).textSelection(.enabled)
                        }
                        Button("Show in conversation") {
                            onSelect(item.messageID)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: symbol(for: item.kind)).foregroundStyle(color(for: item))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(item.label).fontWeight(.medium)
                                    if let status = item.status { Text(status.capitalized).font(.caption2).foregroundStyle(.secondary) }
                                }
                                if !item.preview.isEmpty { Text(item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 560)
    }

    private func symbol(for kind: ConversationOutlineKind) -> String {
        switch kind {
        case .user: "person.circle"
        case .thinking: "brain"
        case .assistantText: "sparkles"
        case .toolCall: "wrench.and.screwdriver"
        case .card: "rectangle.on.rectangle"
        }
    }

    private func color(for item: ConversationOutlineItem) -> Color {
        guard item.status == "failed" else { return .secondary }
        return .red
    }
}
