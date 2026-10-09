import AppKit
import SwiftUI
import Vision
import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconPersistence
@testable import Filicon

private actor AppReactionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

private actor AppReactionProbe {
    typealias Execute = @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult
    var requests: [InferenceRequest] = []
    var callbacks: [Execute] = []
    var results: [NormalizedToolResult] = []
    private var tapped = false
    func request(_ request: InferenceRequest, execute: @escaping Execute) { requests.append(request); callbacks.append(execute) }
    func result(_ result: NormalizedToolResult) { results.append(result) }
    func claimTap() -> Bool { guard !tapped else { return false }; tapped = true; return true }
}

private struct AppReactionProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "group-reaction-fixture", displayName: "Group reaction fixture", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @escaping AppReactionProbe.Execute) async throws -> Void
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping AppReactionProbe.Execute) -> AsyncThrowingStream<InferenceEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, executeTool)
                    continuation.yield(.textDelta("PRIVATE_REACTION_DRAFT"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Actual app native group message reactions", .serialized, .timeLimit(.minutes(1)))
@MainActor struct GroupReactionAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let member: AgentProfile
        let peer: AgentProfile
        let room: AgentGroup
        let foreign: AgentGroup
        let peerMessage: RoomMessage
        let foreignMessage: RoomMessage
        let probe: AppReactionProbe
        let gate: AppReactionGate?
    }

    private func fixture(target: String = "user", remove: Bool = false, held: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reaction-app-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let member = try await agents.create(name: "Engineer", providerID: "group-reaction-fixture", modelID: "test", at: Date(timeIntervalSince1970: 1_000))
        let peer = try await agents.create(name: "Designer", providerID: "group-reaction-fixture", modelID: "test", at: Date(timeIntervalSince1970: 1_000))
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let room = try await groups.create(name: "Reaction room", memberIDs: [member.id, peer.id])
        let foreign = try await groups.create(name: "Private foreign room", memberIDs: [peer.id])
        let peerDraft = RoomMessage(groupID: room.id, senderID: peer.id, text: "A teammate result", createdAt: Date(timeIntervalSince1970: 1_001))
        let foreignDraft = RoomMessage(groupID: foreign.id, senderID: peer.id, text: "PRIVATE_FOREIGN_ROOM", createdAt: peerDraft.createdAt)
        try await groups.recordDelegatedMessage(peerDraft); try await groups.recordDelegatedMessage(foreignDraft)
        let peerMessage = try #require(await groups.messages(groupID: room.id).first)
        let foreignMessage = try #require(await groups.messages(groupID: foreign.id).first)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.save([Conversation(title: "Unrelated private chat", messages: [.init(role: .user, text: "PRIVATE_DM_HISTORY", createdAt: peerDraft.createdAt)])])
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let probe = AppReactionProbe(), gate = held ? AppReactionGate() : nil
        await model.registry.register(AppReactionProvider { request, execute in
            await probe.request(request, execute: execute)
            guard request.messages.first?.text.contains("identity agent:\(member.id.uuidString)") == true else { return }
            guard await probe.claimTap() else { return }
            await gate?.wait()
            let address = target == "peer" ? try #require(peerMessage.shortAddress) : "t0u"
            let call = try NormalizedToolCall(id: "tap", name: "ReactToMessage", argumentsJSON:
                JSONEncoder().encode(["message_address": address, "emoji": "👍"]))
            let result = try await execute(call); await probe.result(result)
            if !held {
                #expect(!result.isError)
                await #expect(throws: ToolLoopError.duplicateCallID(call.id)) { try await execute(call) }
                if remove {
                    let removed = try await execute(.init(id: "take-back", name: "ReactToMessage", argumentsJSON: call.argumentsJSON))
                    #expect(!removed.isError)
                }
            }
        })
        await model.reloadWorkspaceData()
        return .init(root: root, model: model, member: member, peer: peer, room: room, foreign: foreign,
            peerMessage: peerMessage, foreignMessage: foreignMessage, probe: probe, gate: gate)
    }

    private struct Snapshot: Equatable {
        let nonReactionFields: Data
        let roomMessages: [RoomMessage]
        var reactions: [MessageReaction]
    }

    private func state(_ root: URL) throws -> Snapshot {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let bytes = try Data(contentsOf: root.appending(path: "groups.json"))
        let native = try decoder.decode(AgentPersistentState.self, from: bytes)
        var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "reactions")
        return try .init(nonReactionFields: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            roomMessages: native.roomMessages, reactions: native.reactions)
    }

    private func eventually(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try #require(await predicate())
    }

    @Test(arguments: ["user", "peer", "take-back"])
    func bareTapUsesRealTurnPersistsCorrectMemberAndNeverCopiesPrivateHistory(target: String) async throws {
        let f = try await fixture(target: target, remove: target == "take-back")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let privateStore = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let privateHistory = try await privateStore.load()
        await f.model.sendGroupMessage(groupID: f.room.id, text: "Good news")
        #expect(f.model.errorMessage == nil)
        let history = try #require(f.model.groupMessages[f.room.id])
        let user = try #require(history.first { $0.senderID == nil })
        let expected: [MessageReaction] = target == "take-back" ? [] : [.init(
            messageID: target == "peer" ? f.peerMessage.id : user.id, actorID: f.member.id, emoji: "👍")]
        expectNoDifference(f.model.groupReactions[f.room.id], expected)
        let saved = try state(f.root)
        expectNoDifference(saved.reactions, expected)
        expectNoDifference(saved.roomMessages.first { $0.id == f.foreignMessage.id }, f.foreignMessage)
        #expect(!history.contains { $0.text.contains("PRIVATE_") })
        #expect(!history.contains { $0.senderID == f.member.id && !$0.text.isEmpty })
        #expect(!history.contains { $0.senderID == f.member.id && $0.memberOutcome != nil })
        #expect(history.flatMap(\.toolActivities).contains { $0.name == "ReactToMessage" && $0.status == .succeeded })
        let requests = await f.probe.requests
        for request in requests {
            #expect(request.tools.contains { $0.name == "ReactToMessage" })
            #expect(!request.messages.contains { $0.text.contains("PRIVATE_FOREIGN_ROOM") || $0.text.contains("PRIVATE_DM_HISTORY") })
        }
        let savedPrivateHistory = try await privateStore.load()
        expectNoDifference(savedPrivateHistory, privateHistory)
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.groupReactions[f.room.id], expected)
        expectNoDifference(restored.groupMessages[f.foreign.id], [f.foreignMessage])
        let callback = try #require(await f.probe.callbacks.first)
        let bytes = try Data(contentsOf: f.root.appending(path: "groups.json"))
        do {
            let late = try await callback(.init(id: "late", name: "ReactToMessage", argumentsJSON: Data(#"{"message_address":"t0u","emoji":"❤️"}"#.utf8)))
            #expect(late.isError)
        } catch is CancellationError { }
        expectNoDifference(try Data(contentsOf: f.root.appending(path: "groups.json")), bytes)
    }

    @Test func humanReactionIsNotAttributedToFirstMemberAndCanBeRemovedWithoutChangingOtherState() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let human = MessageReaction(messageID: f.peerMessage.id, actorID: GroupService.localUserReactionActorID, emoji: "❤️")
        let original = try state(f.root)
        var saved = original
        await expectDifference(saved) {
            await f.model.toggleGroupReaction(groupID: f.room.id, messageID: f.peerMessage.id, emoji: "❤️")
            saved = try state(f.root)
        } changes: { $0.reactions.append(human) }
        #expect(human.actorID != f.member.id)
        expectNoDifference(f.model.groupReactions[f.room.id], [human])
        let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.groupReactions[f.room.id], [human])
        await restored.toggleGroupReaction(groupID: f.room.id, messageID: f.peerMessage.id, emoji: "❤️")
        expectNoDifference(try state(f.root), original)
        expectNoDifference(restored.groupReactions[f.room.id], [])
        await restored.toggleGroupReaction(groupID: f.room.id, messageID: f.foreignMessage.id, emoji: "👍")
        expectNoDifference(try state(f.root), original)
        #expect(restored.errorMessage != nil)
    }

    @Test func failedHumanReactionSaveDoesNotChangeNativeStateOrPublishFalseUIReceipt() async throws {
        let f = try await fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try state(f.root)
        let file = f.root.appending(path: "groups.json"), backup = f.root.appending(path: "owned-reaction-backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await f.model.toggleGroupReaction(groupID: f.room.id, messageID: f.peerMessage.id, emoji: "❤️")
        #expect(f.model.errorMessage != nil)
        expectNoDifference(f.model.groupReactions[f.room.id], [])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        expectNoDifference(try state(f.root), original)
        await f.model.reloadWorkspaceData()
        expectNoDifference(f.model.groupReactions[f.room.id], [])
        await f.model.toggleGroupReaction(groupID: f.room.id, messageID: f.peerMessage.id, emoji: "❤️")
        var expected = original
        expected.reactions = [.init(messageID: f.peerMessage.id, actorID: GroupService.localUserReactionActorID, emoji: "❤️")]
        expectNoDifference(try state(f.root), expected)
        expectNoDifference(f.model.groupReactions[f.room.id], expected.reactions)
    }

    @Test func ambiguousCrossRoomIDsCannotDisplayOrReceiveHumanOrMemberReactions() async throws {
        let f = try await fixture(target: "peer")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appending(path: "groups.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var native = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: file))
        let index = try #require(native.roomMessages.firstIndex { $0.id == f.foreignMessage.id })
        var damaged = RoomMessage(id: f.peerMessage.id, groupID: f.foreign.id, senderID: f.foreignMessage.senderID,
            text: f.foreignMessage.text, createdAt: f.foreignMessage.createdAt)
        damaged.shortAddress = f.foreignMessage.shortAddress
        native.roomMessages[index] = damaged
        let oldReaction = MessageReaction(messageID: f.peerMessage.id, actorID: f.peer.id, emoji: "🎉")
        native.reactions = [oldReaction]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(native).write(to: file, options: .atomic)
        let model = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
        await model.registry.register(AppReactionProvider { request, execute in
            guard request.messages.first?.text.contains("identity agent:\(f.member.id.uuidString)") == true else { return }
            let call = try NormalizedToolCall(id: "ambiguous", name: "ReactToMessage", argumentsJSON:
                JSONEncoder().encode(["message_address": try #require(f.peerMessage.shortAddress), "emoji": "👍"]))
            await #expect(throws: AgentServiceError.invalidReaction) { try await execute(call) }
        })
        await model.reloadWorkspaceData()
        expectNoDifference(model.groupReactions[f.room.id], [])
        expectNoDifference(model.groupReactions[f.foreign.id], [])
        let before = try state(f.root)
        await model.toggleGroupReaction(groupID: f.room.id, messageID: f.peerMessage.id, emoji: "❤️")
        #expect(model.errorMessage != nil)
        expectNoDifference(try state(f.root), before)
        await model.sendGroupMessage(groupID: f.room.id, text: "Good news")
        expectNoDifference(try state(f.root).reactions, before.reactions)
        expectNoDifference(model.groupMessages[f.foreign.id], [damaged])
        expectNoDifference(model.groupReactions[f.room.id], [])
        expectNoDifference(model.groupReactions[f.foreign.id], [])
    }

    @Test(arguments: ["stop", "account restore", "members restore", "persona restore"])
    func revokedRealMemberCallbackCannotApplyAndAccountClearsReactionProjection(boundary: String) async throws {
        let f = try await fixture(held: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let pending = Task { await f.model.sendGroupMessage(groupID: f.room.id, text: "Good news") }
        do {
            try await eventually { await f.gate?.waiting == true }
            await f.model.toggleGroupReaction(groupID: f.room.id, messageID: f.peerMessage.id, emoji: "❤️")
            #expect(f.model.groupReactions[f.room.id]?.count == 1)
            switch boundary {
            case "stop": await f.model.stopGroup(id: f.room.id)
            case "account restore":
                await f.model.cancelAutoReviewApprovals(nextAccountID: "other-fixture"); f.model.settings.accountScope = "other-fixture"
                expectNoDifference(f.model.groupReactions, [:])
                await f.model.cancelAutoReviewApprovals(nextAccountID: "local"); f.model.settings.accountScope = "local"
            case "members restore":
                await f.model.updateGroupMembers(groupID: f.room.id, memberIDs: [f.peer.id])
                await f.model.updateGroupMembers(groupID: f.room.id, memberIDs: f.room.memberIDs)
            default:
                var changed = f.member; changed.instructions = "CHANGED_PERSONA"
                #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(f.member))
            }
            let before = try state(f.root).reactions
            await f.gate?.open(); await pending.value
            expectNoDifference(try state(f.root).reactions, before)
            let human = MessageReaction(messageID: f.peerMessage.id, actorID: GroupService.localUserReactionActorID, emoji: "❤️")
            expectNoDifference(before, [human])
            if boundary == "account restore" { expectNoDifference(f.model.groupReactions, [:]) }
        } catch {
            pending.cancel(); await f.model.stopGroup(id: f.room.id); await f.gate?.open(); await pending.value
            throw error
        }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func directReactionAuthorsRenderInActualTranscriptWithoutHover(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-reaction-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let memberID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let messageID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let chatID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        let member = AgentProfile(id: memberID, name: "Designer with a longer public name", providerID: "fixture", modelID: "test")
        model.agents = [member]
        let message = ChatMessage(id: messageID, role: .user,
            text: "Acknowledged result", createdAt: Date(timeIntervalSince1970: 1_000),
            reactions: [.init(emoji: "👍", actorID: "agent:\(member.id.uuidString)"),
                .init(emoji: "🎉", actorID: "agent:00000000-0000-0000-0000-000000000003"),
                .init(emoji: "❤️", actorID: "local-user")])
        let chat = Conversation(id: chatID, messages: [message], updatedAt: message.createdAt)
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for dark in [false, true] {
            for width in [320.0, 560.0] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: TranscriptMessageView(message: message, conversation: chat,
                        onJumpToMessage: { _ in Issue.record("Rendering must not navigate") })
                        .padding(16).frame(width: width).background(FiliconTheme.canvas)
                        .environmentObject(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    expectNoDifference(size.width, width)
                    #expect(size.height > 80 && size.height < 500)
                    host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
                    let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                    #expect(text.contains("Designer"), "Direct reaction attribution must be visible: \(text)")
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: output.appending(path: "direct-reactions-\(language)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                    }
                }
            }
        }
        expectNoDifference(model.conversations, [])
        expectNoDifference(chat.messages, [message])
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func visibleReactionPillsRenderWithoutHoverInNarrowAndWideLightAndDarkBubbles(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reaction-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let member = AgentProfile(name: "Engineer", providerID: "fixture", modelID: "test")
        let peer = AgentProfile(name: "Designer with a longer public name", providerID: "fixture", modelID: "test")
        let message = RoomMessage(groupID: UUID(), senderID: member.id, text: "Acknowledged result", createdAt: Date(timeIntervalSince1970: 1_000))
        let reactions = [MessageReaction(messageID: message.id, actorID: peer.id, emoji: "👍"),
            MessageReaction(messageID: message.id, actorID: member.id, emoji: "🎉"),
            MessageReaction(messageID: message.id, actorID: GroupService.localUserReactionActorID, emoji: "❤️")]
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for dark in [false, true] {
            for width in [320.0, 560.0] {
                try await withUIRenderTurn(language: language) {
                    if language != "en" {
                        #expect(l10n("You") != "You"); #expect(l10n("Reaction") != "Reaction")
                    }
                    let host = NSHostingView(rootView: GroupMessageBubble(message: message, agent: member,
                        reactions: reactions, reactionAuthors: [member.id: member.name, peer.id: peer.name],
                        onRemoveReaction: { _ in Issue.record("Rendering must not toggle") }, onReaction: { Issue.record("Rendering must not toggle") })
                        .padding(16).frame(width: width).background(FiliconTheme.canvas)
                        .environmentObject(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    expectNoDifference(size.width, width)
                    #expect(size.height > 80 && size.height < 360)
                    host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate
                    try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
                    let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                    #expect(text.contains("Designer"), "Reaction attribution must be visible without hover: \(text)")
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: output.appending(path: "group-reactions-\(language)-\(dark ? "dark" : "light")-\(Int(width)).png"))
                    }
                }
            }
        }
        expectNoDifference(reactions.count, 3)
    }
}
