import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private actor MemberPreemptionGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiters.isEmpty }
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor MemberPreemptionProbe {
    var requests: [InferenceRequest] = []
    var contexts: [ToolContext] = []
    var events: [String] = []
    func record(_ request: InferenceRequest, groupID: UUID) -> Int {
        requests.append(request)
        let groupCount = requests.filter { $0.conversationID == groupID }.count
        events.append(request.conversationID == groupID ? "group \(groupCount)" : "human")
        return groupCount
    }
    func tool(_ context: ToolContext, attempt: Int) { contexts.append(context); events.append("tool \(attempt)") }
    func cleanup(_ attempt: Int) { events.append("cleanup \(attempt)") }
}

private struct MemberPreemptionTool: ToolExecutor {
    let descriptor = ToolDescriptor(name: "member-cleanup")
    let gates: [MemberPreemptionGate]
    let probe: MemberPreemptionProbe
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        struct Arguments: Decodable { let attempt: Int }
        let attempt = try JSONDecoder().decode(Arguments.self, from: call.argumentsJSON).attempt
        guard gates.indices.contains(attempt - 1) else { throw ProviderError.invalidResponse }
        await probe.tool(context, attempt: attempt)
        // Deliberately retain the native host lane until real tool cleanup ends.
        // A cancelled provider transport is not that cleanup boundary.
        await gates[attempt - 1].wait()
        await probe.cleanup(attempt)
        return .init(callID: call.id, content: [.text("cleaned")])
    }
}

private struct MemberPreemptionProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "member-preemption", displayName: "Member preemption", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct UnattestedMemberFailure: GroupAgentResponder {
    let error: any Error
    let probe: MemberPreemptionProbe
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        await probe.cleanup(1)
        throw error
    }
}

