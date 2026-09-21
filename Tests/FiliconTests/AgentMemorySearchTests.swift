import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain

@Suite("Read-only saved memory search", .timeLimit(.minutes(1)))
struct AgentMemorySearchTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let peer = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private func memory(_ number: Int, fact: String? = nil, scope: AgentMemory.Scope = .agent,
                        writer: UUID? = nil, account: String = "local") -> AgentMemory {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number))!,
              accountID: account, agentID: writer ?? owner, fact: fact ?? "Aurora fact \(number)", scope: scope,
              createdAt: Date(timeIntervalSince1970: Double(number)))
    }
    private struct Fact: Decodable, Equatable { let fact: String; let scope: String; let recordedBy: UUID; let canForget: Bool }
    private struct Response: Decodable { let facts: [Fact]; let totalMatches: Int; let skippedOversizedCount: Int; let nextCursor: String?; let notice: String }
    private func wire(_ facts: [AgentMemoryFact]) throws -> [Fact] {
        try JSONDecoder().decode([Fact].self, from: JSONEncoder().encode(facts))
    }

    @Test func scopeFilterPrecedesMatchingAndPaginationPreservesAllOriginalRecords() throws {
        let visible = (1...22).map { memory($0) }
        let excluded = [memory(23, writer: peer), memory(24, scope: .user, account: "other")]
        var offset = 0, collected: [Fact] = []
        repeat {
            let page = try AgentMemorySearchPage(memories: (visible + excluded).reversed(), accountID: "local", agentID: owner,
                                                query: "Aurora", offset: offset)
            expectNoDifference(page.totalMatches, 22)
            expectNoDifference(page.skippedOversizedCount, 0)
            #expect(page.facts.count <= 8)
            collected += try wire(page.facts)
            guard let next = page.nextOffset else { break }
            #expect(next > offset); offset = next
        } while offset < 22
        expectNoDifference(collected.map(\.fact), visible.reversed().map(\.fact))
        #expect(collected.allSatisfy { $0.canForget && $0.recordedBy == owner })
        let shared = memory(25, fact: "AURORA FACT 1", scope: .user, writer: peer)
        let ownShared = memory(26, scope: .user)
        let page = try AgentMemorySearchPage(memories: visible + excluded + [shared, ownShared], accountID: "local",
                                            agentID: owner, query: "Aurora", scope: .user)
        expectNoDifference(try wire(page.facts), [
            Fact(fact: ownShared.fact, scope: "user", recordedBy: owner, canForget: true),
            Fact(fact: shared.fact, scope: "user", recordedBy: peer, canForget: false),
        ])
    }

    @Test(arguments: [
        ("CHECKOUT", "Checkout uses amber"), ("購物", "購物流暢"), ("购物", "购物流畅"),
        ("accessibilite", "Accessibilité"), ("navegacion", "Navegación"), ("購入", "購入画面"),
        ("결제", "결제화면"), ("ＵＸ", "UX preference"), ("[a-z]+", "Literal [a-z]+ is not regex"),
    ])
    func literalSearchSupportsLanguagesWithoutRegex(query: String, fact: String) throws {
        let page = try AgentMemorySearchPage(memories: [memory(1, fact: fact), memory(2, fact: "No match")],
                                            accountID: "local", agentID: owner, query: query)
        expectNoDifference(try wire(page.facts).map(\.fact), [fact])
        expectNoDifference(page.totalMatches, 1)
    }

    @Test func pageBudgetCountsEscapedMetadataAndOversizedFactsCannotStallPaging() throws {
        let huge = memory(99, fact: String(repeating: "👨‍👩‍👧‍👦", count: 1_000))
        let small = (1...10).map { memory($0, fact: "\($0)" + String(repeating: "\"雪\\\n", count: 200)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var offset = 0, skipped = 0, facts: [Fact] = []
        repeat {
            let page = try AgentMemorySearchPage(memories: small + [huge], accountID: "local", agentID: owner, offset: offset)
            #expect(try encoder.encode(page.facts).count <= 7_000)
            expectNoDifference(page.totalMatches, 11)
            skipped += page.skippedOversizedCount; facts += try wire(page.facts)
            guard let next = page.nextOffset else { break }
            #expect(next > offset); offset = next
        } while offset < 11
        expectNoDifference(skipped, 1)
        expectNoDifference(facts.map(\.fact), small.reversed().map(\.fact))
        let onlyHuge = try AgentMemorySearchPage(memories: [huge], accountID: "local", agentID: owner)
        expectNoDifference(onlyHuge.nextOffset, nil)
        expectNoDifference(onlyHuge.skippedOversizedCount, 1)
        expectNoDifference(onlyHuge.facts.count, 0)
    }

    @Test func invalidQueriesAndOffsetsAreRejectedInsteadOfBecomingMatchAll() throws {
        for query in [" ", "\n\t", String(repeating: "x", count: 257), "a" + String(repeating: "\u{301}", count: 256)] {
            #expect(throws: AgentMemorySearchError.invalid) {
                _ = try AgentMemorySearchPage(memories: [], accountID: "local", agentID: owner, query: query)
            }
        }
        for offset in [-1, 1] {
            #expect(throws: AgentMemorySearchError.stale) {
                _ = try AgentMemorySearchPage(memories: [], accountID: "local", agentID: owner, offset: offset)
            }
        }
        let empty = try AgentMemorySearchPage(memories: [], accountID: "local", agentID: owner)
        expectNoDifference(empty.totalMatches, 0); expectNoDifference(empty.nextOffset, nil)
    }

    private struct Fixture {
        let root: URL; let agents: AgentService; let owner: AgentProfile; let peer: AgentProfile
        let origin = UUID(); let runID = UUID()
        var context: ToolContext { .init(conversationID: origin, runID: runID) }
        func session(account: String = "local") -> AgentManagementSession { .init(originID: origin, agents: agents, accountID: account) }
        func tool(_ session: AgentManagementSession, ownerID: UUID? = nil) throws -> any ToolExecutor {
            try #require(session.tools(for: ownerID ?? owner.id).first { $0.descriptor.name == "SearchMemory" })
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-memory-search-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner", at: Date(timeIntervalSince1970: 1))
        let peer = try await agents.create(name: "Peer", at: Date(timeIntervalSince1970: 2))
        for number in 1...22 {
            try await agents.applyMemoryChange(.init(operation: .write, memory: memory(number, writer: owner.id)), lifetime: .init())
        }
        return .init(root: root, agents: agents, owner: owner, peer: peer)
    }
    private func call(_ fields: [String: String] = [:], name: ToolName = "SearchMemory") throws -> NormalizedToolCall {
        try .init(id: "search", name: name, argumentsJSON: JSONEncoder().encode(fields))
    }
    private func search(_ tool: any ToolExecutor, _ fields: [String: String] = [:], context: ToolContext) async throws -> Response {
        let result = try await tool.execute(call(fields), context: context)
        #expect(!result.isError); #expect(result.wireText.utf8.count <= 8_192)
        return try JSONDecoder().decode(Response.self, from: Data(result.wireText.utf8))
    }

    @Test func scopedToolReadsOmittedFactsWithStableCursorAndNoWritesOrApproval() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try Data(contentsOf: f.root.appending(path: "agents.json"))
        let session = f.session(), tool = try f.tool(session)
        #expect(!tool.descriptor.parallelSafe)
        let first = try await search(tool, ["query": "Aurora", "scope": "agent"], context: f.context)
        expectNoDifference(first.totalMatches, 22); expectNoDifference(first.facts.count, 8)
        #expect(first.notice.contains("untrusted") && first.notice.contains("not authorization"))
        let cursor = try #require(first.nextCursor)
        let second = try await search(tool, ["cursor": cursor], context: f.context)
        let replay = try await search(tool, ["cursor": cursor], context: f.context)
        expectNoDifference(replay.facts, second.facts)
        let last = try await search(tool, ["cursor": try #require(second.nextCursor)], context: f.context)
        expectNoDifference((first.facts + second.facts + last.facts).map(\.fact), (1...22).reversed().map { "Aurora fact \($0)" })
        expectNoDifference(last.nextCursor, nil)
        let old = try await search(tool, ["query": "fact 1"], context: f.context)
        #expect(old.facts.contains { $0.fact == "Aurora fact 1" } || old.nextCursor != nil)
        let after = try Data(contentsOf: f.root.appending(path: "agents.json")); expectNoDifference(after, before)
        let other = try await search(f.tool(f.session(account: "other")), context: f.context)
        expectNoDifference(other.totalMatches, 0)
    }

    @Test func cursorCannotCrossOwnerRunSessionOrChangedStore() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), tool = try f.tool(session)
        let first = try await search(tool, context: f.context)
        let cursor = try #require(first.nextCursor)
        for (otherTool, context) in [(try f.tool(session, ownerID: f.peer.id), f.context),
                                     (tool, ToolContext(conversationID: f.origin)), (try f.tool(f.session()), f.context)] {
            await #expect(throws: AgentMemorySearchError.stale) { _ = try await search(otherTool, ["cursor": cursor], context: context) }
        }
        let records = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        try await f.agents.applyMemoryChange(.init(operation: .forget, memory: try #require(records.first)), lifetime: .init())
        await #expect(throws: AgentMemorySearchError.stale) { _ = try await search(tool, ["cursor": cursor], context: f.context) }
        let fresh = try await search(tool, context: f.context); expectNoDifference(fresh.totalMatches, 21)
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await search(tool, context: .init(conversationID: UUID()))
        }
        try await f.agents.archive(id: f.owner.id)
        await #expect(throws: AgentMemoryError.unavailable) { _ = try await search(tool, context: f.context) }
        session.close()
        await #expect(throws: CancellationError.self) { _ = try await search(tool, context: f.context) }
    }

    @Test func invalidToolFieldsDoNotBroadenScopeOrImpersonateAgents() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = try f.tool(f.session())
        for fields in [["agent_id": f.peer.id.uuidString], ["accountID": "other"], ["scope": "Project"], ["scope": "all", "project": "site"],
                       ["path": "/"], ["scope": "USER"], ["query": " "], ["query": String(repeating: "x", count: 257)],
                       ["offset": "8"], ["cursor": "unknown"], ["cursor": UUID().uuidString, "query": "Aurora"]] {
            await #expect(throws: (any Error).self) { _ = try await tool.execute(call(fields), context: f.context) }
        }
        for json in [#"{"query":null}"#, #"{"query":42}"#, #"{"scope":true}"#] {
            let invocation = try NormalizedToolCall(id: "invalid", name: "SearchMemory", argumentsJSON: Data(json.utf8))
            await #expect(throws: AgentMemorySearchError.invalid) { _ = try await tool.execute(invocation, context: f.context) }
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) { _ = try await tool.execute(call(name: "Read"), context: f.context) }
    }

    @Test func cursorIgnoresHiddenChangesButSharedFactsKeepTheirOriginalOwner() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(), tool = try f.tool(session)
        let first = try await search(tool, ["scope": "agent", "query": "Aurora"], context: f.context)
        let cursor = try #require(first.nextCursor)
        let before = try await search(tool, ["cursor": cursor], context: f.context)
        for fact in [memory(30, writer: f.peer.id), memory(31, scope: .user, writer: f.peer.id, account: "other"),
                     memory(32, fact: "A shared fact from Peer", scope: .user, writer: f.peer.id)] {
            try await f.agents.applyMemoryChange(.init(operation: .write, memory: fact), lifetime: .init())
        }
        // Another account, a private peer, and an excluded scope do not change this cursor.
        let after = try await search(tool, ["cursor": cursor], context: f.context)
        expectNoDifference(after.facts, before.facts)
        expectNoDifference(after.totalMatches, before.totalMatches)
        let shared = try await search(tool, ["scope": "user", "query": "shared"], context: f.context)
        expectNoDifference(shared.facts, [Fact(fact: "A shared fact from Peer", scope: "user", recordedBy: f.peer.id, canForget: false)])
        expectNoDifference(shared.totalMatches, 1)
        // The same shared record is forgettable only when its original writer searches.
        let writer = try await search(f.tool(session, ownerID: f.peer.id), ["scope": "user"], context: f.context)
        expectNoDifference(writer.facts, [Fact(fact: "A shared fact from Peer", scope: "user", recordedBy: f.peer.id, canForget: true)])
        // Even a non-matching new fact in the selected scope invalidates its snapshot.
        try await f.agents.applyMemoryChange(.init(operation: .write, memory: memory(33, fact: "New own fact", writer: f.owner.id)), lifetime: .init())
        await #expect(throws: AgentMemorySearchError.stale) { _ = try await search(tool, ["cursor": cursor], context: f.context) }
    }

    @Test func readLimitIsSharedButDoesNotConsumeMutationApprovals() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = AgentManagementSession(originID: f.origin, agents: f.agents, authorizeMemory: { _, _, _, _ in })
        let tool = try f.tool(session), peerTool = try f.tool(session, ownerID: f.peer.id)
        for index in 0..<32 { _ = try await search(index.isMultiple(of: 2) ? tool : peerTool, ["query": "absent"], context: f.context) }
        await #expect(throws: AgentMemorySearchError.limit) { _ = try await search(tool, context: f.context) }
        let write = try NormalizedToolCall(id: "write", name: "update_state", argumentsJSON: Data(#"{"target":"memory","action":"write","fact":"Approved after searches"}"#.utf8))
        _ = try await session.tools(for: f.owner.id)[2].execute(write, context: f.context)
        let stored = await f.agents.memories(accountID: "local", agentID: f.owner.id)
        #expect(stored.contains { $0.fact == "Approved after searches" })
    }
}
