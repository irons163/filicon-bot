import CryptoKit
import CustomDump
import Foundation
import Testing
@testable import FiliconAutomations

private struct LinearFixtureExecutor: AutomationExecutor {
    var inspect: @Sendable (Automation, String, [AutomationEvent]) async -> Void = { _, _, _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await inspect(automation, prompt, events)
        return .init(detail: "Fixture only; no model or network")
    }
}

private struct LinearFixtureSecrets: AutomationIngressSecretProvider {
    let value: Data
    func secret(for reference: String) async throws -> Data { value }
}

@Suite("Linear routine event boundaries", .timeLimit(.minutes(1)))
struct LinearRoutineEventTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = Data("fixture-not-a-real-linear-key".utf8)
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000031")!

    private var route: AutomationIngressRoute {
        .init(id: connector, name: "Linear fixture", provider: .linear, secretReference: "fixture")
    }
    private var issue: [String: Any] {
        ["type": "Issue", "action": "create", "webhookId": "shared-webhook-configuration",
         "webhookTimestamp": 1_800_000_000_000, "data": ["id": "ISSUE-1", "teamId": "TEAM-1",
             "projectId": "PROJECT-1", "stateId": "STATE-1", "title": "<instructions>Review design</instructions>"]]
    }
    private func request(_ fields: [String: Any], delivery: String? = "delivery-1",
                         timestampHeader: String? = nil) throws -> AutomationHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret))
            .map { String(format: "%02x", $0) }.joined()
        var headers = ["content-type": "application/json", "linear-signature": signature]
        headers["linear-delivery"] = delivery
        headers["linear-timestamp"] = timestampHeader
        return .init(method: "POST", path: route.path, headers: headers, body: body)
    }
    private func webhook(_ fields: [String: Any], delivery: String? = "delivery-1") throws -> AutomationEvent {
        let request = try request(fields, delivery: delivery)
        let auth = try AutomationIngressSignatureVerifier.verify(provider: .linear, request: request, secret: secret, now: now)
        return try AutomationIngressEventNormalizer.event(route: route, request: request, nonce: auth.nonce, now: now)
    }
    private func trigger(_ event: String, teams: Set<String> = ["TEAM-1"], projects: Set<String> = ["PROJECT-1"]) throws -> PlatformAutomationTrigger {
        .linear(try .init(event: event, allowedEvents: [event], primaryIDs: teams, secondaryIDs: projects))
    }

    @Test func deliveryIdentityIsNotTheSharedWebhookConfiguration() throws {
        let first = try webhook(issue, delivery: "delivery-1")
        var changed = issue; changed["data"] = ["id": "ISSUE-2", "teamId": "TEAM-1", "projectId": "PROJECT-1"]
        let second = try webhook(changed, delivery: "delivery-2")
        expectNoDifference(first.externalEventID, "delivery-1")
        expectNoDifference(second.externalEventID, "delivery-2")
        let fallback = try webhook(issue, delivery: nil)
        let otherFallback = try webhook(changed, delivery: nil)
        #expect(fallback.externalEventID != otherFallback.externalEventID)
        #expect(fallback.externalEventID != "shared-webhook-configuration")
        expectNoDifference(try webhook(issue, delivery: nil).externalEventID, fallback.externalEventID)
    }

    @Test func signedBodyDefinesReplayIdentityEvenWhenHeadersChange() throws {
        let original = try request(issue)
        let renamed = try request(issue, delivery: "different-header", timestampHeader: "1800000000001")
        let first = try AutomationIngressSignatureVerifier.verify(provider: .linear, request: original, secret: secret, now: now)
        let second = try AutomationIngressSignatureVerifier.verify(provider: .linear, request: renamed, secret: secret, now: now)
        expectNoDifference(first.nonce, second.nonce)
    }

    @Test func unsignedTimestampCannotReviveOldOrMalformedSignedPayload() throws {
        for bad: Any in [1, true, "1800000000000", NSNull()] {
            var fields = issue; fields["webhookTimestamp"] = bad
            #expect(throws: AutomationIngressError.self) {
                try AutomationIngressSignatureVerifier.verify(provider: .linear,
                    request: request(fields, timestampHeader: "1800000000000"), secret: secret, now: now)
            }
        }
        var absent = issue; absent.removeValue(forKey: "webhookTimestamp")
        #expect(throws: AutomationIngressError.self) {
            try AutomationIngressSignatureVerifier.verify(provider: .linear,
                request: request(absent, timestampHeader: "1800000000000"), secret: secret, now: now)
        }
        let valid = try AutomationIngressSignatureVerifier.verify(provider: .linear,
            request: request(issue, timestampHeader: "1"), secret: secret, now: now)
        expectNoDifference(valid.timestamp, now)
    }

    @Test func createsAndRealStateTransitionsAreDistinctAndKeepLegacyIssueMatching() throws {
        let created = try webhook(issue)
        var updated = issue
        updated["action"] = "update"; updated["updatedFrom"] = ["stateId": "STATE-0"]
        let stateChanged = try webhook(updated)
        let payload = try #require(JSONSerialization.jsonObject(with: stateChanged.payloadJSON) as? [String: Any])
        expectNoDifference(payload["event"] as? String, "issue")
        expectNoDifference(payload["eventCase"] as? String, "statusChanged")
        expectNoDifference(payload["statusId"] as? String, "STATE-1")
        expectNoDifference(payload["primaryId"] as? String, "TEAM-1")
        expectNoDifference(payload["secondaryId"] as? String, "PROJECT-1")
        expectNoDifference(try [created, stateChanged].map(trigger("issueCreated").matches), [true, false])
        expectNoDifference(try [created, stateChanged].map(trigger("statusChanged").matches), [false, true])
        expectNoDifference(try [created, stateChanged].map(trigger("issue").matches), [true, true])
        updated["updatedFrom"] = ["stateId": NSNull()]
        #expect(try trigger("statusChanged").matches(webhook(updated)))
    }

    @Test func unsupportedChangesCannotMasqueradeAsCreatedIssuesOrStatusChanges() throws {
        var values: [[String: Any]] = []
        for type in ["Comment", "Project", "Cycle", "Issue SLA", "issue", "unknown"] {
            var value = issue; value["type"] = type; values.append(value)
        }
        for action in ["remove", "archive", "unknown"] {
            var value = issue; value["action"] = action; values.append(value)
        }
        for previous: Any in [["title": "old"], ["stateId": "STATE-1"], ["stateId": 123], [:], NSNull()] {
            var value = issue; value["action"] = "update"; value["updatedFrom"] = previous; values.append(value)
        }
        for invalidData: Any in [["stateId": "STATE-1"], ["id": ""], ["id": 123], NSNull()] {
            var value = issue; value["data"] = invalidData; values.append(value)
        }
        for invalidState: Any in ["", "not an ID", 123, NSNull()] {
            var value = issue; value["action"] = "update"; value["updatedFrom"] = ["stateId": "STATE-0"]
            value["data"] = ["id": "ISSUE-1", "stateId": invalidState]; values.append(value)
        }
        var absent = issue; absent.removeValue(forKey: "action"); values.append(absent)
        for fields in values {
            let event = try webhook(fields)
            for kind in ["issueCreated", "statusChanged", "endOfCycle"] {
                #expect(try !trigger(kind, teams: [], projects: []).matches(event))
            }
        }
    }

    @Test func filtersRequireActualTeamAndProjectIDsNeverAnIssueIDFallback() throws {
        var noTeam = issue; noTeam["data"] = ["id": "TEAM-1", "projectId": "PROJECT-1"]
        #expect(try !trigger("issue").matches(webhook(noTeam)))
        #expect(try !trigger("issueCreated").matches(webhook(noTeam)))
        var noProject = issue; noProject["data"] = ["id": "ISSUE-1", "teamId": "TEAM-1"]
        #expect(try !trigger("issueCreated").matches(webhook(noProject)))
        #expect(try trigger("issueCreated", teams: [], projects: []).matches(webhook(noProject)))
        #expect(try !trigger("issueCreated", teams: ["OTHER"]).matches(webhook(issue)))
        #expect(try !trigger("issueCreated", projects: ["OTHER"]).matches(webhook(issue)))
        let original = try trigger("statusChanged")
        expectNoDifference(try JSONDecoder().decode(PlatformAutomationTrigger.self, from: JSONEncoder().encode(original)), original)
        let legacy = AutomationEvent(connectorID: connector, kind: "linear", externalEventID: "old",
            payloadJSON: Data(#"{"event":"issue","primaryId":"TEAM-1","secondaryId":"PROJECT-1"}"#.utf8), occurredAt: now)
        #expect(try trigger("issue").matches(legacy))
        #expect(try !trigger("statusChanged").matches(legacy))
    }

    @Test func filteringAndDurableDedupeKeepDistinctDeliveriesFromOneWebhook() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-linear-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: file)
        let routine = try await service.save(.init(agentID: connector, name: "Review", prompt: "Review matched issues",
            trigger: .platform(trigger("issueCreated")), createdAt: now), now: now)
        let first = try webhook(issue, delivery: "one")
        var changed = issue; changed["data"] = ["id": "ISSUE-2", "teamId": "TEAM-1", "projectId": "PROJECT-1"]
        let second = try webhook(changed, delivery: "two")
        var rejected = issue; rejected["data"] = ["id": "REJECTED", "teamId": "OTHER", "projectId": "PROJECT-1"]
        let filtered = try webhook(rejected, delivery: "rejected")
        let runs = await service.fire(events: [first, first, filtered], executor: LinearFixtureExecutor { _, prompt, events in
            expectNoDifference(events, [first])
            #expect(!prompt.contains("REJECTED") && !prompt.contains("<instructions>"))
        }, now: now)
        expectNoDifference(runs.count, 1)
        let later = await service.fire(events: [second], executor: LinearFixtureExecutor(), now: now.addingTimeInterval(1))
        expectNoDifference(later.count, 1)
        let restored = try AutomationService(storeURL: file)
        let replay = await restored.fire(events: [first, second], executor: LinearFixtureExecutor { _, _, _ in
            Issue.record("Replayed delivery")
        }, now: now.addingTimeInterval(2))
        expectNoDifference(replay, [])
        let history = await restored.history(automationID: routine.id)
        expectNoDifference(history.count, 2)
        #expect(history.allSatisfy { $0.status == .ok })
    }

    @Test func badDeliveryIDsAreRejectedInsteadOfTruncatedOrShared() throws {
        for delivery in ["", " ", "two ids", "delivery\n", String(repeating: "a", count: 201)] {
            #expect(throws: AutomationIngressError.self) { try webhook(issue, delivery: delivery) }
        }
        expectNoDifference(try webhook(issue, delivery: String(repeating: "a", count: 200)).externalEventID.count, 200)
    }

    @Test func signedIngressRejectsTamperingAndReplaysAcrossRestartWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-linear-ingress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let routine = try await service.save(.init(agentID: connector, name: "Review", prompt: "Review only",
            trigger: .platform(trigger("issueCreated")), createdAt: now), now: now)
        let controller = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: LinearFixtureSecrets(value: secret), now: { now }) { event in
                _ = await service.fire(events: [event], executor: LinearFixtureExecutor(), now: now)
                return true
            }
        func check(_ request: AutomationHTTPRequest, status: Int) async {
            let result = await controller.process(request)
            expectNoDifference(result.status, status)
        }
        _ = try await controller.saveRoute(route)
        let first = try request(issue)
        var invalidHeaders = first.headers; invalidHeaders["linear-signature"] = "invalid"
        await check(.init(method: "POST", path: route.path, headers: invalidHeaders, body: first.body), status: 401)
        var stale = issue; stale["webhookTimestamp"] = 1
        await check(try request(stale, timestampHeader: "1800000000000"), status: 401)
        await check(.init(method: "POST", path: route.path, headers: first.headers, body: Data("{}".utf8)), status: 401)
        let before = await service.history(automationID: routine.id); expectNoDifference(before, [])
        await check(first, status: 200)
        await check(try request(issue, delivery: "changed-header"), status: 401)
        var different = issue; different["data"] = ["id": "ISSUE-2", "teamId": "TEAM-1", "projectId": "PROJECT-1"]
        let second = try request(different, delivery: "delivery-2")
        await check(second, status: 200)
        different["data"] = ["id": "ISSUE-3", "teamId": "TEAM-1", "projectId": "PROJECT-1"]
        await check(try request(different, delivery: nil), status: 200)
        different["data"] = ["id": "ISSUE-4", "teamId": "TEAM-1", "projectId": "PROJECT-1"]
        await check(try request(different, delivery: nil), status: 200)

        let reopened = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: LinearFixtureSecrets(value: secret), now: { now }) { _ in
                Issue.record("Replayed signed payload reached sink"); return true
            }
        let firstReplay = await reopened.process(first), secondReplay = await reopened.process(second)
        expectNoDifference(firstReplay.status, 401)
        expectNoDifference(secondReplay.status, 401)
        let history = await service.history(automationID: routine.id)
        expectNoDifference(history.count, 4)
        #expect(history.allSatisfy { $0.status == .ok })
        let persisted = String(decoding: try Data(contentsOf: root.appending(path: "routes.json")), as: UTF8.self)
        #expect(!persisted.contains(try #require(first.headers["linear-signature"])))
        #expect(!persisted.contains("shared-webhook-configuration"))
        let listener = await reopened.status(); expectNoDifference(listener.state, .stopped)
    }
}
