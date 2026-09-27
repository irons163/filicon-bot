import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAgents

@Suite("Direct inline message reference index")
struct DirectMessageReferenceTests {
    @Test func remoteOnlyTargetsPreserveVisibilityAndAddressChecks() throws {
        let remote = try RemoteAttachmentReference(url: "https://example.com/report?signature=exact", alt: "Report")
        var conversation = Conversation(title: "Remote references")
        let target = ChatMessage(role: .assistant, text: "", shortAddress: "t0s0", remoteAttachment: remote)
        let response = ChatMessage(role: .assistant, text: "See report", shortAddress: "t0s1")
        let url = try #require(URL(string: "sand-msg:t0s0"))
        conversation.messages = [target, response]
        for complete in [false, true] {
            let directory = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: complete)
            expectNoDifference(directory.target(for: url, from: response.id, in: conversation.id), complete ? target.id : nil)
        }
        conversation.messages[0].role = .tool
        let privateDirectory = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: true)
        expectNoDifference(privateDirectory.target(for: url, from: response.id, in: conversation.id), nil)
        conversation.messages = [target, target, response]
        let duplicateDirectory = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: true)
        expectNoDifference(duplicateDirectory.target(for: url, from: response.id, in: conversation.id), nil)
    }

    @Test func completeHistoryAndExactConversationAreRequired() throws {
        var conversation = Conversation(title: "References")
        let original = ChatMessage(role: .user, text: "Original", shortAddress: "t57u")
        let response = ChatMessage(role: .assistant, text: "Response", shortAddress: "t57s0")
        conversation.messages = [original, response]
        let url = try #require(URL(string: "sand-msg:t57u"))
        for complete in [false, true] {
            let index = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: complete)
            expectNoDifference(index.target(for: url, from: response.id, in: conversation.id), complete ? original.id : nil)
            expectNoDifference(index.target(for: url, from: response.id, in: UUID()), nil)
            expectNoDifference(index.target(for: url, from: original.id, in: conversation.id), nil)
        }
        conversation.messages.removeFirst()
        let deleted = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: true)
        expectNoDifference(deleted.target(for: url, from: response.id, in: conversation.id), nil)
    }

    @Test func ambiguousAndReservedAddressesCannotChangeIdentity() throws {
        var conversation = Conversation(title: "References")
        let original = ChatMessage(role: .user, text: "Original", shortAddress: "t0u")
        let response = ChatMessage(role: .assistant, text: "Response", shortAddress: "t0s0")
        let url = try #require(URL(string: "sand-msg:t0u"))
        conversation.messages = [original, response]
        conversation.messageAddressReservations = [original.id.uuidString: "t0u"]
        let valid = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: true)
        expectNoDifference(valid.target(for: url, from: response.id, in: conversation.id), original.id)
        conversation.messageAddressReservations[UUID().uuidString] = "t0u"
        let reserved = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: true)
        expectNoDifference(reserved.target(for: url, from: response.id, in: conversation.id), nil)
        conversation.messageAddressReservations = [:]
        conversation.messages.insert(original, at: 0)
        let duplicate = DirectMessageReferenceDirectory(conversation: conversation, historyComplete: true)
        expectNoDifference(duplicate.target(for: url, from: response.id, in: conversation.id), nil)
    }

    @Test func rejectsNonPublicMalformedAndFutureReferences() throws {
        var conversation = Conversation(title: "References")
        let original = ChatMessage(role: .user, text: "Original", shortAddress: "t0u")
        let response = ChatMessage(role: .assistant, text: "Response", shortAddress: "t0s0")
        conversation.messages = [
            original,
            ChatMessage(role: .tool, text: "Private tool", shortAddress: "tbs0"),
            ChatMessage(role: .system, text: "Private system", shortAddress: "tbs1"),
            ChatMessage(role: .assistant, text: " \n ", shortAddress: "tbs2"),
            ChatMessage(role: .user, text: "Wrong role", shortAddress: "tbs3"),
            response,
            ChatMessage(role: .user, text: "Future", shortAddress: "t1u")
        ]
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        let index = DirectMessageReferenceDirectory(conversation: restored, historyComplete: true)
        for raw in ["sand-msg:tbs0", "sand-msg:tbs1", "sand-msg:tbs2", "sand-msg:tbs3",
                    "sand-msg:t0s0", "sand-msg:t1u", "sand-msg:t0a0", "sand-msg:t00u",
                    "sand-msg://t0u", "sand-msg:%740u", "sand-msg:t0u?x=1", "sand-msg:t0u#x",
                    "sand-msg:\(original.id)", "https://example.com/t0u"] {
            let url = try #require(URL(string: raw))
            expectNoDifference(index.target(for: url, from: response.id, in: conversation.id), nil)
        }
        let valid = try #require(URL(string: "sand-msg:t0u"))
        expectNoDifference(index.target(for: valid, from: response.id, in: conversation.id), original.id)
    }
}
