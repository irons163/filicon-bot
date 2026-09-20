import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAutomations
@testable import Filicon

@Suite("Connector manual routine editor", .timeLimit(.minutes(1)))
@MainActor
struct ConnectorRoutineEditorTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000113")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func listener(_ filters: String = #"{"environment":"prod","approved":true}"#) -> AutomationListenerDraft {
        var draft = AutomationListenerDraft.defaults(for: .connector, id: id)
        draft.primary = id.uuidString; draft.secondary = "deploy"; draft.filtersJSON = filters
        return draft
    }

    @Test func editorPreservesUntouchedRawJSONAndRejectsUnsafeChanges() throws {
        let raw = Data("{ \"environment\": \"prod\",\n \"approved\": true }".utf8)
        let original = Automation(id: id, agentID: id, name: "Fixture", prompt: "No network",
            trigger: .event(.init(connectorID: id, kind: "deploy", filtersJSON: raw)), createdAt: now)
        var draft = RoutineEditDraft(original)
        #expect(draft.canEditConditions)
        draft.name = "Renamed"
        expectNoDifference(try draft.change.automation.trigger, original.trigger)
        expectDifference(draft) { draft.listeners[0].filtersJSON = #"{"environment":"stage"}"# } changes: {
            $0.listeners[0].filtersJSON = #"{"environment":"stage"}"#
        }
        expectNoDifference(try draft.change.automation.trigger, try listener(#"{"environment":"stage"}"#).trigger)
        for raw in ["[]", "broken", #"{"environment":"stage","environment":"prod"}"#] {
            draft.listeners[0].filtersJSON = raw
            #expect(throws: ConnectorEventFilterError.invalidFilters) { try draft.change }
            #expect(draft.validationMessage != nil)
            var legacy = original
            legacy.trigger = .event(.init(connectorID: id, kind: "deploy", filtersJSON: Data(raw.utf8)))
            var readonly = RoutineEditDraft(legacy); readonly.prompt = "Changed instruction"
            #expect(!readonly.canEditConditions)
            expectNoDifference(try readonly.change.automation.trigger, legacy.trigger)
        }
        var invalid = listener(); invalid.primary = "a connector name"
        #expect(throws: ConnectorEventFilterError.invalidConnector) { try invalid.trigger }
        expectNoDifference(invalid.validationMessage, ConnectorEventFilterError.invalidConnector.rawValue)
        invalid.primary = id.uuidString; invalid.secondary = "deploy "
        #expect(throws: ConnectorEventFilterError.invalidKind) { try invalid.trigger }
        #expect(RoutineEditDraft.editableKinds.contains(.connector))
    }

    @Test func allConnectorMessagesHaveSevenLanguageCoverage() {
        let keys = ["Connector event", "Connector UUID", "Event kind", "JSON filters", AutomationListenerEditor.connectorNotice,
            ConnectorEventFilterError.invalidConnector.rawValue, ConnectorEventFilterError.invalidKind.rawValue,
            ConnectorEventFilterError.invalidFilters.rawValue]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en", "\(language): \(key)") }
        }
    }

    @Test func validEmptyAndDuplicateFiltersRenderInSevenLanguages() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let drafts = [listener(), listener("{}"), listener(#"{"environment":"stage","environment":"prod"}"#)]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                for (index, draft) in drafts.enumerated() {
                    let host = NSHostingView(rootView: AutomationListenerEditor(listener: .constant(draft), canRemove: true, remove: {})
                        .padding(20).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 440, height: 900); host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 900 && host.fittingSize.width <= 440)
                    host.setFrameSize(.init(width: 440, height: ceil(host.fittingSize.height))); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "connector-\(language)-\(dark ? "dark" : "light")-\(index).png"))
                    }
                }
            }
        }
    }
}
