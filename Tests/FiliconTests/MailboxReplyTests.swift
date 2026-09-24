import CustomDump
import Foundation
import Testing
import FiliconAgents

@Suite("Scoped mailbox reply persistence", .timeLimit(.minutes(1)))
struct MailboxReplyTests {
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let date = Date(timeIntervalSince1970: 1_000)

    @Test(arguments: ["valid", "duplicate", "future", "foreignScope", "foreignSender"])
    func displayResolutionUsesOnlyEarlierUnambiguousMailboxMessages(mode: String) {
        let sender = UUID(), owner = UUID(), foreign = UUID()
        let target = AgentMessage(senderID: mode == "foreignSender" ? foreign : sender,
            recipientID: owner, text: "Original", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: mode == "foreignScope" ? foreign : scope))
        var input = AgentMessage(senderID: sender, recipientID: owner, text: "Now", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        var publication = RoomMessage(groupID: scope, senderID: owner, text: "Answer", createdAt: date)
        publication.replyToMessageID = target.id
        input.delivery?.publications = [publication]
        let messages = mode == "future" ? [input, target] : mode == "duplicate" ? [target, target, input] : [target, input]
        let original = AgentMessenger.replySource(for: publication, replyingTo: input.id, messages: messages)
        expectNoDifference(original?.text, mode == "valid" ? "Original" : nil)
    }

    @Test(arguments: ["valid", "foreignScope", "foreignSender", "future", "self", "missing"])
    func validatesReferencesBeforeSaving(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", instructions: "fixture", at: date)
        let owner = try await agents.create(name: "Owner", instructions: "fixture", at: date)
        let other = try await agents.create(name: "Other", instructions: "fixture", at: date)
        let file = root.appending(path: "mail.json")
        let messenger = try AgentMessenger(service: agents, storeURL: file)
        let target = AgentMessage(senderID: mode == "foreignSender" ? other.id : sender.id,
            recipientID: owner.id, text: "Earlier", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: mode == "foreignScope" ? other.id : scope))
        let input = AgentMessage(senderID: sender.id, recipientID: owner.id, text: "Now", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        if mode != "future" { try await messenger.send(target) }
        try await messenger.send(input)
        if mode == "future" { try await messenger.send(target) }
        try await messenger.updateDelivery(id: input.id, state: .running)
        var publication = RoomMessage(groupID: scope, senderID: owner.id, text: "Answer", createdAt: date)
        publication.replyToMessageID = mode == "self" ? publication.id : mode == "missing" ? other.id : target.id
        let before = await messenger.allMessages()
        if mode == "valid" {
            try await messenger.publish(publication, replyingTo: input.id, lifetime: .init())
            try await messenger.publish(publication, replyingTo: input.id, lifetime: .init())
            let saved = await messenger.allMessages()
            expectNoDifference(saved.last?.delivery?.publications, [publication])
            let restored = try AgentMessenger(service: agents, storeURL: file)
            let reloaded = await restored.allMessages()
            expectNoDifference(reloaded.last?.delivery?.publications, [publication])
        } else {
            await #expect(throws: AgentPublicationError.invalid) {
                try await messenger.publish(publication, replyingTo: input.id, lifetime: .init())
            }
            let after = await messenger.allMessages()
            expectNoDifference(after, before)
        }
    }

    @Test func currentInputAndSavedPublicationAreTargetsWithoutIncreasingBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-reply-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", instructions: "fixture", at: date)
        let owner = try await agents.create(name: "Owner", instructions: "fixture", at: date)
        let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "mail.json"))
        let input = AgentMessage(senderID: sender.id, recipientID: owner.id, text: "Now", createdAt: date,
            delivery: .init(chainID: scope, originConversationID: scope))
        try await messenger.send(input)
        try await messenger.updateDelivery(id: input.id, state: .running)
        var first = RoomMessage(groupID: scope, senderID: owner.id, text: "First", createdAt: date)
        first.replyToMessageID = input.id
        try await messenger.publish(first, replyingTo: input.id, lifetime: .init())
        var second = RoomMessage(groupID: scope, senderID: owner.id, text: "Second", createdAt: date)
        second.replyToMessageID = first.id
        try await messenger.publish(second, replyingTo: input.id, lifetime: .init())
        let directory = try await messenger.replyDirectory(replyingTo: input.id)
        expectNoDifference(directory.map(\.id), [input.id, first.id, second.id])
        var third = RoomMessage(groupID: scope, senderID: owner.id, text: "Third", createdAt: date)
        third.replyToMessageID = second.id
        await #expect(throws: (any Error).self) {
            try await messenger.publish(third, replyingTo: input.id, lifetime: .init())
        }
    }
}
