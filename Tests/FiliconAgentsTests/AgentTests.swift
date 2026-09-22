import Foundation
import AppKit
import Testing
import FiliconDomain
@testable import FiliconAgents

private struct EchoResponder: GroupAgentResponder {
    let passNames: Set<String>
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        passNames.contains(agent.name) ? ["(pass)"] : ["\(agent.name)-\(history.count)"]
    }
}

private actor ImmediateSubagentRuntime: SubagentRuntime {
    let text: String
    let usage: Usage
    init(text: String = "done", usage: Usage = .init(inputTokens: 3, outputTokens: 2)) {
        self.text = text
        self.usage = usage
    }
    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        .completed(text: text, usage: usage)
    }
    func interrupt(reason: String) async {}
}

private actor TypedImmediateRuntime: AgentAsyncTaskRuntime {
    nonisolated let taskKind: AgentTaskKind
    init(_ taskKind: AgentTaskKind) { self.taskKind = taskKind }
    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        .completed(text: "\(taskKind.rawValue):\(prompt)", usage: .init())
    }
    func interrupt(reason: String) async {}
}

private actor InterruptibleSubagentRuntime: SubagentRuntime {
    private var firstContinuation: CheckedContinuation<SubagentTurnOutcome, Never>?
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private(set) var prompts: [String] = []
    private(set) var interruptReasons: [String] = []

    func run(prompt: String, scope: SubagentExecutionScope) async throws -> SubagentTurnOutcome {
        try Task.checkCancellation()
        prompts.append(prompt)
        if prompts.count > 1 {
            return .completed(text: "redirected", usage: .init(inputTokens: 2, outputTokens: 1))
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation {
                if Task.isCancelled { $0.resume(returning: .interrupted); return }
                firstContinuation = $0
                started.continuation.yield(())
                started.continuation.finish()
            }
        } onCancel: {
            Task { await self.interrupt(reason: "Task cancelled") }
        }
    }

    func waitUntilStarted() async throws {
        for await _ in started.stream { return }
        throw CancellationError()
    }

    func interrupt(reason: String) async {
        interruptReasons.append(reason)
        firstContinuation?.resume(returning: .interrupted)
        firstContinuation = nil
    }
}

private actor RecordingGroupResponder: GroupAgentResponder {
    private(set) var order: [String] = []
    let outputs: [String]
    init(outputs: [String]) { self.outputs = outputs }
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        order.append(agent.name)
        return outputs
    }
}

private actor GroupMessageRecorder {
    private(set) var messages: [RoomMessage] = []
    func append(_ message: RoomMessage) { messages.append(message) }
}

private actor BlockingGroupResponder: GroupAgentResponder {
    private var continuation: CheckedContinuation<[String], Never>?
    private let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                if Task.isCancelled { $0.resume(returning: []); return }
                continuation = $0
                started.continuation.yield(())
                started.continuation.finish()
            }
        } onCancel: {
            Task { await self.release([]) }
        }
    }
    func waitUntilStarted() async throws {
        for await _ in started.stream { return }
        throw CancellationError()
    }
    func release(_ output: [String]) {
        continuation?.resume(returning: output)
        continuation = nil
    }
}

private struct FailingGroupResponder: GroupAgentResponder {
    struct Failure: Error, Equatable {}
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        throw Failure()
    }
}

