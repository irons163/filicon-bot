import Foundation

/// A display-only projection of the saved room log. Only unambiguous backwards
/// edges form threads; broken/cyclic/foreign references remain on the timeline.
/// No stored message, audience, question or tool permission is changed.
public struct GroupThreadProjection: Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id: Int
        public let message: RoomMessage
    }
    public let roots: [Entry]
    private let children: [UUID: [Entry]]
    private let rootByMessage: [UUID: UUID]
    private let replyableIDs: Set<UUID>
    public let attentionRootIDs: Set<UUID>
    /// Only an explicit human reply starts a reply-scoped turn. Quoting does not
    /// change responders; a newer ordinary request always leaves that thread.
    public let defaultReplyTargetID: UUID?

    public init(history: [RoomMessage], groupID: UUID) {
        let messages = history.filter { $0.groupID == groupID }
        let counts = Dictionary(grouping: messages, by: \.id).mapValues(\.count)
        var roots: [Entry] = [], children: [UUID: [Entry]] = [:]
        var seen: [UUID: RoomMessage] = [:], rootByMessage: [UUID: UUID] = [:]
        var threadableIDs: Set<UUID> = []
        var attention: Set<UUID> = []
        for (index, message) in messages.enumerated() {
            let entry = Entry(id: index, message: message)
            let unique = counts[message.id] == 1
            let root: UUID
            if unique, Self.canThread(message), let parentID = message.replyToMessageID,
               let parent = seen[parentID], threadableIDs.contains(parent.id), let parentRoot = rootByMessage[parentID] {
                root = parentRoot
                children[root, default: []].append(entry)
                threadableIDs.insert(message.id)
            } else {
                root = message.id
                roots.append(entry)
                if unique && Self.canThread(message) && message.replyToMessageID == nil { threadableIDs.insert(message.id) }
            }
            if unique {
                seen[message.id] = message
                rootByMessage[message.id] = root
            }
            if message.question?.isPending == true || message.toolActivities.contains(where: { $0.status == .pending }) {
                attention.insert(root)
            }
        }
        self.roots = roots; self.children = children
        self.rootByMessage = rootByMessage; attentionRootIDs = attention
        replyableIDs = threadableIDs
        defaultReplyTargetID = messages.last(where: { $0.senderID == nil }).flatMap {
            $0.replyToMessageID != nil && threadableIDs.contains($0.id) ? $0.id : nil
        }
    }

    public func replies(to rootID: UUID) -> [Entry] { children[rootID] ?? [] }
    public func root(containing messageID: UUID) -> UUID? { rootByMessage[messageID] }
    public func canReply(to messageID: UUID) -> Bool { replyableIDs.contains(messageID) }

    private static func canThread(_ message: RoomMessage) -> Bool {
        message.memberOutcome == nil && (!message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(message.images ?? []).isEmpty || !(message.files ?? []).isEmpty || message.remoteAttachment != nil || message.externalPublication != nil)
    }
}

/// Ephemeral view state, kept separate from the persistent reply relationship.
public struct GroupThreadPresentationState: Equatable, Sendable {
    public private(set) var expandedRootIDs: Set<UUID> = []
    public private(set) var pendingMessageID: UUID?
    public init() {}

    public func isExpanded(_ rootID: UUID, in projection: GroupThreadProjection) -> Bool {
        expandedRootIDs.contains(rootID) || projection.attentionRootIDs.contains(rootID)
    }

    public mutating func toggle(_ rootID: UUID, in projection: GroupThreadProjection) {
        guard !projection.replies(to: rootID).isEmpty, !projection.attentionRootIDs.contains(rootID) else { return }
        if !expandedRootIDs.insert(rootID).inserted { expandedRootIDs.remove(rootID) }
    }

    public mutating func reveal(_ messageID: UUID, in projection: GroupThreadProjection) {
        guard let rootID = projection.root(containing: messageID) else { return }
        if rootID != messageID { expandedRootIDs.insert(rootID) }
        pendingMessageID = messageID
    }

    public mutating func didReveal(_ messageID: UUID) {
        if pendingMessageID == messageID { pendingMessageID = nil }
    }
}
