import CustomDump
import Foundation
import Testing
import FiliconAutomations
import FiliconDomain

private struct SpendGuardExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Isolated fixture; no model, network or account")
    }
}

private actor SpendGuardGate: AutomationExecutor {
    private var pending: CheckedContinuation<AutomationExecutionResult, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await withCheckedContinuation { continuation in
            pending = continuation
            for observer in observers { observer.resume() }; observers.removeAll()
        }
    }
    func waitForEntry() async { if pending == nil { await withCheckedContinuation { observers.append($0) } } }
    func finish() { pending?.resume(returning: .init(detail: "Fixture finished")); pending = nil }
}

private actor SpendGuardBatchExecutor: AutomationExecutor {
    private let gate = SpendGuardGate()
    private var entered = false
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        if !entered {
            entered = true
            return try await gate.execute(automation: automation, prompt: prompt, events: events)
        }
        return .init(detail: "Later isolated fixture run")
    }
    func waitForEntry() async { await gate.waitForEntry() }
    func finish() async { await gate.finish() }
}

private actor SpendGuardReviewedGroupExecutor: AutomationRunExecutor {
    let bindings: [UUID: UUID]
    let lifetime: AutomationSpendGuardLifetime
    let blocksFirst: Bool
    private let gate = SpendGuardGate()
    private var requests: [AutomationRunRequest] = []
    init(bindings: [UUID: UUID], lifetime: AutomationSpendGuardLifetime = .init(), blocksFirst: Bool = false) {
        self.bindings = bindings; self.lifetime = lifetime; self.blocksFirst = blocksFirst
    }
    func spendGuardContext(for automation: Automation) async throws -> AutomationSpendGuardContext {
        .init(reviewedGroupBindingID: bindings[automation.id], lifetime: lifetime)
    }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Isolated fixture")
    }
    func execute(_ request: AutomationRunRequest) async throws -> AutomationExecutionResult {
        requests.append(request)
        if blocksFirst && requests.count == 1 {
            return try await gate.execute(automation: request.automation, prompt: request.prompt, events: request.events)
        }
        return .init(detail: "Isolated reviewed group fixture")
    }
    func observed() -> [AutomationRunRequest] { requests }
    func waitForEntry() async { await gate.waitForEntry() }
    func finish() async { await gate.finish() }
}

private struct SpendGuardStoreFixture: Encodable {
    var schemaVersion: Int
    var automations: [Automation]
    var runs: [AutomationRun] = []
    var wakes: [AutomationWake] = []
    var claims: Set<String> = []
    var eventClaims: Set<String> = []
    var spendGuard: AutomationSpendGuardState?
    var spendGuards: [UUID: AutomationSpendGuardState]?
}

