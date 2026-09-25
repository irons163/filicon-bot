import Foundation
import Testing
import CustomDump
@testable import FiliconAgents

@Suite("Durable directed mailbox addresses", .timeLimit(.minutes(1)))
struct MailboxMessageAddressTests {
    private let origin = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let sender = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let recipient = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let date = Date(timeIntervalSince1970: 1_000)

    private func input(_ number: Int, reverse: Bool = false) -> AgentMessage {
        AgentMessage(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012d", number))!,
            senderID: reverse ? recipient : sender, recipientID: reverse ? sender : recipient,
            text: "Input \(number)", createdAt: date,
            delivery: .init(chainID: origin, originConversationID: origin))
    }

    @Test func fullHistoryAllocationPreservesSourceAndDirectedScope() throws {
        var state = AgentPersistentState()
        let peer = input(0), human = input(1), reverse = input(2, reverse: true)
        var answered = human
        let publication = RoomMessage(groupID: origin, senderID: recipient, text: "Answer", createdAt: date)
        answered.delivery?.publications = [publication]
        state.messages = [peer, answered, reverse]
        state.mailboxHumanInputs = [human.id, reverse.id]
        #expect(MailboxMessageAddressing.assignMissing(in: &state))
        expectNoDifference(state.mailboxAddresses[peer.id], "tbs0")
        expectNoDifference(state.mailboxAddresses[human.id], "t0u")
        expectNoDifference(state.mailboxAddresses[publication.id], "t0s0")
        expectNoDifference(state.mailboxAddresses[reverse.id], "t0u")
        let original = state.mailboxAddresses
        for number in 3...45 {
            let message = input(number)
            state.messages.append(message)
            state.mailboxHumanInputs.insert(message.id)
        }
        MailboxMessageAddressing.assignMissing(in: &state)
        for (id, address) in original { expectNoDifference(state.mailboxAddresses[id], address) }
        expectNoDifference(state.mailboxAddresses[input(45).id], "t43u")
        state = try JSONDecoder().decode(AgentPersistentState.self, from: JSONEncoder().encode(state))
        #expect(!MailboxMessageAddressing.assignMissing(in: &state))
        expectNoDifference(state.mailboxAddresses[input(45).id], "t43u")
    }

    @Test func legacyAndDamagedAddressesAreNotReinterpretedAsHumanOrRenumbered() throws {
        var state = AgentPersistentState()
        state.messages = [input(0), input(1), input(2)]
        state.mailboxAddresses = [input(0).id: "tbs9", input(1).id: "tbs9"]
        MailboxMessageAddressing.assignMissing(in: &state)
        expectNoDifference(state.mailboxAddresses[input(0).id], "tbs9")
        expectNoDifference(state.mailboxAddresses[input(1).id], "tbs9")
        expectNoDifference(state.mailboxAddresses[input(2).id], "tbs10")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "mailboxAddresses")
        json.removeValue(forKey: "mailboxHumanInputs")
        var legacy = try JSONDecoder().decode(AgentPersistentState.self, from: JSONSerialization.data(withJSONObject: json))
        MailboxMessageAddressing.assignMissing(in: &legacy)
        expectNoDifference(legacy.mailboxAddresses[input(0).id], "tbs0")
        expectNoDifference(legacy.mailboxHumanInputs, [])
    }

    @Test func canonicalReceiptAndDirectorySurviveRestartAndEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-address-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        let from = try await service.create(name: "Sender", instructions: "fixture", at: date)
        let to = try await service.create(name: "Owner", instructions: "fixture", at: date)
        let file = root.appending(path: "mail.json")
        let messenger = try AgentMessenger(service: service, storeURL: file)
        var incoming: [AgentMessage] = []
        for number in 0...41 {
            let message = AgentMessage(id: input(number).id, senderID: from.id, recipientID: to.id,
                text: "Human \(number)", createdAt: date, delivery: .init(chainID: origin, originConversationID: origin))
            try await messenger.sendUserMessage(message, accountID: "fixture", lifetime: .init())
            incoming.append(message)
        }
        let last = try #require(incoming.last)
        try await messenger.updateDelivery(id: last.id, state: .running)
        var publication = RoomMessage(groupID: origin, senderID: to.id, text: "Answer", createdAt: date)
        publication.replyToMessageID = last.id
        let receipt = try await messenger.publish(publication, replyingTo: last.id, lifetime: .init())
        expectNoDifference(receipt.shortAddress, "t41s0")
        let bytes = try Data(contentsOf: file)
        let replay = try await messenger.publish(receipt, replyingTo: last.id, lifetime: .init())
        expectNoDifference(replay, receipt)
        expectNoDifference(try Data(contentsOf: file), bytes)
        let directory = try await messenger.replyDirectory(replyingTo: last.id)
        expectNoDifference(directory.count, 40)
        expectNoDifference(directory.first?.shortAddress, "t3u")
        expectNoDifference(directory.last?.shortAddress, "t41s0")
        expectNoDifference(directory.dropLast().last?.senderID, nil)
        let restarted = try AgentMessenger(service: service, storeURL: file)
        let restored = try await restarted.replyDirectory(replyingTo: last.id)
        expectNoDifference(restored, directory)
    }

    @Test func ambiguousAddressOutsideVisibleWindowCannotBecomeActionable() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mailbox-ambiguous-address-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        var state = AgentPersistentState()
        state.messages = (0...41).map { input($0) }
        state.mailboxHumanInputs = Set(state.messages.map(\.id))
        MailboxMessageAddressing.assignMissing(in: &state)
        state.mailboxAddresses[input(0).id] = "t41u"
        let file = root.appending(path: "mail.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: file)
        let messenger = try AgentMessenger(service: service, storeURL: file)
        let directory = try await messenger.replyDirectory(replyingTo: input(41).id)
        expectNoDifference(directory.count, 40)
        #expect(!directory.contains(where: { $0.id == input(0).id }))
        expectNoDifference(directory.last?.id, input(41).id)
        expectNoDifference(directory.last?.shortAddress, nil)
        expectNoDifference(directory.first?.shortAddress, "t2u")
    }
}
