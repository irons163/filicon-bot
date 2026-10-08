import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconLocalTools
import FiliconPersistence
@testable import Filicon

private actor AppMemberGate {
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

private actor AppMemberProbe {
    typealias ToolCallback = @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult
    var requests: [InferenceRequest] = []
    var contexts: [ToolContext] = []
    var events: [String] = []
    var callbacks: [ToolCallback] = []
    func request(_ request: InferenceRequest, groupID: UUID, execute: @escaping ToolCallback) -> Int {
        requests.append(request)
        let count = requests.filter { $0.conversationID == groupID }.count
        if request.conversationID == groupID { callbacks.append(execute); events.append("group \(count)") }
        else { events.append("private") }
        return count
    }
    func tool(_ context: ToolContext) { contexts.append(context); events.append("tool") }
    func cleaned() { events.append("cleanup") }
}

private struct AppMemberCleanupTool: ToolExecutor {
    let descriptor = ToolDescriptor(name: "app-member-cleanup")
    let gate: AppMemberGate
    let probe: AppMemberProbe
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        await probe.tool(context)
        // Cancellation deliberately cannot release the lane until native tool
        // cleanup finishes. This is not merely a cancelled stream transport.
        await gate.wait(); await probe.cleaned()
        return .init(callID: call.id, content: [.text("cleaned")])
    }
}

private struct AppMemberProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "app-member-fixture", displayName: "App member fixture", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @escaping AppMemberProbe.ToolCallback) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping AppMemberProbe.ToolCallback) -> AsyncThrowingStream<InferenceEvent, any Error> {
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

@Suite("Actual app group-member priority preemption", .timeLimit(.minutes(1)))
@MainActor struct GroupMemberPreemptionAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let agent: AgentProfile
        let peer: AgentProfile
        let room: AgentGroup
        let chat: Conversation
        let unrelated: Conversation
        let groupGate: AppMemberGate
        let humanGate: AppMemberGate?
        let probe: AppMemberProbe