@Suite("Automation spend guard parity", .timeLimit(.minutes(1)))
struct AutomationSpendGuardParityTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let peer = UUID(uuidString: "00000000-0000-0000-0000-000000000084")!
    private var nudgeAt: Date { now.addingTimeInterval(AutomationSpendGuard.idleInterval + 1) }
    private var pauseAt: Date { nudgeAt.addingTimeInterval(AutomationSpendGuard.pauseDelay) }

    private func fixture() async throws -> (URL, AutomationService, Automation, Automation) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-spend-guard-\(UUID())")
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let enabled = try await service.save(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000082")!,
            agentID: owner, name: "Enabled fixture", prompt: "No inference",
            trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), createdAt: now), now: now)
        let disabled = try await service.save(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000083")!,
            agentID: owner, name: "User disabled fixture", prompt: "No inference",
            trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), enabled: false, createdAt: now), now: now)
        return (root, service, enabled, disabled)
    }
    private func addPeer(to service: AutomationService) async throws -> Automation {
        try await service.save(.init(id: peer, agentID: peer, name: "Other owner", prompt: "No inference",
            trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), createdAt: now.addingTimeInterval(1)), now: now)
    }
    private func nudge(_ service: AutomationService, routine: Automation) async throws {
        for index in 1...AutomationSpendGuard.minimumFiresSinceViewed {
            _ = try await service.runNow(id: routine.id, executor: SpendGuardExecutor(), now: now.addingTimeInterval(Double(index)))
        }
        let decision = try await service.evaluateSpendGuard(agentID: routine.agentID, at: nudgeAt)
        expectNoDifference(decision, .nudge)
    }
    private func write(_ fixture: SpendGuardStoreFixture, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(fixture).write(to: file)
    }

    @Test func reviewedGroupHistoryDoesNotCauseAnIndividualRoutineToBeNudged() async throws {
        let (root, service, individual, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let group = try await service.save(.init(agentID: owner, name: "Reviewed group fixture", prompt: "Fixture",
            trigger: individual.trigger, createdAt: now.addingTimeInterval(1)), now: now)
        let executor = SpendGuardReviewedGroupExecutor(bindings: [group.id: group.id])
        for index in 1...40 { _ = try await service.runNow(id: group.id, executor: executor, now: now.addingTimeInterval(Double(index))) }
        try await service.reconcileSpendGuardContexts(executor: executor)
        let history = await service.history(automationID: group.id), wakes = await service.pendingWakes()
        expectNoDifference(history.count, AutomationService.maximumHistory)
        expectNoDifference(wakes.count, 40)
        #expect(wakes.allSatisfy { $0.automationID == group.id })
        let spend = await service.spendGuardState(agentID: owner)
        expectNoDifference(spend.firesSinceViewed, 0)
        expectNoDifference(spend.unreadCount, 0)
        let decision = try await service.evaluateSpendGuard(agentID: owner, at: nudgeAt)
        expectNoDifference(decision, .belowThresholds)
        let definitions = await service.list()
        #expect(definitions.filter(\.enabled).count == 2)
        expectNoDifference(spend.cardID, nil)
    }

    @Test func aTextOnlyExecutorCannotClaimAGroupSessionExemption() async throws {
        let (root, service, individual, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        struct NoSession: AutomationExecutor {
            func spendGuardContext(for automation: Automation) async throws -> AutomationSpendGuardContext {
                .init(reviewedGroupBindingID: automation.id)
            }
            func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
                Issue.record("A group exemption must not route to a text-only executor")
                return .init(detail: "Must not execute")
            }
        }
        let runs = await service.fireDue(at: now.addingTimeInterval(3_600), executor: NoSession())
        let history = await service.history(automationID: individual.id)
        expectNoDifference(runs, []); expectNoDifference(history, [])
    }

    @Test func anExpiredIndividualNudgeDoesNotPauseItsOwnersReviewedGroupRoutine() async throws {
        let (root, service, individual, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let group = try await service.save(.init(agentID: owner, name: "Reviewed group fixture", prompt: "Fixture",
            trigger: individual.trigger, createdAt: now.addingTimeInterval(1)), now: now)
        try await nudge(service, routine: individual)
        let executor = SpendGuardReviewedGroupExecutor(bindings: [group.id: group.id])
        let runs = await service.fireDue(at: pauseAt, executor: executor)
        expectNoDifference(runs.map(\.automationID), [group.id])
        expectNoDifference(runs.first?.status, .ok)
        let spend = await service.spendGuardState(agentID: owner), definitions = await service.list()
        expectNoDifference(spend.guardPausedAutomationIDs, [individual.id])
        #expect(definitions.first { $0.id == group.id }?.enabled == true)
        #expect(definitions.first { $0.id == group.id }?.guardPaused == false)
        let requests = await executor.observed()
        expectNoDifference(requests.first?.reviewedGroupBindingID, group.id)
        expectNoDifference(requests.first?.run.id, runs.first?.id)
    }

    @Test func aRevokedClassificationCannotRouteAnOldEventBatchToAReplacementGroup() async throws {
        let (root, service, original, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000086")!
        var first = original; first.trigger = .event(.init(connectorID: connector, kind: "fixture"))
        first = try await service.save(first, now: now)
        let group = try await service.save(.init(agentID: peer, name: "Reviewed group fixture", prompt: "Fixture",
            trigger: first.trigger, createdAt: now.addingTimeInterval(1)), now: now)
        let lifetime = AutomationSpendGuardLifetime()
        let executor = SpendGuardReviewedGroupExecutor(bindings: [group.id: group.id], lifetime: lifetime, blocksFirst: true)
        let oldEvent = AutomationEvent(connectorID: connector, kind: "fixture", externalEventID: "before-revoke",
            payloadJSON: Data(#"{"group":true,"spend_guard_exempt":true}"#.utf8), occurredAt: now)
        let batch = Task { await service.fire(events: [oldEvent], executor: executor, now: now.addingTimeInterval(1)) }
        await executor.waitForEntry()
        lifetime.cancel()
        await executor.finish()
        let oldRuns = await batch.value, oldRequests = await executor.observed()
        expectNoDifference(oldRuns.map(\.automationID), [first.id])
        expectNoDifference(oldRequests.map(\.automation.id), [first.id])
        let replacementID = UUID(uuidString: "00000000-0000-0000-0000-000000000087")!
        let replacement = SpendGuardReviewedGroupExecutor(bindings: [group.id: replacementID])
        let freshEvent = AutomationEvent(connectorID: connector, kind: "fixture", externalEventID: "after-revoke",
            payloadJSON: Data("{}".utf8), occurredAt: now.addingTimeInterval(2))
        let fresh = await service.fire(events: [freshEvent], executor: replacement, now: now.addingTimeInterval(2))
        expectNoDifference(Set(fresh.map(\.automationID)), [first.id, group.id])
        let replacementRequests = await replacement.observed()
        expectNoDifference(replacementRequests.first { $0.automation.id == group.id }?.reviewedGroupBindingID, replacementID)
    }

    @Test(arguments: [SpendGuardAnswer.keep, .resume, .neverAsk])
    func continuingAnswersResumeOnlyGuardPausedRoutinesAndSetTheOriginalSnooze(answer: SpendGuardAnswer) async throws {
        let (root, service, enabled, disabled) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let resumeAt = now.addingTimeInterval(120)
        try await service.answerSpendGuard(answer, agentID: owner, at: resumeAt)
        let definitions = await service.list(), guardState = await service.spendGuardState(agentID: owner)
        var expected = enabled; expected.nextRunAt = resumeAt.addingTimeInterval(3_600)
        expectNoDifference(definitions, [expected, disabled])
        expectNoDifference(guardState.guardPausedAutomationIDs, [])
        expectNoDifference(guardState.nudgedAt, nil)
        expectNoDifference(guardState.cardID, nil)
        expectNoDifference(guardState.optedOut, answer == .neverAsk)
        expectNoDifference(guardState.snoozedUntil,
            answer == .neverAsk ? nil : resumeAt.addingTimeInterval(AutomationSpendGuard.snoozeInterval))
        let restored = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let durable = await restored.list(), durableGuard = await restored.spendGuardState(agentID: owner)
        expectNoDifference(durable, definitions); expectNoDifference(durableGuard, guardState)
        let catchUp = await restored.fireDue(at: resumeAt, executor: SpendGuardExecutor())
        expectNoDifference(catchUp, [])
    }

    @Test func stayingPausedRetiresGuardOwnershipWithoutRearming() async throws {
        let (root, service, enabled, disabled) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        try await service.answerSpendGuard(.stayPaused, agentID: owner, at: now.addingTimeInterval(120))
        let definitions = await service.list(), guardState = await service.spendGuardState(agentID: owner)
        var expected = enabled; expected.enabled = false; expected.nextRunAt = nil
        expectNoDifference(definitions, [expected, disabled])
        expectNoDifference(guardState.guardPausedAutomationIDs, [])
        expectNoDifference(guardState.cardID, nil)
        let history = await service.history(automationID: enabled.id)
        expectNoDifference(history, [])
    }

    @Test func oneOwnersPauseAndOptOutCannotAffectAnotherOwnerOrFutureOwners() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try await addPeer(to: service), beforePeer = await service.spendGuardState(agentID: peer)
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let paused = await service.list(), spend = await service.spendGuardState(agentID: owner)
        expectNoDifference(paused.first { $0.id == other.id }, other)
        expectNoDifference(spend.guardPausedAutomationIDs, [enabled.id])
        try await service.answerSpendGuard(.neverAsk, agentID: owner, cardID: spend.cardID, at: now.addingTimeInterval(1))
        let afterPeer = await service.spendGuardState(agentID: peer)
        expectNoDifference(afterPeer, beforePeer)
        let future = UUID(uuidString: "00000000-0000-0000-0000-000000000085")!
        _ = try await service.save(.init(agentID: future, name: "New owner", prompt: "Fixture",
            trigger: enabled.trigger, createdAt: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
        let futureState = await service.spendGuardState(agentID: future)
        expectNoDifference(futureState, .init(lastViewedAt: now.addingTimeInterval(2)))
    }

    @Test func viewingOneOwnerKeepsBothUnansweredCardsAndOtherOwnersCounters() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try await addPeer(to: service)
        try await nudge(service, routine: enabled); try await nudge(service, routine: other)
        let before = await service.spendGuardState(agentID: owner), peerBefore = await service.spendGuardState(agentID: peer)
        try await service.recordViewed(agentID: owner, at: nudgeAt.addingTimeInterval(1))
        var expected = before; expected.lastViewedAt = nudgeAt.addingTimeInterval(1); expected.firesSinceViewed = 0; expected.unreadCount = 0
        let after = await service.spendGuardState(agentID: owner), peerAfter = await service.spendGuardState(agentID: peer)
        expectNoDifference(after, expected); expectNoDifference(peerAfter, peerBefore)
        let restored = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let durable = await restored.spendGuardStates()
        expectNoDifference(durable, [owner: expected, peer: peerBefore])
        try await restored.answerSpendGuard(.keep, agentID: owner, cardID: before.cardID, at: nudgeAt.addingTimeInterval(2))
        let answered = await restored.spendGuardState(agentID: owner)
        expectNoDifference(answered.cardID, nil)
    }

    @Test func aDelayedViewReceiptCannotMoveTheOwnersReadTimeBackwards() async throws {
        let (root, service, routine, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await nudge(service, routine: routine)
        try await service.recordViewed(agentID: owner, at: nudgeAt.addingTimeInterval(60))
        let current = await service.spendGuardState(agentID: owner)
        try await service.recordViewed(agentID: owner, at: now)
        try await service.recordViewed(agentID: owner, at: current.lastViewedAt)
        let after = await service.spendGuardState(agentID: owner)
        expectNoDifference(after, current)
        let reopened = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let durable = await reopened.spendGuardState(agentID: owner)
        expectNoDifference(durable, current)
    }

    @Test func aRejectedViewCommitCannotPublishOrPersistReadCounters() async throws {
        let (root, service, routine, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await nudge(service, routine: routine)
        let before = await service.spendGuardStates(), definitions = await service.list()
        await #expect(throws: CancellationError.self) {
            try await service.recordViewed(agentID: owner, at: nudgeAt.addingTimeInterval(60),
                commit: { _ in throw CancellationError() })
        }
        let after = await service.spendGuardStates(), afterDefinitions = await service.list()
        expectNoDifference(after, before); expectNoDifference(afterDefinitions, definitions)
        let reopened = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let durable = await reopened.spendGuardStates()
        expectNoDifference(durable, before)
    }

    @Test func staleWrongOwnerAndReplayedCardsCannotMutateState() async throws {
        let (root, service, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await addPeer(to: service)
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let card = try #require(await service.spendGuardState(agentID: owner).cardID)
        let definitions = await service.list(), spends = await service.spendGuardStates()
        for (agent, id) in [(peer, card), (owner, UUID(uuidString: "00000000-0000-0000-0000-000000000086")!)] {
            await #expect(throws: SpendGuardError.staleCard) {
                try await service.answerSpendGuard(.resume, agentID: agent, cardID: id, at: now)
            }
        }
        let after = await service.list(), afterSpends = await service.spendGuardStates()
        expectNoDifference(after, definitions); expectNoDifference(afterSpends, spends)
        try await service.answerSpendGuard(.resume, agentID: owner, cardID: card, at: now)
        let resumed = await service.list(), resumedSpend = await service.spendGuardStates()
        await #expect(throws: SpendGuardError.staleCard) {
            try await service.answerSpendGuard(.pause, agentID: owner, cardID: card, at: now)
        }
        let replay = await service.list(), replaySpend = await service.spendGuardStates()
        expectNoDifference(replay, resumed); expectNoDifference(replaySpend, resumedSpend)
    }

    @Test func explicitUserDisableRemovesGuardOwnershipAndIsNotRevived() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let card = try #require(await service.spendGuardState(agentID: owner).cardID)
        try await service.setEnabled(id: enabled.id, enabled: false, now: now.addingTimeInterval(1))
        let disabled = await service.list(), spend = await service.spendGuardState(agentID: owner)
        expectNoDifference(spend.guardPausedAutomationIDs, [])
        try await service.answerSpendGuard(.resume, agentID: owner, cardID: card, at: now.addingTimeInterval(2))
        let after = await service.list(); expectNoDifference(after, disabled)
        #expect(after.allSatisfy { !$0.enabled && !$0.guardPaused && $0.nextRunAt == nil })
    }

    @Test func agentProtectionIsOwnerScopedAndCannotBeBypassedByANewRoutineID() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await addPeer(to: service)
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let ownerDraft = Automation(agentID: owner, name: "Bypass", prompt: "Fixture", trigger: enabled.trigger, createdAt: now)
        await #expect(throws: AutomationStateChangeError.protectedDefinition) {
            _ = try await service.applyStateChange(.init(operation: .create, automation: ownerDraft), lifetime: .init(), now: now)
        }
        let peerDraft = Automation(agentID: peer, name: "Independent", prompt: "Fixture", trigger: enabled.trigger, createdAt: now)
        let saved = try await service.applyStateChange(.init(operation: .create, automation: peerDraft), lifetime: .init(), now: now)
        #expect(saved.enabled && saved.nextRunAt == now.addingTimeInterval(3_600))
        let ownerState = await service.spendGuardState(agentID: owner)
        expectNoDifference(ownerState.guardPausedAutomationIDs, [enabled.id])
    }

    @Test func failedScheduleCalculationCannotPartiallyResumeEarlierRoutines() async throws {
        let (root, _, enabled, disabled) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var paused = enabled; paused.enabled = false; paused.guardPaused = true; paused.nextRunAt = nil
        let invalid = Automation(id: peer, agentID: owner, name: "Invalid stored schedule", prompt: "Fixture",
            trigger: .cron(expression: "@hourly", timeZoneIdentifier: "Not/A_Zone"), enabled: false, createdAt: now, guardPaused: true)
        let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000090")!
        let spend = AutomationSpendGuardState(lastViewedAt: now, guardPausedAutomationIDs: [paused.id, invalid.id], cardID: cardID)
        let file = root.appending(path: "automations.json")
        try write(.init(schemaVersion: 2, automations: [paused, disabled, invalid], spendGuards: [owner: spend]), to: file)
        let service = try AutomationService(storeURL: file), definitions = await service.list()
        let bytes = try Data(contentsOf: file)
        await #expect(throws: ScheduleError.invalidTimeZone("Not/A_Zone")) {
            try await service.answerSpendGuard(.resume, agentID: owner, cardID: cardID, at: now)
        }
        let after = await service.list(), guardAfter = await service.spendGuardState(agentID: owner)
        expectNoDifference(after, definitions); expectNoDifference(guardAfter, spend)
        expectNoDifference(try Data(contentsOf: file), bytes)
    }

    @Test(arguments: ["pause", "resume", "view", "nudge"])
    func failedPersistenceCannotPublishPartialGuardOrDefinitionChanges(operation: String) async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await addPeer(to: service)
        if operation == "resume" || operation == "view" { try await service.answerSpendGuard(.pause, agentID: owner, at: now) }
        if operation == "nudge" {
            for index in 1...20 { _ = try await service.runNow(id: enabled.id, executor: SpendGuardExecutor(), now: now.addingTimeInterval(Double(index))) }
        }
        let before = await service.list(), spends = await service.spendGuardStates()
        let file = root.appending(path: "automations.json"), backup = root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            switch operation {
            case "view": try await service.recordViewed(agentID: owner, at: nudgeAt)
            case "nudge": _ = try await service.evaluateSpendGuard(agentID: owner, at: nudgeAt)
            default: try await service.answerSpendGuard(operation == "resume" ? .resume : .pause, agentID: owner, at: now)
            }
        }
        let after = await service.list(), afterSpends = await service.spendGuardStates()
        expectNoDifference(after, before); expectNoDifference(afterSpends, spends)
        // Restore the fixture, not user data, and prove the failed action is retryable.
        try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
        if operation == "nudge" {
            let decision = try await service.evaluateSpendGuard(agentID: owner, at: nudgeAt)
            expectNoDifference(decision, .nudge)
        }
        else if operation == "view" { try await service.recordViewed(agentID: owner, at: nudgeAt) }
        else { try await service.answerSpendGuard(operation == "resume" ? .resume : .pause, agentID: owner, at: now) }
    }

    @Test(arguments: [false, true])
    func revokedLifetimeCannotAnswerOrMarkRead(view: Bool) async throws {
        let (root, service, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let before = await service.list(), spends = await service.spendGuardStates()
        let lifetime = AutomationSpendGuardLifetime(); lifetime.cancel()
        await #expect(throws: CancellationError.self) {
            if view { try await service.recordViewed(agentID: owner, at: nudgeAt, lifetime: lifetime) }
            else { try await service.answerSpendGuard(.resume, agentID: owner, at: now, lifetime: lifetime) }
        }
        let after = await service.list(), afterSpends = await service.spendGuardStates()
        expectNoDifference(after, before); expectNoDifference(afterSpends, spends)
    }

    @Test func aChatLeaseIsCheckedAtTheFinalAnswerCommitNotOnlyAtPresentation() async throws {
        let (root, service, _, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let card = try #require(await service.spendGuardState(agentID: owner).cardID)
        let definitions = await service.list(), spends = await service.spendGuardStates()
        let file = root.appending(path: "automations.json"), bytes = try Data(contentsOf: file)
        let lease = ConversationBindingLease(conversationID: owner, binding: .init(accountID: "local", agentID: owner))
        await #expect(throws: CancellationError.self) {
            try await service.answerSpendGuard(.resume, agentID: owner, cardID: card, at: now,
                expectedPaused: true, commit: { operation in
                    // A native lifecycle revokes after presentation/preflight
                    // but before the service actor's final synchronous write.
                    lease.close()
                    try lease.withValidBinding(operation)
                })
        }
        let after = await service.list(), afterSpends = await service.spendGuardStates()
        expectNoDifference(after, definitions); expectNoDifference(afterSpends, spends)
        expectNoDifference(try Data(contentsOf: file), bytes)
    }

    @Test(arguments: [false, true])
    func anAnswerForTheWrongCardStageCannotCommitEvenWhenTheIDIsUnchanged(paused: Bool) async throws {
        let (root, service, routine, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        if paused { try await service.answerSpendGuard(.pause, agentID: owner, at: now) }
        else { try await nudge(service, routine: routine) }
        let card = try #require(await service.spendGuardState(agentID: owner).cardID)
        let definitions = await service.list(), spends = await service.spendGuardStates()
        await #expect(throws: SpendGuardError.staleCard) {
            try await service.answerSpendGuard(paused ? .keep : .resume, agentID: owner, cardID: card, at: nudgeAt,
                expectedPaused: !paused)
        }
        let after = await service.list(), afterSpends = await service.spendGuardStates()
        expectNoDifference(after, definitions); expectNoDifference(afterSpends, spends)
    }

    @Test(arguments: ["schedule", "event", "scheduler"])
    func elapsedNudgeStopsBackgroundWorkBeforeAdmissionButNotOtherOwners(origin: String) async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000087")!
        _ = try await service.save(.init(agentID: owner, name: "Event fixture", prompt: "Fixture",
            trigger: .event(.init(connectorID: connector, kind: "fixture")), createdAt: now), now: now)
        let other = try await addPeer(to: service)
        try await nudge(service, routine: enabled)
        let previousHistory = await service.history(automationID: enabled.id)
        let results: [AutomationRun]
        if origin == "event" {
            results = await service.fire(events: [.init(connectorID: connector, kind: "fixture", externalEventID: "event-1",
                payloadJSON: Data("{}".utf8), occurredAt: pauseAt)], executor: SpendGuardExecutor(), now: pauseAt)
        } else if origin == "scheduler" {
            results = await AutomationScheduler(service: service, executor: SpendGuardExecutor()).runOnce(at: pauseAt)
        } else { results = await service.fireDue(at: pauseAt, executor: SpendGuardExecutor()) }
        expectNoDifference(results.map(\.automationID), origin == "event" ? [] : [other.id])
        let afterHistory = await service.history(automationID: enabled.id), definitions = await service.list(agentID: owner)
        expectNoDifference(afterHistory, previousHistory)
        #expect(definitions.allSatisfy { !$0.enabled && $0.nextRunAt == nil })
        let guardState = await service.spendGuardState(agentID: owner)
        #expect(guardState.cardID != nil && guardState.guardPausedAutomationIDs.count == 2)
    }

    @Test func manualRunDoesNotImplicitlyResumeGuardPausedSchedules() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await service.answerSpendGuard(.pause, agentID: owner, at: now)
        let before = await service.list(), guardBefore = await service.spendGuardState(agentID: owner)
        let run = try await service.runNow(id: enabled.id, executor: SpendGuardExecutor(), now: now.addingTimeInterval(1))
        let after = await service.list(), guardAfter = await service.spendGuardState(agentID: owner)
        expectNoDifference(run.trigger, .manual); expectNoDifference(run.status, .ok)
        expectNoDifference(after.map(\.enabled), before.map(\.enabled)); expectNoDifference(after.map(\.guardPaused), before.map(\.guardPaused))
        expectNoDifference(after.map(\.nextRunAt), [nil, nil])
        expectNoDifference(guardAfter.cardID, guardBefore.cardID)
        expectNoDifference(guardAfter.guardPausedAutomationIDs, guardBefore.guardPausedAutomationIDs)
    }

    @Test func firesAreCountedAtAdmissionAndViewingDuringARunDoesNotRecountThatFire() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = SpendGuardGate(), runAt = now.addingTimeInterval(1)
        let run = Task { try await service.runNow(id: enabled.id, executor: gate, now: runAt) }
        await gate.waitForEntry()
        let admitted = await service.spendGuardState(agentID: owner)
        expectNoDifference(admitted.firesSinceViewed, 1)
        do { try await service.recordViewed(agentID: owner, at: now.addingTimeInterval(2)) }
        catch { await gate.finish(); _ = try? await run.value; throw error }
        await gate.finish(); _ = try await run.value
        let completed = await service.spendGuardState(agentID: owner)
        expectNoDifference(completed.firesSinceViewed, 0)
    }

    @Test(arguments: ["schedule", "event", "coalesced-event"])
    func pauseAndResumeDoNotReplayTheOldBatchOrInvalidateAnotherOwner(origin: String) async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try await addPeer(to: service)
        let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
        if origin != "schedule" {
            for var routine in [enabled, other] {
                routine.trigger = .event(.init(connectorID: connector, kind: "fixture"))
                _ = try await service.save(routine, now: now)
            }
        }
        let changedOwner = origin == "coalesced-event" ? owner : peer
        let before = await service.list(agentID: changedOwner)
        let dispatchAt = now.addingTimeInterval(3_601), resumeAt = dispatchAt.addingTimeInterval(60)
        let events = (1...(origin == "coalesced-event" ? 26 : 1)).map {
            AutomationEvent(connectorID: connector, kind: "fixture", externalEventID: "batch-\($0)",
                payloadJSON: Data("{}".utf8), occurredAt: dispatchAt)
        }
        let executor = SpendGuardBatchExecutor()
        let batch = Task {
            if origin == "schedule" { return await service.fireDue(at: dispatchAt, executor: executor) }
            return await service.fire(events: events, executor: executor, now: dispatchAt)
        }
        defer { batch.cancel(); Task { await executor.finish() } }
        await executor.waitForEntry()
        try await service.answerSpendGuard(.pause, agentID: changedOwner, at: dispatchAt)
        let cardID = try #require(await service.spendGuardState(agentID: changedOwner).cardID)
        try await service.answerSpendGuard(.resume, agentID: changedOwner, cardID: cardID, at: resumeAt)
        let resumed = await service.list(agentID: changedOwner)
        expectNoDifference(resumed.map(\.revision), before.map(\.revision))
        await executor.finish()
        let admitted = await batch.value
        expectNoDifference(admitted.map(\.automationID), origin == "coalesced-event" ? [enabled.id, other.id, other.id] : [enabled.id])
        let changedHistory = await service.history(automationID: origin == "coalesced-event" ? enabled.id : other.id)
        expectNoDifference(changedHistory.count, origin == "coalesced-event" ? 1 : 0)
        // A fresh dispatch after resuming is eligible, without reusing any of
        // the old delivery IDs or charging for missed scheduled occurrences.
        let freshAt = resumeAt.addingTimeInterval(3_600)
        let fresh: [AutomationRun]
        if origin == "schedule" { fresh = await service.fireDue(at: freshAt, executor: SpendGuardExecutor()) }
        else {
            fresh = await service.fire(events: [.init(connectorID: connector, kind: "fixture", externalEventID: "fresh",
                payloadJSON: Data("{}".utf8), occurredAt: freshAt)], executor: SpendGuardExecutor(), now: freshAt)
        }
        expectNoDifference(Set(fresh.map(\.automationID)), [enabled.id, other.id])
    }

    @Test(arguments: [false, true])
    func aFailedPauseDoesNotInvalidateAPendingDispatch(events: Bool) async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let other = try await addPeer(to: service)
        let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000092")!
        if events {
            for var routine in [enabled, other] {
                routine.trigger = .event(.init(connectorID: connector, kind: "fixture"))
                _ = try await service.save(routine, now: now)
            }
        }
        let dispatchAt = now.addingTimeInterval(3_601), executor = SpendGuardBatchExecutor()
        let batch = Task {
            if events {
                return await service.fire(events: [.init(connectorID: connector, kind: "fixture", externalEventID: "fixture",
                    payloadJSON: Data("{}".utf8), occurredAt: dispatchAt)], executor: executor, now: dispatchAt)
            }
            return await service.fireDue(at: dispatchAt, executor: executor)
        }
        defer { batch.cancel(); Task { await executor.finish() } }
        await executor.waitForEntry()
        let before = await service.list(), spends = await service.spendGuardStates()
        let file = root.appending(path: "automations.json"), backup = root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await service.answerSpendGuard(.pause, agentID: peer, at: dispatchAt)
        }
        let after = await service.list(), afterSpends = await service.spendGuardStates()
        expectNoDifference(after, before); expectNoDifference(afterSpends, spends)
        try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
        await executor.finish()
        let admitted = await batch.value
        expectNoDifference(admitted.map(\.automationID), [enabled.id, other.id])
        #expect(admitted.allSatisfy { $0.status == .ok })
    }

    @Test func retainedHistoryBoundsAndDeletedDefinitionsMatchTheOriginalFireCounter() async throws {
        let (root, service, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 1...22 {
            _ = try await service.runNow(id: enabled.id, executor: SpendGuardExecutor(), now: now.addingTimeInterval(Double(index)))
        }
        let before = await service.spendGuardState(agentID: owner)
        expectNoDifference(before.firesSinceViewed, AutomationService.maximumHistory)
        try await service.delete(id: enabled.id)
        let after = await service.spendGuardState(agentID: owner)
        expectNoDifference(after.firesSinceViewed, 0)
        let decision = try await service.evaluateSpendGuard(agentID: owner, at: nudgeAt)
        expectNoDifference(decision, .belowThresholds)
    }

    @Test func legacyGlobalStateMigratesOnlyKnownOwnerIDsAndAttributableHistory() async throws {
        let (root, _, enabled, disabled) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var paused = enabled; paused.enabled = false; paused.guardPaused = true; paused.nextRunAt = nil
        var other = paused
        other = .init(id: peer, agentID: peer, name: "Other", prompt: "Fixture", trigger: enabled.trigger,
            enabled: false, createdAt: now, guardPaused: true)
        let foreign = UUID(uuidString: "00000000-0000-0000-0000-000000000088")!
        let legacy = AutomationSpendGuardState(lastViewedAt: now, unreadCount: 120, firesSinceViewed: 120,
            nudgedAt: nudgeAt, snoozedUntil: pauseAt, optedOut: true, guardPausedAutomationIDs: [enabled.id, peer, foreign])
        let run = AutomationRun(automationID: enabled.id, trigger: .schedule, startedAt: now.addingTimeInterval(1),
            finishedAt: now.addingTimeInterval(2), status: .ok)
        let wake = AutomationWake(agentID: owner, runID: run.id, status: .ok, detail: "Fixture", createdAt: now.addingTimeInterval(2))
        let file = root.appending(path: "automations.json")
        try write(.init(schemaVersion: 1, automations: [paused, disabled, other], runs: [run], wakes: [wake], spendGuard: legacy), to: file)
        let migrated = try AutomationService(storeURL: file), states = await migrated.spendGuardStates()
        expectNoDifference(states[owner]?.guardPausedAutomationIDs, [enabled.id])
        expectNoDifference(states[peer]?.guardPausedAutomationIDs, [peer])
        expectNoDifference(states[owner]?.firesSinceViewed, 1); expectNoDifference(states[peer]?.firesSinceViewed, 0)
        expectNoDifference(states[owner]?.unreadCount, 1); expectNoDifference(states[peer]?.unreadCount, 0)
        #expect(states[owner]?.cardID != nil && states[peer]?.cardID != nil && states[owner]?.cardID != states[peer]?.cardID)
        expectNoDifference(states[owner]?.snoozedUntil, legacy.snoozedUntil); expectNoDifference(states[owner]?.optedOut, true)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        expectNoDifference(json["schemaVersion"] as? Int, 2); #expect(json["spendGuard"] == nil)
        let restored = try AutomationService(storeURL: file), durableStates = await restored.spendGuardStates()
        expectNoDifference(durableStates, states)
        try await restored.answerSpendGuard(.resume, agentID: owner, cardID: states[owner]?.cardID, at: pauseAt)
        let peerAfter = await restored.list(agentID: peer)
        expectNoDifference(peerAfter, [other])
    }

    @Test(arguments: [2, 99])
    func unsupportedOrIncompleteSchemasAreRejectedWithoutRewriting(version: Int) async throws {
        let (root, _, enabled, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        try write(.init(schemaVersion: version, automations: [enabled]), to: file)
        let bytes = try Data(contentsOf: file)
        #expect(throws: DecodingError.self) { _ = try AutomationService(storeURL: file) }
        expectNoDifference(try Data(contentsOf: file), bytes)
    }
}
