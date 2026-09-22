import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
import FiliconAppServices
import FiliconDomain

private actor AddressPublicationProbe {
    var targets: [UUID] = []
    func record(_ target: UUID) { targets.append(target) }
}

@Suite("Durable group message addresses", .timeLimit(.minutes(1)))
struct GroupMessageAddressTests {
    private let group = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let member = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let foreign = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!

    private func message(user: Bool = false, text: String = "A message", address: String? = nil) -> RoomMessage {
        var result = RoomMessage(groupID: group, senderID: user ? nil : member, text: text, createdAt: Date(timeIntervalSince1970: 1_000))
        result.shortAddress = address
        return result
    }

    private func call(_ address: String, widget: Bool = false, id: ToolCallID = "reply") throws -> NormalizedToolCall {
        var object: [String: Any] = widget
            ? ["type": "widget", "widget": ["prompt": "Review?", "options": [["label": "Yes"]]]]
            : ["text": "A quoted reply"]
        object["reply_to"] = address
        return try .init(id: id, name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: object))
    }

    @Test func fullLogMigrationIsZeroBasedPerGroupAndNeverRenumbersPublishedAddresses() throws {
        var status = message(text: "Host notice")
        status.memberOutcome = .passed
        var messages = [message(), message(user: true), message(), status,
            RoomMessage(groupID: foreign, senderID: nil, text: "Other group"), message(), message(user: true), message(text: "")]
        GroupMessageAddressing.assignMissing(in: &messages)
        expectNoDifference(messages.map(\.shortAddress), ["tbs0", "t0u", "t0s0", nil, "t0u", "t0s1", "t1u", nil])
        messages[7].text = "The tool-only placeholder now has a visible result"
        GroupMessageAddressing.assignMissing(in: &messages)
        expectNoDifference(messages[7].shortAddress, "t1s0")
        let saved = messages
        GroupMessageAddressing.assignMissing(in: &messages)
        expectNoDifference(messages, saved)
        messages = try JSONDecoder().decode([RoomMessage].self, from: JSONEncoder().encode(messages))
        // A persisted suffix must not become turn zero when fed to a model.
        messages = Array(messages.suffix(2))
        messages.append(message())
        messages.append(message(user: true))
        GroupMessageAddressing.assignMissing(in: &messages)
        expectNoDifference(messages.map(\.shortAddress), ["t1u", "t1s0", "t1s1", "t2u"])
    }

    @Test func reservationsPreserveDamagedAndSparseHistoryWithoutInventingEquivalentAddresses() {
        var messages = [message(user: true, address: "t7u"), message(address: "t7s9"), message(address: "t7s9"),
            message(address: "t07s1"), message(), message(user: true)]
        GroupMessageAddressing.assignMissing(in: &messages)
        expectNoDifference(messages.map(\.shortAddress), ["t7u", "t7s9", "t7s9", "t07s1", "t7s10", "t8u"])
        for raw in ["t00u", "t01s0", "t1s00", "tbu", "t1a0", "t1ua0", "T1u", "t１u", "t1u ", "t-1u", "t1000000000u", "t999999999999999999999999999999u"] {
            #expect(!GroupMessageAddressing.isValid(raw, for: message(user: true)))
            #expect(!GroupMessageAddressing.isValid(raw, for: message()))
        }
        #expect(!GroupMessageAddressing.isValid("t1s0", for: message(user: true)))
        #expect(!GroupMessageAddressing.isValid("t1u", for: message()))
        var exhausted = [message(user: true, address: "t999999999u"), message(user: true)]
        GroupMessageAddressing.assignMissing(in: &exhausted)
        expectNoDifference(exhausted.map(\.shortAddress), ["t999999999u", nil])
    }

    @Test(arguments: [false, true])
    func shortAddressAndUUIDShareOneCanonicalReceipt(widget: Bool) async throws {
        let original = message(user: true, address: "t3u")
        var other = RoomMessage(groupID: foreign, senderID: nil, text: "PRIVATE FOREIGN")
        other.shortAddress = "t3u" // Identical spelling in another room never changes the local target.
        let probe = AddressPublicationProbe()
        let tool = AgentUserMessageTool(conversationID: group,
            publishQuestion: { _ in Issue.record("No unquoted question") },
            publishQuestionReply: { _, id in await probe.record(id) }, replyHistory: [original, other],
            publishReply: { _, _, id in await probe.record(id) }) { _ in Issue.record("No unquoted fallback") }
        let context = ToolContext(conversationID: group)
        let runtime = try await tool.runtimeContext(for: context)
        #expect(runtime.contains("\"shortAddress\":\"t3u\""))
        #expect(!runtime.contains("PRIVATE FOREIGN"))
        let schema = try #require(try JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let property = try #require((schema["properties"] as? [String: Any])?["reply_to"] as? [String: Any])
        expectNoDifference(property["minLength"] as? Int, 3)
        for address in ["t3u", original.id.uuidString, original.id.uuidString.lowercased()] {
            if widget {
                await #expect(throws: ToolTurnSuspension.self) { try await tool.execute(call(address, widget: true), context: context) }
            } else {
                #expect(!(try await tool.execute(call(address), context: context).isError))
            }
        }
        let targets = await probe.targets
        expectNoDifference(targets, [original.id])
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) { try await tool.execute(call("t3u", widget: widget), context: context) }
    }

    @Test(arguments: [false, true])
    func directoryNeverRebindsOldForeignAmbiguousOrUnlistedAddresses(widget: Bool) async throws {
        let old = message(user: true, text: "Old", address: "t0u")
        var other = RoomMessage(groupID: foreign, senderID: nil, text: "PRIVATE FOREIGN", createdAt: old.createdAt)
        other.shortAddress = "t90u"
        let recent = (1...41).map { message(user: true, text: "Recent \($0)", address: "t\($0)u") }
        let tool = AgentUserMessageTool(conversationID: group,
            publishQuestion: { _ in Issue.record("No fallback") }, publishQuestionReply: { _, _ in Issue.record("Unavailable") },
            replyHistory: [old, other] + recent, publishReply: { _, _, _ in Issue.record("Unavailable") }) { _ in Issue.record("No fallback") }
        let context = ToolContext(conversationID: group)
        let runtime = try await tool.runtimeContext(for: context)
        #expect(!runtime.contains("PRIVATE FOREIGN") && !runtime.contains(old.id.uuidString))
        #expect(runtime.contains("\"shortAddress\":\"t41u\""))
        for raw in ["t0u", "t1u", "t90u", "t42u", "t41s0", "t041u", "t41u ", "T41u", "[t41u]", "sand-msg:t41u", "https://example.com/t41u"] {
            #expect(try await tool.execute(call(raw, widget: widget), context: context).isError)
        }

        // A colliding address or ID outside the last 40 cannot be hidden by the bound.
        let duplicateAddress = message(user: true, address: "t0u")
        let duplicateID = old
        let badRole = message(address: "t8u")
        let badSyntax = message(address: "t0s00")
        let bounded = AgentUserMessageTool(conversationID: group, publishQuestion: { _ in Issue.record("No fallback") },
            publishQuestionReply: { _, _ in Issue.record("Unavailable") },
            replyHistory: [old] + recent + [duplicateID, duplicateAddress, badRole, badSyntax],
            publishReply: { _, _, _ in Issue.record("Unavailable") }) { _ in Issue.record("No fallback") }
        for raw in [old.id.uuidString, "t0u", "t8u", "t0s00"] {
            #expect(try await bounded.execute(call(raw, widget: widget), context: context).isError)
        }
    }

    @Test func storeMigrationReopenUpdatesAndSaveFailureKeepTheSameIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-address-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let file = root.appending(path: "groups.json")
        let legacy = message(user: true)
        var state = AgentPersistentState()
        state.groups = [.init(id: group, name: "Team", memberIDs: [])]
        state.roomMessages = [legacy]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let bytes = try encoder.encode(state)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("shortAddress"))
        try bytes.write(to: file)
        let groups = try GroupService(agents: agents, storeURL: file)
        let migrated = await groups.messages(groupID: group)
        expectNoDifference(migrated.first?.shortAddress, "t0u")
        expectNoDifference(migrated.first?.id, legacy.id)
        expectNoDifference(try Data(contentsOf: file), bytes) // Loading alone never rewrites the store.
        let next = try await groups.postUserMessage("Next", groupID: group)
        expectNoDifference(next.shortAddress, "t1u")
        var delegated = message(address: "t999s9")
        try await groups.recordDelegatedMessage(delegated)
        let firstPost = await groups.messages(groupID: group)
        expectNoDifference(firstPost.last?.shortAddress, "t1s0") // Caller cannot choose the address.
        delegated.text = "Updated result"
        try await groups.recordDelegatedMessage(delegated)
        let update = await groups.messages(groupID: group)
        expectNoDifference(update.last?.shortAddress, "t1s0")
        let backup = root.appending(path: "groups.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await groups.postUserMessage("Failed save", groupID: group) }
        let afterFailure = await groups.messages(groupID: group)
        expectNoDifference(afterFailure, update)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let reopened = try GroupService(agents: agents, storeURL: file)
        let restored = await reopened.messages(groupID: group)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        expectNoDifference(restored, try decoder.decode([RoomMessage].self, from: encoder.encode(update)))
        let retry = try await reopened.postUserMessage("Retry", groupID: group)
        expectNoDifference(retry.shortAddress, "t2u")
    }
}
