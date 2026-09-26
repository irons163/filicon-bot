import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

@Suite("Approved project memory", .timeLimit(.minutes(1)))
struct AgentProjectMemoryTests {
    private let now = Date(timeIntervalSince1970: 2_000)
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let writer: AgentProfile
        let reader: AgentProfile
        let outsider: AgentProfile
        let context: ToolContext
        var file: URL { root.appending(path: "agents.json") }
        func session(account: String = "local", authorize: @escaping AgentManagementSession.MemoryAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.MemoryCommitter? = nil) -> AgentManagementSession {
            .init(originID: context.conversationID, agents: agents, accountID: account,
                now: { Date(timeIntervalSince1970: 2_000) }, authorizeMemory: authorize, commitMemory: commit)
        }
    }
    private func membership(_ f: Fixture, agent: UUID, slug: String = "site", account: String = "local", action: AgentProjectAction = .create) async throws {
        let change = try await f.agents.proposeProjectChange(accountID: account, agentID: agent, action: action,
            slug: slug, name: action == .create ? "Website" : nil, at: now)
        try await f.agents.applyProjectChange(change, lifetime: .init())
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-project-memory-\(UUID())")
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        let writer = try await service.create(name: "Engineer", instructions: "WRITER_PRIVATE", at: now)
        let reader = try await service.create(name: "Designer", instructions: "READER_PRIVATE", at: now)
        let outsider = try await service.create(name: "Outsider", at: now)
        let f = Fixture(root: root, agents: service, writer: writer, reader: reader, outsider: outsider, context: .init(conversationID: UUID()))
        try await membership(f, agent: writer.id)
        try await membership(f, agent: reader.id, action: .join)
        return f
    }
    private func call(_ fact: String = "Use accessible amber buttons", action: String = "write", project: String = "site", id: ToolCallID = "memory") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: JSONEncoder().encode([
            "target": "memory", "action": action, "fact": fact, "scope": "project", "project": project]))
    }
    private func write(_ f: Fixture, fact: String, agent: UUID? = nil, project: String = "site", tier: AgentMemory.Tier = .log) async throws -> AgentMemoryChange {
        let change = try await f.agents.proposeProjectMemoryChange(accountID: "local", agentID: agent ?? f.writer.id,
            slug: project, operation: .write, fact: fact, tier: tier, at: now)
        try await f.agents.applyMemoryChange(change, lifetime: .init())
        return change
    }
    private struct Fact: Decodable, Equatable { let fact: String; let project: String?; let canForget: Bool }
    private struct Page: Decodable { let facts: [Fact]; let nextCursor: String?; let totalMatches: Int }
    private func search(_ tool: any ToolExecutor, _ fields: [String: String], context: ToolContext) async throws -> Page {
        let result = try await tool.execute(.init(id: "search", name: "SearchMemory", argumentsJSON: JSONEncoder().encode(fields)), context: context)
        return try JSONDecoder().decode(Page.self, from: Data(result.wireText.utf8))
    }

    @Test func explicitApprovalOwnWriterAndDurableProvenance() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let denied = AgentManagementSession(originID: f.context.conversationID, agents: f.agents)
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await denied.tools(for: f.writer.id)[2].execute(call(), context: f.context)
        }
        let before = try Data(contentsOf: f.file)
        let session = f.session(authorize: { agent, change, _, _ in
            expectNoDifference(agent, f.writer)
            expectNoDifference(change.memory.scope, .project)
            expectNoDifference(change.memory.project, "site")
            expectNoDifference(change.project?.memberIDs, [f.writer.id, f.reader.id])
            expectNoDifference(try Data(contentsOf: f.file), before)
        })
        defer { session.close(); denied.close() }
        let tool = session.tools(for: f.writer.id)[2], invocation = try call()
        let result = try await tool.execute(invocation, context: f.context)
        let replay = try await tool.execute(invocation, context: f.context); expectNoDifference(replay, result)
        let saved = try #require(await f.agents.projectMemoriesForEditor(accountID: "local").first)
        let reopened = try AgentService(storeURL: f.file)
        let durable = await reopened.memoryContext(accountID: "local", agentID: f.reader.id)
        expectNoDifference(durable, [saved])
        let page = try await search(session.tools(for: f.reader.id)[3], ["scope": "project", "project": "site"], context: f.context)
        expectNoDifference(page.facts, [.init(fact: saved.fact, project: "site", canForget: false)])
        await #expect(throws: AgentMemoryError.stale) {
            _ = try await session.tools(for: f.reader.id)[2].execute(call(action: "forget", id: "peer-forget"), context: f.context)
        }
        let forgot = f.session(); defer { forgot.close() }
        _ = try await forgot.tools(for: f.writer.id)[2].execute(call(action: "forget"), context: f.context)
        let empty = await f.agents.projectMemoriesForEditor(accountID: "local"); expectNoDifference(empty, [])
    }

    @Test func membershipAccountAndPrivateMemoryRemainIsolated() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let project = try await write(f, fact: "SHARED_PROJECT")
        let privateFact = AgentMemory(accountID: "local", agentID: f.writer.id, fact: "PRIVATE_FACT", createdAt: now)
        try await f.agents.applyMemoryChange(.init(operation: .write, memory: privateFact), lifetime: .init())
        try await membership(f, agent: f.writer.id, slug: "secret")
        let secret = try await write(f, fact: "SECRET_PROJECT", project: "secret")
        let outsider = await f.agents.memoryContext(accountID: "local", agentID: f.outsider.id)
        expectNoDifference(outsider, [])
        let reader = await f.agents.memoryContext(accountID: "local", agentID: f.reader.id)
        expectNoDifference(reader, [project.memory])
        let other = await f.agents.memoryContext(accountID: "other", agentID: f.reader.id); expectNoDifference(other, [])
        try await membership(f, agent: f.reader.id, account: "other")
        let otherEmpty = await f.agents.memoryContext(accountID: "other", agentID: f.reader.id); expectNoDifference(otherEmpty, [])
        // Pure consumers default to no project access, even for the writer's own records.
        let all = [privateFact, project.memory, secret.memory]
        let safe = try AgentMemoryRecall(memories: all, accountID: "local", agentID: f.writer.id)
        expectNoDifference(safe.memories, [privateFact])
        let selected = try AgentMemoryRecall(memories: all, accountID: "local", agentID: f.reader.id, joinedProjects: ["site"])
        expectNoDifference(selected.memories, [project.memory])
        let rawPage = try AgentMemorySearchPage(memories: all, accountID: "local", agentID: f.reader.id)
        expectNoDifference(rawPage.totalMatches, 0)
        try await membership(f, agent: f.reader.id, action: .leave)
        let departed = await f.agents.memoryContext(accountID: "local", agentID: f.reader.id); expectNoDifference(departed, [])
        try await membership(f, agent: f.reader.id, action: .join)
        let rejoined = await f.agents.memoryContext(accountID: "local", agentID: f.reader.id); expectNoDifference(rejoined, reader)
        try await f.agents.archive(id: f.reader.id)
        let archived = await f.agents.memoryContext(accountID: "local", agentID: f.reader.id); expectNoDifference(archived, [])
    }

    @Test(arguments: ["leave", "aba", "peer-leave", "archive", "stop", "disk"])
    func pendingWritesFailClosedWhenAudienceOrLifetimeChanges(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let change = try await f.agents.proposeProjectMemoryChange(accountID: "local", agentID: f.writer.id, slug: "site", operation: .write, fact: "Pending", at: now)
        let lifetime = AgentMemoryChangeLifetime()
        if mode == "leave" || mode == "aba" { try await membership(f, agent: f.writer.id, action: .leave) }
        if mode == "aba" { try await membership(f, agent: f.writer.id, action: .join) }
        if mode == "peer-leave" { try await membership(f, agent: f.reader.id, action: .leave) }
        if mode == "archive" { try await f.agents.archive(id: f.writer.id) }
        if mode == "stop" { lifetime.close() }
        if mode == "disk" {
            try FileManager.default.moveItem(at: f.file, to: f.root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        }
        let before = await f.agents.persistentStateSnapshot()
        await #expect(throws: (any Error).self) { try await f.agents.applyMemoryChange(change, lifetime: lifetime) }
        let after = await f.agents.persistentStateSnapshot()
        // Dictionary/Set ordering is not a JSON wire guarantee; compare decoded full documents.
        let lhs = try JSONSerialization.jsonObject(with: #require(before)) as? NSDictionary
        let rhs = try JSONSerialization.jsonObject(with: #require(after)) as? NSDictionary
        expectNoDifference(rhs, lhs)
        #expect(!lifetime.committed(change))
    }

    @Test func strictScopeAndMissingMembershipNeverReachApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _ in Issue.record("Invalid project request reached approval") }); defer { session.close() }
        var cases: [[String: Any]] = []
        let base: [String: Any] = ["target": "memory", "action": "write", "fact": "x", "scope": "project", "project": "site"]
        for project in ["", "../site", "Site", " site", "site ", "a--b", String(repeating: "a", count: 65)] {
            var fields = base; fields["project"] = project; cases.append(fields)
        }
        for scope in ["agent", "user"] { var fields = base; fields["scope"] = scope; cases.append(fields) }
        for key in ["agent_id", "accountID", "path", "permissions"] { var fields = base; fields[key] = "x"; cases.append(fields) }
        var missing = base; missing.removeValue(forKey: "project"); cases.append(missing)
        for fields in cases {
            await #expect(throws: (any Error).self) {
                _ = try await session.tools(for: f.writer.id)[2].execute(.init(id: "bad", name: "update_state", argumentsJSON: JSONSerialization.data(withJSONObject: fields)), context: f.context)
            }
        }
        await #expect(throws: AgentMemoryError.projectUnavailable) {
            _ = try await session.tools(for: f.outsider.id)[2].execute(call(), context: f.context)
        }
        let other = f.session(account: "other", authorize: { _, _, _, _ in Issue.record("Cross-account approval") }); defer { other.close() }
        await #expect(throws: AgentMemoryError.projectUnavailable) { _ = try await other.tools(for: f.writer.id)[2].execute(call(), context: f.context) }
        let values = await f.agents.projectMemoriesForEditor(accountID: "local"); expectNoDifference(values, [])
    }

    @Test func limitsAreSharedPerProjectAndEditorCanRemoveDepartedAuthors() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await write(f, fact: "Same fact", tier: .profile)
        await #expect(throws: AgentMemoryError.projectDuplicate) { _ = try await write(f, fact: "Same fact", agent: f.reader.id) }
        for i in 1..<8 { _ = try await write(f, fact: "Profile \(i)", tier: .profile) }
        _ = try await write(f, fact: "Ninth foundation", agent: f.reader.id, tier: .profile)
        for i in 8..<48 { _ = try await write(f, fact: "Log \(i)", agent: f.reader.id) }
        _ = try await write(f, fact: "Retained beyond recall")
        try await membership(f, agent: f.writer.id, slug: "other")
        _ = try await write(f, fact: "Same fact", project: "other")
        try await membership(f, agent: f.writer.id, action: .leave)
        await #expect(throws: AgentMemoryError.projectUnavailable) {
            _ = try await f.agents.proposeProjectMemoryChange(accountID: "local", agentID: f.writer.id, slug: "site", operation: .forget, fact: first.memory.fact)
        }
        try await f.agents.archive(id: f.writer.id)
        try await f.agents.forgetMemoryFromEditor(first.memory, lifetime: .init())
        let remaining = await f.agents.projectMemoriesForEditor(accountID: "local")
        #expect(!remaining.contains(first.memory)); expectNoDifference(remaining.count, 50)
        var paged: [AgentMemory] = []
        for index in 0..<3 {
            let page = await f.agents.memoryEditorPage(accountID: "local", agentID: f.reader.id, scope: .project, index: index)
            #expect(page.memories.count <= 20)
            paged.append(contentsOf: page.memories)
        }
        expectNoDifference(paged, remaining)
    }

    @Test func boundedRecallSeparatesProjectDuplicatesAndSearchFencesMembershipABA() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for i in 0..<20 { _ = try await write(f, fact: "Fact \(i)") }
        try await membership(f, agent: f.reader.id, slug: "other")
        _ = try await write(f, fact: "Fact 0", agent: f.reader.id, project: "other")
        let access = try await f.agents.memoryAccess(accountID: "local", agentID: f.reader.id)
        let recall = try AgentMemoryRecall(memories: access.memories, accountID: "local", agentID: f.reader.id, query: .init("Fact 0"), joinedProjects: access.joinedProjects)
        #expect(recall.memories.count <= 20 && recall.factsJSON.utf8.count <= 3_000)
        // The same text in different projects remains distinct when it fits the budget.
        let duplicates = access.memories.filter { $0.fact == "Fact 0" }
        let distinct = try AgentMemoryRecall(memories: duplicates, accountID: "local", agentID: f.reader.id, joinedProjects: access.joinedProjects)
        expectNoDifference(distinct.memories.count, 2)
        let session = f.session(); defer { session.close() }
        let tool = session.tools(for: f.reader.id)[3]
        let page = try await search(tool, ["scope": "project", "project": "site"], context: f.context)
        expectNoDifference(page.totalMatches, 20)
        let cursor = try #require(page.nextCursor)
        try await membership(f, agent: f.reader.id, action: .leave)
        await #expect(throws: AgentMemoryError.projectUnavailable) { _ = try await search(tool, ["cursor": cursor], context: f.context) }
        try await membership(f, agent: f.reader.id, action: .join)
        await #expect(throws: AgentMemorySearchError.stale) { _ = try await search(tool, ["cursor": cursor], context: f.context) }
        let runtime = try #require(session.tools(for: f.reader.id)[2] as? any ToolRuntimeContextProviding)
        let text = try await runtime.runtimeContext(for: f.context)
        #expect(text.contains(#""project":"site""#))
        #expect(!text.contains("WRITER_PRIVATE"))
    }

    @Test func projectRecallSelectsThreeAndBudgetsEachProjectIndependently() throws {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var records: [AgentMemory] = []
        func record(_ project: String, _ fact: String, _ date: Double, tier: AgentMemory.Tier = .log, account: String = "local") -> AgentMemory {
            .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", records.count))!,
                accountID: account, agentID: owner, fact: fact, tier: tier, scope: .project,
                project: project, createdAt: Date(timeIntervalSince1970: date))
        }
        for (slug, date) in [("alpha", 30.0), ("beta", 20.0), ("gamma", 20.0), ("delta", 10.0)] {
            for index in 0..<35 {
                records.append(record(slug, "Foundation \(index)", date, tier: .profile))
                records.append(record(slug, "Recent \(index)", date))
            }
        }
        records.append(record("outsider", "Never visible", 9_999))
        records.append(record("delta", "Other account", 9_999, account: "other"))
        let joined: Set<String> = ["alpha", "beta", "gamma", "delta", "empty"]
        let recall = try AgentMemoryRecall(memories: records, accountID: "local", agentID: owner, joinedProjects: joined)
        expectNoDifference(recall.injectedProjects, ["alpha", "beta", "gamma"])
        expectNoDifference(recall.alsoMemberOf, ["delta", "empty"])
        expectNoDifference(Set(recall.memories.compactMap(\.project)), Set(["alpha", "beta", "gamma"]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for slug in recall.injectedProjects {
            for (profile, limit, bytes) in [(true, 25, 2_500), (false, 10, 1_500)] {
                let pool = recall.memories.filter { $0.project == slug && ($0.tier == .profile) == profile }
                #expect(!pool.isEmpty && pool.count <= limit)
                #expect(try encoder.encode(pool.map { AgentMemoryFact($0, readerID: owner) }).count <= bytes)
            }
        }
        #expect(recall.factsJSON.utf8.count <= 12_000)
        expectNoDifference(recall.omittedCount, 280 - recall.memories.count)
        let reversed = try AgentMemoryRecall(memories: records.reversed(), accountID: "local", agentID: owner, joinedProjects: joined)
        expectNoDifference(reversed.factsJSON, recall.factsJSON)
        expectNoDifference(reversed.injectedProjects, recall.injectedProjects)
        // A fourth project's history is not deleted or made inaccessible by injection selection.
        let search = try AgentMemorySearchPage(memories: records, accountID: "local", agentID: owner,
            query: "Foundation", scope: .project, joinedProjects: joined)
        expectNoDifference(search.totalMatches, 140)
        let left = try AgentMemoryRecall(memories: records, accountID: "local", agentID: owner, joinedProjects: joined.subtracting(["alpha"]))
        expectNoDifference(left.injectedProjects, ["beta", "gamma", "delta"])
        #expect(!left.memories.contains { $0.project == "alpha" })
        let empty = try AgentMemoryRecall(memories: [], accountID: "local", agentID: owner, joinedProjects: joined)
        expectNoDifference(empty.injectedProjects, ["alpha", "beta", "delta"])
        expectNoDifference(empty.alsoMemberOf, ["empty", "gamma"])
    }

    @Test func unselectedProjectRemainsSearchableThroughRuntimeTools() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for slug in ["alpha", "beta", "gamma", "zeta"] {
            try await membership(f, agent: f.reader.id, slug: slug)
            _ = try await write(f, fact: "Saved \(slug)", agent: f.reader.id, project: slug)
        }
        let session = f.session(); defer { session.close() }
        let runtime = try #require(session.tools(for: f.reader.id)[2] as? any ToolRuntimeContextProviding)
        let text = try await runtime.runtimeContext(for: f.context)
        #expect(text.contains("Selected project slugs (untrusted data): [\"alpha\",\"beta\",\"gamma\"]"))
        #expect(text.contains("Other joined project slugs (untrusted data): [\"zeta\",\"site\"]"))
        #expect(!text.contains("Saved zeta"))
        let page = try await search(session.tools(for: f.reader.id)[3], ["scope": "project", "project": "zeta"], context: f.context)
        expectNoDifference(page.facts.map(\.fact), ["Saved zeta"])
        try await membership(f, agent: f.reader.id, slug: "alpha", action: .leave)
        let updated = try await runtime.runtimeContext(for: f.context)
        #expect(updated.contains("Saved zeta"))
        #expect(!updated.contains("Saved alpha"))
    }

    @Test func malformedStoredScopesFailClosedAndProjectCharacterBudgetIsAggregate() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let memory = AgentMemory(accountID: "local", agentID: f.writer.id, fact: "x", createdAt: now)
        let encoded = try JSONEncoder().encode(memory)
        let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (scope, slug) in [("project", nil), ("project", "../site"), ("project", ""), ("agent", "site"), ("user", "site")] as [(String, String?)] {
            var object = original; object["scope"] = scope; object["project"] = slug
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(AgentMemory.self, from: JSONSerialization.data(withJSONObject: object))
            }
        }
        var legacy = original; legacy.removeValue(forKey: "scope")
        expectNoDifference(try JSONDecoder().decode(AgentMemory.self, from: JSONSerialization.data(withJSONObject: legacy)), memory)
        for i in 0..<12 {
            _ = try await write(f, fact: String(repeating: "文", count: 998) + String(format: "%02d", i), agent: i.isMultiple(of: 2) ? f.writer.id : f.reader.id)
        }
        _ = try await write(f, fact: "x")
        let stored = await f.agents.projectMemoriesForEditor(accountID: "local")
        expectNoDifference(stored.count, 13)
        expectNoDifference(stored.reduce(0) { $0 + $1.fact.count }, 12_001)
    }

    @Test func forgetApprovalCannotSurviveMembershipABA() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let saved = try await write(f, fact: "Keep until approved")
        let change = try await f.agents.proposeProjectMemoryChange(accountID: "local", agentID: f.writer.id,
            slug: "site", operation: .forget, fact: saved.memory.fact)
        try await membership(f, agent: f.writer.id, action: .leave)
        try await membership(f, agent: f.writer.id, action: .join)
        let lifetime = AgentMemoryChangeLifetime()
        await #expect(throws: AgentMemoryError.stale) { try await f.agents.applyMemoryChange(change, lifetime: lifetime) }
        let records = await f.agents.projectMemoriesForEditor(accountID: "local")
        expectNoDifference(records, [saved.memory]); #expect(!lifetime.committed(change))
    }

    @Test func projectIdentityParticipatesInReplayAndSharedFourChangeBudget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await membership(f, agent: f.writer.id, slug: "other")
        let session = f.session(); defer { session.close() }
        let tool = session.tools(for: f.writer.id)[2]
        let first = try call("Shared", id: "one")
        let result = try await tool.execute(first, context: f.context)
        let replay = try await tool.execute(first, context: f.context); expectNoDifference(replay, result)
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(call("Shared", project: "other", id: "one"), context: f.context)
        }
        _ = try await tool.execute(call("Shared", project: "other", id: "two"), context: f.context)
        _ = try await tool.execute(call("Third", id: "three"), context: f.context)
        _ = try await tool.execute(call("Fourth", id: "four"), context: f.context)
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await tool.execute(call("Fifth", id: "five"), context: f.context)
        }
        let records = await f.agents.projectMemoriesForEditor(accountID: "local"); expectNoDifference(records.count, 4)
    }
}
