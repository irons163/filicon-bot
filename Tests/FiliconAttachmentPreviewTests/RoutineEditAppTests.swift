import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAutomations
@testable import Filicon

@Suite("Manual routine editor app integration", .timeLimit(.minutes(1)))
@MainActor
struct RoutineEditAppTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000071")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func routine(_ trigger: AutomationTrigger) -> Automation {
        .init(id: id, agentID: id, name: "Fixture routine", prompt: "Review the fixture only", trigger: trigger, createdAt: now)
    }
    private var statusTrigger: AutomationTrigger {
        get throws {
            .platform(.linear(try .init(event: "statusChanged", allowedEvents: ["statusChanged"],
                primaryIDs: [id.uuidString], statusIDs: [id.uuidString])))
        }
    }

    @Test func allSupportedConditionsRoundTripWithoutImplicitNormalization() throws {
        var triggers: [AutomationTrigger] = [
            .cron(expression: "@daily", timeZoneIdentifier: nil),
            .cron(expression: "@every 1h", timeZoneIdentifier: "Asia/Taipei"), try statusTrigger,
            .platform(.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"], cycleIDs: [id.uuidString]))),
            .platform(.sentry(try .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: ["00123", "123"]))),
            .platform(.pagerDuty(try .init(event: "incidentAny", allowedEvents: ["incidentAny"], primaryIDs: ["PF9KMXH", "pf9kmxh"])))
        ]
        triggers.append(.anyOf(triggers))
        for trigger in triggers {
            let original = routine(trigger)
            var draft = RoutineEditDraft(original)
            #expect(draft.canEditConditions && !draft.hasChanges)
            expectNoDifference(try draft.change.automation, original)
            expectDifference(draft) { draft.name = "Renamed" } changes: { $0.name = "Renamed" }
            expectNoDifference(try draft.change.automation.trigger, trigger)
            expectNoDifference(try draft.change.previous, original)
        }
    }

    @Test func editingOneORBranchDoesNotRewriteOthersOrDropInvalidFilters() throws {
        let time = AutomationTrigger.cron(expression: "@daily", timeZoneIdentifier: nil)
        let linear = try statusTrigger
        let sentry = AutomationTrigger.platform(.sentry(try .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: ["123"])))
        var draft = RoutineEditDraft(routine(.anyOf([time, linear, sentry])))
        draft.listeners[2].secondary = "456"
        expectNoDifference(try draft.change.automation.trigger, .anyOf([time, linear,
            .platform(.sentry(try .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: ["456"])))]))
        expectDifference(draft) { draft.listeners[1].primary = "endOfCycle" } changes: { $0.listeners[1].primary = "endOfCycle" }
        #expect(draft.validationMessage != nil)
        expectNoDifference(draft.listeners[1].statusIDs, id.uuidString)
        #expect(throws: (any Error).self) { try draft.change }
        draft.listeners[1].statusIDs = ""
        #expect(draft.validationMessage == nil)
        draft.listeners.removeAll()
        #expect(throws: (any Error).self) { try draft.change }
    }

    @Test func unsupportedAndLegacyDefinitionsAllowMetadataEditsOnly() throws {
        let triggers: [AutomationTrigger] = [
            .unknown(kind: "future", payloadJSON: Data(#"{"untouched":true}"#.utf8)),
            .platform(.linear(try .init(event: "issue", allowedEvents: ["issue"], primaryIDs: ["legacy-name"]))),
            .platform(.microsoftTeams(try .init(tenantID: "tenant", teamIDs: ["team"], messageContains: "pattern", messageContainsIsRegex: true, blockUnauthenticatedUsers: false))),
            .anyOf([.cron(expression: "@daily", timeZoneIdentifier: nil), .unknown(kind: "future", payloadJSON: Data("{}".utf8))])
        ]
        for trigger in triggers {
            var draft = RoutineEditDraft(routine(trigger))
            #expect(!draft.canEditConditions)
            draft.prompt = "Updated instruction"
            expectNoDifference(try draft.change.automation.trigger, trigger)
            draft.listeners.append(.init())
            #expect(throws: AutomationEditError.unsupportedTrigger) { try draft.change }
        }
    }

    @Test(arguments: ["save", "cancel", "account", "stale", "archive", "storage"])
    func appSaveUsesLiveSessionAndPreservesDraftOnFailure(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-routine-edit-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = try #require(await model.createAgent(name: "Fixture", summary: "", instructions: "No provider calls", providerID: "fixture", modelID: "fixture"))
        await model.createAutomation(agentID: agent.id, name: "Original", prompt: "Original instruction", trigger: try statusTrigger)
        let before = try #require(model.automations.first)
        let session = try #require(model.beginAutomationEdit(before))
        defer { model.endAutomationEdit(session) }
        var draft = RoutineEditDraft(before); draft.name = "Saved edit"; draft.prompt = "Changed instruction"
        let expectedDraft = draft
        switch mode {
        case "cancel": model.endAutomationEdit(session)
        case "account": await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
        case "stale": await model.setAutomationEnabled(id: before.id, enabled: false)
        case "archive": await model.archiveAgent(id: agent.id)
        case "storage":
            let url = root.appending(path: "automations.json")
            try FileManager.default.moveItem(at: url, to: root.appending(path: "automations-backup.json"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        default: break
        }
        if mode == "save" {
            try await model.saveAutomationEdit(session, draft: draft)
            let saved = try #require(model.automations.first)
            var expected = before; expected.name = "Saved edit"; expected.prompt = "Changed instruction"; expected.revision += 1
            expectNoDifference(saved, expected)
            let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            await reopened.reloadAutomationDetails(markViewed: false)
            expectNoDifference(reopened.automations.map(\.name), ["Saved edit"])
            #expect(reopened.automationHistory.values.allSatisfy { $0.isEmpty })
        } else {
            let current = model.automations
            await #expect(throws: (any Error).self) { try await model.saveAutomationEdit(session, draft: draft) }
            expectNoDifference(model.automations, current)
            expectNoDifference(draft, expectedDraft)
        }
    }

    @Test func cancellingOneEditorDoesNotRevokeAnother() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-routine-edit-sessions-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = try #require(await model.createAgent(name: "Fixture", summary: "", instructions: "Fixture", providerID: "fixture", modelID: "fixture"))
        await model.createAutomation(agentID: agent.id, name: "Original", prompt: "Fixture", schedule: "@daily")
        let before = try #require(model.automations.first)
        let first = try #require(model.beginAutomationEdit(before)), second = try #require(model.beginAutomationEdit(before))
        defer { model.endAutomationEdit(second) }
        model.endAutomationEdit(first)
        var draft = RoutineEditDraft(before); draft.name = "Second editor"
        try await model.saveAutomationEdit(second, draft: draft)
        expectNoDifference(model.automations.first?.name, "Second editor")
    }

    @Test func editorMessagesAreAvailableInSevenLanguages() {
        let keys = ["Edit routine", "Routine conditions", "Any one matching condition can trigger this routine.",
            RoutineAutomationEditFields.preservationNotice, AutomationEditError.invalidText.rawValue,
            AutomationEditError.stale.rawValue, AutomationEditError.unsupportedTrigger.rawValue, AutomationEditError.unavailable.rawValue]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en", "\(language): \(key)") }
        }
        expectNoDifference(FiliconLocalization.string("Instruction", language: "ja"), "指示")
        expectNoDifference(FiliconLocalization.string("Instruction", language: "ko"), "지침")
        expectNoDifference(FiliconLocalization.string("Time zone", language: "ko"), "시간대")
        for (language, expected) in [("fr", "Planification"), ("es", "Programación"), ("ko", "일정")] {
            expectNoDifference(AutomationListenerKind.schedule.label(language: language), expected)
        }
    }

    // Keep the existing language order, but give each language its own bounded
    // test case instead of putting up to 161 renders under one timeout.
    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func editorSheetRendersSupportedAndReadOnlyStatesInSevenLanguages(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-routine-edit-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let definitions = [routine(try statusTrigger), routine(.unknown(kind: "future", payloadJSON: Data(#"{"untouched":true}"#.utf8))),
            routine(.cron(expression: "@daily", timeZoneIdentifier: nil)),
            routine(.platform(.github(try .init(repo: "example/repo", events: ["pr-opened", "ci-failed"], ciBranch: "main", userAllowlist: ["alice"])))),
            routine(.platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: true))))),
            routine(.event(.init(connectorID: id, kind: "deploy", filtersJSON: Data(#"{"environment":"prod","approved":true}"#.utf8)))),
            routine(.event(.init(connectorID: id, kind: "deploy", filtersJSON: Data(#"{"environment":"prod","environment":"stage"}"#.utf8))))]
        for dark in [false, true] {
            for (index, definition) in definitions.enumerated() {
                try await withUIRenderTurn {
                    let host = NSHostingView(rootView: RoutineAutomationEditView(session: .init(automation: definition))
                        .environmentObject(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 690, height: 760); host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width <= 690 && host.fittingSize.height <= 760)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "routine-edit-\(language)-\(dark ? "dark" : "light")-\(index).png"))
                    }
                }
            }
        }
    }
}
