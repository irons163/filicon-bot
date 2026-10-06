import Foundation
import Testing
import CustomDump
@testable import FiliconAppServices
import FiliconDomain

@Suite("Durable agent conversation isolation")
struct AgentConversationStoreTests {
    @Test func savedCardInspectionNeverCreatesAContextOrPublisherClaim() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-card-inspection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "contexts.json"), sender = UUID(), recipient = UUID(), visible = UUID()
        let store = try AgentConversationStore(url: url)
        let missingOrigins = await store.mailboxOriginIDs(accountID: "local")
        let missingContext = await store.existingContext(accountID: "local", originID: visible, agentID: recipient)
        expectNoDifference(missingOrigins, []); expectNoDifference(missingContext, nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let origin = try await store.mailboxScope(accountID: "local", senderID: sender, recipientID: recipient)
        let foreign = try await store.mailboxScope(accountID: "foreign", senderID: sender, recipientID: recipient)
        var expected = try await store.context(accountID: "local", originID: origin, agentID: recipient)
        expected = try await store.bindProjection(accountID: "local", originID: origin, agentID: recipient,
            expectedContextID: expected.conversationID, conversationID: visible)
        let bytes = try Data(contentsOf: url)
        let reopened = try AgentConversationStore(url: url)
        for reader in [store, reopened] {
            let origins = await reader.mailboxOriginIDs(accountID: "local")
            let participants = await reader.mailboxParticipants(accountID: "local", originID: origin)
            let context = await reader.existingContext(accountID: "local", originID: origin, agentID: recipient)
            expectNoDifference(origins, [origin])
            expectNoDifference(participants, [sender, recipient].sorted { $0.uuidString < $1.uuidString })
            expectNoDifference(context, expected)
            let foreignParticipants = await reader.mailboxParticipants(accountID: "local", originID: foreign)
            let absentContext = await reader.existingContext(accountID: "foreign", originID: origin, agentID: recipient)
            let senderContext = await reader.existingContext(accountID: "local", originID: origin, agentID: sender)
            expectNoDifference(foreignParticipants, nil); expectNoDifference(absentContext, nil); expectNoDifference(senderContext, nil)
        }
        expectNoDifference(try Data(contentsOf: url), bytes)
        try await store.retireProjection(conversationID: origin)
        let retiredBytes = try Data(contentsOf: url)
        let known = await store.mailboxOriginIDs(accountID: "local")
        let retired = await store.mailboxParticipants(accountID: "local", originID: origin)
        expectNoDifference(known, [origin]); expectNoDifference(retired, nil)
        expectNoDifference(try Data(contentsOf: url), retiredBytes)
    }

    @Test(arguments: ["duplicate-origin", "foreign-duplicate", "foreign-account", "missing-participant", "duplicate-participant", "unsorted", "retired", "duplicate-context"])
    func malformedSavedCardNamespacesAreInspectionOnly(mode: String) async throws {
        struct Mailbox: Codable { let accountID: String; let participants: [UUID]; let conversationID: UUID }
        struct Record: Codable { let accountID: String; let originID: UUID; let agentID: UUID; let context: AgentConversationStore.Context }
        struct Envelope: Codable { var records: [Record]; var mailboxes: [Mailbox]; var retiredProjectionIDs: Set<UUID>? }
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-card-corrupt-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "contexts.json"), origin = UUID(), sender = UUID(), recipient = UUID()
        var participants = [sender, recipient].sorted { $0.uuidString < $1.uuidString }
        if mode == "missing-participant" { participants.removeLast() }
        if mode == "duplicate-participant" { participants = [sender, sender] }
        if mode == "unsorted" { participants.reverse() }
        let mailbox = Mailbox(accountID: mode == "foreign-account" ? "foreign" : "local", participants: participants, conversationID: origin)
        var envelope = Envelope(records: [], mailboxes: [mailbox], retiredProjectionIDs: mode == "retired" ? [origin] : nil)
        if mode == "duplicate-origin" { envelope.mailboxes.append(mailbox) }
        if mode == "foreign-duplicate" { envelope.mailboxes.append(.init(accountID: "foreign", participants: participants, conversationID: origin)) }
        if mode == "duplicate-context" {
            let context = AgentConversationStore.Context(conversationID: UUID(), messages: [])
            let record = Record(accountID: "local", originID: origin, agentID: recipient, context: context)
            envelope.records = [record, record]
        }
        try JSONEncoder().encode(envelope).write(to: url, options: .atomic)
        let bytes = try Data(contentsOf: url), store = try AgentConversationStore(url: url)
        let origins = await store.mailboxOriginIDs(accountID: "local")
        let actualParticipants = await store.mailboxParticipants(accountID: "local", originID: origin)
        let context = await store.existingContext(accountID: "local", originID: origin, agentID: recipient)
        expectNoDifference(origins, mode == "foreign-account" ? [] : [origin])
        expectNoDifference(actualParticipants, mode == "duplicate-context" ? participants : nil)
        expectNoDifference(context, nil)
        expectNoDifference(try Data(contentsOf: url), bytes)
    }

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
