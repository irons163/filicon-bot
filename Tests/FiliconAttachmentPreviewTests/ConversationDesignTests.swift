import AppKit
import SwiftUI
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
@testable import Filicon

@Suite("Conversation design", .serialized)
@MainActor
struct ConversationDesignTests {
    @Test func peerRecoverySettingsRenderInEveryLanguage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-recovery-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let agent = AgentProfile(name: "Designer", avatar: .pet(.dewey))
        model.agents = [agent]
        var conversation = Conversation()
        conversation.agentBinding = .init(accountID: "local", agentID: agent.id)
        model.conversations = [conversation]
        model.selection = conversation.id
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try await withUIRenderTurn(language: language) {
                for dark in [false, true] {
                    let view = ChatConfigurationPopover(conversation: conversation)
                        .environmentObject(model).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = NSRect(x: 0, y: 0, width: 310, height: 620)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output { try png.write(to: output.appending(path: "peer-recovery-\(language)-\(dark ? "dark" : "light").png")) }
                }
            }
        }
    }

    @Test func peerTranscriptShowsActualAuthor() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "peer-author-render-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let engineer = AgentProfile(name: "工程師", avatar: .pet(.codex))
        let designer = AgentProfile(name: "設計師", avatar: .pet(.dewey))
        model.agents = [engineer, designer]
        let source = try AgentMessageSource(accountID: "local", originConversationID: UUID(), deliveryID: UUID(),
            senderAgentID: designer.id, recipientAgentID: engineer.id, kind: .incoming)
        let message = ChatMessage(role: .assistant, text: "建議提高按鈕對比，並保留足夠的點擊範圍。", agentMessageSource: source)
        let conversation = Conversation(messages: [message])
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        try await withUIRenderTurn(language: "zh-Hant") {
            for dark in [false, true] {
                let view = TranscriptMessageView(message: message, conversation: conversation, onJumpToMessage: { _ in })
                    .padding(24).frame(width: 620, height: 200).background(FiliconTheme.canvas)
                    .environmentObject(model).environment(\.locale, Locale(identifier: "zh-Hant"))
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 620, height: 200)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(!png.isEmpty)
                if let output { try png.write(to: output.appending(path: dark ? "peer-author-dark.png" : "peer-author-light.png")) }
            }
        }
    }

    @Test func groupOutcomeNoticesAreLocalizedAndRender() async throws {
        let agent = AgentProfile(name: "設計師", avatar: .pet(.dewey))
        let groupID = UUID()
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try await withUIRenderTurn(language: language) {
                for key in ["Member response failed. Send a message to retry.", "No new contribution this turn."] {
                    let translated = FiliconLocalization.string(key)
                    #expect(!translated.isEmpty)
                    if language != "en" { #expect(translated != key) }
                    if language == "zh-Hant", key.hasPrefix("Member") {
                        expectNoDifference(translated, "成員回應失敗。傳送訊息可重試。")
                    }
                }
                let view = VStack(spacing: 24) {
                    GroupMessageBubble(message: .init(groupID: groupID, senderID: agent.id, text: "", memberOutcome: .passed), agent: agent, onReaction: {})
                    GroupMessageBubble(message: .init(groupID: groupID, senderID: agent.id, text: "", memberOutcome: .failed), agent: agent, onReaction: {})
                }
                .padding(24).frame(width: 520, height: 240)
                .background(FiliconTheme.canvas)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, .light)
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 520, height: 240)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(!png.isEmpty)
                if let output { try png.write(to: output.appending(path: "group-outcomes-\(language).png")) }
            }
        }
    }

    @Test func inspectorCollapsesBeforeChatBecomesTooNarrow() {
        #expect(!ConversationLayout.showsInlineInspector(detailWidth: 779))
        #expect(ConversationLayout.showsInlineInspector(detailWidth: 780))
        #expect(ConversationLayout.showsInlineInspector(detailWidth: 1_000))
        #expect(ConversationLayout.sidebarWidth(for: 800) < ConversationLayout.sidebarWidth(for: 1_260))
    }

    @Test func memberSelectionAndPerGroupDraftsStayIndependent() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var settings = GroupSettingsDraft()
        #expect(!settings.isValid)
        settings.name = "Design team"
        settings.memberIDs[includes: first] = true
        settings.memberIDs[includes: second] = true
        settings.memberIDs[includes: first] = false
        #expect(settings.isValid)
        #expect(!settings.memberIDs.contains(first))
        #expect(settings.memberIDs.contains(second))
        settings.name = " \n "
        #expect(!settings.isValid)

        var drafts = GroupComposerDrafts()
        drafts[first] = "Keep this unsent message"
        drafts[second] = ""
        #expect(!drafts[first].isEmpty)
        #expect(drafts[second].isEmpty)
    }

    @Test func groupInspectorPersistsValidFieldsAndRejectsInvalidDrafts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream")
        let agent = try #require(model.agents.first)
        #expect(await model.createGroup(name: "Team", summary: "Original", memberIDs: [agent.id]))
        let group = try #require(model.groups.first)
        #expect(await model.saveGroupSettings(groupID: group.id, name: "Renamed", summary: "Updated", memberIDs: [agent.id]))
        #expect(!(await model.saveGroupSettings(groupID: group.id, name: " ", summary: "Invalid", memberIDs: [])))
        #expect(!(await model.saveGroupSettings(groupID: group.id, name: "Duplicate", summary: "", memberIDs: [agent.id, agent.id])))

        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        let restored = try #require(reopened.groups.first)
        #expect(restored.name.starts(with: "Renamed"))
        #expect(restored.summary.starts(with: "Updated"))
        #expect(restored.memberIDs.contains(agent.id))
    }

    @Test func renamingPreservesTranscriptAndExistingSpeakerOrder() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let service = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        let group = try await service.create(name: "Before", memberIDs: [])
        let message = try await service.postUserMessage("Keep this history", groupID: group.id)
        try await service.update(groupID: group.id, name: "After", summary: "Updated", memberIDs: [])
        let reopened = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        // Millisecond JSON timestamps can lose sub-millisecond floating-point precision.
        let restored = try #require(await reopened.messages(groupID: group.id).first { $0.id == message.id })
        #expect(restored.text == message.text)
        #expect(restored.senderID == message.senderID)
        #expect(abs(restored.createdAt.timeIntervalSince(message.createdAt)) < 0.001)

        let first = AgentProfile(name: "First")
        let second = AgentProfile(name: "Second")
        let orderedGroup = AgentGroup(name: "Team", memberIDs: [second.id, first.id])
        let draft = GroupSettingsDraft(group: orderedGroup)
        #expect(draft.orderedMembers(agents: [first, second], preserving: orderedGroup.memberIDs).starts(with: [second.id, first.id]))
    }

    /// Opt-in PNGs use an isolated model and never seed the user's workspace.
    /// FILICON_UI_REVIEW_OUTPUT=/absolute/temp/directory swift test --filter ConversationDesignTests
    @Test func renderReferenceLayouts() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let first = AgentProfile(name: "設計", summary: "Product design", avatar: .pet(.dewey))
        let second = AgentProfile(name: "工程", summary: "Engineering", avatar: .pet(.codex))
        let group = AgentGroup(name: "一人公司", summary: "一起把想法變成值得使用的產品。", memberIDs: [first.id, second.id])
        model.agents = [first, second]
        model.groups = [group, AgentGroup(name: "Product studio", summary: "A space for the next idea", memberIDs: [first.id])]
        model.selectedGroupID = group.id
        model.route = .groups
        let timestamp = Date(timeIntervalSince1970: 1_789_600_000)
        model.groupMessages[group.id] = [
            RoomMessage(groupID: group.id, senderID: first.id, text: "早安！今天想一起做什麼？我們可以從產品方向、介面設計或新的點子開始。", createdAt: timestamp),
            RoomMessage(groupID: group.id, senderID: nil, text: "我想做一個讓獨立工作者管理專案的工具。\n\n請先研究需求，再提出簡單、有設計感的第一版。", createdAt: timestamp.addingTimeInterval(60)),
            RoomMessage(groupID: group.id, senderID: first.id, text: "我會先整理使用情境，聚焦在每天最重要的三件事。畫面保持安靜，讓工作本身成為主角。", createdAt: timestamp.addingTimeInterval(90)),
            RoomMessage(groupID: group.id, senderID: second.id, text: "收到。我會規劃資料結構與可行的開發步驟，先從專案列表和每日進度開始。", createdAt: timestamp.addingTimeInterval(120))
        ]
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let languages = output == nil ? ["zh-Hant"] : ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"]
        for language in languages {
            try await render(model, size: NSSize(width: 1_260, height: 780), language: language, output: output, name: "chat-\(language)")
        }
        if let output {
            try await FiliconLocalization.$languageOverride.withValue("zh-Hant") {
                try await render(model, size: NSSize(width: 800, height: 680), language: "zh-Hant", output: output, name: "chat-compact")
                try await render(model, size: NSSize(width: 580, height: 650), language: "zh-Hant", output: output, name: "chat-narrow")
                try await render(model, size: NSSize(width: 1_260, height: 780), language: "zh-Hant", output: output, name: "chat-dark", dark: true)
                model.groups = []
                try await render(model, size: NSSize(width: 1_260, height: 780), language: "zh-Hant", output: output, name: "chat-empty")
                let conversation = Conversation(title: "產品規劃", messages: [
                    ChatMessage(role: .assistant, text: "你好！今天想一起做什麼？"),
                    ChatMessage(role: .user, text: "請幫我規劃第一版。\n\n簡單、清楚，而且能真正解決問題。"),
                    ChatMessage(role: .assistant, text: "我們先從三件事開始：\n\n1. 找到真正的使用情境\n2. 定義最小可行功能\n3. 用原型驗證方向")
                ])
                model.conversations = [conversation]
                model.selection = conversation.id
                model.route = .conversation(conversation.id)
                try await render(model, size: NSSize(width: 1_040, height: 720), language: "zh-Hant", output: output, name: "chat-direct")
            }
        }
    }

    private func render(_ model: AppModel, size: NSSize, language: String, output: URL?, name: String, dark: Bool = false) async throws {
        try await withUIRenderTurn(language: language) {
            let view = FiliconWorkspaceShell {
                if let conversation = model.selectedConversation, case .conversation = model.route {
                    ChatDetailView(conversation: conversation)
                } else {
                    GroupWorkspaceView()
                }
            }
                .environmentObject(model)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            #expect(!png.isEmpty)
            if let output { try png.write(to: output.appending(path: "\(name).png")) }
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "filicon-conversation-design-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
