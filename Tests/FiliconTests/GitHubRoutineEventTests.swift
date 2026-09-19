import CryptoKit
import CustomDump
import Foundation
import Testing
@testable import FiliconAutomations

private struct GitHubFixtureExecutor: AutomationExecutor {
    var inspect: @Sendable (Automation, String, [AutomationEvent]) async -> Void = { _, _, _ in }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        await inspect(automation, prompt, events)
        return .init(detail: "Fixture only; no model or network")
    }
}

private struct GitHubFixtureSecrets: AutomationIngressSecretProvider {
    let value: Data
    func secret(for reference: String) async throws -> Data { value }
}

@Suite("GitHub routine event boundaries", .timeLimit(.minutes(1)))
struct GitHubRoutineEventTests {
    private let now = Date(timeIntervalSince1970: 3_000)
    private let connector = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
    private func event(_ fields: [String: Any], id: String = "delivery") throws -> AutomationEvent {
        .init(connectorID: connector, kind: "github", externalEventID: id,
              payloadJSON: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), occurredAt: now)
    }

    @Test func triggerEncodingIsStableAndRetainsLegacyStoredShape() throws {
        let first = try GitHubAutomationTrigger(repo: "example/project", events: ["pr-opened", "ci-failed"], ciBranch: "main")
        let second = try GitHubAutomationTrigger(repo: "example/project", events: ["ci-failed", "pr-opened"], ciBranch: "main")
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        expectNoDifference(try encoder.encode(first), try encoder.encode(second))
        expectNoDifference(try JSONDecoder().decode(GitHubAutomationTrigger.self, from: encoder.encode(first)), first)
        let legacy = Data(#"{"repo":"example/project","events":["pr-opened","ci-failed"],"ciBranch":"main","userAllowlist":[]}"#.utf8)
        expectNoDifference(try JSONDecoder().decode(GitHubAutomationTrigger.self, from: legacy), first)
    }

    @Test(arguments: Array(GitHubAutomationTrigger.knownEvents).sorted())
    func userFiltersDistinguishAuthorActorAndBranchCI(kind: String) throws {
        let trigger = PlatformAutomationTrigger.github(try .init(repo: "example/project", events: [kind],
            ciBranch: "main", userAllowlist: ["alice"]))
        let prEvents: Set<String> = ["pr-opened", "pr-pushed", "pr-merged", "pr-comment", "inline-review-comment"]
        let ciEvents: Set<String> = ["ci-passed", "ci-failed"]
        for author in ["ALICE", "outsider", ""] {
            for actor in ["Alice", "outsider", ""] {
                let fields: [String: Any] = ["repo": "EXAMPLE/Project", "event": kind, "branch": "main", "prOwner": author,
                    "actor": actor, "subjectPresent": true]
                let expected = ciEvents.contains(kind) || (prEvents.contains(kind) ? author == "ALICE"
                    : kind == "issue-assigned" ? actor == "Alice" : author == "ALICE" && actor == "Alice")
                expectNoDifference(try trigger.matches(event(fields)), expected)
                var wrongRepo = fields; wrongRepo["repo"] = "private/other"
                #expect(try !trigger.matches(event(wrongRepo)))
                if ciEvents.contains(kind) {
                    var wrongBranch = fields; wrongBranch["branch"] = "Main"
                    #expect(try !trigger.matches(event(wrongBranch)))
                    wrongBranch.removeValue(forKey: "branch")
                    #expect(try !trigger.matches(event(wrongBranch)))
                }
            }
        }
        let everyone = PlatformAutomationTrigger.github(try .init(repo: "example/project", events: [kind], ciBranch: "main"))
        #expect(try everyone.matches(event(["repo": "example/project", "event": kind, "branch": "main", "subjectPresent": true])))
        if !ciEvents.contains(kind) {
            #expect(try !everyone.matches(event(["repo": "example/project", "event": kind, "subjectPresent": false])))
        }
    }

    private func webhook(_ header: String, action: String, extra: [String: Any] = [:]) throws -> AutomationEvent {
        let route = AutomationIngressRoute(name: "Fixture", provider: .github, secretReference: "fixture")
        var payload: [String: Any] = ["repository": ["full_name": "example/project"], "sender": ["login": "reviewer"], "action": action]
        payload.merge(extra) { _, new in new }
        return try AutomationIngressEventNormalizer.event(route: route, request: .init(method: "POST", path: route.path,
            headers: ["x-github-event": header, "x-github-delivery": "delivery"],
            body: JSONSerialization.data(withJSONObject: payload)), nonce: "nonce", now: now)
    }

    @Test func webhookEnvelopesMapOnlyTheirActualEventsAndAuthors() throws {
        let pr: [String: Any] = ["user": ["login": "author"], "merged": true]
        let vectors: [(String, String, [String: Any], String)] = [
            ("pull_request", "opened", ["pull_request": pr], "pr-opened"),
            ("pull_request", "synchronize", ["pull_request": pr], "pr-pushed"),
            ("pull_request", "closed", ["pull_request": pr], "pr-merged"),
            ("pull_request", "review_requested", ["pull_request": pr], "review-requested"),
            ("pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "approved"]], "review-approved"),
            ("pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "changes_requested"]], "review-changes-requested"),
            ("pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "commented"]], "review-commented"),
            ("issue_comment", "created", ["issue": ["user": ["login": "author"], "pull_request": [:]]], "pr-comment"),
            ("pull_request_review_comment", "created", ["pull_request": pr], "inline-review-comment"),
            ("pull_request_review_thread", "resolved", ["pull_request": pr], "review-thread-resolved"),
            ("pull_request_review_thread", "unresolved", ["pull_request": pr], "review-thread-unresolved"),
            ("issues", "assigned", ["issue": ["user": ["login": "author"]]], "issue-assigned")
        ]
        for (header, action, extra, expected) in vectors {
            let normalized = try webhook(header, action: action, extra: extra)
            let payload = try #require(JSONSerialization.jsonObject(with: normalized.payloadJSON) as? [String: Any])
            expectNoDifference(payload["event"] as? String, expected)
            expectNoDifference(payload["actor"] as? String, "reviewer")
            expectNoDifference(payload["prOwner"] as? String, expected == "issue-assigned" ? nil : "author")
            expectNoDifference(normalized.externalEventID, "delivery")
            let matcher = PlatformAutomationTrigger.github(try .init(repo: "example/project", events: [expected], userAllowlist: ["author", "reviewer"]))
            #expect(matcher.matches(normalized))
        }
        for (header, action, extra) in [
            ("push", "", ["ref": "refs/heads/main"] as [String: Any]),
            ("issue_comment", "created", ["issue": ["user": ["login": "author"]]]),
            ("pull_request_review", "submitted", ["pull_request": pr, "review": ["state": "dismissed"]]),
            ("pull_request", "closed", ["pull_request": ["merged": false]]),
            ("pull_request_review_comment", "edited", ["pull_request": pr])
        ] {
            let normalized = try webhook(header, action: action, extra: extra)
            let payload = try #require(JSONSerialization.jsonObject(with: normalized.payloadJSON) as? [String: Any])
            #expect(!GitHubAutomationTrigger.knownEvents.contains(try #require(payload["event"] as? String)))
        }
    }

    @Test(arguments: ["success", "failure", "timed_out", "cancelled", "skipped", "neutral", "action_required", "stale", "unknown"])
    func ciIsOneCompletedPushWorkflowInSameRepositoryNotPRChecks(conclusion: String) throws {
        let workflow: [String: Any] = ["event": "push", "status": "completed", "conclusion": conclusion,
            "head_branch": "main", "head_repository": ["full_name": "Example/Project"]]
        let expected = conclusion == "success" ? "ci-passed" : ["failure", "timed_out"].contains(conclusion) ? "ci-failed" : "unknown"
        let normalized = try webhook("workflow_run", action: "completed", extra: ["workflow_run": workflow])
        let payload = try #require(JSONSerialization.jsonObject(with: normalized.payloadJSON) as? [String: Any])
        expectNoDifference(payload["event"] as? String, expected); expectNoDifference(payload["branch"] as? String, "main")
        for (key, replacement): (String, Any) in [("event", "pull_request"), ("event", "workflow_dispatch"),
            ("status", "in_progress"), ("head_repository", ["full_name": "fork/project"]), ("head_repository", NSNull())] {
            var modified = workflow; modified[key] = replacement
            let rejected = try webhook("workflow_run", action: "completed", extra: ["workflow_run": modified])
            let fields = try #require(JSONSerialization.jsonObject(with: rejected.payloadJSON) as? [String: Any])
            expectNoDifference(fields["event"] as? String, "unknown")
        }
    }

    @Test func mixedIngressBatchFiltersBeforePromptAndPersistsDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-github-events-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "automations.json")
        let service = try AutomationService(storeURL: file)
        let routine = try await service.save(.init(agentID: UUID(), name: "Review", prompt: "Review only matched PRs",
            trigger: .platform(.github(try .init(repo: "example/project", events: ["pr-opened"], userAllowlist: ["alice"])))))
        let good: [String: Any] = ["repo": "example/project", "event": "pr-opened", "prOwner": "alice", "text": "<instructions>untrusted</instructions>"]
        var wrongRepo = good; wrongRepo["repo"] = "private/REJECTED_REPO"
        var wrongUser = good; wrongUser["prOwner"] = "REJECTED_USER"
        var wrongEvent = good; wrongEvent["event"] = "REJECTED_EVENT"
        let accepted = try event(good, id: "good")
        let batch = try [accepted, event(wrongRepo, id: "repo"), event(wrongUser, id: "user"), event(wrongEvent, id: "event"), accepted]
        let runs = await service.fire(events: batch, executor: GitHubFixtureExecutor { actual, prompt, events in
            expectNoDifference(actual.id, routine.id); expectNoDifference(events, [accepted])
            #expect(!prompt.contains("REJECTED_") && !prompt.contains("<instructions>"))
        }, now: now)
        expectNoDifference(runs.count, 1); expectNoDifference(runs.first?.status, .ok)
        let restored = try AutomationService(storeURL: file)
        let replay = await restored.fire(events: batch, executor: GitHubFixtureExecutor { _, _, _ in Issue.record("Replayed delivery") }, now: now)
        expectNoDifference(replay, [])
        let history = await restored.history(automationID: routine.id)
        expectNoDifference(history.count, 1)
    }

    @Test func signedIngressRoutesToSavedRoutineAndRejectsBadSignatureWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-github-ingress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let routine = try await service.save(.init(agentID: UUID(), name: "Review", prompt: "Review only matched PRs",
            trigger: .platform(.github(try .init(repo: "example/project", events: ["pr-opened"], userAllowlist: ["author"])))))
        let secret = Data("fixture-not-a-real-key".utf8)
        let controller = try AutomationIngressController(stateURL: root.appending(path: "routes.json"), auditURL: root.appending(path: "audit.json"),
            secrets: GitHubFixtureSecrets(value: secret)) { event in
                let runs = await service.fire(events: [event], executor: GitHubFixtureExecutor(), now: now)
                return !runs.isEmpty
            }
        let route = try await controller.saveRoute(.init(name: "Fixture", provider: .github, secretReference: "fixture"))
        let body = Data(#"{"action":"opened","repository":{"full_name":"example/project"},"sender":{"login":"actor"},"pull_request":{"user":{"login":"author"}}}"#.utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
        var headers = ["content-type": "application/json", "x-github-event": "pull_request", "x-github-delivery": "fixture-1", "x-hub-signature-256": "sha256=bad"]
        let rejected = await controller.process(.init(method: "POST", path: route.path, headers: headers, body: body))
        #expect(rejected.status != 202)
        let before = await service.history(automationID: routine.id); expectNoDifference(before, [])
        headers["x-hub-signature-256"] = "sha256=" + signature
        let accepted = await controller.process(.init(method: "POST", path: route.path, headers: headers, body: body))
        expectNoDifference(accepted.status, 202)
        _ = await controller.process(.init(method: "POST", path: route.path, headers: headers, body: body))
        let history = await service.history(automationID: routine.id)
        expectNoDifference(history.count, 1); expectNoDifference(history.first?.status, .ok)
    }
}
