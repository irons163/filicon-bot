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

private struct ConversationSpendGuardFixtureExecutor: AutomationExecutor {
    let context: @Sendable (Automation) async throws -> AutomationSpendGuardContext
    func spendGuardContext(for automation: Automation) async throws -> AutomationSpendGuardContext {
        try await context(automation)
    }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        .init(detail: "Isolated spend guard fixture; no inference or external tools")
    }
}

private actor CanonicalSpendGuardBatchExecutor: AutomationExecutor {
    let context: @Sendable (Automation) async throws -> AutomationSpendGuardContext
    private var entered: [UUID] = []
    private var first: CheckedContinuation<AutomationExecutionResult, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    init(context: @escaping @Sendable (Automation) async throws -> AutomationSpendGuardContext) { self.context = context }
    func spendGuardContext(for automation: Automation) async throws -> AutomationSpendGuardContext {
        try await context(automation)
    }
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult {
        entered.append(automation.id)
        if entered.count == 1 {
            return await withCheckedContinuation { continuation in
                first = continuation
                for observer in observers { observer.resume() }; observers.removeAll()
            }
        }
        return .init(detail: "Later isolated fixture; no inference or external tools")
    }
    func waitForFirst() async { if first == nil { await withCheckedContinuation { observers.append($0) } } }
    func finishFirst() { first?.resume(returning: .init(detail: "First isolated fixture")); first = nil }
    func observed() -> [UUID] { entered }
}

