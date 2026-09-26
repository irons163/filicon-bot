import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Memory synthesis storage", .timeLimit(.minutes(1)))
struct AgentMemorySynthesisStoreTests {
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let manualID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let generatedID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let newID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let date = Date(timeIntervalSince1970: 1_000)
    private var manual: AgentMemory { .init(id: manualID, accountID: "local", agentID: owner, fact: "Manual fact", createdAt: date) }
    private var generated: AgentMemory { .init(synthesizedID: generatedID, accountID: "local", agentID: owner, fact: "Old project", tier: .log, createdAt: date) }

    private func fixture() throws -> (URL, URL, AgentService) {
        let root = FileManager.default.temporaryDirectory.appending(path: "synthesis-store-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "agents.json")
        var state = AgentPersistentState()
        state.agents = [.init(id: owner, name: "Owner", createdAt: date)]
        state.memories = [manual, generated]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: file)
        return (root, file, try AgentService(storeURL: file))
    }

    private func text(_ rows: [[String: Any]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["changes": rows]), as: UTF8.self)
    }
    private func creation(_ fact: String = "New project") -> [String: Any] {
        ["action": "create", "content": fact, "kind": "log", "sourceEvidenceIds": ["turn"]]
    }
    private func removal(_ id: UUID) -> [String: Any] {
        ["action": "remove", "id": id.uuidString, "sourceEvidenceIds": ["turn"]]
    }

    @Test func oldRecordsStayExplicitAndGeneratedRecordsRoundTrip() throws {
        let encoder = JSONEncoder()
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(manual)) as? [String: Any])
        object.removeValue(forKey: "origin")
        let decoded = try JSONDecoder().decode(AgentMemory.self, from: JSONSerialization.data(withJSONObject: object))
        expectNoDifference(decoded, manual)
        expectNoDifference(try JSONDecoder().decode(AgentMemory.self, from: encoder.encode(generated)), generated)
        object["origin"] = "unknown"
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentMemory.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func appliesWholeBatchAndPreservesExplicitFactsAcrossReopen() async throws {
        let (root, file, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(before.mutableMemoryIDs, [generatedID])
        let rows = [removal(generatedID), creation()]
        try await service.applyVerifiedMemorySynthesis(text(rows), expected: before, evidenceIDs: ["turn"], at: date, makeID: { newID }, lifetime: .init())
        let after = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(Set(after.memories), [manual, .init(synthesizedID: newID, accountID: "local", agentID: owner, fact: "New project", tier: .log, createdAt: date)])
        let reopened = try AgentService(storeURL: file)
        let restored = try await reopened.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(restored, after)
        await #expect(throws: AgentMemorySynthesisSnapshotChanged.self) {
            try await service.applyVerifiedMemorySynthesis(text(rows), expected: before, evidenceIDs: ["turn"], at: date, lifetime: .init())
        }
    }

    @Test func explicitDeletionCannotBeRecreatedButManualRewriteClearsTombstone() async throws {
        let (root, file, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await service.forgetMemoryFromEditor(generated, lifetime: .init())
        let reopened = try AgentService(storeURL: file)
        let before = try await reopened.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(before.tombstones, [.init(generated)])
        try await reopened.applyVerifiedMemorySynthesis(text([creation(" OLD PROJECT ")]), expected: before,
            evidenceIDs: ["turn"], at: date, makeID: { newID }, lifetime: .init())
        let unchanged = try await reopened.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(unchanged, before)
        let explicit = AgentMemory(id: newID, accountID: "local", agentID: owner, fact: "Old project", createdAt: date)
        try await reopened.applyMemoryChange(.init(operation: .write, memory: explicit), lifetime: .init())
        let after = try await reopened.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(after.tombstones, [])
        expectNoDifference(after.mutableMemoryIDs, [])
        expectNoDifference(Set(after.memories), [manual, explicit])
    }

    @Test(arguments: ["explicit", "cancelled", "collision", "stale", "oversize"])
    func rejectedBatchLeavesDiskAndMemoryUntouched(mode: String) async throws {
        let (root, file, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var before = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        let lifetime = AgentMemorySuggestionLifetime()
        var rows = [creation()]
        if mode == "explicit" { rows.append(removal(manualID)) }
        if mode == "cancelled" { lifetime.close() }
        if mode == "oversize" { rows.append(creation(String(repeating: "x", count: 501))) }
        if mode == "stale" {
            before = .init(accountID: "other", agentID: owner, memories: before.memories, tombstones: [])
        }
        let bytes = try Data(contentsOf: file)
        await #expect(throws: (any Error).self) {
            try await service.applyVerifiedMemorySynthesis(text(rows), expected: before, evidenceIDs: ["turn"],
                at: date, makeID: { mode == "collision" ? manualID : newID }, lifetime: lifetime)
        }
        // Compare decoded values; JSON Set serialization order is not a state change.
        let after = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(Set(after.memories), [manual, generated])
        expectNoDifference(try Data(contentsOf: file), bytes)
    }

    @Test func updateRetainsIdentityAndPublicWriteCannotForgeOrigin() async throws {
        let (root, _, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        let update: [String: Any] = ["action": "update", "id": generatedID.uuidString,
            "content": "Revised project", "kind": "profile", "sourceEvidenceIds": ["turn"]]
        try await service.applyVerifiedMemorySynthesis(text([update]), expected: before, evidenceIDs: ["turn"], at: date, lifetime: .init())
        let revised = AgentMemory(synthesizedID: generatedID, accountID: "local", agentID: owner,
            fact: "Revised project", tier: .profile, createdAt: date)
        let after = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(Set(after.memories), [manual, revised])
        await #expect(throws: AgentMemoryError.invalid) {
            try await service.applyMemoryChange(.init(operation: .write, memory: generated), lifetime: .init())
        }
    }

    @Test func persistenceFailureRollsBackThenCanRetry() async throws {
        let (root, file, service) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        let backup = root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let proposal = try text([removal(generatedID), creation()])
        await #expect(throws: (any Error).self) {
            try await service.applyVerifiedMemorySynthesis(proposal, expected: before, evidenceIDs: ["turn"], at: date, makeID: { newID }, lifetime: .init())
        }
        let unchanged = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(unchanged, before)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try await service.applyVerifiedMemorySynthesis(proposal, expected: before, evidenceIDs: ["turn"], at: date, makeID: { newID }, lifetime: .init())
        let retried = try await service.memorySynthesisSnapshot(accountID: "local", agentID: owner)
        expectNoDifference(retried.mutableMemoryIDs, [newID])
    }
}
