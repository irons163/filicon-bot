import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
import FiliconAppServices
import FiliconDomain

private func reactionID(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, value))
}

private actor ReactionToolProbe {
    var reactions: [MessageReaction] = []
    var calls: [MessageReaction] = []
    func toggle(_ id: UUID, emoji: String) -> Bool {
        let reaction = MessageReaction(messageID: id, actorID: reactionID(2), emoji: emoji)
        calls.append(reaction)
        if let index = reactions.firstIndex(of: reaction) { reactions.remove(at: index); return false }
        reactions.append(reaction)
        return true
    }
}

private actor ReactionValidationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@Suite("Native group reaction directory and tool", .timeLimit(.minutes(1)))
struct GroupReactionToolTests {
    private let group = reactionID(1), actor = reactionID(2), peer = reactionID(3)
    private let date = Date(timeIntervalSince1970: 1_000)

    private func message(_ id: UInt8, sender: UUID? = nil, address: String, text: String = "Visible message") -> RoomMessage {
        var message = RoomMessage(id: reactionID(id), groupID: group, senderID: sender, text: text, createdAt: date)
        message.shortAddress = address
        return message
    }

    private func directory() -> GroupReactionDirectory {
        .init(history: [message(10, address: "t0u"), message(11, sender: peer, address: "t0s0"),
            message(12, sender: actor, address: "t0s1")], groupID: group, actorID: actor)
    }

    private func call(_ id: ToolCallID = "tap", address: String = "t0u", emoji: String = "👍") throws -> NormalizedToolCall {
        try .init(id: id, name: "ReactToMessage", argumentsJSON: JSONEncoder().encode(["message_address": address, "emoji": emoji]))
    }

    @Test(arguments: [false, true])
    func directDirectoryIsBoundToOriginalChatAndCachesToggleReceipt(foreignContext: Bool) async throws {
        var chat = Conversation(id: group, title: "Direct fixture", messages: [
            .init(id: reactionID(10), role: .user, text: "Human", createdAt: date),
            .init(id: reactionID(11), role: .assistant, text: "Assistant", createdAt: date)])
        DirectMessageAddressing.assignMissing(in: &chat)
        let context = ToolContext(conversationID: foreignContext ? peer : group, runID: reactionID(7))
        let probe = ReactionToolProbe()
        let tool = AgentMessageReactionTool(context: context,
            directory: DirectReactionDirectory(conversation: chat, historyComplete: true),
            validate: {}, react: { await probe.toggle($0, emoji: $1) })
        let description = try #require(tool.descriptor.description)
        #expect(description.contains("direct conversation"))
        #expect(!description.contains("other member"))
        let first = try await tool.execute(call(), context: context)
        if foreignContext {
            #expect(first.isError)
            await #expect(throws: CancellationError.self) { try await tool.runtimeContext(for: context) }
            let calls = await probe.calls
            expectNoDifference(calls, [])
            return
        }
        expectNoDifference(first, .init(callID: "tap", content: [.text("Added 👍 on t0u.")]))
        let replay = try await tool.execute(call(), context: context)
        expectNoDifference(replay, first)
        #expect(try await tool.execute(call("assistant", address: "t0s0"), context: context).isError)
        let removed = try await tool.execute(call("remove"), context: context)
        expectNoDifference(removed, .init(callID: "remove", content: [.text("Removed 👍 on t0u.")]))
        let calls = await probe.calls, reactions = await probe.reactions
        let expected = MessageReaction(messageID: reactionID(10), actorID: actor, emoji: "👍")
        expectNoDifference(calls, [expected, expected]); expectNoDifference(reactions, [])
        await tool.close()
        await #expect(throws: CancellationError.self) { try await tool.execute(call("closed"), context: context) }
    }

