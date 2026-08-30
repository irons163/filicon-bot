import Foundation
import Testing
@testable import FiliconAgents

@Suite("Agent workflow core")
struct AgentWorkflowTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "filicon-workflow-\(UUID().uuidString)/workflows.json")
    }

    @Test func deterministicRoundTripAndV1Migration() throws {
        let workflow = try AgentWorkflow(id: "daily-note", name: "Daily Note", description: "A note", trigger: .schedule("0 9 * * *"),
                                         steps: [.prompt("Draft it"), .action(name: "save_note", payload: "{}")],
                                         createdAt: Date(timeIntervalSince1970: 1)).validated()
        let document = AgentWorkflowDocument(workflows: [workflow])
        let first = try AgentWorkflowCodec.serialize(document)
        let second = try AgentWorkflowCodec.serialize(AgentWorkflowCodec.parse(first))
        #expect(first == second)

        let legacy = #"{"schemaVersion":1,"workflows":[{"id":"old","name":"Old","description":"","body":"Do it","createdAt":0,"updatedAt":0}]}"#.data(using: .utf8)!
        let migrated = try AgentWorkflowCodec.parse(legacy)
        #expect(migrated.schemaVersion == 2)
        #expect(migrated.workflows.first?.steps == [.prompt("Do it")])
        #expect(migrated.workflows.first?.isEnabled == true)
    }

    @Test func malformedFutureAuthorityAndBoundsFailClosed() throws {
        let future = #"{"schemaVersion":3,"workflows":[]}"#.data(using: .utf8)!
        #expect(throws: AgentWorkflowError.unsupportedSchema(3)) { try AgentWorkflowCodec.parse(future) }
        let authority = #"{"schemaVersion":2,"workflows":[{"id":"x","name":"X","description":"","isEnabled":true,"trigger":{"type":"manual","allowShell":true},"steps":[{"type":"prompt","text":"x"}],"createdAt":0,"updatedAt":0}]}"#.data(using: .utf8)!
        #expect(throws: (any Error).self) { try AgentWorkflowCodec.parse(authority) }
        #expect(throws: AgentWorkflowError.boundsExceeded("prompt")) {
            try AgentWorkflow(id: "x", name: "X", steps: [.prompt(String(repeating: "x", count: AgentWorkflowLimits.maximumBodyBytes + 1))]).validated()
        }
    }

    @Test func skillImportHTTPSAndNeutralBridge() async throws {
        let markdown = "---\nname: \"Review PR\"\ndescription: \"Carefully\"\n---\n# Steps\nReview it"
        let imported = try AgentWorkflowImporter.importText(markdown)
        #expect(imported.id == "review-pr")
        #expect(imported.description == "Carefully")
        let fetched = try await AgentWorkflowImporter.importURL(URL(string: "https://example.com/skill.md")!, fetcher: StubFetcher(data: Data(markdown.utf8)))
        #expect(fetched.sourceReference == "https://example.com/skill.md")
        let live = try AgentWorkflowImporter.liveSource(URL(string: "https://example.com/changing-skill.md")!)
        #expect(live.sourceReference == "https://example.com/changing-skill.md")
        #expect(live.steps == [.prompt("This workflow is a live reference to the skill at `https://example.com/changing-skill.md`.\nRead that source now with your file or fetch tools and follow it as written. Do not assume its contents from this note; the source is the source of truth and may have changed since this workflow was created.")])
        #expect(live.description.contains("live reference"))
        await #expect(throws: AgentWorkflowError.insecureURL) {
            try await AgentWorkflowImporter.importURL(URL(string: "http://localhost/skill.md")!, fetcher: StubFetcher(data: Data()))
        }
        #expect(throws: AgentWorkflowError.insecureURL) {
            try AgentWorkflowImporter.liveSource(URL(string: "https://127.0.0.1/private")!)
        }
        let ported = AgentWorkflowImporter.portPrivateSkills([.init(identifier: "private-review", skillMarkdown: markdown), .init(skillMarkdown: "")])
        #expect(ported.imported.map(\.id) == ["private-review"])
        #expect(ported.skipped.count == 1)
    }

    @Test func privateSkillBridgeBoundsBatchWork() {
        let markdown = "---\nname: Imported\n---\nDo it"
        let payloads = (0...AgentWorkflowLimits.maximumWorkflows).map {
            AgentWorkflowSkillImportPayload(identifier: "imported-\($0)", skillMarkdown: markdown)
        }
        let result = AgentWorkflowImporter.portPrivateSkills(payloads)
        #expect(result.imported.count == AgentWorkflowLimits.maximumWorkflows)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == AgentWorkflowError.boundsExceeded("import item count").localizedDescription)
    }

    @Test func CRUDEnablementAndPersistenceAreAtomic() async throws {
        let url = temporaryURL(); let store = try AgentWorkflowStore(persistenceURL: url)
        let created = try await store.create(name: "One", steps: [.prompt("go")])
        #expect(created.id == "one")
        _ = try await store.setEnabled(false, id: created.id)
        #expect(await store.get(created.id)?.isEnabled == false)
        let reopened = try AgentWorkflowStore(persistenceURL: url)
        #expect(await reopened.list().count == 1)
        try await reopened.delete(created.id)
        #expect(await reopened.list().isEmpty)
    }

    @Test func updatePersistsCanonicalizedValues() async throws {
        let url = temporaryURL()
        let store = try AgentWorkflowStore(persistenceURL: url)
        let created = try await store.create(name: "One", steps: [.prompt("go")])
        let proposed = AgentWorkflow(
            id: "ignored",
            name: "  Updated\nName  ",
            trigger: .schedule("  0   9 * * *  "),
            steps: [.prompt("  next  "), .action(name: " notify\n", payload: "hello")]
        )
        let updated = try await store.update(created.id, with: proposed)
        #expect(updated.name == "Updated Name")
        #expect(updated.trigger == .schedule("0 9 * * *"))
        #expect(updated.steps == [.prompt("next"), .action(name: "notify", payload: "hello")])

        let restored = try AgentWorkflowStore(persistenceURL: url)
        let persisted = await restored.get(created.id)
        #expect(persisted?.name == updated.name)
        #expect(persisted?.trigger == updated.trigger)
        #expect(persisted?.steps == updated.steps)
    }

    @Test func triggerManualDisableReferencesFailureAndReplay() async throws {
        let executor = RecordingExecutor()
        let runtime = AgentWorkflowRuntime(executor: executor)
        let helper = AgentWorkflow(id: "helper", name: "Helper", steps: [.prompt("help")])
        let workflow = AgentWorkflow(id: "main", name: "Main", trigger: .event("push"), steps: [.prompt("Use @helper"), .action(name: "record", payload: "{}")])
        #expect(await runtime.fire(event: "other", workflows: [workflow, helper]).isEmpty)
        let triggered = await runtime.fire(event: "push", workflows: [workflow, helper])
        #expect(triggered.first?.status == .succeeded)
        #expect(await executor.references == ["helper", "helper"])
        let manual = await runtime.runManual(workflow, library: [workflow, helper])
        #expect(manual.generation == 2)
        let replay = try await runtime.replay(runID: manual.id, workflow: workflow, library: [workflow, helper])
        #expect(replay.status == .succeeded)
        await #expect(throws: AgentWorkflowError.replayRejected) { try await runtime.replay(runID: manual.id, workflow: workflow) }
        var disabled = workflow; disabled.isEnabled = false
        #expect(await runtime.runManual(disabled).status == .succeeded)
        #expect(await runtime.fire(event: "push", workflows: [disabled]).isEmpty)

        let failureRuntime = AgentWorkflowRuntime(executor: FailingExecutor())
        #expect(await failureRuntime.runManual(workflow).status == .failed)
    }

    @Test func cancellationDeadlineAndGenerationFence() async {
        let runtime = AgentWorkflowRuntime(executor: SlowExecutor())
        let workflow = AgentWorkflow(id: "slow", name: "Slow", steps: [.prompt("wait")])
        let pending = Task { await runtime.runManual(workflow, deadline: 2) }
        try? await Task.sleep(for: .milliseconds(20)); await runtime.cancel(workflowID: workflow.id)
        #expect(await pending.value.status == .cancelled)
        #expect(await runtime.runManual(workflow, deadline: 0.01).status == .deadlineExceeded)

        let first = Task { await runtime.runManual(workflow, deadline: 2) }
        try? await Task.sleep(for: .milliseconds(20))
        let second = Task { await runtime.runManual(workflow, deadline: 2) }
        #expect(await first.value.status == .cancelled)
        await runtime.cancel(workflowID: workflow.id)
        #expect(await second.value.status == .cancelled)
    }

    @Test func durableBoundedHistorySurvivesRestart() async throws {
        let directory = temporaryURL().deletingLastPathComponent()
        let historyURL = directory.appending(path: "runs.json")
        let workflow = AgentWorkflow(id: "durable", name: "Durable", steps: [.prompt("go")])
        let runtime = try AgentWorkflowRuntime(executor: RecordingExecutor(), historyURL: historyURL)
        for _ in 0...AgentWorkflowLimits.maximumRuns {
            #expect(await runtime.runManual(workflow).status == .succeeded)
        }
        #expect(await runtime.runs().count == AgentWorkflowLimits.maximumRuns)

        let restored = try AgentWorkflowRuntime(executor: RecordingExecutor(), historyURL: historyURL)
        let runs = await restored.runs()
        #expect(runs.count == AgentWorkflowLimits.maximumRuns)
        #expect(runs.allSatisfy { $0.status == .succeeded })
        #expect(runs.map(\.generation).max() == UInt64(AgentWorkflowLimits.maximumRuns + 1))
    }

    @Test func durableHistoryBoundsUnicodeFailuresByUTF8Bytes() async throws {
        let historyURL = temporaryURL().deletingLastPathComponent().appending(path: "runs.json")
        let workflow = AgentWorkflow(id: "unicode-failure", name: "Unicode Failure", steps: [.prompt("go")])
        let runtime = try AgentWorkflowRuntime(executor: UnicodeFailingExecutor(), historyURL: historyURL)
        let run = await runtime.runManual(workflow)
        #expect(run.status == .failed)
        #expect((run.failure?.utf8.count ?? 0) <= AgentWorkflowLimits.maximumRunFailureBytes)

        let restored = try AgentWorkflowRuntime(executor: RecordingExecutor(), historyURL: historyURL)
        #expect(await restored.runs().first?.id == run.id)
    }

    @Test func workflowPersistenceRejectsSymlinkTargets() throws {
        let directory = temporaryURL().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "outside.json")
        let link = directory.appending(path: "workflows.json")
        try Data("do-not-touch".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: AgentWorkflowError.persistenceUnsafe) {
            try AgentWorkflowStore(persistenceURL: link)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "do-not-touch")
    }

    @Test func authorizedExecutorSeparatesPromptAndStrictActions() async throws {
        let prompt = PromptRecorder()
        let actions = ActionRecorder()
        let executor = AuthorizedAgentWorkflowExecutor(
            promptExecutor: prompt,
            actionAuthorizer: AllowNotificationsOnly(),
            actionHandler: actions
        )
        let workflow = AgentWorkflow(
            id: "safe",
            name: "Safe",
            steps: [.prompt("draft"), .action(name: "notify", payload: "hello")]
        )
        let run = await AgentWorkflowRuntime(executor: executor).runManual(workflow)
        #expect(run.status == .succeeded)
        #expect(await prompt.prompts == ["draft"])
        #expect(await actions.actions == [.notify])

        let shell = AgentWorkflow(id: "shell", name: "Shell", steps: [.action(name: "shell", payload: "rm -rf")])
        let denied = AgentWorkflow(id: "denied", name: "Denied", steps: [.action(name: "create_draft", payload: "x")])
        #expect(await AgentWorkflowRuntime(executor: executor).runManual(shell).status == .failed)
        #expect(await AgentWorkflowRuntime(executor: executor).runManual(denied).status == .failed)
        #expect(await actions.actions == [.notify])
    }
}

