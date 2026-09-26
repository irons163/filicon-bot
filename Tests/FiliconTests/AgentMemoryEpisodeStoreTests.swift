import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Episode consent and persistence")
struct AgentMemoryEpisodeStoreTests {
    @Test func legacyStateAndFailedPersistenceDoNotGrantConsent() async throws {
        let legacy = try JSONDecoder().decode(AgentPersistentState.self, from: Data("{}".utf8))
        expectNoDifference(legacy.memoryEpisodeSettings, [])
        expectNoDifference(legacy.memoryEpisodes, [])
        let root = FileManager.default.temporaryDirectory.appending(path: "episode-rollback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "agents.json")
        let service = try AgentService(storeURL: url)
        let owner = try await service.create(name: "Fixture", instructions: "", providerID: "fixture", modelID: "fixture",
                                              at: .init(timeIntervalSince1970: 1_900_000_000))
        let disabled = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        let cancelled = AgentMemorySuggestionLifetime()
        cancelled.close()
        await #expect(throws: (any Error).self) {
            try await service.setMemoryEpisodesEnabled(true, expected: disabled, lifetime: cancelled)
        }
        let afterCancellation = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        expectNoDifference(afterCancellation, disabled)
        // Make only this isolated fixture's destination unwritable as a file.
        try FileManager.default.moveItem(at: url, to: root.appending(path: "backup.json"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) {
            try await service.setMemoryEpisodesEnabled(true, expected: disabled, lifetime: .init())
        }
        let afterFailure = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        expectNoDifference(afterFailure, disabled)
    }

    @Test func explicitConsentReopenRevocationAndSynthesisExclusion() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "episode-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "agents.json")
        let service = try AgentService(storeURL: url)
        let date = Date(timeIntervalSince1970: 1_900_000_000)
        let owner = try await service.create(name: "Fixture", instructions: "", providerID: "fixture", modelID: "fixture", at: date)
        let origin = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let exchange = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let disabled = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        #expect(!disabled.enabled)
        func record(_ settings: AgentMemoryEpisodeSettings, on target: AgentService) async throws {
            try await target.recordMemoryEpisode(settings: settings, originID: origin, exchangeID: exchange,
                at: date, user: "Build accessible navigation", assistant: "Use keyboard focus", lifetime: .init())
        }
        await #expect(throws: AgentMemorySuggestionError.stale) { try await record(disabled, on: service) }
        try await service.setMemoryEpisodesEnabled(true, expected: disabled, lifetime: .init())
        let enabled = try await service.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        try await record(enabled, on: service)
        let reopened = try AgentService(storeURL: url)
        try await record(enabled, on: reopened)
        let progress = try await reopened.memoryEpisodeProgress(settings: enabled, originID: origin)
        expectNoDifference(progress?.turns.count, 1)
        expectNoDifference(progress?.turns.first?.user, "Build accessible navigation")
        let other = try await reopened.memoryEpisodeSettings(accountID: "other", agentID: owner.id)
        #expect(!other.enabled)
        let synthesis = try await reopened.memorySynthesisSettings(accountID: "local", agentID: owner.id)
        try await reopened.setMemorySynthesisEnabled(true, expected: synthesis, lifetime: .init())
        await #expect(throws: AgentMemorySuggestionError.stale) { try await record(enabled, on: reopened) }
        let revoked = try await reopened.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        #expect(!revoked.enabled)
        await #expect(throws: AgentMemorySuggestionError.stale) {
            try await reopened.setMemoryEpisodesEnabled(true, expected: revoked, lifetime: .init())
        }
        let activeSynthesis = try await reopened.memorySynthesisSettings(accountID: "local", agentID: owner.id)
        try await reopened.setMemorySynthesisEnabled(false, expected: activeSynthesis, lifetime: .init())
        let afterSynthesis = try await reopened.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        expectNoDifference(afterSynthesis, revoked)
        try await reopened.setMemoryEpisodesEnabled(true, expected: revoked, lifetime: .init())
        let fresh = try await reopened.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
        let cleared = try await reopened.memoryEpisodeProgress(settings: fresh, originID: origin)
        expectNoDifference(cleared, nil)
        try await record(fresh, on: reopened)
        try await reopened.clearMemoryEpisodeOrigin(accountID: "other", originID: origin, lifetime: .init())
        #expect(try await reopened.memoryEpisodeProgress(settings: fresh, originID: origin) != nil)
        try await reopened.clearMemoryEpisodeOrigin(accountID: "local", originID: origin, lifetime: .init())
        let deleted = try await reopened.memoryEpisodeProgress(settings: fresh, originID: origin)
        expectNoDifference(deleted, nil)
        try await record(fresh, on: reopened)
        try await reopened.archive(id: owner.id, at: date)
        try await reopened.restore(id: owner.id, at: date)
        #expect(try await !reopened.memoryEpisodeSettings(accountID: "local", agentID: owner.id).enabled)
    }
}
