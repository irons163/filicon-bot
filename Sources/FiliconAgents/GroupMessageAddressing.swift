import Foundation

/// Addresses describe visible group messages, not private assistant reasoning.
/// The stored UUID remains the identity used for navigation and publication.
public enum GroupMessageAddressing {
    private static let limit = 1_000_000_000

    private struct Address {
        let turn: Int?
        let response: Int?
        var prefix: String { "t\(turn.map(String.init) ?? "b")" }

        init?(_ value: String) {
            guard value.first == "t", value.utf8.count <= 22 else { return nil }
            let body = value.dropFirst()
            if body.last == "u", let turn = Self.number(body.dropLast()) {
                self.turn = turn; response = nil
            } else {
                let parts = body.split(separator: "s", omittingEmptySubsequences: false)
                guard parts.count == 2, let response = Self.number(parts[1]) else { return nil }
                if parts[0] == "b" { turn = nil }
                else if let turn = Self.number(parts[0]) { self.turn = turn }
                else { return nil }
                self.response = response
            }
        }

        private static func number(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                  value.count == 1 || value.first != "0", let number = Int(value), number < limit else { return nil }
            return number
        }
    }

    public static func isValid(_ address: String, for message: RoomMessage) -> Bool {
        guard let parsed = Address(address) else { return false }
        return (parsed.response == nil) == (message.senderID == nil)
    }

    private struct Book {
        var reserved: Set<String> = []
        var nextTurn = 0
        var turn: Int?
        var turnKnown = true
        var nextResponse: [String: Int] = [:]

        mutating func assign(_ message: inout RoomMessage) {
            if let address = message.shortAddress {
                if isValid(address, for: message), let parsed = Address(address) {
                    if let turn = parsed.turn {
                        nextTurn = max(nextTurn, turn + 1)
                        self.turn = turn
                    }
                    if let response = parsed.response {
                        nextResponse[parsed.prefix] = max(nextResponse[parsed.prefix, default: 0], response + 1)
                    }
                    if message.senderID == nil { turnKnown = true }
                } else if message.senderID == nil {
                    turnKnown = false
                }
            } else if message.memberOutcome == nil,
                      message.senderID == nil || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || !(message.images ?? []).isEmpty || !(message.files ?? []).isEmpty || message.remoteAttachment != nil {
                if message.senderID == nil {
                    while nextTurn < limit, reserved.contains("t\(nextTurn)u") { nextTurn += 1 }
                    if nextTurn < limit {
                        message.shortAddress = "t\(nextTurn)u"
                        turn = nextTurn
                        turnKnown = true
                        nextTurn += 1
                    } else { turnKnown = false }
                } else if turnKnown {
                    let prefix = "t\(turn.map(String.init) ?? "b")"
                    var next = nextResponse[prefix, default: 0]
                    while next < limit, reserved.contains("\(prefix)s\(next)") { next += 1 }
                    if next < limit {
                        message.shortAddress = "\(prefix)s\(next)"
                        nextResponse[prefix] = next + 1
                    }
                }
                if let address = message.shortAddress { reserved.insert(address) }
            }
        }
    }

    /// Called only on the full stored log. Existing addresses (even damaged
    /// ones) are never reassigned; the tool directory rejects ambiguous ones.
    static func assignMissing(in messages: inout [RoomMessage]) {
        var books: [UUID: Book] = [:]
        for message in messages {
            if let address = message.shortAddress { books[message.groupID, default: Book()].reserved.insert(address) }
        }
        for index in messages.indices {
            let groupID = messages[index].groupID
            // Mutate the dictionary value in place, avoiding a copy of the
            // growing reserved-address set for every message in a large log.
            books[groupID, default: Book()].assign(&messages[index])
        }
    }
}
