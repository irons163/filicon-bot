import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
import FiliconAppServices
import FiliconDomain

@Suite("Approved collaboration project membership", .timeLimit(.minutes(1)))
struct AgentProjectChangeTests {
    private let now = Date(timeIntervalSince1970: 2_000)
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let owner: AgentProfile
        let peer: AgentProfile
        let context: ToolContext
        var file: URL { root.appending(path: "agents.json") }
        func session(account: String = "local",
                     authorize: @escaping AgentManagementSession.ProjectAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.ProjectCommitter? = nil) -> AgentManagementSession {
            .init(originID: context.conversationID, agents: agents, accountID: account,
                  now: { Date(timeIntervalSince1970: 2_000) }, authorizeProject: authorize, commitProject: commit)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-project-test-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Designer", instructions: "PRIVATE_OWNER", at: now)
        let peer = try await agents.create(name: "Engineer", instructions: "PRIVATE_PEER", at: now.addingTimeInterval(1))
        return .init(root: root, agents: agents, owner: owner, peer: peer, context: .init(conversationID: UUID()))
    }
    private func call(_ fields: [String: Any] = ["target": "project", "action": "create", "project": "site", "name": "Website"],
                      id: ToolCallID = "project") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: JSONSerialization.data(withJSONObject: fields))
    }
    private func apply(_ f: Fixture, owner: UUID? = nil, action: AgentProjectAction = .create, slug: String = "site",
                       account: String = "local", name: String? = "Website", summary: String? = "Public metadata") async throws -> AgentProjectChange {
        let change = try await f.agents.proposeProjectChange(accountID: account, agentID: owner ?? f.owner.id, action: action,
            slug: slug, name: action == .create ? name : nil, summary: action == .create ? summary : nil, at: now)
        try await f.agents.applyProjectChange(change, lifetime: .init())
        return change
    }

    @Test func defaultAuthorizationRejectsWithoutPersistingAnything() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.file)
        let session = AgentManagementSession(originID: f.context.conversationID, agents: f.agents)
        defer { session.close() }
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await session.tools(for: f.owner.id)[2].execute(call(), context: f.context)
        }
        expectNoDifference(try Data(contentsOf: f.file), before)
    }

    @Test func legacyStoreAndPrivateMemoryStayIntactAcrossProjectWrites() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let memory = AgentMemory(id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000019")!,
            accountID: "local", agentID: f.owner.id, fact: "PRIVATE_FACT", createdAt: now)
        try await f.agents.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.file)) as? [String: Any])
        old.removeValue(forKey: "projects")
        try JSONSerialization.data(withJSONObject: old).write(to: f.file)
        let migrated = try AgentService(storeURL: f.file)
        let empty = await migrated.projects(accountID: "local"); expectNoDifference(empty, [])
        let change = try await migrated.proposeProjectChange(accountID: "local", agentID: f.peer.id,
            action: .create, slug: "a", name: "Public", at: now)
        try await migrated.applyProjectChange(change, lifetime: .init())
        let ownFacts = await migrated.memoryContext(accountID: "local", agentID: f.owner.id)
        let peerFacts = await migrated.memoryContext(accountID: "local", agentID: f.peer.id)
        expectNoDifference(ownFacts, [memory]); expectNoDifference(peerFacts, [])
        let profiles = await migrated.list(); expectNoDifference(profiles, [f.owner, f.peer])
        let files = try FileManager.default.contentsOfDirectory(atPath: f.root.path)
        expectNoDifference(files, ["agents.json"])
        let session = AgentManagementSession(originID: f.context.conversationID, agents: migrated,
            authorizeMemory: { _, _, _, _ in Issue.record("Unsupported project memory reached approval") })
        defer { session.close() }
        await #expect(throws: (any Error).self) {
            _ = try await session.tools(for: f.peer.id)[2].execute(call(["target": "memory", "action": "write", "scope": "project", "project": "a", "fact": "UNSHARED"]), context: f.context)
        }
        let restored = try AgentService(storeURL: f.file)
        let after = await restored.projects(accountID: "local")
        expectNoDifference(after, [change.proposed])
    }

    @Test func approvalPreservesProfilesAndCreateIsJoinNeverOverwritesMetadata() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let created = try await apply(f)
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender, f.peer)
            expectNoDifference(change.previous, created.proposed)
            expectNoDifference(change.proposed.name, "Website")
            expectNoDifference(change.proposed.summary, "Public metadata")
            expectNoDifference(change.proposed.memberIDs, [f.owner.id, f.peer.id])
            #expect(!change.createsProject)
            let before = await f.agents.projects(accountID: "local")
            expectNoDifference(before, [created.proposed])
        })
        defer { session.close() }
        let tool = session.tools(for: f.peer.id)[2]
        let proposal = try call(["target": "project", "action": "create", "project": "site", "name": "Ignored", "description": "Not overwritten"])
        let result = try await tool.execute(proposal, context: f.context)
        #expect(result.wireText.contains("Joined existing"))
        let saved = try #require(await f.agents.projects(accountID: "local").first)
        var expected = created.proposed
        expected.memberIDs.insert(f.peer.id); expected.revision = saved.revision
        expectNoDifference(saved, expected)
        #expect(saved.revision != created.proposed.revision)
        let replay = try await tool.execute(proposal, context: f.context)
        expectNoDifference(replay, result)
        let reopened = try AgentService(storeURL: f.file)
        let durable = await reopened.projects(accountID: "local"), profiles = await reopened.list()
        expectNoDifference(durable, [saved]); expectNoDifference(profiles, [f.owner, f.peer])
        let left = try await apply(f, owner: f.peer.id, action: .leave)
        var expectedLeft = saved; expectedLeft.memberIDs.remove(f.peer.id); expectedLeft.revision = left.proposed.revision
        expectNoDifference(left.proposed, expectedLeft)
        let empty = try await apply(f, action: .leave)
        #expect(empty.proposed.memberIDs.isEmpty)
        let retained = await f.agents.projects(accountID: "local")
        expectNoDifference(retained, [empty.proposed])
        let rejoined = try await apply(f, action: .join)
        expectNoDifference(rejoined.proposed.memberIDs, [f.owner.id])
    }

    @Test func accountIsolationAndDirectoryDoNotDisclosePrivateData() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await apply(f)
        _ = try await apply(f, account: "other", name: "OTHER_ACCOUNT_MARKER", summary: "OTHER_DESCRIPTION")
        let session = f.session(); defer { session.close() }
        let provider = try #require(session.tools(for: f.peer.id)[2] as? any ToolRuntimeContextProviding)
        let text = try await provider.runtimeContext(for: f.context)
        #expect(text.contains(#""slug":"site""#) && text.contains(#""joined":false"#))
        for secret in ["OTHER_ACCOUNT_MARKER", "OTHER_DESCRIPTION", "PRIVATE_OWNER", "PRIVATE_PEER", f.owner.id.uuidString, "Public metadata"] {
            #expect(!text.contains(secret))
        }
        let current = await f.agents.projects(accountID: "local")
        expectNoDifference(current, [first.proposed])
        await #expect(throws: AgentProjectError.unavailable) {
            _ = try await f.agents.proposeProjectChange(accountID: "absent", agentID: f.owner.id, action: .join, slug: "site")
        }
    }

    @Test func malformedFieldsNeverReachApprovalOrChangeStorage() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid request reached approval") }); defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2], before = try Data(contentsOf: f.file)
        let base: [String: Any] = ["target": "project", "action": "create", "project": "site", "name": "Website"]
        var cases: [[String: Any]] = []
        for slug in ["", ".", "..", "../site", "/tmp/site", "UPPER", "網站", "two words", "a--b", "-a", "a-", "a_b", String(repeating: "a", count: 65)] {
            var value = base; value["project"] = slug; cases.append(value)
        }
        for (key, values): (String, [Any]) in [("name", ["", "  ", "line\nnext", String(repeating: "中", count: 67), true, NSNull()]),
            ("description", [String(repeating: "a", count: 1001), "x\u{0}", "\nhello", NSNull()]),
            ("action", ["delete", "set", "write", 1]), ("project", [true, NSNull()])] {
            for raw in values { var value = base; value[key] = raw; cases.append(value) }
        }
        for key in ["agent_id", "accountID", "path", "permissions", "fact", "scope"] {
            var value = base; value[key] = "forbidden"; cases.append(value)
        }
        for action in ["join", "leave"] { var value = base; value["action"] = action; cases.append(value) }
        for missing in ["project", "name", "action"] { var value = base; value.removeValue(forKey: missing); cases.append(value) }
        for value in cases {
            await #expect(throws: AgentProjectError.invalid) { _ = try await tool.execute(call(value), context: f.context) }
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(call(), context: .init(conversationID: UUID())) }
        expectNoDifference(try Data(contentsOf: f.file), before)
    }

    @Test func normalizedLimitsNoOpAndMissingMembers() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(); defer { session.close() }
        _ = try await session.tools(for: f.owner.id)[2].execute(call(["target": "project", "action": "create", "project": " site ",
            "name": " " + String(repeating: "a", count: 200) + " ", "description": String(repeating: "b", count: 1_000)]), context: f.context)
        let saved = try #require(await f.agents.projects(accountID: "local").first)
        expectNoDifference(saved.slug, "site"); expectNoDifference(saved.name.utf8.count, 200)
        expectNoDifference(saved.createdAt, now)
        for action: AgentProjectAction in [.join, .create] {
            await #expect(throws: AgentProjectError.unchanged) { _ = try await apply(f, action: action) }
        }
        await #expect(throws: AgentProjectError.unchanged) { _ = try await apply(f, owner: f.peer.id, action: .leave) }
        await #expect(throws: AgentProjectError.unavailable) { _ = try await apply(f, owner: UUID()) }
    }

    @Test(arguments: ["stale", "aba", "archive", "disk"])
    func freshnessAndAtomicRollback(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try await apply(f)
        let session = f.session(authorize: { _, _, _, _ in
            if mode == "archive" { try await f.agents.archive(id: f.peer.id); return }
            if mode == "disk" {
                try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
                try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false); return
            }
            _ = try await apply(f, action: .leave)
            if mode == "aba" { _ = try await apply(f, action: .join) }
        })
        defer { session.close() }
        await #expect(throws: (any Error).self) {
            _ = try await session.tools(for: f.peer.id)[2].execute(call(["target": "project", "action": "join", "project": "site"]), context: f.context)
        }
        let saved = try #require(await f.agents.projects(accountID: "local").first)
        if mode == "disk" || mode == "archive" { expectNoDifference(saved, original.proposed) }
        else {
            var expected = original.proposed; expected.revision = saved.revision
            if mode == "stale" { expected.memberIDs = [] }
            expectNoDifference(saved, expected); #expect(saved.revision != original.proposed.revision)
        }
        if mode == "disk" {
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.moveItem(at: f.root.appending(path: "backup.json"), to: f.file)
            let reopened = try AgentService(storeURL: f.file)
            let durable = await reopened.projects(accountID: "local")
            expectNoDifference(durable, [original.proposed])
        }
    }

    @Test func createRaceAndProjectCapacityAreRecheckedAtCommit() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let pending = try await f.agents.proposeProjectChange(accountID: "local", agentID: f.owner.id, action: .create, slug: "site", name: "First", at: now)
        let actual = try await apply(f, owner: f.peer.id, name: "Concurrent")
        await #expect(throws: AgentProjectError.stale) { try await f.agents.applyProjectChange(pending, lifetime: .init()) }
        let late = try await f.agents.proposeProjectChange(accountID: "local", agentID: f.owner.id, action: .create, slug: "late", name: "Late", at: now)
        for index in 1...49 { _ = try await apply(f, slug: "project-\(index)") }
        await #expect(throws: AgentProjectError.limit) { try await f.agents.applyProjectChange(late, lifetime: .init()) }
        await #expect(throws: AgentProjectError.limit) { _ = try await apply(f, slug: "overflow") }
        let saved = try #require(await f.agents.projects(accountID: "local").first(where: { $0.slug == "site" }))
        expectNoDifference(saved, actual.proposed)
        _ = try await apply(f, action: .join) // Joining at capacity is still allowed.
    }

    @Test(arguments: [false, true]) func stopRevokesApprovalAndDelayedCommit(duringCommit: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ProjectGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            try await f.agents.applyProjectChange(change, lifetime: lifetime)
        })
        let tool = session.tools(for: f.owner.id)[2]
        let task = Task { try await tool.execute(call(), context: f.context) }
        await gate.entered()
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(), context: f.context) }
        session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let after = await f.agents.projects(accountID: "local")
        expectNoDifference(after, [])
    }

    @Test func receiptSurvivesPostCommitFailureAndBudgetIsShared() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            try await f.agents.applyProjectChange(change, lifetime: lifetime)
            throw CancellationError() // UI/quota refresh failed after durable save.
        })
        defer { session.close() }
        let tool = session.tools(for: f.owner.id)[2]
        for index in 0..<4 {
            let c = try call(["target": "project", "action": "create", "project": "site-\(index)", "name": "Website"], id: .init(rawValue: "p-\(index)"))
            let result = try await tool.execute(c, context: f.context)
            #expect(!result.isError)
            let replay = try await tool.execute(c, context: f.context); expectNoDifference(replay, result)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) { _ = try await tool.execute(call(), context: f.context) }
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tool.execute(call(["target": "profile", "action": "set", "name": "New"], id: "profile"), context: f.context)
        }
        let profiles = await f.agents.list(); expectNoDifference(profiles, [f.owner, f.peer])
    }
}

private actor ProjectGate {
    private var held: CheckedContinuation<Void, Never>?
    private var enteredGate = false
    func hold() async { enteredGate = true; await withCheckedContinuation { held = $0 } }
    func entered() async { while !enteredGate { await Task.yield() } }
    func release() { held?.resume(); held = nil }
}
