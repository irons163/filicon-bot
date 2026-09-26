import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Legacy episode progress")
struct AgentMemoryEpisodeProgressTests {
    private func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
    private func progress() throws -> AgentMemoryEpisodeProgress {
        try .init(accountID: "fixture", agentID: id(100), originID: id(101), revision: id(102))
    }
    private func record(_ n: Int, into value: inout AgentMemoryEpisodeProgress) throws {
        try value.record(id: id(n), at: Date(timeIntervalSince1970: Double(n)),
                         user: "Build an accessible dashboard", assistant: "Agreed on keyboard navigation")
    }

    @Test func sixTurnsSurviveReopenAndFinishPreservesNewArrivals() throws {
        var value = try progress()
        for n in 1...5 { try record(n, into: &value) }
        expectNoDifference(value.ready, [])
        value = try JSONDecoder().decode(AgentMemoryEpisodeProgress.self, from: JSONEncoder().encode(value))
        try record(5, into: &value)
        expectNoDifference(value.turns.count, 5)
        try record(6, into: &value)
        let batch = value.ready
        expectNoDifference(batch.count, 6)
        try record(7, into: &value)
        expectDifference(value.turns) { value.finish(batch) } changes: { $0.removeFirst(6) }
        try record(1, into: &value)
        expectNoDifference(value.turns.map(\.id), [id(7)])
        value.clearPending()
        expectNoDifference(value.ready, [])
    }

    @Test func referenceEligibilityAndSentinels() throws {
        for greeting in ["", "  ", "HI!!!", "thank   you…", "got it)]", "OK~"] {
            #expect(!AgentMemoryEpisodeProgress.isMemorable(greeting))
        }
        for content in ["hi?", "Build a website", String(repeating: "x", count: 41)] {
            #expect(AgentMemoryEpisodeProgress.isMemorable(content))
        }
        var value = try progress()
        #expect(try !value.record(id: id(1), at: .init(timeIntervalSince1970: 1), user: "Build a site", assistant: "PASS"))
        expectNoDifference(AgentMemoryEpisodeProgress.narrative("  none \n"), nil)
        expectNoDifference(AgentMemoryEpisodeProgress.narrative(" Built\n a   site. "), "Built a site.")
    }

    @Test func unicodeCapacityAndMalformedPersistence() throws {
        var value = try progress()
        for n in 1...70 {
            try value.record(id: id(n), at: .init(timeIntervalSince1970: Double(n)),
                             user: String(repeating: "a", count: 1_999) + "😀",
                             assistant: String(repeating: "😀", count: 2_000))
        }
        expectNoDifference(value.turns.count, 64)
        expectNoDifference(value.turns.first?.id, id(7))
        expectNoDifference(value.turns.first?.user.utf16.count, 1_999)
        expectNoDifference(value.turns.first?.assistant.utf16.count, 2_000)
        #expect(!value.turns[0].user.contains("�"))
        expectNoDifference(AgentMemoryEpisodeProgress.narrative(String(repeating: "😀", count: 501))?.utf16.count, 500)
        let data = try JSONEncoder().encode(value)
        expectNoDifference(try JSONDecoder().decode(AgentMemoryEpisodeProgress.self, from: data), value)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["recentIDs"] = []
        let corrupt = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(AgentMemoryEpisodeProgress.self, from: corrupt) }
        #expect(throws: AgentMemorySuggestionError.invalid) {
            try value.record(id: id(71), at: .init(timeIntervalSince1970: .nan), user: "Work", assistant: "Done")
        }
    }
}
