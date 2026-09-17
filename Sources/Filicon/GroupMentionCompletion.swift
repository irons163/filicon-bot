import Foundation
import FiliconAgents

/// UTF-16 ranges match AppKit's caret coordinates, including emoji and CJK text.
enum GroupMentionCompletion {
    struct Query: Equatable {
        let range: NSRange
        let value: String
    }

    struct Candidate: Identifiable, Equatable {
        let id: String
        let name: String
        let agent: AgentProfile?

        static let everyone = Candidate(id: "everyone", name: "everyone", agent: nil)
    }

    struct Insertion: Equatable {
        let text: String
        let selection: NSRange
    }

    static func query(in text: String, selection: NSRange, memberNames: [String] = []) -> Query? {
        guard selection.length == 0, let caret = Range(selection, in: text)?.lowerBound,
              let at = text[..<caret].lastIndex(of: "@") else { return nil }
        let prefix = String(text[..<at])
        // The same boundary as the group router: emails and paths are not mentions.
        guard prefix.range(of: #"[\p{L}\p{N}._%+\-]$"#, options: .regularExpression) == nil else { return nil }
        let value = String(text[text.index(after: at)..<caret])
        guard !value.contains(where: \.isNewline), value.last?.isWhitespace != true else { return nil }
        // A space ends the mention unless it is part of a member's multiword name.
        // In particular, typing a sentence after an inserted mention must not reopen
        // completion and consume the Return intended to send the message.
        if value.contains(where: \.isWhitespace),
           !memberNames.contains(where: { $0.localizedStandardContains(value) }) { return nil }
        return Query(range: NSRange(at..<caret, in: text), value: value)
    }

    static func candidates(for query: Query, memberIDs: [UUID], agents: [AgentProfile]) -> [Candidate] {
        let members = memberIDs.compactMap { id in
            agents.first { $0.id == id && $0.archivedAt == nil && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        guard !members.isEmpty else { return [] }
        let candidates = members.map { Candidate(id: $0.id.uuidString, name: $0.name, agent: $0) } + [.everyone]
        return candidates.filter {
            query.value.isEmpty || $0.name.localizedStandardContains(query.value)
                || GroupService.mentionHandles(for: $0.name).contains { $0.localizedStandardContains(query.value) }
                || ($0.id == "everyone" && "all".hasPrefix(query.value.lowercased()))
        }
    }

    static func inserting(_ candidate: Candidate, into text: String, query: Query) -> Insertion? {
        guard let range = Range(query.range, in: text), text[range].first == "@" else { return nil }
        // Replace the token under the caret, not unrelated text following it.
        let suffixEnd = text[range.upperBound...].firstIndex {
            $0.isWhitespace || ($0.isPunctuation && $0 != "_" && $0 != "-") || $0 == "@"
        } ?? text.endIndex
        let handle = "@" + candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trailingSpace = text[suffixEnd...].first?.isWhitespace == true ? "" : " "
        let replacement = handle + trailingSpace
        return Insertion(
            text: text.replacingCharacters(in: range.lowerBound..<suffixEnd, with: replacement),
            selection: NSRange(location: query.range.location + replacement.utf16.count + (text[suffixEnd...].first == " " ? 1 : 0), length: 0)
        )
    }

    static func movedSelection(_ current: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((current + delta) % count + count) % count
    }
}
