import SwiftUI
import FiliconAgents

struct AgentMemorySuggestionsSection: View {
    @EnvironmentObject private var model: AppModel
    let agentID: UUID
    @State private var snapshot: AgentMemorySuggestionSnapshot?
    @State private var busy = false
    @State private var failure: String?
    @State private var confirmsEnable = false
    @State private var selected: AgentMemorySuggestion?
    @State private var confirmsSave = false

    var body: some View {
        Section(l10n("Memory suggestions")) {
            AgentMemorySuggestionsNotice()
            if let snapshot {
                HStack {
                    Text(l10n(snapshot.settings.enabled ? "Enabled" : "Disabled"))
                    Spacer()
                    Button(l10n(snapshot.settings.enabled ? "Disable suggestions" : "Enable suggestions…"), action: preferenceButtonTapped)
                }
                if snapshot.suggestions.isEmpty { Text(l10n("No memory suggestions to review.")).foregroundStyle(.secondary) }
                ForEach(snapshot.suggestions) { suggestion in
                    AgentMemorySuggestionCard(suggestion: suggestion,
                        onSave: { saveButtonTapped(suggestion) },
                        onDismiss: { Task { await review(suggestion, accept: false) } })
                }
            }
            Button(l10n("Refresh")) { Task { await refresh() } }
            if let failure { Text(failure).foregroundStyle(.red) }
        }
        .disabled(busy)
        .task(id: model.settings.accountScope ?? "local") { await accountChanged() }
        .confirmationDialog(l10n("Enable memory suggestions?"), isPresented: $confirmsEnable, titleVisibility: .visible) {
            Button(l10n("Enable")) { Task { await setEnabled(true) } }
            Button(l10n("Cancel"), role: .cancel) {}
        } message: { Text(FiliconLocalization.string(AgentMemorySuggestionsNotice.disclosure)) }
        .confirmationDialog(l10n("Save as private memory?"), isPresented: $confirmsSave, titleVisibility: .visible) {
            Button(l10n("Save")) { Task { await confirmSave() } }
            Button(l10n("Cancel"), role: .cancel) { selected = nil }
        } message: {
            Text((selected?.fact ?? "") + "\n\n" + l10n("Only this agent in this account will recall the saved fact. No tool permission is granted."))
        }
    }

    private func preferenceButtonTapped() {
        if snapshot?.settings.enabled == true { Task { await setEnabled(false) } }
        else { confirmsEnable = true }
    }
    private func saveButtonTapped(_ suggestion: AgentMemorySuggestion) { selected = suggestion; confirmsSave = true }
    private func confirmSave() async {
        guard let selected else { return }
        self.selected = nil
        await review(selected, accept: true)
    }
    private func accountChanged() async {
        snapshot = nil; selected = nil; confirmsEnable = false; confirmsSave = false; failure = nil
        await refresh()
    }
    private func refresh() async {
        do {
            let value = try await model.memorySuggestionSnapshot(agentID: agentID)
            try Task.checkCancellation()
            guard value.settings.accountID == (model.settings.accountScope ?? "local") else { return }
            snapshot = value
        } catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
    }
    private func setEnabled(_ enabled: Bool) async {
        guard let expected = snapshot?.settings else { return }
        busy = true; failure = nil
        defer { busy = false }
        do { try await model.setMemorySuggestionsEnabled(enabled, expected: expected) }
        catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
        await refresh()
    }
    private func review(_ suggestion: AgentMemorySuggestion, accept: Bool) async {
        busy = true; failure = nil
        defer { busy = false }
        do { try await model.reviewMemorySuggestion(suggestion, accept: accept) }
        catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
        await refresh()
    }
}

struct AgentMemorySuggestionsNotice: View {
    static let disclosure = "Optional extra model requests after completed group turns may incur costs. Only this agent's current human request, reply and private facts are sent to its selected model. Suggestions are not recalled until you approve each fact. No peer wakes, old images or shared memories are scanned. Disabling clears unapproved suggestions, not saved facts."
    var body: some View {
        Text(FiliconLocalization.string(Self.disclosure)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentMemoryReviewProgress: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(l10n("Reviewing memory suggestions…")).font(.caption)
        }.foregroundStyle(.secondary)
    }
}

struct AgentMemorySuggestionCard: View {
    let suggestion: AgentMemorySuggestion
    let onSave: () -> Void
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: suggestion.fact).textSelection(.enabled)
            Text(l10n("Evidence from your message")).font(.caption.bold())
            Text(verbatim: suggestion.evidence).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                HStack { reviewActions }
                VStack(alignment: .leading, spacing: 8) { reviewActions }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: .rect(cornerRadius: 8))
    }

    @ViewBuilder private var reviewActions: some View {
        Button(l10n("Save as private memory…"), action: onSave)
        Button(l10n("Dismiss suggestion"), action: onDismiss)
    }
}
