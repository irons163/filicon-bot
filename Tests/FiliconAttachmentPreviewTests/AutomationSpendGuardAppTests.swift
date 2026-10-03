import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAgents
import FiliconAutomations
@testable import Filicon

@Suite("Automation activity check app integration", .timeLimit(.minutes(1)))
@MainActor struct AutomationSpendGuardAppTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() async throws -> (URL, AppModel, AgentProfile, AgentProfile) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-spend-guard-app-\(UUID())")
        let profiles = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await profiles.create(name: "Fixture engineer", instructions: "No provider calls",
            providerID: "fixture", modelID: "fixture", at: now)
        let peer = try await profiles.create(name: "Fixture designer", instructions: "No provider calls",
            providerID: "fixture", modelID: "fixture", at: now.addingTimeInterval(1))
        let routines = try AutomationService(storeURL: root.appending(path: "automations.json"))
        for profile in [owner, peer] {
            _ = try await routines.save(.init(id: profile.id, agentID: profile.id, name: "Fixture routine", prompt: "No inference",
                trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), createdAt: now), now: now)
            try await routines.answerSpendGuard(.pause, agentID: profile.id, at: now)
        }
        // No bootstrap, scheduler, external listeners or user app launch.
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadWorkspaceData()
        await model.reloadAutomationDetails()
        return (root, model, owner, peer)
    }

    @Test func openingTheWorkspaceDoesNotAnswerOrMarkAllAgentsRead() async throws {
        let (root, model, owner, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = model.automationSpendGuardPrompts
        expectNoDifference(before.count, 2)
        model.selectRoute(.automations)
        await model.reloadAutomationDetails()
        expectNoDifference(model.automationSpendGuardPrompts, before)
        let read = try #require(model.beginAutomationAgentRead(id: owner.id))
        await model.markAutomationAgentViewed(read, at: now.addingTimeInterval(60))
        let after = model.automationSpendGuardPrompts
        expectNoDifference(after.map(\.id), before.map(\.id))
        expectNoDifference(after.first { $0.agentID == owner.id }?.state.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(after.first { $0.agentID != owner.id }, before.first { $0.agentID != owner.id })
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData(); await reopened.reloadAutomationDetails()
        expectNoDifference(reopened.automationSpendGuardPrompts, after)
    }

    @Test func oneCardsAnswerResumesOnlyItsOwnerAndCannotBeReplayed() async throws {
        let (root, model, owner, peer) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        let other = model.automations.filter { $0.agentID == peer.id }
        await model.answerAutomationSpendGuard(.resume, prompt: prompt, at: now.addingTimeInterval(60))
        expectNoDifference(model.automationSpendGuardPrompts.map(\.agentID), [peer.id])
        expectNoDifference(model.automations.filter { $0.agentID == peer.id }, other)
        let resumed = try #require(model.automations.first { $0.agentID == owner.id })
        #expect(resumed.enabled && !resumed.guardPaused)
        expectNoDifference(resumed.nextRunAt, now.addingTimeInterval(3_660))
        let beforeReplay = model.automations
        await model.answerAutomationSpendGuard(.pause, prompt: prompt, at: now.addingTimeInterval(61))
        expectNoDifference(model.automations, beforeReplay)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.snoozedUntil, now.addingTimeInterval(60 + AutomationSpendGuard.snoozeInterval))
        expectNoDifference(spend.cardID, nil)
        let history = await durable.history(automationID: resumed.id)
        expectNoDifference(history, [])
    }

    @Test(arguments: ["account", "archive", "wrong-owner", "storage"])
    func staleOrUnavailableCardsCannotCommitAnAnswer(mode: String) async throws {
        let (root, model, owner, peer) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var prompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        let before = model.automations
        switch mode {
        case "account":
            await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
            model.settings.accountScope = "other-fixture-account"
            await model.reloadAutomationDetails()
        case "archive": await model.archiveAgent(id: owner.id)
        case "wrong-owner":
            prompt = .init(id: prompt.id, agentID: peer.id, agentName: peer.name, accountID: prompt.accountID,
                generation: prompt.generation, state: prompt.state)
        case "storage":
            let file = root.appending(path: "automations.json")
            try FileManager.default.moveItem(at: file, to: root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        default: break
        }
        await model.answerAutomationSpendGuard(.resume, prompt: prompt, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations, before)
        expectNoDifference(model.answeringAutomationSpendGuardIDs, [])
        if mode == "storage" {
            #expect(model.errorMessage != nil)
            #expect(model.automationSpendGuardPrompts.contains { $0.id == prompt.id })
        }
    }

    @Test func anOldCardCannotAnswerAfterSwitchingAwayAndBackToTheSameAccount() async throws {
        let (root, model, owner, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let oldPrompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        let oldRead = try #require(model.beginAutomationAgentRead(id: owner.id))
        let before = model.automations
        await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
        model.settings.accountScope = "other-fixture-account"
        await model.cancelAutoReviewApprovals(nextAccountID: "local")
        model.settings.accountScope = "local"
        await model.reloadAutomationDetails()
        let current = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        expectNoDifference(current.id, oldPrompt.id)
        await model.answerAutomationSpendGuard(.resume, prompt: oldPrompt, at: now.addingTimeInterval(120))
        await model.markAutomationAgentViewed(oldRead, at: now.addingTimeInterval(120))
        expectNoDifference(model.automations, before)
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == owner.id }, current)
        #expect(current.generation != oldPrompt.generation)
        await model.answerAutomationSpendGuard(.resume, prompt: current, at: now.addingTimeInterval(120))
        #expect(model.automations.first { $0.agentID == owner.id }?.enabled == true)
    }

    @Test func cardMessagesAreAvailableInSevenLanguagesWithoutReinterpretingAgentNames() {
        let keys = [SpendGuardError.staleCard.rawValue, "This check affects only {0}'s individual routines; reviewed group sessions are excluded.",
            "Keep running or Resume postpones the next activity check for 30 days; it does not run missed tasks.",
            "Never ask disables this check only for this agent.", "Mark as read"]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en") }
            let name = "{1} / USER_NAME"
            let message = FiliconLocalization.render(.init(key: keys[1], arguments: [name]), language: language)
            #expect(message.contains(name))
        }
        // These labels are task execution choices, not running exercise, a
        // résumé/summary, podcasts, product descriptions or lodging terms.
        let actionKeys = ["Keep running", "Pause", "Never ask", "Resume", "Stay paused"]
        let actionLabels = [
            "en": ["Keep running", "Pause", "Never ask", "Resume", "Stay paused"],
            "zh-Hant": ["繼續執行", "暫停", "不再詢問", "繼續", "保持暫停"],
            "zh-Hans": ["继续运行", "暂停", "不再询问", "继续", "保持暂停"],
            "fr": ["Continuer l’exécution", "Mettre en pause", "Ne plus demander", "Reprendre", "Maintenir en pause"],
            "es": ["Seguir ejecutando", "Pausar", "No volver a preguntar", "Reanudar", "Mantener en pausa"],
            "ja": ["実行を続ける", "一時停止", "今後確認しない", "再開", "一時停止を続ける"],
            "ko": ["계속 실행", "일시 중지", "다시 묻지 않기", "재개", "일시 중지 유지"],
        ]
        for (language, labels) in actionLabels {
            for (key, label) in zip(actionKeys, labels) {
                expectNoDifference(FiliconLocalization.string(key, language: language), label)
            }
        }
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func cardsRenderInSevenLanguagesAtNarrowWidthAndBothAppearances(language: String) async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        for paused in [false, true] {
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let state = AutomationSpendGuardState(lastViewedAt: now, nudgedAt: paused ? nil : now,
                        guardPausedAutomationIDs: paused ? [id] : [], cardID: id)
                    let prompt = AutomationSpendGuardPrompt(id: id, agentID: id,
                        agentName: "A fixture owner with a deliberately long name", accountID: "local", generation: 1, state: state)
                    let host = NSHostingView(rootView: AutomationSpendGuardCard(prompt: prompt) { _ in }
                        .frame(width: 280, alignment: .leading).padding(16)
                        .frame(width: 312, height: 620, alignment: .topLeading)
                        .background(dark ? Color(white: 0.12) : Color.white)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 312, height: 620)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = host.appearance
                    window.contentView = host; defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    #expect(host.fittingSize.width <= 312 && host.fittingSize.height <= 620)
                    let controls = host.subviews.filter { !$0.frame.isEmpty }
                    expectNoDifference(controls.count, paused ? 2 : 3)
                    let bounds = controls.map { host.convert($0.bounds, from: $0) }
                    for (index, frame) in bounds.enumerated() {
                        #expect(host.bounds.contains(frame))
                        for other in bounds.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.appearance?.performAsCurrentDrawingAppearance {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                    }
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "spend-guard-\(language)-\(paused ? "paused" : "nudge")-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
