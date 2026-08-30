import Foundation
import FiliconDomain

extension Notification.Name {
    static let filiconFindInChat = Notification.Name("FiliconFindInChat")
}

/// Keeps large transcripts inexpensive to render without changing the canonical
/// conversation or the messages supplied to a provider.
struct TranscriptPresentationState: Equatable {
    static let initialPageSize = 100
    static let pageSize = 100

    private(set) var renderedCount: Int
    private(set) var knownMessageCount: Int
    var query = ""
    private(set) var matchIDs: [UUID] = []
    private(set) var selectedMatchIndex: Int?

    init(messages: [ChatMessage]) {
        knownMessageCount = messages.count
        renderedCount = min(Self.initialPageSize, messages.count)
    }

    var hasOlderMessages: Bool { renderedCount < knownMessageCount }
    var activeMatchID: UUID? {
        guard let selectedMatchIndex, matchIDs.indices.contains(selectedMatchIndex) else { return nil }
        return matchIDs[selectedMatchIndex]
    }
    var matchPositionLabel: String {
        guard let selectedMatchIndex, !matchIDs.isEmpty else { return "0 of 0" }
        return "\(selectedMatchIndex + 1) of \(matchIDs.count)"
    }

    func visibleMessages(from messages: [ChatMessage]) -> ArraySlice<ChatMessage> {
        messages.suffix(min(renderedCount, messages.count))
    }

    mutating func reset(messages: [ChatMessage]) {
        self = TranscriptPresentationState(messages: messages)
    }

    mutating func synchronize(messages: [ChatMessage]) {
        let previousActiveID = activeMatchID
        if messages.count > knownMessageCount {
            // Keep everything the user already exposed visible and append new turns.
            renderedCount += messages.count - knownMessageCount
        }
        knownMessageCount = messages.count
        renderedCount = min(max(0, renderedCount), messages.count)
        rebuildMatches(messages: messages, preserving: previousActiveID)
    }

    mutating func loadOlder() {
        renderedCount = min(knownMessageCount, renderedCount + Self.pageSize)
    }

    /// Makes an arbitrary thread/reply target part of the rendered window.
    @discardableResult
    mutating func exposeMessage(id: UUID, in messages: [ChatMessage]) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        renderedCount = max(renderedCount, messages.count - index)
        return true
    }

    mutating func setQuery(_ value: String, messages: [ChatMessage]) {
        query = value
        rebuildMatches(messages: messages, preserving: nil)
    }

    @discardableResult
    mutating func selectNext(messages: [ChatMessage]) -> UUID? {
        guard !matchIDs.isEmpty else { return nil }
        selectedMatchIndex = ((selectedMatchIndex ?? -1) + 1) % matchIDs.count
        return exposeActiveMatch(in: messages)
    }

    @discardableResult
    mutating func selectPrevious(messages: [ChatMessage]) -> UUID? {
        guard !matchIDs.isEmpty else { return nil }
        selectedMatchIndex = ((selectedMatchIndex ?? 0) - 1 + matchIDs.count) % matchIDs.count
        return exposeActiveMatch(in: messages)
    }

    @discardableResult
    mutating func exposeActiveMatch(in messages: [ChatMessage]) -> UUID? {
        guard let id = activeMatchID else { return nil }
        guard exposeMessage(id: id, in: messages) else { return nil }
        return id
    }

    func isMatch(_ id: UUID) -> Bool { matchIDs.contains(id) }

    private mutating func rebuildMatches(messages: [ChatMessage], preserving activeID: UUID?) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            matchIDs = []
            selectedMatchIndex = nil
            return
        }
        matchIDs = messages.filter { message in
            message.searchableTranscriptText.localizedStandardContains(normalized)
        }.map(\.id)
        if let activeID, let index = matchIDs.firstIndex(of: activeID) {
            selectedMatchIndex = index
        } else {
            selectedMatchIndex = matchIDs.isEmpty ? nil : 0
        }
        _ = exposeActiveMatch(in: messages)
    }
}

private extension ChatMessage {
    var searchableTranscriptText: String {
        let tools = toolActivities.flatMap { activity in
            [activity.name.rawValue, activity.argumentsJSON, activity.result ?? ""]
        }
        return ([text, reasoningText, deliveryError ?? ""]
            + attachments.map(\.filename)
            + tools
            + transcriptCards.map(TranscriptCardPresenter.searchableText))
            .joined(separator: "\n")
    }
}
