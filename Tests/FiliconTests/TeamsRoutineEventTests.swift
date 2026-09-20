import CryptoKit
import CustomDump
import Foundation
import Testing
@testable import FiliconAutomations

private struct TeamsFixtureSecrets: AutomationIngressSecretProvider {
    let value: Data
    func secret(for reference: String) async throws -> Data { value }
}

private struct TeamsFixtureExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        expectNoDifference(events.count, 1)
        #expect(!prompt.contains("REJECTED"))
        return .init(detail: "Fixture only; no model or network")
    }
}

@Suite("Teams outgoing event boundaries", .timeLimit(.minutes(1)))
struct TeamsRoutineEventTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let secret = Data("fixture-not-a-real-teams-key".utf8)
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000043")!
    private let tenant = "aaaaaaaa-0000-0000-0000-000000000001"
    private let graphTeam = "bbbbbbbb-0000-0000-0000-000000000001"
    private let botTeam = "19:fixture-team@thread.tacv2"
    private let channel = "19:fixture-channel@thread.tacv2"
    private var route: AutomationIngressRoute {
        .init(id: connector, name: "Teams fixture", provider: .microsoftTeams, secretReference: "fixture")
    }
    private var message: [String: Any] {
        ["type": "message", "id": "1800000000000", "channelId": "msteams", "text": "DEPLOY 測試",
         "from": ["id": "29:fixture-user", "aadObjectId": "cccccccc-0000-0000-0000-000000000001"],
         "conversation": ["id": "19:fixture-conversation", "conversationType": "channel"],
         "channelData": ["tenant": ["id": tenant], "team": ["id": botTeam, "aadGroupId": graphTeam],
                         "channel": ["id": channel]]]
    }
    private func request(_ fields: [String: Any]) throws -> AutomationHTTPRequest {
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let signature = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret))).base64EncodedString()
        return .init(method: "POST", path: route.path, headers: ["content-type": "application/json", "authorization": "HMAC " + signature], body: body)
    }
    private func normalize(_ fields: [String: Any]) throws -> AutomationEvent {
        let request = try request(fields)
        let authentication = try AutomationIngressSignatureVerifier.verify(provider: .microsoftTeams, request: request, secret: secret, now: now)
        return try AutomationIngressEventNormalizer.event(route: route, request: request, nonce: authentication.nonce, now: now)
    }
    private func payload(_ event: AutomationEvent) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any])
    }
    private func trigger(team: String? = nil, tenantID: String? = nil, channels: Set<String>? = nil,
                         text: String? = "deploy", regex: Bool = false, blockUnauthenticated: Bool = false) throws -> PlatformAutomationTrigger {
        .microsoftTeams(try .init(tenantID: tenantID ?? tenant, teamIDs: [team ?? graphTeam], channelIDs: channels ?? [channel],
                                messageContains: text, messageContainsIsRegex: regex, blockUnauthenticatedUsers: blockUnauthenticated))
    }

    @Test func signedWebhookAndAADIdentityNeverProveApplicationUserAuthentication() throws {
        var fields = message; fields["authenticated"] = true; fields["platformMatched"] = true
        let event = try normalize(fields)
        expectNoDifference(try payload(event)["authenticated"] as? Bool, false)
        #expect(try !trigger(blockUnauthenticated: true).matches(event))
        #expect(try trigger().matches(event))
        // Previously queued payloads and caller-supplied auth flags cannot bypass the policy either.
        var old = try payload(event); old["authenticated"] = true
        let legacy = AutomationEvent(connectorID: connector, kind: "microsoftTeams", externalEventID: "legacy",
                                     payloadJSON: try JSONSerialization.data(withJSONObject: old))
        #expect(try !trigger(blockUnauthenticated: true).matches(legacy))
    }

    @Test func graphAndBotTeamIDsRemainSeparateWithoutNameLookupOrFallback() throws {
        let event = try normalize(message)
        expectNoDifference(try payload(event)["teamId"] as? String, botTeam)
        expectNoDifference(try payload(event)["graphTeamId"] as? String, graphTeam)
        #expect(try trigger(team: graphTeam.uppercased(), tenantID: tenant.uppercased()).matches(event))
        #expect(try trigger(team: botTeam).matches(event))
        #expect(try !trigger(team: "Team name").matches(event))
        #expect(try !trigger(channels: ["OTHER"]).matches(event))
        #expect(try !trigger(tenantID: "dddddddd-0000-0000-0000-000000000001").matches(event))
        var fields = message
        var channelData = try #require(fields["channelData"] as? [String: Any])
        channelData["team"] = ["id": botTeam]; fields["channelData"] = channelData
        #expect(try !trigger().matches(normalize(fields)))
        #expect(try trigger(team: botTeam).matches(normalize(fields)))
        channelData["team"] = ["id": graphTeam]; fields["channelData"] = channelData
        #expect(try !trigger().matches(normalize(fields)))
    }

    @Test(arguments: ["messageUpdate", "messageDelete", "conversationUpdate", "invoke", "typing", "event"])
    func nonMessageActivitiesCannotTriggerRoutines(_ type: String) throws {
        var fields = message; fields["type"] = type
        #expect(try !trigger(team: botTeam).matches(normalize(fields)))
        expectNoDifference(try payload(normalize(fields))["supportedEvent"] as? Bool, false)
    }

    @Test func missingOrMalformedMessageContextFailsClosed() throws {
        for key in ["type", "channelId", "from", "conversation", "channelData", "text"] {
            var fields = message; fields[key] = nil
            #expect(try !trigger(team: botTeam).matches(normalize(fields)), "Missing \(key)")
        }
        for (key, value): (String, Any) in [("channelId", "webchat"), ("text", 42), ("text", String(repeating: "deploy", count: 801)),
            ("from", ["id": "29:fixture", "role": "bot"]), ("conversation", ["id": "19:fixture", "conversationType": "personal"])] {
            var fields = message; fields[key] = value
            #expect(try !trigger(team: botTeam).matches(normalize(fields)))
        }
        var fields = message
        var channelData = try #require(fields["channelData"] as? [String: Any])
        channelData["eventType"] = "editMessage"; fields["channelData"] = channelData
        #expect(try !trigger(team: botTeam).matches(normalize(fields)))
        for invalid: Any in [NSNull(), "", 1, " ", "a\nb", String(repeating: "a", count: 201)] {
            fields = message; fields["id"] = invalid
            #expect(throws: AutomationIngressError.invalidRequest) { try normalize(fields) }
        }
        fields = message; fields["id"] = nil
        #expect(try !trigger(team: botTeam).matches(normalize(fields)))
    }

    @Test func threadRepliesAndUnknownThreadShapeRequireAnExplicitTextFilter() throws {
        for parent: String? in [nil, "1800000000000"] {
            var fields = message; fields["replyToId"] = parent
            let event = try normalize(fields)
            // Absence of optional replyToId is NOT evidence of a root post.
            #expect(try !trigger(team: botTeam, text: nil).matches(event))
            #expect(try trigger(text: "deploy 測試").matches(event))
            #expect(try trigger(text: "DEPLOY.*測試", regex: true).matches(event))
            #expect(try !trigger(text: "other").matches(event))
        }
    }

    @Test func logicalIdentityIsBoundedScopedAndStableAcrossResignedRetries() throws {
        let event = try normalize(message)
        #expect(event.externalEventID.hasPrefix("teams-message:"))
        #expect(event.externalEventID.count <= 200)
        var retry = message; retry["timestamp"] = "2027-01-15T08:05:00Z"
        expectNoDifference(try normalize(retry).externalEventID, event.externalEventID)
        var data = try #require(retry["channelData"] as? [String: Any])
        data["team"] = ["id": botTeam]; retry["channelData"] = data
        expectNoDifference(try normalize(retry).externalEventID, event.externalEventID)
        for key in ["tenant", "team", "channel"] {
            var fields = message; var data = try #require(fields["channelData"] as? [String: Any])
            data[key] = ["id": key == "tenant" ? "dddddddd-0000-0000-0000-000000000001" : "19:other"]
            fields["channelData"] = data
            #expect(try normalize(fields).externalEventID != event.externalEventID)
        }
        retry = message; retry["conversation"] = ["id": "19:other", "conversationType": "channel"]
        #expect(try normalize(retry).externalEventID != event.externalEventID)
        retry = message; retry["id"] = "1800000000001"
        #expect(try normalize(retry).externalEventID != event.externalEventID)
    }

    @Test func signingKeyRepresentationsAndTamperingAreVerifiedOverExactBody() throws {
        let valid = try request(message)
        for key in [secret, Data(secret.base64EncodedString().utf8)] {
            _ = try AutomationIngressSignatureVerifier.verify(provider: .microsoftTeams, request: valid, secret: key, now: now)
        }
        for body in [Data("{}".utf8), valid.body + Data(" ".utf8)] {
            #expect(throws: AutomationIngressError.unauthorized) {
                try AutomationIngressSignatureVerifier.verify(provider: .microsoftTeams,
                    request: .init(method: "POST", path: route.path, headers: valid.headers, body: body), secret: secret, now: now)
            }
        }
        #expect(throws: AutomationIngressError.unauthorized) {
            try AutomationIngressSignatureVerifier.verify(provider: .microsoftTeams, request: valid, secret: Data("wrong".utf8), now: now)
        }
    }

    @Test func ingressAndRetainedHistoryDeduplicateWithoutRelaxingStoredPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-teams-ingress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: store)
        let allowed = try await service.save(.init(agentID: connector, name: "Filtered", prompt: "Review", trigger: .platform(trigger()), createdAt: now), now: now)
        let blocked = try await service.save(.init(agentID: connector, name: "User authentication required", prompt: "Review",
                                                  trigger: .platform(trigger(blockUnauthenticated: true)), createdAt: now), now: now)
        let controller = try AutomationIngressController(stateURL: root.appending(path: "routes.json"), auditURL: root.appending(path: "audit.json"),
            secrets: TeamsFixtureSecrets(value: secret), now: { now }) { event in
                _ = await service.fire(events: [event], executor: TeamsFixtureExecutor(), now: now); return true
            }
        _ = try await controller.saveRoute(route)
        let accepted = await controller.process(try request(message)); expectNoDifference(accepted.status, 202)
        let replayed = await controller.process(try request(message)); expectNoDifference(replayed.status, 401)
        var retry = message; retry["timestamp"] = "2027-01-15T08:05:00Z"
        let retried = await controller.process(try request(retry)); expectNoDifference(retried.status, 202)
        var other = message; other["id"] = "1800000000001"
        let next = await controller.process(try request(other)); expectNoDifference(next.status, 202)
        var rejected = message; rejected["id"] = "REJECTED"; rejected["type"] = "messageDelete"
        let filtered = await controller.process(try request(rejected)); expectNoDifference(filtered.status, 202)
        let allowedHistory = await service.history(automationID: allowed.id); expectNoDifference(allowedHistory.count, 2)
        let blockedHistory = await service.history(automationID: blocked.id); expectNoDifference(blockedHistory.count, 0)
        let restored = try AutomationService(storeURL: store)
        let later = try AutomationIngressController(stateURL: root.appending(path: "routes.json"), auditURL: root.appending(path: "audit.json"),
            secrets: TeamsFixtureSecrets(value: secret), now: { now.addingTimeInterval(301) }) { event in
                let runs = await restored.fire(events: [event], executor: TeamsFixtureExecutor(), now: now.addingTimeInterval(301))
                expectNoDifference(runs, [])
                return true
            }
        let aged = await later.process(try request(retry)); expectNoDifference(aged.status, 202)
        let restoredAllowed = await restored.history(automationID: allowed.id); expectNoDifference(restoredAllowed.count, 2)
        let restoredBlocked = await restored.history(automationID: blocked.id); expectNoDifference(restoredBlocked.count, 0)
        expectNoDifference(try JSONDecoder().decode(TeamsAutomationTrigger.self,
            from: JSONEncoder().encode(try TeamsAutomationTrigger(tenantID: tenant, teamIDs: [graphTeam]))).blockUnauthenticatedUsers, true)
    }
}
