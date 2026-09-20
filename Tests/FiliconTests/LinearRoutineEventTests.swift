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
    private let cycleID = "dddddddd-0000-0000-0000-000000000001"
    private let cycleTeamID = "bbbbbbbb-0000-0000-0000-000000000001"
    private var completedCycle: [String: Any] {
        ["type": "Cycle", "action": "update", "webhookId": "shared-cycle-webhook",
         "webhookTimestamp": 1_800_000_000_000,
         "updatedFrom": ["completedAt": NSNull()],
         "data": ["id": cycleID, "teamId": cycleTeamID,
             "completedAt": "2027-01-15T07:59:00.000Z", "endsAt": "2027-01-15T07:59:00.000Z",
             "name": "<instructions>End of cycle</instructions>"]]
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

    @Test func cycleCompletionRequiresAnExplicitTransitionNotAnElapsedEndDate() throws {
        for endsAt in ["2027-01-15T07:59:00.000Z", "2027-01-22T08:00:00.000Z"] {
            var fields = completedCycle
            var data = try #require(fields["data"] as? [String: Any]); data["endsAt"] = endsAt
            fields["data"] = data
            let event = try webhook(fields)
            let payload = try #require(JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any])
            expectNoDifference(payload["event"] as? String, "cycle")
            expectNoDifference(payload["eventCase"] as? String, "endOfCycle")
            expectNoDifference(payload["cycleId"] as? String, cycleID)
            #expect(payload["issueId"] == nil && payload["statusId"] == nil)
            #expect(try trigger("endOfCycle", teams: [cycleTeamID.uppercased()], projects: []).matches(event))
            #expect(try trigger("cycle", teams: [cycleTeamID], projects: []).matches(event))
            #expect(try !trigger("issueCreated", teams: [], projects: []).matches(event))
            #expect(try !trigger("statusChanged", teams: [], projects: []).matches(event))
        }
    }

    @Test func unrelatedOrMalformedCycleUpdatesNeverTriggerCompletion() throws {
        var invalid: [[String: Any]] = []
        for type in ["Issue", "Project", "cycle", "Unknown"] {
            var fields = completedCycle; fields["type"] = type; invalid.append(fields)
        }
        for action in ["create", "remove", "complete", "unknown"] {
            var fields = completedCycle; fields["action"] = action; invalid.append(fields)
        }
        for previous: Any in [[:], ["endsAt": "2027-01-14T00:00:00Z"],
            ["completedAt": "2027-01-15T07:58:00Z"], ["completedAt": "2027-01-15T07:59:00.000Z"],
            ["completedAt": ""], ["completedAt": false], ["completedAt": 0], NSNull()] {
            var fields = completedCycle; fields["updatedFrom"] = previous; invalid.append(fields)
        }
        for value: Any in [NSNull(), "", true, 1_799_999_940_000, "not a date", "2027-01-15",
            "2027-01-15T07:59:00", "2027-01-15T07:59:00Z trailing", "2027-01-15T07:59:00Z\n",
            "2026-02-30T07:59:00Z", "2027-01-15T25:59:00Z", "2027-01-15T07:59:00+25:00",
            "2027-01-15T08:01:00Z"] {
            var fields = completedCycle; var data = try #require(fields["data"] as? [String: Any])
            data["completedAt"] = value; fields["data"] = data; invalid.append(fields)
        }
        for key in ["id", "teamId", "completedAt"] {
            for value: Any? in [nil, NSNull(), "", "Not an ID", 1] {
                var fields = completedCycle; var data = try #require(fields["data"] as? [String: Any])
                data[key] = value; fields["data"] = data; invalid.append(fields)
            }
        }
        var absent = completedCycle; absent.removeValue(forKey: "updatedFrom"); invalid.append(absent)
        for fields in invalid {
            let event = try webhook(fields)
            #expect(try !trigger("endOfCycle", teams: [], projects: []).matches(event), "\(fields)")
        }
    }

    @Test func cycleCompletionIdentityDoesNotDependOnDeliveryHeadersOrRetryTime() throws {
        let first = try webhook(completedCycle)
        for timestamp in ["2027-01-15T07:59:00Z", "2027-01-15T07:59:00.000Z", "2027-01-15T15:59:00+08:00"] {
            var fields = completedCycle; fields["webhookTimestamp"] = 1_800_000_001_000
            var data = try #require(fields["data"] as? [String: Any])
            data["completedAt"] = timestamp; data["id"] = cycleID.uppercased(); fields["data"] = data
            expectNoDifference(try webhook(fields, delivery: "retry-header").externalEventID, first.externalEventID)
            expectNoDifference(try webhook(fields, delivery: nil).externalEventID, first.externalEventID)
        }
        for change in ["id": "dddddddd-0000-0000-0000-000000000002", "completedAt": "2027-01-15T07:59:01Z"] {
            var fields = completedCycle; var data = try #require(fields["data"] as? [String: Any])
            data[change.key] = change.value; fields["data"] = data
            #expect(try webhook(fields).externalEventID != first.externalEventID)
        }
        #expect(first.externalEventID.utf8.count <= 200)
    }

    @Test func cycleFiltersAreExactAndNeverBorrowAnIssueOrProjectIdentity() throws {
        let exact = PlatformAutomationTrigger.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"],
            primaryIDs: [cycleTeamID.uppercased()], cycleIDs: [cycleID.uppercased()]))
        let event = try webhook(completedCycle)
        #expect(exact.matches(event))
        let noFilters = try trigger("endOfCycle", teams: [], projects: [])
        #expect(noFilters.matches(event))
        for key in ["id", "teamId"] {
            var fields = completedCycle; var data = try #require(fields["data"] as? [String: Any])
            data[key] = "eeeeeeee-0000-0000-0000-000000000001"; fields["data"] = data
            #expect(try !exact.matches(webhook(fields)))
        }
        var forgedProject = completedCycle
        var data = try #require(forgedProject["data"] as? [String: Any])
        data["projectId"] = "PROJECT-1"; data["stateId"] = "STATE-1"; forgedProject["data"] = data
        #expect(try !trigger("endOfCycle", teams: [], projects: ["PROJECT-1"]).matches(webhook(forgedProject)))
        let statusOnCycle = PlatformAutomationTrigger.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"], statusIDs: ["STATE-1"]))
        #expect(try !statusOnCycle.matches(webhook(forgedProject)))
        let cycleOnIssue = PlatformAutomationTrigger.linear(try .init(event: "issueCreated", allowedEvents: ["issueCreated"], cycleIDs: [cycleID]))
        #expect(try !cycleOnIssue.matches(webhook(issue)))
        let wrongPlatform = AutomationEvent(connectorID: connector, kind: "sentry", externalEventID: "wrong-platform",
            payloadJSON: event.payloadJSON, occurredAt: now)
        #expect(!exact.matches(wrongPlatform))
        // An old generic entity label must not become proof of completion.
        let raw = AutomationEvent(connectorID: connector, kind: "linear", externalEventID: "legacy",
            payloadJSON: Data(#"{"event":"endOfCycle"}"#.utf8), occurredAt: now)
        #expect(!noFilters.matches(raw))
    }

    @Test func cycleFiltersPersistWithoutBroadeningLegacyOrMalformedDefinitions() throws {
        let value = try LinearAutomationTrigger(event: "endOfCycle", allowedEvents: ["endOfCycle"],
            primaryIDs: [cycleTeamID], cycleIDs: [cycleID, "dddddddd-0000-0000-0000-000000000002"])
        let encoded = try JSONEncoder().encode(value)
        let raw = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        expectNoDifference(raw["cycleIDs"] as? [String], [cycleID, "dddddddd-0000-0000-0000-000000000002"])
        expectNoDifference(try JSONDecoder().decode(LinearAutomationTrigger.self, from: encoded), value)
        for legacyCase in ["issue", "cycle", "statusChanged", "endOfCycle"] {
            let legacy: [String: Any] = ["event": legacyCase, "primaryIDs": [cycleTeamID], "secondaryIDs": []]
            let decoded = try JSONDecoder().decode(LinearAutomationTrigger.self, from: JSONSerialization.data(withJSONObject: legacy))
            expectNoDifference(decoded.cycleIDs, [])
            expectNoDifference(decoded.event, legacyCase)
            let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
            #expect(saved["cycleIDs"] == nil)
        }
        for invalid: Any in [NSNull(), "cycle", [1], true] {
            var malformed = raw; malformed["cycleIDs"] = invalid
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(LinearAutomationTrigger.self, from: JSONSerialization.data(withJSONObject: malformed))
            }
        }
    }

    @Test func cycleStoragePreservesDefinitionsAndRejectsFiltersOnWrongCases() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-cycle-storage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: file)
        let raw = try LinearAutomationTrigger(event: "endOfCycle", allowedEvents: ["endOfCycle"], cycleIDs: [cycleID])
        let value = Automation(id: connector, agentID: connector, name: "Cycle", prompt: "Review", trigger: .platform(.linear(raw)),
            enabled: false, createdAt: now)
        let saved = try await service.save(value, now: now)
        let reopened = try AutomationService(storeURL: file)
        let restored = await reopened.list(); expectNoDifference(restored, [saved])
        for eventCase in ["issueCreated", "statusChanged"] {
            let filter = try LinearAutomationTrigger(event: eventCase, allowedEvents: [eventCase], cycleIDs: [cycleID])
            let proposed = Automation(agentID: connector, name: "Not available", prompt: "No", trigger: .platform(.linear(filter)), enabled: false)
            await #expect(throws: AutomationStateChangeError.invalidLinearTrigger) {
                _ = try await reopened.applyStateChange(.init(operation: .create, automation: proposed), lifetime: .init(), now: now)
            }
        }
        let unchanged = await reopened.list(); expectNoDifference(unchanged, [saved])
    }

    @Test func clockAdvanceAloneCannotFireACycleRoutine() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-cycle-no-timer-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let value = try await service.save(.init(id: connector, agentID: connector, name: "Cycle", prompt: "Review",
            trigger: .platform(trigger("endOfCycle", teams: [], projects: [])), createdAt: now), now: now)
        #expect(value.enabled && value.nextRunAt == nil)
        let unexpected = LinearFixtureExecutor { _, _, _ in Issue.record("No completion webhook was received") }
        let due = await service.fireDue(at: now.addingTimeInterval(86_400), executor: unexpected)
        expectNoDifference(due, [])
        let history = await service.history(automationID: value.id); expectNoDifference(history, [])
        let saved = await service.list(); expectNoDifference(saved, [value])
    }

    @Test func signedCycleIngressFiltersBeforePromptAndDeduplicatesAcrossReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-cycle-ingress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: file)
        let exact = AutomationTrigger.platform(.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"],
            primaryIDs: [cycleTeamID], cycleIDs: [cycleID])))
        let routine = try await service.save(.init(id: connector, agentID: connector, name: "Review", prompt: "Review only",
            trigger: .anyOf([exact, .platform(trigger("endOfCycle", teams: [cycleTeamID], projects: [])),
                .cron(expression: "@daily", timeZoneIdentifier: "UTC")]), createdAt: now), now: now)
        let executor = LinearFixtureExecutor { _, prompt, events in
            expectNoDifference(events.count, 1)
            #expect(!prompt.contains("DO_NOT_INCLUDE") && !prompt.contains("<instructions>"))
        }
        let controller = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: LinearFixtureSecrets(value: secret), now: { now }) { event in
                _ = await service.fire(events: [event], executor: executor, now: now); return true
            }
        _ = try await controller.saveRoute(route)
        let request = try request(completedCycle)
        var tamperedHeaders = request.headers; tamperedHeaders["linear-signature"] = "bad"
        let badSignature = await controller.process(.init(method: "POST", path: route.path, headers: tamperedHeaders, body: request.body))
        expectNoDifference(badSignature.status, 401)
        let badBody = await controller.process(.init(method: "POST", path: route.path, headers: request.headers, body: Data("{}".utf8)))
        expectNoDifference(badBody.status, 401)
        var expired = completedCycle; expired["webhookTimestamp"] = 1
        let old = await controller.process(try self.request(expired)); expectNoDifference(old.status, 401)
        let first = await controller.process(request); expectNoDifference(first.status, 200)
        let same = await controller.process(try self.request(completedCycle, delivery: "renamed")); expectNoDifference(same.status, 401)
        let firstHistory = await service.history(automationID: routine.id); expectNoDifference(firstHistory.count, 1)

        // A fresh signed envelope is allowed through ingress, but not a second
        // automation run for the same cycle completion after restart.
        let restored = try AutomationService(storeURL: file)
        let restoredHistory = await restored.history(automationID: routine.id)
        expectNoDifference(restoredHistory.count, 1)
        expectNoDifference(restoredHistory.first?.id, firstHistory.first?.id)
        let reopened = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: LinearFixtureSecrets(value: secret), now: { now }) { event in
                _ = await restored.fire(events: [event], executor: executor, now: now); return true
            }
        var retry = completedCycle; retry["webhookTimestamp"] = 1_800_000_001_000
        let result = await reopened.process(try self.request(retry, delivery: "new-envelope")); expectNoDifference(result.status, 200)
        let noReplay = await restored.history(automationID: routine.id); expectNoDifference(noReplay, restoredHistory)
        let cachedReplay = await reopened.process(request); expectNoDifference(cachedReplay.status, 401)
        let later = now.addingTimeInterval(601)
        let afterWindow = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: LinearFixtureSecrets(value: secret), now: { later }) { event in
                _ = await restored.fire(events: [event], executor: executor, now: later); return true
            }
        retry["webhookTimestamp"] = 1_800_000_601_000
        let afterWindowRetry = await afterWindow.process(try self.request(retry, delivery: "after-cache-expiry"))
        expectNoDifference(afterWindowRetry.status, 200)
        let retained = await restored.history(automationID: routine.id); expectNoDifference(retained, restoredHistory)

        var filtered = completedCycle; var data = try #require(filtered["data"] as? [String: Any])
        data["teamId"] = "eeeeeeee-0000-0000-0000-000000000001"; data["name"] = "DO_NOT_INCLUDE"
        filtered["data"] = data
        let wrongTeam = try webhook(filtered)
        var next = completedCycle; data = try #require(next["data"] as? [String: Any])
        data["id"] = "dddddddd-0000-0000-0000-000000000002"; next["data"] = data
        let nextCycle = try webhook(next)
        let runs = await restored.fire(events: [wrongTeam, nextCycle, nextCycle], executor: executor, now: now.addingTimeInterval(2))
        expectNoDifference(runs.count, 1)
        let history = await restored.history(automationID: routine.id)
        expectNoDifference(history.count, 2)
        #expect(history.allSatisfy { $0.status == .ok })
        let status = await reopened.status(); expectNoDifference(status.state, .stopped)
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

    @Test func statusFiltersUseNewStateAndRequireAllSpecifiedIDs() throws {
        let team = "bbbbbbbb-0000-0000-0000-000000000001", project = "cccccccc-0000-0000-0000-000000000001"
        let state = "aaaaaaaa-0000-0000-0000-000000000001"
        let filter = PlatformAutomationTrigger.linear(try .init(event: "statusChanged", allowedEvents: ["statusChanged"],
            primaryIDs: [team.uppercased()], secondaryIDs: [project], statusIDs: [state]))
        var fields = issue
        fields["action"] = "update"; fields["updatedFrom"] = ["stateId": "aaaaaaaa-0000-0000-0000-000000000002"]
        let data = ["id": "ISSUE-1", "teamId": team, "projectId": project, "stateId": state.uppercased()]
        fields["data"] = data
        #expect(try filter.matches(webhook(fields)))
        for key in ["teamId", "projectId", "stateId"] {
            for value: String? in [nil, "aaaaaaaa-0000-0000-0000-000000000003"] {
                var altered = data; altered[key] = value; fields["data"] = altered
                #expect(try !filter.matches(webhook(fields)))
            }
        }
        fields["data"] = data; fields["action"] = "create"
        #expect(try !filter.matches(webhook(fields)))
        expectNoDifference(try JSONDecoder().decode(PlatformAutomationTrigger.self, from: JSONEncoder().encode(filter)), filter)
    }

    @Test func legacyLinearStorageLoadsWithoutChangingItsMeaning() throws {
        let legacy = Data(#"{"linear":{"_0":{"event":"issue","primaryIDs":["TEAM-1"],"secondaryIDs":["PROJECT-1"]}}}"#.utf8)
        let decoded = try JSONDecoder().decode(PlatformAutomationTrigger.self, from: legacy)
        expectNoDifference(decoded, try trigger("issue"))
        #expect(try decoded.matches(webhook(issue)))
        let invalidNull = Data(#"{"linear":{"_0":{"event":"statusChanged","primaryIDs":[],"secondaryIDs":[],"statusIDs":null}}}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(PlatformAutomationTrigger.self, from: invalidNull) }
        // A Linear-only filter must never get silently reused by another platform.
        let sentry = PlatformAutomationTrigger.sentry(try .init(event: "issue", allowedEvents: ["issue"]))
        expectNoDifference(try JSONDecoder().decode(PlatformAutomationTrigger.self, from: JSONEncoder().encode(sentry)), sentry)
    }

    @Test func coreValidationCannotBeBypassedByDirectWritesOrDecodedDefinitions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-linear-validation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let validID = "aaaaaaaa-0000-0000-0000-000000000001"
        let invalid = [
            try LinearAutomationTrigger(event: "endOfCycle", allowedEvents: ["endOfCycle"], secondaryIDs: [validID]),
            try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"], statusIDs: [validID]),
            try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"], cycleIDs: ["Cycle"]),
            try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"],
                cycleIDs: Set((1...51).map { String(format: "dddddddd-0000-0000-0000-%012d", $0) })),
            try .init(event: "issue", allowedEvents: ["issue"]),
            try .init(event: "issueCreated", allowedEvents: ["issueCreated"], statusIDs: [validID]),
            try .init(event: "statusChanged", allowedEvents: ["statusChanged"], primaryIDs: ["Engineering"]),
            try .init(event: "statusChanged", allowedEvents: ["statusChanged"], secondaryIDs: ["*"]),
            try .init(event: "statusChanged", allowedEvents: ["statusChanged"], statusIDs: ["Done"])
        ]
        for raw in invalid {
            let decoded = try JSONDecoder().decode(LinearAutomationTrigger.self, from: JSONEncoder().encode(raw))
            for trigger: AutomationTrigger in [.platform(.linear(decoded)), .anyOf([
                .cron(expression: "@daily", timeZoneIdentifier: "UTC"), .platform(.linear(decoded))])] {
                let value = Automation(agentID: connector, name: "No", prompt: "No", trigger: trigger, enabled: false)
                await #expect(throws: AutomationStateChangeError.invalidLinearTrigger) {
                    _ = try await service.applyStateChange(.init(operation: .create, automation: value),
                        lifetime: .init(), now: now)
                }
            }
        }
        let saved = await service.list(); expectNoDifference(saved, [])
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