private actor RecordingExecutor: AgentWorkflowStepExecutor {
    var references: [String] = []
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String {
        references.append(contentsOf: request.referencedWorkflows.map(\.id)); return "step-\(request.stepIndex)"
    }
}
private struct FailingExecutor: AgentWorkflowStepExecutor {
    struct Failure: Error {}
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String { throw Failure() }
}
private struct UnicodeFailingExecutor: AgentWorkflowStepExecutor {
    struct Failure: Error, CustomStringConvertible {
        var description: String { String(repeating: "🧨", count: AgentWorkflowLimits.maximumRunFailureBytes) }
    }
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String { throw Failure() }
}
private struct SlowExecutor: AgentWorkflowStepExecutor {
    func execute(_ request: AgentWorkflowStepRequest) async throws -> String { try await Task.sleep(for: .milliseconds(100)); return "done" }
}
private struct StubFetcher: AgentWorkflowHTTPSFetching {
    let data: Data
    func fetch(_ url: URL, maximumBytes: Int) async throws -> (data: Data, finalURL: URL) { (data, url) }
}
private actor PromptRecorder: AgentWorkflowPromptExecuting {
    var prompts: [String] = []
    func executePrompt(_ request: AgentWorkflowPromptRequest) async throws -> String {
        prompts.append(request.prompt)
        return "prompt-result"
    }
}
private actor ActionRecorder: AgentWorkflowActionHandling {
    var actions: [AgentWorkflowAllowedAction] = []
    func perform(_ request: AgentWorkflowActionRequest) async throws -> String {
        actions.append(request.action)
        return "action-result"
    }
}
private struct AllowNotificationsOnly: AgentWorkflowActionAuthorizing {
    func authorize(_ request: AgentWorkflowActionRequest) async -> Bool { request.action == .notify }
}
