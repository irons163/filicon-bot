import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor ProfileChangeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        await withCheckedContinuation {
            continuation = $0; entered = true
            observer?.resume(); observer = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Approved agent profile tools", .timeLimit(.minutes(1)))
struct AgentManagementSessionTests {
    private struct Fixture: Sendable {
        let root: URL
        let agents: AgentService
        let sender: AgentProfile
        let target: AgentProfile
        let origin = UUID()
        var store: URL { root.appending(path: "agents.json") }
        var context: ToolContext { .init(conversationID: origin) }
        func session(authorize: @escaping AgentManagementSession.Authorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.Committer? = nil) -> AgentManagementSession {
            .init(originID: origin, agents: agents, authorize: authorize, commit: commit ?? { change, lifetime in
                try await agents.applyProfileChange(change, lifetime: lifetime, at: Date(timeIntervalSince1970: 2_000))
            })
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-profile-tools-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Engineer", instructions: "PRIVATE_ENGINEER_CONTEXT", providerID: "fixture", modelID: "test", at: Date(timeIntervalSince1970: 1_000))
        let target = try await agents.create(name: "Designer", summary: "Public design role", instructions: "PRIVATE_DESIGN_CONTEXT",
                                             providerID: "different-provider", modelID: "different-model", title: "Visual designer",
                                             avatar: .init(kind: .pet, petID: "dewey"), at: Date(timeIntervalSince1970: 1_001))
        return .init(root: root, agents: agents, sender: sender, target: target)
    }
    private func call(_ fields: [String: String], operation: String = "CreateAgent", id: ToolCallID = "change") throws -> NormalizedToolCall {
        try .init(id: id, name: .init(rawValue: operation), argumentsJSON: JSONEncoder().encode(fields))
    }

    @Test func approvedCreateIsDurableIdempotentAndDoesNotCopyPrivateProfile() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = f.context
        let tool = session.tools(for: f.sender.id)[0]
        let invocation = try call(["name": " Writer ", "description": " Write concise copy "])
        let result = try await tool.execute(invocation, context: context)
        let replay = try await tool.execute(invocation, context: context)
        expectNoDifference(replay, result)
        let profiles = await f.agents.list()
        let created = try #require(profiles.first { $0.name == "Writer" })
        expectNoDifference(profiles.count, 3)
        expectNoDifference(created.summary, "Write concise copy")
        expectNoDifference(created.instructions, "Write concise copy")
        expectNoDifference(created.providerID, f.sender.providerID)
        expectNoDifference(created.modelID, f.sender.modelID)
        expectNoDifference(created.avatar, nil)
        expectNoDifference(created.title, "")
        #expect(result.wireText.lowercased().contains(created.id.uuidString.lowercased()))
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call(["name": "Writer", "description": "Write concise copy"], id: "other"), context: context)
        }
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call(["name": "Different"], id: "change"), context: context)
        }
        session.close()
        await #expect(throws: CancellationError.self) { _ = try await tool.execute(invocation, context: context) }
        let reopened = try AgentService(storeURL: f.store)
        let restored = await reopened.profile(id: created.id)
        expectNoDifference(restored, created)
    }

    @Test func defaultDenialAndInvalidFieldsNeverMutate() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.origin, agents: f.agents)
        let create = session.tools(for: f.sender.id)[0], update = session.tools(for: f.sender.id)[1]
        let before = await f.agents.list()
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await create.execute(call(["name": "Writer"]), context: f.context)
        }
        for fields in [["name": ""], ["name": String(repeating: "x", count: 121)],
                       ["name": "Writer", "description": String(repeating: "x", count: 2_001)],
                       ["name": "Writer", "providerID": "override"], ["name": "Writer", "instructions": "secret"],
                       ["name": "Writer", "permissions": "all"], [:]] {
            await #expect(throws: AgentProfileChangeError.invalidFields) {
                _ = try await create.execute(call(fields), context: f.context)
            }
        }
        for json in [#"{"name":"Writer","description":null}"#, #"{"name":42}"#] {
            await #expect(throws: AgentProfileChangeError.invalidFields) {
                _ = try await create.execute(.init(id: "bad", name: "CreateAgent", argumentsJSON: Data(json.utf8)), context: f.context)
            }
        }
        for fields in [["agent_id": f.target.id.uuidString], ["agent_id": f.target.id.uuidString, "description": "  "],
                       ["name": "No target"]] {
            await #expect(throws: AgentProfileChangeError.invalidFields) {
                _ = try await update.execute(call(fields, operation: "UpdateAgent"), context: f.context)
            }
        }
        for id in [f.sender.id, UUID()] {
            await #expect(throws: AgentProfileChangeError.unavailable) {
                _ = try await update.execute(call(["agent_id": id.uuidString, "name": "New"], operation: "UpdateAgent"), context: f.context)
            }
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await create.execute(call(["name": "Writer"]), context: .init(conversationID: UUID()))
        }
        let after = await f.agents.list()
        expectNoDifference(after, before)
    }

    @Test(arguments: [false, true]) func updateMergesOnlyApprovedPublicFields(rename: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let session = f.session(authorize: { _, _, _, _ in
            // A legitimate concurrent UI edit to private fields must survive.
            var current = try #require(await f.agents.profile(id: f.target.id))
            current.instructions = "NEW_PRIVATE_INSTRUCTIONS"
            current.modelID = "new-model"; current.providerID = "new-provider"
            current.status = .awaitingInput; current.unreadCount = 3
            current.title = "Updated title"; current.avatar = .init(kind: .pet, petID: "hoots")
            try await f.agents.update(current)
        }, commit: { change, lifetime in try await f.agents.applyProfileChange(change, lifetime: lifetime, at: timestamp) })
        var fields = ["agent_id": f.target.id.uuidString]
        fields[rename ? "name" : "description"] = rename ? "Creative director" : "Public accessibility review"
        _ = try await session.tools(for: f.sender.id)[1].execute(call(fields, operation: "UpdateAgent"), context: f.context)
        var expected = f.target
        expected.name = rename ? "Creative director" : expected.name
        expected.summary = rename ? expected.summary : "Public accessibility review"
        expected.instructions = "NEW_PRIVATE_INSTRUCTIONS"; expected.modelID = "new-model"; expected.providerID = "new-provider"
        expected.status = .awaitingInput; expected.unreadCount = 3; expected.title = "Updated title"
        expected.avatar = .init(kind: .pet, petID: "hoots"); expected.updatedAt = timestamp
        let actual = await f.agents.profile(id: f.target.id)
        expectNoDifference(actual, expected)
    }

    @Test(arguments: [false, true]) func publicChangesOrArchivedTargetsInvalidateApproval(archive: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in
            if archive { try await f.agents.archive(id: f.target.id) }
            else {
                var current = f.target; current.name = "Changed in UI"
                try await f.agents.update(current)
            }
        })
        await #expect(throws: archive ? AgentProfileChangeError.unavailable : .stale) {
            _ = try await session.tools(for: f.sender.id)[1].execute(
                call(["agent_id": f.target.id.uuidString, "name": "Overwrite"], operation: "UpdateAgent"), context: f.context)
        }
        let actual = await f.agents.profile(id: f.target.id)
        expectNoDifference(actual?.name, archive ? f.target.name : "Changed in UI")
    }

    @Test(arguments: [false, true]) func closeFencesBothApprovalAndCommitActorHop(duringCommit: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ProfileChangeGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.agents.applyProfileChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.sender.id)[0], context = f.context
        let run = Task { try await tool.execute(call(["name": "Writer"]), context: context) }
        await gate.waitForEntry()
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call(["name": "Writer"], id: "repeat"), context: context)
        }
        session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        let profiles = await f.agents.list()
        expectNoDifference(profiles.count, 2)
    }

    @Test func failedPersistenceRollsBackAndSameCallCanBeRetried() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = f.context
        let tool = session.tools(for: f.sender.id)[0], invocation = try call(["name": "Writer"])
        let before = await f.agents.list()
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.store, to: backup)
        try FileManager.default.createDirectory(at: f.store, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await tool.execute(invocation, context: context) }
        let after = await f.agents.list()
        expectNoDifference(after, before)
        // Remove only the empty blocking directory in this isolated test fixture.
        try FileManager.default.removeItem(at: f.store)
        try FileManager.default.moveItem(at: backup, to: f.store)
        _ = try await tool.execute(invocation, context: context)
        let persisted = await f.agents.list()
        expectNoDifference(persisted.count, 3)
        let reopened = try AgentService(storeURL: f.store)
        let restored = await reopened.list()
        expectNoDifference(restored, persisted)
    }

    @Test func fourChangeLimitAndChangedCreatorModelAreEnforced() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = f.context
        let tool = session.tools(for: f.sender.id)[0]
        for index in 0..<4 {
            _ = try await tool.execute(call(["name": "Member \(index)"], id: .init(rawValue: "create-\(index)")), context: context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tool.execute(call(["name": "Fifth"], id: "fifth"), context: context)
        }
        let staleSession = f.session(authorize: { _, _, _, _ in
            var current = f.sender; current.modelID = "changed-during-approval"
            try await f.agents.update(current)
        })
        await #expect(throws: AgentProfileChangeError.stale) {
            _ = try await staleSession.tools(for: f.sender.id)[0].execute(call(["name": "Wrong model"]), context: f.context)
        }
        let profiles = await f.agents.list()
        expectNoDifference(profiles.count, 6)
    }

    @Test func postCommitFailureReturnsReceiptWithoutDuplicatingTheAgent() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        struct BookkeepingFailure: Error {}
        let session = f.session(commit: { change, lifetime in
            _ = try await f.agents.applyProfileChange(change, lifetime: lifetime)
            throw BookkeepingFailure()
        })
        let tool = session.tools(for: f.sender.id)[0], context = f.context
        let invocation = try call(["name": "Writer"])
        let result = try await tool.execute(invocation, context: context)
        let retry = try await tool.execute(invocation, context: context)
        expectNoDifference(retry, result)
        #expect(!result.isError)
        let profiles = await f.agents.list()
        expectNoDifference(profiles.count, 3)
    }

    @Test(arguments: ["name", "description", "clear"]) func ownProfileUsesFixedIdentityAndPreservesPrivateFields(field: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = f.context
        let tool = session.tools(for: f.target.id)[2]
        var fields = ["target": "profile", "action": "set"]
        fields[field == "name" ? "name" : "description"] = field == "name" ? " Art director " : field == "clear" ? "" : " Public review role "
        let invocation = try call(fields, operation: "update_state")
        let result = try await tool.execute(invocation, context: context)
        let replay = try await tool.execute(invocation, context: context)
        expectNoDifference(replay, result)
        var expected = f.target
        if field == "name" { expected.name = "Art director" }
        else { expected.summary = field == "clear" ? "" : "Public review role" }
        expected.updatedAt = Date(timeIntervalSince1970: 2_000)
        let actual = await f.agents.profile(id: f.target.id)
        expectNoDifference(actual, expected)
        let sender = await f.agents.profile(id: f.sender.id)
        expectNoDifference(sender, f.sender)
        #expect(!result.wireText.contains("PRIVATE_DESIGN_CONTEXT"))
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call(fields, operation: "update_state", id: "duplicate"), context: context)
        }
        let restored = try AgentService(storeURL: f.store)
        let durable = await restored.profile(id: f.target.id)
        expectNoDifference(durable, expected)
    }

    @Test func ownProfileRejectsOtherStateRoutesFieldsAndIdentitySpoofing() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.origin, agents: f.agents)
        let tool = session.tools(for: f.sender.id)[2]
        let before = await f.agents.list()
        let base = ["target": "profile", "action": "set", "name": "New name"]
        var invalid: [[String: String]] = [[:], ["target": "profile", "action": "set"],
            ["action": "set", "name": "New name"], ["target": "profile", "name": "New name"],
            ["target": "profile", "action": "set", "name": "  "],
            ["target": "profile", "action": "set", "description": String(repeating: "x", count: 2_001)]]
        for target in ["routine", "workflow", "settings", "channel", "project", "PROFILE"] {
            var fields = base; fields["target"] = target; invalid.append(fields)
        }
        for action in ["write", "delete", "archive", "create", "SET"] {
            var fields = base; fields["action"] = action; invalid.append(fields)
        }
        for field in ["agent_id", "id", "senderID", "instructions", "permissions", "providerID", "modelID"] {
            var fields = base; fields[field] = f.target.id.uuidString; invalid.append(fields)
        }
        for fields in invalid {
            await #expect(throws: AgentProfileChangeError.invalidFields) {
                _ = try await tool.execute(call(fields, operation: "update_state"), context: f.context)
            }
        }
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await tool.execute(call(base, operation: "update_state"), context: f.context)
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(call(base, operation: "update_state"), context: .init(conversationID: UUID()))
        }
        let spoofed = AgentProfileChange(operation: .setOwnProfile, requesterID: f.sender.id, targetID: f.target.id,
            name: "Wrong target", description: "", providerID: f.target.providerID, modelID: f.target.modelID,
            previousName: f.target.name, previousDescription: f.target.summary)
        await #expect(throws: AgentProfileChangeError.unavailable) {
            _ = try await f.agents.applyProfileChange(spoofed, lifetime: .init())
        }
        let after = await f.agents.list()
        expectNoDifference(after, before)
    }

    @Test(arguments: ["stale", "archive", "private"]) func ownProfileRechecksTheLatestProfileBeforeSaving(mutation: String) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in
            var current = f.target
            switch mutation {
            case "stale": current.summary = "Changed by user"
            case "archive": current.archivedAt = Date(timeIntervalSince1970: 1_500)
            default:
                current.instructions = "NEW_PRIVATE_CONTEXT"
                current.modelID = "updated-model"
            }
            try await f.agents.update(current)
        })
        let tool = session.tools(for: f.target.id)[2]
        let invocation = try call(["target": "profile", "action": "set", "name": "New name"], operation: "update_state")
        if mutation == "private" {
            _ = try await tool.execute(invocation, context: f.context)
        } else {
            await #expect(throws: mutation == "stale" ? AgentProfileChangeError.stale : .unavailable) {
                _ = try await tool.execute(invocation, context: f.context)
            }
        }
        let actual = try #require(await f.agents.profile(id: f.target.id))
        expectNoDifference(actual.name, mutation == "private" ? "New name" : f.target.name)
        expectNoDifference(actual.summary, mutation == "stale" ? "Changed by user" : f.target.summary)
        expectNoDifference(actual.instructions, mutation == "private" ? "NEW_PRIVATE_CONTEXT" : f.target.instructions)
        expectNoDifference(actual.modelID, mutation == "private" ? "updated-model" : f.target.modelID)
    }

    @Test(arguments: [false, true]) func ownProfileCannotCommitAfterScopeCloses(duringCommit: Bool) async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ProfileChangeGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.agents.applyProfileChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.target.id)[2]
        let run = Task { try await tool.execute(call(["target": "profile", "action": "set", "name": "Late name"], operation: "update_state"), context: f.context) }
        await gate.waitForEntry()
        session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        let actual = await f.agents.profile(id: f.target.id)
        expectNoDifference(actual, f.target)
    }

    @Test func profileChangeBudgetIsSharedByAllThreeTools() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), context = f.context
        let tools = session.tools(for: f.sender.id)
        _ = try await tools[0].execute(call(["name": "Writer"], id: "create"), context: context)
        _ = try await tools[1].execute(call(["agent_id": f.target.id.uuidString, "name": "Artist"], operation: "UpdateAgent", id: "update"), context: context)
        for index in 0..<2 {
            _ = try await tools[2].execute(call(["target": "profile", "action": "set", "name": "Engineer \(index)"],
                                                 operation: "update_state", id: .init(rawValue: "self-\(index)")), context: context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tools[2].execute(call(["target": "profile", "action": "set", "name": "Fifth change"],
                                                 operation: "update_state", id: "fifth"), context: context)
        }
        let actual = await f.agents.profile(id: f.sender.id)
        expectNoDifference(actual?.name, "Engineer 1")
    }
}
