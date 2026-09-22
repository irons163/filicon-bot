import Foundation
import Testing
import CustomDump
import FiliconAgents

@Suite("Group inline message references")
struct GroupMessageReferenceTests {
    private func row(_ address: String?, group: UUID, user: Bool = false) -> RoomMessage {
        var message = RoomMessage(groupID: group, senderID: user ? nil : UUID(), text: "Visible message")
        message.shortAddress = address
        return message
    }

    @Test func referencesUseStoredAddressesAndSurviveRoundTripWithoutPromptRenumbering() throws {
        let group = UUID()
        let source = row("t57u", group: group, user: true)
        let proposal = row("t57s3", group: group)
        let response = row("t58s0", group: group)
        let history = [source, proposal, response]
        for stored in [history, try JSONDecoder().decode([RoomMessage].self, from: JSONEncoder().encode(history))] {
            let directory = GroupMessageReferenceDirectory(history: stored, groupID: group)
            expectNoDifference(directory.target(for: URL(string: "sand-msg:t57u")!, from: response.id), source.id)
            expectNoDifference(directory.target(for: URL(string: "sand-msg:t57s3")!, from: response.id), proposal.id)
            expectNoDifference(directory.target(for: URL(string: "sand-msg:t0u")!, from: response.id), nil)
        }
        let withoutOriginal = GroupMessageReferenceDirectory(history: [response], groupID: group)
        expectNoDifference(withoutOriginal.target(for: URL(string: "sand-msg:t57u")!, from: response.id), nil)
    }

    @Test func rejectsAmbiguousMissingForeignEmptyStatusAndFutureTargets() throws {
        let group = UUID(), foreign = UUID()
        let valid = row("t0u", group: group, user: true)
        let response = row("t0s0", group: group)
        let later = row("t1u", group: group, user: true)
        var empty = row("tbs0", group: group); empty.text = " \n "
        var status = row("tbs1", group: group); status.memberOutcome = .failed
        let wrongRole = row("tbs2", group: group, user: true)
        let duplicatedAddress = row("tbs3", group: group)
        let duplicatedID = row("tbs4", group: group)
        let history = [valid, row("t0u", group: foreign, user: true), row("t3u", group: foreign, user: true),
                       empty, status, wrongRole, duplicatedAddress, row("tbs3", group: group),
                       duplicatedID, duplicatedID, response, later]
        let directory = GroupMessageReferenceDirectory(history: history, groupID: group)
        expectNoDifference(directory.target(for: URL(string: "sand-msg:t0u")!, from: response.id), valid.id)
        for address in ["t0s0", "t1u", "t3u", "tbs0", "tbs1", "tbs2", "tbs3", "tbs4", "t99s0"] {
            expectNoDifference(directory.target(for: URL(string: "sand-msg:\(address)")!, from: response.id), nil)
        }
        expectNoDifference(directory.target(for: URL(string: "sand-msg:t0u")!, from: UUID()), nil)
        let duplicateSource = GroupMessageReferenceDirectory(history: history + [response], groupID: group)
        expectNoDifference(duplicateSource.target(for: URL(string: "sand-msg:t0u")!, from: response.id), nil)
        // A previously missing reference must not start pointing to a future publication.
        expectNoDifference(directory.target(for: URL(string: "sand-msg:t1u")!, from: valid.id), nil)
    }

    @Test func rejectsURLSyntaxThatCouldEscapeGroupOrAddressIdentity() throws {
        let group = UUID()
        let original = row("t0u", group: group, user: true)
        let response = row("t0s0", group: group)
        let directory = GroupMessageReferenceDirectory(history: [original, response], groupID: group)
        for raw in ["https://example.com/t0u", "file:///t0u", "SAND-MSG:t0u", "sand-msg://t0u",
                    "sand-msg:///t0u", "sand-msg:t0u?x=1", "sand-msg:t0u#x", "sand-msg:%740u",
                    "sand-msg:t00u", "sand-msg:t0a0", "sand-msg:t0ua0", "sand-msg:\(original.id)",
                    "sand-msg:t1000000000u", "sand-msg:t0u/../t0u", "sand-msg:t0u "] {
            let url = try #require(URL(string: raw))
            expectNoDifference(directory.target(for: url, from: response.id), nil)
        }
    }
}
