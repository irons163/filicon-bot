import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor AvatarGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        await withCheckedContinuation {
            waiter = $0; entered = true; observer?.resume(); observer = nil
        }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

@Suite("Approved own-avatar changes", .timeLimit(.minutes(1)))
struct AgentAvatarChangeTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let owner: AgentProfile
        let peer: AgentProfile
        let context: ToolContext
        var file: URL { root.appending(path: "agents.json") }
        func session(authorize: @escaping AgentManagementSession.AvatarAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.AvatarCommitter? = nil) -> AgentManagementSession {
            .init(originID: context.conversationID, agents: agents, authorize: { _, _, _, _ in },
                  now: { Date(timeIntervalSince1970: 3_000) }, authorizeMemory: { _, _, _, _ in },
                  authorizeAvatar: authorize, commitAvatar: commit ?? { change, lifetime in
                      try await agents.applyAvatarChange(change, lifetime: lifetime, at: Date(timeIntervalSince1970: 2_000))
                  })
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-avatar-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Designer", summary: "Public design", instructions: "PRIVATE_PERSONA",
            providerID: "fixture", modelID: "test", title: "Design", avatar: .pet(.dewey), at: Date(timeIntervalSince1970: 1_000))
        let peer = try await agents.create(name: "Engineer", instructions: "PRIVATE_PEER", avatar: .pet(.rocky), at: Date(timeIntervalSince1970: 1_001))
        return .init(root: root, agents: agents, owner: owner, peer: peer,
                     context: .init(conversationID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!))
    }
    private func call(_ fields: [String: String], id: ToolCallID = "avatar") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: JSONEncoder().encode(fields))
    }
    private let set = ["target": "avatar", "action": "set", "pet_id": "hoots"]

    @Test(arguments: AgentPetAvatar.allCases)
    func eachPetIsPreviewedBeforeCommitAndPersists(pet: AgentPetAvatar) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { sender, change, _, context in
            expectNoDifference(sender, f.owner)
            expectNoDifference(change.agentID, f.owner.id)
            expectNoDifference(change.previousAvatar, f.owner.avatar)
            expectNoDifference(change.avatar, .pet(pet))
            expectNoDifference(context.conversationID, f.context.conversationID)
            let before = await f.agents.profile(id: f.owner.id)
            expectNoDifference(before, f.owner)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let request = try call(["target": "avatar", "action": "set", "pet_id": pet.rawValue])
        let result = try await tool.execute(request, context: f.context)
        #expect(!result.isError)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        var expected = f.owner; expected.avatar = .pet(pet); expected.updatedAt = Date(timeIntervalSince1970: 2_000)
        let actual = await f.agents.profile(id: f.owner.id)
        expectNoDifference(actual, expected)
        let restored = try AgentService(storeURL: f.file)
        let durable = await restored.profile(id: f.owner.id), peer = await restored.profile(id: f.peer.id)
        expectNoDifference(durable, expected); expectNoDifference(peer, f.peer)
        session.close()
    }

    @Test func clearRestoresCodexAndPreservesCustomImageFiles() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.root.appending(path: "old-avatar.png"), bytes = Data("existing image fixture".utf8)
        try bytes.write(to: source)
        var custom = f.owner
        custom.avatar = .image(hash: "legacy", relativePath: "old-avatar.png", shape: .hexagon)
        try await f.agents.update(custom)
        let session = f.session(), tool = session.tools(for: f.owner.id)[2]
        _ = try await tool.execute(call(["target": "avatar", "action": "clear"]), context: f.context)
        let after = await f.agents.profile(id: f.owner.id)
        expectNoDifference(after?.avatar, .pet(.codex))
        expectNoDifference(try Data(contentsOf: source), bytes)
        session.close()
    }

    @Test func fieldsScopeAndDefaultDenialCannotChangeProfiles() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.context.conversationID, agents: f.agents)
        let tool = session.tools(for: f.owner.id)[2]
        await #expect(throws: AgentMessagingError.approvalRequired) { _ = try await tool.execute(call(set), context: f.context) }
        var invalid = [["target": "avatar", "action": "set"], ["target": "avatar", "action": "clear", "pet_id": "hoots"],
                       ["target": "avatar", "action": "set", "pet_id": "unknown"], ["target": "avatar", "action": "write"],
                       ["target": "avatar", "action": "set", "pet_id": "https://example.invalid/avatar.png"]]
        for field in ["agent_id", "senderID", "path", "url", "name", "instructions", "modelID", "image", "scope", "fact"] {
            var fields = set; fields[field] = f.peer.id.uuidString; invalid.append(fields)
        }
        for fields in invalid {
            await #expect(throws: AgentAvatarChangeError.invalid) { _ = try await tool.execute(call(fields), context: f.context) }
        }
        for json in [#"{"target":"avatar","action":"set","pet_id":null}"#, #"{"target":"avatar","action":"clear","pet_id":false}"#] {
            await #expect(throws: AgentAvatarChangeError.invalid) {
                _ = try await tool.execute(.init(id: "invalid", name: "update_state", argumentsJSON: Data(json.utf8)), context: f.context)
            }
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(call(set), context: .init(conversationID: UUID())) }
        let after = await f.agents.list()
        expectNoDifference(after, [f.owner, f.peer])
        let contextual = try #require(tool as? any ToolRuntimeContextProviding)
        let context = try await contextual.runtimeContext(for: f.context)
        #expect(context.contains("dewey") && context.contains("null-signal"))
        #expect(!context.contains("PRIVATE_") && !context.contains(f.root.path))
    }

    @Test(arguments: ["avatar", "archive", "other-fields", "save-failure"])
    func commitRechecksAvatarAndMergesOnlyApprovedField(mutation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in
            if mutation == "archive" { try await f.agents.archive(id: f.owner.id); return }
            if mutation == "save-failure" {
                try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "agents.backup"))
                try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
                return
            }
            var profile = f.owner
            if mutation == "avatar" { profile.avatar = .pet(.seedy) }
            else { profile.name = "New name"; profile.instructions = "NEW_PRIVATE"; profile.modelID = "new-model" }
            try await f.agents.update(profile)
        })
        let tool = session.tools(for: f.owner.id)[2]
        if mutation == "other-fields" {
            _ = try await tool.execute(call(set), context: f.context)
            let saved = try #require(await f.agents.profile(id: f.owner.id))
            expectNoDifference(saved.avatar, .pet(.hoots)); expectNoDifference(saved.name, "New name")
            expectNoDifference(saved.instructions, "NEW_PRIVATE"); expectNoDifference(saved.modelID, "new-model")
        } else {
            await #expect(throws: (any Error).self) { _ = try await tool.execute(call(set), context: f.context) }
            let saved = try #require(await f.agents.profile(id: f.owner.id))
            expectNoDifference(saved.avatar, mutation == "avatar" ? .pet(.seedy) : f.owner.avatar)
            if mutation == "save-failure" {
                expectNoDifference(saved, f.owner)
                try FileManager.default.removeItem(at: f.file)
                try FileManager.default.moveItem(at: f.root.appending(path: "agents.backup"), to: f.file)
                let restored = try AgentService(storeURL: f.file)
                let durable = await restored.profile(id: f.owner.id)
                expectNoDifference(durable, f.owner)
            }
        }
        session.close()
    }

    @Test(arguments: [false, true]) func stopRevokesApprovalAndDelayedCommit(duringCommit: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = AvatarGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            return try await f.agents.applyAvatarChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let work = Task { try await tool.execute(call(set), context: f.context) }
        await gate.waitForEntry(); session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        let profile = await f.agents.profile(id: f.owner.id)
        expectNoDifference(profile, f.owner)
    }

    @Test func avatarSharesBudgetAndCannotReplayAsAnotherMutation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), tool = session.tools(for: f.owner.id)[2]
        let invocation = try call(set)
        _ = try await tool.execute(invocation, context: f.context)
        for fields in [["target": "avatar", "action": "set", "pet_id": "rocky"], ["target": "avatar", "action": "clear"],
                       ["target": "profile", "action": "set", "name": "Impersonate"]] {
            await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(fields), context: f.context) }
        }
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(set, id: "again"), context: f.context) }
        _ = try await tool.execute(call(["target": "memory", "action": "write", "fact": "Use accessible contrast"], id: "memory"), context: f.context)
        _ = try await tool.execute(call(["target": "profile", "action": "set", "name": "Visual designer"], id: "profile"), context: f.context)
        _ = try await session.tools(for: f.owner.id)[0].execute(.init(id: "create", name: "CreateAgent", argumentsJSON: Data(#"{"name":"Writer"}"#.utf8)), context: f.context)
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tool.execute(call(["target": "avatar", "action": "clear"], id: "fifth"), context: f.context)
        }
        session.close()
    }

    @Test func durableReceiptSurvivesBookkeepingFailure() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            _ = try await f.agents.applyAvatarChange(change, lifetime: lifetime)
            throw AgentAvatarChangeError.invalid
        })
        let tool = session.tools(for: f.owner.id)[2], request = try call(set)
        let result = try await tool.execute(request, context: f.context)
        #expect(!result.isError)
        let replay = try await tool.execute(request, context: f.context)
        expectNoDifference(replay, result)
        let profile = await f.agents.profile(id: f.owner.id)
        expectNoDifference(profile?.avatar, .pet(.hoots))
        session.close()
    }
}
