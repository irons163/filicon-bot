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
    @State private var synthesis: AgentMemorySynthesisSettings?
    @State private var confirmsSynthesis = false
    @State private var episodes: AgentMemoryEpisodeSettings?
    @State private var confirmsEpisodes = false

    var body: some View {
        Section(l10n("Memory suggestions")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n("Automatic memory synthesis")).font(.headline)
                AgentMemorySynthesisNotice()
                if let synthesis {
                    Text(l10n(synthesis.enabled ? "Enabled" : "Disabled"))
                    Button(l10n(synthesis.enabled ? "Disable automatic synthesis" : "Enable automatic synthesis…"),
                        action: synthesisButtonTapped)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(l10n("Episode summaries")).font(.headline)
                AgentMemoryEpisodeNotice()
                if let episodes {
                    Text(l10n(episodes.enabled ? "Enabled" : "Disabled"))
                    Button(l10n(episodes.enabled ? "Disable episode summaries" : "Enable episode summaries…"), action: episodeButtonTapped)
                        .disabled(synthesis?.enabled == true && !episodes.enabled)
                }
            }
            Divider()
            Text(l10n("Memory suggestions")).font(.headline)
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
        .confirmationDialog(l10n("Enable episode summaries?"), isPresented: $confirmsEpisodes, titleVisibility: .visible) {
            Button(l10n("Enable")) { Task { await setEpisodesEnabled(true) } }
            Button(l10n("Cancel"), role: .cancel) {}
        } message: { Text(FiliconLocalization.string(AgentMemoryEpisodeNotice.disclosure)) }
        .confirmationDialog(l10n("Enable automatic memory synthesis?"), isPresented: $confirmsSynthesis, titleVisibility: .visible) {
            Button(l10n("Enable")) { Task { await setSynthesisEnabled(true) } }
            Button(l10n("Cancel"), role: .cancel) {}
        } message: {
            Text(FiliconLocalization.string(AgentMemorySynthesisNotice.disclosure) + "\n\n" +
                FiliconLocalization.string(AgentMemorySynthesisNotice.temporalDisclosure) + "\n\n" +
                FiliconLocalization.string(AgentMemoryEpisodeNotice.disclosure))
        }
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
        synthesis = nil; confirmsSynthesis = false
        episodes = nil; confirmsEpisodes = false
        snapshot = nil; selected = nil; confirmsEnable = false; confirmsSave = false; failure = nil
        await refresh()
    }
    private func refresh() async {
        do {
            let value = try await model.memorySuggestionSnapshot(agentID: agentID)
            let synthesisValue = try await model.memorySynthesisSettings(agentID: agentID)
            let episodeValue = try await model.memoryEpisodeSettings(agentID: agentID)
            try Task.checkCancellation()
            guard value.settings.accountID == (model.settings.accountScope ?? "local"),
                  synthesisValue.accountID == value.settings.accountID,
                  episodeValue.accountID == value.settings.accountID else { return }
            snapshot = value
            synthesis = synthesisValue
            episodes = episodeValue
        } catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
    }
    private func synthesisButtonTapped() {
        if synthesis?.enabled == true { Task { await setSynthesisEnabled(false) } }
        else { confirmsSynthesis = true }
    }
    private func episodeButtonTapped() {
        if episodes?.enabled == true { Task { await setEpisodesEnabled(false) } }
        else { confirmsEpisodes = true }
    }
    private func setEpisodesEnabled(_ enabled: Bool) async {
        guard let expected = episodes else { return }
        busy = true; failure = nil
        defer { busy = false }
        do { try await model.setMemoryEpisodesEnabled(enabled, expected: expected) }
        catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
        await refresh()
    }
    private func setSynthesisEnabled(_ enabled: Bool) async {
        guard let expected = synthesis else { return }
        busy = true; failure = nil
        defer { busy = false }
        do { try await model.setMemorySynthesisEnabled(enabled, expected: expected) }
        catch is CancellationError {} catch { failure = FiliconLocalization.string(error.localizedDescription) }
        await refresh()
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

struct AgentMemoryEpisodeNotice: View {
    static let disclosure = "Separate opt-in: retain bounded text from completed replies across turns. Every six eligible turns may incur extra model costs to summarize and independently verify private memories, saved without individual approval. Stopping, deleting the conversation, switching accounts or disabling clears pending text, not saved memories. Automatic synthesis disables this feature and clears pending text. No tool permissions are granted."
    var body: some View {
        Text(FiliconLocalization.string(Self.disclosure)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct AgentMemorySynthesisNotice: View {
    static let temporalDisclosure = "While enabled, the app also checks hourly for private memories due for a date-based review, including at startup. Reviews may incur extra model costs without a new chat message. After a review completes, the next review is due 24 hours after that review's start time."
    static let disclosure = "Separate opt-in: completed direct and group replies may trigger extra paid model requests using this agent's current human message, reply and private memories. After independent model verification, generated memories can be added, updated or removed without individual approval. Manually saved memories are protected. Disabling keeps saved memories and grants no tool permissions."
    var body: some View {
        Text(FiliconLocalization.string(Self.disclosure)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text(FiliconLocalization.string(Self.temporalDisclosure)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
