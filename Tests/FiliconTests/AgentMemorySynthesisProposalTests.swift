import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Memory synthesis proposal boundary")
struct AgentMemorySynthesisProposalTests {
    private let target = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func parse(_ rows: [[String: Any]], evidence: Set<String> = ["turn-1"],
                       clock: String? = nil) throws -> AgentMemorySynthesisProposal {
        let data = try JSONSerialization.data(withJSONObject: ["changes": rows])
        return try .parse(String(decoding: data, as: UTF8.self), evidenceIDs: evidence,
                          mutableMemoryIDs: [target], clockEvidenceID: clock)
    }
    private var creation: [String: Any] {
        ["action": "create", "content": "  Prefers concise answers  ", "kind": "profile", "sourceEvidenceIds": ["turn-1"]]
    }

    @Test func boundedChangesAndNoWork() throws {
        let update: [String: Any] = ["action": "update", "id": target.uuidString,
            "content": "Project is scheduled", "kind": "log", "sourceEvidenceIds": ["turn-1"]]
        expectNoDifference(try parse([creation, update]), .init(changes: [
            .init(action: .create, id: nil, content: "Prefers concise answers", tier: .profile, evidenceIDs: ["turn-1"]),
            .init(action: .update, id: target, content: "Project is scheduled", tier: .log, evidenceIDs: ["turn-1"])
        ]))
        expectNoDifference(try parse([]).changes, [])
    }

    @Test(arguments: ["unknown-evidence", "duplicate-evidence", "no-evidence", "extra-key", "id-on-create",
        "note-tier", "empty", "long", "control", "explicit", "duplicate-target", "too-many", "bad-action"])
    func rejectsWholeBatch(mode: String) throws {
        var bad = creation
        var rows: [[String: Any]] = []
        switch mode {
        case "unknown-evidence": bad["sourceEvidenceIds"] = ["other-turn"]
        case "duplicate-evidence": bad["sourceEvidenceIds"] = ["turn-1", "turn-1"]
        case "no-evidence": bad["sourceEvidenceIds"] = [String]()
        case "extra-key": bad["accountID"] = "other"
        case "id-on-create": bad["id"] = target.uuidString
        case "note-tier": bad["kind"] = "note"
        case "empty": bad["content"] = "   "
        case "long": bad["content"] = String(repeating: "字", count: 501)
        case "control": bad["content"] = "fact\u{0}"
        case "explicit": bad = ["action": "remove", "id": "00000000-0000-0000-0000-000000000002", "sourceEvidenceIds": ["turn-1"]]
        case "duplicate-target":
            bad = ["action": "remove", "id": target.uuidString, "sourceEvidenceIds": ["turn-1"]]
            rows = [bad]
        case "too-many": rows = Array(repeating: creation, count: 64)
        default: bad["action"] = "execute"
        }
        rows.append(bad)
        #expect(throws: AgentMemorySynthesisProposal.Invalid.self) { try parse(rows) }
    }

    @Test func clockIsNotNewEvidenceOrImplicitlyTrusted() throws {
        var create = creation; create["sourceEvidenceIds"] = ["clock"]
        #expect(throws: AgentMemorySynthesisProposal.Invalid.self) { try parse([create], clock: "clock") }
        let remove: [String: Any] = ["action": "remove", "id": target.uuidString, "sourceEvidenceIds": ["clock"]]
        #expect(throws: AgentMemorySynthesisProposal.Invalid.self) { try parse([remove]) }
        expectNoDifference(try parse([remove], clock: "clock").changes, [
            .init(action: .remove, id: target, content: nil, tier: nil, evidenceIDs: ["clock"])
        ])
        #expect(throws: AgentMemorySynthesisProposal.Invalid.self) { try parse([], evidence: ["clock"], clock: "clock") }
    }

    @Test func oversizedEnvelopeIsRejected() {
        #expect(throws: AgentMemorySynthesisProposal.Invalid.self) {
            try AgentMemorySynthesisProposal.parse(String(repeating: "x", count: 262_145),
                evidenceIDs: ["turn-1"], mutableMemoryIDs: [target])
        }
    }

    @Test(arguments: ["null", "[]", "{\"changes\":null}", "{\"changes\":[],\"execute\":true}", "```json\n{\"changes\":[]}\n```"])
    func malformedEnvelopeIsRejected(text: String) {
        #expect(throws: AgentMemorySynthesisProposal.Invalid.self) {
            try AgentMemorySynthesisProposal.parse(text, evidenceIDs: ["turn-1"], mutableMemoryIDs: [target])
        }
    }
}
