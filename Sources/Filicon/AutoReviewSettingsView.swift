import SwiftUI
import FiliconAutoReview

struct AutoReviewSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var allowRules = ""
    @State private var askRules = ""
    @State private var loaded = false

    var body: some View {
        Section("Auto-review") {
            Toggle("Auto-review enabled", isOn: Binding(
                get: { model.autoReviewInstructions.isEnabled },
                set: { value in Task { await model.setAutoReviewEnabled(value) } }
            ))
            Text("Only explicitly allowed read-only actions may run automatically. Local writes, commands, network access, sensitive data, and destructive actions always require approval.")
                .font(.caption)
                .foregroundStyle(.secondary)

            rulesEditor(
                title: "Allow rules",
                help: "One literal phrase per line. At most 20 rules; each rule is limited to 1,000 characters.",
                text: $allowRules
            )
            rulesEditor(
                title: "Ask rules",
                help: "Ask rules take precedence over allow rules.",
                text: $askRules
            )
            HStack {
                Button("Save Auto-review Rules") {
                    let allow = Self.rules(from: allowRules)
                    let ask = Self.rules(from: askRules)
                    Task { await model.setAutoReviewRules(allow: allow, ask: ask) }
                }
                Spacer()
                Text("\(Self.rules(from: allowRules).count)/20 allow · \(Self.rules(from: askRules).count)/20 ask")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { loadFromModelIfNeeded() }
        .onChange(of: model.autoReviewInstructions) { _, _ in loadFromModel(force: true) }
    }

    @ViewBuilder
    private func rulesEditor(title: String, help: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            TextEditor(text: text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 72, maxHeight: 120)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func loadFromModelIfNeeded() {
        guard !loaded else { return }
        loadFromModel(force: true)
        loaded = true
    }

    private func loadFromModel(force: Bool) {
        guard force else { return }
        allowRules = model.autoReviewInstructions.allowRules.joined(separator: "\n")
        askRules = model.autoReviewInstructions.askRules.joined(separator: "\n")
    }

    private static func rules(from text: String) -> [String] {
        Array(text.components(separatedBy: .newlines).prefix(AutoReviewInstructions.maximumRulesPerKind))
            .map { String($0.prefix(AutoReviewInstructions.maximumRuleLength)) }
    }
}
