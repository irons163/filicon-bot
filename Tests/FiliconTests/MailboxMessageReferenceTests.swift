import Foundation
import Testing
import CustomDump
import FiliconAgents

@Suite("Mailbox reference navigation", .timeLimit(.minutes(1)))
struct MailboxMessageReferenceTests {
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let date = Date(timeIntervalSince1970: 1_000)

    @Test(arguments: ["targetCollision", "sourceCollision", "inputCollision", "wrongAuthor", "wrongGroup"])
    func invalidIdentitiesCannotEnterIndex(mode: String) throws {
        var incoming = AgentMessage(senderID: sender, recipientID: owner, text: "Input", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        var publication = RoomMessage(groupID: mode == "wrongGroup" ? sender : scope,
            senderID: mode == "wrongAuthor" ? sender : owner, text: "Reply", createdAt: date)
        publication.replyToMessageID = incoming.id
        incoming.delivery?.publications = [publication]
        var history = [incoming]
        if mode.hasSuffix("Collision") {
            // Even a foreign, invalid publication must reserve its identity globally.
            let duplicateID = mode == "sourceCollision" ? publication.id : incoming.id
            var foreign = AgentMessage(senderID: owner, recipientID: sender, text: "Foreign", createdAt: date,
                delivery: .init(chainID: owner, originConversationID: owner))
            if mode == "inputCollision" {
                foreign = AgentMessage(id: duplicateID, senderID: owner, recipientID: sender, text: "Foreign", createdAt: date)
            } else {
                foreign.delivery?.publications = [RoomMessage(id: duplicateID, groupID: sender,
                    senderID: sender, text: "Invalid foreign copy", createdAt: date)]
            }
            history.append(foreign)
        }
        let references = MailboxMessageReferences(history: history, addresses: [incoming.id: "t0u"], humanInputs: [incoming.id])
        expectNoDifference(references.target(for: URL(string: "sand-msg:t0u")!, from: publication.id, replyingTo: incoming.id)?.message.id, nil)
        expectNoDifference(references.quotedTarget(from: publication.id, replyingTo: incoming.id)?.message.id, nil)
        expectNoDifference(references.referenceTarget(incoming.id, from: publication.id, replyingTo: incoming.id)?.message.id, nil)
    }

    @Test func repeatedLookupsAreScopedAndSnapshotIsImmutable() throws {
        var history: [AgentMessage] = []
        var addresses: [UUID: String] = [:]
        for number in 0..<1_000 {
            let origin = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!
            var input = AgentMessage(senderID: sender, recipientID: owner, text: "Input \(number)", createdAt: date,
                delivery: .init(chainID: origin, originConversationID: origin))
            var reply = RoomMessage(groupID: origin, senderID: owner, text: "Reply", createdAt: date)
            reply.replyToMessageID = input.id
            input.delivery?.publications = [reply]
            history.append(input)
            addresses[input.id] = "t0u"
        }
        let references = MailboxMessageReferences(history: history, addresses: addresses, humanInputs: Set(history.map(\.id)))
        for input in history {
            let reply = try #require(input.delivery?.publications?.first)
            expectNoDifference(references.target(for: URL(string: "sand-msg:t0u")!, from: reply.id, replyingTo: input.id)?.message.id, input.id)
            expectNoDifference(references.quotedTarget(from: reply.id, replyingTo: input.id)?.incoming.id, input.id)
            expectNoDifference(references.referenceTarget(input.id, from: reply.id, replyingTo: input.id)?.message.id, input.id)
            expectNoDifference(references.quotedTarget(from: input.id, replyingTo: input.id)?.message.id, nil)
        }
        let first = try #require(history.first)
        let reply = try #require(first.delivery?.publications?.first)
        history.removeAll()
        addresses.removeAll()
        expectNoDifference(references.referenceTarget(first.id, from: reply.id, replyingTo: first.id)?.message.text, "Input 0")
        expectNoDifference(MailboxMessageReferences(history: history, addresses: addresses)
            .referenceTarget(first.id, from: reply.id, replyingTo: first.id)?.message.id, nil)
    }

    @Test(arguments: ["valid", "foreignScope", "reverse", "duplicateID", "duplicateAddress", "future", "wrongSource"])
    func navigationIsEarlierUniqueAndDirected(mode: String) throws {
        let original = AgentMessage(senderID: mode == "reverse" ? owner : sender,
            recipientID: mode == "reverse" ? sender : owner, text: "Original", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: mode == "foreignScope" ? owner : scope))
        var current = AgentMessage(senderID: sender, recipientID: owner, text: "Now", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        var publication = RoomMessage(groupID: scope, senderID: owner, text: "See [original](sand-msg:t0u)", createdAt: date)
        publication.replyToMessageID = original.id
        current.delivery?.publications = [publication]
        let extra = AgentMessage(senderID: sender, recipientID: owner, text: "Later", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        var history = mode == "future" ? [current, original] : [original, current]
        if mode == "duplicateID" { history.append(original) }
        if mode == "duplicateAddress" { history.append(extra) }
        let references = MailboxMessageReferences(history: history,
            addresses: [original.id: "t0u", current.id: "t1u", publication.id: "t1s0", extra.id: "t0u"],
            humanInputs: [original.id, current.id, extra.id])
        let source = mode == "wrongSource" ? original.id : current.id
        let target = references.target(for: try #require(URL(string: "sand-msg:t0u")), from: publication.id, replyingTo: source)
        expectNoDifference(target?.message.id, mode == "valid" ? original.id : nil)
        expectNoDifference(target?.incoming.id, mode == "valid" ? original.id : nil)
        expectNoDifference(references.referenceTarget(original.id, from: publication.id, replyingTo: source)?.message.id,
                           mode == "valid" ? original.id : nil)
        expectNoDifference(references.quotedTarget(from: publication.id, replyingTo: source)?.message.id,
                           mode == "valid" || mode == "duplicateAddress" ? original.id : nil)
        for raw in ["https://example.com/t0u", "file:///t0u", "sand-msg://t0u", "sand-msg:t0u?x=1",
                    "sand-msg:t0u#x", "sand-msg:t00u", "sand-msg:%740u", "sand-msg:\(original.id)", "sand-msg:t1s0"] {
            let url = try #require(URL(string: raw))
            expectNoDifference(references.target(for: url, from: publication.id, replyingTo: source)?.message.id, nil)
        }
    }

    @Test func publishedTargetKeepsItsOwnIdentityAndContainingRowBeyondPromptWindow() throws {
        var original = AgentMessage(senderID: sender, recipientID: owner, text: "Start", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        let answer = RoomMessage(groupID: scope, senderID: owner, text: "Original answer", createdAt: date)
        original.delivery?.publications = [answer]
        var history = [original]
        for number in 0..<510 {
            history.append(AgentMessage(senderID: sender, recipientID: owner, text: "Middle \(number)", createdAt: date,
                delivery: .init(chainID: scope, originConversationID: scope)))
        }
        let removed = history.popLast()
        var last = try #require(removed)
        var reply = RoomMessage(groupID: scope, senderID: owner, text: "See [answer](sand-msg:t0s0)", createdAt: date)
        reply.replyToMessageID = answer.id
        last.delivery?.publications = [reply]
        history.append(last)
        let references = MailboxMessageReferences(history: history, addresses: [answer.id: "t0s0", reply.id: "t510s0"])
        let result = try #require(references.target(for: URL(string: "sand-msg:t0s0")!, from: reply.id, replyingTo: last.id))
        expectNoDifference(result.message.id, answer.id)
        expectNoDifference(result.incoming.id, original.id)
        expectNoDifference(references.quotedTarget(from: reply.id, replyingTo: last.id)?.message.id, answer.id)
    }
}
