import CustomDump
import Foundation
import Testing
import FiliconAutomations

private struct CompositeScheduleExecutor: AutomationExecutor {
    var inspect: @Sendable (Automation) async -> Void = { _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await inspect(automation)
        return .init(detail: "Isolated schedule fixture; no model or network")
    }
}

private actor CompositeScheduleGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        await withCheckedContinuation { waiter = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { waiter?.resume(); waiter = nil }
}

@Suite("Composite time and event scheduling", .timeLimit(.minutes(1)))
struct CompositeRoutineScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 00:00 UTC
    private let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    private let connectorID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
    private func cron(_ expression: String, zone: String = "UTC") -> AutomationTrigger {
        .cron(expression: expression, timeZoneIdentifier: zone)
    }
    private func routine(_ members: [AutomationTrigger], enabled: Bool = true) -> Automation {
        .init(agentID: agentID, name: "Mixed schedule", prompt: "Inspect only", trigger: .anyOf(members),
              enabled: enabled, createdAt: now)
    }
    private func slack() throws -> AutomationTrigger { .platform(.slack(try .init(channel: "C123", match: .message))) }
    private func event(_ id: String) -> AutomationEvent {
        .init(connectorID: connectorID, kind: "slack", externalEventID: id,
              payloadJSON: Data(#"{"channel":"C123","text":"fixture"}"#.utf8), occurredAt: now)
    }
    private func fixture(_ body: (AutomationService, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-composite-schedule-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        try await body(AutomationService(storeURL: file), file)
    }

    @Test func earliestTimeWinsAndCoincidentMembersExecuteOnce() async throws {
        try await fixture { service, file in
            let saved = try await service.save(routine([cron("@daily"), cron("@every 1h"), cron("0 * * * *"), slack()]), now: now)
            expectNoDifference(saved.nextRunAt, now.addingTimeInterval(3_600))
            let early = await service.fireDue(at: now.addingTimeInterval(3_599), executor: CompositeScheduleExecutor())
            expectNoDifference(early, [])
            let due = now.addingTimeInterval(3_600)
            var snapshot = saved
            await expectDifference(snapshot) {
                let runs = await service.fireDue(at: due, executor: CompositeScheduleExecutor())
                expectNoDifference(runs.count, 1); expectNoDifference(runs.first?.trigger, .schedule)
                snapshot = try #require(await service.list().first)
            } changes: {
                $0.lastRunAt = due
                $0.nextRunAt = now.addingTimeInterval(7_200)
            }
            let restored = try AutomationService(storeURL: file)
            let replay = await restored.fireDue(at: due, executor: CompositeScheduleExecutor())
            expectNoDifference(replay, [])
            let restoredValue = await restored.list().first
            expectNoDifference(restoredValue, snapshot)
        }
    }

    @Test(arguments: [false, true])
    func eventAndManualRunsAdvanceTheSharedIntervalAnchor(manual: Bool) async throws {
        try await fixture { service, _ in
            let saved = try await service.save(routine([cron("@every 1h"), slack()]), now: now)
            let firedAt = now.addingTimeInterval(1_800)
            var snapshot = saved
            await expectDifference(snapshot) {
                if manual {
                    let run = try await service.runNow(id: saved.id, executor: CompositeScheduleExecutor(), now: firedAt)
                    expectNoDifference(run.trigger, .manual)
                } else {
                    let runs = await service.fire(events: [event("first")], executor: CompositeScheduleExecutor(), now: firedAt)
                    expectNoDifference(runs.count, 1); expectNoDifference(runs.first?.trigger, .event)
                }
                snapshot = try #require(await service.list().first)
            } changes: {
                $0.lastRunAt = firedAt
                $0.nextRunAt = now.addingTimeInterval(5_400)
            }
            let oldDeadline = await service.fireDue(at: now.addingTimeInterval(3_600), executor: CompositeScheduleExecutor())
            expectNoDifference(oldDeadline, [])
            let runs = await service.fireDue(at: now.addingTimeInterval(5_400), executor: CompositeScheduleExecutor())
            expectNoDifference(runs.count, 1)
        }
    }

    @Test func pauseResumeAndReloadDoNotExecuteOrCatchUp() async throws {
        try await fixture { service, file in
            let saved = try await service.save(routine([cron("@every 1h"), slack()]), now: now)
            try await service.setEnabled(id: saved.id, enabled: false, now: now.addingTimeInterval(60))
            let paused = await service.list().first
            expectNoDifference(paused?.nextRunAt, nil)
            let ignored = await service.fire(events: [event("paused")], executor: CompositeScheduleExecutor(), now: now.addingTimeInterval(120))
            expectNoDifference(ignored, [])
            let restored = try AutomationService(storeURL: file)
            let resumeAt = now.addingTimeInterval(7_200)
            try await restored.setEnabled(id: saved.id, enabled: true, now: resumeAt)
            let pending = await restored.nextScheduledRunAt(), history = await restored.history(automationID: saved.id)
            expectNoDifference(pending, now.addingTimeInterval(10_800)); expectNoDifference(history, [])
            let noCatchUp = await restored.fireDue(at: resumeAt, executor: CompositeScheduleExecutor())
            expectNoDifference(noCatchUp, [])
            let runs = await restored.fireDue(at: now.addingTimeInterval(10_800), executor: CompositeScheduleExecutor())
            expectNoDifference(runs.count, 1)
        }
    }

    @Test func overdueMembersCoalesceWithoutBackfill() async throws {
        try await fixture { service, _ in
            _ = try await service.save(routine([cron("@every 1h"), cron("@every 2h"), slack()]), now: now)
            let runs = await service.fireDue(at: now.addingTimeInterval(10_000), executor: CompositeScheduleExecutor())
            expectNoDifference(runs.count, 1)
            let next = await service.nextScheduledRunAt()
            expectNoDifference(next, now.addingTimeInterval(13_600))
        }
    }

    @Test func spendGuardPauseKeepsBothPathsStoppedUntilUserResumes() async throws {
        try await fixture { service, file in
            let saved = try await service.save(routine([cron("@every 1h"), slack()]), now: now)
            try await service.answerSpendGuard(.pause, at: now)
            let restored = try AutomationService(storeURL: file)
            let paused = try #require(await restored.list().first)
            expectNoDifference(paused.guardPaused, true); expectNoDifference(paused.nextRunAt, nil)
            await #expect(throws: AutomationStateChangeError.protected) {
                _ = try await restored.applyStateChange(.init(operation: .resume, automation: paused), lifetime: .init(), now: now)
            }
            let skippedTime = await restored.fireDue(at: now.addingTimeInterval(7_200), executor: CompositeScheduleExecutor())
            let skippedEvent = await restored.fire(events: [event("guard-paused")], executor: CompositeScheduleExecutor(), now: now)
            expectNoDifference(skippedTime, []); expectNoDifference(skippedEvent, [])
            try await restored.answerSpendGuard(.resume, at: now.addingTimeInterval(7_200))
            let resumed = await restored.list().first, history = await restored.history(automationID: saved.id)
            expectNoDifference(resumed?.guardPaused, false)
            expectNoDifference(resumed?.nextRunAt, now.addingTimeInterval(10_800))
            expectNoDifference(history, [])
        }
    }

    @Test func scheduleCalculationFailureDoesNotPartiallyEnableDefinition() async throws {
        try await fixture { service, file in
            // Preserve the existing single-cron behavior when there is no
            // instant within the bounded search, while publishing no mutation.
            let saved = try await service.save(.init(agentID: agentID, name: "Leap day", prompt: "Inspect",
                trigger: cron("0 0 29 2 *"), enabled: false, createdAt: now), now: now)
            await #expect(throws: ScheduleError.noRunWithinSearchBound) {
                try await service.setEnabled(id: saved.id, enabled: true, now: now)
            }
            let current = await service.list().first
            expectNoDifference(current, saved)
            let restored = try AutomationService(storeURL: file)
            let persisted = await restored.list().first
            expectNoDifference(persisted, saved)
        }
    }

    @Test(arguments: [false, true])
    func eachTimeMemberHonorsItsZoneAndExplicitOverride(override: Bool) async throws {
        try await fixture { service, _ in
            let start = try #require(ISO8601DateFormatter().date(from: "2026-03-08T00:00:00Z"))
            var value = routine([cron("0 3 * * *", zone: "America/New_York"), cron("0 8 * * *")])
            if override { value.trigger = .anyOf([cron("TZ=UTC 0 6 * * *", zone: "Asia/Taipei"), cron("0 8 * * *")]) }
            value.lastRunAt = start
            let saved = try await service.save(value, now: start)
            expectNoDifference(saved.nextRunAt, start.addingTimeInterval(override ? 6 * 3_600 : 7 * 3_600))
        }
    }

    @Test func dormantCalendarMemberDoesNotDisableOtherMembers() async throws {
        try await fixture { service, _ in
            let saved = try await service.save(routine([cron("0 0 29 2 *"), cron("@daily"), slack()]), now: now)
            expectNoDifference(saved.nextRunAt, now.addingTimeInterval(86_400))
            let dormant = try await service.save(routine([cron("0 0 29 2 *"), slack()]), now: now)
            expectNoDifference(dormant.nextRunAt, nil)
        }
    }

    @Test func eventOnlyAndUnknownCompositesDoNotAcquireTimeSchedules() async throws {
        try await fixture { service, _ in
            let eventOnly = try await service.save(routine([slack(), .event(.init(connectorID: connectorID, kind: "fixture"))]), now: now)
            expectNoDifference(eventOnly.nextRunAt, nil)
            let unknown = try await service.save(routine([cron("@daily"), .unknown(kind: "future", payloadJSON: Data("{}".utf8))]), now: now)
            expectNoDifference(unknown.nextRunAt, nil)
        }
    }

    @Test func legacyDefinitionsWithoutNextRunAreNotArmedOnLoad() async throws {
        try await fixture { service, file in
            let saved = try await service.save(routine([cron("@daily"), slack()], enabled: false), now: now)
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            var definitions = try #require(json["automations"] as? [[String: Any]])
            definitions[0]["enabled"] = true // Pre-fix mixed definition had no nextRunAt.
            definitions[0].removeValue(forKey: "nextRunAt")
            json["automations"] = definitions
            try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
            let restored = try AutomationService(storeURL: file)
            let next = await restored.nextScheduledRunAt()
            expectNoDifference(next, nil)
            let runs = await restored.fireDue(at: now.addingTimeInterval(86_400), executor: CompositeScheduleExecutor())
            expectNoDifference(runs, [])
            try await restored.setEnabled(id: saved.id, enabled: true, now: now)
            let explicitlyEnabled = await restored.nextScheduledRunAt()
            expectNoDifference(explicitlyEnabled, now.addingTimeInterval(86_400))
        }
    }

    @Test(arguments: [false, true])
    func interveningRunInvalidatesAnAwaitingScheduledBatch(manual: Bool) async throws {
        try await fixture { service, _ in
            // The first, single-cron task holds the batch while another agent runs.
            let first = try await service.save(.init(agentID: UUID(), name: "Gate", prompt: "Wait",
                trigger: cron("@every 1h"), createdAt: now), now: now)
            let second = try await service.save(routine([cron("@every 1h"), slack()]), now: now)
            let gate = CompositeScheduleGate(), deadline = now.addingTimeInterval(3_600)
            let batch = Task {
                await service.fireDue(at: deadline, executor: CompositeScheduleExecutor { value in
                    if value.id == first.id { await gate.hold() }
                })
            }
            defer { batch.cancel(); Task { await gate.release() } }
            await gate.waitForEntry()
            if manual {
                _ = try await service.runNow(id: second.id, executor: CompositeScheduleExecutor(), now: deadline)
            } else {
                let eventRuns = await service.fire(events: [event("intervening")], executor: CompositeScheduleExecutor(), now: deadline)
                expectNoDifference(eventRuns.count, 1)
            }
            await gate.release()
            let scheduledRuns = await batch.value
            expectNoDifference(scheduledRuns.map(\.automationID), [first.id])
            let history = await service.history(automationID: second.id)
            expectNoDifference(history.count, 1)
            let nextRuns = await service.fireDue(at: now.addingTimeInterval(7_200), executor: CompositeScheduleExecutor())
            expectNoDifference(Set(nextRuns.map(\.automationID)), Set([first.id, second.id]))
        }
    }

    @Test(arguments: ["syntax", "zone", "nested", "capacity"])
    func invalidMembersRejectEntireDefinitionIncludingWhenDisabled(kind: String) async throws {
        try await fixture { service, _ in
            let bad: [AutomationTrigger]
            switch kind {
            case "syntax": bad = [cron("bad cron"), cron("@daily")]
            case "zone": bad = [cron("@daily", zone: "Not/AZone"), cron("@daily")]
            case "nested": bad = [.anyOf([cron("@daily"), cron("@hourly")]), cron("@daily")]
            default: bad = Array(repeating: cron("@daily"), count: 9)
            }
            await #expect(throws: (any Error).self) { _ = try await service.save(routine(bad, enabled: false), now: now) }
            let definitions = await service.list()
            expectNoDifference(definitions, [])
        }
    }

    @Test(arguments: ["create", "update", "enable", "fire"])
    func failedPersistenceDoesNotPublishDefinitionsOrConsumeScheduledClaims(operation: String) async throws {
        try await fixture { service, file in
            // Use a single cron so this also detects the pre-existing claim/busy leak.
            let saved = try await service.save(.init(agentID: agentID, name: "Atomic", prompt: "Inspect",
                trigger: cron("@every 1h"), enabled: operation != "enable", createdAt: now), now: now)
            let before = await service.list(), historyBefore = await service.history(automationID: saved.id)
            let backup = file.appendingPathExtension("backup")
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            switch operation {
            case "create":
                await #expect(throws: (any Error).self) { _ = try await service.save(routine([cron("@daily"), slack()]), now: now) }
            case "update":
                var proposed = saved; proposed.trigger = .anyOf([cron("@daily"), try slack()])
                await #expect(throws: (any Error).self) { _ = try await service.save(proposed, now: now) }
            case "enable":
                await #expect(throws: (any Error).self) { try await service.setEnabled(id: saved.id, enabled: true, now: now) }
            default:
                let failed = await service.fireDue(at: now.addingTimeInterval(3_600), executor: CompositeScheduleExecutor { _ in
                    Issue.record("Executor must not start before durable run claim")
                })
                expectNoDifference(failed, [])
            }
            let after = await service.list(), historyAfter = await service.history(automationID: saved.id)
            expectNoDifference(after, before); expectNoDifference(historyAfter, historyBefore)
            // Remove only this fixture's empty blocker and restore its own store.
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
            if operation == "enable" { try await service.setEnabled(id: saved.id, enabled: true, now: now) }
            let retry = await service.fireDue(at: now.addingTimeInterval(3_600), executor: CompositeScheduleExecutor())
            expectNoDifference(retry.count, 1); expectNoDifference(retry.first?.status, .ok)
            let restored = try AutomationService(storeURL: file)
            let persisted = await restored.history(automationID: saved.id)
            expectNoDifference(persisted.map(\.id), retry.map(\.id))
            expectNoDifference(persisted.map(\.status), [.ok])
            expectNoDifference(persisted.map(\.startedAt), [now.addingTimeInterval(3_600)])
        }
    }
}
