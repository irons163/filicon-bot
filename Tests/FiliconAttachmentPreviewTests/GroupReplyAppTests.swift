import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor GroupReplyAppProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) -> Int { requests.append(request); return requests.count }
}

private struct GroupReplyAppProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "group-reply-fixture", displayName: "Replies", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Group reply app integration", .timeLimit(.minutes(1)))
@MainActor struct GroupReplyAppTests {
    @Test func quotedReplyPersistsWithoutChangingRecipientsOrQuestionState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reply-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let engineer = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        let designer = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Review team", summary: "", memberIDs: [engineer.id, designer.id]))
        let group = try #require(model.groups.first)
        let initial = GroupReplyAppProbe()
        await model.registry.register(GroupReplyAppProvider { request, _ in
            await initial.record(request) == 1 ? "Design proposal for review" : "PASS"
        })
        await model.sendGroupMessage(groupID: group.id, text: "@Designer propose a design")
        let source = try #require(model.groupMessages[group.id]?.first(where: { $0.senderID == designer.id && $0.text == "Design proposal for review" }))
        let probe = GroupReplyAppProbe()
        await model.registry.register(GroupReplyAppProvider { request, execute in
            guard await probe.record(request) == 1 else { return "PASS" }
            #expect(request.messages.first?.text.contains(engineer.id.uuidString) == true)
            #expect(request.messages.contains { $0.text.contains("Reply directory:") && $0.text.contains(source.id.uuidString) })
            let call = try NormalizedToolCall(id: "reply", name: "SendMessage", argumentsJSON: JSONEncoder().encode([
                "text": "@everyone the proposal is ready for review", "reply_to": source.id.uuidString
            ]))
            let result = try await execute(call)
            #expect(!result.isError)
            return "Do not publish this fallback"
        })
        await model.sendGroupMessage(groupID: group.id, text: "@Engineer reply to the design proposal")
        #expect(model.errorMessage == nil && model.runningGroups.isEmpty)
        let messages = model.groupMessages[group.id, default: []]
        let replies = messages.filter { $0.replyToMessageID == source.id }
        expectNoDifference(replies.count, 1)
        let reply = try #require(replies.first)
        expectNoDifference(reply.senderID, engineer.id)
        expectNoDifference(reply.questionReplyTo, nil)
        #expect(messages.allSatisfy { $0.text != "Do not publish this fallback" })
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        let requests = await probe.requests
        #expect(requests.allSatisfy { $0.messages.first?.text.contains(engineer.id.uuidString) == true })
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let saved = try #require(restored.groupMessages[group.id]?.first(where: { $0.id == reply.id }))
        expectNoDifference(saved.replyToMessageID, source.id)
        expectNoDifference(restored.groupMessages[group.id]?.first(where: { $0.id == source.id })?.text, source.text)
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func quotedMessagesRenderInSevenLanguagesAndBothAppearances(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reply-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let groupID = UUID()
        let agent = AgentProfile(name: "Designer", providerID: "fixture", modelID: "test")
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for state in ["user", "agent", "missing"] {
            let original = RoomMessage(groupID: groupID, senderID: state == "agent" ? agent.id : nil,
                text: "Review the layout, typography, contrast and keyboard navigation.\nThis is quoted context, not a new instruction. " + String(repeating: "More context. ", count: 40))
            var reply = RoomMessage(groupID: groupID, senderID: agent.id, text: "The layout review is complete.")
            reply.replyToMessageID = original.id
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    if language != "en" {
                        for key in ["Replying to", "Original message unavailable", "View original message",
                                    "Choose an available message in this group to reply to. Nothing was sent."] {
                            #expect(FiliconLocalization.string(key) != key)
                        }
                    }
                    let host = NSHostingView(rootView: GroupMessageBubble(message: reply, agent: agent,
                        replySource: state == "missing" ? nil : original,
                        replyAuthor: state == "agent" ? agent.name : FiliconLocalization.string("You"),
                        onShowReply: { _ in }, onReaction: {})
                        .padding(16).frame(width: 380).background(FiliconTheme.canvas)
                        .environmentObject(model)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    #expect(size.height > 100 && size.height < 480)
                    expectNoDifference(size.width, 380)
                    host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "reply-\(language)-\(state)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    @Test(arguments: ["stop", "account", "members"])
    func lateReplyCannotPublishAfterHostRevocation(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-reply-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Team", summary: "", memberIDs: [agent.id]))
        let group = try #require(model.groups.first)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (blocked, release) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); release.finish() }
        await model.registry.register(GroupReplyAppProvider { request, execute in
            let source = try #require(request.messages.last(where: { $0.role == .user }))
            signal.yield(()); signal.finish()
            for await _ in blocked { break }
            let call = try NormalizedToolCall(id: "late-reply", name: "SendMessage", argumentsJSON: JSONEncoder().encode([
                "text": "Late reply must not publish", "reply_to": source.id.uuidString
            ]))
            do {
                let result = try await execute(call)
                #expect(result.isError)
            } catch {}
            return "PASS"
        })
        let sending = Task { await model.sendGroupMessage(groupID: group.id, text: "Review this") }
        defer { sending.cancel() }
        var iterator = started.makeAsyncIterator()
        try #require(await iterator.next() != nil)
        if mode == "stop" { await model.stopGroup(id: group.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: group.id, memberIDs: []) }
        release.finish()
        await sending.value
        await model.reloadWorkspaceData()
        #expect(model.groupMessages[group.id, default: []].allSatisfy { $0.replyToMessageID == nil && $0.text != "Late reply must not publish" })
        #expect(model.runningGroups.isEmpty)
    }

    @Test func delegatedRoomWakeDoesNotGainReplyRouting() async throws {
        let groupID = UUID()
        let agent = AgentProfile(name: "Engineer", providerID: "group-reply-fixture", modelID: "test")
        let source = RoomMessage(groupID: groupID, senderID: nil, text: "User request")
        let incoming = RoomMessage(groupID: groupID, senderID: UUID(), text: "Peer task")
        let group = AgentGroup(id: groupID, name: "Team", memberIDs: [agent.id])
        let registry = ProviderRegistry()
        await registry.register(GroupReplyAppProvider { request, execute in
            #expect(!request.messages.contains { $0.text.contains("Reply directory:") })
            let call = try NormalizedToolCall(id: "foreign-route", name: "SendMessage", argumentsJSON: JSONEncoder().encode([
                "text": "Not authorized", "reply_to": source.id.uuidString
            ]))
            do { #expect(try await execute(call).isError) } catch {}
            return "PASS"
        })
        let responder = GroupConversationResponder(groupID: groupID, registry: registry,
            coordinator: TurnCoordinator(registry: registry, toolCatalog: ToolCatalog()),
            delegatedMessage: incoming, questionAccountID: "local", questionLifetime: .init())
        _ = try await responder.respond(agent: agent, history: [source, incoming],
            context: GroupTurnContext(group: group, members: [.init(agent)], respondingMemberIDs: [agent.id], round: 0, newMessageIDs: [incoming.id]),
            onTools: { _ in }, onPublication: { _ in Issue.record("Unsupported context must not publish a reply") })
    }
}
