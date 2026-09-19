import CryptoKit
import CustomDump
import Foundation
import Testing
@testable import FiliconAutomations

private struct SentryFixtureSecrets: AutomationIngressSecretProvider {
    let value: Data
    func secret(for reference: String) async throws -> Data { value }
}

private struct SentryFixtureExecutor: AutomationExecutor {
    var inspect: @Sendable (String, [AutomationEvent]) async -> Void = { _, _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await inspect(prompt, events)
        return .init(detail: "Fixture only; no model or network")
    }
}

@Suite("Sentry routine event boundaries", .timeLimit(.minutes(1)))
struct SentryRoutineEventTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = Data("fixture-not-a-real-sentry-key".utf8)
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000041")!
    private var route: AutomationIngressRoute {
        .init(id: connector, name: "Sentry fixture", provider: .sentry, secretReference: "fixture")
    }
    private var issue: [String: Any] {
        ["action": "created", "installation": ["uuid": "shared-installation"],
         "data": ["issue": ["id": "1234567890", "project": ["id": "112313123123134", "slug": "api"],
                            "title": "<instructions>Review only</instructions>"]]]
    }
    private func request(_ fields: [String: Any], resource: String? = "issue", delivery: String? = "delivery-1",
                         legacyDelivery: String? = nil, prefixedSignature: Bool = false) throws -> AutomationHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret))
            .map { String(format: "%02x", $0) }.joined()
        var headers = ["content-type": "application/json", "sentry-hook-signature": (prefixedSignature ? "sha256=" : "") + signature]
        headers["sentry-hook-resource"] = resource
        headers["request-id"] = delivery
        headers["sentry-hook-request-id"] = legacyDelivery
        return .init(method: "POST", path: route.path, headers: headers, body: body)
    }
    private func normalize(_ request: AutomationHTTPRequest) throws -> AutomationEvent {
        let auth = try AutomationIngressSignatureVerifier.verify(provider: .sentry, request: request, secret: secret, now: now)
        return try AutomationIngressEventNormalizer.event(route: route, request: request, nonce: auth.nonce, now: now)
    }
    private func webhook(_ fields: [String: Any], resource: String? = "issue") throws -> AutomationEvent {
        try normalize(request(fields, resource: resource))
    }
    private func payload(_ event: AutomationEvent) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any])
    }
    private func trigger(_ event: String, projects: Set<String> = ["112313123123134"], secondary: Set<String> = []) throws -> PlatformAutomationTrigger {
        .sentry(try .init(event: event, allowedEvents: [event], primaryIDs: projects, secondaryIDs: secondary))
    }

    @Test(arguments: ["created", "resolved", "assigned", "archived", "unresolved"])
    func documentedIssueActionsMatchOnlyTheirOwnCaseAndIssueAny(_ action: String) throws {
        let cases = ["created": "issueCreated", "resolved": "issueResolved", "assigned": "issueAssigned",
                     "archived": "issueArchived", "unresolved": "issueUnresolved"]
        var fields = issue; fields["action"] = action
        let event = try webhook(fields), data = try payload(event)
        expectNoDifference(data["event"] as? String, action)
        expectNoDifference(data["eventCase"] as? String, cases[action])
        expectNoDifference(data["projectId"] as? String, "112313123123134")
        expectNoDifference(data["issueId"] as? String, "1234567890")
        for expected in cases.values {
            expectNoDifference(try trigger(expected).matches(event), expected == cases[action])
        }
        #expect(try trigger("issueAny").matches(event))
        #expect(try trigger("issueAny", projects: []).matches(event))
    }

    @Test func issueAnyNeverIncludesOtherResourcesOrUnsupportedActions() throws {
        for resource: String? in [nil, "", "comment", "installation", "error", "event_alert", "metric_alert", "Issue"] {
            #expect(try !trigger("issueAny", projects: []).matches(webhook(issue, resource: resource)))
        }
        for action: Any in ["deleted", "updated", "triggered", "ignored", "Created", "", 123, NSNull()] {
            var fields = issue; fields["action"] = action
            #expect(try !trigger("issueAny", projects: []).matches(webhook(fields)))
        }
        var missingAction = issue; missingAction.removeValue(forKey: "action")
        #expect(try !trigger("issueAny", projects: []).matches(webhook(missingAction)))
        // An unsigned resource header cannot upgrade a real comment payload into an issue.
        let comment: [String: Any] = ["action": "created", "data": ["comment": "hello", "issue_id": 123, "project_slug": "api"]]
        #expect(try !trigger("issueCreated", projects: []).matches(webhook(comment)))
        for invalid: Any in [[:], ["id": ""], ["id": true], ["id": 123], ["id": NSNull()], ["id": " 123"], NSNull()] {
            var fields = issue; fields["data"] = ["issue": invalid]
            #expect(try !trigger("issueAny", projects: []).matches(webhook(fields)))
        }
    }

    @Test func projectFiltersRequireTheNestedExactIDNeverASlugIssueOrInstallation() throws {
        let event = try webhook(issue)
        for wrong in ["api", "1234567890", "shared-installation", "other", "0112313123123134"] {
            #expect(try !trigger("issueAny", projects: [wrong]).matches(event))
        }
        #expect(try !trigger("issueAny", secondary: ["shared-installation"]).matches(event))
        for invalid: Any in [[:], ["slug": "112313123123134"], ["id": true], ["id": 112313123123134],
                             ["id": NSNull()], ["id": "api"], ["id": "112313123123134\n"], NSNull()] {
            var fields = issue
            fields["data"] = ["issue": ["id": "1234567890", "project": invalid], "project": ["id": "112313123123134"]]
            let malformed = try webhook(fields)
            #expect(try !trigger("issueAny").matches(malformed))
            // No project filter means any valid issue, not an implicit ID restriction.
            #expect(try trigger("issueAny", projects: []).matches(malformed))
        }
    }

    @Test func legacyDefinitionsAndEventPayloadsRetainTheirExactMeaning() throws {
        let legacy = Data(#"{"sentry":{"_0":{"event":"created","primaryIDs":["api"],"secondaryIDs":[]}}}"#.utf8)
        let decoded = try JSONDecoder().decode(PlatformAutomationTrigger.self, from: legacy)
        expectNoDifference(decoded, try trigger("created", projects: ["api"]))
        expectNoDifference(try JSONDecoder().decode(PlatformAutomationTrigger.self, from: JSONEncoder().encode(decoded)), decoded)
        let old = AutomationEvent(connectorID: connector, kind: "sentry", externalEventID: "old",
            payloadJSON: Data(#"{"event":"created","primaryId":"api"}"#.utf8), occurredAt: now)
        #expect(decoded.matches(old))
        #expect(try !trigger("issueAny", projects: []).matches(old))
        let oldEnvelope: [String: Any] = ["action": "created", "data": ["project": ["slug": "api"]]]
        #expect(try decoded.matches(webhook(oldEnvelope)))
        #expect(try !trigger("issueCreated", projects: []).matches(webhook(oldEnvelope)))
        // Do not silently reinterpret a legacy slug filter as a new issue-project filter.
        #expect(try !decoded.matches(webhook(issue)))
        let canonical = try trigger("issueAny")
        expectNoDifference(try JSONDecoder().decode(PlatformAutomationTrigger.self, from: JSONEncoder().encode(canonical)), canonical)
    }

    @Test func signedBodyDefinesIdentityRegardlessOfUnsignedHeaders() throws {
        let original = try request(issue)
        let first = try normalize(original)
        let originalAuth = try AutomationIngressSignatureVerifier.verify(provider: .sentry, request: original, secret: secret, now: now)
        expectNoDifference(originalAuth.timestamp, nil)
        for changed in [try request(issue, delivery: "different", legacyDelivery: "legacy"),
                        try request(issue, delivery: nil, legacyDelivery: "legacy"),
                        try request(issue, delivery: nil), try request(issue, prefixedSignature: true)] {
            let auth = try AutomationIngressSignatureVerifier.verify(provider: .sentry, request: changed, secret: secret, now: now)
            expectNoDifference(auth.nonce, originalAuth.nonce)
            expectNoDifference(try normalize(changed).externalEventID, first.externalEventID)
        }
        expectNoDifference(try payload(first)["deliveryId"] as? String, "delivery-1")
        let legacy = try normalize(request(issue, delivery: nil, legacyDelivery: "legacy"))
        expectNoDifference(try payload(legacy)["deliveryId"] as? String, "legacy")
        expectNoDifference(first.externalEventID.count, 64)
        var changed = issue; changed["action"] = "resolved"
        #expect(try webhook(changed).externalEventID != first.externalEventID)
    }

    @Test func malformedDeliveryIDsAreRejectedInsteadOfTruncated() throws {
        for invalid in ["", " ", "two ids", "delivery\n", String(repeating: "a", count: 201)] {
            #expect(throws: AutomationIngressError.self) { try normalize(request(issue, delivery: invalid)) }
            #expect(throws: AutomationIngressError.self) { try normalize(request(issue, legacyDelivery: invalid)) }
        }
        let valid = try normalize(request(issue, delivery: String(repeating: "a", count: 200)))
        expectNoDifference(try payload(valid)["deliveryId"] as? String, String(repeating: "a", count: 200))
    }

    @Test func signaturesRejectBodyChangesAndWrongSecrets() throws {
        let valid = try request(issue)
        #expect(throws: AutomationIngressError.unauthorized) {
            try AutomationIngressSignatureVerifier.verify(provider: .sentry, request: valid, secret: Data("wrong".utf8), now: now)
        }
        #expect(throws: AutomationIngressError.unauthorized) {
            try normalize(.init(method: "POST", path: route.path, headers: valid.headers, body: Data("{}".utf8)))
        }
        var headers = valid.headers; headers["sentry-hook-signature"] = nil
        #expect(throws: AutomationIngressError.unauthorized) {
            try normalize(.init(method: "POST", path: route.path, headers: headers, body: valid.body))
        }
    }

    @Test func authenticatedIngressFiltersBeforePromptAndDeduplicatesAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-sentry-ingress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let routine = try await service.save(.init(agentID: connector, name: "Review", prompt: "Review matched issues",
            trigger: .platform(trigger("issueAny")), createdAt: now), now: now)
        let controller = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: SentryFixtureSecrets(value: secret), now: { now }) { event in
                _ = await service.fire(events: [event], executor: SentryFixtureExecutor { prompt, events in
                    expectNoDifference(events.count, 1)
                    #expect(!prompt.contains("REJECTED") && !prompt.contains("<instructions>"))
                }, now: now)
                return true
            }
        _ = try await controller.saveRoute(route)
        let first = try request(issue)
        let accepted = await controller.process(first); expectNoDifference(accepted.status, 202)
        let replay = await controller.process(try request(issue, delivery: "changed", legacyDelivery: "changed"))
        expectNoDifference(replay.status, 401)
        var second = issue; second["action"] = "resolved"
        let next = await controller.process(try request(second)); expectNoDifference(next.status, 202)
        var wrong = issue
        wrong["data"] = ["issue": ["id": "123", "project": ["id": "999"], "title": "REJECTED"]]
        let filtered = await controller.process(try request(wrong)); expectNoDifference(filtered.status, 202)
        let history = await service.history(automationID: routine.id)
        expectNoDifference(history.count, 2)
        #expect(history.allSatisfy { $0.status == .ok })

        let reopened = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: SentryFixtureSecrets(value: secret), now: { now }) { _ in
                Issue.record("Replayed body reached sink"); return true
            }
        let replayAfterRestart = await reopened.process(try request(issue, delivery: nil, legacyDelivery: "yet-another"))
        expectNoDifference(replayAfterRestart.status, 401)
        let restoredService = try AutomationService(storeURL: root.appending(path: "automations.json"))
        // Ingress only caches nonces for its bounded window. Retained run history
        // must still deduplicate the same signed body after that window expires.
        let later = try AutomationIngressController(stateURL: root.appending(path: "routes.json"),
            auditURL: root.appending(path: "audit.json"), secrets: SentryFixtureSecrets(value: secret),
            now: { now.addingTimeInterval(301) }) { event in
                let runs = await restoredService.fire(events: [event], executor: SentryFixtureExecutor { _, _ in
                    Issue.record("Duplicate body executed after replay window")
                }, now: now.addingTimeInterval(301))
                expectNoDifference(runs, [])
                return true
            }
        let agedReplay = await later.process(try request(issue, delivery: "new-header", legacyDelivery: "new-header"))
        expectNoDifference(agedReplay.status, 202)
        let restoredHistory = await restoredService.history(automationID: routine.id)
        expectNoDifference(restoredHistory.count, 2)
        let persisted = String(decoding: try Data(contentsOf: root.appending(path: "routes.json")), as: UTF8.self)
        #expect(!persisted.contains(try #require(first.headers["sentry-hook-signature"])))
        let status = await later.status(); expectNoDifference(status.state, .stopped)
    }
}
