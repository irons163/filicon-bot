import AppKit
import SwiftUI
import Vision
import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private final class GroupReadAppClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func date() -> Date { lock.withLock { value } }
    func advance() { lock.withLock { value.addTimeInterval(1) } }
}

private actor GroupReadPublicationProbe {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

private struct GroupReadPublicationProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "group-read-fixture", displayName: "Group read fixture", requiresAPIKey: false)
    let probe = GroupReadPublicationProbe()
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        Issue.record("Group unread must exercise the real interactive publication path")
        return AsyncThrowingStream { $0.finish() }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if await probe.next() == 1 {
                        _ = try await executeTool(.init(id: "publish-unread", name: "SendMessage",
                            argumentsJSON: Data(#"{"text":"A real saved member publication"}"#.utf8)))
                    }
                    continuation.yield(.textDelta("PASS")); continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private struct GroupReadQuestionResponder: GroupAgentResponder {
    let question: AgentQuestion
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("Question fixture must use the saved publication callback"); return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        _ = try #require(try await onSavedPublication(.init(text: question.prompt, lifetime: AgentPublicationLifetime(),
            question: .init(question: question, accountID: "local", memberIDs: context.group.memberIDs))))
        return []
    }
}

@Suite("Group read UI integration", .serialized, .timeLimit(.minutes(1)))
@MainActor struct GroupReadAppTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func fixture(count: Int = 1, question: Bool = false) async throws -> (URL, AppModel, AgentGroup, AgentGroup) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-read-ui-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Fixture member", providerID: "group-read-fixture", modelID: "fixture")
        let clock = GroupReadAppClock()
        let service = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"), activityDate: clock.date)
        let group = try await service.create(name: "Unread room", memberIDs: [owner.id])
        let other = try await service.create(name: "Unread room", memberIDs: [owner.id])
        for index in 0..<count {
            clock.advance()
            try await service.recordDelegatedMessage(.init(groupID: group.id, senderID: owner.id,
                text: "Saved visible publication \(index)", createdAt: clock.date()))
        }
        if question {
            clock.advance()
            _ = try await service.run(groupID: group.id, responder: GroupReadQuestionResponder(question:
                AgentQuestion.parse(Data(#"{"prompt":"Choose a fixture option","options":[{"label":"Inspect"}]}"#.utf8))))
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.registry.register(GroupReadPublicationProvider())
        await model.reloadWorkspaceData()
        return (root, model, group, other)
    }

    private func durable(_ root: URL, id: UUID) async throws -> ConversationUnreadState {
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let service = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
        return try await service.unreadState(groupID: id)
    }

    private func expectDurableCount(_ root: URL, id: UUID, count: Int) async throws {
        let state = try await durable(root, id: id)
        expectNoDifference(state.unreadCount, count)
    }

    private func nonReadEnvelope(_ root: URL) throws -> Data {
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "groups.json"))) as? [String: Any])
        json.removeValue(forKey: "groupReadBookkeeping")
        return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<800 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Group unread projection did not reach its durable publication boundary")
        throw CancellationError()
    }

    private func renderSidebar(_ model: AppModel, language: String, dark: Bool, output: URL? = nil) async throws -> String {
        var text = ""
        try await withUIRenderTurn(language: language) {
            let host = NSHostingView(rootView: FiliconSidebar(onNewGroup: {})
                .environmentObject(model).environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light).frame(width: 224, height: 640))
            host.sizingOptions = []
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = .init(x: 0, y: 0, width: 224, height: 640)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = host.appearance; window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            #expect(host.fittingSize.width <= 224 && host.fittingSize.height <= 640)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: bitmap) }
            let recognition = VNRecognizeTextRequest(); recognition.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
            text = recognition.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: output.appending(path: "group-unread-sidebar-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
        return text
    }

    @Test func actualGroupSidebarShowsItsDurableUnreadBadge() async throws {
        let (root, model, _, _) = try await fixture(count: 123)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = try await renderSidebar(model, language: "en", dark: false)
        #expect(text.contains("Unread room"), "The actual group row must render: \(text)")
        #expect(text.contains("99+"), "The canonical group unread badge is missing: \(text)")
    }

    @Test func manualUnreadSurvivesFocusButSidebarActivationExplicitlyReadsItsOriginalRoom() async throws {
        let (root, model, group, other) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        expectNoDifference(model.groupUnreadState(id: group.id)?.unreadCount, 1)
        expectNoDifference(model.groupUnreadState(id: other.id)?.unreadCount, 0)
        let unread = try #require(model.beginGroupRead(id: group.id, action: .unread))
        try #require(await model.recordGroupRead(unread, at: now))
        let manual = try #require(model.groupUnreadState(id: group.id))
        #expect(manual.isManuallyUnread)
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        let focus = try #require(model.beginGroupRead(id: group.id, action: .viewed(preserveManualUnread: true)))
        try #require(await model.recordGroupRead(focus, at: now.addingTimeInterval(1)))
        expectNoDifference(model.groupUnreadState(id: group.id), manual)
        let read = try #require(model.beginSidebarGroupActivation(id: group.id))
        model.selectGroup(id: other.id)
        try #require(await model.recordGroupRead(read, at: now.addingTimeInterval(2)))
        #expect(!read.lease.isActive)
        #expect(!(await model.recordGroupRead(read, at: now.addingTimeInterval(3))))
        try await expectDurableCount(root, id: group.id, count: 0)
        try await expectDurableCount(root, id: other.id, count: 0)
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        expectNoDifference(reopened.groupUnreadState(id: group.id)?.unreadCount, 0)
        expectNoDifference(reopened.groupUnreadState(id: group.id)?.isManuallyUnread, false)
    }

    @Test func aHumanChoiceCannotBeSupersededByFocusOrByProjectionRefresh() async throws {
        let (root, model, group, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        let pending = try #require(model.beginGroupRead(id: group.id, action: .unread))
        await model.reloadGroupUnreadState(id: group.id)
        model.setConversationWindowFocused(true)
        #expect(model.beginGroupRead(id: group.id, action: .viewed(preserveManualUnread: true)) == nil)
        #expect(pending.lease.isActive)
        let replacement = try #require(model.beginGroupRead(id: group.id, action: .read))
        #expect(!pending.lease.isActive)
        #expect(!(await model.recordGroupRead(pending, at: now)))
        #expect(replacement.lease.isActive)
        try #require(await model.recordGroupRead(replacement, at: now.addingTimeInterval(1)))
        try await expectDurableCount(root, id: group.id, count: 0)
    }

    @Test(arguments: ["blur-cycle", "route-cycle", "selection-cycle", "covered", "new-history", "unloaded-history"])
    func automaticReadRequiresItsOriginalFocusedUncoveredAndLoadedHistory(change: String) async throws {
        let (root, model, group, other) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        let read = try #require(model.beginGroupRead(id: group.id, action: .viewed(preserveManualUnread: true)))
        let bytes = try Data(contentsOf: root.appending(path: "groups.json"))
        switch change {
        case "blur-cycle": model.setConversationWindowFocused(false); model.setConversationWindowFocused(true)
        case "route-cycle": model.route = .agents; model.route = .groups
        case "selection-cycle": model.selectedGroupID = other.id; model.selectedGroupID = group.id
        case "covered": model.showingOnboarding = true
        case "new-history": model.groupMessages[group.id, default: []].append(.init(groupID: group.id, senderID: group.memberIDs[0], text: "Not the captured arrival"))
        default: model.groupMessages[group.id] = nil
        }
        #expect(!(await model.recordGroupRead(read, at: now)))
        #expect(!read.lease.isActive)
        expectNoDifference(try Data(contentsOf: root.appending(path: "groups.json")), bytes)
        try await expectDurableCount(root, id: group.id, count: 1)
    }

    @Test(arguments: ["membership-cycle", "projection-membership-cycle", "remove-cycle", "account-cycle"])
    func queuedHumanReadsDoNotAcquireNewAuthorityAfterAwayAndBackCycles(change: String) async throws {
        let (root, model, group, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let read = try #require(model.beginGroupRead(id: group.id, action: .read))
        switch change {
        case "membership-cycle":
            await model.updateGroupMembers(groupID: group.id, memberIDs: [])
            await model.updateGroupMembers(groupID: group.id, memberIDs: group.memberIDs)
        case "projection-membership-cycle":
            let index = try #require(model.groups.firstIndex { $0.id == group.id })
            model.groups[index].memberIDs = []; model.groups[index].memberIDs = group.memberIDs
        case "remove-cycle": model.groups.removeAll { $0.id == group.id }; model.groups.append(group)
        default:
            await model.cancelAutoReviewApprovals(nextAccountID: "away-fixture"); model.settings.accountScope = "away-fixture"
            await model.cancelAutoReviewApprovals(nextAccountID: "local"); model.settings.accountScope = "local"
        }
        await model.reloadGroupUnreadState(id: group.id)
        let bytes = try Data(contentsOf: root.appending(path: "groups.json"))
        #expect(!(await model.recordGroupRead(read, at: now)))
        #expect(!read.lease.isActive)
        expectNoDifference(try Data(contentsOf: root.appending(path: "groups.json")), bytes)
        try await expectDurableCount(root, id: group.id, count: 1)
        let fresh = try #require(model.beginGroupRead(id: group.id, action: .read))
        try #require(await model.recordGroupRead(fresh, at: now.addingTimeInterval(1)))
        try await expectDurableCount(root, id: group.id, count: 0)
    }

    @Test(arguments: ["read", "unread", "viewed"])
    func aFailedSaveKeepsItsKnownProjectionAndDoesNotPublishZero(action: String) async throws {
        let (root, model, group, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        let selected: ConversationReadAction = action == "read" ? .read : action == "unread" ? .unread : .viewed(preserveManualUnread: true)
        let read = try #require(model.beginGroupRead(id: group.id, action: selected))
        let file = root.appending(path: "groups.json"), backup = root.appending(path: "groups-backup.json")
        let bytes = try Data(contentsOf: file), before = model.groupUnreadState(id: group.id)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(!(await model.recordGroupRead(read, at: now)))
        expectNoDifference(model.groupUnreadState(id: group.id), before)
        expectNoDifference(try Data(contentsOf: backup), bytes)
        #expect(model.errorMessage != nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let restored = try await durable(root, id: group.id)
        expectNoDifference(restored, before)
        model.errorMessage = nil
        let retry = try #require(model.beginGroupRead(id: group.id, action: selected))
        try #require(await model.recordGroupRead(retry, at: now.addingTimeInterval(1)))
        expectNoDifference(model.groupUnreadState(id: group.id)?.isManuallyUnread, action == "unread")
        expectNoDifference(model.groupUnreadState(id: group.id)?.unreadCount, action == "unread" ? 1 : 0)
    }

    @Test func allNativeReadActionsLeavePendingQuestionsHistoryAndOtherHostStateUntouched() async throws {
        let (root, model, group, _) = try await fixture(count: 0, question: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let history = model.groupMessages, envelope = try nonReadEnvelope(root)
        let routines = model.automations, approvals = model.pendingToolApprovals, cards = model.automationSpendGuardPrompts
        #expect(model.groupMessages[group.id]?.first?.question?.isPending == true)
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        for (index, action) in [ConversationReadAction.read, .unread, .viewed(preserveManualUnread: true)].enumerated() {
            let read = try #require(model.beginGroupRead(id: group.id, action: action))
            try #require(await model.recordGroupRead(read, at: now.addingTimeInterval(Double(index))))
            expectNoDifference(model.groupMessages, history)
            expectNoDifference(try nonReadEnvelope(root), envelope)
            expectNoDifference(model.automations, routines)
            expectNoDifference(model.pendingToolApprovals, approvals)
            expectNoDifference(model.automationSpendGuardPrompts, cards)
        }
        #expect(model.groupUnreadState(id: group.id)?.isManuallyUnread == true)
    }

    @Test(arguments: [false, true])
    func actualSavedMemberCallbacksRefreshCountsWithoutRetargetingAQueuedHumanAction(human: Bool) async throws {
        let (root, model, group, other) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        let read = try #require(model.beginGroupRead(id: group.id, action: human ? .read : .viewed(preserveManualUnread: true)))
        model.selectGroup(id: other.id)
        await model.sendGroupMessage(groupID: group.id, text: "Publish a fixture contribution")
        try await eventually { model.groupUnreadState(id: group.id)?.unreadCount == 3 }
        #expect(model.groupMessages[group.id]?.contains { $0.text == "A real saved member publication" } == true)
        expectNoDifference(model.groupUnreadState(id: other.id)?.unreadCount, 0)
        let saved = await model.recordGroupRead(read, at: Date())
        expectNoDifference(saved, human)
        try await expectDurableCount(root, id: group.id, count: human ? 0 : 3)
        try await expectDurableCount(root, id: other.id, count: 0)
        #expect(model.errorMessage == nil)
    }

    @Test func aFreshFocusedViewReadsActualArrivalsButNotAHandMarkedUnreadFlag() async throws {
        let (root, model, group, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectGroup(id: group.id); model.setConversationWindowFocused(true)
        let old = try #require(model.beginGroupRead(id: group.id, action: .viewed(preserveManualUnread: true)))
        await model.sendGroupMessage(groupID: group.id, text: "Publish while the group is focused")
        try await eventually { model.groupUnreadState(id: group.id)?.unreadCount == 3 }
        #expect(!(await model.recordGroupRead(old, at: Date())))
        let current = try #require(model.beginGroupRead(id: group.id, action: .viewed(preserveManualUnread: true)))
        try #require(await model.recordGroupRead(current, at: Date()))
        try await expectDurableCount(root, id: group.id, count: 0)
        let unread = try #require(model.beginGroupRead(id: group.id, action: .unread))
        try #require(await model.recordGroupRead(unread, at: Date()))
        await model.sendGroupMessage(groupID: group.id, text: "Another actual arrival")
        try await eventually { model.groupUnreadState(id: group.id)?.unreadCount == 2 }
        let preserved = try #require(model.groupUnreadState(id: group.id))
        let viewed = try #require(model.beginGroupRead(id: group.id, action: .viewed(preserveManualUnread: true)))
        try #require(await model.recordGroupRead(viewed, at: Date()))
        expectNoDifference(model.groupUnreadState(id: group.id), preserved)
        #expect(preserved.isManuallyUnread)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func actualGroupSidebarKeepsUnreadAndWorkingIndicatorsVisibleInSevenLanguages(language: String) async throws {
        let (root, model, group, _) = try await fixture(count: 123)
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectGroup(id: group.id)
        model.runningGroups.insert(group.id)
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for dark in [false, true] {
            let text = try await renderSidebar(model, language: language, dark: dark, output: output)
            #expect(text.contains("99+"), "Canonical unread count must remain visible in the actual narrow sidebar: \(text)")
        }
        let label = FiliconLocalization.render(.init(key: "Unread messages: {0}", arguments: ["123"]), language: language)
        #expect(label.contains("123") && !label.contains("{0}"))
        expectNoDifference(label == "Unread messages: 123", language == "en")
        expectNoDifference(FiliconLocalization.string("Mark as unread", language: language) == "Mark as unread", language == "en")
    }
}
