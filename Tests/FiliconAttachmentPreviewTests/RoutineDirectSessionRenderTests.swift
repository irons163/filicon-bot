import AppKit
import Foundation
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutomations
import FiliconDomain
@testable import Filicon

@Suite("Routine agent consent presentation", .timeLimit(.minutes(1)))
@MainActor struct RoutineDirectSessionRenderTests {
    @Test func authorityAndMemoryDisclosuresAreLocalized() {
        let keys = ["Background agent session", "Allow saved facts for this background agent", "Approve agent session",
            "Revoke agent session", "Text-only · no background session consent", "Open conversation",
            "A background session belongs to another account. Revoke it in that account before switching session type.",
            "Scheduled, event and manual runs will use this exact agent conversation and shared tool runner. Its text history will be sent to the reviewed model provider; attachments are not automatically forwarded. Tools and peer messages still require their existing approvals. Busy conversations and pending questions are not interrupted or retried. Changes to the routine, account, binding, persona or model require another review.",
            "Independent consent: this agent may send its permitted private, shared user and joined-project facts to its configured model provider during this routine. Delegated agents do not inherit memory consent. This does not authorize publishing unrelated facts or collecting memory suggestions, episodes or synthesis from routine wakes. Off disables memory recall, search and changes for this run."]
            + [AutomationDirectSessionError.unavailable.rawValue, AutomationDirectSessionError.reviewRequired.rawValue,
               AutomationDirectSessionError.busy.rawValue, AutomationDirectSessionError.conflictingSession.rawValue]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys {
                expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en")
            }
        }
        // A non-English value is not sufficient: the reused picker label must
        // mean conversation, not conversion (ja) or field of research (ko).
        expectNoDifference(FiliconLocalization.string("Conversation", language: "ja"), "会話")
        expectNoDifference(FiliconLocalization.string("Conversation", language: "ko"), "대화")
    }

    @Test func consentRendersInSevenLanguagesAndBothAppearances() async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-consent-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000081")!
        let profile = AgentProfile(id: owner, name: "Reviewed agent", instructions: "Fixture persona")
        var conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000082")!, title: "Reviewed conversation")
        conversation.agentBinding = .init(accountID: "local", agentID: owner)
        let automation = Automation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000083")!, agentID: owner,
            name: "Reviewed routine", prompt: "Review the isolated fixture project. Ask before modifying files.",
            trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"), createdAt: Date(timeIntervalSince1970: 1_000))
        let binding = try AutomationDirectSessionBinding(automation: automation, accountID: "local",
            conversation: conversation, profile: profile, memoryAccess: .savedFacts, reviewedAt: Date(timeIntervalSince1970: 1_000))
        let edit = RoutineDirectSessionEdit(automation: automation, accountID: "local", generation: 0,
            binding: binding, profile: profile, conversations: [conversation])
        model.agents = [profile]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: RoutineDirectSessionView(edit: edit).environmentObject(model)
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
                        try png.write(to: output.appending(path: "routine-direct-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
