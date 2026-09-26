import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

private actor SynthesisStageProbe {
    var stages: [AgentMemorySynthesisStage] = []
    var payloads: [String] = []
    var delays: [Duration] = []
    func delay(_ value: Duration) { delays.append(value) }
    func record(_ stage: AgentMemorySynthesisStage, _ payload: String) {
        stages.append(stage); payloads.append(payload)
    }
}

@Suite("Two-stage memory synthesis", .timeLimit(.minutes(1)))
struct AgentMemorySynthesisTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let date = Date(timeIntervalSince1970: 10_000)
    private let proposal = #"{"changes":[{"action":"create","content":"Prefers short answers","kind":"profile","sourceEvidenceIds":["turn-1"]}]}"#
    private var evidence: [AgentMemorySynthesisEvidence] {
        [.init(id: "turn-1", occurredAt: date, user: "I prefer short answers", assistant: "Understood")]
    }
    private func fixture(memories: [AgentMemory] = []) throws -> (URL, AgentService) {
        let root = FileManager.default.temporaryDirectory.appending(path: "synthesis-pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "agents.json")
        var state = AgentPersistentState()
        state.agents = [.init(id: owner, name: "Owner", createdAt: date)]
        state.memories = memories
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: file)
        return (root, try AgentService(storeURL: file))
    }

    @Test(arguments: ["commit", "unseen-target", "unseen-stale"])
    func largeArchiveUsesBoundedInputAndFullCommitFence(mode: String) async throws {
        let history = (0..<600).map { index in
            AgentMemory(synthesizedID: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))!,
                accountID: "local", agentID: owner,
                fact: "Archived \(index) " + String(repeating: "x", count: 450), tier: .log,
                createdAt: date.addingTimeInterval(Double(index)))
        }
        let explicit = AgentMemory(accountID: "local", agentID: owner, fact: "Old explicit preference", createdAt: .distantPast)
        let foundational = AgentMemory(synthesizedID: UUID(uuidString: "00000000-0000-0000-0002-000000000000")!,
            accountID: "local", agentID: owner, fact: "Old generated foundation", tier: .profile, createdAt: .distantPast)
        let (root, service) = try fixture(memories: history + [explicit, foundational])
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(snapshot.memories.count, 602)
        expectNoDifference(Array(snapshot.inputMemories.prefix(2).map(\.id)), [explicit.id, foundational.id])
        #expect(snapshot.inputMemories.count <= 512)
        let unseen = history[0]
        #expect(!snapshot.mutableMemoryIDs.contains(unseen.id))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(snapshot.inputMemories.map(AgentMemorySynthesisInputFact.init)).count <= 64_000)
        let probe = SynthesisStageProbe()
        let operation = {
            try await service.synthesizeMemory(accountID: "local", agentID: owner, evidence: evidence,
                at: date.addingTimeInterval(1_000), lifetime: .init()) { stage, _, payload in
                await probe.record(stage, payload)
                if stage == .verification { return #"{"approved":true}"# }
                let input = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
                let facts = try #require(input["currentMemories"] as? [[String: Any]])
                expectNoDifference(facts.count, snapshot.inputMemories.count)
                #expect(!facts.contains { ($0["id"] as? String) == unseen.id.uuidString })
                #expect(payload.utf8.count <= 262_144)
                if mode == "unseen-target" {
                    return "{\"changes\":[{\"action\":\"remove\",\"id\":\"\(unseen.id)\",\"sourceEvidenceIds\":[\"turn-1\"]}]}"
                }
                if mode == "unseen-stale" { try await service.forgetMemoryFromEditor(unseen, lifetime: .init()) }
                return proposal
            }
        }
        if mode == "commit" {
            let result = try await operation()
            expectNoDifference(result, .committed)
        }
        else { await #expect(throws: (any Error).self) { try await operation() } }
        let reopened = try AgentService(storeURL: root.appending(path: "agents.json"))
        let saved = await reopened.memories(accountID: "local", agentID: owner)
        expectNoDifference(saved.count, mode == "commit" ? 603 : mode == "unseen-stale" ? 601 : 602)
        expectNoDifference(saved.contains { $0.fact == "Prefers short answers" }, mode == "commit")
        #expect(saved.contains { $0.id == explicit.id })
    }

    @Test func allWritersRetainHistoryPastFormerCapacity() async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<60 {
            try await service.applyMemoryChange(.init(operation: .write, memory: .init(accountID: "local",
                agentID: owner, fact: "History \(index) " + String(repeating: "x", count: 250), createdAt: date)), lifetime: .init())
        }
        let original = await service.memories(accountID: "local", agentID: owner)
        #expect(original.reduce(0) { $0 + $1.fact.count } > 12_000)
        let disabled = try await service.memorySuggestions(accountID: "local", agentID: owner).settings
        try await service.setMemorySuggestionsEnabled(true, expected: disabled, lifetime: .init())
        let settings = try await service.memorySuggestions(accountID: "local", agentID: owner).settings
        let exchange = UUID(uuidString: "00000000-0000-0000-0000-000000000100")!
        let suggestion = AgentMemorySuggestion(accountID: "local", agentID: owner, exchangeID: exchange,
            fact: "Human approved history", evidence: "Human approved history", tier: .log, createdAt: date)
        try await service.recordMemorySuggestions([suggestion], settings: settings, exchangeID: exchange, lifetime: .init())
        try await service.reviewMemorySuggestion(suggestion, accept: true, lifetime: .init())
        let result = try await service.synthesizeMemory(accountID: "local", agentID: owner,
            evidence: evidence, at: date, lifetime: .init()) { stage, _, _ in
                stage == .proposal ? proposal : #"{"approved":true}"#
            }
        expectNoDifference(result, .committed)
        let initial = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner)
        try await service.setMemoryEpisodesEnabled(true, expected: initial, lifetime: .init())
        let episode = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner)
        for index in 0..<6 {
            let turn = UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", index))!
            try await service.recordMemoryEpisode(settings: episode, originID: exchange, exchangeID: turn,
                at: date, user: "Design an accessible site", assistant: "Agreed on keyboard navigation", lifetime: .init())
        }
        let summarized = try await service.runMemoryEpisode(settings: episode, originID: exchange, lifetime: .init()) { stage, _, _ in
            stage == .proposal ? "Agreed on keyboard navigation for the site." : #"{"approved":true}"#
        }
        expectNoDifference(summarized, .committed)
        let reopened = try AgentService(storeURL: root.appending(path: "agents.json"))
        let saved = await reopened.memories(accountID: "local", agentID: owner)
        expectNoDifference(saved.count, 63)
        #expect(Set(original.map(\.id)).isSubset(of: Set(saved.map(\.id))))
        expectNoDifference(saved.filter { $0.origin == .synthesis }.count, 1)
        expectNoDifference(saved.filter { $0.origin == .episode }.count, 1)
        let recall = try AgentMemoryRecall(memories: saved, accountID: "local", agentID: owner)
        #expect(recall.memories.count < saved.count)
        #expect(recall.factsJSON.utf8.count <= 12_000)
    }

    @Test(arguments: ["empty", "rejected", "invalid", "network", "cancel", "revoked", "snapshot", "committed", "chat-empty"])
    func completionUpdatesOnlyEligibleTemporalReceipts(mode: String) async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let disabled = try await service.memorySynthesisSettings(accountID: "local", agentID: owner)
        try await service.setMemorySynthesisEnabled(true, expected: disabled, lifetime: .init())
        let settings = try await service.memorySynthesisSettings(accountID: "local", agentID: owner)
        let fact = AgentMemory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            accountID: "local", agentID: owner, fact: "Existing explicit fact", createdAt: date)
        try await service.applyMemoryChange(.init(operation: .write, memory: fact), lifetime: .init())
        let token = AgentMemorySuggestionLifetime(), probe = SynthesisStageProbe()
        let journal = AgentMemorySynthesisJournal()
        let temporal = !["committed", "chat-empty"].contains(mode)
        let operation = {
            try await service.runMemorySynthesis(settings: settings, evidence: mode == "empty" ? [] : evidence,
                temporalReview: temporal, at: date, lifetime: token, retrySleep: { _ in }, report: { journal.append($0) }, execute: { stage, _, payload in
                    await probe.record(stage, payload)
                    if mode == "network" { throw URLError(.networkConnectionLost) }
                    if mode == "cancel" { throw CancellationError() }
                    if mode == "revoked" { token.close(); return #"{"changes":[]}"# }
                    if mode == "snapshot" { throw AgentMemorySynthesisSnapshotChanged() }
                    if stage == .verification { return mode == "rejected" ? #"{"approved":false}"# : #"{"approved":true}"# }
                    if mode == "invalid" { return "invalid" }
                    return ["empty", "chat-empty"].contains(mode) ? #"{"changes":[]}"# : proposal
                })
        }
        if ["invalid", "network", "cancel", "revoked", "snapshot"].contains(mode) {
            await #expect(throws: (any Error).self) { try await operation() }
        } else {
            let result = try await operation()
            expectNoDifference(result, mode == "committed" ? .committed : mode == "rejected" ? .rejected : .noWork)
        }
        let marked = ["empty", "rejected", "invalid", "network", "committed"].contains(mode)
        let before = try await service.dueMemoryTemporalReviews(accountID: "local", at: date.addingTimeInterval(86_399))
        let boundary = try await service.dueMemoryTemporalReviews(accountID: "local", at: date.addingTimeInterval(86_400))
        expectNoDifference(before, marked ? [] : [settings])
        expectNoDifference(boundary, [settings])
        let reports = journal.snapshot()
        expectNoDifference(reports.count, 1)
        expectNoDifference(reports.first?.inputMemoryCount, 1)
        if mode == "empty" || mode == "chat-empty" { expectNoDifference(reports.first?.outcome, .noWork) }
        if mode == "empty" {
            let payload = try #require(await probe.payloads.first)
            let input = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            expectNoDifference(input["clockEvidenceID"] as? String, "clock")
            expectNoDifference((input["evidence"] as? [Any])?.count, 0)
        }
    }

    @Test func sweepDiagnosticsRemainBoundedAndSeparateFromModelRuns() {
        let journal = AgentMemorySynthesisJournal()
        for _ in 0..<70 { journal.recordSweep(.failed) }
        journal.recordSweep(.cancelled)
        expectNoDifference(journal.snapshot(), [])
        expectNoDifference(journal.summary(), "memorySynthesis=none\nmemoryTemporalSweep[recent=64]=failed=63,cancelled=1")
    }

    @Test func reportJournalIsBoundedAndContainsOnlyStructuredHostMetrics() throws {
        let journal = AgentMemorySynthesisJournal()
        expectNoDifference(journal.summary(), "memorySynthesis=none")
        for index in 0..<70 {
            journal.append(.init(outcome: .failed, agentID: owner, evidenceCount: index,
                inputMemoryCount: 3, changeCount: 0, durationMilliseconds: 12))
        }
        let snapshot = journal.snapshot()
        expectNoDifference(snapshot.count, 64)
        expectNoDifference(snapshot.first?.evidenceCount, 6)
        expectNoDifference(snapshot.last?.evidenceCount, 69)
        #expect(journal.summary().contains("failed=64"))
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require(snapshot.last))) as? [String: Any]
        expectNoDifference(Set(try #require(encoded).keys), ["outcome", "agentID", "evidenceCount", "inputMemoryCount", "changeCount", "durationMilliseconds"])
        let bounded = AgentMemorySynthesisReport(outcome: .failed, agentID: owner, evidenceCount: -1,
            inputMemoryCount: Int.max, changeCount: Int.max, durationMilliseconds: .infinity)
        expectNoDifference(bounded.evidenceCount, 0)
        expectNoDifference(bounded.inputMemoryCount, 1_000_000)
        expectNoDifference(bounded.changeCount, 64)
        expectNoDifference(bounded.durationMilliseconds, 0)
    }

    @Test(arguments: ["recover", "reject", "invalid", "transport", "cancel-delay", "disable-delay", "stale-delay"])
    func productionRetriesWholePairButNeverRevokedOrStaleEvidence(mode: String) async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await service.memorySynthesisSettings(accountID: "local", agentID: owner)
        try await service.setMemorySynthesisEnabled(true, expected: initial, lifetime: .init())
        let settings = try await service.memorySynthesisSettings(accountID: "local", agentID: owner)
        let lifetime = AgentMemorySuggestionLifetime(), probe = SynthesisStageProbe()
        let journal = AgentMemorySynthesisJournal(), instant = ContinuousClock.now
        let operation = {
            try await service.runMemorySynthesis(settings: settings, evidence: evidence, at: date, lifetime: lifetime,
                retrySleep: { duration in
                    await probe.delay(duration)
                    if mode == "cancel-delay" { lifetime.close() }
                    if mode == "disable-delay" { try await service.setMemorySynthesisEnabled(false, expected: settings, lifetime: .init()) }
                    if mode == "stale-delay" {
                        let fact = AgentMemory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                            accountID: "local", agentID: owner, fact: "Manual addition", createdAt: date)
                        try await service.applyMemoryChange(.init(operation: .write, memory: fact), lifetime: .init())
                    }
                }, report: { journal.append($0) }, measurementNow: { instant }, execute: { stage, _, payload in
                    await probe.record(stage, payload)
                    if mode == "transport" { throw URLError(.networkConnectionLost) }
                    if stage == .proposal { return mode == "invalid" ? "invalid" : proposal }
                    let count = await probe.stages.filter { $0 == .proposal }.count
                    return mode == "recover" && count == 3 ? #"{"approved":true}"# : #"{"approved":false}"#
                })
        }
        if mode == "recover" || mode == "reject" {
            let outcome = try await operation()
            expectNoDifference(outcome, mode == "recover" ? .committed : .rejected)
        } else {
            await #expect(throws: (any Error).self) { try await operation() }
        }
        let delays = await probe.delays
        expectNoDifference(delays, mode.hasSuffix("-delay") ? [.seconds(2)] : [.seconds(2), .seconds(4)])
        let stages = await probe.stages
        let attempts = mode.hasSuffix("-delay") ? 1 : 3
        expectNoDifference(stages.filter { $0 == .proposal }.count, attempts)
        expectNoDifference(stages.filter { $0 == .verification }.count, ["invalid", "transport"].contains(mode) ? 0 : attempts)
        let payloads = await probe.payloads
        let proposals = zip(stages, payloads).filter { $0.0 == .proposal }.map { $0.1 }
        expectNoDifference(Set(proposals).count, 1)
        let facts = await service.memories(accountID: "local", agentID: owner)
        expectNoDifference(facts.map(\.fact), mode == "recover" ? ["Prefers short answers"] : mode == "stale-delay" ? ["Manual addition"] : [])
        let expected: AgentMemorySynthesisReport.Outcome = switch mode {
        case "recover": .committed
        case "reject": .rejected
        case "invalid": .invalidOutput
        case "cancel-delay": .cancelled
        case "disable-delay", "stale-delay": .stale
        default: .failed
        }
        expectNoDifference(journal.snapshot(), [.init(outcome: expected, agentID: owner, evidenceCount: 1,
            inputMemoryCount: 0, changeCount: ["invalid", "transport"].contains(mode) ? 0 : 1, durationMilliseconds: 0)])
        let diagnostic = journal.summary()
        #expect(!diagnostic.contains("Prefers short answers") && !diagnostic.contains("turn-1"))
    }

    @Test(arguments: ["approve", "reject", "numeric", "extra", "duplicate-verdict", "malformed", "oversized", "empty-proposal", "bad-proposal", "cancel-proposal", "cancel-verification", "stale", "transport"])
    func pipelineRequiresIndependentValidApproval(mode: String) async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let lifetime = AgentMemorySuggestionLifetime(), probe = SynthesisStageProbe()
        let before = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        let execute: @Sendable (AgentMemorySynthesisStage, String, String) async throws -> String = { stage, instructions, payload in
            await probe.record(stage, payload)
            if stage == .proposal {
                expectNoDifference(instructions, AgentService.memorySynthesisInstructions)
                if mode == "cancel-proposal" { lifetime.close() }
                if mode == "empty-proposal" { return #"{"changes":[]}"# }
                if mode == "bad-proposal" { return #"{"changes":[{"action":"remove","id":"unknown","sourceEvidenceIds":["turn-1"]}]}"# }
                return proposal
            }
            expectNoDifference(instructions, AgentService.memoryVerificationInstructions)
            let outer = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
            expectNoDifference(outer["proposedChangesJSON"] as? String, proposal)
            if mode == "cancel-verification" { lifetime.close() }
            if mode == "stale" {
                let memory = AgentMemory(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                    accountID: "local", agentID: owner, fact: "Manual addition", createdAt: date)
                try await service.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
            }
            if mode == "transport" { throw CancellationError() }
            switch mode {
            case "reject": return #"{"approved":false}"#
            case "numeric": return #"{"approved":1}"#
            case "extra": return #"{"approved":true,"permission":"all"}"#
            case "duplicate-verdict": return #"{"approved":false,"approved":true}"#
            case "malformed": return "approved"
            case "oversized": return String(repeating: " ", count: 1_025)
            default: return #"{"approved":true}"#
            }
        }
        if ["approve", "reject", "empty-proposal"].contains(mode) {
            let result = try await service.synthesizeMemory(accountID: "local", agentID: owner,
                evidence: evidence, at: date, lifetime: lifetime, execute: execute)
            expectNoDifference(result, mode == "approve" ? .committed : mode == "reject" ? .rejected : .noWork)
        } else {
            await #expect(throws: (any Error).self) {
                try await service.synthesizeMemory(accountID: "local", agentID: owner,
                    evidence: evidence, at: date, lifetime: lifetime, execute: execute)
            }
        }
        let after = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        if mode == "approve" {
            expectNoDifference(after.memories.map(\.fact), ["Prefers short answers"])
            expectNoDifference(after.memories.map(\.origin), [.synthesis])
        } else if mode == "stale" {
            expectNoDifference(after.memories.map(\.fact), ["Manual addition"])
            expectNoDifference(after.memories.map(\.origin), [.explicit])
        } else { expectNoDifference(after, before) }
        let stages = await probe.stages
        expectNoDifference(stages, ["empty-proposal", "bad-proposal", "cancel-proposal"].contains(mode) ? [.proposal] : [.proposal, .verification])
    }

    @Test(arguments: ["duplicate", "future", "too-long", "encoded-budget", "empty-user", "empty-assistant", "unknown-agent", "clock-collision"])
    func invalidHostEvidenceNeverReachesTransport(mode: String) async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var input = evidence
        switch mode {
        case "encoded-budget":
            // Every field is individually valid; JSON escaping makes the total
            // snapshot exceed the transport budget without many UTF-8 bytes.
            input = (0..<12).map { .init(id: "turn-\($0)", occurredAt: date,
                user: "a" + String(repeating: "\u{0001}", count: 7_999),
                assistant: "a" + String(repeating: "\u{0001}", count: 7_999)) }
        case "duplicate": input.append(input[0])
        case "future": input = [.init(id: "turn-1", occurredAt: date.addingTimeInterval(1), user: "human", assistant: "reply")]
        case "too-long": input = [.init(id: "turn-1", occurredAt: date, user: String(repeating: "x", count: 8_001), assistant: "reply")]
        case "empty-user": input = [.init(id: "turn-1", occurredAt: date, user: " ", assistant: "reply")]
        case "empty-assistant": input = [.init(id: "turn-1", occurredAt: date, user: "human", assistant: " ")]
        case "clock-collision": input = [.init(id: "clock", occurredAt: date, user: "human", assistant: "reply")]
        default: break
        }
        let probe = SynthesisStageProbe()
        await #expect(throws: (any Error).self) {
            try await service.synthesizeMemory(accountID: "local", agentID: mode == "unknown-agent" ? UUID(uuidString: "00000000-0000-0000-0000-000000000009")! : owner,
                evidence: input, temporalReview: mode == "clock-collision", at: date, lifetime: .init()) { stage, _, payload in
                    await probe.record(stage, payload); return "{}"
                }
        }
        let stages = await probe.stages; expectNoDifference(stages, [])
    }
}
