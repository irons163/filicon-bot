import CustomDump
import FiliconAgents
import FiliconDomain
import Foundation
import Testing

@Suite("Direct agent execution identity")
struct DirectAgentExecutionIdentityTests {
    let id = UUID(uuidString: "10000000-0000-0000-0000-000000000042")!

    @Test func onlyExecutionChangesInvalidateSnapshot() throws {
        var profile = AgentProfile(id: id, name: "Designer", instructions: "Review accessibility.",
            createdAt: Date(timeIntervalSince1970: 1000))
        let binding = DirectConversationAgentBinding(accountID: "local", agentID: id)
        func resolve(_ profile: AgentProfile) throws -> DirectAgentExecutionIdentity? {
            try .resolve(binding: binding, accountID: "local", profile: profile,
                providerID: "fake", modelID: "fake-stream")
        }
        let initial = try #require(try resolve(profile))
        profile.unreadCount = 9
        profile.updatedAt = Date(timeIntervalSince1970: 2000)
        expectNoDifference(try resolve(profile), initial)
        profile.instructions = "Review contrast."
        #expect(try resolve(profile) != initial)
        expectNoDifference(initial.agentID, id)
        #expect(initial.systemMessage.text.contains("Review accessibility."))
    }

    @Test(arguments: ["missing", "archived", "foreign-account", "wrong-agent", "provider", "model"])
    func invalidBindingsNeverFallBackToUnbound(reason: String) throws {
        var profile: AgentProfile? = AgentProfile(id: id, name: "Designer")
        if reason == "missing" { profile = nil }
        if reason == "archived" { profile?.archivedAt = Date(timeIntervalSince1970: 1000) }
        if reason == "wrong-agent" { profile = AgentProfile(id: UUID(uuidString: "10000000-0000-0000-0000-000000000043")!, name: "Other") }
        #expect(throws: DirectAgentBindingError.unavailable) {
            try DirectAgentExecutionIdentity.resolve(binding: .init(accountID: "local", agentID: id),
                accountID: reason == "foreign-account" ? "other" : "local", profile: profile,
                providerID: reason == "provider" ? "other" : "fake",
                modelID: reason == "model" ? "other" : "fake-stream")
        }
    }

    @Test func legacyUnboundConversationRemainsUnbound() throws {
        expectNoDifference(try DirectAgentExecutionIdentity.resolve(binding: nil, accountID: "local",
            profile: AgentProfile(id: id, name: "Unrelated"), providerID: "fake", modelID: "fake-stream"), nil)
    }
}
