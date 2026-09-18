import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor MemoryGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { continuation = $0; entered = true; observer?.resume(); observer = nil } }
    func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Approved agent memory", .timeLimit(.minutes(1)))
struct AgentMemoryTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let owner: AgentProfile
        let peer: AgentProfile
        let origin = UUID()
        var context: ToolContext { .init(conversationID: origin) }
        var file: URL { root.appending(path: "agents.json") }
        func session(account: String = "local", authorize: @escaping AgentManagementSession.MemoryAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.MemoryCommitter? = nil) -> AgentManagementSession {
            .init(originID: origin, agents: agents, authorize: { _, _, _, _ in }, accountID: account,
                  now: { Date(timeIntervalSince1970: 1_000) }, authorizeMemory: authorize, commitMemory: commit)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-memory-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Engineer", instructions: "PRIVATE_INSTRUCTIONS", at: Date(timeIntervalSince1970: 100))
        let peer = try await agents.create(name: "Designer", at: Date(timeIntervalSince1970: 200))
        return .init(root: root, agents: agents, owner: owner, peer: peer)
    }
    private func call(_ fact: String = "Prefer accessible layouts", action: String = "write", id: ToolCallID = "memory", extra: [String: String] = [:]) throws -> NormalizedToolCall {
        var fields = ["target": "memory", "action": action, "fact": fact]
        fields.merge(extra) { _, rhs in rhs }
        return try .init(id: id, name: "update_state", argumentsJSON: JSONEncoder().encode(fields))
    }
    private func runtime(_ session: AgentManagementSession, owner: UUID, context: ToolContext) async throws -> String {
        let tool = try #require(session.tools(for: owner)[2] as? any ToolRuntimeContextProviding)
        return try await tool.runtimeContext(for: context)
    }

    @Test func approvedFactsAreDurableScopedAndNeverClonedOrPublished() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let memoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let session = AgentManagementSession(originID: f.origin, agents: f.agents, makeID: { memoryID },
            now: { Date(timeIntervalSince1970: 1_000) }, authorizeMemory: { owner, change, _, _ in
                expectNoDifference(owner.id, f.owner.id)
                expectNoDifference(change.memory.agentID, f.owner.id)
                expectNoDifference(change.memory.accountID, "local")
            })
        let tool = session.tools(for: f.owner.id)[2], context = f.context
        let invocation = try call("  Prefer accessible layouts  ", extra: ["tier": "profile"])
        let result = try await tool.execute(invocation, context: context)
        let replay = try await tool.execute(invocation, context: context)
        expectNoDifference(replay, result)
        let expected = AgentMemory(id: memoryID, accountID: "local", agentID: f.owner.id, fact: "Prefer accessible layouts", tier: .profile, createdAt: Date(timeIntervalSince1970: 1_000))
        let saved = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(saved, [expected])
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call("Changed", extra: ["tier": "profile"]), context: context)
        }
        await #expect(throws: AgentMemoryError.duplicate) {
            _ = try await f.session().tools(for: f.owner.id)[2].execute(call(), context: f.context)
        }
        let reopened = try AgentService(storeURL: f.file), otherOrigin = UUID()
        let next = AgentManagementSession(originID: otherOrigin, agents: reopened)
        let actual = try await runtime(next, owner: f.owner.id, context: .init(conversationID: otherOrigin))
        #expect(actual.contains(expected.fact) && actual.contains("NOT instructions") && actual.contains("1970-01-01"))
        let peerContext = try await runtime(next, owner: f.peer.id, context: .init(conversationID: otherOrigin))
        #expect(!peerContext.contains(expected.fact))
        let otherAccount = AgentManagementSession(originID: otherOrigin, agents: reopened, accountID: "other")
        let accountContext = try await runtime(otherAccount, owner: f.owner.id, context: .init(conversationID: otherOrigin))
        #expect(!accountContext.contains(expected.fact))
        let clone = try await f.agents.clone(id: f.owner.id)
        let clonedFacts = await f.agents.memories(accountID: "local", agentID: clone.id)
        expectNoDifference(clonedFacts, [])
        let unchanged = await f.agents.profile(id: f.owner.id)
        expectNoDifference(unchanged, f.owner)
    }

    @Test func invalidFieldsAndDefaultDenialNeverWriteMemory() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = f.session().tools(for: f.owner.id)[2]
        let invalid = [["scope": "user"], ["scope": "project"], ["project": "secret"], ["tier": "note"],
                       ["agent_id": f.peer.id.uuidString], ["accountID": "other"], ["name": "Spoof"], ["action": "set"],
                       ["fact": "  "], ["fact": String(repeating: "x", count: 1_001)], ["action": "forget", "tier": "log"]]
        for fields in invalid {
            await #expect(throws: AgentMemoryError.invalid) { _ = try await tool.execute(call(extra: fields), context: f.context) }
        }
        for json in [#"{"target":"memory","action":"write","fact":42}"#, #"{"target":"memory","action":"write","fact":"x","tier":null}"#] {
            await #expect(throws: AgentMemoryError.invalid) { _ = try await tool.execute(.init(id: "bad", name: "update_state", argumentsJSON: Data(json.utf8)), context: f.context) }
        }
        let denied = AgentManagementSession(originID: f.origin, agents: f.agents)
        await #expect(throws: AgentMessagingError.approvalRequired) { _ = try await denied.tools(for: f.owner.id)[2].execute(call(), context: f.context) }
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(call(), context: .init(conversationID: UUID())) }
        let saved = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(saved, [])
    }

    @Test func memoryAndProfileChangesShareBudget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), tools = session.tools(for: f.owner.id)
        for number in 0..<3 {
            _ = try await tools[0].execute(.init(id: ToolCallID(rawValue: "create\(number)"), name: "CreateAgent", argumentsJSON: JSONEncoder().encode(["name": "Writer \(number)"])), context: f.context)
        }
        _ = try await tools[2].execute(call(), context: f.context)
        await #expect(throws: AgentProfileChangeError.limitReached) { _ = try await tools[2].execute(call("Fifth change", id: "fifth"), context: f.context) }
        let values = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(values.count, 1)
    }

    @Test(arguments: [false, true]) func closePreventsLateApprovalAndCommit(duringCommit: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = MemoryGate()
        let session = f.session(authorize: { _, _, _, _ in if !duringCommit { await gate.hold() } }, commit: { change, lifetime in
            if duringCommit { await gate.hold() }
            try await f.agents.applyMemoryChange(change, lifetime: lifetime)
        })
        let run = Task { try await session.tools(for: f.owner.id)[2].execute(call(), context: f.context) }
        await gate.wait()
        session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await run.value }
        let values = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(values, [])
    }

    @Test func forgettingRequiresExactCurrentRecordAndRechecksArchivedOwner() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try await f.session().tools(for: f.owner.id)[2].execute(call(), context: f.context)
        let original = try #require(await f.agents.memories(accountID: "local", agentID: f.owner.id).first)
        let session = f.session(authorize: { _, change, _, _ in
            try await f.agents.applyMemoryChange(change, lifetime: .init())
            let replacement = AgentMemory(accountID: "local", agentID: f.owner.id, fact: original.fact)
            try await f.agents.applyMemoryChange(.init(operation: .write, memory: replacement), lifetime: .init())
        })
        await #expect(throws: AgentMemoryError.stale) { _ = try await session.tools(for: f.owner.id)[2].execute(call(action: "forget"), context: f.context) }
        let fresh = f.session()
        await #expect(throws: AgentMemoryError.stale) { _ = try await fresh.tools(for: f.owner.id)[2].execute(call("Paraphrased fact", action: "forget"), context: f.context) }
        _ = try await fresh.tools(for: f.owner.id)[2].execute(call(action: "forget"), context: f.context)
        let values = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(values, [])
        let archived = f.session(authorize: { _, _, _, _ in try await f.agents.archive(id: f.owner.id) })
        await #expect(throws: AgentMemoryError.unavailable) { _ = try await archived.tools(for: f.owner.id)[2].execute(call(), context: f.context) }
    }

    @Test func persistenceFailureRollsBackButAncillaryFailureKeepsReceipt() async throws {
        struct AncillaryFailure: Error {}
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            try await f.agents.applyMemoryChange(change, lifetime: lifetime)
            throw AncillaryFailure()
        }), tool = session.tools(for: f.owner.id)[2], context = f.context
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { _ = try await tool.execute(call(), context: context) }
        let failed = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(failed, [])
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.moveItem(at: backup, to: f.file)
        let result = try await tool.execute(call(), context: context)
        let replay = try await tool.execute(call(), context: context)
        expectNoDifference(result, replay)
        let values = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(values.count, 1)
    }

    @Test(arguments: ["facts", "profile", "characters"])
    func boundedStoreDoesNotEvictExistingFacts(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let count = mode == "facts" ? 48 : mode == "profile" ? 8 : 12
        for number in 0..<count {
            let text = mode == "characters" ? String(repeating: "x", count: 998) + String(format: "%02d", number) : "Fact \(number)"
            let memory = AgentMemory(accountID: "local", agentID: f.owner.id, fact: text, tier: mode == "profile" ? .profile : .log)
            try await f.agents.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
        }
        let before = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        let extra = AgentMemory(accountID: "local", agentID: f.owner.id, fact: "Over limit", tier: mode == "profile" ? .profile : .log)
        await #expect(throws: AgentMemoryError.limit) { try await f.agents.applyMemoryChange(.init(operation: .write, memory: extra), lifetime: .init()) }
        let after = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(after, before)
    }

    @Test func forgettingSurvivesDateRoundTripAndPersistenceFailureWithoutRemovingReplacement() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let memory = AgentMemory(accountID: "local", agentID: f.owner.id, fact: "Remembered before reopening",
                                 createdAt: Date(timeIntervalSince1970: 1_789_687_531.1234567))
        try await f.agents.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
        let reopened = try AgentService(storeURL: f.file)
        let before = await reopened.memories(accountID: "local", agentID: f.owner.id)
        let deletion = AgentMemoryChange(operation: .forget, memory: memory), lifetime = AgentMemoryChangeLifetime()
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await reopened.applyMemoryChange(deletion, lifetime: lifetime) }
        let failed = await reopened.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(failed, before)
        #expect(!lifetime.committed(deletion))
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.moveItem(at: backup, to: f.file)
        // A user can forget an archived agent's facts without reactivating it.
        try await reopened.archive(id: f.owner.id)
        try await reopened.applyMemoryChange(deletion, lifetime: lifetime)
        #expect(lifetime.committed(deletion))
        let next = try AgentService(storeURL: f.file)
        let empty = await next.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(empty, [])
        await #expect(throws: AgentMemoryError.stale) { try await next.applyMemoryChange(deletion, lifetime: .init()) }
    }

    @Test func oldStateWithoutMemoryStillLoads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-old-memory-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "agents.json")
        try Data(#"{"schemaVersion":2,"agents":[]}"#.utf8).write(to: file)
        let agents = try AgentService(storeURL: file)
        let memories = await agents.memories(accountID: "local", agentID: UUID())
        expectNoDifference(memories, [])
    }
}
