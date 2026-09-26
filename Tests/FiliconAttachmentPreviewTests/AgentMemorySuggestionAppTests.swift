import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor MemorySuggestionAppProbe {
    private(set) var requests: [InferenceRequest] = []
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    func record(_ request: InferenceRequest) { requests.append(request) }
    func hold() async {
        entered.continuation.yield(())
        for await _ in release.stream { break }
    }
    func wait() async { for await _ in entered.stream { break } }
    func resume() { release.continuation.finish() }
}

private struct MemorySuggestionAppProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "memory-app-fixture", displayName: "Memory", requiresAPIKey: false)
    let probe: MemorySuggestionAppProbe
    var gated = false
    var malformed = false
    var synthesis = false
    var gatedSynthesisStage: String?
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                let proposal = request.messages.first?.text.contains("Maintain compact durable") == true
                let verification = request.messages.first?.text.contains("Independently verify") == true
                if synthesis && (proposal || verification) {
                    if gatedSynthesisStage == (proposal ? "proposal" : "verification") { await probe.hold() }
                    let object = try? JSONSerialization.jsonObject(with: Data((request.messages.last?.text ?? "").utf8)) as? [String: Any]
                    let evidenceID = (object?["evidence"] as? [[String: Any]])?.first?["id"] as? String ?? "missing"
                    let temporal = object?["clockEvidenceID"] as? String == "clock"
                    let text = proposal && temporal ? #"{"changes":[]}"# : proposal
                        ? #"{"changes":[{"action":"create","content":"Prefers accessible layouts","kind":"profile","sourceEvidenceIds":["\#(evidenceID)"]}]}"#
                        : #"{"approved":true}"#
                    continuation.yield(.textDelta(text)); continuation.yield(.completed(.stop)); continuation.finish()
                    return
                }
                let extraction = request.messages.first?.text == AgentMemorySuggestionExtractor.instructions
                if !extraction {
                    if request.toolExchanges.isEmpty {
                        do {
                            let call = try NormalizedToolCall(id: "report", name: "SendMessage",
                                argumentsJSON: JSONEncoder().encode(["text": "Understood. I will review the layout."]))
                            continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                            continuation.yield(.toolCallCompleted(call))
                            continuation.yield(.completed(.toolUse))
                        } catch { continuation.finish(throwing: error); return }
                    } else { continuation.yield(.completed(.stop)) }
                    continuation.finish(); return
                }
                if extraction && gated { await probe.hold() }
                let text = extraction
                    ? (malformed ? "Not a valid suggestion response" : #"{"suggestions":[{"fact":"Prefers accessible layouts","evidence":"accessible layouts","tier":"profile"}]}"#)
                    : "Understood. I will review the layout."
                continuation.yield(.textDelta(text)); continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class SynthesisAppTime: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    private var wallDate = Date(timeIntervalSince1970: 1_900_000_000)
    var date: Date { lock.withLock { wallDate } }
    func advanceDate(_ seconds: TimeInterval) { lock.withLock { wallDate.addTimeInterval(seconds) } }
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(to deadline: ContinuousClock.Instant) { lock.withLock { instant = max(instant, deadline) } }
}

private actor SynthesisAppTimer {
    private(set) var count = 0
    private var gates: [AsyncStream<Void>.Continuation] = []
    func wait() async throws {
        let pair = AsyncStream<Void>.makeStream()
        gates.append(pair.continuation); count += 1
        for await _ in pair.stream { break }
        try Task.checkCancellation()
    }
    func release() {
        for gate in gates { gate.yield(()); gate.finish() }
        gates.removeAll()
    }
}

