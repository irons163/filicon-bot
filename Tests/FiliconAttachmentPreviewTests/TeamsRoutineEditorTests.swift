import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAutomations
@testable import Filicon

@Suite("Teams manual routine editor", .timeLimit(.minutes(1)))
@MainActor
struct TeamsRoutineEditorTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000141")!
    private let tenant = "aaaaaaaa-0000-0000-0000-000000000001"
    private let graph = "bbbbbbbb-0000-0000-0000-000000000001"
    private let bot = "19:Fixture-Team@thread.tacv2"
    private let channel = "19:Fixture-Channel@thread.tacv2"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func listener() -> AutomationListenerDraft {
        var value = AutomationListenerDraft.defaults(for: .teams, id: id)
        value.primary = tenant; value.secondary = graph + ", " + bot
        value.tertiary = channel; value.quaternary = "deploy"
        return value
    }
    private func routine(_ trigger: AutomationTrigger) -> Automation {
        .init(id: id, agentID: id, name: "Teams fixture", prompt: "No network or model", trigger: trigger, createdAt: now)
    }

    @Test func validTeamsConditionsCanBeEditedWithoutRewritingUntouchedMembers() throws {
        let teams = AutomationTrigger.platform(.microsoftTeams(try .init(tenantID: tenant.uppercased(), teamIDs: [graph.uppercased(), bot],
            channelIDs: [channel], messageContains: "deploy")))
        let time = AutomationTrigger.cron(expression: "@daily", timeZoneIdentifier: nil)
        let original = routine(.anyOf([time, teams]))
        var draft = RoutineEditDraft(original)
        #expect(draft.canEditConditions)
        // Require a usable draft before indexing, so a failed regression is not a crash.
        _ = try #require(draft.listeners.count == 2 ? draft.listeners.last : nil)
        expectNoDifference(try draft.change.automation, original)
        draft.name = "Renamed"
        expectNoDifference(try draft.change.automation.trigger, original.trigger)
        expectDifference(draft) { draft.listeners[1].quaternary = "ship" } changes: { $0.listeners[1].quaternary = "ship" }
        let expected = AutomationTrigger.platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph, bot],
            channelIDs: [channel], messageContains: "ship")))
        expectNoDifference(try draft.change.automation.trigger, .anyOf([time, expected]))
        #expect(RoutineEditDraft.editableKinds.contains(.teams))
    }

    @Test func rawEmptyCommaSegmentsAreRejectedInsteadOfDropped() throws {
        var draft = listener()
        draft.tertiary = channel + ","
        #expect(draft.validationMessage != nil)
        #expect(throws: (any Error).self) { try draft.trigger }
    }

    @Test func strictListsNormalizeOnlyUUIDsAndEnforceRawLimits() throws {
        var draft = listener()
        draft.primary = " " + tenant.uppercased() + " "
        draft.secondary = graph.uppercased() + "," + graph + "," + bot + "," + bot.lowercased()
        draft.tertiary = channel + "," + channel.lowercased()
        expectNoDifference(try draft.trigger, .platform(.microsoftTeams(try .init(tenantID: tenant,
            teamIDs: [graph, bot, bot.lowercased()], channelIDs: [channel, channel.lowercased()], messageContains: "deploy"))))
        for field in [\AutomationListenerDraft.secondary, \.tertiary] {
            var valid = listener()
            valid[keyPath: field] = Array(repeating: bot, count: 50).joined(separator: ",")
            _ = try valid.trigger
            for raw in [",", " , ", bot + ",", "," + bot, bot + ",," + bot,
                        Array(repeating: bot, count: 51).joined(separator: ","), "*", "prefix*", "a b", "a\u{0}b",
                        String(repeating: "a", count: 201), String(repeating: "中", count: 67)] {
                var value = listener(); value[keyPath: field] = raw
                #expect(throws: AutomationEditError.invalidTeamsScope) { try value.trigger }
                expectNoDifference(value.validationMessage, AutomationEditError.invalidTeamsScope.rawValue)
            }
            valid[keyPath: field] = String(repeating: "a", count: 200); _ = try valid.trigger
        }
        for raw in ["", "name", "{\(tenant)}", tenant + "x", "*"] {
            var value = listener(); value.primary = raw
            #expect(throws: AutomationEditError.invalidTeamsScope) { try value.trigger }
        }
        var empty = listener(); empty.secondary = " "
        #expect(throws: AutomationEditError.invalidTeamsScope) { try empty.trigger }
        empty = listener(); empty.tertiary = " "
        expectNoDifference(try empty.trigger, .platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph, bot], messageContains: "deploy"))))
    }

    @Test func literalFilterIsBoundedAndAuthenticationCannotBeRelaxed() throws {
        for raw in ["", "  ", "\ntext", "text\n", "a\tb", "a\u{0}b", String(repeating: "字", count: 121)] {
            var value = listener(); value.quaternary = raw
            #expect(throws: AutomationEditError.invalidTeamsText) { try value.trigger }
            expectNoDifference(value.validationMessage, AutomationEditError.invalidTeamsText.rawValue)
        }
        for raw in ["[deploy].*", String(repeating: "字", count: 120), " Déployer "] {
            var value = listener(); value.quaternary = raw
            let condition = try value.trigger
            expectNoDifference(condition, .platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph, bot], channelIDs: [channel],
                messageContains: raw.trimmingCharacters(in: .whitespacesAndNewlines), messageContainsIsRegex: false, blockUnauthenticatedUsers: true))))
            let payload: [String: Any] = ["supportedEvent": true, "authenticated": true, "platformMatched": true,
                "tenantId": tenant, "teamId": bot, "graphTeamId": graph, "channelId": channel, "text": raw]
            let event = AutomationEvent(connectorID: id, kind: "microsoftTeams", externalEventID: "fixture",
                payloadJSON: try JSONSerialization.data(withJSONObject: payload))
            guard case .platform(let platform) = condition else { Issue.record("Expected Teams condition"); continue }
            #expect(!platform.matches(event))
        }
        expectNoDifference(AutomationListenerDraft.defaults(for: .teams, id: id).validationMessage, AutomationEditError.invalidTeamsScope.rawValue)
    }

    @Test func legacyPolicyRegexAndInvalidScopesAreReadOnlyWithoutMigration() throws {
        let triggers: [AutomationTrigger] = [
            .platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph], messageContains: "deploy", blockUnauthenticatedUsers: false))),
            .platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph], messageContains: "deploy.*", messageContainsIsRegex: true))),
            .platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph]))),
            .platform(.microsoftTeams(try .init(tenantID: "tenant-name", teamIDs: [graph], messageContains: "deploy"))),
            .platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph], channelIDs: ["*"], messageContains: "deploy")))
        ]
        for trigger in triggers {
            for value in [trigger, .anyOf([.cron(expression: "@daily", timeZoneIdentifier: nil), trigger])] {
                var draft = RoutineEditDraft(routine(value))
                #expect(!draft.canEditConditions)
                draft.name = "Renamed"
                var expected = draft.original; expected.name = "Renamed"
                expectNoDifference(try draft.change.automation, expected)
                draft.listeners = [listener()]
                #expect(throws: AutomationEditError.unsupportedTrigger) { try draft.change }
            }
        }
    }

    @Test func serviceRejectsFormBypassAndKeepsTimeAnchorHistoryAndPolicy() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-teams-editor-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "automations.json"), service = try AutomationService(storeURL: url)
        let time = AutomationTrigger.cron(expression: "@every 1h", timeZoneIdentifier: "UTC")
        let original = try await service.save(routine(.anyOf([time, listener().trigger])), now: now)
        var draft = RoutineEditDraft(original); draft.listeners[1].tertiary = ""
        let change = try draft.change
        let saved = try await service.updateManualDefinition(change, lifetime: .init(), now: now.addingTimeInterval(300))
        var expected = original; expected.trigger = change.automation.trigger; expected.revision += 1
        expectNoDifference(saved, expected)
        for condition in [
            try TeamsAutomationTrigger(tenantID: tenant, teamIDs: [graph], messageContains: "deploy", blockUnauthenticatedUsers: false),
            try TeamsAutomationTrigger(tenantID: tenant, teamIDs: [graph], messageContains: "deploy", messageContainsIsRegex: true),
            try TeamsAutomationTrigger(tenantID: tenant, teamIDs: [graph], channelIDs: ["bad,id"], messageContains: "deploy"),
            try TeamsAutomationTrigger(tenantID: tenant, teamIDs: [graph], messageContains: nil)
        ] {
            var forged = saved; forged.trigger = .anyOf([time, .platform(.microsoftTeams(condition))])
            await #expect(throws: AutomationEditError.self) {
                try await service.updateManualDefinition(.init(operation: .update, automation: forged, previous: saved), lifetime: .init(), now: now)
            }
        }
        let reopened = try AutomationService(storeURL: url)
        let restored = await reopened.list(), current = await service.list(), history = await service.history(automationID: id)
        expectNoDifference(restored, [expected])
        expectNoDifference(current, [expected])
        expectNoDifference(history, [])
    }

    @Test(arguments: ["save", "cancel", "account", "stale", "archive", "storage"])
    func teamsChangesUseTheSameManualSessionFences(_ mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-teams-editor-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = try #require(await model.createAgent(name: "Fixture", summary: "", instructions: "No provider calls", providerID: "fixture", modelID: "fixture"))
        await model.createAutomation(agentID: agent.id, name: "Fixture", prompt: "No calls", trigger: try listener().trigger)
        let before = try #require(model.automations.first)
        let session = try #require(model.beginAutomationEdit(before))
        defer { model.endAutomationEdit(session) }
        var draft = RoutineEditDraft(before)
        _ = try #require(draft.listeners.first)
        draft.listeners[0].quaternary = "ship"
        let expectedDraft = draft
        switch mode {
        case "cancel": model.endAutomationEdit(session)
        case "account": await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
        case "stale": await model.setAutomationEnabled(id: before.id, enabled: false)
        case "archive": await model.archiveAgent(id: agent.id)
        case "storage":
            let url = root.appending(path: "automations.json")
            try FileManager.default.moveItem(at: url, to: root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        default: break
        }
        if mode == "save" {
            try await model.saveAutomationEdit(session, draft: draft)
            var expected = before; expected.trigger = try draft.change.automation.trigger; expected.revision += 1
            expectNoDifference(model.automations, [expected])
            let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
            await reopened.reloadAutomationDetails(markViewed: false)
            // Compare the full persisted representation, including the store's
            // millisecond Date round-trip rather than submillisecond clock bits.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let durable = try decoder.decode(Automation.self, from: encoder.encode(expected))
            expectNoDifference(reopened.automations, [durable])
            #expect(reopened.automationHistory.values.allSatisfy { $0.isEmpty })
        } else {
            let current = model.automations
            await #expect(throws: (any Error).self) { try await model.saveAutomationEdit(session, draft: draft) }
            expectNoDifference(model.automations, current)
            expectNoDifference(draft, expectedDraft)
        }
    }

    @Test func editorLabelsAndErrorsHaveSevenLanguageCoverage() {
        let keys = ["Teams event execution unavailable", "Tenant UUID", "Graph UUIDs or exact Bot team IDs, comma-separated",
            "Literal message filter (required, up to 120 characters)", AutomationListenerEditor.teamsFilterNotice,
            AutomationEditError.invalidTeamsScope.rawValue, AutomationEditError.invalidTeamsText.rawValue,
            AutomationEditError.unsupportedTeamsPolicy.rawValue]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en", "\(language): \(key)") }
        }
        expectNoDifference(FiliconLocalization.string("Channel IDs, comma-separated (optional)", language: "ko"), "채널 ID, 쉼표로 구분 (선택 사항)")
    }

    @Test func teamsFieldsAndReadOnlySheetsRenderInSevenLanguages() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-teams-editor-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        var invalid = listener(); invalid.tertiary += ","
        let readOnly = routine(.platform(.microsoftTeams(try .init(tenantID: tenant, teamIDs: [graph], messageContains: "deploy.*", messageContainsIsRegex: true))))
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                for (index, draft) in [listener(), invalid].enumerated() {
                    let host = NSHostingView(rootView: AutomationListenerEditor(listener: .constant(draft), canRemove: true, remove: {})
                        .padding(20).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    try render(host, width: 440, height: 1100, output: output, name: "teams-fields-\(language)-\(dark)-\(index)")
                }
                for (index, definition) in [routine(try listener().trigger), readOnly].enumerated() {
                    let host = NSHostingView(rootView: RoutineAutomationEditView(session: .init(automation: definition))
                        .environmentObject(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    try render(host, width: 690, height: 760, output: output, name: "teams-sheet-\(language)-\(dark)-\(index)")
                }
            }
        }
    }

    private func render<V: View>(_ host: NSHostingView<V>, width: CGFloat, height: CGFloat, output: URL?, name: String) throws {
        host.appearance = NSAppearance(named: name.contains("-true-") ? .darkAqua : .aqua)
        host.frame = .init(x: 0, y: 0, width: width, height: height); host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width <= width && host.fittingSize.height <= height)
        host.setFrameSize(.init(width: width, height: ceil(host.fittingSize.height))); host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        if let output {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try png.write(to: output.appending(path: name + ".png"))
        }
    }
}
