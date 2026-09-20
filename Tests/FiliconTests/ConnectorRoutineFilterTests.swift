import CustomDump
import Foundation
import Testing
import FiliconAutomations

private struct ConnectorFilterExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Fixture only; no network")
    }
}

@Suite("Connector routine filter safety", .timeLimit(.minutes(1)))
struct ConnectorRoutineFilterTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000111")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func definition(_ filters: String, kind: String = "deploy") -> Automation {
        .init(id: id, agentID: id, name: "Fixture", prompt: "Do not contact a provider",
            trigger: .event(.init(connectorID: id, kind: kind, filtersJSON: Data(filters.utf8))), createdAt: now)
    }

    @Test(arguments: ["[]", "null", "true", "broken", "{\"x\":1,\"x\":2}",
                      #"{"x":1,"\u0078":2}"#, #"{"nested":{"x":1,"x":2}}"#])
    func rejectsInvalidOrAmbiguousDefinitions(filters: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-connector-filter-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        await #expect(throws: (any Error).self) { try await service.save(definition(filters), now: now) }
        let definitions = await service.list()
        expectNoDifference(definitions, [])
    }

    @Test(arguments: ["broken", "[]", #"{"x":1,"x":2}"#])
    func malformedLegacyFiltersNeverBecomeMatchAll(filters: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-connector-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: url)
        _ = try await service.save(definition("{}"), now: now)
        // Simulate a definition written by an old build, without using new validation.
        var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let original = definition(filters)
        state["automations"] = [try JSONSerialization.jsonObject(with: encoder.encode(original))]
        try JSONSerialization.data(withJSONObject: state).write(to: url, options: .atomic)
        let restored = try AutomationService(storeURL: url)
        let event = AutomationEvent(connectorID: id, kind: "deploy", externalEventID: "legacy",
            payloadJSON: Data(#"{"x":2}"#.utf8), occurredAt: now)
        let runs = await restored.fire(events: [event], executor: ConnectorFilterExecutor(), now: now)
        let definitions = await restored.list()
        expectNoDifference(runs, [])
        expectNoDifference(definitions, [original])
        // Metadata stays editable, without repairing, dropping or enabling conditions.
        var renamed = original; renamed.name = "Renamed"
        let edited = try await restored.updateManualDefinition(.init(operation: .update, automation: renamed, previous: original), lifetime: .init(), now: now)
        renamed.revision += 1
        expectNoDifference(edited, renamed)
    }

    @Test func exactTypedMatchingAndMalformedPayloads() async throws {
        let cases: [(String, String, Bool)] = [
            (#"{"x":1}"#, #"{"x":"1"}"#, false),
            (#"{"x":true}"#, #"{"x":1}"#, false),
            (#"{"x":false}"#, #"{"x":0}"#, false),
            (#"{"x":null}"#, "{}", false),
            (#"{"x":null}"#, #"{"x":null}"#, true),
            (#"{"x":1}"#, #"{"x":1.00e0,"extra":true}"#, true),
            (#"{"x":9007199254740993}"#, #"{"x":9007199254740992}"#, false),
            (#"{"x":0.123456789012345678901}"#, #"{"x":0.123456789012345678902}"#, false),
            (#"{"x":-0.0}"#, #"{"x":0e10}"#, true),
            (#"{"x":{"a":1,"b":[true,null,"x"]}}"#, #"{"x":{"b":[true,null,"x"],"a":1}}"#, true),
            (#"{"x":{"a":1}}"#, #"{"x":{"a":1,"b":2}}"#, false),
            (#"{"x":[1,2]}"#, #"{"x":[2,1]}"#, false),
            (#"{"x":"a"}"#, #"{"x":"A"}"#, false),
            (#"{"x":"\u00e9"}"#, #"{"x":"e\u0301"}"#, false),
            (#"{"\u00e9":1}"#, #"{"e\u0301":1}"#, false),
            (#"{"x":"\u00e9"}"#, #"{"x":"é"}"#, true),
            (#"{"x":2}"#, #"{"x":2,"extra":{"x":1,"x":2}}"#, false),
            (#"{"x":2}"#, #"{"x":1,"x":2}"#, false),
            ("{}", "{\"x\":\"" + String(repeating: "a", count: 1_048_568) + "\"}", true),
            ("{}", "{\"x\":\"" + String(repeating: "a", count: 1_048_569) + "\"}", false),
            ("{}", "[]", false), ("{}", "broken", false), ("{}", "{}", true)
        ]
        for (filters, payload, matches) in cases {
            let root = FileManager.default.temporaryDirectory.appending(path: "filicon-connector-match-\(UUID())")
            defer { try? FileManager.default.removeItem(at: root) }
            let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
            _ = try await service.save(definition(filters), now: now)
            let event = AutomationEvent(connectorID: id, kind: "deploy", externalEventID: "event", payloadJSON: Data(payload.utf8), occurredAt: now)
            let runs = await service.fire(events: [event], executor: ConnectorFilterExecutor(), now: now)
            expectNoDifference(runs.map(\.status), matches ? [.ok] : [], "\(filters) against \(payload)")
        }
    }

    @Test func strictSyntaxAndResourceBounds() throws {
        let valid = ["{}", #"{"escaped":"a\"b\\c\n","emoji":"\uD83D\uDE00"}"#,
            #"{"x":1e10000}"#, #"{"x":1e-10000}"#,
            "{\"x\":" + String(repeating: "9", count: 256) + "}",
            "{\"x\":" + String(repeating: "[", count: 15) + "0" + String(repeating: "]", count: 15) + "}",
            "{\"x\":[" + Array(repeating: "0", count: 4094).joined(separator: ",") + "]}",
            "{\"x\":\"" + String(repeating: "a", count: 16_376) + "\"}"]
        for json in valid {
            try AutomationEventTrigger(connectorID: id, kind: "deploy", filtersJSON: Data(json.utf8)).validateFilters()
        }
        let invalid = ["{", "{} trailing", "{},{}", "{\"x\":01}", "{\"x\":+1}", "{\"x\":1.}", "{\"x\":.1}",
            "{\"x\":1e}", "{\"x\":truefalse}", "{\"x\":NaN}", "{\"x\":Infinity}", "{\"x\":1e10001}", "{\"x\":1e-10001}",
            "{\"x\":1e9999999999999999999999999999999}", "{\"x\":1,}", "{\"x\":[1,]}", "{\"x\":\"line\nline\"}",
            #"{"x":"\q"}"#, #"{"x":"\uD800"}"#,
            "{\"x\":" + String(repeating: "9", count: 257) + "}",
            "{\"x\":" + String(repeating: "[", count: 16) + "0" + String(repeating: "]", count: 16) + "}",
            "{\"x\":[" + Array(repeating: "0", count: 4095).joined(separator: ",") + "]}",
            "{\"x\":\"" + String(repeating: "a", count: 16_377) + "\"}"]
        for json in invalid {
            #expect(throws: ConnectorEventFilterError.invalidFilters) {
                try AutomationEventTrigger(connectorID: id, kind: "deploy", filtersJSON: Data(json.utf8)).validateFilters()
            }
        }
        for bytes: [UInt8] in [[123, 34, 120, 34, 58, 34, 255, 34, 125], [123, 34, 120, 34, 58, 34, 92]] {
            #expect(throws: ConnectorEventFilterError.invalidFilters) {
                try AutomationEventTrigger(connectorID: id, kind: "deploy", filtersJSON: Data(bytes)).validateFilters()
            }
        }
        for kind in ["", " deploy", "deploy ", "de\nploy", "de\u{0}ploy", String(repeating: "a", count: 129)] {
            #expect(throws: ConnectorEventFilterError.invalidKind) { try AutomationEventTrigger(connectorID: id, kind: kind).validateFilters() }
        }
        try AutomationEventTrigger(connectorID: id, kind: String(repeating: "a", count: 128)).validateFilters()
    }

    @Test func editedMixedORRetainsHistoryScopesAndDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-connector-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "automations.json"), service = try AutomationService(storeURL: url)
        let originalFilter = definition(#"{"env":"stage"}"#).trigger
        let other = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000112")!
        var original = definition("{}"); original.trigger = .anyOf([.cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), originalFilter])
        let saved = try await service.save(original, now: now)
        var edited = saved; edited.trigger = .anyOf([.cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), definition(#"{"env":"prod"}"#).trigger, definition("{}").trigger])
        let change = AutomationStateChange(operation: .update, automation: edited, previous: saved)
        let result = try await service.updateManualDefinition(change, lifetime: .init(), now: now.addingTimeInterval(60))
        edited.revision += 1
        expectNoDifference(result, edited)
        let reopened = try AutomationService(storeURL: url)
        let definitions = await reopened.list(), initialHistory = await reopened.history(automationID: id)
        expectNoDifference(definitions, [edited]); expectNoDifference(initialHistory, [])
        let event = AutomationEvent(connectorID: id, kind: "deploy", externalEventID: "fixture", payloadJSON: Data(#"{"env":"prod"}"#.utf8), occurredAt: now)
        let wrongScope = [AutomationEvent(connectorID: other, kind: "deploy", externalEventID: "fixture", payloadJSON: event.payloadJSON, occurredAt: now),
            AutomationEvent(connectorID: id, kind: "Deploy", externalEventID: "other-kind", payloadJSON: event.payloadJSON, occurredAt: now)]
        let wrongRuns = await reopened.fire(events: wrongScope, executor: ConnectorFilterExecutor(), now: now)
        expectNoDifference(wrongRuns, [])
        let runs = await reopened.fire(events: [event, event], executor: ConnectorFilterExecutor(), now: now)
        expectNoDifference(runs.map(\.coalescedEventIDs), [["fixture"]])
        let again = try AutomationService(storeURL: url)
        let replays = await again.fire(events: [event], executor: ConnectorFilterExecutor(), now: now)
        expectNoDifference(replays, [])
    }

    @Test func manualEditorSupportDoesNotGrantModelWriteAuthority() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-connector-model-boundary-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let original = definition(#"{"environment":"prod"}"#)
        let create = AutomationStateChange(operation: .create, automation: original)
        await #expect(throws: AutomationStateChangeError.unsupportedSchedule) { try await service.validateStateChange(create, now: now) }
        await #expect(throws: AutomationStateChangeError.unsupportedSchedule) { try await service.applyStateChange(create, lifetime: .init(), now: now) }
        let saved = try await service.save(original, now: now)
        var proposed = saved; proposed.name = "Changed"
        let update = AutomationStateChange(operation: .update, automation: proposed, previous: saved)
        await #expect(throws: AutomationStateChangeError.unsupportedSchedule) { try await service.applyStateChange(update, lifetime: .init(), now: now) }
        let definitions = await service.list()
        expectNoDifference(definitions, [saved])
    }
}
