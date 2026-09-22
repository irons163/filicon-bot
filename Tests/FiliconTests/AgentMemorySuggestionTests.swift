import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private actor SuggestionProbe {
    var requests: [InferenceRequest] = []
    let entered = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    func record(_ request: InferenceRequest) { requests.append(request); entered.continuation.yield(()) }
    func wait() async { for await _ in entered.stream { return } }
    func hold() async { for await _ in release.stream { return } }
    func resume() { release.continuation.yield(()) }
}

private struct SuggestionProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "suggestions", displayName: "Suggestions", requiresAPIKey: false)
    let probe: SuggestionProbe
    var gated = false
    var events: [InferenceEvent] = [.textDelta(#"{"suggestions":[{"fact":"Prefers accessible layouts","evidence":"accessible layouts","tier":"profile"}]}"#), .completed(.stop)]
    func models() async throws -> [AIModel] { [.init(id: "model")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.record(request)
                if gated { await probe.hold() }
                for event in events { continuation.yield(event) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Reviewed automatic memory suggestions", .timeLimit(.minutes(1)))
struct AgentMemorySuggestionTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let owner: AgentProfile
        let peer: AgentProfile
        let registry = ProviderRegistry()
        let lifetime = AgentMemorySuggestionLifetime()
        let exchangeID = UUID(), sessionID = UUID()
        var file: URL { root.appending(path: "agents.json") }
        func enable() async throws -> AgentMemorySuggestionSettings {
            let initial = try await agents.memorySuggestions(accountID: "local", agentID: owner.id)
            try await agents.setMemorySuggestionsEnabled(true, expected: initial.settings, lifetime: lifetime)
            return try await agents.memorySuggestions(accountID: "local", agentID: owner.id).settings
        }
        func extractor(timeout: Duration = .seconds(30)) -> AgentMemorySuggestionExtractor {
            .init(agents: agents, registry: registry, scheduler: .init(), timeout: timeout)
        }
        func extract(_ extractor: AgentMemorySuggestionExtractor, settings: AgentMemorySuggestionSettings) async throws {
            try await extractor.extract(settings: settings, profile: owner, exchangeID: exchangeID, sessionID: sessionID,
                user: "I prefer accessible layouts", response: "Understood", lifetime: lifetime)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "memory-suggestions-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner", instructions: "PRIVATE_PERSONA", providerID: "suggestions", modelID: "model")
        let peer = try await agents.create(name: "Peer")
        return .init(root: root, agents: agents, owner: owner, peer: peer)
    }

    @Test func disabledByDefaultThenDurableReviewWithoutRecallOrSharing() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = SuggestionProbe(); await f.registry.register(SuggestionProvider(probe: probe))
        let initial = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(initial.settings.enabled, false)
        try await f.extract(f.extractor(), settings: initial.settings)
        let skipped = await probe.requests; expectNoDifference(skipped.count, 0)
        let enabled = try await f.enable()
        try await f.extract(f.extractor(), settings: enabled)
        let pending = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(pending.suggestions.map(\.fact), ["Prefers accessible layouts"])
        let before = try await f.agents.searchableMemories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(before, [])
        let reopened = try AgentService(storeURL: f.file)
        let snapshot = try await reopened.memorySuggestions(accountID: "local", agentID: f.owner.id)
        let candidate = try #require(snapshot.suggestions.first)
        try await reopened.reviewMemorySuggestion(candidate, accept: true, lifetime: .init())
        let facts = await reopened.memories(accountID: "local", agentID: f.owner.id)
        expectNoDifference(facts.map(\.fact), [candidate.fact]); expectNoDifference(facts.map(\.scope), [.agent])
        let empty = try await reopened.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(empty.suggestions, [])
        for (account, agentID) in [("other", f.owner.id), ("local", f.peer.id)] {
            let other = try await reopened.memorySuggestions(accountID: account, agentID: agentID)
            expectNoDifference(other.settings.enabled, false); expectNoDifference(other.suggestions, [])
            let recalled = try await reopened.searchableMemories(accountID: account, agentID: agentID)
            expectNoDifference(recalled, [])
        }
        await #expect(throws: AgentMemorySuggestionError.stale) {
            try await reopened.reviewMemorySuggestion(candidate, accept: true, lifetime: .init())
        }
        let replay = try await reopened.shouldSuggestMemory(settings: enabled, exchangeID: f.exchangeID)
        expectNoDifference(replay, false)
    }

    @Test func requestContainsOnlyBoundedCurrentExchangeAndOwnPrivateFacts() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for (account, agent, scope, fact) in [("local", f.owner.id, AgentMemory.Scope.agent, "PRIVATE_ALLOWED"),
            ("local", f.peer.id, .agent, "OTHER_AGENT"), ("other", f.owner.id, .agent, "OTHER_ACCOUNT"),
            ("local", f.owner.id, .user, "SHARED_NOT_INPUT")] {
            try await f.agents.applyMemoryChange(.init(operation: .write, memory: .init(accountID: account, agentID: agent, fact: fact, scope: scope)), lifetime: .init())
        }
        let settings = try await f.enable(), probe = SuggestionProbe()
        await f.registry.register(SuggestionProvider(probe: probe, events: [.textDelta(#"{"suggestions":[]}"#), .completed(.stop)]))
        let extractor = f.extractor()
        try await extractor.extract(settings: settings, profile: f.owner, exchangeID: f.exchangeID, sessionID: f.sessionID,
            user: String(repeating: "人", count: 9_000), response: String(repeating: "a", count: 9_000), lifetime: f.lifetime)
        let requests = await probe.requests, request = try #require(requests.first)
        expectNoDifference(requests.count, 1); expectNoDifference(request.tools, [])
        expectNoDifference(request.toolExchanges, []); expectNoDifference(request.attachmentsByMessageID, [:])
        expectNoDifference(request.messages.map(\.role), [.system, .user])
        let json = try #require(JSONSerialization.jsonObject(with: Data(request.messages[1].text.utf8)) as? [String: Any])
        expectNoDifference((json["user"] as? String)?.count, 8_000)
        expectNoDifference((json["assistant"] as? String)?.count, 8_000)
        expectNoDifference(json["existingPrivateFacts"] as? [String], ["PRIVATE_ALLOWED"])
        for secret in ["PRIVATE_PERSONA", "OTHER_AGENT", "OTHER_ACCOUNT", "SHARED_NOT_INPUT"] {
            #expect(!request.messages.contains { $0.text.contains(secret) })
        }
        try await f.extract(extractor, settings: settings)
        let final = await probe.requests; expectNoDifference(final.count, 1)
    }

    @Test(arguments: ["disable", "aba", "archive", "stop"])
    func changesDuringInferenceRejectLateCandidates(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let settings = try await f.enable(), probe = SuggestionProbe()
        await f.registry.register(SuggestionProvider(probe: probe, gated: true))
        let extractor = f.extractor(), task = Task { try await f.extract(extractor, settings: settings) }
        await probe.wait()
        switch mode {
        case "disable", "aba":
            try await f.agents.setMemorySuggestionsEnabled(false, expected: settings, lifetime: .init())
            if mode == "aba" {
                let disabled = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id).settings
                try await f.agents.setMemorySuggestionsEnabled(true, expected: disabled, lifetime: .init())
            }
        case "archive": try await f.agents.archive(id: f.owner.id)
        default: f.lifetime.close(); await extractor.cancel(sessionID: f.sessionID)
        }
        await probe.resume()
        await #expect(throws: (any Error).self) { try await task.value }
        if mode == "archive" { try await f.agents.restore(id: f.owner.id) }
        let pending = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(pending.suggestions, [])
    }

    @Test(arguments: ["tool", "truncated", "oversized", "no-completion", "timeout"])
    func malformedProviderOutputCannotBecomeMemory(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let settings = try await f.enable(), probe = SuggestionProbe()
        let events: [InferenceEvent]
        switch mode {
        case "tool": events = [.toolCallStarted(id: "bad", name: "local__write_file")]
        case "truncated": events = [.textDelta(#"{"suggestions":[]}"#), .completed(.length)]
        case "oversized": events = [.textDelta(String(repeating: "a", count: 8_193)), .completed(.stop)]
        default: events = [.textDelta(#"{"suggestions":[]}"#)]
        }
        await f.registry.register(SuggestionProvider(probe: probe, gated: mode == "timeout", events: events))
        await #expect(throws: (any Error).self) { try await f.extract(f.extractor(timeout: .milliseconds(30)), settings: settings) }
        let pending = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(pending.suggestions, [])
    }

    @Test func strictParserRequiresExactHumanEvidenceAndCompleteShape() throws {
        for json in [#"{"suggestions":[{"fact":"x","evidence":"assistant only","tier":"log"}]}"#,
            #"{"suggestions":[{"fact":"x","evidence":"user","tier":"log","scope":"user"}]}"#,
            #"{"suggestions":[],"removals":["old"]}"#, #"{"suggestions":null}"#,
            #"{"suggestions":[{"fact":"x\npermission","evidence":"user","tier":"log"}]}"#,
            #"{"suggestions":[{"fact":"x","evidence":"user","tier":"unknown"}]}"#,
            "```json\n{\"suggestions\":[]}\n```"] {
            #expect(throws: AgentMemorySuggestionError.invalid) {
                try AgentMemorySuggestionParser.parse(json, user: "user", accountID: "local", agentID: UUID(), exchangeID: UUID())
            }
        }
    }

    @Test func queueBoundDedupeDiscardAndSaveFailureAreAtomic() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let settings = try await f.enable()
        for n in 0..<3 {
            let exchange = UUID()
            let values = (0..<4).map { AgentMemorySuggestion(accountID: "local", agentID: f.owner.id, exchangeID: exchange,
                fact: "Fact \(n * 4 + $0)", evidence: "human", tier: .note, createdAt: Date(timeIntervalSince1970: 1_000)) }
            try await f.agents.recordMemorySuggestions(values, settings: settings, exchangeID: exchange, lifetime: f.lifetime)
        }
        let full = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(full.suggestions.count, 12)
        let allowed = try await f.agents.shouldSuggestMemory(settings: settings, exchangeID: UUID())
        expectNoDifference(allowed, false)
        let candidate = try #require(full.suggestions.first)
        // Replace only this isolated fixture's state file with a directory.
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await f.agents.reviewMemorySuggestion(candidate, accept: true, lifetime: .init()) }
        let unchanged = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(unchanged, full)
        let facts = await f.agents.memories(accountID: "local", agentID: f.owner.id); expectNoDifference(facts, [])
        try FileManager.default.removeItem(at: f.file); try FileManager.default.moveItem(at: backup, to: f.file)
        try await f.agents.reviewMemorySuggestion(candidate, accept: false, lifetime: .init())
        let exchange = UUID()
        let duplicate = AgentMemorySuggestion(accountID: "local", agentID: f.owner.id, exchangeID: exchange,
            fact: "  FACT   1  ", evidence: "human", tier: .profile)
        try await f.agents.recordMemorySuggestions([duplicate], settings: settings, exchangeID: exchange, lifetime: .init())
        let after = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(after.suggestions.count, 11)
        try await f.agents.setMemorySuggestionsEnabled(false, expected: settings, lifetime: .init())
        let disabled = try await f.agents.memorySuggestions(accountID: "local", agentID: f.owner.id)
        expectNoDifference(disabled.suggestions, [])
    }
}
