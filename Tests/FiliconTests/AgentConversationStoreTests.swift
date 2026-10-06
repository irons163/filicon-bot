import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain

@Suite("Durable agent conversation isolation")
struct AgentConversationStoreTests {
    @Test func visibleCanonicalClaimNeverMergesPrivateContextsAndSurvivesReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-canonical-claim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json"), agent = UUID(), origin = UUID(), otherOrigin = UUID(), canonical = UUID()
        let store = try AgentConversationStore(url: url)
        try await store.appendExchange(accountID: "local", originID: origin, agentID: agent,
            incoming: .init(role: .assistant, text: "ONLY_ORIGIN_ONE"), response: "OWN_RESULT_ONE")
        try await store.appendExchange(accountID: "local", originID: otherOrigin, agentID: agent,
            incoming: .init(role: .assistant, text: "ONLY_ORIGIN_TWO"), response: "OWN_RESULT_TWO")
        let one = try await store.context(accountID: "local", originID: origin, agentID: agent)
        let two = try await store.context(accountID: "local", originID: otherOrigin, agentID: agent)
        for (scope, before) in [(origin, one), (otherOrigin, two)] {
            var expected = before; expected.projectionConversationID = canonical
            let actual = try await store.bindProjection(accountID: "local", originID: scope, agentID: agent,
                expectedContextID: before.conversationID, conversationID: canonical)
            expectNoDifference(actual, expected)
            expectNoDifference(actual.transcriptConversationID, canonical)
            let bytes = try Data(contentsOf: url)
            let repeated = try await store.bindProjection(accountID: "local", originID: scope, agentID: agent,
                expectedContextID: before.conversationID, conversationID: canonical)
            expectNoDifference(repeated, expected); expectNoDifference(try Data(contentsOf: url), bytes)
            let reopened = try AgentConversationStore(url: url)
            let restored = try await reopened.context(accountID: "local", originID: scope, agentID: agent)
            expectNoDifference(restored, expected)
        }
        #expect(one.conversationID != two.conversationID)
        let foreign = try await store.context(accountID: "other", originID: origin, agentID: agent)
        expectNoDifference(foreign.messages, []); expectNoDifference(foreign.projectionConversationID, nil)
        #expect(foreign.conversationID != canonical && foreign.conversationID != one.conversationID)
    }

    @Test(arguments: ["context", "origin", "destination", "stale-context", "different-account", "different-agent", "different-origin", "prior-claim", "commit"])
    func invalidCanonicalClaimCannotChangeAnyStoredValue(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-canonical-denied-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json"), agent = UUID(), origin = UUID(), canonical = UUID()
        let store = try AgentConversationStore(url: url)
        var expected = try await store.context(accountID: "local", originID: origin, agentID: agent)
        if mode == "context" { try await store.retireProjection(conversationID: expected.conversationID) }
        if mode == "origin" { try await store.retireProjection(conversationID: origin) }
        if mode == "destination" { try await store.retireProjection(conversationID: canonical) }
        if mode == "prior-claim" {
            expected = try await store.bindProjection(accountID: "local", originID: origin, agentID: agent,
                expectedContextID: expected.conversationID, conversationID: UUID())
        }
        let before = try Data(contentsOf: url)
        await #expect(throws: CancellationError.self) {
            try await store.bindProjection(accountID: mode == "different-account" ? "foreign" : "local",
                originID: mode == "different-origin" ? UUID() : origin, agentID: mode == "different-agent" ? UUID() : agent,
                expectedContextID: mode == "stale-context" ? UUID() : expected.conversationID, conversationID: canonical,
                commit: { operation in if mode == "commit" { throw CancellationError() }; try operation() })
        }
        let after = try await store.context(accountID: "local", originID: origin, agentID: agent)
        expectNoDifference(after, expected); expectNoDifference(try Data(contentsOf: url), before)
        let reopened = try AgentConversationStore(url: url)
        let restored = try await reopened.context(accountID: "local", originID: origin, agentID: agent)
        expectNoDifference(restored, expected)
    }

    @Test func failedCanonicalSaveDoesNotClaimPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-canonical-write-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json"), store = try AgentConversationStore(url: url)
        let origin = UUID(), agent = UUID()
        let before = try await store.context(accountID: "local", originID: origin, agentID: agent)
        try FileManager.default.moveItem(at: url, to: root.appending(path: "backup.json"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await store.bindProjection(accountID: "local", originID: origin, agentID: agent,
                expectedContextID: before.conversationID, conversationID: UUID())
        }
        let actual = try await store.context(accountID: "local", originID: origin, agentID: agent)
        expectNoDifference(actual, before)
        let reopened = try AgentConversationStore(url: root.appending(path: "backup.json"))
        let restored = try await reopened.context(accountID: "local", originID: origin, agentID: agent)
        expectNoDifference(restored, before)
    }

    @Test func projectionRetirementSurvivesRestartWithoutErasingContext() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-projection-retire-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json")
        let store = try AgentConversationStore(url: url)
        let origin = UUID(), agent = UUID()
        try await store.appendExchange(accountID: "local", originID: origin, agentID: agent,
            incoming: .init(role: .assistant, text: "Task"), response: "Report")
        let before = try await store.context(accountID: "local", originID: origin, agentID: agent)
        try await store.retireProjection(conversationID: before.conversationID)
        let bytes = try Data(contentsOf: url)
        try await store.retireProjection(conversationID: before.conversationID)
        expectNoDifference(try Data(contentsOf: url), bytes)
        let reopened = try AgentConversationStore(url: url)
        let retired = await reopened.isProjectionRetired(conversationID: before.conversationID)
        #expect(retired)
        let unrelated = await reopened.isProjectionRetired(conversationID: origin)
        #expect(!unrelated)
        let after = try await reopened.context(accountID: "local", originID: origin, agentID: agent)
        expectNoDifference(after, before)
    }

    @Test func legacyStoreHasNoGuessedRetirements() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-projection-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "contexts.json")
        try Data(#"{"records":[],"mailboxes":[]}"#.utf8).write(to: url)
        let store = try AgentConversationStore(url: url)
        let retired = await store.isProjectionRetired(conversationID: UUID())
        #expect(!retired)
    }

    @Test func failedRetirementDoesNotClaimPersistence() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-projection-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json")
        let store = try AgentConversationStore(url: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let id = UUID()
        await #expect(throws: (any Error).self) { try await store.retireProjection(conversationID: id) }
        let retired = await store.isProjectionRetired(conversationID: id)
        #expect(!retired)
    }

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
