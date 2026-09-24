import Foundation

public struct MailboxSecretRequest: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case pending, stored, dismissed, retired }
    public let request: AgentSecretRequest
    public let accountID: String
    public let memberIDs: [UUID]
    public let connectionID: UUID
    public internal(set) var state: State = .pending
    public internal(set) var responseMessageID: UUID?
    public var isPending: Bool { state == .pending }

    init(request: AgentSecretRequest, accountID: String, memberIDs: [UUID], connectionID: UUID) {
        self.request = request; self.accountID = accountID
        self.memberIDs = memberIDs; self.connectionID = connectionID
    }
}

public struct MailboxSecretResponse: Codable, Hashable, Sendable {
    public let incomingMessageID: UUID
    public let publicationID: UUID
    public let accountID: String
    public let provided: Bool

    public var acknowledgement: String {
        provided
            ? "The user securely provided the requested credential. It was stored directly in its destination; the value is not in this conversation. This does not confirm remote authentication or grant additional tool permissions."
            : "The user dismissed the credential request without providing a credential. Do not claim it was stored or that authentication succeeded."
    }
}
