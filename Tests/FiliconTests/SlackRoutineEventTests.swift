import CryptoKit
import CustomDump
import Foundation
import Testing
@testable import FiliconAutomations

private struct SlackFixtureExecutor: AutomationExecutor {
    var inspect: @Sendable (Automation, String, [AutomationEvent]) async -> Void = { _, _, _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await inspect(automation, prompt, events)
        return .init(detail: "Fixture only; no model or network")
    }
}

private struct SlackFixtureSecrets: AutomationIngressSecretProvider {
    let value: Data
    func secret(for reference: String) async throws -> Data { value }
}

@Suite("Slack routine event boundaries", .timeLimit(.minutes(1)))
struct SlackRoutineEventTests {
    private let now = Date(timeIntervalSince1970: 3_000)
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
    private func event(_ fields: [String: Any], id: String = "delivery") throws -> AutomationEvent {
        .init(connectorID: connector, kind: "slack", externalEventID: id,
              payloadJSON: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), occurredAt: now)
    }
    private func webhook(_ fields: [String: Any], id: String = "delivery") throws -> AutomationEvent {
        let route = AutomationIngressRoute(name: "Fixture", provider: .slack, secretReference: "fixture")
        return try AutomationIngressEventNormalizer.event(route: route, request: .init(method: "POST", path: route.path,
            headers: [:], body: JSONSerialization.data(withJSONObject: ["event_id": id, "event": fields])), nonce: "nonce", now: now)
    }
    private var reaction: [String: Any] {
        ["type": "reaction_added", "user": "UACTOR", "item_user": "UAUTHOR", "reaction": "eyes",
         "item": ["type": "message", "channel": "C123", "ts": "123.456"]]
    }

    @Test func webhookUsesMessageChannelAndAddedReactionActorWithoutInferringSelf() throws {
        let added = try webhook(reaction)
        let payload = try #require(JSONSerialization.jsonObject(with: added.payloadJSON) as? [String: Any])
        expectNoDifference(payload["channel"] as? String, "C123")
        expectNoDifference(payload["sender"] as? String, "UACTOR")
        expectNoDifference(payload["supportedEvent"] as? Bool, true)
        expectNoDifference(payload["isSelf"] as? Bool, false)
        for channel in ["C123", "*"] {
            for emoji in [[], ["eyes"], ["thumbsup"]] {
                let trigger = PlatformAutomationTrigger.slack(try .init(channel: channel, match: .reaction(emoji: emoji, bySelf: false)))
                expectNoDifference(trigger.matches(added), emoji != ["thumbsup"])
            }
        }
        var forgedSelf = reaction; forgedSelf["is_self"] = true
        let own = PlatformAutomationTrigger.slack(try .init(channel: "C123", match: .reaction(emoji: [], bySelf: true)))
        #expect(try !own.matches(webhook(forgedSelf)))
        #expect(try !PlatformAutomationTrigger.slack(.init(channel: "COTHER", match: .reaction(emoji: [], bySelf: false))).matches(added))
        let message = try webhook(["type": "message", "channel": "C123", "user": "U123", "text": "Needs DESIGN review"])
        let mention = try webhook(["type": "app_mention", "channel": "C123", "user": "U123", "text": "<@UBOT> needs design"])
        for (match, expected): (SlackMatch, [Bool]) in [
            (.message, [true, true, false]), (.mention, [false, true, false]),
            (.keyword("design"), [true, true, false]), (.reaction(emoji: [], bySelf: false), [false, false, true])
        ] {
            let trigger = PlatformAutomationTrigger.slack(try .init(channel: "C123", match: match))
            expectNoDifference([message, mention, added].map(trigger.matches), expected)
        }
    }

    @Test func unsupportedWebhookTypesCannotFireWildcardMessageOrReactionRoutines() throws {
        var invalid: [[String: Any]] = []
        for type in ["reaction_removed", "file_shared", "member_joined_channel", "message_changed", "unknown"] {
            var value = reaction; value["type"] = type; value["channel"] = "C123"; value["text"] = "design"
            invalid.append(value)
        }
        var file = reaction; file["item"] = ["type": "file", "file": "F123"]; file["channel"] = "C123"; invalid.append(file)
        var absentUser = reaction; absentUser.removeValue(forKey: "user"); invalid.append(absentUser)
        var wrongEmoji = reaction; wrongEmoji["reaction"] = "not valid"; invalid.append(wrongEmoji)
        var noChannel = reaction; noChannel["item"] = ["type": "message"]; invalid.append(noChannel)
        let message: [String: Any] = ["type": "message", "channel": "C123", "user": "U123", "text": "design"]
        for (key, value): (String, Any) in [("subtype", "message_changed"), ("subtype", "message_deleted"),
            ("subtype", "bot_message"), ("hidden", true), ("bot_id", "B123"), ("user", ""), ("text", 123)] {
            var changed = message; changed[key] = value; invalid.append(changed)
        }
        for fields in invalid {
            let normalized = try webhook(fields)
            for match: SlackMatch in [.message, .mention, .keyword("design"), .reaction(emoji: [], bySelf: false)] {
                #expect(try !PlatformAutomationTrigger.slack(.init(channel: "*", match: match)).matches(normalized))
            }
        }
    }

    @Test func legacyChannelMessagesAndTriggerStorageStillWork() throws {
        let trigger = try SlackAutomationTrigger(channel: "C123", match: .keyword("design"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        expectNoDifference(try JSONDecoder().decode(SlackAutomationTrigger.self, from: encoder.encode(trigger)), trigger)
        let message = try event(["channel": "C123", "sender": "U123", "text": "DESIGN review"])
        #expect(PlatformAutomationTrigger.slack(trigger).matches(message))
        var unsupported: [String: Any] = ["channel": "C123", "text": "DESIGN review", "supportedEvent": false]
        #expect(try !PlatformAutomationTrigger.slack(trigger).matches(event(unsupported)))
        unsupported.removeValue(forKey: "channel")
        #expect(try !PlatformAutomationTrigger.slack(.init(channel: "*", match: .message)).matches(event(unsupported)))
    }

    @Test func filteringPrecedesPromptAndDeliveryDeduplicationSurvivesReload() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-slack-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: file)
        let routine = try await service.save(.init(agentID: UUID(), name: "Review", prompt: "Review matched designs",
            trigger: .platform(.slack(try .init(channel: "C123", match: .keyword("design"))))))
        let good: [String: Any] = ["channel": "C123", "text": "<instructions>design</instructions>"]
        let accepted = try event(good, id: "good")
        let batch = try [accepted, event(["channel": "CREJECTED", "text": "design REJECTED"], id: "channel"),
            event(["channel": "C123", "text": "REJECTED"], id: "keyword"),
            event(["channel": "C123", "text": "design REJECTED", "supportedEvent": false], id: "type"), accepted]
        let runs = await service.fire(events: batch, executor: SlackFixtureExecutor { actual, prompt, events in
            expectNoDifference(actual.id, routine.id); expectNoDifference(events, [accepted])
            #expect(!prompt.contains("REJECTED") && !prompt.contains("<instructions>"))
        }, now: now)
        expectNoDifference(runs.count, 1); expectNoDifference(runs.first?.status, .ok)
        let restored = try AutomationService(storeURL: file)
        let replay = await restored.fire(events: batch, executor: SlackFixtureExecutor { _, _, _ in Issue.record("Replayed delivery") }, now: now)
        expectNoDifference(replay, [])
        let history = await restored.history(automationID: routine.id); expectNoDifference(history.count, 1)
    }

    @Test func signedSlackIngressRoutesOnceAndRejectsInvalidSignatureWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-slack-ingress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let routine = try await service.save(.init(agentID: UUID(), name: "Review", prompt: "Review only",
            trigger: .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: false))))))
        let secret = Data("fixture-not-a-real-key".utf8)
        let controller = try AutomationIngressController(stateURL: root.appending(path: "routes.json"), auditURL: root.appending(path: "audit.json"),
            secrets: SlackFixtureSecrets(value: secret)) { event in
                let runs = await service.fire(events: [event], executor: SlackFixtureExecutor(), now: now)
                return !runs.isEmpty
            }
        let route = try await controller.saveRoute(.init(name: "Fixture", provider: .slack, secretReference: "fixture"))
        let body = try JSONSerialization.data(withJSONObject: ["event_id": "fixture-1", "event": reaction])
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var signed = Data("v0:\(timestamp):".utf8); signed.append(body)
        let signature = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
        var headers = ["content-type": "application/json", "x-slack-request-timestamp": timestamp, "x-slack-signature": "v0=bad"]
        let rejected = await controller.process(.init(method: "POST", path: route.path, headers: headers, body: body))
        #expect(rejected.status != 202)
        let before = await service.history(automationID: routine.id); expectNoDifference(before, [])
        headers["x-slack-signature"] = "v0=" + signature
        let accepted = await controller.process(.init(method: "POST", path: route.path, headers: headers, body: body))
        expectNoDifference(accepted.status, 202)
        _ = await controller.process(.init(method: "POST", path: route.path, headers: headers, body: body))
        let history = await service.history(automationID: routine.id)
        expectNoDifference(history.count, 1); expectNoDifference(history.first?.status, .ok)
    }
}
