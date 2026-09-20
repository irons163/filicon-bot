import CustomDump
import Foundation
import Testing
import FiliconAutomations

private struct ManualEditExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Fixture only; no provider or network")
    }
}

private actor ManualEditGate: AutomationExecutor {
    private var pending: CheckedContinuation<AutomationExecutionResult, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var definitions: [Automation] = []

    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        definitions.append(automation)
        return await withCheckedContinuation { continuation in
            pending = continuation
            for waiter in startWaiters { waiter.resume() }
            startWaiters.removeAll()
        }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func finish() {
        pending?.resume(returning: .init(detail: "Original in-flight task completed", actualCost: 0.25))
        pending = nil
    }
}

@Suite("Manual routine definition edits", .timeLimit(.minutes(1)))
struct ManualRoutineEditTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000051")!
    private let owner = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000052")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var routine: Automation {
        .init(id: id, agentID: owner, name: "Original", prompt: "Original task",
            trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), createdAt: now)
    }
    private func fixture() throws -> (URL, AutomationService) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "filicon-manual-edit-\(UUID())")
        return (folder, try AutomationService(storeURL: folder.appending(path: "automations.json")))
    }
    private func change(_ original: Automation, name: String = "Updated", trigger: AutomationTrigger? = nil) -> AutomationStateChange {
        var proposed = original; proposed.name = name; proposed.trigger = trigger ?? original.trigger
        return .init(operation: .update, automation: proposed, previous: original)
    }

    @Test func metadataEditPreservesRuntimeAdvancesAndDoesNotRunOrRearm() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        _ = try await service.runNow(id: id, executor: ManualEditExecutor(), now: now.addingTimeInterval(60))
        let current = try #require(await service.list().first)
        let history = await service.history(automationID: id)
        let wakes = await service.pendingWakes()
        let guardState = await service.spendGuardState()
        var proposal = before; proposal.name = " Updated "; proposal.prompt = " Updated task "
        // Runtime fields from an old or forged UI snapshot are never restored.
        proposal.lastRunAt = .distantPast; proposal.nextRunAt = .distantPast
        let edit = AutomationStateChange(operation: .update, automation: proposal, previous: before)
        let lifetime = AutomationStateChangeLifetime()
        let saved = try await service.updateManualDefinition(edit, lifetime: lifetime, now: now.addingTimeInterval(120))
        var expected = current; expected.name = "Updated"; expected.prompt = "Updated task"; expected.revision = 2
        expectNoDifference(saved, expected)
        expectNoDifference(lifetime.committed(for: edit), saved)
        let afterHistory = await service.history(automationID: id), afterWakes = await service.pendingWakes()
        let afterGuard = await service.spendGuardState()
        expectNoDifference(afterHistory, history); expectNoDifference(afterWakes, wakes); expectNoDifference(afterGuard, guardState)
        let restored = try AutomationService(storeURL: folder.appending(path: "automations.json"))
        let restoredDefinitions = await restored.list()
        expectNoDifference(restoredDefinitions, [expected])
    }

    @Test func changedScheduleUsesSaveTimeButMetadataAndNoopKeepExistingAnchor() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        let same = try await service.updateManualDefinition(change(before, name: before.name), lifetime: .init(), now: now.addingTimeInterval(180))
        expectNoDifference(same, before)
        let edited = try await service.updateManualDefinition(change(before, trigger: .cron(expression: "@every 2h", timeZoneIdentifier: "Asia/Taipei")), lifetime: .init(), now: now.addingTimeInterval(180))
        expectNoDifference(edited.nextRunAt, now.addingTimeInterval(180 + 7200))
        #expect(edited.lastRunAt == nil)
        let runs = await service.history(automationID: id)
        expectNoDifference(runs, [])
    }

    @Test func completingAnInflightRunKeepsTheEditedDefinitionAndItsNewSchedule() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        let gate = ManualEditGate(), runTime = now.addingTimeInterval(60), routineID = id
        let running = Task { try await service.runNow(id: routineID, executor: gate, now: runTime) }
        await gate.waitUntilStarted()
        let saved: Automation
        do {
            let edit = change(before, trigger: .cron(expression: "@every 2h", timeZoneIdentifier: "UTC"))
            saved = try await service.updateManualDefinition(edit, lifetime: .init(), now: now.addingTimeInterval(120))
        } catch {
            await gate.finish(); _ = try? await running.value
            throw error
        }
        let during = await service.history(automationID: id)
        expectNoDifference(during.map(\.status), [.running])
        await gate.finish()
        let completed = try await running.value
        let definitions = await service.list(), history = await service.history(automationID: id)
        let executed = await gate.definitions, wakes = await service.pendingWakes()
        expectNoDifference(definitions, [saved])
        expectNoDifference(saved.nextRunAt, now.addingTimeInterval(120 + 7200))
        expectNoDifference(executed, [before])
        expectNoDifference(history, [completed])
        expectNoDifference(completed.status, .ok)
        expectNoDifference(completed.actualCost, 0.25)
        expectNoDifference(wakes.map(\.runID), [completed.id])
    }

    @Test(arguments: [false, true])
    func disabledAndSpendProtectedDefinitionsRemainPaused(guardPaused: Bool) async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        _ = try await service.save(routine, now: now)
        if guardPaused { try await service.answerSpendGuard(.pause, at: now) }
        else { try await service.setEnabled(id: id, enabled: false, now: now) }
        let before = try #require(await service.list().first)
        let spend = await service.spendGuardState()
        let saved = try await service.updateManualDefinition(change(before, trigger: .cron(expression: "@every 2h", timeZoneIdentifier: "UTC")), lifetime: .init(), now: now)
        expectNoDifference(saved.enabled, false); expectNoDifference(saved.guardPaused, guardPaused)
        #expect(saved.nextRunAt == nil)
        let afterSpend = await service.spendGuardState()
        expectNoDifference(afterSpend, spend)
    }

    @Test func eventFilterEditsDoNotResetAnUnchangedTimeCondition() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let first = AutomationTrigger.platform(.sentry(try .init(event: "issueCreated", allowedEvents: ["issueCreated"], primaryIDs: ["123"])))
        let second = AutomationTrigger.platform(.sentry(try .init(event: "issueCreated", allowedEvents: ["issueCreated"], primaryIDs: ["456"])))
        var original = routine; original.trigger = .anyOf([routine.trigger, first])
        let before = try await service.save(original, now: now)
        let saved = try await service.updateManualDefinition(change(before, trigger: .anyOf([routine.trigger, second])), lifetime: .init(), now: now.addingTimeInterval(600))
        expectNoDifference(saved.nextRunAt, before.nextRunAt)
    }

    @Test(arguments: ["rename", "toggle", "delete", "spend"])
    func staleSnapshotsCannotOverwriteAnotherAction(_ operation: String) async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        switch operation {
        case "rename": _ = try await service.updateManualDefinition(change(before, name: "Other editor"), lifetime: .init(), now: now)
        case "toggle":
            try await service.setEnabled(id: id, enabled: false, now: now)
            try await service.setEnabled(id: id, enabled: true, now: now)
        case "delete": try await service.delete(id: id)
        default: try await service.answerSpendGuard(.pause, at: now)
        }
        let current = await service.list(), lifetime = AutomationStateChangeLifetime(), edit = change(before)
        await #expect(throws: AutomationEditError.stale) { try await service.updateManualDefinition(edit, lifetime: lifetime, now: now) }
        let after = await service.list()
        expectNoDifference(after, current); #expect(lifetime.committed(for: edit) == nil)
    }

    @Test func immutableDefinitionFieldsCannotBeChangedByBypassingTheForm() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        var proposals: [Automation] = []
        var value = before; value.enabled = false; proposals.append(value)
        value = before; value.guardPaused = true; proposals.append(value)
        value = before; value.revision = 0; proposals.append(value)
        proposals.append(.init(id: id, agentID: id, name: before.name, prompt: before.prompt, trigger: before.trigger, createdAt: now))
        proposals.append(.init(id: owner, agentID: owner, name: before.name, prompt: before.prompt, trigger: before.trigger, createdAt: now))
        proposals.append(.init(id: id, agentID: owner, name: before.name, prompt: before.prompt, trigger: before.trigger, createdAt: now.addingTimeInterval(1)))
        for proposal in proposals {
            let edit = AutomationStateChange(operation: .update, automation: proposal, previous: before)
            await #expect(throws: AutomationEditError.stale) { try await service.updateManualDefinition(edit, lifetime: .init(), now: now) }
        }
        let after = await service.list(); expectNoDifference(after, [before])
    }

    @Test func failedPersistenceKeepsPublishedDefinitionAndReceiptRetryable() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        let url = folder.appending(path: "automations.json"), backup = folder.appending(path: "backup.json")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let lifetime = AutomationStateChangeLifetime(), edit = change(before)
        await #expect(throws: (any Error).self) { try await service.updateManualDefinition(edit, lifetime: lifetime, now: now) }
        let after = await service.list(); expectNoDifference(after, [before])
        #expect(lifetime.committed(for: edit) == nil)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        let saved = try await service.updateManualDefinition(edit, lifetime: lifetime, now: now)
        expectNoDifference(lifetime.committed(for: edit), saved)
    }

    @Test func legacyAndUnknownTriggersArePreservedForMetadataOnly() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let triggers: [AutomationTrigger] = [
            .unknown(kind: "future", payloadJSON: Data(#"{"untouched":true}"#.utf8)),
            .platform(.sentry(try .init(event: "created", allowedEvents: ["created"], primaryIDs: ["legacy-name"]))),
            .anyOf([routine.trigger, .unknown(kind: "future", payloadJSON: Data("{}".utf8))]),
            .platform(.microsoftTeams(try .init(tenantID: "tenant", teamIDs: ["team"], messageContains: "text", messageContainsIsRegex: true, blockUnauthenticatedUsers: false)))
        ]
        for trigger in triggers {
            var original = routine; original.trigger = trigger
            let before = try await service.save(original, now: now)
            let saved = try await service.updateManualDefinition(change(before), lifetime: .init(), now: now)
            expectNoDifference(saved.trigger, trigger); expectNoDifference(saved.enabled, before.enabled)
            await #expect(throws: (any Error).self) { try await service.updateManualDefinition(change(saved, trigger: routine.trigger), lifetime: .init(), now: now) }
        }
    }

    @Test func invalidTextAndChangedConditionsNeverSavePartialDefinitions() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        for name in [" ", String(repeating: "a", count: 81)] {
            await #expect(throws: AutomationEditError.invalidText) { try await service.updateManualDefinition(change(before, name: name), lifetime: .init(), now: now) }
        }
        for prompt in ["\n", String(repeating: "a", count: 32_001)] {
            var proposed = before; proposed.prompt = prompt
            let edit = AutomationStateChange(operation: .update, automation: proposed, previous: before)
            await #expect(throws: AutomationEditError.invalidText) { try await service.updateManualDefinition(edit, lifetime: .init(), now: now) }
        }
        let invalid: [AutomationTrigger] = [
            .cron(expression: "@every 1s", timeZoneIdentifier: "UTC"), .cron(expression: "invalid", timeZoneIdentifier: "UTC"),
            .cron(expression: "@daily", timeZoneIdentifier: "Invalid/Zone"), .anyOf([]), .anyOf([routine.trigger, routine.trigger]),
            .anyOf([routine.trigger, .anyOf([routine.trigger, routine.trigger])]),
            .platform(.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"], secondaryIDs: [owner.uuidString]))),
            .platform(.sentry(try .init(event: "issueCreated", allowedEvents: ["issueCreated"], primaryIDs: ["name"]))),
            .platform(.pagerDuty(try .init(event: "incidentTriggered", allowedEvents: ["incidentTriggered"], primaryIDs: ["*"])))
        ]
        for trigger in invalid {
            await #expect(throws: (any Error).self) { try await service.updateManualDefinition(change(before, trigger: trigger), lifetime: .init(), now: now) }
        }
        let after = await service.list(); expectNoDifference(after, [before])
    }

    @Test func closingOrCancellingAnEditorRevokesAnUncommittedWrite() async throws {
        let (folder, service) = try fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try await service.save(routine, now: now)
        let lifetime = AutomationStateChangeLifetime(); lifetime.close()
        await #expect(throws: CancellationError.self) { try await service.updateManualDefinition(change(before), lifetime: lifetime, now: now) }
        let edit = change(before), time = now
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.updateManualDefinition(edit, lifetime: .init(), now: time)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        let after = await service.list(); expectNoDifference(after, [before])
    }
}