        func release() async { await groupGate.open(); await humanGate?.open() }
    }

    private func fixture(mode: String = "cleanup", holdHuman: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-app-member-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let agent = try await agents.create(name: "Worker", instructions: "CURRENT_MEMBER_PERSONA", providerID: "app-member-fixture", modelID: "test", at: date)
        let peer = try await agents.create(name: "Separate peer", instructions: "SEPARATE_PEER_PERSONA", providerID: "app-member-fixture", modelID: "test", at: date)
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let room = try await groups.create(name: "Original room", summary: "Original task only", memberIDs: [agent.id])
        var chat = Conversation(title: "Actual own DM", providerID: agent.providerID, modelID: agent.modelID,
            messages: [.init(role: .user, text: "PRIVATE_OWN_HISTORY", createdAt: date)], updatedAt: date)
        chat.agentBinding = .init(accountID: "local", agentID: agent.id)
        // Allocate the real native transcript identities before capturing the
        // canonical baseline. A first send normally migrates legacy addresses.
        DirectMessageAddressing.assignMissing(in: &chat)
        let unrelated = Conversation(title: "Unrelated DM", messages: [.init(role: .user, text: "UNRELATED_PRIVATE_HISTORY", createdAt: date)], updatedAt: date)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.save([chat, unrelated])
        let groupGate = AppMemberGate(), humanGate = holdHuman ? AppMemberGate() : nil, probe = AppMemberProbe()
        let generation = UUID(), key = LocalToolRuntime.randomSessionKey()
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: .init(fileURL: root.appending(path: "bookmarks.json")),
            generation: generation, sessionKey: key, helper: helper)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
        await model.registry.register(AppMemberProvider { request, execute in
            let attempt = await probe.request(request, groupID: room.id, execute: execute)
            guard request.conversationID == room.id else {
                await humanGate?.wait(); try Task.checkCancellation()
                return "PRIVATE_HUMAN_RESULT"
            }
            if mode == "published", attempt == 1 {
                let result = try await execute(.init(id: "progress", name: "SendMessage",
                    argumentsJSON: JSONEncoder().encode(["text": "Published progress"])))
                #expect(!result.isError)
            }
            if mode == "approval" {
                let result = try await execute(.init(id: "write", name: "local__write_file", argumentsJSON:
                    JSONEncoder().encode(["root": root.path, "path": "result.txt", "content": "FRESH_APPROVED_RESULT"])))
                try Task.checkCancellation()
                let report = try await execute(.init(id: "report", name: "SendMessage",
                    argumentsJSON: JSONEncoder().encode(["text": result.isError ? "Write declined" : "Write completed"])))
                #expect(!report.isError)
            } else {
                if attempt == 1 {
                    _ = try await execute(.init(id: "cleanup", name: "app-member-cleanup", argumentsJSON: Data("{}".utf8)))
                    try Task.checkCancellation()
                }
                let result = try await execute(.init(id: "report", name: "SendMessage",
                    argumentsJSON: JSONEncoder().encode(["text": "GROUP_RESULT"])))
                #expect(!result.isError)
            }
            return "PRIVATE_GROUP_FINAL"
        })
        await model.bootstrap(); await model.setAutomationRuntimeActive(false); model.setWorkflowRuntimeActive(false)
        // Test-only dependency, installed after bootstrap's real scoped tools.
        // Approval tests below use the real native write/review executors.
        await model.toolCatalog.register(AppMemberCleanupTool(gate: groupGate, probe: probe))
        await model.setAutoReviewEnabled(true)
        if mode == "approval" {
            _ = try await model.localToolRuntime.workspaceStore.authorize(root)
            try await model.localToolPermissionPolicy.setChoice(.ask, for: .writeFile)
        }
        try await model.loadAllMessages(for: chat.id)
        model.selectRoute(.conversation(chat.id)); await model.refreshModels()
        try await eventually {
            model.selection == chat.id && model.selectedConversationConfigurationError == nil && !model.isLoadingModels
                && model.modelCatalogConversationID == chat.id && model.modelCatalogProviderID == agent.providerID
                && model.availableModels.contains { $0.id == agent.modelID }
        }
        let canonicalChat = try #require(try await store.conversation(id: chat.id))
        let canonicalOther = try #require(try await store.conversation(id: unrelated.id))
        return .init(root: root, model: model, agent: agent, peer: peer, room: room, chat: canonicalChat,
            unrelated: canonicalOther, groupGate: groupGate, humanGate: humanGate, probe: probe)
    }

    private func eventually(sourceLocation: SourceLocation = #_sourceLocation,
                            _ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate(), sourceLocation: sourceLocation)
    }

    private func sendHuman(_ f: Fixture) async throws {
        #expect(!f.model.isConversationWorking(f.chat.id))
        #expect(f.model.selectedConversationConfigurationError == nil)
        f.model.draft = "ACTUAL_TYPED_HUMAN_TASK"
        await f.model.sendButtonTapped()
        try await eventually { await f.model.agentExecutionScheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
    }

    private func recordFailureState(_ f: Fixture) async {
        let events = await f.probe.events
        let lane = await f.model.agentExecutionScheduler.snapshot(agentID: f.agent.id)
        Issue.record("Isolated native state: events=\(events), lane=\(lane), running=\(f.model.runningGroups), error=\(f.model.errorMessage ?? "nil"), room=\(f.model.groupMessages[f.room.id, default: []])")
    }

    private func assertPrivateBoundary(_ f: Fixture) async throws {
        let requests = await f.probe.requests
        let groupRequests = requests.filter { $0.conversationID == f.room.id }
        #expect(groupRequests.allSatisfy { request in
            !request.messages.contains { $0.text.contains("PRIVATE_OWN_HISTORY") || $0.text.contains("PRIVATE_HUMAN_RESULT")
                || $0.text.contains("ACTUAL_TYPED_HUMAN_TASK") || $0.text.contains("UNRELATED_PRIVATE_HISTORY") }
        })
        #expect(requests.allSatisfy { !$0.messages.contains { $0.text.contains("UNRELATED_PRIVATE_HISTORY") } })
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let unrelated = try await store.conversation(id: f.unrelated.id)
        expectNoDifference(unrelated, f.unrelated)
        let own = try #require(try await store.conversation(id: f.chat.id))
        expectNoDifference(Array(own.messages.prefix(f.chat.messages.count)), f.chat.messages)
        #expect(!own.messages.contains { $0.text == "GROUP_RESULT" || $0.text == "PRIVATE_GROUP_FINAL" })
        #expect(f.model.groupMessages[f.room.id, default: []].allSatisfy { !$0.text.contains("PRIVATE_") })
    }

    @Test(arguments: ["resume", "published", "stop", "persona restore", "account restore"])
    func actualTypedHumanSendWaitsForCleanupAndOnlyCurrentGroupMayResume(boundary: String) async throws {
        let f = try await fixture(mode: boundary == "published" ? "published" : "cleanup")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let group = Task { await f.model.sendGroupMessage(groupID: f.room.id, text: "GROUP_TASK") }
        do {
            try await eventually { await f.groupGate.isWaiting }
            try await sendHuman(f)
            let blocked = await f.probe.events
            expectNoDifference(blocked, ["group 1", "tool"])
            await f.groupGate.open()
            try await eventually { await f.humanGate?.isWaiting == true }
            if boundary != "published" {
                try await eventually { await f.model.agentExecutionScheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            } else { await group.value }
            if boundary == "stop" { await f.model.stopGroup(id: f.room.id) }
            else if boundary == "persona restore" {
                var edited = f.agent; edited.instructions = "CHANGED_PERSONA"
                #expect(await f.model.updateAgent(edited)); #expect(await f.model.updateAgent(f.agent))
            } else if boundary == "account restore" {
                await f.model.cancelAutoReviewApprovals(nextAccountID: "foreign")
                f.model.settings.accountScope = "foreign"
                await f.model.cancelAutoReviewApprovals(nextAccountID: "local")
                f.model.settings.accountScope = nil
            }
            await f.humanGate?.open(); await group.value
            try await eventually { !f.model.isConversationWorking(f.chat.id) && !f.model.runningGroups.contains(f.room.id) }
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), boundary == "resume"
                ? [f.room.id, f.chat.id, f.room.id] : [f.room.id, f.chat.id])
            let groupMessages = f.model.groupMessages[f.room.id, default: []]
            expectNoDifference(groupMessages.filter { $0.senderID != nil && !$0.text.isEmpty }.map(\.text),
                boundary == "resume" ? ["GROUP_RESULT"] : boundary == "published" ? ["Published progress"] : [])
            #expect(!groupMessages.contains { $0.memberOutcome == .failed })
            expectNoDifference(groupMessages.flatMap(\.toolActivities).filter { $0.name == "app-member-cleanup" }.map(\.status), [.cancelled])
            let old = try #require(await f.probe.callbacks.first)
            let before = f.model.groupMessages[f.room.id, default: []]
            do {
                let late = try await old(.init(id: "late-old-report", name: "SendMessage",
                    argumentsJSON: JSONEncoder().encode(["text": "STALE_PUBLICATION"])))
                #expect(late.isError)
            } catch { #expect(error is CancellationError) }
            expectNoDifference(f.model.groupMessages[f.room.id, default: []], before)
            try await assertPrivateBoundary(f)
        } catch {
            await recordFailureState(f)
            group.cancel(); await f.release(); await f.model.stopGroup(id: f.room.id)
            f.model.cancel(); await group.value
            throw error
        }
    }

    @Test(arguments: ["review", "local permission"], [false, true])
    func resumedGroupRequiresFreshNativeReviewAndLocalPermission(phase: String, allow: Bool) async throws {
        let f = try await fixture(mode: "approval")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let group = Task { await f.model.sendGroupMessage(groupID: f.room.id, text: "Write result.txt only after approval") }
        do {
            try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty }
            let oldReview = try #require(f.model.pendingAutoReviewApprovals.first)
            if phase == "local permission" {
                await f.model.resolveGroupApproval(oldReview, groupID: f.room.id, approve: true)
                try await eventually { !f.model.pendingToolApprovals.isEmpty }
            }
            let oldPermission = f.model.pendingToolApprovals.first
            let permissionPolicy = await f.model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
            try await sendHuman(f)
            try await eventually { await f.humanGate?.isWaiting == true }
            try await eventually { await f.model.agentExecutionScheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            expectNoDifference(f.model.pendingAutoReviewApprovals, [])
            expectNoDifference(f.model.pendingToolApprovals, [])
            #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "result.txt").path))
            await f.humanGate?.open()
            try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty }
            let freshReview = try #require(f.model.pendingAutoReviewApprovals.first)
            #expect(freshReview.id != oldReview.id)
            #expect(freshReview.action.context.fence.runID != oldReview.action.context.fence.runID)
            let pending = f.model.pendingAutoReviewApprovals
            // Stale UI callbacks must not approve the newly admitted attempt.
            await f.model.resolveGroupApproval(oldReview, groupID: f.room.id, approve: true)
            if let oldPermission { f.model.resolveLocalToolApproval(id: oldPermission.id, allowed: true) }
            expectNoDifference(f.model.pendingAutoReviewApprovals, pending)
            expectNoDifference(f.model.pendingToolApprovals, [])
            #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "result.txt").path))
            await f.model.resolveGroupApproval(freshReview, groupID: f.room.id, approve: true)
            try await eventually { !f.model.pendingToolApprovals.isEmpty }
            let freshPermission = try #require(f.model.pendingToolApprovals.first)
            expectNoDifference(freshPermission.conversationID, freshReview.action.context.conversationID)
            expectNoDifference(freshPermission.toolCallID, freshReview.action.context.toolCallID)
            if let oldPermission { #expect(freshPermission.id != oldPermission.id) }
            let actualPolicy = await f.model.localToolPermissionPolicy.effectivePermission(for: .writeFile)
            expectNoDifference(actualPolicy, permissionPolicy)
            let waiting = f.model.pendingToolApprovals
            if let oldPermission { f.model.resolveLocalToolApproval(id: oldPermission.id, allowed: true) }
            expectNoDifference(f.model.pendingToolApprovals, waiting)
            f.model.resolveLocalToolApproval(id: freshPermission.id, allowed: allow)
            await group.value
            try await eventually { !f.model.isConversationWorking(f.chat.id) }
            expectNoDifference(FileManager.default.fileExists(atPath: f.root.appending(path: "result.txt").path), allow)
            if allow { expectNoDifference(try String(contentsOf: f.root.appending(path: "result.txt"), encoding: .utf8), "FRESH_APPROVED_RESULT") }
            expectNoDifference(f.model.groupMessages[f.room.id, default: []].filter { $0.senderID != nil && !$0.text.isEmpty }.map(\.text),
                [allow ? "Write completed" : "Write declined"])
            let requests = await f.probe.requests
            expectNoDifference(requests.map(\.conversationID), [f.room.id, f.chat.id, f.room.id])
            expectNoDifference(f.model.pendingAutoReviewApprovals, [])
            expectNoDifference(f.model.pendingToolApprovals, [])
            try await assertPrivateBoundary(f)
        } catch {
            await recordFailureState(f)
            group.cancel(); await f.release(); await f.model.stopGroup(id: f.room.id)
            f.model.cancel(); await group.value
            throw error
        }
    }

    @Test(arguments: [false, true])
    func onlyExplicitPriorityPeerMessagePreemptsActualGroup(priority: Bool) async throws {
        let f = try await fixture(holdHuman: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let group = Task { await f.model.sendGroupMessage(groupID: f.room.id, text: "GROUP_TASK") }
        do {
            try await eventually { await f.groupGate.isWaiting }
            #expect(await f.model.sendAgentMessage(senderID: f.peer.id, recipientID: f.agent.id, text: "EXACT_PEER_TASK", priority: priority ? .priority : .normal))
            try await eventually { await f.model.agentExecutionScheduler.snapshot(agentID: f.agent.id).queuedCount == 1 }
            let before = await f.probe.events
            expectNoDifference(before, ["group 1", "tool"])
            await f.groupGate.open(); await group.value
            try await eventually { f.model.runningAgentMessageScopes.isEmpty }
            let requests = await f.probe.requests
            expectNoDifference(requests.filter { $0.conversationID == f.room.id }.count, priority ? 2 : 1)
            expectNoDifference(f.model.groupMessages[f.room.id, default: []].filter { $0.senderID != nil && !$0.text.isEmpty }.map(\.text), ["GROUP_RESULT"])
            #expect(!f.model.groupMessages[f.room.id, default: []].contains { $0.memberOutcome == .failed })
            let delivery = try #require(f.model.agentMessages.first?.delivery)
            expectNoDifference(delivery.state, .completed)
            try await assertPrivateBoundary(f)
        } catch {
            await recordFailureState(f)
            group.cancel(); await f.release(); await f.model.stopGroup(id: f.room.id)
            for scope in f.model.runningAgentMessageScopes { await f.model.stopAgentMessages(scopeID: scope) }
            await group.value
            throw error
        }
    }
}
