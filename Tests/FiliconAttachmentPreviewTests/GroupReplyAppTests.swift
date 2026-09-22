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
    func models() async throws -> [AIModel] { [.init(id: "test", capabilities: .init(inputModalities: [.text, .image]))] }
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
    @Test func inlineReferencePublishesAndReopensWithoutQuotingRoutingOrApproval() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-inline-app-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let engineer = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        let designer = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Team", summary: "", memberIDs: [engineer.id, designer.id]))
        let group = try #require(model.groups.first)
        await model.registry.register(GroupReplyAppProvider { _, _ in "Design proposal" })
        await model.sendGroupMessage(groupID: group.id, text: "@Designer propose a layout")
        let original = try #require(model.groupMessages[group.id]?.first { $0.senderID == designer.id && $0.text == "Design proposal" })
        let address = try #require(original.shortAddress)
        let text = "Review [the design proposal](sand-msg:\(address)) before implementation."
        let probe = GroupReplyAppProbe()
        await model.registry.register(GroupReplyAppProvider { request, execute in
            guard await probe.record(request) == 1 else { return "PASS" }
            #expect(request.messages.contains { $0.text.contains("[descriptive label](sand-msg:<shortAddress>)") })
            let call = try NormalizedToolCall(id: "inline-reference", name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": text]))
            #expect(try await !execute(call).isError)
            return "Do not repeat this final text"
        })
        await model.sendGroupMessage(groupID: group.id, text: "@Engineer link the proposal")
        let response = try #require(model.groupMessages[group.id]?.first { $0.text == text })
        expectNoDifference(response.senderID, engineer.id)
        #expect(response.replyToMessageID == nil && response.questionReplyTo == nil && response.question == nil)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty && model.errorMessage == nil)
        #expect(await probe.requests.allSatisfy { $0.messages.first?.text.contains(engineer.id.uuidString) == true })
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let history = restored.groupMessages[group.id, default: []]
        expectNoDifference(history.first { $0.id == response.id }?.text, text)
        #expect(history.allSatisfy { $0.text != "Do not repeat this final text" })
        let directory = GroupMessageReferenceDirectory(history: history, groupID: group.id)
        expectNoDifference(directory.target(for: URL(string: "sand-msg:\(address)")!, from: response.id), original.id)
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func inlineReferencesRenderInSevenLanguagesAndBothAppearances(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-inline-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let group = UUID()
        let agent = AgentProfile(name: "Designer", providerID: "fixture", modelID: "test")
        var original = RoomMessage(groupID: group, senderID: nil, text: "Earlier request")
        original.shortAddress = "t0u"
        let response = RoomMessage(groupID: group, senderID: agent.id,
            text: "Review [the earlier request / 原始需求](sand-msg:t0u) and [an unavailable reference](sand-msg:t9u).\n\n`[code stays literal](sand-msg:t0u)`\n\n**This is navigation, not approval.**")
        let directory = GroupMessageReferenceDirectory(history: [original, response], groupID: group)
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let host = NSHostingView(rootView: GroupMessageBubble(message: response, agent: agent,
                    inlineReferences: directory, onShowReply: { _ in }, onReaction: {})
                    .padding(16).frame(width: 380).background(FiliconTheme.canvas)
                    .environmentObject(model)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                expectNoDifference(size.width, 380)
                #expect(size.height > 120 && size.height < 480)
                host.frame = .init(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "inline-reference-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func quotedReplyPersistsWithoutChangingRecipientsOrQuestionState(shortAddress: Bool) async throws {
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
        let target = shortAddress ? try #require(source.shortAddress) : source.id.uuidString
        expectNoDifference(source.shortAddress, "t0s0")
        let probe = GroupReplyAppProbe()
        await model.registry.register(GroupReplyAppProvider { request, execute in
            guard await probe.record(request) == 1 else { return "PASS" }
            #expect(request.messages.first?.text.contains(engineer.id.uuidString) == true)
            #expect(request.messages.contains { $0.text.contains("Reply directory:") && $0.text.contains(source.id.uuidString) })
            let call = try NormalizedToolCall(id: "reply", name: "SendMessage", argumentsJSON: JSONEncoder().encode([
                "text": "@everyone the proposal is ready for review", "reply_to": target
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
        expectNoDifference(saved.shortAddress, "t1s0")
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

    @Test(arguments: ["stop", "account", "members"], [false, true])
    func lateReplyCannotPublishAfterHostRevocation(mode: String, quotedQuestion: Bool) async throws {
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
            let payload: [String: Any] = quotedQuestion
                ? ["type": "widget", "widget": ["prompt": "Late reply must not publish", "options": [["label": "Continue"]]], "reply_to": source.id.uuidString]
                : ["text": "Late reply must not publish", "reply_to": source.id.uuidString]
            let call = try NormalizedToolCall(id: "late-reply", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: payload))
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

    @Test(arguments: [false, true])
    func delegatedRoomWakeDoesNotGainReplyRouting(quotedQuestion: Bool) async throws {
        let groupID = UUID()
        let agent = AgentProfile(name: "Engineer", providerID: "group-reply-fixture", modelID: "test")
        let source = RoomMessage(groupID: groupID, senderID: nil, text: "User request")
        let incoming = RoomMessage(groupID: groupID, senderID: UUID(), text: "Peer task")
        let group = AgentGroup(id: groupID, name: "Team", memberIDs: [agent.id])
        let registry = ProviderRegistry()
        await registry.register(GroupReplyAppProvider { request, execute in
            #expect(!request.messages.contains { $0.text.contains("Reply directory:") })
            #expect(!request.messages.contains { $0.text.contains("[descriptive label](sand-msg:<shortAddress>)") })
            let payload: [String: Any] = quotedQuestion
                ? ["type": "widget", "widget": ["prompt": "Not authorized", "options": [["label": "Continue"]]], "reply_to": source.id.uuidString]
                : ["text": "Not authorized", "reply_to": source.id.uuidString]
            let call = try NormalizedToolCall(id: "foreign-route", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: payload))
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

    private func quotedQuestionFixture(withImage: Bool = false) async throws -> (URL, AppModel, AgentGroup, RoomMessage, RoomMessage, GroupReplyAppProbe) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-question-reply-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let engineer = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        let designer = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "group-reply-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Review team", summary: "", memberIDs: [engineer.id, designer.id]))
        let group = try #require(model.groups.first)
        let initial = GroupReplyAppProbe()
        await model.registry.register(GroupReplyAppProvider { request, _ in
            await initial.record(request) == 1 ? "Design proposal to discuss" : "PASS"
        })
        await model.sendGroupMessage(groupID: group.id, text: "@Designer propose a design")
        let original = try #require(model.groupMessages[group.id]?.first { $0.senderID == designer.id && $0.text == "Design proposal to discuss" })
        let target = withImage ? try #require(original.shortAddress) : original.id.uuidString
        var images: [AttachmentMetadata] = []
        if withImage {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            for y in 0..<8 { for x in 0..<8 { bitmap.setColor(.blue, atX: x, y: y) } }
            let file = root.appending(path: "review.png")
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: file)
            images = try await model.importAgentMessageImages([file])
        }
        let probe = GroupReplyAppProbe()
        await model.registry.register(GroupReplyAppProvider { request, execute in
            _ = await probe.record(request)
            #expect(request.messages.first?.text.contains(engineer.id.uuidString) == true)
            #expect(request.messages.contains { $0.text.contains("Reply directory:") && $0.text.contains(original.id.uuidString) })
            expectNoDifference(request.attachmentsByMessageID.isEmpty, !withImage)
            let payload: [String: Any] = ["type": "widget", "reply_to": target, "widget": [
                "prompt": "Which part of this proposal should we review?", "allowCustom": true, "dismissOnMoveOn": true,
                "options": [["label": "Layout", "value": "@everyone review layout"], ["label": "Typography", "value": "@Designer review typography"]]
            ]]
            _ = try await execute(.init(id: "quoted-question", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: payload)))
            Issue.record("Saved question must suspend the turn")
            return "Must never publish"
        })
        await model.sendGroupMessage(groupID: group.id, text: "@Engineer ask about the proposal", images: images)
        #expect(model.runningGroups.isEmpty && model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.errorMessage == nil)
        let question = try #require(model.groupMessages[group.id]?.first { $0.question != nil })
        expectNoDifference(question.replyToMessageID, original.id)
        expectNoDifference(question.shortAddress, "t1s0")
        expectNoDifference(question.senderID, engineer.id)
        #expect(question.images == nil && question.questionReplyTo == nil && model.canAnswerGroupQuestion(question))
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
        return (root, model, group, original, question, probe)
    }

    @Test(arguments: [AgentQuestionAnswer.option(0), .custom("@Designer review everything"), .dismissed], [false, true])
    func quotedChoiceSurvivesRestartAndAnswerOnlyResumesAsker(answer: AgentQuestionAnswer, withImage: Bool) async throws {
        let (root, _, group, original, question, _) = try await quotedQuestionFixture(withImage: withImage)
        defer { try? FileManager.default.removeItem(at: root) }
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        let pending = try #require(restored.groupMessages[group.id]?.first { $0.id == question.id })
        expectNoDifference(pending, try persistedMessage(question))
        let savedOriginal = try #require(restored.groupMessages[group.id]?.first { $0.id == original.id })
        expectNoDifference(savedOriginal, try persistedMessage(original))
        #expect(restored.canAnswerGroupQuestion(pending))
        let askerID = try #require(question.senderID)
        let probe = GroupReplyAppProbe()
        await restored.registry.register(GroupReplyAppProvider { request, _ in
            _ = await probe.record(request)
            #expect(request.messages.first?.text.contains(askerID.uuidString) == true)
            #expect(request.messages.contains { $0.role == .system && $0.text.contains("not a tool approval") })
            #expect(request.attachmentsByMessageID.isEmpty)
            return "Decision noted."
        })
        let permission = await restored.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        await restored.groupQuestionAnswered(pending, answer: answer)
        await restored.groupQuestionAnswered(pending, answer: answer)
        let messages = restored.groupMessages[group.id, default: []]
        let updated = try #require(messages.first { $0.id == question.id })
        expectNoDifference(updated.replyToMessageID, original.id)
        expectNoDifference(updated.question?.answer, answer)
        expectNoDifference(messages.first { $0.id == original.id }, savedOriginal)
        let answers = messages.filter { $0.questionReplyTo == question.id }
        expectNoDifference(answers.count, 1)
        expectNoDifference(answers.first?.shortAddress, "t2u")
        expectNoDifference(answers.first?.replyToMessageID, nil)
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
        let after = await restored.localToolPermissionPolicy.effectivePermission(for: .writeFile)
        expectNoDifference(after, permission)
        #expect(restored.runningGroups.isEmpty && restored.pendingAutoReviewApprovals.isEmpty && restored.errorMessage == nil)
    }

    private func persistedMessage(_ message: RoomMessage) throws -> RoomMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(RoomMessage.self, from: encoder.encode(message))
    }

    @Test(arguments: ["account", "members", "archive", "move-on"])
    func staleQuotedQuestionCannotResumeOrAlterOriginal(mode: String) async throws {
        let (root, model, group, original, question, probe) = try await quotedQuestionFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        if mode == "account" { model.settings.accountScope = "other" }
        if mode == "members" {
            await model.updateGroupMembers(groupID: group.id, memberIDs: [group.memberIDs[1]])
            await model.updateGroupMembers(groupID: group.id, memberIDs: group.memberIDs)
        }
        if mode == "archive" { await model.archiveAgent(id: group.memberIDs[0]) }
        if mode == "move-on" {
            await model.registry.register(GroupReplyAppProvider { _, _ in "PASS" })
            await model.sendGroupMessage(groupID: group.id, text: "@Engineer move on")
        }
        #expect(!model.canAnswerGroupQuestion(question))
        await model.groupQuestionAnswered(question, answer: .option(0))
        let messages = model.groupMessages[group.id, default: []]
        #expect(messages.allSatisfy { $0.questionReplyTo == nil })
        expectNoDifference(messages.first { $0.id == original.id }, original)
        expectNoDifference(messages.first { $0.id == question.id }?.replyToMessageID, original.id)
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func quotedChoiceCardsRenderInSevenLanguagesAndBothAppearances(language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-question-reply-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let groupID = UUID()
        let agent = AgentProfile(name: "Engineer", providerID: "fixture", modelID: "test")
        let original = RoomMessage(groupID: groupID, senderID: UUID(), text: "Design proposal: prioritize readable typography and a clear layout. " + String(repeating: "Additional design context. ", count: 20))
        let question = try AgentQuestion.parse(Data(#"{"prompt":"Which part should we review?","options":[{"label":"Layout","value":"@everyone review layout"},{"label":"Typography","value":"@Designer review typography"}],"allowCustom":true}"#.utf8))
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for state in ["pending", "answered", "missing", "retired"] {
            var message = RoomMessage(groupID: groupID, senderID: agent.id, text: question.prompt)
            message.replyToMessageID = original.id
            var card = GroupQuestion(question: question, accountID: "local", memberIDs: [agent.id])
            if state == "answered" { card.answer = .option(0) }
            if state == "retired" { card.retired = true }
            message.question = card
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: GroupMessageBubble(message: message, agent: agent,
                        questionEnabled: card.isPending, onQuestionAnswer: { _ in },
                        replySource: state == "missing" ? nil : original, replyAuthor: "Designer", onShowReply: { _ in }, onReaction: {})
                        .padding(16).frame(width: 380).background(FiliconTheme.canvas)
                        .environmentObject(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    expectNoDifference(size.width, 380)
                    #expect(size.height > (state == "retired" ? 180 : 250) && size.height < 880)
                    host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "question-reply-\(language)-\(state)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
