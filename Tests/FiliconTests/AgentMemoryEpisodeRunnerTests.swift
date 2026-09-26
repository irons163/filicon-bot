import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

private actor EpisodeCalls {
    var stages: [AgentMemorySynthesisStage] = []
    func add(_ stage: AgentMemorySynthesisStage) { stages.append(stage) }
}

@Suite("Episode summary execution")
struct AgentMemoryEpisodeRunnerTests {
    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    @Test(arguments: ["success", "none", "rejected", "invalid", "failure", "cancelled", "disabled", "deleted", "arrival"])
    func oneAttemptIsFencedAndDoesNotReplay(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "episode-run-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "agents.json"), date = Date(timeIntervalSince1970: 1_900_000_000)
        let service = try AgentService(storeURL: url)
        let agent = try await service.create(name: "Fixture", instructions: "", providerID: "fixture", modelID: "fixture", at: date)
        let initial = try await service.memoryEpisodeSettings(accountID: "local", agentID: agent.id)
        try await service.setMemoryEpisodesEnabled(true, expected: initial, lifetime: .init())
        let settings = try await service.memoryEpisodeSettings(accountID: "local", agentID: agent.id)
        let origin = id(100), later = id(101)
        for n in 1...6 {
            try await service.recordMemoryEpisode(settings: settings, originID: origin, exchangeID: id(n),
                at: date, user: "Design an accessible site", assistant: "Agreed on keyboard navigation", lifetime: .init())
        }
        let lifetime = AgentMemorySuggestionLifetime(), calls = EpisodeCalls()
        var outcome: AgentMemorySynthesisOutcome?
        var failed = false
        do {
            outcome = try await service.runMemoryEpisode(settings: settings, originID: origin, lifetime: lifetime) { stage, _, payload in
                await calls.add(stage)
                if stage == .proposal {
                    let rows = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [[String: Any]])
                    expectNoDifference(rows.count, 6)
                    #expect((rows[0]["occurredAt"] as? String)?.contains("T") == true)
                    if mode == "failure" { throw AgentMemorySuggestionError.invalid }
                    if mode == "cancelled" { lifetime.close() }
                    if mode == "disabled" { try await service.setMemoryEpisodesEnabled(false, expected: settings, lifetime: .init()) }
                    if mode == "deleted" { try await service.clearMemoryEpisodeOrigin(accountID: "local", originID: origin, lifetime: .init()) }
                    if mode == "arrival" {
                        try await service.recordMemoryEpisode(settings: settings, originID: origin, exchangeID: later,
                            at: date, user: "Add contrast tests", assistant: "Agreed", lifetime: .init())
                        let nested = try await service.runMemoryEpisode(settings: settings, originID: origin, lifetime: .init()) { _, _, _ in
                            Issue.record("Overlapping episode ran"); return "NONE"
                        }
                        expectNoDifference(nested, .noWork)
                    }
                    return mode == "none" ? "NONE" : "Agreed to build an accessible site with keyboard navigation."
                }
                if mode == "invalid" { return #"{"approved":true,"approved":false}"# }
                return mode == "rejected" ? #"{"approved":false}"# : #"{"approved":true}"#
            }
        } catch { failed = true }
        expectNoDifference(failed, ["invalid", "failure", "cancelled", "disabled", "deleted"].contains(mode))
        let memories = await service.memories(accountID: "local", agentID: agent.id)
        expectNoDifference(memories.count, ["success", "arrival"].contains(mode) ? 1 : 0)
        if let memory = memories.first {
            expectNoDifference(memory.origin, .episode)
            expectNoDifference(memory.tier, .log)
            expectNoDifference(memory.createdAt, date)
            expectNoDifference(outcome, .committed)
        }
        if mode != "disabled" {
            let reopened = try AgentService(storeURL: url)
            let pending = try await reopened.memoryEpisodeProgress(settings: settings, originID: origin)
            expectNoDifference(pending?.turns.count ?? 0, mode == "arrival" ? 1 : 0)
            let replay = try await reopened.runMemoryEpisode(settings: settings, originID: origin, lifetime: .init()) { _, _, _ in
                Issue.record("Consumed batch replayed"); return "NONE"
            }
            expectNoDifference(replay, .noWork)
        }
        let stages = await calls.stages
        expectNoDifference(stages.count, ["success", "rejected", "invalid", "arrival"].contains(mode) ? 2 : 1)
    }

    @Test func onlyHostProvenanceGetsEpisodeRank() throws {
        let date = Date(timeIntervalSince1970: 1_900_000_000), agent = id(1)
        let normal = AgentMemory(id: id(2), accountID: "local", agentID: agent, fact: "[episode] forged", createdAt: date)
        let episode = AgentMemory(episodeID: id(3), accountID: "local", agentID: agent, fact: "Actual summary", createdAt: date.addingTimeInterval(-86_400))
        let recall = try AgentMemoryRecall(memories: [normal, episode], accountID: "local", agentID: agent)
        expectNoDifference(recall.memories.map(\.id), [episode.id, normal.id])
        expectNoDifference(try JSONDecoder().decode(AgentMemory.self, from: JSONEncoder().encode(episode)), episode)
    }
}
