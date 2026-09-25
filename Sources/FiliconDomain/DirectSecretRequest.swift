import Foundation

/// Value-free transcript metadata, never proof of a Keychain write or authority
/// to submit a credential. The host must retain and validate a live submission.
public struct DirectSecretRequest: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case pending, stored, dismissed, retired }
    public let requestID: UUID
    public let request: AgentSecretRequest
    public let binding: DirectConversationAgentBinding
    public let conversationID: UUID
    public let connectionID: UUID
    public private(set) var state: State
    public private(set) var responseMessageID: UUID?

    public init(requestID: UUID, request: AgentSecretRequest, binding: DirectConversationAgentBinding,
                conversationID: UUID, connectionID: UUID) {
        self.requestID = requestID
        self.request = request; self.binding = binding
        self.conversationID = conversationID; self.connectionID = connectionID
        state = .pending
    }

    public var isPending: Bool { state == .pending }

    /// The caller may record `provided` only after validating an actual host
    /// submission receipt. This transition itself performs no credential write.
    public mutating func resolve(provided: Bool, responseMessageID: UUID) throws {
        guard state == .pending else { throw AgentSecretRequestError.stale }
        state = provided ? .stored : .dismissed
        self.responseMessageID = responseMessageID
    }

    public mutating func retire() {
        if state == .pending { state = .retired }
    }

    public var acknowledgement: String? {
        switch state {
        case .stored:
            "The user securely provided the requested credential. It was stored directly in its destination; the value is not in this conversation. This does not confirm remote authentication or grant additional tool permissions."
        case .dismissed:
            "The user dismissed the credential request without providing a credential. Do not claim it was stored or that authentication succeeded."
        case .pending, .retired: nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, request, binding, conversationID, connectionID, state, responseMessageID
    }

    public init(from decoder: any Decoder) throws {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            requestID = try values.decode(UUID.self, forKey: .requestID)
            request = try values.decode(AgentSecretRequest.self, forKey: .request)
            binding = try values.decode(DirectConversationAgentBinding.self, forKey: .binding)
            conversationID = try values.decode(UUID.self, forKey: .conversationID)
            connectionID = try values.decode(UUID.self, forKey: .connectionID)
            state = try values.decode(State.self, forKey: .state)
            responseMessageID = try values.decodeIfPresent(UUID.self, forKey: .responseMessageID)
            guard !binding.accountID.isEmpty,
                  (state == .stored || state == .dismissed) == (responseMessageID != nil) else {
                throw AgentSecretRequestError.invalid
            }
        } catch { throw AgentSecretRequestError.invalid }
    }
}