@Suite("Memory suggestion app integration", .timeLimit(.minutes(1)))
@MainActor struct AgentMemorySuggestionAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let owner: AgentProfile
        let peer: AgentProfile
        let group: AgentGroup
        let probe = MemorySuggestionAppProbe()
        func enable() async throws {
            let initial = try await model.memorySuggestionSnapshot(agentID: owner.id)
            try await model.setMemorySuggestionsEnabled(true, expected: initial.settings)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "memory-suggestion-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let time = SynthesisAppTime()
        model.memorySynthesisWorkerFactory = { run in
            AgentMemorySynthesisWorker(now: { time.now }, sleep: { deadline in
                try Task.checkCancellation()
                time.advance(to: deadline)
            }, run: run)
        }
        let owner = try #require(await model.createAgent(name: "Owner", summary: "", instructions: "", providerID: "memory-app-fixture", modelID: "test"))
        let peer = try #require(await model.createAgent(name: "Peer", summary: "", instructions: "", providerID: "memory-app-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Team", summary: "", memberIDs: [owner.id, peer.id]))
        return .init(root: root, model: model, owner: owner, peer: peer, group: try #require(model.groups.first))
    }

    @Test(arguments: ["scheduled", "account", "disabled"])
    func startupAndHourlyTemporalReviewRemainAccountFenced(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "temporal-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await service.create(name: "Owner", instructions: "", providerID: "memory-app-fixture", modelID: "test", at: date)
        try await service.applyMemoryChange(.init(operation: .write, memory: .init(accountID: "local", agentID: owner.id,
            fact: "Existing preference", createdAt: date)), lifetime: .init())
        if mode != "disabled" {
            let disabled = try await service.memorySynthesisSettings(accountID: "local", agentID: owner.id)
            try await service.setMemorySynthesisEnabled(true, expected: disabled, lifetime: .init())
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let time = SynthesisAppTime(), debounce = SynthesisAppTimer(), hourly = SynthesisAppTimer()
        let probe = MemorySuggestionAppProbe()
        model.memoryTemporalNow = { time.date }
        model.memoryTemporalSleep = { duration in
            expectNoDifference(duration, .seconds(3_600))
            try await hourly.wait()
        }
        model.memorySynthesisWorkerFactory = { run in
            AgentMemorySynthesisWorker(now: { time.now }, sleep: { deadline in
                try await debounce.wait(); time.advance(to: deadline)
            }, run: run)
        }
        defer { model.stopMemoryTemporalReviews() }
        await model.bootstrap()
        await model.registry.register(MemorySuggestionAppProvider(probe: probe, synthesis: true))
        func wait(_ condition: () async -> Bool) async throws {
            for _ in 0..<500 {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            Issue.record("Temporal app did not reach the expected state")
            throw CancellationError()
        }
        try await wait { await hourly.count == 1 }
        model.startMemoryTemporalReviews() // Idempotent; no second startup sweep/timer.
        if mode != "disabled" { try await wait { await debounce.count == 1 } }
        if mode == "account" {
            await model.cancelAutoReviewApprovals(nextAccountID: "other")
            model.settings.scopeToAccount("other")
        }
        await debounce.release()
        try await wait { await model.isBackgroundMemorySynthesisIdle() }
        let requests = await probe.requests
        expectNoDifference(requests.count, mode == "scheduled" ? 1 : 0)
        let diagnostic = model.rootDiagnostics()
        #expect(diagnostic.contains(mode == "scheduled" ? "noWork=1" : "memorySynthesis=none"))
        #expect(!diagnostic.contains("Existing preference"))
        if let request = requests.first {
            let payload = try #require(request.messages.last?.text)
            let object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            expectNoDifference(object["clockEvidenceID"] as? String, "clock")
            expectNoDifference((object["evidence"] as? [Any])?.count, 0)
            #expect(request.tools.isEmpty)
        }
        await hourly.release()
        try await wait { await hourly.count == 2 }
        let after = await probe.requests
        expectNoDifference(after.count, requests.count)
        let timerCount = await debounce.count
        expectNoDifference(timerCount, mode == "disabled" ? 0 : 1)
        if mode == "scheduled" {
            time.advanceDate(86_400)
            await hourly.release()
            try await wait { await hourly.count == 3 }
            try await wait { await debounce.count == 2 }
            await debounce.release()
            try await wait { await model.isBackgroundMemorySynthesisIdle() }
            let nextDayCount = await probe.requests.count
            expectNoDifference(nextDayCount, 2)
            #expect(model.rootDiagnostics().contains("noWork=2"))
            await model.cancelAutoReviewApprovals(nextAccountID: "other")
            #expect(model.rootDiagnostics().contains("memorySynthesis=none"))
        }
        model.stopMemoryTemporalReviews()
        await hourly.release()
    }

    @Test(arguments: ["keep", "remove-group", "account"])
    func completedChatsHandoffAndCoalesceWithoutKeepingForegroundBusy(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let time = SynthesisAppTime(), timer = SynthesisAppTimer()
        f.model.memorySynthesisWorkerFactory = { run in
            AgentMemorySynthesisWorker(now: { time.now }, sleep: { deadline in
                try await timer.wait(); time.advance(to: deadline)
            }, run: run)
        }
        await f.model.bootstrap()
        let initial = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
        try await f.model.setMemorySynthesisEnabled(true, expected: initial)
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, synthesis: true))
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts")
        #expect(f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        let directID = try #require(await f.model.addConversation(agentID: f.owner.id))
        f.model.draft = "I prefer short summaries"; f.model.send()
        let deadline = ContinuousClock.now + .seconds(10)
        while f.model.isConversationWorking(directID), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!f.model.isConversationWorking(directID))
        while await timer.count < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(await timer.count >= 2)
        let before = await f.probe.requests.filter { $0.messages.first?.text.contains("Maintain compact durable") == true }
        expectNoDifference(before.count, 0)
        switch mode {
        case "remove-group": await f.model.updateGroupMembers(groupID: f.group.id, memberIDs: [])
        case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
        default: break
        }
        await timer.release()
        while !(await f.model.isBackgroundMemorySynthesisIdle()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await f.model.isBackgroundMemorySynthesisIdle())
        let proposals = await f.probe.requests.filter { $0.messages.first?.text.contains("Maintain compact durable") == true }
        expectNoDifference(proposals.count, mode == "account" ? 0 : 1)
        if mode != "account" {
            let proposal = try #require(proposals.first)
            let data = Data(try #require(proposal.messages.last?.text).utf8)
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let evidence = try #require(object["evidence"] as? [[String: Any]])
            expectNoDifference(evidence.count, mode == "keep" ? 2 : 1)
            if mode == "remove-group" { expectNoDifference(evidence.first?["user"] as? String, "I prefer short summaries") }
        }
        let facts = try await f.model.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(facts.count, mode == "account" ? 0 : 1)
    }

    @Test(arguments: ["direct", "group"], ["enabled", "disabled", "stop-proposal", "stop-verification", "account", "disable", "reenable", "delete-or-members"])
    func synthesisAppLifecycleRejectsLateCommits(route: String, mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if route == "direct" { await f.model.bootstrap() }
        let initial = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
        if mode != "disabled" { try await f.model.setMemorySynthesisEnabled(true, expected: initial) }
        let gated = !["enabled", "disabled"].contains(mode)
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, synthesis: true,
            gatedSynthesisStage: gated ? (mode == "stop-proposal" ? "proposal" : "verification") : nil))
        let directID: UUID?
        let groupTask: Task<Void, Never>?
        if route == "direct" {
            directID = try #require(await f.model.addConversation(agentID: f.owner.id))
            groupTask = nil
            f.model.draft = "I prefer accessible layouts"
            f.model.send()
        } else {
            directID = nil
            groupTask = Task { await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts") }
        }
        defer { groupTask?.cancel() }
        if gated {
            await f.probe.wait()
            switch mode {
            case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
            case "disable", "reenable":
                let current = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
                try await f.model.setMemorySynthesisEnabled(false, expected: current)
                if mode == "reenable" {
                    let disabled = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
                    try await f.model.setMemorySynthesisEnabled(true, expected: disabled)
                }
            case "delete-or-members":
                if let directID { f.model.deleteConversation(id: directID) }
                else { await f.model.updateGroupMembers(groupID: f.group.id, memberIDs: []) }
            default:
                if directID != nil { f.model.cancel() }
                else { await f.model.stopGroup(id: f.group.id) }
            }
            await f.probe.resume()
        }
        await groupTask?.value
        if let directID {
            let deadline = ContinuousClock.now + .seconds(10)
            while f.model.isConversationWorking(directID), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!f.model.isConversationWorking(directID))
        }
        let backgroundDeadline = ContinuousClock.now + .seconds(10)
        while !(await f.model.isBackgroundMemorySynthesisIdle()), ContinuousClock.now < backgroundDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await f.model.isBackgroundMemorySynthesisIdle())
        let facts = try await f.model.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(facts.map(\.fact), mode == "enabled" ? ["Prefers accessible layouts"] : [])
        expectNoDifference(facts.map(\.origin), mode == "enabled" ? [.synthesis] : [])
        let peer = try await f.model.savedAgentMemories(agentID: f.peer.id)
        expectNoDifference(peer, [])
        let requests = await f.probe.requests.filter {
            $0.messages.first?.text.contains("Maintain compact durable") == true ||
            $0.messages.first?.text.contains("Independently verify") == true
        }
        expectNoDifference(requests.count, mode == "disabled" ? 0 : mode == "stop-proposal" ? 1 : 2)
        #expect(requests.allSatisfy { $0.tools.isEmpty && $0.toolExchanges.isEmpty && $0.attachmentsByMessageID.isEmpty })
        #expect(f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
    }

    @Test func synthesisPreferenceIsIndependentScopedAndPersisted() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let initial = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
        expectNoDifference(initial.enabled, false)
        try await f.enable()
        let afterSuggestions = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
        expectNoDifference(afterSuggestions, initial)
        try await f.model.setMemorySynthesisEnabled(true, expected: initial)
        let enabled = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
        expectNoDifference(enabled.enabled, true)
        #expect(enabled.revision != nil)
        let peer = try await f.model.memorySynthesisSettings(agentID: f.peer.id)
        expectNoDifference(peer.enabled, false)
        do {
            try await f.model.setMemorySynthesisEnabled(false, expected: initial)
            Issue.record("Stale preference must be rejected")
        } catch {}
        let foreign = AgentMemorySynthesisSettings(accountID: "other", agentID: f.owner.id)
        do {
            try await f.model.setMemorySynthesisEnabled(true, expected: foreign)
            Issue.record("Another account must be rejected")
        } catch {}
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let reopened = try await restored.memorySynthesisSettings(agentID: f.owner.id)
        expectNoDifference(reopened, enabled)
        try await f.model.setMemorySynthesisEnabled(false, expected: enabled)
        let disabled = try await f.model.memorySynthesisSettings(agentID: f.owner.id)
        expectNoDifference(disabled.enabled, false)
        #expect(disabled.revision != enabled.revision)
        let suggestions = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(suggestions.settings.enabled, true)
    }

    @Test(arguments: [false, true])
    func directCompletionProducesOnlyOptedInReviewCandidates(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.bootstrap()
        if enabled { try await f.enable() }
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe))
        let id = try #require(await f.model.addConversation(agentID: f.owner.id))
        f.model.draft = "I prefer accessible layouts"
        f.model.send()
        let deadline = ContinuousClock.now + .seconds(10)
        while f.model.isConversationWorking(id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!f.model.isConversationWorking(id))
        #expect(f.model.errorMessage == nil)
        let snapshot = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(snapshot.suggestions.map(\.fact), enabled ? ["Prefers accessible layouts"] : [])
        let facts = try await f.model.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(facts, [])
        let other = try await f.model.memorySuggestionSnapshot(agentID: f.peer.id)
        expectNoDifference(other.suggestions, [])
        let requests = await f.probe.requests
        let extra = requests.filter { $0.messages.first?.text == AgentMemorySuggestionExtractor.instructions }
        expectNoDifference(extra.count, enabled ? 1 : 0)
        #expect(extra.allSatisfy { $0.tools.isEmpty && $0.attachmentsByMessageID.isEmpty })
        #expect(!f.model.conversations.flatMap(\.messages).contains { $0.text.contains("suggestions") })
    }

    @Test(arguments: ["stop", "account", "delete", "disable"])
    func directLifecycleDiscardsLateMemoryCandidates(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.bootstrap()
        try await f.enable()
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, gated: true))
        let id = try #require(await f.model.addConversation(agentID: f.owner.id))
        f.model.draft = "I prefer accessible layouts"
        f.model.send()
        await f.probe.wait()
        #expect(f.model.conversations.first(where: { $0.id == id })?.messages.contains {
            $0.role == .assistant && $0.text == "Understood. I will review the layout."
        } == true)
        switch mode {
        case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "delete": f.model.deleteConversation(id: id)
        case "disable":
            let snapshot = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
            try await f.model.setMemorySuggestionsEnabled(false, expected: snapshot.settings)
        default: f.model.cancel()
        }
        await f.probe.resume()
        let deadline = ContinuousClock.now + .seconds(10)
        while f.model.isConversationWorking(id), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!f.model.isConversationWorking(id))
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let snapshot = try await restored.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(snapshot.suggestions, [])
        let facts = try await restored.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(facts, [])
    }

    @Test(arguments: [false, true])
    func groupCompletionProducesOnlyOptedInPrivateReviewCandidates(enabled: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        if enabled { try await f.enable() }
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe))
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts")
        #expect(f.model.errorMessage == nil && f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        let requests = await f.probe.requests
        let extra = requests.filter { $0.messages.first?.text == AgentMemorySuggestionExtractor.instructions }
        expectNoDifference(extra.count, enabled ? 1 : 0)
        #expect(extra.allSatisfy { $0.tools.isEmpty && $0.toolExchanges.isEmpty && $0.attachmentsByMessageID.isEmpty })
        let history = f.model.groupMessages[f.group.id, default: []]
        expectNoDifference(history.filter { $0.senderID != nil && !$0.text.isEmpty }.map(\.senderID), [f.owner.id])
        #expect(!history.contains { $0.text.contains("suggestions") })
        let snapshot = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(snapshot.suggestions.map(\.fact), enabled ? ["Prefers accessible layouts"] : [])
        let facts = try await f.model.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(facts, [])
        let other = try await f.model.memorySuggestionSnapshot(agentID: f.peer.id)
        #expect(!other.settings.enabled && other.suggestions.isEmpty)
        if enabled {
            let candidate = try #require(snapshot.suggestions.first)
            try await f.model.reviewMemorySuggestion(candidate, accept: true)
            let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
            await restored.reloadWorkspaceData()
            let saved = try await restored.savedAgentMemories(agentID: f.owner.id)
            expectNoDifference(saved.map(\.fact), [candidate.fact]); expectNoDifference(saved.map(\.scope), [.agent])
            let pending = try await restored.memorySuggestionSnapshot(agentID: f.owner.id)
            #expect(pending.settings.enabled && pending.suggestions.isEmpty)
            let shared = try await restored.savedAgentMemories(agentID: f.owner.id, scope: .user)
            expectNoDifference(shared, [])
        }
    }

    @Test(arguments: ["stop", "account", "members", "disable"])
    func lifecycleChangesDiscardLateMaintenanceWithoutRemovingPublishedReply(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.enable()
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, gated: true))
        let sending = Task { await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts") }
        defer { sending.cancel() }
        await f.probe.wait()
        #expect(f.model.runningGroups.contains(f.group.id) && f.model.reviewingMemoryGroups.contains(f.group.id))
        #expect(f.model.groupMessages[f.group.id, default: []].contains { $0.senderID == f.owner.id && !$0.text.isEmpty })
        switch mode {
        case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "members": await f.model.updateGroupMembers(groupID: f.group.id, memberIDs: [])
        case "disable":
            let current = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
            try await f.model.setMemorySuggestionsEnabled(false, expected: current.settings)
        default: await f.model.stopGroup(id: f.group.id)
        }
        await f.probe.resume(); await sending.value
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let current = try await restored.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(current.suggestions, [])
        let saved = try await restored.savedAgentMemories(agentID: f.owner.id)
        expectNoDifference(saved, [])
        #expect(f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        #expect(restored.groupMessages[f.group.id, default: []].contains { $0.senderID == f.owner.id && !$0.text.isEmpty })
    }

    @Test func malformedExtractionDoesNotFailOrRepeatCompletedGroupTurn() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.enable()
        await f.model.registry.register(MemorySuggestionAppProvider(probe: f.probe, malformed: true))
        await f.model.sendGroupMessage(groupID: f.group.id, text: "@Owner I prefer accessible layouts")
        #expect(f.model.errorMessage == nil && f.model.runningGroups.isEmpty && f.model.reviewingMemoryGroups.isEmpty)
        let current = try await f.model.memorySuggestionSnapshot(agentID: f.owner.id)
        expectNoDifference(current.suggestions, [])
        let requests = await f.probe.requests
        expectNoDifference(requests.filter { $0.messages.first?.text == AgentMemorySuggestionExtractor.instructions }.count, 1)
        expectNoDifference(f.model.groupMessages[f.group.id, default: []].filter { $0.senderID != nil && !$0.text.isEmpty }.count, 1)
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func reviewCardAndDisclosureRenderInSevenLanguages(language: String) async throws {
        let candidate = AgentMemorySuggestion(accountID: "local", agentID: UUID(), exchangeID: UUID(),
            fact: "Prefers accessible layouts with clear focus indicators and consistent spacing.",
            evidence: "accessible layouts with clear focus indicators and consistent spacing", tier: .profile)
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                if language != "en" {
                    for key in ["Memory suggestions", "Save as private memory…", "Dismiss suggestion", "Reviewing memory suggestions…", AgentMemorySuggestionsNotice.disclosure,
                        "Automatic memory synthesis", "Disable automatic synthesis", "Enable automatic synthesis…",
                        "Enable automatic memory synthesis?", AgentMemorySynthesisNotice.disclosure, AgentMemorySynthesisNotice.temporalDisclosure] {
                        #expect(FiliconLocalization.string(key) != key)
                    }
                }
                let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 20) {
                    Text(l10n("Memory suggestions")).font(.headline)
                    AgentMemorySuggestionsNotice()
                    Text(l10n("Automatic memory synthesis")).font(.headline)
                    AgentMemorySynthesisNotice()
                    Button(l10n("Enable automatic synthesis…")) {}
                    AgentMemorySuggestionCard(suggestion: candidate, onSave: {}, onDismiss: {})
                    AgentMemoryReviewProgress()
                }.padding(16).frame(width: 380).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                expectNoDifference(size.width, 380)
                #expect(size.height > 250 && size.height < 1100)
                host.frame = .init(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "memory-suggestion-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
