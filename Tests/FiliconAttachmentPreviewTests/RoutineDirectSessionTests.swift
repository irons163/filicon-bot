import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
import FiliconDomain
import FiliconProviderKit
import FiliconLocalTools
@testable import Filicon

private actor RoutineDirectProbe {
    var plain: [InferenceRequest] = []
    var shared: [InferenceRequest] = []
    var activityCardsAtInference: [Bool] = []
    func recordPlain(_ request: InferenceRequest) { plain.append(request) }
    func recordShared(_ request: InferenceRequest, activityCardExists: Bool? = nil) -> Int {
        shared.append(request)
        if let activityCardExists { activityCardsAtInference.append(activityCardExists) }
        return shared.filter { $0.conversationID == request.conversationID }.count
    }
}
private actor RoutineDirectGate {
    var started = false
    var open = false
    var continuation: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        started = true
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                if open { value.resume() } else { continuation = value }
            }
        } onCancel: { Task { await self.release(cancelled: true) } }
    }
    func release(cancelled: Bool = false) {
        open = true
        if cancelled { continuation?.resume(throwing: CancellationError()) } else { continuation?.resume() }
        continuation = nil
    }
}
private struct RoutineDirectProvider: InteractiveToolProvider {
    var supportsTools = true
    var descriptor: ProviderDescriptor {
        .init(id: "routine-direct-fixture", displayName: "Routine direct fixture", requiresAPIKey: false, supportsToolCalling: supportsTools)
    }
    let probe: RoutineDirectProbe
    var gate: RoutineDirectGate? = nil
    var question = false
    var silent = false
    var writeRoot: URL? = nil
    var peerID: UUID? = nil
    var activityStoreURL: URL? = nil
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.recordPlain(request)
                continuation.yield(.textDelta("LEGACY_DIRECT")); continuation.yield(.completed(.stop)); continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let activityCardExists: Bool?
                    if let activityStoreURL {
                        let chat = try await ConversationStore(fileURL: activityStoreURL).conversation(id: request.conversationID)
                        activityCardExists = chat?.messages.flatMap(\.transcriptCards).contains { card in
                            if case .widget(let widget) = card.payload { return widget.automationActivity != nil }
                            return false
                        } == true
                    } else { activityCardExists = nil }
                    let index = await probe.recordShared(request, activityCardExists: activityCardExists)
                    try await gate?.wait()
                    let owner = request.messages.first?.text.contains("DIRECT_PERSONA") == true
                    if owner, index == 1, let peerID {
                        _ = try await executeTool(.init(id: "routine-peer", name: "SendToAgent",
                            argumentsJSON: JSONEncoder().encode(["recipientID": peerID.uuidString, "message": "Review only the explicitly delivered fixture task."])))
                    }
                    if let writeRoot {
                        _ = try await executeTool(.init(id: "routine-write", name: "local__write_file",
                            argumentsJSON: JSONEncoder().encode(["root": writeRoot.path, "path": "routine-created.txt", "content": "APPROVED_DIRECT_WRITE"])))
                    }
                    if question, request.messages.contains(where: { $0.role == .system && $0.text.contains("host-bound background routine wake") }) {
                        _ = try await executeTool(.init(id: "routine-choice", name: "SendMessage",
                            argumentsJSON: Data(#"{"type":"widget","widget":{"prompt":"Which fixture?","options":[{"label":"Inspect only","value":"Inspect only"}]}}"#.utf8)))
                        Issue.record("A routine question must end the current turn")
                    } else if !silent {
                        _ = try await executeTool(.init(id: "routine-result", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(["text": peerID != nil && !owner ? "PEER_DIRECT_RESULT" : "SHARED_DIRECT_RESULT"])))
                    }
                    continuation.yield(.usage(.init(inputTokens: 8, outputTokens: 3)))
                    continuation.yield(.textDelta("PRIVATE_ASSISTANT_TEXT"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Routine direct sessions", .timeLimit(.minutes(1)))
@MainActor struct RoutineDirectSessionTests {
    private let base = Date(timeIntervalSince1970: 1_000)
    private func fixture(gate: RoutineDirectGate? = nil, question: Bool = false, silent: Bool = false, write: Bool = false, peer: Bool = false, activityProbe: Bool = false) async throws -> (URL, AppModel, Automation, UUID, RoutineDirectProbe) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-routine-direct-\(UUID())")
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        let agent = try await service.create(name: "Reviewed agent", instructions: "DIRECT_PERSONA",
            providerID: "routine-direct-fixture", modelID: "fixture", at: base)
        try await service.applyMemoryChange(.init(operation: .write, memory: .init(accountID: "local", agentID: agent.id,
            fact: "PRIVATE_SAVED_FACT", createdAt: base)), lifetime: .init())
        if peer {
            let profile = try await service.create(name: "Peer", instructions: "PEER_PERSONA",
                providerID: agent.providerID, modelID: agent.modelID, at: base.addingTimeInterval(1))
            try await service.applyMemoryChange(.init(operation: .write, memory: .init(accountID: "local", agentID: profile.id,
                fact: "PRIVATE_PEER_FACT", createdAt: base)), lifetime: .init())
        }
        let routines = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let initial = try await routines.save(.init(agentID: agent.id, name: "Reviewed routine", prompt: "DIRECT_ROUTINE_TASK",
            trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), enabled: false, createdAt: base), now: base)
        var conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000051")!, title: "Reviewed conversation",
            providerID: agent.providerID, modelID: agent.modelID, messages: [.init(role: .user, text: "REVIEWED_HISTORY", createdAt: base)], updatedAt: base)
        conversation.agentBinding = .init(accountID: "local", agentID: agent.id)
        let unrelated = Conversation(title: "Other chat", messages: [.init(role: .user, text: "UNRELATED_PRIVATE_HISTORY", createdAt: base)])
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.save([conversation, unrelated])
        let model: AppModel
        if write {
            let generation = UUID(), key = LocalToolRuntime.randomSessionKey()
            let authenticator = LocalSessionAuthenticator(sessionKey: key)
            let host = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
                authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
            let runtime = LocalToolRuntime(workspaceStore: WorkspaceAuthorizationStore(fileURL: root.appending(path: "bookmarks.json")),
                generation: generation, sessionKey: key, helper: host)
            model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime)
            _ = try await runtime.workspaceStore.authorize(root)
            try await model.localToolPermissionPolicy.setChoice(.ask, for: .writeFile)
        } else { model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false) }
        let probe = RoutineDirectProbe()
        await model.registry.register(RoutineDirectProvider(probe: probe, gate: gate, question: question, silent: silent, writeRoot: write ? root : nil,
            activityStoreURL: activityProbe ? root.appending(path: "conversations.json") : nil))
        await model.bootstrap()
        // Bootstrap must not fire a wall-clock overdue fixture or race account
        // restoration. Pause only this isolated scheduler, then arm the routine.
        await model.setAutomationRuntimeActive(false)
        await model.setAutomationEnabled(id: initial.id, enabled: true)
        let automation = try #require(model.automations.first { $0.id == initial.id })
        try await model.loadAllMessages(for: conversation.id)
        model.selectRoute(.conversation(conversation.id))
        return (root, model, automation, conversation.id, probe)
    }
    private func approve(_ model: AppModel, automation: Automation, id: UUID, memory: Bool = false) async throws {
        let edit = try #require(model.beginRoutineDirectSessionEdit(automation))
        try #require(await model.saveRoutineDirectSession(edit, conversationID: id, memoryAccess: memory ? .savedFacts : .none))
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Direct routine did not reach the expected boundary")
        throw AutomationDirectSessionError.unavailable
    }
    private func currentRun(in root: URL, automationID: UUID) throws -> AutomationRun {
        // A second live AutomationService would perform restart recovery and
        // rewrite the active run. Read only this isolated fixture's snapshot.
        struct History: Decodable { let runs: [AutomationRun] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let snapshot = try decoder.decode(History.self, from: Data(contentsOf: root.appending(path: "automations.json")))
        return try #require(snapshot.runs.last { $0.automationID == automationID })
    }
    @Test(arguments: [false, true]) func reviewedRoutineUsesExistingHistoryAndSharedToolsWithIndependentMemoryConsent(memory: Bool) async throws {
        let (root, model, automation, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id, memory: memory)
        await model.runAutomationNow(id: automation.id)
        let run = try #require(model.automationHistory[automation.id]?.first)
        expectNoDifference(run.status, .ok)
        let request = try #require(await probe.shared.first)
        expectNoDifference(request.conversationID, id)
        #expect(request.tools.contains { $0.name == "SendMessage" })
        #expect(request.tools.contains { $0.name == "SendToAgent" })
        expectNoDifference(request.tools.contains { $0.name == "SearchMemory" }, memory)
        let context = request.messages.map(\.text).joined(separator: "\n")
        #expect(context.contains("DIRECT_PERSONA"))
        #expect(context.contains("REVIEWED_HISTORY"))
        #expect(context.contains("DIRECT_ROUTINE_TASK"))
        #expect(context.contains("host-bound background routine wake"))
        #expect(!context.contains("UNRELATED_PRIVATE_HISTORY"))
        expectNoDifference(context.contains("PRIVATE_SAVED_FACT"), memory)
        let plainCount = await probe.plain.count
        expectNoDifference(plainCount, 0)
        let durable = try #require(try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: id))
        let published = try #require(durable.messages.first { $0.id == run.id })
        expectNoDifference(published.text, "SHARED_DIRECT_RESULT")
        #expect(!durable.messages.contains { $0.role == .user && $0.text == automation.prompt })
        #expect(!durable.messages.contains { $0.text.contains("PRIVATE_ASSISTANT_TEXT") })
        #expect(!model.running.contains(id))
        expectNoDifference(run.inputTokens, 8)
        expectNoDifference(run.outputTokens, 3)
    }
    @Test func unreviewedRoutineDoesNotReadAnyConversation() async throws {
        let (root, model, automation, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.runAutomationNow(id: automation.id)
        let sharedCount = await probe.shared.count
        expectNoDifference(sharedCount, 0)
        let request = try #require(await probe.plain.first)
        #expect(!request.messages.map(\.text).joined().contains("REVIEWED_HISTORY"))
        expectNoDifference(model.conversations.first { $0.id == id }?.messages.map(\.text), ["REVIEWED_HISTORY"])
    }
    @Test(arguments: ["definition", "account", "persona", "binding", "busy", "question"])
    func staleOrBusyConsentDoesNotFallBack(change: String) async throws {
        let (root, model, automation, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        switch change {
        case "definition": await model.setAutomationEnabled(id: automation.id, enabled: false)
        case "account": model.settings.accountScope = "other"
        case "persona":
            var agent = try #require(model.agents.first { $0.id == automation.agentID })
            agent.instructions = "NEW_PERSONA"; #expect(await model.updateAgent(agent))
        case "binding":
            let index = try #require(model.conversations.firstIndex { $0.id == id })
            model.conversations[index].agentBinding = .init(accountID: "other", agentID: automation.agentID)
        case "busy": model.running.insert(id)
        default:
            let index = try #require(model.conversations.firstIndex { $0.id == id })
            let question = try AgentQuestion.parse(Data(#"{"prompt":"Choose","options":[{"label":"One"}]}"#.utf8))
            model.conversations[index].messages.append(.init(role: .assistant, text: "Pending question", transcriptCards: [
                .init(lifecycle: .waiting, payload: .widget(.init(title: "Choose", widgetKind: "choice",
                    question: .init(question: question, accountID: "local", memberIDs: []))))
            ]))
        }
        await model.runAutomationNow(id: automation.id)
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .error)
        let plainCount = await probe.plain.count, sharedCount = await probe.shared.count
        expectNoDifference(plainCount, 0)
        expectNoDifference(sharedCount, 0)
    }
    @Test func scheduledRoutineReopensReviewedConsentAndUsesActualRunIdentity() async throws {
        let (root, model, automation, id, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false), probe = RoutineDirectProbe()
        await reopened.registry.register(RoutineDirectProvider(probe: probe))
        await reopened.reloadWorkspaceData()
        reopened.conversations = try await ConversationStore(fileURL: root.appending(path: "conversations.json")).load()
        let due = try #require(reopened.automations.first { $0.id == automation.id }?.nextRunAt)
        await reopened.runAutomationScheduleTick(at: due)
        let run = try #require(reopened.automationHistory[automation.id]?.first)
        expectNoDifference(run.trigger, .schedule)
        expectNoDifference(run.status, .ok)
        #expect(reopened.conversations.first { $0.id == id }?.messages.contains { $0.id == run.id } == true)
        let sharedCount = await probe.shared.count
        expectNoDifference(sharedCount, 1)
    }
    private func seedNudgeActivity(root: URL, model: AppModel, id: UUID) async throws -> (ConversationStore, Date) {
        let activityAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        var chat = try #require(try await store.conversation(id: id))
        _ = try await store.updateReadState(conversationID: id, action: .read,
            at: activityAt.addingTimeInterval(-AutomationSpendGuard.idleInterval), expectedBinding: chat.agentBinding)
        chat.messages += (0..<AutomationSpendGuard.minimumUnreadCount).map { index in
            .init(role: .assistant, text: "UNREAD_FIXTURE_\(index)", createdAt: activityAt)
        }
        try await store.upsert(chat, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: activityAt)
        model.conversations = try await store.load()
        return (store, activityAt.addingTimeInterval(1))
    }
    @Test func scheduledNudgePublishesTheHostCardBeforeOneEphemeralReminderWithoutChangingConsent() async throws {
        let (root, model, automation, id, probe) = try await fixture(activityProbe: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        let bindings = model.automationDirectBindings
        let (store, nudgeAt) = try await seedNudgeActivity(root: root, model: model, id: id)
        await model.runAutomationScheduleTick(at: nudgeAt)
        let first = try #require(await probe.shared.first)
        let wake = try #require(first.messages.last)
        #expect(wake.text.contains("<system_reminder>"))
        #expect(wake.text.contains("Do NOT ask again"))
        let cardsAtInference = await probe.activityCardsAtInference
        expectNoDifference(cardsAtInference, [true])
        expectNoDifference(model.automationDirectBindings, bindings)
        #expect(!first.tools.contains { $0.name == "SearchMemory" })
        let next = try #require(model.automations.first { $0.id == automation.id }?.nextRunAt)
        await model.runAutomationScheduleTick(at: next)
        let requests = await probe.shared
        expectNoDifference(requests.count, 2)
        #expect(!requests[1].messages.map(\.text).joined().contains("<system_reminder>"))
        let durable = try #require(try await store.conversation(id: id))
        #expect(!durable.messages.contains { $0.text.contains("<system_reminder>") || $0.text == automation.prompt })
        expectNoDifference(durable.messages.filter { message in
            message.transcriptCards.contains { card in
                if case .widget(let widget) = card.payload { return widget.automationActivity != nil }
                return false
            }
        }.count, 1)
        expectNoDifference(model.automationHistory[automation.id]?.map(\.status), [.ok, .ok])
    }
    @Test func anAutomaticPauseKeepsTheOriginalNudgeCallbackBoundToItsReviewedDirectSession() async throws {
        let (root, model, automation, id, probe) = try await fixture(activityProbe: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        let bindings = model.automationDirectBindings
        let (_, nudgeAt) = try await seedNudgeActivity(root: root, model: model, id: id)
        await model.runAutomationScheduleTick(at: nudgeAt)
        let nudge = try #require(model.conversationSpendGuardPresentation(id: id))
        #expect(!nudge.prompt.isPaused)
        let pauseAt = nudgeAt.addingTimeInterval(AutomationSpendGuard.pauseDelay)
        await model.runAutomationScheduleTick(at: pauseAt)
        let paused = try #require(model.conversationSpendGuardPresentation(id: id))
        #expect(paused.prompt.isPaused)
        #expect(nudge.bindingLease.isActive)
        expectNoDifference(nudge.prompt.id, paused.prompt.id)
        expectNoDifference(model.automationDirectBindings, bindings)
        let before = await probe.shared
        expectNoDifference(before.count, 1)
        await model.answerConversationSpendGuard(.keep, presentation: nudge, at: pauseAt.addingTimeInterval(1))
        #expect(model.errorMessage == nil)
        let resumed = try #require(model.automations.first { $0.id == automation.id })
        #expect(resumed.enabled && !resumed.guardPaused)
        expectNoDifference(model.automationDirectBindings, bindings)
        expectNoDifference(model.conversationSpendGuardPresentation(id: id) == nil, true)
        await model.runAutomationScheduleTick(at: try #require(resumed.nextRunAt))
        let after = await probe.shared
        expectNoDifference(after.count, 2)
        #expect(!after[1].messages.map(\.text).joined().contains("<system_reminder>"))
    }

    @Test(arguments: [false, true])
    func canonicalActivityReminderDoesNotGrantAnUnreviewedTextOnlyRoutineHistoryOrTools(manual: Bool) async throws {
        let (root, model, automation, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, nudgeAt) = try await seedNudgeActivity(root: root, model: model, id: id)
        // The scheduler executor already exists. A later timezone preference
        // must apply at this admission, not retain its startup timezone.
        model.settings.timeZoneIdentifier = "Pacific/Honolulu"
        if manual { await model.runAutomationNow(id: automation.id) }
        else { await model.runAutomationScheduleTick(at: nudgeAt) }
        let request = try #require(await probe.plain.first), text = request.messages.map(\.text).joined()
        expectNoDifference(text.contains("<system_reminder>"), !manual)
        if !manual { #expect(text.contains("2027-01-17 22:00 HST")) }
        #expect(!text.contains("REVIEWED_HISTORY"))
        #expect(!text.contains("UNREAD_FIXTURE_"))
        #expect(!text.contains("PRIVATE_SAVED_FACT"))
        expectNoDifference(request.tools, [])
        expectNoDifference(model.automationDirectBindings, [])
        let shared = await probe.shared
        expectNoDifference(shared.count, 0)
        let chat = try #require(try await store.conversation(id: id))
        let cards = chat.messages.flatMap(\.transcriptCards).filter { card in
            if case .widget(let widget) = card.payload { return widget.automationActivity != nil }
            return false
        }
        expectNoDifference(cards.count, manual ? 0 : 1)
        #expect(!chat.messages.contains { $0.text.contains("<system_reminder>") })
    }
    @Test(arguments: [SpendGuardAnswer.keep, .resume, .neverAsk])
    func pausedNativeCardRejectsNudgeOnlyChoicesBeforeReviewedConsentResumes(answer: SpendGuardAnswer) async throws {
        let (root, model, automation, id, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        let binding = try #require(model.automationDirectBindings.first { $0.automationID == automation.id })
        // The first fixture scheduler is suspended and no run is active. Seed
        // a saved host pause, then reopen only the isolated test model/store.
        let routines = try AutomationService(storeURL: root.appending(path: "automations.json"))
        try await routines.answerSpendGuard(.pause, agentID: automation.agentID, at: base)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false), probe = RoutineDirectProbe()
        await reopened.registry.register(RoutineDirectProvider(probe: probe))
        await reopened.reloadWorkspaceData()
        reopened.conversations = try await ConversationStore(fileURL: root.appending(path: "conversations.json")).load()
        await reopened.reloadAutomationDetails()
        let prompt = try #require(reopened.automationSpendGuardPrompts.first { $0.agentID == automation.agentID })
        #expect(prompt.isPaused)
        if answer != .resume {
            // A paused native card shows only Resume / Stay paused. Keep and
            // Never ask belong to the nudge stage, not to this callback. Prove
            // rejection does not alter schedules, consent or the outbox bytes,
            // then exercise the actual displayed Resume option below.
            let definitions = reopened.automations
            let storeURL = root.appending(path: "automations.json")
            let bytes = try Data(contentsOf: storeURL)
            await reopened.answerAutomationSpendGuard(answer, prompt: prompt, at: base.addingTimeInterval(119))
            expectNoDifference(reopened.automations, definitions)
            expectNoDifference(reopened.automationDirectBindings, [binding])
            expectNoDifference(try Data(contentsOf: storeURL), bytes)
        }
        await reopened.answerAutomationSpendGuard(.resume, prompt: prompt, at: base.addingTimeInterval(120))
        expectNoDifference(reopened.automationDirectBindings, [binding])
        let resumed = try #require(reopened.automations.first { $0.id == automation.id })
        expectNoDifference(resumed.revision, automation.revision)
        await reopened.runAutomationScheduleTick(at: try #require(resumed.nextRunAt))
        let run = try #require(reopened.automationHistory[automation.id]?.first)
        expectNoDifference(run.status, .ok)
        expectNoDifference(run.trigger, .schedule)
        let plainCount = await probe.plain.count, sharedCount = await probe.shared.count
        expectNoDifference(plainCount, 0)
        expectNoDifference(sharedCount, 1)
        #expect(reopened.conversations.first { $0.id == id }?.messages.contains { $0.id == run.id } == true)
        let savedBindings = try AutomationDirectSessionBindingStore(url: root.appending(path: "automation-direct-sessions.json"))
        let durableBindings = await savedBindings.list()
        expectNoDifference(durableBindings, [binding])
    }
    @Test func questionSuspendsAndBlocksAnotherBackgroundRun() async throws {
        let (root, model, automation, id, probe) = try await fixture(question: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        await model.runAutomationNow(id: automation.id)
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .ok)
        #expect(model.conversations.first { $0.id == id }?.messages.flatMap(\.transcriptCards).contains {
            if case .widget(let widget) = $0.payload { return widget.question?.isPending == true }; return false
        } == true)
        await model.runAutomationNow(id: automation.id)
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .error)
        let sharedCount = await probe.shared.count
        expectNoDifference(sharedCount, 1)
    }
    @Test func revokingConsentCancelsTheActiveRunWithoutPublishing() async throws {
        let gate = RoutineDirectGate()
        let (root, model, automation, id, probe) = try await fixture(gate: gate)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        let work = Task { await model.runAutomationNow(id: automation.id) }
        defer { work.cancel() }
        try await eventually { await gate.started }
        let grant = try #require(model.automationDirectBindings.first)
        await model.revokeRoutineDirectSession(grant)
        await gate.release()
        await work.value
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .cancelled)
        #expect(!model.conversations.first { $0.id == id }!.messages.contains { $0.text == "SHARED_DIRECT_RESULT" })
        #expect(!model.running.contains(id))
        let sharedCount = await probe.shared.count
        expectNoDifference(sharedCount, 1)
    }

    @Test(arguments: ["answer", "revoked", "account", "invalid"])
    func routineQuestionIsAnsweredOnlyByAnActualScopedHumanTurn(mode: String) async throws {
        let (root, model, automation, id, probe) = try await fixture(question: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        await model.runAutomationNow(id: automation.id)
        let row = try #require(model.conversations.first { $0.id == id }?.messages.first { $0.transcriptCards.contains { $0.directQuestion != nil } })
        let card = try #require(row.transcriptCards.first { $0.directQuestion != nil })
        #expect(model.canAnswerDirectQuestion(conversationID: id, messageID: row.id, cardID: card.id))
        if mode == "revoked" { await model.revokeRoutineDirectSession(try #require(model.automationDirectBindings.first)) }
        if mode == "account" { model.settings.accountScope = "other" }
        await model.directQuestionAnswered(conversationID: id, messageID: row.id, cardID: card.id, answer: .option(mode == "invalid" ? 99 : 0))
        try await eventually { !model.running.contains(id) }
        let durable = try #require(try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: id))
        let question = try #require(durable.messages.first { $0.id == row.id }?.transcriptCards.first { $0.id == card.id }?.directQuestion)
        let allowed = mode == "answer" || mode == "revoked"
        expectNoDifference(question.isPending, !allowed)
        let requests = await probe.shared
        expectNoDifference(requests.count, allowed ? 2 : 1)
        if allowed {
            let human = try #require(durable.messages.first { $0.id == question.responseMessageID })
            expectNoDifference(human.role, .user)
            expectNoDifference(human.text, "Inspect only")
            expectNoDifference(human.replyToMessageID, row.id)
            expectNoDifference(durable.messages.last?.text, "SHARED_DIRECT_RESULT")
            #expect(!requests.last!.messages.contains { $0.role == .system && $0.text.contains("host-bound background routine wake") })
        }
    }

    @Test(arguments: [false, true])
    func peerDispatchNeedsRealApprovalAndCannotBorrowBackgroundMemory(allow: Bool) async throws {
        let (root, model, automation, id, probe) = try await fixture(peer: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try #require(model.agents.first { $0.name == "Peer" })
        await model.registry.register(RoutineDirectProvider(probe: probe, peerID: peer.id))
        try await approve(model, automation: automation, id: id, memory: true)
        await model.setAutoReviewEnabled(true)
        let work = Task { await model.runAutomationNow(id: automation.id) }
        defer { work.cancel() }
        try await eventually { model.pendingAutoReviewApprovals.contains { $0.action.context.metadata["tool"] == "SendToAgent" } }
        let approval = try #require(model.pendingAutoReviewApprovals.first { $0.action.context.metadata["tool"] == "SendToAgent" })
        expectNoDifference(approval.action.target, .recipient(identifier: peer.id.uuidString))
        expectNoDifference(approval.action.context.conversationID, id)
        let runID = try currentRun(in: root, automationID: automation.id).id
        expectNoDifference(approval.fence.runID, runID)
        #expect(model.agentMessages.isEmpty)
        model.handleTranscriptCardIntent(allow ? .approveReview(reviewID: approval.id) : .rejectReview(reviewID: approval.id))
        await work.value
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .ok)
        expectNoDifference(model.conversations.first { $0.id == id }?.messages.flatMap(\.toolActivities)
            .first { $0.name == "SendToAgent" }?.status, allow ? .succeeded : .failed)
        let requests = await probe.shared
        let peerRequests = requests.filter { $0.messages.first?.text.contains("PEER_PERSONA") == true }
        expectNoDifference(peerRequests.count, allow ? 1 : 0)
        for request in peerRequests {
            let context = request.messages.map(\.text).joined(separator: "\n")
            #expect(!request.tools.contains { $0.name == "SearchMemory" })
            #expect(!context.contains("PRIVATE_SAVED_FACT"))
            #expect(!context.contains("PRIVATE_PEER_FACT"))
            #expect(!context.contains("REVIEWED_HISTORY"))
            #expect(context.contains("Review only the explicitly delivered fixture task."))
        }
        expectNoDifference(model.agentMessages.contains { $0.recipientID == peer.id }, allow)
        #expect(!model.running.contains(id))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func reviewedSessionCannotDowngradeToPlainAssistantOutput() async throws {
        let (root, model, automation, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        await model.registry.register(RoutineDirectProvider(supportsTools: false, probe: probe))
        await model.runAutomationNow(id: automation.id)
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .error)
        let plain = await probe.plain, shared = await probe.shared
        #expect(plain.isEmpty)
        #expect(shared.isEmpty)
        #expect(!model.conversations.first { $0.id == id }!.messages.contains { $0.text == "LEGACY_DIRECT" })
        #expect(!model.running.contains(id))
    }

    @Test(arguments: ["definition", "account", "persona", "model", "projectedModel", "deleted"])
    func changingTheReviewedSessionWhileTheSheetIsOpenCannotArmIt(change: String) async throws {
        let (root, model, automation, id, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let edit = try #require(model.beginRoutineDirectSessionEdit(automation))
        var restoreProjection: Task<Void, Never>?
        switch change {
        case "definition": await model.setAutomationEnabled(id: automation.id, enabled: false)
        case "account": await model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "persona":
            var profile = try #require(model.agents.first { $0.id == automation.agentID })
            profile.instructions = "Changed after review"; #expect(await model.updateAgent(profile))
        case "model", "projectedModel":
            var conversation = try #require(model.conversations.first { $0.id == id })
            conversation.reasoningEffort = .high
            if change == "model" {
                try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(
                    conversation, replacingLoadedMessageIDs: [], historyComplete: true)
            } else {
                let index = try #require(model.conversations.firstIndex { $0.id == id })
                let originalProjection = model.conversations
                model.conversations[index] = conversation
                // A queued canonical snapshot can restore the old projection
                // at the first admission await. It must not hide this mismatch.
                restoreProjection = Task { @MainActor in model.conversations = originalProjection }
            }
        default: model.deleteConversation(id: id)
        }
        #expect(await model.saveRoutineDirectSession(edit, conversationID: id, memoryAccess: .savedFacts) == false)
        await restoreProjection?.value
        #expect(model.automationDirectBindings.isEmpty)
        let saved = try AutomationDirectSessionBindingStore(url: root.appending(path: "automation-direct-sessions.json"))
        let bindings = await saved.list()
        #expect(bindings.isEmpty)
    }

    @Test func groupAndSoloConsentCannotSilentlyReplaceEachOther() async throws {
        let (root, model, automation, id, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await model.createGroup(name: "Fixture group", summary: "Explicit audience", memberIDs: [automation.agentID]))
        let group = try #require(model.groups.first)
        let groupEdit = try #require(model.beginRoutineGroupSessionEdit(automation))
        try await approve(model, automation: automation, id: id)
        #expect(await model.saveRoutineGroupSession(groupEdit, groupID: group.id, memoryAccess: .savedFacts) == false)
        #expect(model.automationGroupBindings.isEmpty)
        await model.revokeRoutineDirectSession(try #require(model.automationDirectBindings.first))
        #expect(await model.saveRoutineGroupSession(groupEdit, groupID: group.id, memoryAccess: .none))
        let directEdit = try #require(model.beginRoutineDirectSessionEdit(automation))
        #expect(await model.saveRoutineDirectSession(directEdit, conversationID: id, memoryAccess: .savedFacts) == false)
        #expect(model.automationDirectBindings.isEmpty)
        expectNoDifference(model.automationGroupBindings.first?.groupID, group.id)
    }

    @Test func backgroundHistoryDoesNotImplicitlyReadOrForwardOldAttachments() async throws {
        let (root, model, automation, id, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var conversation = try #require(model.conversations.first { $0.id == id })
        let image = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "private-not-imported.png",
            mimeType: "image/png", byteCount: 100, kind: .image, createdAt: Date(timeIntervalSince1970: 1_000))
        conversation.messages[0].attachments = [image]
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(
            conversation, replacingLoadedMessageIDs: [], historyComplete: true)
        let index = try #require(model.conversations.firstIndex { $0.id == id })
        model.conversations[index] = conversation
        try await approve(model, automation: automation, id: id)
        await model.runAutomationNow(id: automation.id)
        expectNoDifference(model.automationHistory[automation.id]?.first?.status, .ok)
        let request = try #require(await probe.shared.first)
        #expect(request.attachmentsByMessageID.isEmpty)
        #expect(request.messages.allSatisfy { $0.attachments.isEmpty && $0.remoteAttachment == nil && $0.remoteImages == nil })
        #expect(!request.messages.map(\.text).joined().contains(image.filename))
        let saved = try #require(try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: id))
        expectNoDifference(saved.messages.first?.attachments, [image])
    }

    @Test func silenceLeavesOnlyActualRunEvidenceAndNoPrivateText() async throws {
        let (root, model, automation, id, _) = try await fixture(silent: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        await model.runAutomationNow(id: automation.id)
        let run = try #require(model.automationHistory[automation.id]?.first)
        expectNoDifference(run.status, .ok)
        let row = try #require(model.conversations.first { $0.id == id }?.messages.first { $0.id == run.id })
        expectNoDifference(row.text, "")
        expectNoDifference(row.deliveryStatus, .succeeded)
        #expect(row.transcriptCards.contains { $0.id == run.id && $0.lifecycle == .succeeded })
        #expect(!model.running.contains(id))
    }

    @Test(arguments: [false, true]) func writeRetainsBothRealApprovalBoundaries(allow: Bool) async throws {
        let (root, model, automation, id, _) = try await fixture(write: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        await model.setAutoReviewEnabled(true)
        let work = Task { await model.runAutomationNow(id: automation.id) }
        defer { work.cancel() }
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty }
        let review = try #require(model.pendingAutoReviewApprovals.first)
        expectNoDifference(review.action.context.conversationID, id)
        let actual = try currentRun(in: root, automationID: automation.id)
        expectNoDifference(review.fence.runID, actual.id)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "routine-created.txt").path))
        model.handleTranscriptCardIntent(.approveReview(reviewID: review.id))
        try await eventually { !model.pendingToolApprovals.isEmpty }
        let local = try #require(model.pendingToolApprovals.first)
        expectNoDifference(local.conversationID, id)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "routine-created.txt").path))
        model.resolveLocalToolApproval(id: local.id, allowed: allow)
        await work.value
        expectNoDifference(FileManager.default.fileExists(atPath: root.appending(path: "routine-created.txt").path), allow)
        if allow { expectNoDifference(try String(contentsOf: root.appending(path: "routine-created.txt"), encoding: .utf8), "APPROVED_DIRECT_WRITE") }
        expectNoDifference(model.conversations.first { $0.id == id }?.messages.flatMap(\.toolActivities).first { $0.name == "local__write_file" }?.status, allow ? .succeeded : .failed)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.pendingToolApprovals.isEmpty)
    }

    @Test(arguments: ["revoke", "account", "definition", "delete", "persona"])
    func staleLocalApprovalCannotWriteAfterRevocation(change: String) async throws {
        let (root, model, automation, id, _) = try await fixture(write: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await approve(model, automation: automation, id: id)
        await model.setAutoReviewEnabled(true)
        let work = Task { await model.runAutomationNow(id: automation.id) }
        defer { work.cancel() }
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty }
        model.handleTranscriptCardIntent(.approveReview(reviewID: try #require(model.pendingAutoReviewApprovals.first).id))
        try await eventually { !model.pendingToolApprovals.isEmpty }
        let pending = try #require(model.pendingToolApprovals.first)
        switch change {
        case "account": await model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "definition": await model.setAutomationEnabled(id: automation.id, enabled: false)
        case "delete": model.deleteConversation(id: id)
        case "persona":
            var profile = try #require(model.agents.first { $0.id == automation.agentID })
            profile.instructions = "New persona"; #expect(await model.updateAgent(profile))
        default: await model.revokeRoutineDirectSession(try #require(model.automationDirectBindings.first))
        }
        model.resolveLocalToolApproval(id: pending.id, allowed: true)
        await work.value
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "routine-created.txt").path))
        #expect(!model.running.contains(id))
        #expect(model.pendingToolApprovals.isEmpty && model.pendingAutoReviewApprovals.isEmpty)
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let actual = await service.history(automationID: automation.id).first
        expectNoDifference(actual?.status, .cancelled)
    }
}
