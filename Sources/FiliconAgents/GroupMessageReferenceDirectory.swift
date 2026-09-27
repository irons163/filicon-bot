import Foundation

/// A read-only navigation index over the full, ordered log of one group.
/// Never derives addresses from a prompt window or treats links as instructions.
public struct GroupMessageReferenceDirectory: Sendable {
    private struct Target: Sendable {
        let id: UUID
        let index: Int
    }
    private let positions: [UUID: Int]
    private let targets: [String: Target]

    public init(history: [RoomMessage], groupID: UUID) {
        let messages = history.filter { $0.groupID == groupID }
        let idCounts = Dictionary(grouping: messages, by: \.id).mapValues(\.count)
        let addressCounts = Dictionary(grouping: messages.compactMap(\.shortAddress), by: { $0 }).mapValues(\.count)
        var positions: [UUID: Int] = [:]
        var targets: [String: Target] = [:]
        for (index, message) in messages.enumerated() {
            guard idCounts[message.id] == 1 else { continue }
            positions[message.id] = index
            guard message.memberOutcome == nil,
                  (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.remoteAttachment != nil),
                  let address = message.shortAddress, addressCounts[address] == 1,
                  GroupMessageAddressing.isValid(address, for: message) else { continue }
            targets[address] = Target(id: message.id, index: index)
        }
        self.positions = positions
        self.targets = targets
    }

    /// Only canonical `sand-msg:t0s0` links to earlier visible messages qualify.
    /// No hosts, percent decoding, UUIDs, query strings, fragments, or private addresses.
    public func target(for url: URL, from messageID: UUID) -> UUID? {
        let value = url.absoluteString
        guard value.hasPrefix("sand-msg:"), let sourceIndex = positions[messageID],
              let target = targets[String(value.dropFirst("sand-msg:".count))],
              target.index < sourceIndex else { return nil }
        return target.id
    }
}
