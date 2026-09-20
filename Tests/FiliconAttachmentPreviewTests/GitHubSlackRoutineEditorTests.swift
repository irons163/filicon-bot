import AppKit
import CryptoKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAutomations
@testable import Filicon

private struct PlatformEditorExecutor: AutomationExecutor {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Fixture only; no provider or network")
    }
}

@Suite("GitHub and Slack manual routine editors", .timeLimit(.minutes(1)))
@MainActor
struct GitHubSlackRoutineEditorTests {
    private let id = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000091")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func github() -> AutomationListenerDraft {
        var draft = AutomationListenerDraft.defaults(for: .github, id: id)
        draft.primary = "Example/Repo"
        return draft
    }

    @Test func githubRejectsConditionsTheLegacyInitializerWouldSilentlyDrop() throws {
        for (events, branch, users) in [
            ("pr-opened,unknown", "", ""), ("pr-opened,", "", ""), (",pr-opened", "", ""),
            ("pr-opened,ci-failed", "", ""), ("pr-opened,ci-passed", "bad branch", ""),
            ("pr-opened", "", ","), ("pr-opened", "", "alice,"),
            ("pr-opened", "", "@"), ("pr-opened", "", "a b"),
            (Array(repeating: "pr-opened", count: 15).joined(separator: ","), "", ""),
            ("pr-opened", "", Array(repeating: "alice", count: 51).joined(separator: ","))
        ] {
            var draft = github(); draft.secondary = events; draft.tertiary = branch; draft.quaternary = users
            #expect(throws: AutomationStateChangeError.invalidGitHubTrigger) { try draft.trigger }
            #expect(draft.validationMessage != nil)
        }
    }

    @Test func slackRejectsSilentFallbackTruncationAndNames() throws {
        for (channel, match, keyword) in [
            ("C123", "typo", ""), ("#general", "mention", ""), ("@alice", "message", ""),
            ("C" + String(repeating: "1", count: 80), "mention", ""),
            ("C123", "keyword", ""), ("", "message", ""),
            ("C123", "keyword", String(repeating: "a", count: 121)), ("C123", "keyword", "a\nb"),
            ("C123", "message", "retained keyword"), ("C123", "mention", "retained keyword")
        ] {
            var draft = AutomationListenerDraft.defaults(for: .slack, id: id)
            draft.primary = channel; draft.secondary = match; draft.tertiary = keyword
            #expect(throws: AutomationStateChangeError.invalidSlackTrigger) { try draft.trigger }
            #expect(draft.validationMessage != nil)
        }
    }

    @Test func supportedExistingConditionsCanBeEditedWithoutRewritingUntouchedValues() throws {
        let triggers: [AutomationTrigger] = [
            .platform(.github(try .init(repo: "Example/Repo", events: ["pr-opened", "ci-failed"], ciBranch: "Main", userAllowlist: ["alice"]))),
            .platform(.slack(try .init(channel: "C123", match: .keyword("Review")))),
            .platform(.slack(try .init(channel: "*", match: .reaction(emoji: ["wave", "+1"], bySelf: false))))
        ]
        for trigger in triggers + [.anyOf(triggers)] {
            let original = Automation(id: id, agentID: id, name: "Fixture", prompt: "No network", trigger: trigger, createdAt: now)
            var draft = RoutineEditDraft(original)
            #expect(draft.canEditConditions)
            draft.name = "Renamed"
            expectNoDifference(try draft.change.automation.trigger, trigger)
            expectNoDifference(try draft.change.previous, original)
            if case .anyOf = trigger {
                draft.listeners[1].tertiary = "Changed keyword"
                var expected = triggers
                expected[1] = .platform(.slack(try .init(channel: "C123", match: .keyword("Changed keyword"))))
                expectNoDifference(try draft.change.automation.trigger, .anyOf(expected))
            } else {
                // Editing the condition cannot rewrite a different field's semantics.
                draft.listeners[0].primary = draft.listeners[0].kind == .github ? "Example/Other" : "G456"
                try draft.change.automation.trigger.validateForManualEditing()
            }
        }
    }

    @Test func menuCoversEveryGitHubEventAndRetainsUnknownRawTokens() throws {
        expectNoDifference(Set(GitHubRoutineEvent.allCases.map(\.rawValue)), GitHubAutomationTrigger.knownEvents)
        for event in GitHubRoutineEvent.allCases {
            var draft = github(); draft.secondary = ""; draft.tertiary = "main"
            draft[gitHubEvent: event] = true
            #expect(draft[gitHubEvent: event])
            expectNoDifference(try draft.trigger, .platform(.github(try .init(repo: "Example/Repo", events: [event.rawValue], ciBranch: "main"))))
            draft[gitHubEvent: event] = false
            #expect(!draft[gitHubEvent: event])
            #expect(draft.validationMessage != nil)
        }
        var draft = github(); draft.secondary = "pr-opened,unknown,"; draft.tertiary = "main"
        draft[gitHubEvent: .prOpened] = false
        draft[gitHubEvent: .ciFailed] = true
        expectNoDifference(draft.secondary, "unknown,,ci-failed")
        #expect(throws: AutomationStateChangeError.invalidGitHubTrigger) { try draft.trigger }
    }

    @Test func githubNormalizesOnlyExplicitlySupportedInputAndEnforcesBoundaries() throws {
        var draft = github(); draft.secondary = " pr-opened, ci-failed,pr-opened "
        draft.tertiary = " Main "; draft.quaternary = " @Alice,alice,Dependabot[bot] "
        expectNoDifference(try draft.trigger, .platform(.github(try .init(repo: "Example/Repo", events: ["pr-opened", "ci-failed"],
            ciBranch: "Main", userAllowlist: ["alice", "dependabot[bot]"]))))
        for branch in ["a b", "@", ".hidden", "a//b", "a.lock/b", "main.", "main\u{0}", String(repeating: "a", count: 201)] {
            draft.tertiary = branch
            #expect(throws: AutomationStateChangeError.invalidGitHubTrigger) { try draft.trigger }
        }
        draft.tertiary = String(repeating: "a", count: 200)
        draft.secondary = Array(repeating: "pr-opened", count: 14).joined(separator: ",")
        draft.quaternary = Array(repeating: "alice", count: 50).joined(separator: ",")
        _ = try draft.trigger
        for repo in ["", "*/*", "example/..", "example/a b", "-owner/repo", String(repeating: "a", count: 136) + "/repo"] {
            draft.primary = repo
            #expect(throws: AutomationStateChangeError.invalidGitHubTrigger) { try draft.trigger }
        }
    }

    @Test func slackKeepsSeparateFiltersUntilExplicitlyClearedAndNeverDropsEmoji() throws {
        var draft = AutomationListenerDraft.defaults(for: .slack, id: id)
        draft.primary = " C123 "; draft.secondary = "keyword"; draft.tertiary = " Review "
        expectNoDifference(try draft.trigger, .platform(.slack(try .init(channel: "C123", match: .keyword("Review")))))
        expectDifference(draft) { draft.secondary = "reaction" } changes: { $0.secondary = "reaction" }
        #expect(throws: AutomationStateChangeError.invalidSlackTrigger) { try draft.trigger }
        draft.tertiary = ""; draft.slackEmoji = " :Eyes:, +1,eyes "
        expectNoDifference(try draft.trigger, .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["+1", "eyes"], bySelf: false)))))
        for text in [",", "eyes,", "eyes,,wave", "👀", "eyes::skin-tone-2", "bad name", String(repeating: "a", count: 81),
                     Array(repeating: "eyes", count: 9).joined(separator: ",")] {
            draft.slackEmoji = text
            #expect(throws: AutomationStateChangeError.invalidSlackTrigger) { try draft.trigger }
        }
        for text in ["", " \n", ":eyes:", "wave,+1", String(repeating: "a", count: 80), Array(repeating: "eyes", count: 8).joined(separator: ",")] {
            draft.slackEmoji = text; _ = try draft.trigger
        }
        draft.slackEmoji = "wave"
        for match in ["message", "mention", "keyword"] {
            draft.secondary = match; draft.tertiary = match == "keyword" ? "Review" : ""
            #expect(throws: AutomationStateChangeError.invalidSlackTrigger) { try draft.trigger }
            expectNoDifference(draft.slackEmoji, "wave")
        }
        draft.slackEmoji = ""; draft.tertiary = String(repeating: "a", count: 120)
        _ = try draft.trigger
    }

    @Test func unsupportedLegacyNamesSelfOnlyAndMalformedStoredConditionsStayReadOnly() throws {
        let malformed = try JSONDecoder().decode(GitHubAutomationTrigger.self,
            from: Data(#"{"repo":"example/repo","events":["pr-opened","future-event"],"ciBranch":null,"userAllowlist":[]}"#.utf8))
        let triggers: [AutomationTrigger] = [
            .platform(.github(malformed)),
            .platform(.slack(try .init(channel: "#design", match: .message))),
            .platform(.slack(try .init(channel: "C123", match: .reaction(emoji: ["eyes"], bySelf: true))))
        ]
        for trigger in triggers + [.anyOf(triggers)] {
            #expect(throws: (any Error).self) { try trigger.validateForManualEditing() }
            var draft = RoutineEditDraft(.init(id: id, agentID: id, name: "Legacy", prompt: "Preserve", trigger: trigger, createdAt: now))
            #expect(!draft.canEditConditions && draft.listeners.isEmpty)
            draft.name = "Renamed"
            expectNoDifference(try draft.change.automation.trigger, trigger)
        }
    }

    @Test(arguments: [AutomationListenerKind.github, .slack, .connector], ["save", "cancel", "stale", "storage"])
    func appEditsPersistOnlyWhenTheSessionAndStorageAreValid(kind: AutomationListenerKind, mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-platform-editor-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = try #require(await model.createAgent(name: "Fixture", summary: "", instructions: "No provider calls", providerID: "fixture", modelID: "fixture"))
        var listener = kind == .github ? github() : AutomationListenerDraft.defaults(for: kind, id: id)
        if kind == .connector { listener.primary = id.uuidString; listener.secondary = "deploy"; listener.filtersJSON = #"{"environment":"prod"}"# }
        await model.createAutomation(agentID: agent.id, name: "Fixture", prompt: "No network", trigger: try listener.trigger)
        let before = try #require(model.automations.first)
        let session = try #require(model.beginAutomationEdit(before))
        defer { model.endAutomationEdit(session) }
        var draft = RoutineEditDraft(before)
        try #require(draft.canEditConditions)
        draft.listeners[0].primary = kind == .github ? "example/changed" : "C456"
        if kind == .connector { draft.listeners[0].primary = "aaaaaaaa-0000-0000-0000-000000000092" }
        let expectedDraft = draft
        switch mode {
        case "cancel": model.endAutomationEdit(session)
        case "stale": await model.setAutomationEnabled(id: before.id, enabled: false)
        case "storage":
            try FileManager.default.moveItem(at: root.appending(path: "automations.json"), to: root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: root.appending(path: "automations.json"), withIntermediateDirectories: false)
        default: break
        }
        if mode == "save" {
            try await model.saveAutomationEdit(session, draft: draft)
            var expected = before; expected.trigger = try draft.change.automation.trigger; expected.revision += 1
            expectNoDifference(model.automations, [expected])
            let restored = try AutomationService(storeURL: root.appending(path: "automations.json"))
            let list = await restored.list(), history = await restored.history(automationID: before.id)
            // App-created dates include sub-microsecond precision; compare the
            // entire definition at the store's documented Codable boundary.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            let persisted = try decoder.decode(Automation.self, from: encoder.encode(expected))
            expectNoDifference(list, [persisted]); expectNoDifference(history, [])
        } else {
            let current = model.automations
            await #expect(throws: (any Error).self) { try await model.saveAutomationEdit(session, draft: draft) }
            expectNoDifference(model.automations, current)
            expectNoDifference(draft, expectedDraft)
        }
    }

    @Test func newMessagesHaveSevenLanguageCoverage() {
        let keys = GitHubRoutineEvent.allCases.map(\.label) + ["Slack conversation ID or *", AutomationListenerEditor.githubNotice, AutomationListenerEditor.slackNotice]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en", "\(language): \(key)") }
        }
        for (key, expected) in [("Match", "일치 조건"), ("Keyword", "키워드"), ("Mention", "멘션"), ("Reaction", "반응"),
                                ("Emoji names, comma-separated", "이모지 이름 (쉼표로 구분)"), ("CI branch (required for CI events)", "CI 브랜치 (CI 이벤트에 필수)")] {
            expectNoDifference(FiliconLocalization.string(key, language: "ko"), expected)
        }
        expectNoDifference(FiliconLocalization.string("CI branch (required for CI events)", language: "fr"), "Branche CI (obligatoire pour les événements CI)")
        expectNoDifference(FiliconLocalization.string("Match", language: "es"), "Coincidencia")
    }

    @Test func everyMenuChoiceMatchesVerifiedFixturesAndPreservesFilterSemantics() throws {
        let pr: [String: Any] = ["user": ["login": "alice"], "merged": true]
        let vectors: [(GitHubRoutineEvent, String, String, [String: Any])] = [
            (.prOpened, "pull_request", "opened", ["pull_request": pr]),
            (.prPushed, "pull_request", "synchronize", ["pull_request": pr]),
            (.prMerged, "pull_request", "closed", ["pull_request": pr]),
            (.reviewRequested, "pull_request", "review_requested", ["pull_request": pr]),
            (.reviewApproved, "pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "approved"]]),
            (.reviewChangesRequested, "pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "changes_requested"]]),
            (.reviewCommented, "pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "commented"]]),
            (.prComment, "issue_comment", "created", ["issue": ["user": ["login": "alice"], "pull_request": [:]]]),
            (.inlineReviewComment, "pull_request_review_comment", "created", ["pull_request": pr]),
            (.reviewThreadResolved, "pull_request_review_thread", "resolved", ["pull_request": pr]),
            (.reviewThreadUnresolved, "pull_request_review_thread", "unresolved", ["pull_request": pr]),
            (.issueAssigned, "issues", "assigned", ["issue": [:], "assignee": ["login": "outsider"]]),
            (.ciPassed, "workflow_run", "completed", ["workflow_run": ["event": "push", "status": "completed", "conclusion": "success", "head_branch": "main", "head_repository": ["full_name": "Example/Repo"]]]),
            (.ciFailed, "workflow_run", "completed", ["workflow_run": ["event": "push", "status": "completed", "conclusion": "failure", "head_branch": "main", "head_repository": ["full_name": "Example/Repo"]]])
        ]
        expectNoDifference(Set(vectors.map { $0.0 }), Set(GitHubRoutineEvent.allCases))
        for (option, header, action, extra) in vectors {
            var draft = github(); draft.secondary = ""; draft[gitHubEvent: option] = true
            draft.tertiary = "main"; draft.quaternary = "alice"
            let trigger = try draft.trigger
            var fields: [String: Any] = ["repository": ["full_name": "Example/Repo"], "sender": ["login": "alice"], "action": action]
            fields.merge(extra) { _, new in new }
            let event = try verified(.github, fields: fields, header: header)
            guard case .platform(let platform) = trigger else { Issue.record("Expected platform"); continue }
            #expect(platform.matches(event))
            draft.primary = "example/other"
            guard case .platform(let wrongRepo) = try draft.trigger else { continue }
            #expect(!wrongRepo.matches(event))
            draft.primary = "Example/Repo"; draft.quaternary = "outsider"
            guard case .platform(let wrongUser) = try draft.trigger else { continue }
            expectNoDifference(wrongUser.matches(event), option == .ciPassed || option == .ciFailed)
            expectNoDifference(try JSONDecoder().decode(AutomationTrigger.self, from: JSONEncoder().encode(trigger)), trigger)
        }
        let slackEvents = try [
            verified(.slack, fields: ["type": "message", "user": "U123", "channel": "C123", "text": "DESIGN review"]),
            verified(.slack, fields: ["type": "app_mention", "user": "U123", "channel": "C123", "text": "<@UBOT> design"]),
            verified(.slack, fields: ["type": "reaction_added", "user": "U123", "reaction": "eyes", "item": ["type": "message", "channel": "C123"]])
        ]
        for (match, keyword, emoji, expected) in [
            ("message", "", "", [true, true, false]), ("mention", "", "", [false, true, false]),
            ("keyword", "design", "", [true, true, false]), ("reaction", "", ":Eyes:", [false, false, true])
        ] {
            var draft = AutomationListenerDraft.defaults(for: .slack, id: id)
            draft.primary = "C123"; draft.secondary = match; draft.tertiary = keyword; draft.slackEmoji = emoji
            guard case .platform(let platform) = try draft.trigger else { Issue.record("Expected platform"); continue }
            expectNoDifference(slackEvents.map(platform.matches), expected)
            draft.primary = "C456"
            guard case .platform(let wrongChannel) = try draft.trigger else { continue }
            expectNoDifference(slackEvents.map(wrongChannel.matches), [false, false, false])
        }
    }

    @Test func mixedORConditionEditPersistsWithoutResettingTimeOrHistoryAndRunsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-platform-or-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "automations.json"), service = try AutomationService(storeURL: url)
        let time = AutomationTrigger.cron(expression: "@every 1h", timeZoneIdentifier: "UTC")
        let slack = AutomationListenerDraft.defaults(for: .slack, id: id)
        let before = try await service.save(.init(id: id, agentID: id, name: "Fixture", prompt: "No network",
            trigger: .anyOf([time, try github().trigger, try slack.trigger]), createdAt: now), now: now)
        _ = try await service.runNow(id: id, executor: PlatformEditorExecutor(), now: now)
        let history = await service.history(automationID: id), current = try #require(await service.list().first)
        var draft = RoutineEditDraft(before)
        draft.listeners[1].secondary = "pr-opened"; draft.listeners[1].quaternary = "alice"
        draft.listeners[2].primary = "C123"
        let saved = try await service.updateManualDefinition(draft.change, lifetime: .init(), now: now.addingTimeInterval(30))
        expectNoDifference(saved.nextRunAt, current.nextRunAt)
        expectNoDifference(saved.lastRunAt, current.lastRunAt)
        let restored = try AutomationService(storeURL: url)
        let restoredHistory = await restored.history(automationID: id), restoredList = await restored.list()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let persistedHistory = try decoder.decode([AutomationRun].self, from: encoder.encode(history))
        expectNoDifference(restoredHistory, persistedHistory); expectNoDifference(restoredList, [saved])
        let event = try verified(.slack, fields: ["type": "app_mention", "user": "U123", "channel": "C123", "text": "hello"])
        let runs = await restored.fire(events: [event, event], executor: PlatformEditorExecutor(), now: now.addingTimeInterval(60))
        expectNoDifference(runs.map(\.status), [.ok])
        let again = try AutomationService(storeURL: url)
        let replay = await again.fire(events: [event], executor: PlatformEditorExecutor(), now: now.addingTimeInterval(120))
        expectNoDifference(replay, [])
    }

    private func verified(_ provider: AutomationIngressProvider, fields: [String: Any], header: String = "") throws -> AutomationEvent {
        let secret = Data("fixture-not-a-real-key".utf8)
        let route = AutomationIngressRoute(id: id, name: "Fixture", provider: provider, secretReference: "fixture")
        let payload = provider == .slack ? ["event_id": "fixture", "event": fields] : fields
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let timestamp = String(Int(now.timeIntervalSince1970))
        var signed = provider == .slack ? Data("v0:\(timestamp):".utf8) : Data(); signed.append(body)
        let signature = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
        let headers = provider == .slack
            ? ["x-slack-request-timestamp": timestamp, "x-slack-signature": "v0=" + signature]
            : ["x-github-event": header, "x-github-delivery": "fixture", "x-hub-signature-256": "sha256=" + signature]
        let request = AutomationHTTPRequest(method: "POST", path: route.path, headers: headers, body: body)
        let auth = try AutomationIngressSignatureVerifier.verify(provider: provider, request: request, secret: secret, now: now)
        return try AutomationIngressEventNormalizer.event(route: route, request: request, nonce: auth.nonce, now: now)
    }

    @Test func nativeEditorsRenderMenusAndRetainedErrorsInSevenLanguages() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        var github = github(); github.secondary = "pr-opened,ci-failed"; github.tertiary = "main"; github.quaternary = "alice"
        var slack = AutomationListenerDraft.defaults(for: .slack, id: id)
        slack.primary = "C123"; slack.secondary = "reaction"; slack.slackEmoji = "eyes, +1"
        var invalid = slack; invalid.secondary = "keyword"; invalid.tertiary = "Review"
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                for (index, draft) in [github, slack, invalid].enumerated() {
                    let host = NSHostingView(rootView: AutomationListenerEditor(listener: .constant(draft), canRemove: true, remove: {})
                        .padding(20).frame(width: 440).background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 440, height: 1100); host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 1100 && host.fittingSize.width <= 440)
                    host.setFrameSize(.init(width: 440, height: ceil(host.fittingSize.height))); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "github-slack-\(language)-\(dark ? "dark" : "light")-\(index).png"))
                    }
                }
            }
        }
    }
}
