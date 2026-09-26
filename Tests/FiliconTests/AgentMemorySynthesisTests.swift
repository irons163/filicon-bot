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
    private func fixture() throws -> (URL, AgentService) {
        let root = FileManager.default.temporaryDirectory.appending(path: "synthesis-pipeline-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "agents.json")
        var state = AgentPersistentState()
        state.agents = [.init(id: owner, name: "Owner", createdAt: date)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: file)
        return (root, try AgentService(storeURL: file))
    }

    @Test(arguments: ["recover", "reject", "invalid", "transport", "cancel-delay", "disable-delay", "stale-delay"])
    func productionRetriesWholePairButNeverRevokedOrStaleEvidence(mode: String) async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await service.memorySynthesisSettings(accountID: "local", agentID: owner)
        try await service.setMemorySynthesisEnabled(true, expected: initial, lifetime: .init())
        let settings = try await service.memorySynthesisSettings(accountID: "local", agentID: owner)
        let lifetime = AgentMemorySuggestionLifetime(), probe = SynthesisStageProbe()
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
                }, execute: { stage, _, payload in
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

    @Test(arguments: ["duplicate", "future", "too-long", "empty-user", "empty-assistant", "unknown-agent", "clock-collision"])
    func invalidHostEvidenceNeverReachesTransport(mode: String) async throws {
        let (root, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var input = evidence
        switch mode {
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
