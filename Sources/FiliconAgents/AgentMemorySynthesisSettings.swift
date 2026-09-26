import Foundation

/// Separate consent from human-reviewed suggestions. Never infer automatic
/// rewriting consent from an existing suggestions toggle or a model message.
public struct AgentMemorySynthesisSettings: Codable, Equatable, Sendable {
    public let accountID: String
    public let agentID: UUID
    public internal(set) var enabled: Bool
    public internal(set) var revision: UUID?
    public init(accountID: String, agentID: UUID) {
        self.accountID = accountID; self.agentID = agentID
        self.enabled = false; self.revision = nil
    }
}
