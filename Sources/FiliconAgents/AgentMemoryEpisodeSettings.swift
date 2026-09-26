import Foundation

/// Explicit consent to retain bounded cross-turn text and automatically append
/// independently verified episodic summaries to private memory.
/// Neither suggestion consent nor disabling synthesis implies this consent.
public struct AgentMemoryEpisodeSettings: Codable, Equatable, Sendable {
    public let accountID: String
    public let agentID: UUID
    public internal(set) var enabled = false
    public internal(set) var revision: UUID?
    public init(accountID: String, agentID: UUID) {
        self.accountID = accountID; self.agentID = agentID
    }
}
