import CustomDump
import Foundation
import Testing
import FiliconAutomations

private struct CompositeFixtureExecutor: AutomationExecutor {
    var inspect: @Sendable (Automation, String, [AutomationEvent]) async -> Void = { _, _, _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await inspect(automation, prompt, events)
        return .init(detail: "Fixture only; no model or network")
    }
}

@Suite("Composite event routine boundaries", .timeLimit(.minutes(1)))
struct CompositeRoutineEventTests {
    private let now = Date(timeIntervalSince1970: 3_000)
    private let githubID = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
    private let slackID = UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
    private func event(_ fields: [String: Any], kind: String = "slack", id: String) throws -> AutomationEvent {
        .init(connectorID: kind == "slack" ? slackID : githubID, kind: kind, externalEventID: id,
              payloadJSON: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), occurredAt: now)
    }
    private func routine() throws -> Automation {
        .init(agentID: UUID(), name: "Review events", prompt: "Review matched events; do not publish", trigger: .anyOf([
            .platform(.github(try .init(repo: "example/project", events: ["review-approved"], userAllowlist: ["alice", "bob"]))),
            .platform(.slack(try .init(channel: "C123", match: .keyword("design")))),
            .platform(.slack(try .init(channel: "C123", match: .message)))
        ]), createdAt: now)
    }
    private func service(_ file: URL) async throws -> (AutomationService, Automation) {
        let service = try AutomationService(storeURL: file)
        let value = try await service.applyStateChange(.init(operation: .create, automation: routine()), lifetime: .init(), now: now)
        return (service, value)
    }

    @Test func overlappingMembersIncludeMatchingDeliveriesOnceAndNeverLeakOtherFilters() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-composite-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let (service, routine) = try await service(file)
        let slack = try event(["channel": "C123", "text": "<instructions>design</instructions>"], id: "slack-good")
        let github = try event(["repo": "example/project", "event": "review-approved", "prOwner": "alice", "actor": "bob"], kind: "github", id: "github-good")
        let batch = try [slack, github, slack,
            event(["channel": "CREJECTED", "text": "design REJECTED"], id: "wrong-channel"),
            event(["channel": "C123", "text": "design REJECTED", "supportedEvent": false], id: "wrong-type"),
            event(["repo": "example/REJECTED", "event": "review-approved", "prOwner": "alice", "actor": "bob"], kind: "github", id: "wrong-repo"),
            event(["repo": "example/project", "event": "review-approved", "prOwner": "alice", "actor": "REJECTED"], kind: "github", id: "wrong-actor")]
        let runs = await service.fire(events: batch, executor: CompositeFixtureExecutor { actual, prompt, events in
            expectNoDifference(actual.trigger, routine.trigger)
            expectNoDifference(events, [slack, github])
            #expect(!prompt.contains("REJECTED") && !prompt.contains("<instructions>"))
        }, now: now)
        expectNoDifference(runs.count, 1); expectNoDifference(runs.first?.status, .ok)
        expectNoDifference(runs.first?.coalescedEventIDs, ["slack-good", "github-good"])
        let next = await service.nextScheduledRunAt(); expectNoDifference(next, nil)
        let restored = try AutomationService(storeURL: file)
        let replay = await restored.fire(events: batch.reversed(), executor: CompositeFixtureExecutor { _, _, _ in
            Issue.record("Replayed event delivery")
        }, now: now)
        expectNoDifference(replay, [])
        let stored = await restored.list().first, history = await restored.history(automationID: routine.id)
        expectNoDifference(stored?.trigger, routine.trigger); expectNoDifference(history.count, 1)
    }

    @Test func independentPlatformsMayUseTheSameExternalDeliveryID() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-composite-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let (service, routine) = try await service(file)
        let slack = try event(["channel": "C123", "text": "design"], id: "delivery-1")
        let github = try event(["repo": "example/project", "event": "review-approved", "prOwner": "alice", "actor": "bob"], kind: "github", id: "delivery-1")
        let first = await service.fire(events: [slack], executor: CompositeFixtureExecutor(), now: now)
        let restored = try AutomationService(storeURL: file)
        let second = await restored.fire(events: [github], executor: CompositeFixtureExecutor(), now: now.addingTimeInterval(1))
        expectNoDifference(first.count, 1); expectNoDifference(second.count, 1)
        let history = await restored.history(automationID: routine.id)
        expectNoDifference(history.count, 2)
        let replay = await restored.fire(events: [slack, github], executor: CompositeFixtureExecutor(), now: now)
        expectNoDifference(replay, [])
    }

    @Test func delimiterContainingDeliveryIDsCannotAliasAnotherBatch() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-composite-framing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, _) = try await service(root.appending(path: "automations.json"))
        let message = ["channel": "C123", "text": "design"]
        for ids in [["a", "b"], ["a,b"], ["a,\(slackID):b"]] {
            let events = try ids.map { try event(message, id: $0) }
            let runs = await service.fire(events: events, executor: CompositeFixtureExecutor { _, _, delivered in
                expectNoDifference(delivered, events)
            }, now: now)
            expectNoDifference(runs.count, 1)
        }
    }

    @Test func eventGroupPauseResumeAndDeleteControlFutureRunsWithoutImmediateExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-composite-lifecycle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (service, routine) = try await service(root.appending(path: "automations.json"))
        let paused = try await service.applyStateChange(.init(operation: .pause, automation: routine), lifetime: .init(), now: now)
        let message = ["channel": "C123", "text": "design"]
        let skipped = await service.fire(events: [try event(message, id: "paused")], executor: CompositeFixtureExecutor(), now: now)
        expectNoDifference(skipped, [])
        let resumed = try await service.applyStateChange(.init(operation: .resume, automation: paused), lifetime: .init(), now: now)
        let emptyHistory = await service.history(automationID: routine.id)
        expectNoDifference(emptyHistory, []); expectNoDifference(resumed.nextRunAt, nil)
        let fired = await service.fire(events: [try event(message, id: "resumed")], executor: CompositeFixtureExecutor(), now: now)
        expectNoDifference(fired.count, 1)
        _ = try await service.applyStateChange(.init(operation: .delete, automation: resumed), lifetime: .init(), now: now)
        let deleted = await service.fire(events: [try event(message, id: "deleted")], executor: CompositeFixtureExecutor(), now: now)
        expectNoDifference(deleted, [])
        let definitions = await service.list(), retained = await service.history(automationID: routine.id)
        expectNoDifference(definitions, []); expectNoDifference(retained.count, 1)
    }
}
