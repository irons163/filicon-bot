import Foundation

/// Durable attribution for a projected mailbox event, not authority to run tools.
/// The host must validate the canonical mailbox event and conversation binding
/// before projecting. Never reinterpret incoming peer text as a human instruction.
public struct AgentMessageSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case incoming, publication }
    public let accountID: String
    public let originConversationID: UUID
    public let deliveryID: UUID
    public let senderAgentID: UUID
    public let recipientAgentID: UUID
    public let kind: Kind

    public var authorAgentID: UUID { kind == .incoming ? senderAgentID : recipientAgentID }

    public init(accountID: String, originConversationID: UUID, deliveryID: UUID,
                senderAgentID: UUID, recipientAgentID: UUID, kind: Kind) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              accountID.utf8.count <= 1024, senderAgentID != recipientAgentID else {
            throw ValidationError.invalidSource
        }
        self.accountID = accountID
        self.originConversationID = originConversationID
        self.deliveryID = deliveryID
        self.senderAgentID = senderAgentID
        self.recipientAgentID = recipientAgentID
        self.kind = kind
    }

    public enum ValidationError: Error { case invalidSource }
    private enum CodingKeys: String, CodingKey {
        case accountID, originConversationID, deliveryID, senderAgentID, recipientAgentID, kind
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(accountID: values.decode(String.self, forKey: .accountID),
                      originConversationID: values.decode(UUID.self, forKey: .originConversationID),
                      deliveryID: values.decode(UUID.self, forKey: .deliveryID),
                      senderAgentID: values.decode(UUID.self, forKey: .senderAgentID),
                      recipientAgentID: values.decode(UUID.self, forKey: .recipientAgentID),
                      kind: values.decode(Kind.self, forKey: .kind))
    }
}
