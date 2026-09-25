import FiliconDomain
import Foundation

/// Only execution-relevant profile fields. Presence and unread-count updates
/// must not invalidate a queued turn; instruction or model changes must.
public struct DirectAgentExecutionIdentity: Equatable, Sendable {
    public let agentID: UUID
    public let providerID: ProviderID
    public let modelID: ModelID
    public let systemMessage: ChatMessage

    public static func resolve(
        binding: DirectConversationAgentBinding?, accountID: String,
        profile: AgentProfile?, providerID: ProviderID, modelID: ModelID
    ) throws -> Self? {
        guard let binding else { return nil }
        guard !accountID.isEmpty, binding.accountID == accountID,
              let profile, profile.id == binding.agentID, profile.archivedAt == nil,
              profile.providerID == providerID, profile.modelID == modelID else {
            throw DirectAgentBindingError.unavailable
        }
        return Self(agentID: profile.id, providerID: profile.providerID, modelID: profile.modelID,
            systemMessage: ChatMessage(id: profile.id, role: .system,
                text: "You are \(profile.name), agent:\(profile.id.uuidString). Role: \(profile.title). Description: \(profile.summary).\n\(profile.instructions)",
                createdAt: Date(timeIntervalSince1970: 0)))
    }
}

public enum DirectAgentBindingError: Error, Equatable, Sendable {
    case unavailable
}
