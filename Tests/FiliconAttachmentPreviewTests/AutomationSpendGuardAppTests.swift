import AppKit
import CustomDump
import Foundation
import SwiftUI
import Testing
import FiliconAgents
import FiliconAutomations
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import CSQLite
import Vision
@testable import Filicon

private struct ConversationReadFixtureProvider: AIProvider {
    var descriptor: ProviderDescriptor {
        .init(id: "fixture", displayName: "Conversation read fixture", requiresAPIKey: false, supportsToolCalling: false)
    }

    func models() async throws -> [AIModel] { [.init(id: "fixture")] }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        Issue.record("Conversation read fixtures must not perform inference.")
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.transport("No inference in the conversation read fixture"))
        }
    }
}

@Suite("Automation activity check app integration", .timeLimit(.minutes(1)))
@MainActor struct AutomationSpendGuardAppTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture() async throws -> (URL, AppModel, AgentProfile, AgentProfile) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-spend-guard-app-\(UUID())")
        let profiles = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await profiles.create(name: "Fixture engineer", instructions: "No provider calls",
            providerID: "fixture", modelID: "fixture", at: now)
        let peer = try await profiles.create(name: "Fixture designer", instructions: "No provider calls",
            providerID: "fixture", modelID: "fixture", at: now.addingTimeInterval(1))
        let routines = try AutomationService(storeURL: root.appending(path: "automations.json"))
        for profile in [owner, peer] {
            _ = try await routines.save(.init(id: profile.id, agentID: profile.id, name: "Fixture routine", prompt: "No inference",
                trigger: .cron(expression: "@every 1h", timeZoneIdentifier: "UTC"), createdAt: now), now: now)
            try await routines.answerSpendGuard(.pause, agentID: profile.id, at: now)
        }
        // No bootstrap, scheduler, external listeners or user app launch.
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.registry.register(ConversationReadFixtureProvider())
        await model.reloadWorkspaceData()
        await model.reloadAutomationDetails()
        return (root, model, owner, peer)
    }

    @Test func openingTheWorkspaceDoesNotAnswerOrMarkAllAgentsRead() async throws {
        let (root, model, owner, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = model.automationSpendGuardPrompts
        expectNoDifference(before.count, 2)
        model.selectRoute(.automations)
        await model.reloadAutomationDetails()
        expectNoDifference(model.automationSpendGuardPrompts, before)
        let read = try #require(model.beginAutomationAgentRead(id: owner.id))
        await model.markAutomationAgentViewed(read, at: now.addingTimeInterval(60))
        let after = model.automationSpendGuardPrompts
        expectNoDifference(after.map(\.id), before.map(\.id))
        expectNoDifference(after.first { $0.agentID == owner.id }?.state.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(after.first { $0.agentID != owner.id }, before.first { $0.agentID != owner.id })
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData(); await reopened.reloadAutomationDetails()
        expectNoDifference(reopened.automationSpendGuardPrompts, after)
    }

    private func visibleChatFixture() async throws -> (URL, AppModel, AgentProfile, AgentProfile, Conversation) {
        let (root, model, owner, peer) = try await fixture()
        var chat = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000159")!,
            title: peer.name, providerID: owner.providerID, modelID: owner.modelID, updatedAt: now)
        chat.agentBinding = .init(accountID: "local", agentID: owner.id)
        chat.messages = [.init(role: .assistant, text: "Isolated visible result", createdAt: now)]
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(chat, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        model.conversations = [chat]
        model.selection = chat.id
        model.route = .conversation(chat.id)
        await model.loadLatestMessages(for: chat.id)
        model.setConversationWindowFocused(true)
        return (root, model, owner, peer, chat)
    }

    @Test func viewingTheExactBoundChatUpdatesOnlyItsOwnerWithoutAnsweringTheCard() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.automationSpendGuardPrompts, definitions = model.automations
        let read = try #require(await model.beginVisibleConversationRead(id: chat.id))
        let saved = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        expectNoDifference(model.automations, definitions)
        expectNoDifference(model.automationSpendGuardPrompts.map(\.id), before.map(\.id))
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == owner.id }?.state.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == peer.id }, before.first { $0.agentID == peer.id })
        let replay = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(120))
        expectNoDifference(replay, false)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(spend.cardID, before.first { $0.agentID == owner.id }?.id)
        expectNoDifference(spend.guardPausedAutomationIDs, [owner.id])
    }

    @Test func aVisibleChatReadAlsoClearsTheCanonicalConversationUnreadCount() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let before = try #require(try await store.unreadState(conversationID: chat.id))
        expectNoDifference(before.unreadCount, 1)
        let read = try #require(await model.beginVisibleConversationRead(id: chat.id))
        let saved = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        let after = try #require(try await store.unreadState(conversationID: chat.id))
        expectNoDifference(after.unreadCount, 0)
        expectNoDifference(after.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(after.isManuallyUnread, false)
    }

    @Test func aNewArrivalRevokesAnAlreadyResolvedBoundActivityReadBeforeTheViewUpdates() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let before = try await store.unreadState(conversationID: chat.id), prompts = model.automationSpendGuardPrompts
        let read = try #require(await model.beginVisibleConversationRead(id: chat.id))
        model.conversations[0].messages.append(.init(role: .assistant, text: "An arrival not yet rendered", createdAt: now.addingTimeInterval(1)))
        let saved = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, false)
        let after = try await store.unreadState(conversationID: chat.id)
        expectNoDifference(after, before)
        expectNoDifference(model.automationSpendGuardPrompts, prompts)
    }

    @Test func aVisibleManualUnreadChatDoesNotClearItsFlagOrAdvanceTheActivityGuard() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let before = try await store.updateReadState(conversationID: chat.id, action: .unread,
            at: now.addingTimeInterval(20), expectedBinding: chat.agentBinding)
        let prompts = model.automationSpendGuardPrompts, definitions = model.automations
        let read = try #require(await model.beginVisibleConversationRead(id: chat.id))
        let saved = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        let after = try #require(try await store.unreadState(conversationID: chat.id))
        expectNoDifference(after, before)
        expectNoDifference(model.automationSpendGuardPrompts, prompts)
        expectNoDifference(model.automations, definitions)
    }

    @Test func explicitChatReadAndUnreadPersistAndCannotAnswerOrResumeAnActivityCard() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let beforePrompts = model.automationSpendGuardPrompts, definitions = model.automations
        let unread = try #require(model.beginConversationRead(id: chat.id, action: .unread))
        let marked = await model.recordConversationRead(unread, at: now.addingTimeInterval(30))
        expectNoDifference(marked, true)
        let state = try #require(model.conversationUnreadState(id: chat.id))
        expectNoDifference(state.isManuallyUnread, true)
        expectNoDifference(state.unreadCount, 1)
        let replay = await model.recordConversationRead(unread, at: now.addingTimeInterval(50))
        expectNoDifference(replay, false)
        let auto = try #require(model.beginConversationRead(id: chat.id, action: .viewed(preserveManualUnread: true)))
        let viewed = await model.recordConversationRead(auto, at: now.addingTimeInterval(60))
        expectNoDifference(viewed, true)
        expectNoDifference(model.conversationUnreadState(id: chat.id), state)
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        let cleared = await model.recordConversationRead(read, at: now.addingTimeInterval(70))
        expectNoDifference(cleared, true)
        let final = try #require(model.conversationUnreadState(id: chat.id))
        expectNoDifference(final.unreadCount, 0)
        expectNoDifference(final.isManuallyUnread, false)
        expectNoDifference(final.lastViewedAt, now.addingTimeInterval(70))
        expectNoDifference(model.automationSpendGuardPrompts, beforePrompts)
        expectNoDifference(model.automations, definitions)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        reopened.conversations = [chat]
        await reopened.reloadWorkspaceData()
        expectNoDifference(reopened.conversationUnreadState(id: chat.id), final)
    }

    @Test(arguments: [true, false])
    func aFocusCallbackCannotSupersedeAnAlreadyQueuedHumanReadAction(unread: Bool) async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let human = try #require(model.beginConversationRead(id: chat.id, action: unread ? .unread : .read))
        let automatic = model.beginConversationRead(id: chat.id, action: .viewed(preserveManualUnread: true))
        expectNoDifference(automatic == nil, true)
        expectNoDifference(human.lifetime.isCurrent, true)
        let saved = await model.recordConversationRead(human, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.isManuallyUnread, unread)
    }

    @Test func explicitlyOpeningAChatFromTheSidebarClearsManualUnreadButKeepsItsActivityCard() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        _ = try await store.updateReadState(conversationID: chat.id, action: .unread,
            at: now.addingTimeInterval(30), expectedBinding: chat.agentBinding)
        let prompts = model.automationSpendGuardPrompts, definitions = model.automations
        model.selectRoute(.agents)
        let activation = try #require(model.beginSidebarConversationActivation(id: chat.id))
        expectNoDifference(model.route, .conversation(chat.id))
        let saved = await model.recordSidebarConversationActivation(activation, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.isManuallyUnread, false)
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.unreadCount, 0)
        expectNoDifference(model.automations, definitions)
        expectNoDifference(model.automationSpendGuardPrompts.map(\.id), prompts.map(\.id))
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == owner.id }?.state.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == peer.id }, prompts.first { $0.agentID == peer.id })
    }

    @Test(arguments: [true, false])
    func nativeChatReadDoesNotRequireARoutineOrAnAgentBinding(bound: Bool) async throws {
        let (root, model, _, _, original) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000161")!,
            title: "Native chat without a routine", providerID: "fixture", modelID: "fixture", updatedAt: now)
        chat.agentBinding = bound ? original.agentBinding : nil
        chat.messages = [.init(role: .assistant, text: "Native arrival", createdAt: now)]
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(
            chat, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        model.automations = []
        model.conversations = [chat]; model.selection = chat.id; model.route = .conversation(chat.id)
        await model.loadLatestMessages(for: chat.id)
        await model.reloadConversationUnreadStates()
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.unreadCount, 1)
        let read = try #require(model.beginConversationRead(id: chat.id, action: .viewed(preserveManualUnread: true)))
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.unreadCount, 0)
        expectNoDifference(model.errorMessage, nil)
    }

    @Test(arguments: ["account-cycle", "archive", "rebind", "rebind-cycle", "remove", "new-action", "durable-rebind"])
    func aQueuedHumanReadCannotSurviveOwnerRevocationOrSupersedeANewAction(change: String) async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        var current: ConversationReadContext?
        switch change {
        case "account-cycle":
            await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
            model.settings.accountScope = "other-fixture-account"
            await model.cancelAutoReviewApprovals(nextAccountID: "local")
            model.settings.accountScope = "local"
        case "archive": await model.archiveAgent(id: owner.id)
        case "rebind": model.conversations[0].agentBinding = .init(accountID: "local", agentID: peer.id)
        case "rebind-cycle":
            model.conversations[0].agentBinding = .init(accountID: "local", agentID: peer.id)
            model.conversations[0].agentBinding = chat.agentBinding
        case "remove": model.conversations = []
        case "new-action": current = try #require(model.beginConversationRead(id: chat.id, action: .unread))
        case "durable-rebind":
            var replacement = chat; replacement.agentBinding = .init(accountID: "local", agentID: peer.id)
            try await store.upsert(replacement, replacingLoadedMessageIDs: [], historyComplete: true)
        default: break
        }
        let before = try await store.unreadState(conversationID: chat.id)
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, false)
        expectNoDifference(read.lifetime.isCurrent, false)
        let after = try await store.unreadState(conversationID: chat.id)
        expectNoDifference(after, before)
        if let current {
            expectNoDifference(current.lifetime.isCurrent, true)
            let fresh = await model.recordConversationRead(current, at: now.addingTimeInterval(61))
            expectNoDifference(fresh, true)
            expectNoDifference(model.conversationUnreadState(id: chat.id)?.isManuallyUnread, true)
        }
    }

    @Test(arguments: ["blur", "route", "selection", "covered", "new-message"])
    func aQueuedAutomaticChatReadRequiresTheOriginalVisiblePresentation(change: String) async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let before = try await store.unreadState(conversationID: chat.id)
        let read = try #require(model.beginConversationRead(id: chat.id, action: .viewed(preserveManualUnread: true)))
        switch change {
        case "blur": model.setConversationWindowFocused(false)
        case "route": model.route = .groups
        case "selection": model.selection = nil
        case "covered": model.showingOnboarding = true
        case "new-message": model.conversations[0].messages.append(.init(role: .assistant, text: "Not the captured visible arrival", createdAt: now.addingTimeInterval(1)))
        default: break
        }
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, false)
        let after = try await store.unreadState(conversationID: chat.id)
        expectNoDifference(after, before)
    }

    @Test func unreadProjectionRejectsForeignArchivedAndChangedCanonicalOwners() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadConversationUnreadStates()
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.unreadCount, 1)
        model.conversations[0].agentBinding = .init(accountID: "foreign", agentID: owner.id)
        expectNoDifference(model.conversationUnreadState(id: chat.id), nil)
        expectNoDifference(model.beginConversationRead(id: chat.id, action: .read) == nil, true)
        model.conversations[0].agentBinding = .init(accountID: "local", agentID: peer.id)
        await model.reloadConversationUnreadState(id: chat.id)
        expectNoDifference(model.conversationUnreadState(id: chat.id), nil)
        model.conversations[0].agentBinding = chat.agentBinding
        await model.reloadConversationUnreadState(id: chat.id)
        expectNoDifference(model.conversationUnreadState(id: chat.id)?.unreadCount, 1)
        await model.archiveAgent(id: owner.id)
        expectNoDifference(model.conversationUnreadState(id: chat.id), nil)
    }

    @Test func unreadLabelsAreLocalizedWithoutChangingTheCount() {
        let labels = ["en": "Mark as unread", "zh-Hant": "標示為未讀", "zh-Hans": "标记为未读",
            "fr": "Marquer comme non lu", "es": "Marcar como no leído", "ja": "未読にする", "ko": "읽지 않음으로 표시"]
        for (language, label) in labels {
            expectNoDifference(FiliconLocalization.string("Mark as unread", language: language), label)
            let message = FiliconLocalization.render(.init(key: "Unread messages: {0}", arguments: ["123"]), language: language)
            #expect(message.contains("123") && !message.contains("{0}"))
            expectNoDifference(message == "Unread messages: 123", language == "en")
        }
    }

    @Test func unreadStorageFailureDoesNotPublishZeroOrReadTheAutomationOwner() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadConversationUnreadStates()
        let before = model.conversationUnreadState(id: chat.id), prompts = model.automationSpendGuardPrompts
        var database: OpaquePointer?
        try #require(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        try #require(sqlite3_exec(database, "DELETE FROM conversation_read_state", nil, nil, nil) == SQLITE_OK)
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, false)
        expectNoDifference(model.conversationUnreadState(id: chat.id), before)
        expectNoDifference(model.automationSpendGuardPrompts, prompts)
        #expect(model.errorMessage != nil)
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func unreadBadgesRenderAtNarrowSidebarWidthInBothAppearances(language: String) async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let host = NSHostingView(rootView: VStack(spacing: 3) {
                    ChatListRow(title: "Long fixture conversation title for a narrow sidebar", subtitle: "Long preview retained beside the badge",
                        date: now, selected: true, unreadCount: 1) { Image(systemName: "person") }
                    ChatListRow(title: "A second long fixture title", subtitle: "An active conversation with a large count",
                        isWorking: true, unreadCount: 123) { Image(systemName: "person") }
                }.padding(8).frame(width: 224, height: 160, alignment: .top)
                    .background(FiliconTheme.sidebar)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.sizingOptions = []
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = .init(x: 0, y: 0, width: 224, height: 160)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance; window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                #expect(host.fittingSize.width <= 224 && host.fittingSize.height <= 160)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                let image = try #require(bitmap.cgImage)
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([recognition])
                let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                #expect(text.contains("99+"), "Large unread count must remain visible: \(text)")
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                if let output {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try png.write(to: output.appending(path: "unread-sidebar-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test(arguments: ["route", "selection", "blur", "rebind", "removed-projection", "account-cycle", "archive", "covered"])
    func aNoLongerVisibleOrOwnedChatCannotCommitALateRead(change: String) async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let read = try #require(await model.beginVisibleConversationRead(id: chat.id))
        switch change {
        case "route": model.selectRoute(.groups)
        case "selection": model.selection = nil
        case "blur": model.setConversationWindowFocused(false)
        case "rebind": model.conversations[0].agentBinding = .init(accountID: "local", agentID: peer.id)
        case "removed-projection": model.conversations.removeAll { $0.id == chat.id }
        case "account-cycle":
            await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
            model.settings.accountScope = "other-fixture-account"
            await model.cancelAutoReviewApprovals(nextAccountID: "local")
            model.settings.accountScope = "local"
        case "archive": await model.archiveAgent(id: owner.id)
        case "covered": model.showingOnboarding = true
        default: break
        }
        let saved = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, false)
        expectNoDifference(read.lifetime.isCurrent, false)
        expectNoDifference(read.bindingLease?.isActive, false)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.lastViewedAt, now)
    }

    @Test func anExpiredReceiptCannotCancelTheNewVisibleReceipt() async throws {
        let (root, model, owner, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(await model.beginVisibleConversationRead(id: chat.id))
        let second = try #require(await model.beginVisibleConversationRead(id: chat.id))
        let oldSaved = await model.recordVisibleConversationRead(first, at: now.addingTimeInterval(120))
        expectNoDifference(oldSaved, false)
        expectNoDifference(second.lifetime.isCurrent, true)
        expectNoDifference(second.bindingLease?.isActive, true)
        let newSaved = await model.recordVisibleConversationRead(second, at: now.addingTimeInterval(60))
        expectNoDifference(newSaved, true)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.lastViewedAt, now.addingTimeInterval(60))
    }

    @Test(arguments: ["unfocused", "unbound", "foreign-account", "ambiguous", "queued-epoch", "queued-rebind", "queued-rebind-cycle"])
    func aChatReadMustResolveCurrentUniqueOwnershipAndVisibility(rejection: String) async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let epoch = model.visibleConversationReadEpoch
        switch rejection {
        case "unfocused": model.setConversationWindowFocused(false)
        case "unbound": model.conversations[0].agentBinding = nil
        case "foreign-account": model.conversations[0].agentBinding = .init(accountID: "foreign", agentID: owner.id)
        case "ambiguous":
            var second = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000160")!,
                title: "Not in the loaded sidebar", providerID: owner.providerID, modelID: owner.modelID, updatedAt: now)
            second.agentBinding = chat.agentBinding
            try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(
                second, replacingLoadedMessageIDs: [], historyComplete: true)
        case "queued-epoch":
            model.setConversationWindowFocused(false)
            model.setConversationWindowFocused(true)
        case "queued-rebind":
            var replacement = chat; replacement.agentBinding = .init(accountID: "local", agentID: peer.id)
            try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(
                replacement, replacingLoadedMessageIDs: [], historyComplete: true)
            model.conversations[0].agentBinding = replacement.agentBinding
        case "queued-rebind-cycle":
            model.conversations[0].agentBinding = .init(accountID: "local", agentID: peer.id)
            model.conversations[0].agentBinding = chat.agentBinding
        default: break
        }
        let read = await model.beginVisibleConversationRead(id: chat.id, epoch: epoch)
        expectNoDifference(read == nil, true)
        model.cancelVisibleConversationRead()
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.lastViewedAt, now)
        if ["queued-rebind", "queued-rebind-cycle"].contains(rejection) {
            let fresh = try #require(await model.beginVisibleConversationRead(id: chat.id, epoch: model.visibleConversationReadEpoch))
            let saved = await model.recordVisibleConversationRead(fresh, at: now.addingTimeInterval(60))
            expectNoDifference(saved, true)
            let target = rejection == "queued-rebind" ? peer.id : owner.id
            let reopened = try AutomationService(storeURL: root.appending(path: "automations.json"))
            let current = await reopened.spendGuardState(agentID: target)
            let untouched = await reopened.spendGuardState(agentID: target == peer.id ? owner.id : peer.id)
            expectNoDifference(current.lastViewedAt, now.addingTimeInterval(60))
            expectNoDifference(untouched.lastViewedAt, now)
        }
    }

    @Test func oneCardsAnswerResumesOnlyItsOwnerAndCannotBeReplayed() async throws {
        let (root, model, owner, peer) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let prompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        let other = model.automations.filter { $0.agentID == peer.id }
        await model.answerAutomationSpendGuard(.resume, prompt: prompt, at: now.addingTimeInterval(60))
        expectNoDifference(model.automationSpendGuardPrompts.map(\.agentID), [peer.id])
        expectNoDifference(model.automations.filter { $0.agentID == peer.id }, other)
        let resumed = try #require(model.automations.first { $0.agentID == owner.id })
        #expect(resumed.enabled && !resumed.guardPaused)
        expectNoDifference(resumed.nextRunAt, now.addingTimeInterval(3_660))
        let beforeReplay = model.automations
        await model.answerAutomationSpendGuard(.pause, prompt: prompt, at: now.addingTimeInterval(61))
        expectNoDifference(model.automations, beforeReplay)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.snoozedUntil, now.addingTimeInterval(60 + AutomationSpendGuard.snoozeInterval))
        expectNoDifference(spend.cardID, nil)
        let history = await durable.history(automationID: resumed.id)
        expectNoDifference(history, [])
    }

    @Test(arguments: ["account", "archive", "wrong-owner", "storage"])
    func staleOrUnavailableCardsCannotCommitAnAnswer(mode: String) async throws {
        let (root, model, owner, peer) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var prompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        let before = model.automations
        switch mode {
        case "account":
            await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
            model.settings.accountScope = "other-fixture-account"
            await model.reloadAutomationDetails()
        case "archive": await model.archiveAgent(id: owner.id)
        case "wrong-owner":
            prompt = .init(id: prompt.id, agentID: peer.id, agentName: peer.name, accountID: prompt.accountID,
                generation: prompt.generation, state: prompt.state)
        case "storage":
            let file = root.appending(path: "automations.json")
            try FileManager.default.moveItem(at: file, to: root.appending(path: "backup.json"))
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        default: break
        }
        await model.answerAutomationSpendGuard(.resume, prompt: prompt, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations, before)
        expectNoDifference(model.answeringAutomationSpendGuardIDs, [])
        if mode == "storage" {
            #expect(model.errorMessage != nil)
            #expect(model.automationSpendGuardPrompts.contains { $0.id == prompt.id })
        }
    }

    @Test func anOldCardCannotAnswerAfterSwitchingAwayAndBackToTheSameAccount() async throws {
        let (root, model, owner, _) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let oldPrompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        let oldRead = try #require(model.beginAutomationAgentRead(id: owner.id))
        let before = model.automations
        await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
        model.settings.accountScope = "other-fixture-account"
        await model.cancelAutoReviewApprovals(nextAccountID: "local")
        model.settings.accountScope = "local"
        await model.reloadAutomationDetails()
        let current = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        expectNoDifference(current.id, oldPrompt.id)
        await model.answerAutomationSpendGuard(.resume, prompt: oldPrompt, at: now.addingTimeInterval(120))
        await model.markAutomationAgentViewed(oldRead, at: now.addingTimeInterval(120))
        expectNoDifference(model.automations, before)
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == owner.id }, current)
        #expect(current.generation != oldPrompt.generation)
        await model.answerAutomationSpendGuard(.resume, prompt: current, at: now.addingTimeInterval(120))
        #expect(model.automations.first { $0.agentID == owner.id }?.enabled == true)
    }

    @Test func cardMessagesAreAvailableInSevenLanguagesWithoutReinterpretingAgentNames() {
        let keys = [SpendGuardError.staleCard.rawValue, "This check affects only {0}'s individual routines; reviewed group sessions are excluded.",
            "Keep running or Resume postpones the next activity check for 30 days; it does not run missed tasks.",
            "Never ask disables this check only for this agent.", "Mark as read"]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en") }
            let name = "{1} / USER_NAME"
            let message = FiliconLocalization.render(.init(key: keys[1], arguments: [name]), language: language)
            #expect(message.contains(name))
        }
        // These labels are task execution choices, not running exercise, a
        // résumé/summary, podcasts, product descriptions or lodging terms.
        let actionKeys = ["Keep running", "Pause", "Never ask", "Resume", "Stay paused"]
        let actionLabels = [
            "en": ["Keep running", "Pause", "Never ask", "Resume", "Stay paused"],
            "zh-Hant": ["繼續執行", "暫停", "不再詢問", "繼續", "保持暫停"],
            "zh-Hans": ["继续运行", "暂停", "不再询问", "继续", "保持暂停"],
            "fr": ["Continuer l’exécution", "Mettre en pause", "Ne plus demander", "Reprendre", "Maintenir en pause"],
            "es": ["Seguir ejecutando", "Pausar", "No volver a preguntar", "Reanudar", "Mantener en pausa"],
            "ja": ["実行を続ける", "一時停止", "今後確認しない", "再開", "一時停止を続ける"],
            "ko": ["계속 실행", "일시 중지", "다시 묻지 않기", "재개", "일시 중지 유지"],
        ]
        for (language, labels) in actionLabels {
            for (key, label) in zip(actionKeys, labels) {
                expectNoDifference(FiliconLocalization.string(key, language: language), label)
            }
        }
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func cardsRenderInSevenLanguagesAtNarrowWidthAndBothAppearances(language: String) async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        for paused in [false, true] {
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let state = AutomationSpendGuardState(lastViewedAt: now, nudgedAt: paused ? nil : now,
                        guardPausedAutomationIDs: paused ? [id] : [], cardID: id)
                    let prompt = AutomationSpendGuardPrompt(id: id, agentID: id,
                        agentName: "A fixture owner with a deliberately long name", accountID: "local", generation: 1, state: state)
                    let host = NSHostingView(rootView: AutomationSpendGuardCard(prompt: prompt) { _ in }
                        .frame(width: 280, alignment: .leading).padding(16)
                        .frame(width: 312, height: 620, alignment: .topLeading)
                        .background(dark ? Color(white: 0.12) : Color.white)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 312, height: 620)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = host.appearance
                    window.contentView = host; defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    #expect(host.fittingSize.width <= 312 && host.fittingSize.height <= 620)
                    let controls = host.subviews.filter { !$0.frame.isEmpty }
                    expectNoDifference(controls.count, paused ? 2 : 3)
                    let bounds = controls.map { host.convert($0.bounds, from: $0) }
                    for (index, frame) in bounds.enumerated() {
                        #expect(host.bounds.contains(frame))
                        for other in bounds.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.appearance?.performAsCurrentDrawingAppearance {
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                    }
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "spend-guard-\(language)-\(paused ? "paused" : "nudge")-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }
}
