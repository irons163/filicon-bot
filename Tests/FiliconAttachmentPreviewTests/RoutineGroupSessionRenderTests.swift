import AppKit
import Foundation
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
@testable import Filicon

@Suite("Routine group consent presentation", .timeLimit(.minutes(1)))
@MainActor struct RoutineGroupSessionRenderTests {
    @Test func authorityAndMemoryDisclosuresAreLocalized() {
        let keys = ["Background group session", "Background memory consent", "Allow saved facts for this background group",
            "Approve group session", "Revoke group session", "Text-only · no group session consent",
            "Runs may incur model costs; no price or whole-group budget guarantee is provided."]
            + [AutomationGroupSessionError.unavailable.rawValue, AutomationGroupSessionError.reviewRequired.rawValue,
               AutomationGroupSessionError.busy.rawValue]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys {
                expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en")
            }
        }
    }

    @Test func consentRendersInSevenLanguagesAndBothAppearances() async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-routine-consent-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let group = AgentGroup(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Reviewed group", summary: "Group goal", memberIDs: [owner])
        let automation = Automation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, agentID: owner,
            name: "Reviewed routine", prompt: "Review the isolated fixture project. Ask before modifying files.",
            trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), createdAt: Date(timeIntervalSince1970: 1_000))
        let binding = try AutomationGroupSessionBinding(id: owner, automation: automation, accountID: "local", group: group,
            memoryAccess: .savedFacts, reviewedAt: Date(timeIntervalSince1970: 1_000))
        let edit = RoutineGroupSessionEdit(automation: automation, accountID: "local", generation: 0, binding: binding, groups: [group])
        model.agents = [.init(id: owner, name: "Fixture member")]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: RoutineGroupSessionView(edit: edit).environmentObject(model)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 640, height: 740)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width <= 640)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "routine-group-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
