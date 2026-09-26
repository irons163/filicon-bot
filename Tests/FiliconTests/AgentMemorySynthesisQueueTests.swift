import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Memory synthesis pending queue")
struct AgentMemorySynthesisQueueTests {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
    private func settings(_ n: Int = 1, account: String = "local", revision: Int = 100) -> AgentMemorySynthesisSettings {
        var result = AgentMemorySynthesisSettings(accountID: account, agentID: id(n))
        result.enabled = true; result.revision = id(revision)
        return result
    }
    private func entry(_ n: Int, origin: Int = 200) -> AgentMemorySynthesisQueue.Entry {
        .init(originID: id(origin), evidence: .init(id: "turn-\(n)", occurredAt: Date(timeIntervalSince1970: 100),
            user: "Preference \(n)", assistant: "Understood"))
    }

    @Test func debounceResetsAndDetachedCompletionCannotConsumeNewEvidence() throws {
        var queue = AgentMemorySynthesisQueue()
        let now = ContinuousClock.now
        try queue.enqueue(settings: settings(), entry: entry(1), now: now)
        expectNoDifference(queue.takeReady(now: now.advanced(by: .seconds(14))), [])
        try queue.enqueue(settings: settings(), entry: entry(2), now: now.advanced(by: .seconds(10)))
        expectNoDifference(queue.nextRun, now.advanced(by: .seconds(25)))
        expectNoDifference(queue.takeReady(now: now.advanced(by: .seconds(15))), [])
        let batch = queue.takeReady(now: now.advanced(by: .seconds(25)))
        expectNoDifference(batch.first?.entries, [entry(1), entry(2)])
        expectNoDifference(queue.count, 0)
        try queue.enqueue(settings: settings(), entry: entry(3), now: now.advanced(by: .seconds(26)))
        expectNoDifference(batch.first?.entries, [entry(1), entry(2)])
        expectNoDifference(queue.takeReady(now: now.advanced(by: .seconds(41))).first?.entries, [entry(3)])
        expectNoDifference(queue.nextRun, nil)
    }

    @Test func capsEvictOldestAgentsAndEvidenceWithoutCrossAccountMixing() throws {
        var queue = AgentMemorySynthesisQueue()
        let now = ContinuousClock.now
        for n in 1...64 { try queue.enqueue(settings: settings(n), entry: entry(n), now: now) }
        let admission = try queue.enqueue(settings: settings(65), entry: entry(65), now: now)
        expectNoDifference(admission.droppedAgents, 1)
        expectNoDifference(admission.droppedEvidence, 1)
        expectNoDifference(queue.count, 64)
        let batches = queue.takeReady(now: now.advanced(by: .seconds(15)))
        expectNoDifference(batches.map(\.settings.agentID), (2...65).map(id))
        for n in 1...13 { try queue.enqueue(settings: settings(), entry: entry(n), now: now) }
        try queue.enqueue(settings: settings(account: "other"), entry: entry(1), now: now)
        let scoped = queue.takeReady(now: now.advanced(by: .seconds(15)))
        try #require(scoped.count == 2)
        expectNoDifference(scoped[0].entries, (2...13).map { entry($0) })
        expectNoDifference(scoped[1].entries, [entry(1)])
        expectNoDifference(scoped.map(\.settings.accountID), ["local", "other"])
    }

    @Test func duplicateConflictRevisionAndOriginRemovalAreBounded() throws {
        var queue = AgentMemorySynthesisQueue()
        let now = ContinuousClock.now
        try queue.enqueue(settings: settings(), entry: entry(1), now: now)
        let duplicate = try queue.enqueue(settings: settings(), entry: entry(1), now: now.advanced(by: .seconds(10)))
        expectNoDifference(duplicate.inserted, false)
        expectNoDifference(queue.nextRun, now.advanced(by: .seconds(15)))
        #expect(throws: AgentMemorySuggestionError.invalid) {
            try queue.enqueue(settings: settings(), entry: entry(1, origin: 201), now: now)
        }
        let changed = try queue.enqueue(settings: settings(revision: 101), entry: entry(2, origin: 201), now: now)
        expectNoDifference(changed.droppedEvidence, 1)
        try queue.enqueue(settings: settings(revision: 101), entry: entry(3), now: now)
        queue.removeOrigin(id(201))
        let batch = queue.takeReady(now: now.advanced(by: .seconds(15)))
        expectNoDifference(batch.first?.entries, [entry(3)])
        expectNoDifference(batch.first?.settings, settings(revision: 101))
        try queue.enqueue(settings: settings(), entry: entry(4), now: now)
        queue.removeAgent(accountID: "other", agentID: id(1))
        expectNoDifference(queue.count, 1)
        expectDifference(queue.count) {
            queue.removeAgent(accountID: "local", agentID: id(1))
        } changes: { $0 = 0 }
        expectNoDifference(queue.nextRun, nil)
    }

    @Test func disabledConsentAndInvalidEvidenceNeverEnterQueue() throws {
        var queue = AgentMemorySynthesisQueue()
        let now = ContinuousClock.now
        #expect(throws: AgentMemorySuggestionError.invalid) {
            try queue.enqueue(settings: .init(accountID: "local", agentID: id(1)), entry: entry(1), now: now)
        }
        for text in ["", "PASS", "(pass)", String(repeating: "x", count: 8_001)] {
            let invalid = AgentMemorySynthesisQueue.Entry(originID: id(200),
                evidence: .init(id: "turn", occurredAt: Date(timeIntervalSince1970: 100), user: "Hello", assistant: text))
            #expect(throws: AgentMemorySuggestionError.invalid) {
                try queue.enqueue(settings: settings(), entry: invalid, now: now)
            }
        }
        expectNoDifference(queue.count, 0)
        expectNoDifference(queue.nextRun, nil)
    }

    @Test(arguments: ["empty-id", "long-id", "empty-user", "nonfinite", "utf8", "missing-revision"])
    func invalidAdmissionPreservesAlreadyQueuedEvidence(mode: String) throws {
        var queue = AgentMemorySynthesisQueue()
        let now = ContinuousClock.now
        try queue.enqueue(settings: settings(), entry: entry(1), now: now)
        var consent = settings()
        if mode == "missing-revision" { consent.revision = nil }
        let value = AgentMemorySynthesisQueue.Entry(originID: id(200), evidence: .init(
            id: mode == "empty-id" ? "" : mode == "long-id" ? String(repeating: "x", count: 65) : "invalid",
            occurredAt: Date(timeIntervalSince1970: mode == "nonfinite" ? .infinity : 100),
            user: mode == "empty-user" ? " " : "Hello",
            assistant: mode == "utf8" ? String(repeating: "a\u{0301}\u{0302}\u{0303}", count: 7_000) : "Understood"))
        #expect(throws: AgentMemorySuggestionError.invalid) {
            try queue.enqueue(settings: consent, entry: value, now: now.advanced(by: .seconds(5)))
        }
        expectNoDifference(queue.nextRun, now.advanced(by: .seconds(15)))
        expectNoDifference(queue.takeReady(now: now.advanced(by: .seconds(15))).first?.entries, [entry(1)])
    }
}