private struct CanonicalSpendGuardStoreSeed: Encodable {
    let schemaVersion = 2
    let automations: [Automation]
    let runs: [AutomationRun]
    let wakes: [AutomationWake]
    let claims: Set<String> = []
    let eventClaims: Set<String> = []
    let spendGuards: [UUID: AutomationSpendGuardState]
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
        // Fail at fixture readiness rather than attributing missing profiles
        // (for example protected-file read denial) to a widget regression.
        _ = try Data(contentsOf: root.appending(path: "agents.json"))
        // No bootstrap, scheduler, external listeners or user app launch.
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.registry.register(ConversationReadFixtureProvider())
        await model.reloadWorkspaceData()
        let loadedProfiles = model.agents.map(\.id)
        try #require(Set(loadedProfiles) == [owner.id, peer.id], "Isolated profiles must be readable before testing activity cards.")
        await model.reloadAutomationDetails()
        return (root, model, owner, peer)
    }

    @Test func theNativeProtectionProbeCanReadAnIsolatedProfileAfterItsAtomicWrite() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-protected-profile-probe-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "agents.json")
        let service = try AgentService(storeURL: file)
        let profile = try await service.create(name: "Offline protection probe", instructions: "No inference", providerID: "fixture", modelID: "fixture", at: now)
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.isEmpty)
        let reopened = try AgentService(storeURL: file)
        let retained = await reopened.list()
        expectNoDifference(retained, [profile])
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

    @Test(arguments: [SpendGuardAnswer.keep, .neverAsk])
    func workspaceCallbacksWithoutTranscriptEntriesStillRejectNudgeOnlyChoices(answer: SpendGuardAnswer) async throws {
        let (root, model, owner, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = try #require(model.automationSpendGuardPrompts.first { $0.agentID == owner.id })
        #expect(prompt.isPaused)
        let definitions = model.automations, prompts = model.automationSpendGuardPrompts
        let file = root.appending(path: "automations.json"), bytes = try Data(contentsOf: file)
        struct Outbox: Decodable { let spendGuardTranscriptEntries: [AutomationSpendGuardTranscriptEntry] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let outbox = try decoder.decode(Outbox.self, from: bytes)
        expectNoDifference(outbox.spendGuardTranscriptEntries, [])
        await model.answerAutomationSpendGuard(answer, prompt: prompt, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations, definitions)
        expectNoDifference(model.automationSpendGuardPrompts, prompts)
        expectNoDifference(try Data(contentsOf: file), bytes)
        expectNoDifference(model.answeringAutomationSpendGuardIDs, [])
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

    @Test func anActivityCheckIsActuallyVisibleInsideItsOwnersChat() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let renderedChat = try #require(model.conversations.first { $0.id == chat.id })
        #expect(renderedChat.messages.contains { !$0.transcriptCards.isEmpty })
        try await withUIRenderTurn(language: "en") {
            let host = NSHostingView(rootView: ChatDetailView(conversation: renderedChat)
                .environmentObject(model).environment(\.locale, Locale(identifier: "en"))
                .environment(\.colorScheme, .light))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: .aqua)
            host.frame = .init(x: 0, y: 0, width: 640, height: 900)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance; window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
            let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            #expect(text.contains("Resume") && text.contains("Stay paused"), "The real chat must show its activity check actions: \(text)")
            if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "spend-guard-owner-chat.png"))
            }
        }
    }

    @Test func activityChecksAndAppliedChoicesRemainInTheCanonicalChatAfterReopening() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        #expect(model.errorMessage == nil, "Activity transcript publication error: \(model.errorMessage ?? "none")")
        #expect(model.conversationSpendGuardPresentation(id: chat.id) != nil,
            "The host must retain a live presentation after successful materialization.")
        let issued = try #require(try await store.conversation(id: chat.id))
        let entry = try #require(issued.messages.first { message in
            message.transcriptCards.contains { card in
                guard case .widget(let widget) = card.payload else { return false }
                return widget.widgetKind == "automationActivity"
            }
        }, "A host activity check must be an actual saved transcript entry, not a temporary view.")
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        await model.answerConversationSpendGuard(.resume, presentation: presentation, at: now.addingTimeInterval(60))
        #expect(model.errorMessage == nil, "Applied receipt publication error: \(model.errorMessage ?? "none")")
        let guardStore = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let receipts = await guardStore.spendGuardTranscriptEntries(accountID: "local")
        expectNoDifference(receipts.first { $0.id == entry.id }?.answer, .resume)
        let answered = try #require(try await store.conversation(id: chat.id))
        #expect(answered.messages.contains { $0.id == entry.id })
        #expect(answered.messages.contains { message in
            message.role == .system && message.transcriptCards.contains { card in
                guard case .widget(let widget) = card.payload else { return false }
                return widget.widgetKind == "automationActivityAcknowledgment"
            }
        }, "The applied host choice must have a durable, non-human acknowledgment.")
        let before = answered.messages
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        reopened.conversations = try await store.conversationPage().items
        await reopened.reloadWorkspaceData(); await reopened.reloadAutomationDetails()
        let retained = try #require(try await store.conversation(id: chat.id))
        expectNoDifference(retained.messages, before)
        expectNoDifference(reopened.conversationSpendGuardPresentation(id: chat.id) == nil, true)
    }

    private func executeFixtureSQL(_ statement: String, at root: URL) throws {
        var handle: OpaquePointer?
        try #require(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
    }

    @Test(arguments: [false, true])
    func aFailedChatReceiptCanRecoverWithoutApplyingTheChoiceAgain(retainedNudge: Bool) async throws {
        let root: URL, model: AppModel, owner: AgentProfile, chat: Conversation
        let presentation: ConversationAutomationSpendGuardPresentation
        if retainedNudge {
            let fixture = try await retainedNudgeFixture()
            root = fixture.0; model = fixture.1; owner = fixture.2; chat = fixture.3
            let message = try #require(model.conversations.first { $0.id == chat.id }?.messages.first { $0.id == fixture.4.id })
            let card = try #require(message.transcriptCards.first)
            presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id, messageID: message.id,
                card: card))
        } else {
            let fixture = try await visibleChatFixture()
            root = fixture.0; model = fixture.1; owner = fixture.2; chat = fixture.4
            await model.reloadAutomationDetails()
            presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let answer: SpendGuardAnswer = retainedNudge ? .keep : .resume
        let answeredAt = now.addingTimeInterval(retainedNudge ? AutomationSpendGuard.pauseDelay + 3 : 60)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let before = try #require(try await store.conversation(id: chat.id))
        try executeFixtureSQL("CREATE TRIGGER reject_activity_ack BEFORE INSERT ON messages WHEN NEW.role='system' BEGIN SELECT RAISE(ABORT,'isolated receipt failure'); END", at: root)
        await FiliconLocalization.$languageOverride.withValue("en") {
            await model.answerConversationSpendGuard(answer, presentation: presentation, at: answeredAt)
        }
        #expect(model.errorMessage?.hasPrefix("The routine choice was applied, but its chat confirmation could not be saved:") == true)
        let failed = try #require(try await store.conversation(id: chat.id))
        expectNoDifference(failed, before)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let entries = await durable.spendGuardTranscriptEntries(accountID: "local")
        let receipt = try #require(entries.first { $0.id == presentation.transcriptEntryID })
        expectNoDifference(receipt.answer, answer)
        let definitions = await durable.list(), spend = await durable.spendGuardState(agentID: owner.id)
        #expect(spend.cardID == nil)
        try executeFixtureSQL("DROP TRIGGER reject_activity_ack", at: root)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        reopened.conversations = try await store.conversationPage().items
        await reopened.reloadWorkspaceData(); await reopened.reloadAutomationDetails()
        #expect(reopened.errorMessage == nil)
        let recovered = try #require(try await store.conversation(id: chat.id))
        #expect(recovered.messages.contains { $0.id == receipt.acknowledgmentID && $0.role == .system })
        expectNoDifference(reopened.automations, definitions)
        let retained = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let retainedSpend = await retained.spendGuardState(agentID: owner.id), retainedEntries = await retained.spendGuardTranscriptEntries(accountID: "local")
        expectNoDifference(retainedSpend, spend); expectNoDifference(retainedEntries, entries)
        await reopened.reloadAutomationDetails()
        let replayed = try #require(try await store.conversation(id: chat.id))
        expectNoDifference(replayed, recovered)
    }

    @Test func importedActivityMetadataCannotHideAHumanRequestOrReviveAnAction() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let current = try #require(model.conversations.first { $0.id == chat.id })
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let issued = try #require(current.messages.first { $0.id == presentation.transcriptEntryID })
        let card = try #require(issued.transcriptCards.first)
        let importedID = UUID(uuidString: "00000000-0000-0000-0000-000000001101")!
        let imported = ChatMessage(id: importedID, role: .assistant, text: "Imported display-only widget", createdAt: now, transcriptCards: [card])
        let human = ChatMessage(id: card.id, role: .user, text: "Actual human request", createdAt: now, transcriptCards: [card])
        #expect(issued.isAutomationActivityCardBody)
        #expect(!imported.isAutomationActivityCardBody && !human.isAutomationActivityCardBody)
        var hostTextHuman = human
        hostTextHuman.text = issued.text
        #expect(!hostTextHuman.isAutomationActivityCardBody,
            "A human's text is still visible even when it exactly quotes the host's activity summary.")
        let visible = model.conversationSpendGuardPresentation(id: chat.id, messageID: issued.id, card: card)
        #expect(visible != nil)
        #expect(model.conversationSpendGuardPresentation(id: chat.id, messageID: importedID, card: card) == nil)
        let withoutBookkeeping = await model.requestMessagesExcludingAutomationBookkeeping([issued, imported, human], in: chat.id, accountID: "local")
        expectNoDifference(withoutBookkeeping, [imported, human])
        let foreign = await model.requestMessagesExcludingAutomationBookkeeping([issued], in: chat.id, accountID: "other")
        expectNoDifference(foreign, [issued])
    }

    @Test(arguments: ["rebound", "replacement", "duplicate", "account"])
    func chatReceiptRecoveryNeverRetargetsItsOriginalOwner(change: String) async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try executeFixtureSQL("CREATE TRIGGER reject_activity_ack BEFORE INSERT ON messages WHEN NEW.role='system' BEGIN SELECT RAISE(ABORT,'isolated receipt failure'); END", at: root)
        await model.answerConversationSpendGuard(.resume, presentation: presentation, at: now.addingTimeInterval(60))
        try executeFixtureSQL("DROP TRIGGER reject_activity_ack", at: root)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let receipts = await durable.spendGuardTranscriptEntries(accountID: "local")
        let receipt = try #require(receipts.first { $0.id == presentation.transcriptEntryID && $0.answer == .resume })
        var original = try #require(try await store.conversation(id: chat.id))
        var replacement = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000001102")!, title: "Replacement fixture", updatedAt: now)
        replacement.agentBinding = .init(accountID: "local", agentID: owner.id)
        switch change {
        case "rebound":
            original.agentBinding = .init(accountID: "local", agentID: peer.id)
            try await store.upsert(original, replacingLoadedMessageIDs: Set(original.messages.map(\.id)), historyComplete: true)
            try await store.upsert(replacement, replacingLoadedMessageIDs: [], historyComplete: true)
        case "replacement":
            try await store.delete(id: chat.id)
            try await store.upsert(replacement, replacingLoadedMessageIDs: [], historyComplete: true)
        case "duplicate":
            try await store.upsert(replacement, replacingLoadedMessageIDs: [], historyComplete: true)
        default: break
        }
        let before = try await store.load()
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        if change == "account" { reopened.settings.accountScope = "other" }
        reopened.conversations = try await store.conversationPage().items
        await reopened.reloadWorkspaceData(); await reopened.reloadAutomationDetails()
        let after = try await store.load()
        #expect(!after.flatMap(\.messages).contains { $0.id == receipt.acknowledgmentID })
        // Other owners may receive their own live card, but this receipt must
        // never be copied to that chat or to the replacement owner's chat.
        for prior in before {
            let current = try #require(after.first { $0.id == prior.id })
            #expect(!current.messages.contains { $0.id == receipt.acknowledgmentID })
            #expect(current.messages.filter { $0.id == receipt.id } == prior.messages.filter { $0.id == receipt.id })
        }
        let retained = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let retainedReceipts = await retained.spendGuardTranscriptEntries(accountID: "local")
        expectNoDifference(retainedReceipts.first { $0.id == receipt.id }, receipt)
    }

    private func chatActivityFixture(paused: Bool) async throws -> (URL, AppModel, AgentProfile, AgentProfile, Conversation) {
        let (root, initial, owner, peer, chat) = try await visibleChatFixture()
        var definitions = initial.automations
        var spends = Dictionary(uniqueKeysWithValues: initial.automationSpendGuardPrompts.map { ($0.agentID, $0.state) })
        if !paused {
            let index = try #require(definitions.firstIndex { $0.agentID == owner.id })
            definitions[index].enabled = true; definitions[index].guardPaused = false
            definitions[index].nextRunAt = now.addingTimeInterval(3_600)
            spends[owner.id]?.guardPausedAutomationIDs = []
            spends[owner.id]?.nudgedAt = now.addingTimeInterval(1)
        }
        definitions.append(.init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000998")!, agentID: owner.id,
            name: "Human disabled fixture", prompt: "No inference", trigger: definitions[0].trigger, enabled: false, createdAt: now))
        let seed = CanonicalSpendGuardStoreSeed(automations: definitions, runs: [], wakes: [], spendGuards: spends)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(seed).write(to: root.appending(path: "automations.json"))
        // Reopen the host after seeding; two automation actors must not compete
        // to overwrite one file. This never bootstraps or starts a scheduler.
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.registry.register(ConversationReadFixtureProvider())
        let canonicalStore = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        model.conversations = try await canonicalStore.conversationPage().items
        await model.reloadWorkspaceData(); await model.reloadAutomationDetails()
        model.selection = chat.id; model.route = .conversation(chat.id)
        await model.loadLatestMessages(for: chat.id)
        return (root, model, owner, peer, chat)
    }

    private func retainedNudgeFixture() async throws -> (URL, AppModel, AgentProfile, Conversation, AutomationSpendGuardTranscriptEntry) {
        let (root, initial, owner, _, chat) = try await chatActivityFixture(paused: false)
        let nudge = try #require(initial.conversationSpendGuardPresentation(id: chat.id))
        // The seed actor only mutates before the new AppModel is opened. No
        // competing automation-store writers or real scheduler/model calls.
        let seed = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let pauseAt = now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 1)
        let decision = try await seed.evaluateSpendGuard(agentID: owner.id, at: pauseAt)
        expectNoDifference(decision, .pause)
        _ = try await seed.issueSpendGuardTranscript(agentID: owner.id, cardID: nudge.prompt.id,
            accountID: "local", conversationID: chat.id, isPaused: true, at: pauseAt)
        let retained = try #require(await seed.spendGuardTranscriptEntries(accountID: "local").first { $0.id == nudge.transcriptEntryID })
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.registry.register(ConversationReadFixtureProvider())
        model.conversations = try await store.conversationPage().items
        await model.reloadWorkspaceData(); await model.reloadAutomationDetails()
        return (root, model, owner, chat, retained)
    }

    @Test(arguments: [SpendGuardAnswer.keep, .pause, .neverAsk])
    func anUnansweredHostNudgeRemainsActionableAfterAutomaticPauseAndReopening(answer: SpendGuardAnswer) async throws {
        let (root, model, owner, chat, retained) = try await retainedNudgeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        #expect(current.prompt.isPaused)
        let message = try #require(model.conversations.first { $0.id == chat.id }?.messages.first { $0.id == retained.id })
        let card = try #require(message.transcriptCards.first)
        let old = try #require(model.conversationSpendGuardPresentation(id: chat.id, messageID: message.id, card: card),
            "The retained host nudge must keep its own choices after automatic pause, not become display-only.")
        #expect(!old.prompt.isPaused)
        expectNoDifference(old.prompt.id, current.prompt.id)
        let before = model.automations, grants = model.automationDirectBindings, groups = model.automationGroupBindings
        let file = root.appending(path: "automations.json"), bytes = try Data(contentsOf: file)
        await model.answerConversationSpendGuard(.resume, presentation: old, at: now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 2))
        expectNoDifference(model.automations, before); expectNoDifference(try Data(contentsOf: file), bytes)
        await model.answerConversationSpendGuard(answer, presentation: old, at: now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 3))
        #expect(model.errorMessage == nil)
        expectNoDifference(model.automationDirectBindings, grants); expectNoDifference(model.automationGroupBindings, groups)
        let durable = try AutomationService(storeURL: file), entries = await durable.spendGuardTranscriptEntries(accountID: "local")
        expectNoDifference(entries.first { $0.id == retained.id }?.answer, answer)
        expectNoDifference(model.automations.first { $0.id == owner.id }?.enabled, answer != .pause)
        #expect(model.conversationSpendGuardPresentation(id: chat.id, messageID: message.id, card: card) == nil)
        let definitions = model.automations, receiptBytes = try Data(contentsOf: file)
        await model.answerConversationSpendGuard(answer, presentation: old, at: now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 4))
        expectNoDifference(model.automations, definitions); expectNoDifference(try Data(contentsOf: file), receiptBytes)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let canonical = try #require(try await store.conversation(id: chat.id))
        #expect(canonical.messages.contains { $0.id == retained.acknowledgmentID && $0.role == .system })
        if answer == .pause {
            let paused = try #require(model.conversationSpendGuardPresentation(id: chat.id))
            await model.answerConversationSpendGuard(.resume, presentation: paused, at: now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 5))
            #expect(model.automations.first { $0.id == owner.id }?.enabled == true)
        } else { #expect(model.conversationSpendGuardPresentation(id: chat.id) == nil) }
    }

    @Test(arguments: ["rebind-cycle", "hide-cycle", "account-cycle", "forged-entry"])
    func aRetainedNudgeStillRejectsAnOwnershipCycleOrUnissuedEntry(mode: String) async throws {
        let (root, model, owner, chat, retained) = try await retainedNudgeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let message = try #require(model.conversations.first { $0.id == chat.id }?.messages.first { $0.id == retained.id })
        let card = try #require(message.transcriptCards.first)
        let original = try #require(model.conversationSpendGuardPresentation(id: chat.id, messageID: message.id, card: card))
        var callback = original
        switch mode {
        case "rebind-cycle":
            let index = try #require(model.conversations.firstIndex { $0.id == chat.id })
            model.conversations[index].agentBinding = nil
            model.conversations[index].agentBinding = chat.agentBinding
        case "hide-cycle":
            let index = try #require(model.conversations.firstIndex { $0.id == chat.id })
            model.conversations[index].hiddenAt = now
            model.conversations[index].hiddenAt = nil
        case "account-cycle":
            await model.cancelAutoReviewApprovals(nextAccountID: "fixture-away")
            model.settings.accountScope = "fixture-away"
            await model.cancelAutoReviewApprovals(nextAccountID: "local"); model.settings.accountScope = "local"
        default:
            callback = .init(conversationID: chat.id, prompt: original.prompt, bindingLease: original.bindingLease,
                transcriptEntryID: UUID(uuidString: "00000000-0000-0000-0000-000000001233")!)
        }
        await model.reloadAutomationDetails()
        let definitions = model.automations, file = root.appending(path: "automations.json"), bytes = try Data(contentsOf: file)
        await model.answerConversationSpendGuard(.keep, presentation: callback, at: now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 3))
        expectNoDifference(model.automations, definitions); expectNoDifference(try Data(contentsOf: file), bytes)
        let fresh = try #require(model.conversationSpendGuardPresentation(id: chat.id, messageID: message.id, card: card))
        await model.answerConversationSpendGuard(.keep, presentation: fresh, at: now.addingTimeInterval(AutomationSpendGuard.pauseDelay + 4))
        #expect(model.automations.first { $0.id == owner.id }?.enabled == true)
    }

    @Test func chatChecksUseCanonicalBindingsNotTitlesAndViewingDoesNotAnswerThem() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var other = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000997")!,
            title: owner.name, providerID: peer.providerID, modelID: peer.modelID, updatedAt: now)
        other.agentBinding = .init(accountID: "local", agentID: peer.id)
        let unbound = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000996")!, title: owner.name, updatedAt: now)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(other, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        try await store.upsert(unbound, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        model.conversations = [chat, other, unbound]
        await model.reloadAutomationDetails()
        let card = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let peerCard = try #require(model.conversationSpendGuardPresentation(id: other.id))
        expectNoDifference(card.prompt.agentID, owner.id); expectNoDifference(peerCard.prompt.agentID, peer.id)
        expectNoDifference(card.prompt.id, model.automationSpendGuardPrompts.first { $0.agentID == owner.id }?.id)
        expectNoDifference(model.conversationSpendGuardPresentation(id: unbound.id) == nil, true)
        let definitions = model.automations, peerPrompt = peerCard.prompt
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        await model.reloadAutomationDetails()
        expectNoDifference(model.automations, definitions)
        expectNoDifference(model.conversationSpendGuardPresentation(id: chat.id)?.prompt.id, card.prompt.id)
        expectNoDifference(model.conversationSpendGuardPresentation(id: other.id)?.prompt, peerPrompt)
        #expect(card.bindingLease.isActive)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        reopened.conversations = try await store.conversationPage().items
        await reopened.reloadWorkspaceData(); await reopened.reloadAutomationDetails()
        expectNoDifference(reopened.conversationSpendGuardPresentation(id: chat.id)?.prompt.id, card.prompt.id)
        expectNoDifference(reopened.conversationSpendGuardPresentation(id: other.id)?.prompt.id, peerCard.prompt.id)
    }

    @Test(arguments: ["keep", "pause", "neverAsk", "resume", "stayPaused"])
    func chatAnswersShareThePersistedGuardAndNeverGrantToolOrPeerAuthority(value: String) async throws {
        let answer = try #require(SpendGuardAnswer(rawValue: value))
        let (root, model, owner, peer, chat) = try await chatActivityFixture(paused: [.resume, .stayPaused].contains(answer))
        defer { try? FileManager.default.removeItem(at: root) }
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let peers = model.automations.filter { $0.agentID == peer.id }
        let disabled = try #require(model.automations.first { $0.name == "Human disabled fixture" })
        let settings = model.settings, messages = model.conversations, grants = model.automationDirectBindings
        let groups = model.automationGroupBindings, prompt = model.automationSpendGuardPrompts.first { $0.agentID == peer.id }
        await model.answerConversationSpendGuard(answer, presentation: presentation, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations.filter { $0.agentID == peer.id }, peers)
        expectNoDifference(model.automations.first { $0.id == disabled.id }, disabled)
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == peer.id }, prompt)
        expectNoDifference(model.settings, settings)
        for original in messages {
            let current = try #require(model.conversations.first { $0.id == original.id })
            expectNoDifference(current.agentBinding, original.agentBinding)
            let ordinaryMessages: (Conversation) -> [ChatMessage] = { value in
                value.messages.filter { message in
                    !message.transcriptCards.contains { card in
                        guard case .widget(let widget) = card.payload else { return false }
                        return widget.automationActivity != nil
                    }
                }
            }
            expectNoDifference(ordinaryMessages(current), ordinaryMessages(original))
        }
        expectNoDifference(model.automationDirectBindings, grants); expectNoDifference(model.automationGroupBindings, groups)
        expectNoDifference(model.selection, chat.id); expectNoDifference(model.answeringAutomationSpendGuardIDs, [])
        let routine = try #require(model.automations.first { $0.id == owner.id })
        let enabled = [.keep, .resume, .neverAsk].contains(answer)
        expectNoDifference(routine.enabled, enabled)
        expectNoDifference(routine.guardPaused, answer == .pause)
        expectNoDifference(routine.nextRunAt, enabled ? now.addingTimeInterval(answer == .resume ? 3_660 : 3_600) : nil)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let spend = await durable.spendGuardState(agentID: owner.id), history = await durable.history(automationID: owner.id)
        expectNoDifference(spend.optedOut, answer == .neverAsk)
        expectNoDifference(spend.snoozedUntil, [.keep, .resume].contains(answer) ? now.addingTimeInterval(60 + AutomationSpendGuard.snoozeInterval) : nil)
        expectNoDifference(history, [])
        expectNoDifference(presentation.bindingLease.isActive, false)
        let beforeReplay = model.automations
        await model.answerConversationSpendGuard(.resume, presentation: presentation, at: now.addingTimeInterval(61))
        expectNoDifference(model.automations, beforeReplay)
        if answer == .pause {
            let paused = try #require(model.conversationSpendGuardPresentation(id: chat.id))
            expectNoDifference(paused.prompt.id, presentation.prompt.id)
            #expect(paused.prompt.isPaused)
            await model.answerConversationSpendGuard(.resume, presentation: paused, at: now.addingTimeInterval(62))
            #expect(model.automations.first { $0.id == owner.id }?.enabled == true)
        } else { expectNoDifference(model.conversationSpendGuardPresentation(id: chat.id) == nil, true) }
    }

    @Test(arguments: ["rebind-cycle", "remove-cycle", "hide-cycle", "sidebar-hide-cycle", "duplicate-cycle", "archive-cycle", "account-cycle", "foreign-account", "forged-lease", "durable-rebind", "durable-ambiguous"])
    func staleChatButtonsCannotReviveAfterAnOwnershipCycle(mode: String) async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let definitions = model.automations
        var callback = presentation
        switch mode {
        case "rebind-cycle":
            model.conversations[0].agentBinding = .init(accountID: "local", agentID: peer.id)
            model.conversations[0].agentBinding = chat.agentBinding
        case "remove-cycle": model.conversations = []; model.conversations = [chat]
        case "hide-cycle": model.conversations[0].hiddenAt = now; model.conversations[0].hiddenAt = nil
        case "sidebar-hide-cycle":
            let hidden = await model.saveBoundConversationVisibility(id: chat.id, hidden: true)
            let shown = await model.saveBoundConversationVisibility(id: chat.id, hidden: false)
            expectNoDifference(hidden, true); expectNoDifference(shown, true)
        case "duplicate-cycle":
            var duplicate = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000995")!, updatedAt: now)
            duplicate.agentBinding = chat.agentBinding
            model.conversations.append(duplicate); model.conversations.removeLast()
        case "archive-cycle": await model.archiveAgent(id: owner.id); await model.restoreAgent(id: owner.id)
        case "account-cycle":
            await model.cancelAutoReviewApprovals(nextAccountID: "fixture-away")
            model.settings.accountScope = "fixture-away"
            await model.cancelAutoReviewApprovals(nextAccountID: "local"); model.settings.accountScope = "local"
        case "foreign-account": model.conversations[0].agentBinding = .init(accountID: "other", agentID: owner.id)
        case "forged-lease":
            callback = .init(conversationID: chat.id, prompt: presentation.prompt,
                bindingLease: .init(conversationID: chat.id, binding: try #require(chat.agentBinding)),
                transcriptEntryID: presentation.transcriptEntryID)
        case "durable-rebind":
            var replacement = chat; replacement.agentBinding = .init(accountID: "local", agentID: peer.id)
            let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
            try await store.upsert(replacement, replacingLoadedMessageIDs: Set(chat.messages.map(\.id)), historyComplete: true)
        case "durable-ambiguous":
            var duplicate = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000994")!, hiddenAt: now)
            duplicate.agentBinding = chat.agentBinding
            let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
            try await store.upsert(duplicate, replacingLoadedMessageIDs: [], historyComplete: true)
        default: break
        }
        if !["durable-rebind", "foreign-account"].contains(mode) { await model.reloadAutomationDetails() }
        await model.answerConversationSpendGuard(.resume, presentation: callback, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations, definitions)
        let durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let after = await durable.list()
        expectNoDifference(after, definitions)
        if mode == "durable-ambiguous" {
            expectNoDifference(model.conversationSpendGuardPresentation(id: chat.id) == nil, true)
            #expect(model.errorMessage != nil)
        }
        if ["rebind-cycle", "remove-cycle", "hide-cycle", "sidebar-hide-cycle", "duplicate-cycle", "archive-cycle", "account-cycle"].contains(mode) {
            #expect(!presentation.bindingLease.isActive)
            let fresh = try #require(model.conversationSpendGuardPresentation(id: chat.id))
            expectNoDifference(fresh.prompt.id, presentation.prompt.id)
            await model.answerConversationSpendGuard(.resume, presentation: fresh, at: now.addingTimeInterval(61))
            #expect(model.automations.first { $0.id == owner.id }?.enabled == true)
        }
    }

    @Test func aModelWidgetOrWrongStageDoesNotAcquireActivityAnswerAuthority() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let before = model.automations
        await model.answerConversationSpendGuard(.neverAsk, presentation: presentation, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations, before)
        let widget = TranscriptCard(id: presentation.prompt.id, lifecycle: .pending,
            payload: .widget(.init(title: "Automation activity check", widgetKind: "automation-activity-check",
                facts: ["cardID": presentation.prompt.id.uuidString])))
        var fake = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000993")!,
            messages: [.init(role: .assistant, text: "A model claims this can resume routines", transcriptCards: [widget])])
        fake.agentBinding = nil
        model.conversations.append(fake)
        await model.reloadAutomationDetails()
        expectNoDifference(model.conversationSpendGuardPresentation(id: fake.id) == nil, true)
        expectNoDifference(model.automations, before)
    }

    @Test func aFailedChatAnswerKeepsItsCardAndCanBeRetriedWithoutPartialResume() async throws {
        let (root, model, _, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let before = model.automations, cards = model.automationSpendGuardPrompts
        let file = root.appending(path: "automations.json"), backup = root.appending(path: "chat-answer-backup.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await model.answerConversationSpendGuard(.resume, presentation: presentation, at: now.addingTimeInterval(60))
        expectNoDifference(model.automations, before); expectNoDifference(model.automationSpendGuardPrompts, cards)
        expectNoDifference(model.answeringAutomationSpendGuardIDs, [])
        #expect(model.errorMessage != nil && presentation.bindingLease.isActive)
        try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
        model.errorMessage = nil
        await model.answerConversationSpendGuard(.resume, presentation: presentation, at: now.addingTimeInterval(61))
        expectNoDifference(model.conversationSpendGuardPresentation(id: chat.id) == nil, true)
        #expect(model.automations.first { $0.agentID == presentation.prompt.agentID }?.enabled == true)
    }

    @Test func navigatingElsewhereDoesNotRetargetAnAlreadyCapturedHumanAnswer() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
        let peerDefinitions = model.automations.filter { $0.agentID == peer.id }
        let peerCard = model.automationSpendGuardPrompts.first { $0.agentID == peer.id }
        let other = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000992")!, title: owner.name)
        model.conversations.append(other); model.selection = other.id; model.route = .conversation(other.id)
        await model.answerConversationSpendGuard(.resume, presentation: presentation, at: now.addingTimeInterval(60))
        #expect(model.automations.first { $0.agentID == owner.id }?.enabled == true)
        expectNoDifference(model.automations.filter { $0.agentID == peer.id }, peerDefinitions)
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == peer.id }, peerCard)
        expectNoDifference(model.selection, other.id)
        expectNoDifference(model.conversationSpendGuardPresentation(id: other.id) == nil, true)
    }

    @Test func theActivityGuardUsesCanonicalUnreadMessagesEvenWithoutResultWakes() async throws {
        let (root, model, owner, _, original) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.setConversationWindowFocused(false)
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        try await service.answerSpendGuard(.stayPaused, agentID: owner.id, at: now)
        try await service.setEnabled(id: owner.id, enabled: true, now: now)
        var chat = original
        for index in 1...14 {
            chat.messages.append(.init(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 170 + index))!,
                role: .assistant, text: "Canonical unread fixture \(index)", createdAt: now.addingTimeInterval(1)))
        }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(chat, replacingLoadedMessageIDs: Set(original.messages.map(\.id)), historyComplete: true,
            activityAt: now.addingTimeInterval(1))
        let canonical = try #require(try await store.unreadState(conversationID: chat.id))
        expectNoDifference(canonical.unreadCount, 15)
        let executor = ConversationSpendGuardFixtureExecutor { try await model.automationSpendGuardContext(for: $0) }
        try await service.reconcileSpendGuardContexts(executor: executor)
        let wakes = await service.pendingWakes(agentID: owner.id), state = await service.spendGuardState(agentID: owner.id)
        expectNoDifference(wakes, [])
        expectNoDifference(state.unreadCount, canonical.unreadCount)
        expectNoDifference(state.lastViewedAt, canonical.lastViewedAt)
        let decision = try await service.evaluateSpendGuard(agentID: owner.id,
            at: now.addingTimeInterval(AutomationSpendGuard.idleInterval + 1))
        expectNoDifference(decision, .nudge)
        let nudged = await service.spendGuardState(agentID: owner.id)
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        let viewedAt = now.addingTimeInterval(AutomationSpendGuard.idleInterval + 2)
        let readSaved = await model.recordConversationRead(read, at: viewedAt)
        expectNoDifference(readSaved, true)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        let durableService = try AutomationService(storeURL: root.appending(path: "automations.json"))
        try await durableService.reconcileSpendGuardContexts(executor: ConversationSpendGuardFixtureExecutor {
            try await reopened.automationSpendGuardContext(for: $0)
        })
        let durable = await durableService.spendGuardState(agentID: owner.id)
        expectNoDifference(durable.unreadCount, 0)
        expectNoDifference(durable.lastViewedAt, viewedAt)
        expectNoDifference(durable.cardID, nudged.cardID)
        expectNoDifference(durable.nudgedAt, nudged.nudgedAt)
    }

    @Test func resultWakesAndRunsCannotReplaceTheCanonicalChatReadMarker() async throws {
        let (root, model, owner, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var definition = try #require(model.automations.first { $0.agentID == owner.id })
        definition.enabled = true; definition.guardPaused = false
        definition.nextRunAt = now.addingTimeInterval(3_600)
        let runs = (0..<20).map { index in
            var run = AutomationRun(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 210 + index))!,
                automationID: definition.id, trigger: .manual, startedAt: now.addingTimeInterval(1))
            run.status = .ok; run.finishedAt = now.addingTimeInterval(1)
            return run
        }
        let wakes = runs.prefix(15).map {
            AutomationWake(agentID: owner.id, runID: $0.id, status: .ok, detail: "Isolated old wake",
                createdAt: now.addingTimeInterval(1), automationID: definition.id)
        }
        let seed = CanonicalSpendGuardStoreSeed(automations: [definition], runs: runs, wakes: wakes,
            spendGuards: [owner.id: .init(lastViewedAt: now)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(seed).write(to: root.appending(path: "automations.json"))
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(2))
        expectNoDifference(saved, true)
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        try await service.reconcileSpendGuardContexts(executor: ConversationSpendGuardFixtureExecutor {
            try await model.automationSpendGuardContext(for: $0)
        })
        let state = await service.spendGuardState(agentID: owner.id), retained = await service.pendingWakes(agentID: owner.id)
        expectNoDifference(state.unreadCount, 0)
        expectNoDifference(state.firesSinceViewed, 0)
        expectNoDifference(state.lastViewedAt, now.addingTimeInterval(2))
        expectNoDifference(retained, wakes)
        let decision = try await service.evaluateSpendGuard(agentID: owner.id,
            at: now.addingTimeInterval(AutomationSpendGuard.idleInterval + 5))
        expectNoDifference(decision, .belowThresholds)
    }

    @Test(arguments: ["read", "unchanged", "write-failure", "account-cycle"])
    func aQueuedBatchRechecksCanonicalActivityBeforeItsNextOwner(change: String) async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try #require(model.conversationUnreadState(id: chat.id))
        var definitions = try [#require(model.automations.first { $0.agentID == peer.id }),
            #require(model.automations.first { $0.agentID == owner.id })]
        for index in definitions.indices {
            definitions[index].enabled = true; definitions[index].guardPaused = false
            definitions[index].nextRunAt = now.addingTimeInterval(3_600)
        }
        let card = UUID(uuidString: "00000000-0000-0000-0000-000000000241")!
        let seed = CanonicalSpendGuardStoreSeed(automations: definitions, runs: [], wakes: [],
            spendGuards: [peer.id: .init(lastViewedAt: now), owner.id: .init(lastViewedAt: now, nudgedAt: now, cardID: card)])
        // Separate automation store avoids two independent service instances
        // overwriting each other when the real App read action saves its marker.
        let file = root.appending(path: "queued-automations.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(seed).write(to: file)
        let service = try AutomationService(storeURL: file)
        let executor = CanonicalSpendGuardBatchExecutor { try await model.automationSpendGuardContext(for: $0) }
        let firedAt = now.addingTimeInterval(AutomationSpendGuard.idleInterval + AutomationSpendGuard.pauseDelay + 2)
        let batch = Task { await service.fireDue(at: firedAt, executor: executor) }
        defer { Task { await executor.finishFirst() } }
        await executor.waitForFirst()
        if change == "write-failure" {
            var database: OpaquePointer?
            try #require(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            try #require(sqlite3_exec(database,
                "CREATE TRIGGER reject_guard_read BEFORE UPDATE ON conversation_read_state BEGIN SELECT RAISE(ABORT, 'fixture failure'); END",
                nil, nil, nil) == SQLITE_OK)
        }
        if change == "read" || change == "write-failure" {
            let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
            let saved = await model.recordConversationRead(read, at: firedAt)
            expectNoDifference(saved, change == "read")
        } else if change == "account-cycle" {
            await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
            model.settings.accountScope = "other-fixture-account"
            await model.cancelAutoReviewApprovals(nextAccountID: "local")
            model.settings.accountScope = "local"
        }
        await executor.finishFirst()
        let runs = await batch.value, entered = await executor.observed(), current = await service.list()
        expectNoDifference(runs.map(\.automationID), change == "read" ? [peer.id, owner.id] : [peer.id])
        expectNoDifference(entered, runs.map(\.automationID))
        #expect(runs.allSatisfy { $0.status == .ok })
        let ownerDefinition = try #require(current.first { $0.agentID == owner.id })
        let paused = change == "unchanged" || change == "write-failure"
        expectNoDifference(ownerDefinition.enabled, !paused)
        expectNoDifference(ownerDefinition.guardPaused, paused)
        expectNoDifference(ownerDefinition.revision, definitions[1].revision)
        let spend = await service.spendGuardState(agentID: owner.id)
        expectNoDifference(spend.cardID, card)
        expectNoDifference(spend.guardPausedAutomationIDs, paused ? [owner.id] : [])
        if change != "account-cycle" {
            expectNoDifference(spend.lastViewedAt, change == "read" ? firedAt : before.lastViewedAt)
            expectNoDifference(spend.unreadCount, change == "read" ? 0 : before.unreadCount)
        }
    }

    @Test(arguments: ["missing-read-row", "ambiguous-owner"])
    func anInvalidCanonicalSourceCannotPublishGuessedActivityOrReplaceTheCurrentCards(change: String) async throws {
        let (root, model, owner, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let before = model.automationSpendGuardPrompts, definitions = model.automations
        if change == "missing-read-row" {
            var database: OpaquePointer?
            try #require(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            try #require(sqlite3_exec(database, "DELETE FROM conversation_read_state", nil, nil, nil) == SQLITE_OK)
        } else {
            var duplicate = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000242")!,
                title: "Not in the loaded sidebar", providerID: owner.providerID, modelID: owner.modelID, updatedAt: now)
            duplicate.agentBinding = chat.agentBinding
            try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(
                duplicate, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        }
        await #expect(throws: (any Error).self) {
            try await model.automationSpendGuardContext(for: #require(definitions.first { $0.agentID == owner.id }))
        }
        model.errorMessage = nil
        await model.reloadAutomationDetails()
        #expect(model.errorMessage != nil)
        expectNoDifference(model.automationSpendGuardPrompts, before)
        expectNoDifference(model.automations, definitions)
    }

    @Test(arguments: ["account-cycle", "archive"])
    func aResolvedCanonicalGuardCannotCrossItsOriginalOwnerLifetime(change: String) async throws {
        let (root, model, owner, _, _) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        try await service.reconcileSpendGuardContexts(executor: ConversationSpendGuardFixtureExecutor {
            try await model.automationSpendGuardContext(for: $0)
        })
        let definitions = await service.list(), before = await service.spendGuardState(agentID: owner.id)
        if change == "archive" { await model.archiveAgent(id: owner.id) }
        else {
            await model.cancelAutoReviewApprovals(nextAccountID: "other-fixture-account")
            model.settings.accountScope = "other-fixture-account"
            await model.cancelAutoReviewApprovals(nextAccountID: "local")
            model.settings.accountScope = "local"
        }
        await #expect(throws: CancellationError.self) {
            try await service.evaluateSpendGuard(agentID: owner.id, at: now.addingTimeInterval(AutomationSpendGuard.idleInterval + 1))
        }
        let after = await service.list(), durable = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let card = await durable.spendGuardState(agentID: owner.id)
        expectNoDifference(after, definitions)
        expectNoDifference(card.cardID, before.cardID)
        expectNoDifference(card.guardPausedAutomationIDs, before.guardPausedAutomationIDs)
    }

    @Test func aReconciledGuardReadsLaterCanonicalReadActionsWithoutAnotherReload() async throws {
        let (root, model, owner, _, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let executor = ConversationSpendGuardFixtureExecutor { try await model.automationSpendGuardContext(for: $0) }
        try await service.reconcileSpendGuardContexts(executor: executor)
        let initial = await service.spendGuardState(agentID: owner.id)
        expectNoDifference(initial.unreadCount, 1)
        let read = try #require(model.beginConversationRead(id: chat.id, action: .read))
        let saved = await model.recordConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        let after = await service.spendGuardState(agentID: owner.id)
        var expected = initial; expected.lastViewedAt = now.addingTimeInterval(60); expected.unreadCount = 0
        expectNoDifference(after, expected)
        let unread = try #require(model.beginConversationRead(id: chat.id, action: .unread))
        let marked = await model.recordConversationRead(unread, at: now.addingTimeInterval(61))
        expectNoDifference(marked, true)
        let manual = try #require(model.conversationUnreadState(id: chat.id)), guarded = await service.spendGuardState(agentID: owner.id)
        expectNoDifference(guarded.unreadCount, manual.unreadCount)
        expectNoDifference(guarded.lastViewedAt, manual.lastViewedAt)
        expectNoDifference(guarded.cardID, initial.cardID)
        expectNoDifference(guarded.guardPausedAutomationIDs, initial.guardPausedAutomationIDs)
    }

    @Test func theExplicitActivityReadActionAlsoReadsOnlyItsExactCanonicalChat() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.reloadAutomationDetails()
        let before = model.automationSpendGuardPrompts, definitions = model.automations
        let action = try #require(model.beginAutomationAgentRead(id: owner.id))
        await model.markAutomationAgentViewed(action, at: now.addingTimeInterval(60))
        let state = try #require(model.conversationUnreadState(id: chat.id))
        expectNoDifference(state.unreadCount, 0)
        expectNoDifference(state.lastViewedAt, now.addingTimeInterval(60))
        expectNoDifference(model.automations, definitions)
        expectNoDifference(model.automationSpendGuardPrompts.map(\.id), before.map(\.id))
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == peer.id }, before.first { $0.agentID == peer.id })
        expectNoDifference(model.automationSpendGuardPrompts.first { $0.agentID == owner.id }?.state.guardPausedAutomationIDs,
            before.first { $0.agentID == owner.id }?.state.guardPausedAutomationIDs)
    }

    @Test func viewingTheExactBoundChatUpdatesOnlyItsOwnerWithoutAnsweringTheCard() async throws {
        let (root, model, owner, peer, chat) = try await visibleChatFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = model.automationSpendGuardPrompts, definitions = model.automations
        let read = try #require(await model.beginVisibleConversationRead(id: chat.id))
        let saved = await model.recordVisibleConversationRead(read, at: now.addingTimeInterval(60))
        expectNoDifference(saved, true)
        #expect(!read.lifetime.isCurrent && read.bindingLease?.isActive == false)
        #expect(model.conversationSpendGuardPresentation(id: chat.id) != nil,
            "Publishing the permanent prompt after a successful read must not report that read as failed.")
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
    func chatCardsRenderWithVisibleNonoverlappingActionsInBothAppearances(language: String) async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for paused in [false, true] {
            let (root, model, owner, _, chat) = try await chatActivityFixture(paused: paused)
            defer { try? FileManager.default.removeItem(at: root) }
            var profile = owner
            profile.name = "A fixture owner with a deliberately long name"
            let updated = await model.updateAgent(profile)
            expectNoDifference(updated, true)
            await model.reloadAutomationDetails()
            let presentation = try #require(model.conversationSpendGuardPresentation(id: chat.id))
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let host = NSHostingView(rootView: ConversationAutomationSpendGuardCard(presentation: presentation)
                        .frame(width: 280, alignment: .leading).padding(16)
                        .frame(width: 312, height: 700, alignment: .topLeading)
                        .background(FiliconTheme.canvas).environmentObject(model)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.sizingOptions = []
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 312, height: 700)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = host.appearance; window.contentView = host
                    defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    let controls = host.subviews.filter { !$0.frame.isEmpty }
                    expectNoDifference(controls.count, paused ? 2 : 3)
                    let bounds = controls.map { host.convert($0.bounds, from: $0) }
                    for (index, frame) in bounds.enumerated() {
                        #expect(host.bounds.contains(frame))
                        for other in bounds.dropFirst(index + 1) { #expect(!frame.intersects(other)) }
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "spend-guard-chat-\(language)-\(paused ? "paused" : "nudge")-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    @Test(.serialized, arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func savedReceiptsAndRetiredPromptsRenderWithoutActionsOrSpinners(language: String) async throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000991")!
        let guardID = UUID(uuidString: "00000000-0000-0000-0000-000000000992")!
        let acknowledgmentID = UUID(uuidString: "00000000-0000-0000-0000-000000000993")!
        let conversationID = UUID(uuidString: "00000000-0000-0000-0000-000000000994")!
        for variant in ["nudge", "paused", "keep", "pause", "neverAsk", "resume", "stayPaused"] {
            let answer = AutomationActivityTranscriptAnswer(rawValue: variant)
            let metadata = AutomationActivityTranscriptCard(entryID: entryID, guardID: guardID,
                binding: .init(accountID: "local", agentID: guardID), conversationID: conversationID,
                isPaused: ["paused", "resume", "stayPaused"].contains(variant), answer: answer)
            let publication = AutomationActivityTranscriptPublication(card: metadata, createdAt: now,
                answeredAt: answer == nil ? nil : now.addingTimeInterval(60), acknowledgmentID: acknowledgmentID)
            let message = try #require(publication.messages.last)
            let card = try #require(message.transcriptCards.first)
            expectNoDifference(card.rendererActions, [])
            expectNoDifference(card.rendererLifecycle, answer == nil ? .retired : .succeeded)
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let presentation = TranscriptCardPresenter.presentation(for: card)
                    let bodyKey = answer?.confirmationKey ?? metadata.bodyKey
                    expectNoDifference(presentation.detail, FiliconLocalization.string(bodyKey, language: language))
                    if language != "en" { #expect(presentation.detail != bodyKey) }
                    if let answer {
                        expectNoDifference(message.role, .system)
                        expectNoDifference(presentation.subtitle, FiliconLocalization.string(answer.labelKey, language: language))
                    }
                    let host = NSHostingView(rootView: TranscriptCardRow(card: card) { _ in
                        Issue.record("A durable receipt or retired prompt must never dispatch an action.")
                    }.frame(width: 280, alignment: .leading).padding(16)
                        .background(FiliconTheme.canvas).environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    #expect(size.width == 312 && size.height > 60 && size.height <= 420)
                    host.frame = .init(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = host.appearance; window.contentView = host
                    defer { window.contentView = nil }
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    #expect(!host.subviews.contains { $0 is NSButton || $0 is NSProgressIndicator },
                        "Readonly activity history must not create action buttons or indefinite progress indicators.")
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
                    if language == "ja" {
                        let recognition = VNRecognizeTextRequest()
                        recognition.recognitionLevel = .accurate
                        recognition.recognitionLanguages = ["ja-JP"]
                        try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
                        let text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }
                            .joined().filter { !$0.isWhitespace } ?? ""
                        #expect(text.contains(presentation.title.filter { !$0.isWhitespace }),
                            "The long Japanese title must be rendered in full: \(text)")
                    }
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(!png.isEmpty)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appending(path: "spend-guard-history-\(language)-\(variant)-\(dark ? "dark" : "light").png"))
                    }
                }
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