    @Test func directoryContainsOnlyVisibleNativeHumanAndOtherMemberAddresses() throws {
        let human = message(10, address: "t0u", text: String(repeating: "a", count: 500))
        let teammate = message(11, sender: peer, address: "t0s0")
        let own = message(12, sender: actor, address: "t0s1")
        var foreign = RoomMessage(id: reactionID(13), groupID: reactionID(4), senderID: nil, text: "PRIVATE_OTHER_ROOM", createdAt: date)
        foreign.shortAddress = "t1u"
        var status = message(14, sender: peer, address: "t0s2", text: "Host failure notice")
        status.memberOutcome = .failed
        var wake = message(15, address: "t2u", text: "Host routine seed")
        wake.routineWake = .init(automationID: reactionID(5), runID: reactionID(6), name: "Wake", containsUntrustedEvents: false)
        let history = [human, teammate, own, foreign, status, wake,
            message(16, sender: peer, address: "t0s3", text: " "), message(17, sender: peer, address: "t5u"),
            message(18, address: "t01u")]
        let directory = GroupReactionDirectory(history: history, groupID: group, actorID: actor)
        struct Entry: Decodable, Equatable { let message_address: String; let sender: String; let excerpt: String }
        let encoded = try JSONEncoder().encode(directory.entries)
        expectNoDifference(try JSONDecoder().decode([Entry].self, from: encoded), [
            Entry(message_address: "t0u", sender: "user", excerpt: String(repeating: "a", count: 240)),
            Entry(message_address: "t0s0", sender: "agent:\(peer.uuidString)", excerpt: teammate.text)
        ])
        let objects = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        for object in objects { expectNoDifference(Set(object.keys), ["message_address", "sender", "excerpt"]) }
        expectNoDifference(directory.messageID(for: "t0u"), human.id)
        expectNoDifference(directory.messageID(for: human.id.uuidString), nil)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("PRIVATE_OTHER_ROOM"))
        expectNoDifference(history, [human, teammate, own, foreign, status, wake,
            message(16, sender: peer, address: "t0s3", text: " "), message(17, sender: peer, address: "t5u"),
            message(18, address: "t01u")])
    }

    @Test(arguments: [false, true])
    func fullNativeLogRejectsCollisionsHiddenOutsideFortyMessageWindow(duplicateID: Bool) {
        let old = message(10, address: "t0u")
        let recent = (20..<61).map { message(UInt8($0), address: "t\($0)u") }
        let collision = duplicateID ? old : message(70, address: "t0u")
        let value = GroupReactionDirectory(history: [old] + recent + [collision], groupID: group, actorID: actor)
        expectNoDifference(value.messageID(for: "t0u"), nil)
        expectNoDifference(value.messageID(for: "t20u"), nil)
        expectNoDifference(value.messageID(for: "t60u"), reactionID(60))
        #expect(!value.contains(old.id))
    }

    @Test func fullNativeLogRejectsAnIDAlsoStoredInAnotherRoom() {
        let target = message(10, address: "t0u")
        var foreign = RoomMessage(id: target.id, groupID: reactionID(4), senderID: peer,
            text: "PRIVATE_OTHER_ROOM", createdAt: date)
        foreign.shortAddress = "t0s0"
        let value = GroupReactionDirectory(history: [target, foreign], groupID: group, actorID: actor)
        expectNoDifference(value.entries, [])
        expectNoDifference(value.messageID(for: "t0u"), nil)
    }

    @Test func repeatedCallReceiptCannotToggleTwiceAndNewCallCanTakeBackOwnReaction() async throws {
        let context = ToolContext(conversationID: group, runID: reactionID(7)), probe = ReactionToolProbe()
        let tool = AgentMessageReactionTool(context: context, directory: directory(), validate: {}, react: { await probe.toggle($0, emoji: $1) })
        let first = try await tool.execute(call(), context: context)
        let saved = [MessageReaction(messageID: reactionID(10), actorID: actor, emoji: "👍")]
        expectNoDifference(first, .init(callID: "tap", content: [.text("Added 👍 on t0u.")]))
        let repeated = try await tool.execute(call(emoji: " 👍 "), context: context)
        expectNoDifference(repeated, first)
        #expect(try await tool.execute(call(emoji: "❤️"), context: context).isError)
        let before = await probe.reactions, calls = await probe.calls
        expectNoDifference(before, saved); expectNoDifference(calls, saved)
        let removed = try await tool.execute(call("remove"), context: context)
        expectNoDifference(removed, .init(callID: "remove", content: [.text("Removed 👍 on t0u.")]))
        let after = await probe.reactions, allCalls = await probe.calls
        expectNoDifference(after, []); expectNoDifference(allCalls, saved + saved)
        let replay = try await tool.execute(call("remove"), context: context), replayCalls = await probe.calls
        expectNoDifference(replay, removed); expectNoDifference(replayCalls, saved + saved)
    }

    @Test(arguments: ["👍", "❤️", "😂", "🎉", "👍🏽", "👨‍👩‍👧‍👦", "🇹🇼", "1️⃣"])
    func commonSingleEmojiIncludingJoinedAndModifiedFormsIsAccepted(emoji: String) async throws {
        let context = ToolContext(conversationID: group), probe = ReactionToolProbe()
        let tool = AgentMessageReactionTool(context: context, directory: directory(), validate: {}, react: { await probe.toggle($0, emoji: $1) })
        #expect(!(try await tool.execute(call(address: "t0s0", emoji: emoji), context: context).isError))
        let reactions = await probe.reactions
        expectNoDifference(reactions, [.init(messageID: reactionID(11), actorID: actor, emoji: emoji)])
    }

    @Test func unlistedAddressesUnsupportedEmojiAndIdentityFieldsNeverApply() async throws {
        let context = ToolContext(conversationID: group), probe = ReactionToolProbe()
        let tool = AgentMessageReactionTool(context: context, directory: directory(), validate: {}, react: { await probe.toggle($0, emoji: $1) })
        for address in ["t0s1", "t1u", reactionID(10).uuidString, "[t0u]", "t00u", "T0u", "sand-msg:t0u", "https://example.com/t0u"] {
            #expect(try await tool.execute(call(address: address), context: context).isError)
        }
        for emoji in ["", " ", "hello", "1", "👍👍", String(repeating: "👍", count: 9)] {
            #expect(try await tool.execute(call(emoji: emoji), context: context).isError)
        }
        for payload in [#"{"message_address":"t0u","emoji":"👍","actorID":"someone"}"#,
            #"{"message_address":"t0u","emoji":"👍","groupID":"other"}"#,
            #"{"message_address":"t0u","emoji":null}"#, #"{"message_address":"t0u","emoji":1}"#,
            #"{"message_address":1,"emoji":"👍"}"#, #"{"message_address":"t0u"}"#] {
            #expect(try await tool.execute(.init(id: "bad", name: "ReactToMessage", argumentsJSON: Data(payload.utf8)), context: context).isError)
        }
        let wrongName = try NormalizedToolCall(id: "wrong", name: "SendMessage", argumentsJSON: call().argumentsJSON)
        #expect(try await tool.execute(wrongName, context: context).isError)
        let calls = await probe.calls, reactions = await probe.reactions
        expectNoDifference(calls, []); expectNoDifference(reactions, [])
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        expectNoDifference(Set(try #require(schema["properties"] as? [String: Any]).keys), ["message_address", "emoji"])
        expectNoDifference(schema["additionalProperties"] as? Bool, false)
    }

    @Test(arguments: ["scope", "run", "closed", "revoked", "restored"])
    func oldContextAndAccountABARejectEvenCachedReceipts(boundary: String) async throws {
        let scope = AgentWorkflowExecutionScope(), lease = try scope.capture(), probe = ReactionToolProbe()
        let original = ToolContext(conversationID: group, runID: reactionID(7))
        let tool = AgentMessageReactionTool(context: original, directory: directory(), validate: { try lease.check() },
            react: { await probe.toggle($0, emoji: $1) })
        _ = try await tool.execute(call(), context: original)
        let before = await probe.reactions, calls = await probe.calls
        var context = original
        switch boundary {
        case "scope": context = .init(conversationID: reactionID(4), runID: original.runID)
        case "run": context = .init(conversationID: group, runID: reactionID(8))
        case "closed": await tool.close()
        default: scope.suspend(); if boundary == "restored" { scope.resume() }
        }
        await #expect(throws: CancellationError.self) { try await tool.execute(call(), context: context) }
        await #expect(throws: CancellationError.self) { try await tool.runtimeContext(for: context) }
        let after = await probe.reactions, afterCalls = await probe.calls
        expectNoDifference(after, before); expectNoDifference(afterCalls, calls)
    }

    @Test(arguments: [false, true])
    func closingWhileValidationIsSuspendedDoesNotExposeDirectoryOrApply(runtimeContext: Bool) async throws {
        let context = ToolContext(conversationID: group), probe = ReactionToolProbe(), gate = ReactionValidationGate()
        let tool = AgentMessageReactionTool(context: context, directory: directory(), validate: { await gate.wait() },
            react: { await probe.toggle($0, emoji: $1) })
        let task = Task {
            if runtimeContext { _ = try await tool.runtimeContext(for: context) }
            else { _ = try await tool.execute(call(), context: context) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.waiting), ContinuousClock.now < deadline { await Task.yield() }
        let wasWaiting = await gate.waiting
        await tool.close(); await gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(wasWaiting)
        let calls = await probe.calls
        expectNoDifference(calls, [])
    }

    @Test func failedEffectHasNoSuccessReceiptAndReactionBudgetIsBounded() async throws {
        struct SaveFailure: Error {}
        let context = ToolContext(conversationID: group), probe = ReactionToolProbe()
        let failed = AgentMessageReactionTool(context: context, directory: directory(), validate: {}, react: { _, _ in throw SaveFailure() })
        await #expect(throws: SaveFailure.self) { try await failed.execute(call(), context: context) }
        await #expect(throws: SaveFailure.self) { try await failed.execute(call(), context: context) }
        let tool = AgentMessageReactionTool(context: context, directory: directory(), validate: {}, react: { await probe.toggle($0, emoji: $1) })
        for index in 0..<8 {
            #expect(!(try await tool.execute(call(ToolCallID(rawValue: "tap-\(index)")), context: context).isError))
        }
        #expect(try await tool.execute(call("overflow"), context: context).isError)
        let calls = await probe.calls, reactions = await probe.reactions
        expectNoDifference(calls, Array(repeating: MessageReaction(messageID: reactionID(10), actorID: actor, emoji: "👍"), count: 8))
        expectNoDifference(reactions, [])
    }
}
