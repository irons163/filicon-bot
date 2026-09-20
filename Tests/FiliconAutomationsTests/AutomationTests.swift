import Foundation
import Testing
@testable import FiliconAutomations

private struct EchoAutomationExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: prompt, inputTokens: 4, outputTokens: 2, actualCost: Decimal(string: "0.01"))
    }
}

private actor BlockingAutomationExecutor: AutomationExecutor {
    private var continuation: CheckedContinuation<AutomationExecutionResult, Never>?
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: .init(detail: "late")); continuation = nil }
}

private actor EventBatchProbe {
    private(set) var batches: [[String]] = []
    func record(_ events: [AutomationEvent]) { batches.append(events.map(\.externalEventID)) }
}

private actor CancellationProbe {
    private(set) var sinkWasCancelled: Bool?
    func recordCancellationState() { sinkWasCancelled = Task.isCancelled }
}

@Suite("Automations")
struct AutomationTests {
    private func sandbox() throws -> (URL, AutomationService) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try AutomationService(storeURL: root.appending(path: "automations.json")))
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    @Test func cronFieldsAliasesEveryTimezoneDSTAndDayOrSemantics() throws {
        let stepped = try AutomationSchedule.compile("*/15 9-17/2 * * 1-5", defaultTimeZone: TimeZone(secondsFromGMT: 0))
        #expect(stepped.minute == [0, 15, 30, 45])
        #expect(stepped.hour == [9, 11, 13, 15, 17])
        #expect(try AutomationSchedule.nextRun(for: "@hourly", after: date("2026-01-01T10:13:20Z"), defaultTimeZone: TimeZone(secondsFromGMT: 0)) == date("2026-01-01T11:00:00Z"))
        #expect(try AutomationSchedule.nextRun(for: "@every 90m", after: date("2026-01-01T10:00:00Z")) == date("2026-01-01T11:30:00Z"))
        #expect(try AutomationSchedule.nextRun(for: "0 0 13 * 1", after: date("2026-01-06T00:01:00Z"), defaultTimeZone: TimeZone(secondsFromGMT: 0)) == date("2026-01-12T00:00:00Z"))

        let newYork = TimeZone(identifier: "America/New_York")!
        #expect(try AutomationSchedule.nextRun(for: "30 2 * * *", after: date("2026-03-08T06:59:00Z"), defaultTimeZone: newYork) == date("2026-03-09T06:30:00Z"))
        #expect(try AutomationSchedule.nextRun(for: "30 1 * * *", after: date("2026-11-01T05:30:00Z"), defaultTimeZone: newYork) == date("2026-11-02T06:30:00Z"))
        #expect(throws: ScheduleError.self) { _ = try AutomationSchedule.compile("CRON_TZ=No/Such_Zone 0 0 * * *") }
    }

    @Test func scheduledManualAndEventRunsAreClaimedDedupedBoundedAndDurable() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let agent = UUID(), connector = UUID(), base = date("2026-01-01T00:00:00Z")
        let scheduled = try await service.save(.init(agentID: agent, name: "Hourly", prompt: "check", trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), createdAt: base), now: base)
        #expect(scheduled.nextRunAt == date("2026-01-01T01:00:00Z"))
        let due = await service.fireDue(at: date("2026-01-01T01:00:00Z"), executor: EchoAutomationExecutor())
        #expect(due.count == 1)
        #expect(due[0].status == .ok)
        #expect(due[0].inputTokens == 4)
        #expect(await service.fireDue(at: date("2026-01-01T01:00:00Z"), executor: EchoAutomationExecutor()).isEmpty)

        let listener = try await service.save(.init(
            agentID: UUID(), name: "Deploy", prompt: "inspect",
            trigger: .event(.init(connectorID: connector, kind: "deploy", filtersJSON: Data(#"{"environment":"prod"}"#.utf8))),
            createdAt: base
        ), now: base)
        let events = (0..<30).map { index in
            AutomationEvent(connectorID: connector, kind: "deploy", externalEventID: "event-\(index)", payloadJSON: Data(#"{"environment":"prod","note":"<ignore me>"}"#.utf8))
        }
        let fired = await service.fire(events: events, executor: EchoAutomationExecutor(), now: base)
        #expect(fired.count == 2)
        #expect(fired.flatMap(\.coalescedEventIDs).count == 30)
        #expect(await service.fire(events: events, executor: EchoAutomationExecutor(), now: base).isEmpty)
        #expect(await service.history(automationID: listener.id).first?.detail?.contains("‹ignore me›") == true)
        #expect(await service.pendingWakes().count == 3)

        let unknown = try await service.save(.init(agentID: agent, name: "Future", prompt: "keep", trigger: .unknown(kind: "future", payloadJSON: Data("{}".utf8))), now: base)
        #expect(unknown.enabled == false)
        let reopened = try AutomationService(storeURL: root.appending(path: "automations.json"))
        #expect(await reopened.list().contains(where: { $0.id == unknown.id }))
    }

    @Test func stableAutomationIDMatchesSourceVectors() {
        #expect(AutomationStableID.make(agentID: "agent-1", localID: "daily-digest").uuidString.lowercased() == "e6a280d6-6ed6-5be2-a257-d1aa3fd1932e")
        #expect(AutomationStableID.make(agentID: "a", localID: "b").uuidString.lowercased() == "59b271ae-1bbc-51d3-9d41-929817f4b16f")
        #expect(AutomationStableID.make(agentID: "agent", localID: "automation").uuidString.lowercased() == "3dc3254c-155b-5325-9850-43d81c219a38")
    }

    @Test func platformTriggerNormalizationValidationAndMatching() throws {
        #expect(SlackAutomationTrigger.normalizeEmoji("::Eyes::") == "eyes")
        #expect(SlackAutomationTrigger.normalizeEmoji("bad emoji") == nil)
        let slack = try SlackAutomationTrigger(channel: "#Eng", match: .reaction(emoji: [":Eyes:", "eyes", "bad emoji"], bySelf: true))
        let slackEvent = AutomationEvent(connectorID: UUID(), kind: "slack", externalEventID: "s1", payloadJSON: Data(##"{"channel":"#eng","reaction":"EYES","isSelf":true}"##.utf8))
        #expect(PlatformAutomationTrigger.slack(slack).matches(slackEvent))
        let notSelf = AutomationEvent(connectorID: UUID(), kind: "slack", externalEventID: "s2", payloadJSON: Data(##"{"channel":"#eng","reaction":"eyes","isSelf":false}"##.utf8))
        #expect(!PlatformAutomationTrigger.slack(slack).matches(notSelf))

        #expect(throws: AutomationServiceError.self) { _ = try GitHubAutomationTrigger(repo: "bad repo", events: ["pr-opened"]) }
        let github = try GitHubAutomationTrigger(repo: "OpenAI/SDK", events: ["ci-passed", "pr-opened"], ciBranch: "main", userAllowlist: ["@Alice", "alice", "BOB"])
        #expect(github.userAllowlist == ["alice", "bob"])
        let githubEvent = AutomationEvent(connectorID: UUID(), kind: "github", externalEventID: "g1", payloadJSON: Data(#"{"repo":"openai/sdk","event":"ci-passed","branch":"main","actor":"ALICE","subjectPresent":true}"#.utf8))
        #expect(PlatformAutomationTrigger.github(github).matches(githubEvent))
        let noBranch = try GitHubAutomationTrigger(repo: "OpenAI/SDK", events: ["ci-passed", "pr-opened"])
        #expect(!noBranch.events.contains("ci-passed"))
        #expect(!PlatformAutomationTrigger.github(noBranch).matches(githubEvent))
        #expect(throws: AutomationServiceError.self) {
            _ = try GitHubAutomationTrigger(repo: "OpenAI/SDK", events: ["ci-passed"])
        }

        let teams = try TeamsAutomationTrigger(tenantID: "tenant", teamIDs: ["team"], channelIDs: ["channel"], messageContains: "deploy", blockUnauthenticatedUsers: true)
        let teamsEvent = AutomationEvent(connectorID: UUID(), kind: "microsoftTeams", externalEventID: "t1", payloadJSON: Data(#"{"tenantId":"tenant","teamId":"team","channelId":"channel","authenticated":true,"text":"DEPLOY now"}"#.utf8))
        // Legacy HMAC-only payloads do not prove an authenticated application user.
        #expect(!PlatformAutomationTrigger.microsoftTeams(teams).matches(teamsEvent))
    }

    @Test func schedulerTickAndTriggerHubDriveDurableRuns() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let base = date("2026-01-01T00:00:00Z")
        let scheduled = try await service.save(.init(
            agentID: UUID(), name: "Hourly", prompt: "tick",
            trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), createdAt: base
        ), now: base)
        let scheduler = AutomationScheduler(service: service, executor: EchoAutomationExecutor())
        let runs = await scheduler.runOnce(at: date("2026-01-01T01:00:00Z"))
        #expect(runs.count == 1)
        #expect(await service.history(automationID: scheduled.id).count == 1)
        #expect(await service.nextScheduledRunAt() == date("2026-01-01T02:00:00Z"))

        let connector = UUID()
        let listener = try await service.save(.init(
            agentID: UUID(), name: "Webhook", prompt: "event",
            trigger: .event(.init(connectorID: connector, kind: "deploy")), createdAt: base
        ), now: base)
        let hub = AutomationTriggerHub(service: service, executor: EchoAutomationExecutor(), debounce: .milliseconds(10))
        #expect(await hub.ingest(.init(connectorID: connector, kind: "deploy", externalEventID: "evt-1", payloadJSON: Data("{}".utf8))))
        #expect(await hub.queuedCount() == 1)
        await hub.waitUntilIdle()
        #expect(await service.history(automationID: listener.id).count == 1)
        #expect(await hub.queuedCount() == 0)
    }

    @Test func eventBatcherDebouncesDedupesCapsAndChunks() async throws {
        let probe = EventBatchProbe(), automationID = UUID(), connectorID = UUID()
        let batcher = AutomationEventBatcher(debounce: .milliseconds(10)) { _, events in await probe.record(events) }
        for index in 0..<30 {
            #expect(await batcher.enqueue(.init(connectorID: connectorID, kind: "test", externalEventID: "e\(index)", payloadJSON: Data("{}".utf8)), automationID: automationID))
        }
        #expect(await batcher.enqueue(.init(connectorID: connectorID, kind: "test", externalEventID: "e0", payloadJSON: Data("{}".utf8)), automationID: automationID) == false)
        #expect(await batcher.queuedCount(automationID: automationID) == 30)
        await batcher.waitUntilIdle(automationID: automationID)
        #expect(await probe.batches.map(\.count) == [25, 5])
        #expect(await probe.batches.flatMap { $0 }.count == 30)
    }

    @Test func debounceTimerDoesNotCancelItsOwnSink() async {
        let probe = CancellationProbe(), automationID = UUID()
        let batcher = AutomationEventBatcher(debounce: .milliseconds(1)) { _, _ in
            await probe.recordCancellationState()
        }
        _ = await batcher.enqueue(
            .init(connectorID: UUID(), kind: "test", externalEventID: "event", payloadJSON: Data("{}".utf8)),
            automationID: automationID
        )

        await batcher.waitUntilIdle(automationID: automationID)

        #expect(await probe.sinkWasCancelled == false)
    }

    @Test func restartMarksRunningInterruptedWithoutRerun() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let automation = try await service.save(.init(agentID: UUID(), name: "Block", prompt: "wait", trigger: .cron(expression: "@daily", timeZoneIdentifier: "UTC")))
        let blocker = BlockingAutomationExecutor()
        let task = Task { try await service.runNow(id: automation.id, executor: blocker) }
        var observedRunning = false
        for _ in 0..<100 {
            if await service.history(automationID: automation.id).first?.status == .running {
                observedRunning = true
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(observedRunning)
        let reopened = try AutomationService(storeURL: root.appending(path: "automations.json"))
        #expect(await reopened.history(automationID: automation.id).first?.status == .interrupted)
        #expect(await reopened.pendingWakes().first?.status == .interrupted)
        await blocker.release(); _ = try await task.value
    }

    @Test func spendGuardThresholdsAndResumeOwnership() async throws {
        let (root, service) = try sandbox(); defer { try? FileManager.default.removeItem(at: root) }
        let old = date("2026-01-01T00:00:00Z"), agent = UUID()
        let enabled = try await service.save(.init(agentID: agent, name: "Enabled", prompt: "run", trigger: .cron(expression: "@daily", timeZoneIdentifier: "UTC"), createdAt: old), now: old)
        let disabled = try await service.save(.init(agentID: agent, name: "Disabled", prompt: "run", trigger: .cron(expression: "@daily", timeZoneIdentifier: "UTC"), enabled: false, createdAt: old), now: old)
        try await service.recordViewed(at: old)
        for index in 0..<AutomationSpendGuard.minimumFiresSinceViewed {
            _ = try await service.runNow(id: enabled.id, executor: EchoAutomationExecutor(), now: old.addingTimeInterval(Double(index)))
        }
        let nudgeAt = old.addingTimeInterval(AutomationSpendGuard.idleInterval + 1)
        #expect(try await service.evaluateSpendGuard(at: nudgeAt) == .nudge)
        let pauseAt = nudgeAt.addingTimeInterval(AutomationSpendGuard.pauseDelay + 1)
        #expect(try await service.evaluateSpendGuard(at: pauseAt) == .pause)
        #expect(await service.list().first(where: { $0.id == enabled.id })?.enabled == false)
        try await service.answerSpendGuard(.resume, at: pauseAt)
        #expect(await service.list().first(where: { $0.id == enabled.id })?.enabled == true)
        #expect(await service.list().first(where: { $0.id == disabled.id })?.enabled == false)
        #expect(await service.history(automationID: enabled.id).count == AutomationService.maximumHistory)
    }
}
