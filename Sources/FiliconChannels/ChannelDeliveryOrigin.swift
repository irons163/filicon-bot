import Foundation

/// Credential-free provenance saved with the queue entry, not a permission or
/// proof that a local transcript entry or remote delivery exists. A projector
/// must separately validate the current canonical destination before writing.
public struct ChannelDeliveryOrigin: Codable, Hashable, Sendable {
    public enum Route: String, Codable, Hashable, Sendable {
        case directConversation, groupConversation
    }
    public struct Intent: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable { case text, attachment }
        public struct Source: Codable, Hashable, Sendable {
            public let url: String
            public let alt: String?
            public init(url: String, alt: String? = nil) { self.url = url; self.alt = alt }
        }
        public let kind: Kind
        public let text: String
        /// All submitted locators, in order, including those not sent by the
        /// first-image channel contract. These never authorize URL/path access.
        public let sources: [Source]
        public init(kind: Kind, text: String, sources: [Source] = []) {
            self.kind = kind; self.text = text; self.sources = sources
        }
    }
    public let route: Route
    public let conversationID: UUID
    public let senderID: UUID
    public let senderName: String
    public let runID: UUID
    public let callID: String
    /// A local quote, never a platform thread or an external recipient.
    public let replyToMessageID: UUID?
    public let intent: Intent

    public init(route: Route, conversationID: UUID, senderID: UUID, senderName: String,
                runID: UUID, callID: String, replyToMessageID: UUID? = nil, intent: Intent) {
        self.route = route; self.conversationID = conversationID; self.senderID = senderID
        self.senderName = senderName; self.runID = runID; self.callID = callID
        self.replyToMessageID = replyToMessageID; self.intent = intent
    }

    /// Consistency only. Decoding or passing this check cannot grant consent,
    /// connection ownership, folder access, or authority to resume a model.
    public func isConsistent(agentID: UUID, outbound: ChannelOutbound) -> Bool {
        guard senderID == (route == .directConversation ? conversationID : agentID),
              Self.boundedLabel(senderName, maximumBytes: 8_000),
              Self.boundedLabel(callID, maximumBytes: 2_048),
              intent.text == outbound.text, intent.text.count <= ChannelService.maximumMessageCharacters,
              intent.sources.count <= 64,
              outbound.attachments.count == (intent.sources.isEmpty ? 0 : 1),
              intent.kind != .attachment || intent.sources.count == 1,
              intent.kind != .text || !intent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              intent.sources.reduce(0, { $0 + $1.url.utf8.count + ($1.alt?.utf8.count ?? 0) }) <= 64_000 else { return false }
        return intent.sources.allSatisfy { source in
            guard !source.url.isEmpty, source.url.utf8.count <= 16_384,
                  !source.url.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let scheme = URLComponents(string: source.url)?.scheme?.lowercased(),
                  scheme == "file" || scheme == "https" else { return false }
            return source.alt.map { Self.boundedLabel($0, maximumBytes: 2_000) && $0.count <= 500 } ?? true
        }
    }

    private static func boundedLabel(_ value: String, maximumBytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}
