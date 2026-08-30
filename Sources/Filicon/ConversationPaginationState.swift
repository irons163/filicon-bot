import Foundation
import FiliconDomain

/// Selection generations are deliberately independent from persistence fences:
/// fences stabilize a DB walk, while generations reject a completed walk after
/// the user has switched away (or begun a newer refresh of the same chat).
struct ConversationLoadTicket: Equatable, Sendable {
    let conversationID: UUID
    let generation: Int
}

struct ConversationLoadFence: Equatable, Sendable {
    private(set) var generation = 0

    mutating func begin(conversationID: UUID) -> ConversationLoadTicket {
        generation += 1
        return .init(conversationID: conversationID, generation: generation)
    }

    func accepts(_ ticket: ConversationLoadTicket, selectedConversationID: UUID?) -> Bool {
        ticket.generation == generation && ticket.conversationID == selectedConversationID
    }
}

enum ConversationPageMerge {
    /// Older pages are prepended. Existing values win at an overlap boundary,
    /// preserving streamed text or other local edits while eliminating duplicates.
    static func older(_ older: [ChatMessage], into existing: [ChatMessage]) -> [ChatMessage] {
        let existingIDs = Set(existing.map(\.id))
        return older.filter { !existingIDs.contains($0.id) } + existing
    }

    /// A newly selected chat replaces its prior window with the latest page.
    /// Broken/corrupt duplicate rows are still collapsed deterministically.
    static func latest(_ messages: [ChatMessage]) -> [ChatMessage] {
        var seen: Set<UUID> = []
        return messages.filter { seen.insert($0.id).inserted }
    }
}
