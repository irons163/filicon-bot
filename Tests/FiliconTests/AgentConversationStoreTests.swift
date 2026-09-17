import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain

@Suite("Durable agent conversation isolation")
struct AgentConversationStoreTests {
    @Test func reopeningPreservesContextButIsolatesAccountsOriginsAndAgents() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-context-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json")
        let store = try AgentConversationStore(url: url)
        let sender = UUID(), recipient = UUID()
        let origin = try await store.mailboxScope(accountID: "one", senderID: sender, recipientID: recipient)
        let reversed = try await store.mailboxScope(accountID: "one", senderID: recipient, recipientID: sender)
        expectNoDifference(reversed, origin)
        let initial = try await store.context(accountID: "one", originID: origin, agentID: recipient)
        let inbound = ChatMessage(role: .system, text: "PRIVATE_PEER_CONTEXT")
        try await store.appendExchange(accountID: "one", originID: origin, agentID: recipient, incoming: inbound, response: "Result")
        try await store.appendExchange(accountID: "one", originID: origin, agentID: recipient, incoming: inbound, response: "Duplicate")
        let reopened = try AgentConversationStore(url: url)
        let restored = try await reopened.context(accountID: "one", originID: origin, agentID: recipient)
        expectNoDifference(restored.conversationID, initial.conversationID)
        expectNoDifference(restored.messages.map(\.text), ["PRIVATE_PEER_CONTEXT", "Result"])
        expectNoDifference(restored.messages.map(\.role), [.assistant, .assistant])
        for (account, scope, agent) in [("two", origin, recipient), ("one", UUID(), recipient), ("one", origin, sender)] {
            let isolated = try await reopened.context(accountID: account, originID: scope, agentID: agent)
            expectNoDifference(isolated.messages, [])
            #expect(isolated.conversationID != restored.conversationID)
        }
    }

    @Test func boundedHistoryAndCorruptionNeverSilentlyReset() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-context-bound-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json")
        let store = try AgentConversationStore(url: url)
        let agent = UUID(), origin = UUID()
        for index in 0..<20 {
            try await store.appendExchange(accountID: "local", originID: origin, agentID: agent,
                                           incoming: .init(role: .assistant, text: "Input \(index)"), response: "Result \(index)")
        }
        let context = try await store.context(accountID: "local", originID: origin, agentID: agent)
        expectNoDifference(context.messages.count, 30)
        expectNoDifference(context.messages.first?.text, "Input 5")
        try Data("broken".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AgentConversationStore(url: url) }
        expectNoDifference(try Data(contentsOf: url), Data("broken".utf8))
    }
}
