import AppKit
import CryptoKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAutomations
@testable import Filicon

private struct EditorFixtureExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Editor fixture only; no model or network")
    }
}

@Suite("Manual routine event editors", .timeLimit(.minutes(1)))
@MainActor
struct RoutineListenerEditorTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000001")!
    private let team = "bbbbbbbb-0000-0000-0000-000000000001"
    private let project = "cccccccc-0000-0000-0000-000000000001"
    private let status = "dddddddd-0000-0000-0000-000000000001"
    private let cycle = "eeeeeeee-0000-0000-0000-000000000001"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let kinds: [AutomationListenerKind] = [.linear, .sentry, .pagerDuty]

    @Test func defaultsUseSupportedEventsInsteadOfLegacyHyphenatedNames() throws {
        for kind in kinds {
            let draft = AutomationListenerDraft.defaults(for: kind, id: id)
            expectNoDifference(draft.id, id)
            expectNoDifference(draft.primary, kind == .pagerDuty ? "incidentTriggered" : "issueCreated")
            #expect(draft.validationMessage == nil)
            _ = try draft.trigger
        }
        expectNoDifference(AutomationListenerKind.linear.events.map(\.rawValue), ["issueCreated", "statusChanged", "endOfCycle"])
        expectNoDifference(Set(AutomationListenerKind.sentry.events.map(\.rawValue)), CaseAutomationTrigger.sentryEvents)
        expectNoDifference(Set(AutomationListenerKind.pagerDuty.events.map(\.rawValue)), CaseAutomationTrigger.pagerDutyEvents)
        for kind in kinds {
            for event in ["", "issue-updated", "issue-created", "incident-triggered", "madeUp", "issueCreated "] {
                var draft = AutomationListenerDraft.defaults(for: kind, id: id); draft.primary = event
                #expect(draft.validationMessage != nil)
                #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
            }
        }
    }

    @Test func filtersNormalizeUUIDsButPreserveOpaqueAndDecimalIdentity() throws {
        var linear = AutomationListenerDraft.defaults(for: .linear, id: id)
        linear.primary = "statusChanged"
        linear.secondary = " \(team.uppercased()), \(team) "
        linear.tertiary = project.uppercased(); linear.statusIDs = status.uppercased()
        expectNoDifference(try linear.trigger, .platform(.linear(try .init(event: "statusChanged", allowedEvents: ["statusChanged"],
            primaryIDs: [team], secondaryIDs: [project], statusIDs: [status]))))
        var sentry = AutomationListenerDraft.defaults(for: .sentry, id: id)
        sentry.secondary = " 00123, 123,00123 "
        expectNoDifference(try sentry.trigger, .platform(.sentry(try .init(event: "issueCreated", allowedEvents: ["issueCreated"], primaryIDs: ["00123", "123"]))))
        var pd = AutomationListenerDraft.defaults(for: .pagerDuty, id: id)
        pd.secondary = " PF9KMXH,pf9kmxh,PF9KMXH "
        expectNoDifference(try pd.trigger, .platform(.pagerDuty(try .init(event: "incidentTriggered", allowedEvents: ["incidentTriggered"], primaryIDs: ["PF9KMXH", "pf9kmxh"]))))
    }

    @Test func rawListLimitsAndEmptySegmentsNeverBroadenScope() throws {
        for kind in kinds {
            let token = kind == .linear ? team : kind == .sentry ? "123" : "PF9KMXH"
            var draft = AutomationListenerDraft.defaults(for: kind, id: id)
            for raw in ["", " \n ", token, Array(repeating: token, count: 50).joined(separator: ",")] {
                draft.secondary = raw; _ = try draft.trigger
                #expect(draft.validationMessage == nil)
            }
            for raw in [",", " , ", token + ",", "," + token, token + ",," + token,
                        Array(repeating: token, count: 51).joined(separator: ","), "*", "a b", "a\u{0}b"] {
                draft.secondary = raw
                #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
                #expect(draft.validationMessage != nil)
            }
        }
        for field in [\AutomationListenerDraft.secondary, \.tertiary, \.statusIDs, \.cycleIDs] {
            var draft = AutomationListenerDraft.defaults(for: .linear, id: id)
            draft.primary = field == \.cycleIDs ? "endOfCycle" : "statusChanged"
            for raw in ["project-name", "123", team + "x", "{\(team)}", Array(repeating: team, count: 51).joined(separator: ",")] {
                draft[keyPath: field] = raw
                #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
            }
        }
        for kind in [AutomationListenerKind.sentry, .pagerDuty] {
            var draft = AutomationListenerDraft.defaults(for: kind, id: id)
            let token = String(repeating: "1", count: 200)
            draft.secondary = token; _ = try draft.trigger
            draft.secondary += "1"
            #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
            if kind == .sentry {
                for raw in ["project-name", "1.2", "+123", "１２３"] {
                    draft.secondary = raw
                    #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
                }
            }
        }
    }

    @Test func eventChangesRetainIncompatibleFiltersUntilUserClearsThem() throws {
        var draft = AutomationListenerDraft.defaults(for: .linear, id: id)
        draft.primary = "statusChanged"; draft.tertiary = project; draft.statusIDs = status
        var expected = draft; expected.primary = "endOfCycle"
        draft.primary = "endOfCycle"
        expectNoDifference(draft, expected)
        #expect(draft.validationMessage != nil)
        #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
        draft.statusIDs = ""
        #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
        draft.tertiary = ""; draft.cycleIDs = cycle
        _ = try draft.trigger
        draft.primary = "issueCreated"
        #expect(throws: AutomationStateChangeError.self) { try draft.trigger }
        expectNoDifference(draft.cycleIDs, cycle)
        draft.cycleIDs = ""
        #expect(draft.validationMessage == nil)
        for kind in [AutomationListenerKind.sentry, .pagerDuty] {
            for field in [\AutomationListenerDraft.tertiary, \.statusIDs, \.cycleIDs] {
                var value = AutomationListenerDraft.defaults(for: kind, id: id)
                value[keyPath: field] = "123"
                #expect(throws: AutomationStateChangeError.self) { try value.trigger }
            }
        }
    }

    @Test func everyMenuChoiceMatchesAnAuthenticatedFixtureWithExactFilters() throws {
        for kind in kinds {
            for option in kind.events {
                let draft = configured(kind, event: option.rawValue)
                guard case .platform(let platform) = try draft.trigger else { Issue.record("Expected platform trigger"); continue }
                #expect(try platform.matches(webhook(kind, event: option.rawValue)))
                #expect(try !platform.matches(webhook(kind, event: option.rawValue, wrongID: true)))
                let encoded = try JSONEncoder().encode(draft.trigger)
                expectNoDifference(try JSONDecoder().decode(AutomationTrigger.self, from: encoded), try draft.trigger)
            }
        }
    }

    @Test func createdDefinitionsPersistAndMixedListenersRunOnceWithoutMigratingLegacy() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "filicon-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "automations.json")
        let service = try AutomationService(storeURL: url)
        let triggers = try kinds.map { try configured($0, event: $0.events[0].rawValue).trigger }
        let legacy = Automation(id: UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000002")!, agentID: id,
            name: "Legacy", prompt: "Do not migrate", trigger: .platform(.sentry(try .init(event: "issue-created", allowedEvents: ["issue-created"]))),
            enabled: false, createdAt: now.addingTimeInterval(-1))
        let old = try await service.save(legacy, now: now)
        let saved = try await service.save(.init(id: id, agentID: id, name: "Manual OR", prompt: "Fixture task",
            trigger: .anyOf(triggers), createdAt: now), now: now)
        let reopened = try AutomationService(storeURL: url)
        let listed = await reopened.list()
        expectNoDifference(listed, [old, saved])
        let events = try kinds.map { try webhook($0, event: $0.events[0].rawValue) }
        let runs = await reopened.fire(events: events, executor: EditorFixtureExecutor(), now: now)
        expectNoDifference(runs.map(\.status), [.ok])
        expectNoDifference(runs.map(\.automationID), [id])
        let again = try AutomationService(storeURL: url)
        let duplicateRuns = await again.fire(events: events, executor: EditorFixtureExecutor(), now: now.addingTimeInterval(1))
        expectNoDifference(duplicateRuns, [])
        let after = await again.list()
        expectNoDifference(after.first, old)
    }

    @Test func newLabelsAndNoticesHaveSevenLanguageCoverage() {
        let keys = AutomationListenerEvent.allCases.map(\.label) + ["Trigger", "Event", "Remove", "Team UUIDs", "Project UUIDs", "New status UUIDs", "Cycle UUIDs",
            "Project IDs (digits only)", "Service IDs (case-sensitive)", AutomationListenerEditor.filterNotice,
            AutomationListenerEditor.ingressNotice, AutomationListenerEditor.linearNotice]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for kind in kinds { expectNoDifference(kind.label(language: language), kind.rawValue) }
            for key in keys {
                let value = FiliconLocalization.string(key, language: language)
                expectNoDifference(value == key, language == "en", "\(language): \(key)")
            }
        }
    }

    // Keep the existing language order, but give each language its own bounded
    // test case instead of putting up to 161 renders under one timeout.
    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func nativeEditorsRenderAcrossLanguagesAppearancesAndRetainedInvalidFilters(language: String) async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        var invalid = configured(.linear, event: "statusChanged"); invalid.primary = "endOfCycle"
        let drafts = [configured(.linear, event: "issueCreated"), configured(.linear, event: "statusChanged"),
            configured(.linear, event: "endOfCycle"), configured(.sentry, event: "issueAny"), configured(.pagerDuty, event: "incidentAny"), invalid]
        for dark in [false, true] {
            for (index, draft) in drafts.enumerated() {
                try await withUIRenderTurn {
                    let host = NSHostingView(rootView: AutomationListenerEditor(listener: .constant(draft), canRemove: true, remove: {})
                        .padding(20).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 440, height: 900); host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 900)
                    #expect(host.fittingSize.width <= 440)
                    host.setFrameSize(.init(width: 440, height: ceil(host.fittingSize.height)))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "editor-\(language)-\(dark ? "dark" : "light")-\(index).png"))
                    }
                }
            }
        }
    }

    private func configured(_ kind: AutomationListenerKind, event: String) -> AutomationListenerDraft {
        var draft = AutomationListenerDraft.defaults(for: kind, id: id); draft.primary = event
        switch kind {
        case .linear:
            draft.secondary = team
            if event == "endOfCycle" { draft.cycleIDs = cycle }
            else { draft.tertiary = project }
            if event == "statusChanged" { draft.statusIDs = status }
        case .sentry: draft.secondary = "123"
        case .pagerDuty: draft.secondary = "PF9KMXH"
        default: break
        }
        return draft
    }

    private func webhook(_ kind: AutomationListenerKind, event: String, wrongID: Bool = false) throws -> AutomationEvent {
        let provider: AutomationIngressProvider
        let fields: [String: Any]
        var headers = ["content-type": "application/json"]
        let signatureHeader: String
        switch kind {
        case .linear:
            provider = .linear; signatureHeader = "linear-signature"
            if event == "endOfCycle" {
                fields = ["type": "Cycle", "action": "update", "webhookTimestamp": 1_800_000_000_000,
                    "updatedFrom": ["completedAt": NSNull()], "data": ["id": cycle, "teamId": wrongID ? project : team,
                        "completedAt": "2027-01-15T07:59:00.000Z"]]
            } else {
                fields = ["type": "Issue", "action": event == "issueCreated" ? "create" : "update",
                    "webhookTimestamp": 1_800_000_000_000, "updatedFrom": ["stateId": cycle],
                    "data": ["id": "fixture-issue", "teamId": wrongID ? project : team, "projectId": project, "stateId": status]]
            }
        case .sentry:
            provider = .sentry; signatureHeader = "sentry-hook-signature"; headers["sentry-hook-resource"] = "issue"
            let action = ["issueCreated": "created", "issueResolved": "resolved", "issueAssigned": "assigned",
                "issueArchived": "archived", "issueUnresolved": "unresolved", "issueAny": "created"][event]!
            fields = ["action": action, "data": ["issue": ["id": "123456", "project": ["id": wrongID ? "0123" : "123"]]]]
        case .pagerDuty:
            provider = .pagerDuty; signatureHeader = "x-pagerduty-signature"
            let action = ["incidentTriggered": "triggered", "incidentAcknowledged": "acknowledged", "incidentResolved": "resolved",
                "incidentEscalated": "escalated", "incidentAny": "triggered"][event]!
            fields = ["event": ["id": "fixture-incident-event", "event_type": "incident." + action, "resource_type": "incident",
                "occurred_at": "2027-01-15T07:59:00Z", "data": ["id": "PGR0VU2", "type": "incident",
                    "service": ["id": wrongID ? "pf9kmxh" : "PF9KMXH", "type": "service_reference"]]]]
        default: throw AutomationServiceError.invalidDefinition
        }
        let secret = Data("fixture-not-a-real-key".utf8)
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
        headers[signatureHeader] = (kind == .pagerDuty ? "v1=" : "") + signature
        let route = AutomationIngressRoute(id: id, name: "Fixture", provider: provider, secretReference: "fixture")
        let request = AutomationHTTPRequest(method: "POST", path: route.path, headers: headers, body: body)
        let auth = try AutomationIngressSignatureVerifier.verify(provider: provider, request: request, secret: secret, now: now)
        return try AutomationIngressEventNormalizer.event(route: route, request: request, nonce: auth.nonce, now: now)
    }
}
