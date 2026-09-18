import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private actor GroupPostGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor GroupPostProbe {
    var approved: [AgentGroupAudience] = []
    var runs: [UUID] = []
    var finished: [UUID] = []
    func approve(_ audience: AgentGroupAudience) { approved.append(audience) }
    func run(_ dispatch: AgentGroupDispatch) { runs.append(dispatch.audience.id) }
    func finish(_ id: UUID) { finished.append(id) }
}

@Suite("Group SendToAgent routing", .timeLimit(.minutes(1)))
struct AgentGroupMessagingTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let groups: GroupService
        let messenger: AgentMessenger
        let sender: AgentProfile
        let peer: AgentProfile
        let group: AgentGroup
        let origin = UUID()
        let probe = GroupPostProbe()
        func session(authorize: AgentMessagingSession.GroupAuthorizer? = nil,
                     post: AgentMessagingSession.GroupPoster? = nil) -> AgentMessagingSession {
            let registry = ProviderRegistry()
            return AgentMessagingSession(originConversationID: origin, agents: agents, messenger: messenger,
                registry: registry, coordinator: TurnCoordinator(registry: registry), groups: groups,
                authorizeGroup: authorize ?? { _, audience, _, _, _ in await probe.approve(audience) },
                postGroup: post ?? { dispatch, lifetime in
                    try await groups.postAgentMessage(dispatch.message, audience: dispatch.audience, lifetime: lifetime)
                }, runGroup: { dispatch, _ in await probe.run(dispatch) },
                finishGroup: { id, _ in await probe.finish(id) }, authorize: { _, _, _, _, _ in })
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-post-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Engineer", instructions: "PRIVATE_ENGINEER", providerID: "fixture", modelID: "test", at: Date(timeIntervalSince1970: 1_000))
        let peer = try await agents.create(name: "Designer", instructions: "PRIVATE_DESIGNER", providerID: "fixture", modelID: "test", at: Date(timeIntervalSince1970: 1_001))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Review", memberIDs: [sender.id, peer.id])
        return .init(root: root, agents: agents, groups: groups,
            messenger: try AgentMessenger(service: agents, storeURL: root.appending(path: "messages.json")), sender: sender, peer: peer, group: group)
    }
    private func call(_ target: UUID, text: String = "Review contrast", id: ToolCallID = "send") throws -> NormalizedToolCall {
        try .init(id: id, name: "SendToAgent", argumentsJSON: JSONEncoder().encode(["recipientID": target.uuidString, "message": text]))
    }
    private func entered(_ gate: GroupPostGate) async throws {
        for _ in 0..<500 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw AgentGroupPostError.unavailable
    }

    @Test func directoryContainsOnlyMemberGroupsAndPublicProfiles() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let hidden = try await f.groups.create(name: "PRIVATE_GROUP_NAME", memberIDs: [f.peer.id])
        let session = f.session()
        let tool = session.tool(for: f.sender.id)
        let contextual = try #require(tool as? any ToolRuntimeContextProviding)
        let context = try await contextual.runtimeContext(for: .init(conversationID: f.origin))
        #expect(context.contains(f.group.id.uuidString))
        #expect(!context.contains(hidden.id.uuidString)); #expect(!context.contains("PRIVATE_"))
        let result = try await tool.execute(call(hidden.id), context: .init(conversationID: f.origin))
        #expect(result.isError)
        let posts = await f.groups.messages(groupID: hidden.id)
        expectNoDifference(posts, [])
    }

    @Test func approvalPrecedesDurablePostAndIdempotentDeferredWake() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = GroupPostGate()
        let session = f.session(authorize: { _, audience, _, _, _ in await f.probe.approve(audience); await gate.wait() })
        let tool = session.tool(for: f.sender.id), context = ToolContext(conversationID: f.origin)
        let request = try call(f.group.id)
        let send = Task { try await tool.execute(request, context: context) }
        try await entered(gate)
        let before = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(before, [])
        await gate.release()
        let result = try await send.value
        #expect(!result.isError && result.wireText.contains("NOT completed"))
        let post = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(post.count, 1); expectNoDifference(post.first?.senderID, f.sender.id)
        let restored = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let persisted = await restored.messages(groupID: f.group.id)
        expectNoDifference(persisted.map(\.id), post.map(\.id))
        let replay = try await tool.execute(request, context: context)
        expectNoDifference(replay, result)
        let duplicate = try await tool.execute(call(f.group.id, text: "Different post", id: "again"), context: context)
        #expect(duplicate.isError)
        let beforeRuns = await f.probe.runs
        expectNoDifference(beforeRuns, [])
        try await session.drain()
        let runs = await f.probe.runs, approvals = await f.probe.approved
        expectNoDifference(runs, [f.group.id]); expectNoDifference(approvals.count, 1)
        let mailbox = await f.messenger.allMessages()
        expectNoDifference(mailbox, []) // A shared-room post is not a collection of private DMs.
    }

    @Test(arguments: ["remove", "add", "rename", "archive"])
    func changedAudienceCannotUseOldApproval(mutation: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _, _ in
            switch mutation {
            case "remove": try await f.groups.updateMembers(groupID: f.group.id, memberIDs: [f.peer.id])
            case "add":
                let third = try await f.agents.create(name: "Third", instructions: "", providerID: "fixture", modelID: "test")
                try await f.groups.updateMembers(groupID: f.group.id, memberIDs: [f.sender.id, f.peer.id, third.id])
            case "rename": try await f.groups.update(groupID: f.group.id, name: "Changed", summary: "", memberIDs: f.group.memberIDs)
            default: try await f.agents.archive(id: f.peer.id)
            }
        })
        let result = try await session.tool(for: f.sender.id).execute(call(f.group.id), context: .init(conversationID: f.origin))
        #expect(result.isError)
        let posts = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(posts, [])
    }

    @Test(arguments: [false, true]) func stopFencesApprovalAndCommitHop(duringPost: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = GroupPostGate()
        let session = f.session(authorize: { _, _, _, _, _ in if !duringPost { await gate.wait() } },
            post: { dispatch, lifetime in
                if duringPost { await gate.wait() }
                try await f.groups.postAgentMessage(dispatch.message, audience: dispatch.audience, lifetime: lifetime)
            })
        let request = try call(f.group.id)
        let task = Task { try await session.tool(for: f.sender.id).execute(request, context: .init(conversationID: f.origin)) }
        try await entered(gate)
        session.revokeProfileChanges()
        try await session.close()
        await gate.release()
        await #expect { try await task.value } throws: { $0 is CancellationError || ($0 as? AgentMessagingError) == .closed }
        let posts = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(posts, [])
    }

    @Test func stoppedQueuedWorkKeepsThePostButNeverRuns() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        _ = try await session.tool(for: f.sender.id).execute(call(f.group.id), context: .init(conversationID: f.origin))
        try await session.close()
        try await session.drain()
        let posts = await f.groups.messages(groupID: f.group.id), runs = await f.probe.runs, finished = await f.probe.finished
        expectNoDifference(posts.count, 1); expectNoDifference(runs, []); expectNoDifference(finished, [f.group.id])
    }

    @Test func storageFailureRollsBackAndAllowsRetry() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let url = f.root.appending(path: "groups.json")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let session = f.session(), request = try call(f.group.id), context = ToolContext(conversationID: f.origin)
        let failed = try await session.tool(for: f.sender.id).execute(request, context: context)
        #expect(failed.isError)
        let before = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(before, [])
        try FileManager.default.removeItem(at: url)
        let retry = try await session.tool(for: f.sender.id).execute(request, context: context)
        #expect(!retry.isError)
        let after = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(after.count, 1)
    }

    @Test func groupPostsShareTheTotalCapAndHaveTheirOwnFanoutCap() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let second = try await f.groups.create(name: "Second", memberIDs: f.group.memberIDs)
        let third = try await f.groups.create(name: "Third", memberIDs: f.group.memberIDs)
        let session = f.session(), context = ToolContext(conversationID: f.origin)
        let tool = session.tool(for: f.sender.id)
        for (index, target) in [f.group.id, second.id].enumerated() {
            let result = try await tool.execute(call(target, id: .init(rawValue: "group-\(index)")), context: context)
            #expect(!result.isError)
        }
        let capped = try await tool.execute(call(third.id, id: "third"), context: context)
        #expect(capped.isError)
        for index in 0..<4 {
            let result = try await tool.execute(call(f.peer.id, text: "Task \(index)", id: .init(rawValue: "peer-\(index)")), context: context)
            #expect(!result.isError)
        }
        let seventh = try await tool.execute(call(f.peer.id, text: "One too many", id: "seventh"), context: context)
        #expect(seventh.isError)
        try await session.close()
    }

    @Test func unsupportedFieldsDeniedApprovalAndPassDoNotPost() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(authorize: { _, _, _, _, _ in throw AgentMessagingError.approvalRequired })
        let tool = session.tool(for: f.sender.id), context = ToolContext(conversationID: f.origin)
        let denied = try await tool.execute(call(f.group.id), context: context)
        #expect(denied.isError)
        for field in ["senderID", "images", "priority"] {
            let payload = ["recipientID": f.group.id.uuidString, "message": "Review", field: "spoof"]
            let result = try await tool.execute(.init(id: "invalid", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(payload)), context: context)
            #expect(result.isError)
        }
        let pass = try await tool.execute(call(f.group.id, text: "(PASS)", id: "pass"), context: context)
        #expect(!pass.isError && pass.wireText.contains("Nothing was posted"))
        let posts = await f.groups.messages(groupID: f.group.id)
        expectNoDifference(posts, [])
    }
}