@Suite("Native group-member priority redrive", .timeLimit(.minutes(1)))
struct GroupMemberPreemptionTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let groups: GroupService
        let agent: AgentProfile
        let room: AgentGroup
        let user: RoomMessage
        let registry: ProviderRegistry
        let scheduler: AgentExecutionScheduler
        let coordinator: TurnCoordinator
        let probe: MemberPreemptionProbe
        let gates: [MemberPreemptionGate]
        let humanGate: MemberPreemptionGate?
        let hostScope: AgentWorkflowExecutionScope
        let lifetime: AgentPublicationLifetime

        var responder: GroupConversationResponder {
            .init(groupID: room.id, registry: registry, coordinator: coordinator,
                questionAccountID: "local", questionLifetime: lifetime)
        }

        func humanTurn() -> Task<Void, any Error> {
            Task {
                try await coordinator.send(request: .init(conversationID: agent.id, modelID: "test",
                    messages: [.init(id: agent.id, role: .user, text: "PRIVATE_HUMAN_TASK",
                        createdAt: Date(timeIntervalSince1970: 103))]), providerID: agent.providerID,
                    agentID: agent.id, agentLane: .user, priority: true) { _ in }
            }
        }

        func groupTurn() throws -> Task<[RoomMessage], any Error> {
            let lease = try hostScope.capture()
            return Task { try await groups.run(groupID: room.id, responder: responder, executionLease: lease) }
        }

        func release() async {
            for gate in gates { await gate.open() }
            await humanGate?.open()
        }
    }

    private func fixture(interruptions: Int = 1, publishBeforeInterruption: Bool = false,
                         holdHuman: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-member-preemption-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let agent = try await agents.create(name: "Worker", instructions: "MEMBER_PERSONA",
            providerID: "member-preemption", modelID: "test", at: Date(timeIntervalSince1970: 100))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"),
            activityDate: { Date(timeIntervalSince1970: 102) })
        let room = try await groups.create(name: "Room", summary: "Original group task", memberIDs: [agent.id])
        let user = try await groups.postUserMessage("GROUP_TASK", groupID: room.id)
        let registry = ProviderRegistry(), scheduler = AgentExecutionScheduler(), probe = MemberPreemptionProbe()
        let gates = (0..<interruptions).map { _ in MemberPreemptionGate() }
        let humanGate = holdHuman ? MemberPreemptionGate() : nil
        let coordinator = TurnCoordinator(registry: registry,
            toolCatalog: ToolCatalog([MemberPreemptionTool(gates: gates, probe: probe)]), agentScheduler: scheduler)
        await registry.register(MemberPreemptionProvider { request, execute in
            let attempt = await probe.record(request, groupID: room.id)
            guard request.conversationID == room.id else {
                await humanGate?.wait()
                try Task.checkCancellation()
                return "PRIVATE_HUMAN_RESULT"
            }
            if publishBeforeInterruption && attempt == 1 {
                _ = try await execute(.init(id: "progress", name: "SendMessage",
                    argumentsJSON: JSONEncoder().encode(["text": "Visible progress"])))
            }
            if attempt <= interruptions {
                _ = try await execute(.init(id: ToolCallID(rawValue: "cleanup-\(attempt)"), name: "member-cleanup",
                    argumentsJSON: JSONEncoder().encode(["attempt": attempt])))
                try Task.checkCancellation()
            }
            _ = try await execute(.init(id: "recovered", name: "SendMessage",
                argumentsJSON: JSONEncoder().encode(["text": "Recovered group result"])))
            return "PRIVATE_GROUP_DRAFT"
        })
        return .init(root: root, agents: agents, groups: groups, agent: agent, room: room, user: user,
            registry: registry, scheduler: scheduler, coordinator: coordinator, probe: probe,
            gates: gates, humanGate: humanGate, hostScope: .init(), lifetime: .init())
    }

    /// Match the complete native on-disk schema, including its Date encoding.
    /// Encoding/decoding milliseconds can round a sub-microsecond in-memory
    /// Date; no identity, tool, outcome, attachment, or text field is omitted.
    private func durable(_ history: [RoomMessage]) throws -> [RoomMessage] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode([RoomMessage].self, from: encoder.encode(history))
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation,
                           _ predicate: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate(), sourceLocation: sourceLocation)
    }

    @Test(arguments: [false, true])
    func groupMemberRedrivesOnlyWhenNothingWasPublished(published: Bool) async throws {
        let f = try await fixture(publishBeforeInterruption: published)
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let group = try f.groupTurn()
        var human: Task<Void, any Error>?
        do {
            try await waitUntil { await f.gates[0].isWaiting }
            let before = await f.groups.messages(groupID: f.room.id)
            human = f.humanTurn()
            try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            let blocked = await f.probe.events
            expectNoDifference(blocked, ["group 1", "tool 1"])
            await f.gates[0].open()
            try await human?.value
            let produced = try await group.value
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), published
                ? [f.room.id, f.agent.id] : [f.room.id, f.agent.id, f.room.id])
            expectNoDifference(produced.map(\.text), [published ? "Visible progress" : "Recovered group result"])
            let history = await f.groups.messages(groupID: f.room.id)
            expectNoDifference(history.first, before.first)
            #expect(!history.contains { $0.memberOutcome == .failed })
            #expect(!history.contains { $0.text.contains("PRIVATE_") })
            expectNoDifference(history.filter { $0.senderID == f.agent.id && !$0.text.isEmpty }.map(\.text), produced.map(\.text))
            let oldActivity = try #require(before.first { !$0.toolActivities.isEmpty })
            var retired = oldActivity
            retired.toolActivities = retired.toolActivities.map { activity in
                var activity = activity
                if activity.status == .pending { activity.status = .cancelled }
                return activity
            }
            expectNoDifference(history.first { $0.id == oldActivity.id }, retired)
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: f.room.id)
            expectNoDifference(restored, try durable(history))
            let events = await f.probe.events
            expectNoDifference(events, published ? ["group 1", "tool 1", "cleanup 1", "human"]
                : ["group 1", "tool 1", "cleanup 1", "human", "group 2"])
        } catch {
            group.cancel(); human?.cancel()
            await f.groups.stop(groupID: f.room.id)
            await f.release()
            _ = await group.result; _ = await human?.result
            throw error
        }
    }

    @Test func repeatedNativePreemptionIsBoundedToThreeMemberAttempts() async throws {
        let f = try await fixture(interruptions: 3)
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let group = try f.groupTurn()
        var humans: [Task<Void, any Error>] = []
        do {
            for index in f.gates.indices {
                try await waitUntil { await f.gates[index].isWaiting }
                let human = f.humanTurn(); humans.append(human)
                try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
                await f.gates[index].open()
                try await human.value
            }
            let produced = try await group.value
            expectNoDifference(produced, [])
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), [f.room.id, f.agent.id, f.room.id, f.agent.id, f.room.id, f.agent.id])
            let history = await f.groups.messages(groupID: f.room.id)
            #expect(!history.contains { $0.memberOutcome == .failed })
            expectNoDifference(history.flatMap(\.toolActivities).map(\.status), [.cancelled, .cancelled, .cancelled])
            let contexts = await f.probe.contexts
            expectNoDifference(contexts.count, 3)
            expectNoDifference(Set(contexts.map(\.runID)).count, 3)
            #expect(contexts.allSatisfy { $0.conversationID == f.room.id })
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: f.room.id)
            expectNoDifference(restored, try durable(history))
        } catch {
            group.cancel(); humans.forEach { $0.cancel() }
            await f.groups.stop(groupID: f.room.id)
            await f.release()
            _ = await group.result
            for human in humans { _ = await human.result }
            throw error
        }
    }

    @Test(arguments: ["stop", "room restore", "members restore", "persona restore", "name restore", "summary restore", "model restore", "archive restore", "account restore", "new request"])
    func queuedRedriveNeverSurvivesRevocationOrABA(boundary: String) async throws {
        let f = try await fixture(holdHuman: true)
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let group = try f.groupTurn()
        var human: Task<Void, any Error>?
        do {
            try await waitUntil { await f.gates[0].isWaiting }
            human = f.humanTurn()
            try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            await f.gates[0].open()
            try await waitUntil { await f.humanGate?.isWaiting == true }
            // The retry must actually be waiting behind the protected human
            // lane; a test that mutates before retry admission misses this race.
            try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            switch boundary {
            case "stop": await f.groups.stop(groupID: f.room.id)
            case "room restore":
                try await f.groups.update(groupID: f.room.id, name: "Edited", summary: f.room.summary, memberIDs: f.room.memberIDs)
                try await f.groups.update(groupID: f.room.id, name: f.room.name, summary: f.room.summary, memberIDs: f.room.memberIDs)
            case "members restore":
                try await f.groups.updateMembers(groupID: f.room.id, memberIDs: [])
                try await f.groups.updateMembers(groupID: f.room.id, memberIDs: f.room.memberIDs)
            case "persona restore":
                var edited = f.agent; edited.instructions = "DIFFERENT_PERSONA"
                try await f.agents.update(edited); try await f.agents.update(f.agent)
            case "name restore":
                var edited = f.agent; edited.name = "DIFFERENT_NAME"
                try await f.agents.update(edited); try await f.agents.update(f.agent)
            case "summary restore":
                var edited = f.agent; edited.summary = "DIFFERENT_SUMMARY"
                try await f.agents.update(edited); try await f.agents.update(f.agent)
            case "model restore":
                var edited = f.agent; edited.modelID = "DIFFERENT_MODEL"
                try await f.agents.update(edited); try await f.agents.update(f.agent)
            case "archive restore":
                try await f.agents.archive(id: f.agent.id); try await f.agents.restore(id: f.agent.id)
            case "account restore": f.hostScope.suspend(); f.hostScope.resume()
            default: _ = try await f.groups.postUserMessage("NEW_GROUP_TASK", groupID: f.room.id)
            }
            let expected = await f.groups.messages(groupID: f.room.id)
            await f.humanGate?.open(); try await human?.value
            _ = await group.result
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), [f.room.id, f.agent.id])
            let actual = await f.groups.messages(groupID: f.room.id)
            expectNoDifference(actual, expected)
            #expect(!actual.contains { $0.memberOutcome == .failed || $0.text.contains("PRIVATE_") })
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: f.room.id)
            expectNoDifference(restored, try durable(expected))
        } catch {
            group.cancel(); human?.cancel(); await f.groups.stop(groupID: f.room.id); await f.release()
            _ = await group.result; _ = await human?.result
            throw error
        }
    }

    @Test(arguments: ["instructions", "title", "model", "archive"])
    func admittedTurnStillRejectsPrivateIdentityChangesAndRestoration(field: String) async throws {
        let f = try await fixture()
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let group = try f.groupTurn()
        do {
            try await waitUntil { await f.gates[0].isWaiting }
            let before = await f.groups.messages(groupID: f.room.id)
            if field == "archive" {
                try await f.agents.archive(id: f.agent.id); try await f.agents.restore(id: f.agent.id)
            } else {
                var edited = f.agent
                if field == "instructions" { edited.instructions = "CHANGED_PRIVATE_PERSONA" }
                else if field == "title" { edited.title = "CHANGED_ROLE" }
                else { edited.modelID = "CHANGED_MODEL" }
                try await f.agents.update(edited); try await f.agents.update(f.agent)
            }
            await f.gates[0].open()
            _ = try await group.value
            let history = await f.groups.messages(groupID: f.room.id)
            var retired = before
            for row in retired.indices {
                for tool in retired[row].toolActivities.indices
                    where retired[row].toolActivities[tool].status == .pending {
                    retired[row].toolActivities[tool].status = .cancelled
                }
            }
            expectNoDifference(history, retired)
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), [f.room.id])
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: f.room.id)
            expectNoDifference(restored, try durable(retired))
        } catch {
            group.cancel(); await f.groups.stop(groupID: f.room.id); await f.release()
            _ = await group.result
            throw error
        }
    }

    @Test func presenceAndUnreadBookkeepingDoNotRevokeCurrentMember() async throws {
        let f = try await fixture(holdHuman: true)
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let group = try f.groupTurn()
        var human: Task<Void, any Error>?
        do {
            try await waitUntil { await f.gates[0].isWaiting }
            human = f.humanTurn()
            try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            await f.gates[0].open()
            try await waitUntil { await f.humanGate?.isWaiting == true }
            try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            try await f.agents.setPresence(id: f.agent.id, status: .running)
            try await f.agents.setUnreadCount(id: f.agent.id, count: 4)
            await f.humanGate?.open(); try await human?.value
            let produced = try await group.value
            expectNoDifference(produced.map(\.text), ["Recovered group result"])
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), [f.room.id, f.agent.id, f.room.id])
        } catch {
            group.cancel(); human?.cancel(); await f.groups.stop(groupID: f.room.id); await f.release()
            _ = await group.result; _ = await human?.result
            throw error
        }
    }

    @Test(arguments: [false, true])
    func aDurableMemberReactionPreventsDuplicateRedrive(removedAgain: Bool) async throws {
        let f = try await fixture()
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let group = try f.groupTurn()
        var human: Task<Void, any Error>?
        do {
            try await waitUntil { await f.gates[0].isWaiting }
            #expect(try await f.groups.toggleReaction(messageID: f.user.id, actorID: f.agent.id, emoji: "👍"))
            if removedAgain {
                let added = try await f.groups.toggleReaction(messageID: f.user.id, actorID: f.agent.id, emoji: "👍")
                #expect(!added)
            }
            let reactions = await f.groups.reactions(messageID: f.user.id)
            human = f.humanTurn()
            try await waitUntil { await f.scheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            await f.gates[0].open(); try await human?.value
            let produced = try await group.value
            expectNoDifference(produced, [])
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), [f.room.id, f.agent.id])
            let actualReactions = await f.groups.reactions(messageID: f.user.id)
            expectNoDifference(actualReactions, reactions)
            let history = await f.groups.messages(groupID: f.room.id)
            #expect(!history.contains { $0.memberOutcome == .failed })
            expectNoDifference(history.flatMap(\.toolActivities).map(\.status), [.cancelled])
        } catch {
            group.cancel(); human?.cancel(); await f.groups.stop(groupID: f.room.id); await f.release()
            _ = await group.result; _ = await human?.result
            throw error
        }
    }

    @Test(arguments: ["ordinary", "cancellation", "unattested priority"])
    func errorTypeOrProseCannotMintMemberRedrive(reason: String) async throws {
        let f = try await fixture()
        defer { f.lifetime.close(); try? FileManager.default.removeItem(at: f.root) }
        let error = selfError(reason)
        do {
            _ = try await f.groups.run(groupID: f.room.id, responder: UnattestedMemberFailure(error: error, probe: f.probe))
            Issue.record("The original failure must remain a failure")
        } catch {
            expectNoDifference(String(reflecting: type(of: error)), String(reflecting: type(of: selfError(reason))))
        }
        let events = await f.probe.events
        expectNoDifference(events, ["cleanup 1"])
        let history = await f.groups.messages(groupID: f.room.id)
        expectNoDifference(history.compactMap(\.memberOutcome), [.failed])
        expectNoDifference(history.filter { $0.senderID == nil }.map(\.id), [f.user.id])
    }

    private func selfError(_ reason: String) -> any Error {
        if reason == "unattested priority" { return AgentExecutionSuperseded() }
        if reason == "cancellation" { return CancellationError() }
        return ProviderError.transport("Interrupted by priority; redrive me")
    }
}