@Suite("Agents and groups")
struct AgentTests {
    private func sandbox() throws -> (URL, AgentService) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try AgentService(storeURL: root.appending(path: "agents.json")))
    }

    @Test func profileCRUDCloneArchiveAndRestart() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try await service.create(name: "Researcher", summary: "find facts", providerID: "openai", modelID: "gpt")
        let clone = try await service.clone(id: first.id)
        #expect(clone.id != first.id)
        #expect(clone.name == "Researcher copy")
        try await service.archive(id: first.id)
        #expect(await service.list().map(\.id) == [clone.id])
        let reopened = try AgentService(storeURL: root.appending(path: "agents.json"))
        #expect(await reopened.list(includeArchived: true).count == 2)
    }

    @Test func stateSnapshotsAreAtomicallySeededAndPublishPersistedMutations() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let stream = await service.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initial = try #require(await iterator.next())
        #expect(initial.revision == 0)
        #expect(initial.agents.isEmpty)
        #expect(initial.subagents.isEmpty)

        let profile = try await service.create(name: "Observer")
        let created = try #require(await iterator.next())
        #expect(created.revision == 1)
        #expect(created.agents.map(\.id) == [profile.id])

        try await service.setPresence(id: profile.id, status: .running)
        let running = try #require(await iterator.next())
        #expect(running.revision == 2)
        #expect(running.agents.first?.status == .running)
    }

    @Test func profileEditRestoreAndBackwardDecode() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = try await service.create(name: "Writer", summary: "old", providerID: "openai", modelID: "gpt-old")
        profile.name = "  Editor  "; profile.title = "Lead"; profile.summary = "new"
        profile.instructions = "Be exact"; profile.providerID = "anthropic"; profile.modelID = "claude"
        try await service.update(profile)
        let edited = try #require(await service.profile(id: profile.id))
        #expect(edited.name == "Editor")
        #expect(edited.title == "Lead" && edited.summary == "new" && edited.instructions == "Be exact")
        #expect(edited.providerID == "anthropic" && edited.modelID == "claude")
        try await service.archive(id: profile.id)
        #expect(await service.profile(id: profile.id)?.status == .offline)
        try await service.restore(id: profile.id)
        #expect(await service.profile(id: profile.id)?.archivedAt == nil)
        #expect(await service.profile(id: profile.id)?.status == .idle)

        let legacy = "{\"id\":\"\(UUID().uuidString)\",\"name\":\"Legacy\"}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AgentProfile.self, from: legacy)
        #expect(decoded.summary.isEmpty && decoded.instructions.isEmpty && decoded.title.isEmpty)
        #expect(decoded.providerID == "fake" && decoded.modelID == "fake-stream")
        #expect(decoded.status == .idle && decoded.unreadCount == 0 && decoded.avatar == nil)
    }

    @Test func avatarNormalizesToPNGAndRejectsUnsafeReferencesAndLimits() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "source.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 800,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemPurple.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 800)).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: source)
        let store = AgentAvatarStore(rootURL: root.appending(path: "cas"))
        let avatar = try store.importImage(at: source, crop: .init(focusX: 0.25, focusY: 0.75, zoom: 2), shape: .hexagon)
        let stored = try #require(store.imageURL(for: avatar))
        let output = try #require(NSImage(contentsOf: stored))
        #expect(output.size.width == 256 && output.size.height == 256)
        #expect(stored.pathExtension == "png" && avatar.shape == .hexagon)
        #expect(store.imageURL(for: .image(hash: String(repeating: "a", count: 64), relativePath: "../escape.png")) == nil)
        #expect(store.imageURL(for: .image(hash: String(repeating: "a", count: 64), relativePath: "aa/\(String(repeating: "b", count: 64)).png")) == nil)
        #expect(throws: AgentAvatarStoreError.invalidCrop) {
            try store.importImage(at: source, crop: .init(zoom: 5.1))
        }
        let outside = root.appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: stored.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: stored.deletingLastPathComponent(), withDestinationURL: outside)
        #expect(throws: AgentAvatarStoreError.unsafePath) {
            try store.importImage(at: source, crop: .init(focusX: 0.25, focusY: 0.75, zoom: 2), shape: .hexagon)
        }
        let oversized = root.appending(path: "oversized.bin")
        FileManager.default.createFile(atPath: oversized.path, contents: Data(count: AgentAvatarStore.maximumInputBytes))
        #expect(throws: AgentAvatarStoreError.fileTooLarge) {
            try store.importImage(at: oversized, crop: .init())
        }
    }

    @Test func rosterAndOrgChartAreDeterministic() {
        let rootID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let childID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let archivedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let root = AgentProfile(id: rootID, name: "Root", unreadCount: 1)
        let child = AgentProfile(id: childID, name: "Child", unreadCount: 4)
        let archived = AgentProfile(id: archivedID, name: "Old", archivedAt: Date())
        let sections = AgentRosterSection.build(profiles: [archived, root, child], pinnedIDs: [rootID])
        #expect(sections.map(\.id) == [.pinned, .active, .archived])
        #expect(sections[0].agents.map(\.id) == [rootID])
        let record = SubagentRecord(parentRunID: UUID(), parentToolCallID: "x", agentID: childID,
                                    title: "Child work", depth: 1, parentAgentID: rootID)
        let first = AgentOrgChartLayout.make(profiles: [child, root], tasks: [.init(record: record)])
        let second = AgentOrgChartLayout.make(profiles: [root, child], tasks: [.init(record: record)])
        #expect(first == second)
        #expect(first.edges == [.init(parentID: rootID, childID: childID)])
        #expect(first.nodes.first(where: { $0.id == rootID })?.level == 0)
        #expect(first.nodes.first(where: { $0.id == childID })?.level == 1)
    }

    @Test func typedAsyncRuntimesCannotMasqueradeAsAnotherTaskKind() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await agents.create(name: "Worker")
        let service = SubagentService(agents: agents)
        await #expect(throws: AgentServiceError.invalidSubagent) {
            _ = try await service.launch(
                .init(agentID: profile.id, title: "Cloud", prompt: "work", parentToolCallID: "c", depth: 1, taskKind: .cloud),
                parentRunID: UUID(), parentScope: .init(), runtime: TypedImmediateRuntime(.shell)
            )
        }
        let id = try await service.launch(
            .init(agentID: profile.id, title: "Shell", prompt: "work", parentToolCallID: "s", depth: 1, taskKind: .shell),
            parentRunID: UUID(), parentScope: .init(), runtime: TypedImmediateRuntime(.shell)
        )
        await service.drain()
        #expect(await service.status(id)?.taskKind == .shell)
        #expect(await service.status(id)?.status == .succeeded)
    }

    @Test func messengerIsIdempotentPriorityOrderedAndAtMostOnce() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try await service.create(name: "A"), b = try await service.create(name: "B")
        let messenger = try AgentMessenger(service: service, storeURL: root.appending(path: "messages.json"))
        let normal = AgentMessage(senderID: a.id, recipientID: b.id, text: "normal")
        let priority = AgentMessage(senderID: a.id, recipientID: b.id, text: "priority", priority: .priority)
        try await messenger.send(normal); try await messenger.send(priority)
        #expect(try await messenger.dequeue(recipientID: b.id)?.id == priority.id)
        #expect(try await messenger.dequeue(recipientID: b.id)?.id == normal.id)
        #expect(try await messenger.dequeue(recipientID: b.id) == nil)
        await #expect(throws: AgentServiceError.self) { try await messenger.send(normal) }
        await #expect(throws: AgentServiceError.self) { try await messenger.send(.init(senderID: a.id, recipientID: a.id, text: "self")) }
    }

    @Test func groupCapsRoundRobinAllPassAndReactionToggle() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try await service.create(name: "A"), b = try await service.create(name: "B")
        let groups = try GroupService(agents: service, storeURL: root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Pair", memberIDs: [a.id, b.id])
        _ = try await groups.postUserMessage("start", groupID: group.id)
        let firstRun = try await groups.run(groupID: group.id, responder: EchoResponder(passNames: ["B"]))
        #expect(firstRun.count == 1)
        let secondRun = try await groups.run(groupID: group.id, responder: EchoResponder(passNames: ["A", "B"]))
        #expect(secondRun.isEmpty)
        let target = firstRun[0]
        #expect(try await groups.toggleReaction(messageID: target.id, actorID: b.id, emoji: "👍"))
        #expect(try await groups.toggleReaction(messageID: target.id, actorID: b.id, emoji: "👍") == false)
        await #expect(throws: AgentServiceError.self) { _ = try await groups.create(name: "Dup", memberIDs: [a.id, a.id]) }
    }

    @Test(.timeLimit(.minutes(1))) func groupMentionsBoundariesRotationCapsAndEpochStop() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let alpha = try await service.create(name: "Alpha Agent")
        let beta = try await service.create(name: "Beta")
        let members = [alpha, beta]
        #expect(GroupService.mentionHandles(for: alpha.name) == ["alpha agent", "alphaagent", "alpha"])
        #expect(GroupService.parseMentions(in: "hi @AlphaAgent, @all", members: members).everyone)
        #expect(GroupService.parseMentions(in: "hi @AlphaAgent, @all", members: members).memberIDs == [alpha.id])
        #expect(GroupService.parseMentions(in: "mail@alphax", members: members).memberIDs.isEmpty)
        #expect(GroupService.isPass("(PASS)."))

        let groups = try GroupService(agents: service, storeURL: root.appending(path: "groups-advanced.json"))
        let group = try await groups.create(name: "Pair", memberIDs: [alpha.id, beta.id])
        _ = try await groups.postUserMessage("@alpha please", groupID: group.id)
        let mentionedResponder = RecordingGroupResponder(outputs: ["one", "two", "ignored"])
        let mentioned = try await groups.run(groupID: group.id, responder: mentionedResponder)
        #expect(mentioned.count == 2)
        #expect(await mentionedResponder.order == ["Alpha Agent"])

        _ = try await groups.postUserMessage("@everyone continue", groupID: group.id)
        let cappedResponder = RecordingGroupResponder(outputs: ["one", "two", "ignored"])
        let capped = try await groups.run(groupID: group.id, responder: cappedResponder)
        #expect(capped.count == 4)
        // Alpha sees Beta's new contribution, but repeating the same text does
        // not publish it again or keep the group alive.
        #expect(await cappedResponder.order == ["Alpha Agent", "Beta", "Alpha Agent"])

        _ = try await groups.postUserMessage("late", groupID: group.id)
        let blocker = BlockingGroupResponder()
        let running = Task { try await groups.run(groupID: group.id, responder: blocker) }
        defer { running.cancel() }
        try await blocker.waitUntilStarted()
        await groups.stop(groupID: group.id)
        await blocker.release(["must not publish"])
        #expect(try await running.value.isEmpty)
        #expect(await groups.messages(groupID: group.id).last?.text == "late")
    }

    @Test func groupSurfacesFailureWhenNoMemberCanRespond() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let member = try await agents.create(name: "Broken")
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups-failure.json"))
        let group = try await groups.create(name: "Failure", memberIDs: [member.id])
        _ = try await groups.postUserMessage("hello", groupID: group.id)

        await #expect(throws: FailingGroupResponder.Failure.self) {
            _ = try await groups.run(groupID: group.id, responder: FailingGroupResponder())
        }
    }

    @Test func groupPublishesEachMessageBeforeTheRunCompletes() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let member = try await agents.create(name: "Live")
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups-live.json"))
        let group = try await groups.create(name: "Live", memberIDs: [member.id])
        _ = try await groups.postUserMessage("hello", groupID: group.id)
        let recorder = GroupMessageRecorder()

        let result = try await groups.run(groupID: group.id, responder: EchoResponder(passNames: []), onMessage: { message in
            await recorder.append(message)
        })

        #expect(await recorder.messages == result)
        #expect(result.isEmpty == false)
    }

    @Test func subagentCompletesAndCreatesAcknowledgableWake() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await agents.create(name: "Worker")
        let service = SubagentService(agents: agents)
        let parent = UUID()
        let id = try await service.launch(
            .init(agentID: profile.id, title: "Task", prompt: "work", parentToolCallID: "call-1", depth: 1),
            parentRunID: parent,
            parentScope: .init(),
            runtime: ImmediateSubagentRuntime()
        )
        await service.drain()
        #expect(await service.status(id)?.status == .succeeded)
        #expect(await service.status(id)?.usage == .init(inputTokens: 3, outputTokens: 2))
        let wakes = await agents.pendingWakes(parentRunID: parent)
        #expect(wakes.count == 1)
        #expect(wakes[0].workID == id)
        #expect(wakes[0].result == "done")
        try await agents.acknowledgeWake(id: wakes[0].id)
        #expect(await agents.pendingWakes(parentRunID: parent).isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func subagentSteerInterruptsAndContinuesWhileCancelIsTerminal() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await agents.create(name: "Worker")
        let service = SubagentService(agents: agents)
        let parent = UUID()
        let runtime = InterruptibleSubagentRuntime()
        let id = try await service.launch(
            .init(agentID: profile.id, title: "Task", prompt: "start", parentToolCallID: "call-1", depth: 1),
            parentRunID: parent,
            parentScope: .init(),
            runtime: runtime
        )
        do {
            try await runtime.waitUntilStarted()
            try await service.steer(id, message: "change course")
        } catch {
            await service.cancelAll(); await service.drain()
            throw error
        }
        await service.drain()
        #expect(await service.status(id)?.status == .succeeded)
        #expect(await runtime.prompts.count == 2)
        #expect(await runtime.prompts.last?.contains("change course") == true)

        let cancelRuntime = InterruptibleSubagentRuntime()
        let cancelledID = try await service.launch(
            .init(agentID: profile.id, title: "Stop", prompt: "wait", parentToolCallID: "call-2", depth: 1),
            parentRunID: parent,
            parentScope: .init(),
            runtime: cancelRuntime
        )
        do { try await cancelRuntime.waitUntilStarted() }
        catch {
            await service.cancelAll(); await service.drain()
            throw error
        }
        await service.cancel(cancelledID)
        await service.drain()
        #expect(await service.status(cancelledID)?.status == .cancelled)
        #expect(await agents.pendingWakes(parentRunID: parent).allSatisfy { $0.workID != cancelledID })
    }

    @Test func subagentRejectsCycleScopeEscalationAndParentConcurrencyOverflow() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await agents.create(name: "Worker")
        let service = SubagentService(agents: agents)
        let parent = UUID()
        let parentScope = SubagentExecutionScope(allowedToolNames: ["read"])
        await #expect(throws: AgentServiceError.cycleDetected) {
            _ = try await service.launch(
                .init(agentID: profile.id, title: "Cycle", prompt: "x", parentToolCallID: "c", depth: 1, ancestorAgentIDs: [profile.id]),
                parentRunID: parent, parentScope: parentScope, runtime: ImmediateSubagentRuntime()
            )
        }
        await #expect(throws: AgentServiceError.scopeEscalation) {
            _ = try await service.launch(
                .init(agentID: profile.id, title: "Escalate", prompt: "x", parentToolCallID: "e", depth: 1, scope: .init(allowedToolNames: ["write"])),
                parentRunID: parent, parentScope: parentScope, runtime: ImmediateSubagentRuntime()
            )
        }
        let firstRuntime = InterruptibleSubagentRuntime(), secondRuntime = InterruptibleSubagentRuntime()
        let first = try await service.launch(
            .init(agentID: profile.id, title: "One", prompt: "x", parentToolCallID: "1", depth: 1),
            parentRunID: parent, parentScope: parentScope, runtime: firstRuntime
        )
        let second = try await service.launch(
            .init(agentID: profile.id, title: "Two", prompt: "x", parentToolCallID: "2", depth: 1),
            parentRunID: parent, parentScope: parentScope, runtime: secondRuntime
        )
        await #expect(throws: AgentServiceError.concurrencyLimit) {
            _ = try await service.launch(
                .init(agentID: profile.id, title: "Three", prompt: "x", parentToolCallID: "3", depth: 1),
                parentRunID: parent, parentScope: parentScope, runtime: ImmediateSubagentRuntime()
            )
        }
        await service.cancel(first); await service.cancel(second); await service.drain()
    }

    @Test func restartRecoversOrphanedRunAndWake() async throws {
        let (root, agents) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let profile = try await agents.create(name: "Worker")
        let parent = UUID()
        let record = SubagentRecord(parentRunID: parent, parentToolCallID: "call", agentID: profile.id, title: "Orphan", status: .running, depth: 1)
        try await agents.registerSubagent(record)
        let reopened = try AgentService(storeURL: root.appending(path: "agents.json"))
        #expect(await reopened.subagent(id: record.id)?.status == .interrupted)
        let wakes = await reopened.pendingWakes(parentRunID: parent)
        #expect(wakes.count == 1)
        #expect(wakes[0].status == .interrupted)
    }
}
