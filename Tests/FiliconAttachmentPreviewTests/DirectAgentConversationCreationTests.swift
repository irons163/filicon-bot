import CustomDump
import CSQLite
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import Foundation
import Testing
@testable import Filicon

@Suite("Create bound direct conversations") @MainActor
struct DirectAgentConversationCreationTests {
    @Test(arguments: ["success", "write-failure", "archived", "foreign", "running"])
    func syncUsesLiveAgentWithoutChangingIdentityOrHistory(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-bound-sync-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        var agent = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "",
            providerID: "fake", modelID: "fake-stream"))
        let id = try #require(await model.addConversation(agentID: agent.id))
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].messages = [.init(role: .user, text: "Keep this history",
            createdAt: Date(timeIntervalSince1970: 1000))]
        DirectMessageAddressing.assignMissing(in: &model.conversations[ci])
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(model.conversations[ci], replacingLoadedMessageIDs: [], historyComplete: true)
        let binding = model.conversations[ci].agentBinding
        let before = model.conversations[ci]
        agent.modelID = "updated-model"
        #expect(await model.updateAgent(agent))
        if mode == "archived" { await model.archiveAgent(id: agent.id) }
        if mode == "foreign" { model.conversations[ci].agentBinding = .init(accountID: "other", agentID: agent.id) }
        if mode == "running" { model.running.insert(id) }
        var database: OpaquePointer?
        defer { if let database { sqlite3_close(database) } }
        if mode == "write-failure" {
            #expect(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
            #expect(sqlite3_exec(database, "CREATE TRIGGER reject_sync BEFORE UPDATE ON conversations BEGIN SELECT RAISE(ABORT, 'test sync failure'); END", nil, nil, nil) == SQLITE_OK)
        }
        let snapshot = model.conversations[ci]
        let synced = await model.syncAgentModel(conversationID: id)
        expectNoDifference(synced, mode == "success")
        var expected = snapshot
        if mode == "success" { expected.modelID = "updated-model" }
        expectNoDifference(model.conversations[ci], expected)
        expectNoDifference(model.synchronizingAgentConversations, [])
        let saved = try #require(try await store.conversation(id: id))
        expectNoDifference(saved.agentBinding, binding)
        expectNoDifference(saved.messages, before.messages)
        expectNoDifference(saved.modelID, mode == "success" ? "updated-model" : before.modelID)
    }

    @Test func failedDatabaseWriteDoesNotOpenPhantomChat() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-bound-save-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        let agent = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "",
            providerID: "fake", modelID: "fake-stream"))
        var database: OpaquePointer?
        #expect(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TRIGGER reject_test_insert BEFORE INSERT ON conversations BEGIN SELECT RAISE(ABORT, 'test write failure'); END", nil, nil, nil) == SQLITE_OK)
        let before = model.conversations
        let selection = model.selection
        let result = await model.addConversation(agentID: agent.id)
        expectNoDifference(result, nil)
        expectNoDifference(model.conversations, before)
        expectNoDifference(model.selection, selection)
        expectNoDifference(model.isCreatingAgentConversation, false)
        #expect(model.errorMessage != nil)
    }

    @Test func createsDurableBoundHistoryWithoutRepurposingExistingChat() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-create-bound-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        let original = try #require(model.selectedConversation)
        let agent = try #require(await model.createAgent(name: "Designer", summary: "Design",
            instructions: "Check contrast", providerID: "fake", modelID: "fake-stream"))
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let created = await model.addConversation(agentID: agent.id, id: id, now: Date(timeIntervalSince1970: 1000))
        expectNoDifference(created, id)
        expectNoDifference(model.selection, id)
        expectNoDifference(model.conversations.first(where: { $0.id == original.id }), original)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        expectNoDifference(saved.agentBinding, .init(accountID: "local", agentID: agent.id))
        expectNoDifference(saved.title, "Designer")
        expectNoDifference(saved.messages, [])
        expectNoDifference(saved.providerID, agent.providerID)
        expectNoDifference(saved.modelID, agent.modelID)
        expectNoDifference(saved.updatedAt, Date(timeIntervalSince1970: 1000))
        // Generic model controls cannot silently detach or override this identity.
        let beforeModelChange = model.conversations
        model.updateRoute(providerID: "other", modelID: "other")
        expectNoDifference(model.conversations, beforeModelChange)
        expectNoDifference(model.isCreatingAgentConversation, false)
    }

    @Test(arguments: [false, true])
    func missingOrArchivedAgentDoesNotCreateOrNavigate(archived: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reject-bound-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.bootstrap()
        let agent = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "",
            providerID: "fake", modelID: "fake-stream"))
        if archived { await model.archiveAgent(id: agent.id) }
        let before = model.conversations
        let selection = model.selection
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        let result = await model.addConversation(agentID: archived ? agent.id : id, id: id)
        expectNoDifference(result, nil)
        expectNoDifference(model.conversations, before)
        expectNoDifference(model.selection, selection)
        expectNoDifference(model.isCreatingAgentConversation, false)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try await store.conversation(id: id)
        expectNoDifference(saved, nil)
    }
}
