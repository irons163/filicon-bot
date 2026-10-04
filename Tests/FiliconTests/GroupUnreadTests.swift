import Foundation
import Testing
import CustomDump
@testable import FiliconAgents
import FiliconDomain

private final class GroupUnreadClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    func date() -> Date { lock.withLock { value } }
    func set(_ date: Date) { lock.withLock { value = date } }
}

private struct UnreadGroupResponder: GroupAgentResponder {
    let body: @Sendable (GroupTurnContext, @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
        @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("Group read test requires actual durable publication callbacks"); return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        try await body(context, onTools, onSavedPublication)
    }
}

@Suite("Canonical group unread state")
struct GroupUnreadTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "filicon-group-unread-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func fixture(_ root: URL) async throws -> (AgentService, GroupService, AgentGroup, GroupUnreadClock) {
        let clock = GroupUnreadClock(now)
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Fixture member", providerID: "fixture", modelID: "test")
        let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"), activityDate: clock.date)
        let group = try await groups.create(name: "Original room", memberIDs: [sender.id])
        return (agents, groups, group, clock)
    }

    private func encode(_ state: AgentPersistentState, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: file, options: .atomic)
    }

    private func published(_ group: AgentGroup, id: UUID = UUID(), text: String = "Published result") -> RoomMessage {
        .init(id: id, groupID: group.id, senderID: group.memberIDs.first, text: text, createdAt: now)
    }

    @Test func visiblePublicationSavesItsOwnDurableUnreadState() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Fixture member", providerID: "fixture", modelID: "test")
        let file = root.appending(path: "groups.json")
        let groups = try GroupService(agents: agents, storeURL: file)
        let group = try await groups.create(name: "Original room", memberIDs: [sender.id])
        let message = RoomMessage(groupID: group.id, senderID: sender.id, text: "Published group result", createdAt: now)
        try await groups.recordDelegatedMessage(message)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let ledger = try #require(json["groupReadBookkeeping"] as? [String: Any])
        let records = try #require(ledger["records"] as? [[String: Any]])
        let record = try #require(records.first)
        expectNoDifference(record["groupID"] as? String, group.id.uuidString)
        let read = try #require(record["state"] as? [String: Any])
        expectNoDifference(read["unreadCount"] as? Int, 1)
        expectNoDifference(record["activityMessageIDs"] as? [String], [message.id.uuidString])
        let reopened = try GroupService(agents: agents, storeURL: file)
        let history = await reopened.messages(groupID: group.id)
        expectNoDifference(history.map(\.id), [message.id])
    }

    @Test func manualUnreadSurvivesFocusAndArrivalUntilAnExplicitRead() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (agents, groups, group, clock) = try await fixture(root)
        clock.set(now.addingTimeInterval(1))
        _ = try await groups.postUserMessage("An actual human message", groupID: group.id)
        let first = try await groups.unreadState(groupID: group.id)
        expectNoDifference(first.unreadCount, 1)
        let unreadLease = try await groups.leaseReadState(groupID: group.id); defer { unreadLease.close() }
        let manual = try await groups.updateReadState(unreadLease, action: .unread, at: now.addingTimeInterval(2))
        #expect(manual.isManuallyUnread)
        let focus = try await groups.leaseReadState(groupID: group.id); defer { focus.close() }
        let preserved = try await groups.updateReadState(focus, action: .viewed(preserveManualUnread: true), at: now.addingTimeInterval(3))
        expectNoDifference(preserved, manual)
        clock.set(now.addingTimeInterval(4))
        try await groups.recordDelegatedMessage(published(group))
        let arrived = try await groups.unreadState(groupID: group.id)
        expectNoDifference(arrived.unreadCount, 2); #expect(arrived.isManuallyUnread)
        let readLease = try await groups.leaseReadState(groupID: group.id); defer { readLease.close() }
        let read = try await groups.updateReadState(readLease, action: .read, at: now.addingTimeInterval(5))
        expectNoDifference(read.unreadCount, 0); #expect(!read.isManuallyUnread)
        expectNoDifference(read.lastViewedAt, now.addingTimeInterval(5))
        let reopened = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"), activityDate: clock.date)
        let restored = try await reopened.unreadState(groupID: group.id)
        expectNoDifference(restored, read)
    }

    @Test func editsReactionsMetadataAndSameNamedRoomsDoNotCreateArrivals() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        let other = try await groups.create(name: group.name, memberIDs: group.memberIDs)
        var message = published(group)
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(message)
        let first = try await groups.unreadState(groupID: group.id)
        let otherBefore = try await groups.unreadState(groupID: other.id)
        expectNoDifference(otherBefore.unreadCount, 0)
        message.text = "Edited content, not a second arrival"
        clock.set(now.addingTimeInterval(2)); try await groups.recordDelegatedMessage(message)
        _ = try await groups.toggleReaction(messageID: message.id, actorID: UUID(), emoji: "👍")
        try await groups.update(groupID: group.id, name: "Renamed", summary: "Changed metadata", memberIDs: group.memberIDs)
        let after = try await groups.unreadState(groupID: group.id)
        expectNoDifference(after, first)
        let otherLease = try await groups.leaseReadState(groupID: other.id); defer { otherLease.close() }
        _ = try await groups.updateReadState(otherLease, action: .unread, at: now.addingTimeInterval(3))
        let originalAfter = try await groups.unreadState(groupID: group.id)
        expectNoDifference(originalAfter, first)
        let history = await groups.messages(groupID: group.id)
        expectNoDifference(history.count, 1); expectNoDifference(history.first?.text, message.text)
    }

    @Test func actualMemberTurnCountsPublicationNotToolUpdatesOrPass() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        clock.set(now.addingTimeInterval(1))
        _ = try await groups.postUserMessage("Inspect and report", groupID: group.id)
        let lease = try await groups.leaseReadState(groupID: group.id); defer { lease.close() }
        _ = try await groups.updateReadState(lease, action: .read, at: now.addingTimeInterval(2))
        let responder = UnreadGroupResponder { context, tools, publish in
            guard context.round == 0 else { return ["PASS"] }
            clock.set(now.addingTimeInterval(3))
            try await tools([.init(id: "fixture-tool", name: "fixture_read")])
            let pending = try await groups.unreadState(groupID: group.id)
            expectNoDifference(pending.unreadCount, 0)
            clock.set(now.addingTimeInterval(4))
            _ = try #require(try await publish(.init(text: "Actual shared-runner publication")))
            let visible = try await groups.unreadState(groupID: group.id)
            expectNoDifference(visible.unreadCount, 1)
            clock.set(now.addingTimeInterval(5))
            try await tools([.init(id: "fixture-tool", name: "fixture_read", status: .succeeded)])
            return ["PASS"]
        }
        _ = try await groups.run(groupID: group.id, responder: responder)
        let final = try await groups.unreadState(groupID: group.id)
        expectNoDifference(final.unreadCount, 1)
        expectNoDifference(final.lastActivityAt, now.addingTimeInterval(4))
    }

    @Test func staleAutomaticViewCannotClearNewArrivalsOrLaterManualUnread() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(published(group))
        let view = try await groups.leaseReadState(groupID: group.id); defer { view.close() }
        clock.set(now.addingTimeInterval(2)); try await groups.recordDelegatedMessage(published(group))
        await #expect(throws: CancellationError.self) {
            try await groups.updateReadState(view, action: .viewed(preserveManualUnread: true), at: now.addingTimeInterval(3))
        }
        let afterArrival = try await groups.unreadState(groupID: group.id)
        expectNoDifference(afterArrival.unreadCount, 2)
        // A real explicit human read may cover the currently saved messages.
        _ = try await groups.updateReadState(view, action: .read, at: now.addingTimeInterval(3))
        let olderFocus = try await groups.leaseReadState(groupID: group.id); defer { olderFocus.close() }
        let manual = try await groups.leaseReadState(groupID: group.id); defer { manual.close() }
        _ = try await groups.updateReadState(manual, action: .unread, at: now.addingTimeInterval(4))
        await #expect(throws: CancellationError.self) {
            try await groups.updateReadState(olderFocus, action: .viewed(preserveManualUnread: false), at: now.addingTimeInterval(5))
        }
        let afterManual = try await groups.unreadState(groupID: group.id)
        #expect(afterManual.isManuallyUnread); expectNoDifference(afterManual.unreadCount, 1)
    }

    @Test(arguments: ["closed", "membership-cycle", "host-cycle", "different-instance"])
    func queuedNativeActionsKeepOriginalLifetimeAndStore(change: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (agents, groups, group, clock) = try await fixture(root)
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(published(group))
        let host = AgentWorkflowExecutionScope()
        let lease = try await groups.leaseReadState(groupID: group.id, inheriting: host.capture()); defer { lease.close() }
        var target = groups
        switch change {
        case "closed": lease.close()
        case "membership-cycle":
            try await groups.updateMembers(groupID: group.id, memberIDs: [])
            try await groups.updateMembers(groupID: group.id, memberIDs: group.memberIDs)
        case "host-cycle": host.suspend(); host.resume()
        default: target = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"), activityDate: clock.date)
        }
        let bytes = try Data(contentsOf: root.appending(path: "groups.json"))
        await #expect(throws: CancellationError.self) {
            try await target.updateReadState(lease, action: .read, at: now.addingTimeInterval(2))
        }
        expectNoDifference(try Data(contentsOf: root.appending(path: "groups.json")), bytes)
        let unread = try await target.unreadState(groupID: group.id)
        expectNoDifference(unread.unreadCount, 1)
        let current = try await target.leaseReadState(groupID: group.id); defer { current.close() }
        _ = try await target.updateReadState(current, action: .read, at: now.addingTimeInterval(3))
        let read = try await target.unreadState(groupID: group.id)
        expectNoDifference(read.unreadCount, 0)
    }

    @Test func legacyHistorySeedsReceiptsWithoutInventingUnreadArrivalsOrRewritingOnOpen() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (agents, _, group, clock) = try await fixture(root)
        let file = root.appending(path: "groups.json")
        var legacy = AgentPersistentState(); legacy.groups = [group]
        legacy.roomMessages = [published(group), published(group)]
        try encode(legacy, to: file)
        let originalBytes = try Data(contentsOf: file)
        let migrated = try GroupService(agents: agents, storeURL: file, activityDate: clock.date)
        let old = try await migrated.unreadState(groupID: group.id)
        expectNoDifference(old, .init()); expectNoDifference(try Data(contentsOf: file), originalBytes)
        try await migrated.update(groupID: group.id, name: "After migration", summary: "", memberIDs: group.memberIDs)
        let afterSave = try await migrated.unreadState(groupID: group.id)
        expectNoDifference(afterSave, .init())
        let reopened = try GroupService(agents: agents, storeURL: file, activityDate: clock.date)
        clock.set(now.addingTimeInterval(1)); try await reopened.recordDelegatedMessage(legacy.roomMessages[0])
        let replayed = try await reopened.unreadState(groupID: group.id)
        expectNoDifference(replayed, .init())
        clock.set(now.addingTimeInterval(2)); try await reopened.recordDelegatedMessage(published(group))
        let fresh = try await reopened.unreadState(groupID: group.id)
        expectNoDifference(fresh.unreadCount, 1)
    }

    @Test(arguments: ["read", "unread", "viewed", "publication", "create", "reaction", "speaker-offset", "members"])
    func failedAtomicSaveCannotPublishReadStateOrConsumeArrival(action: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (agents, groups, group, clock) = try await fixture(root)
        if action == "speaker-offset" {
            let second = try await agents.create(name: "Second", providerID: "fixture", modelID: "test")
            try await groups.updateMembers(groupID: group.id, memberIDs: group.memberIDs + [second.id])
        }
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(published(group))
        let before = try await groups.unreadState(groupID: group.id)
        let history = await groups.messages(groupID: group.id)
        let originalGroups = await groups.list()
        let lease = try await groups.leaseReadState(groupID: group.id); defer { lease.close() }
        let file = root.appending(path: "groups.json"), backup = root.appending(path: "owned-backup.json")
        let bytes = try Data(contentsOf: file)
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let newMessage = published(group)
        clock.set(now.addingTimeInterval(2))
        await #expect(throws: (any Error).self) {
            switch action {
            case "publication": try await groups.recordDelegatedMessage(newMessage)
            case "create": _ = try await groups.create(name: "Failed room", memberIDs: group.memberIDs)
            case "members": try await groups.updateMembers(groupID: group.id, memberIDs: [])
            case "reaction": _ = try await groups.toggleReaction(messageID: history[0].id, actorID: group.memberIDs[0], emoji: "👍")
            case "speaker-offset":
                _ = try await groups.run(groupID: group.id, responder: UnreadGroupResponder { _, _, _ in
                    Issue.record("A failed initial save must not start a member"); return []
                })
            default:
                let readAction: ConversationReadAction = action == "read" ? .read : (action == "unread" ? .unread : .viewed(preserveManualUnread: true))
                _ = try await groups.updateReadState(lease, action: readAction, at: now.addingTimeInterval(2))
            }
        }
        let failed = try await groups.unreadState(groupID: group.id)
        let failedHistory = await groups.messages(groupID: group.id), failedGroups = await groups.list()
        expectNoDifference(failed, before); expectNoDifference(failedHistory, history); expectNoDifference(failedGroups, originalGroups)
        let failedReactions = await groups.reactions(messageID: history[0].id)
        expectNoDifference(failedReactions, [])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        expectNoDifference(try Data(contentsOf: file), bytes)
        if action == "publication" {
            clock.set(now.addingTimeInterval(3)); try await groups.recordDelegatedMessage(newMessage)
            let retried = try await groups.unreadState(groupID: group.id)
            expectNoDifference(retried.unreadCount, 2)
        }
        if action == "members" {
            // A rejected membership save did not commit a change or revoke the
            // original membership lease; a native read may safely retry.
            _ = try await groups.updateReadState(lease, action: .read, at: now.addingTimeInterval(3))
        }
        let reopened = try GroupService(agents: agents, storeURL: file, activityDate: clock.date)
        let durable = try await reopened.unreadState(groupID: group.id), current = try await groups.unreadState(groupID: group.id)
        expectNoDifference(durable, current)
    }

    @Test(arguments: ["null", "missing-row", "orphan", "duplicate-row", "negative-count", "missing-receipts", "duplicate-receipt", "future-version"])
    func corruptCurrentBookkeepingIsRejectedWithoutResetOrOverwrite(change: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (agents, groups, group, clock) = try await fixture(root)
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(published(group))
        let file = root.appending(path: "groups.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var ledger = try #require(json["groupReadBookkeeping"] as? [String: Any])
        var records = try #require(ledger["records"] as? [[String: Any]])
        switch change {
        case "missing-row": records = []
        case "orphan": records[0]["groupID"] = UUID().uuidString
        case "duplicate-row": records.append(records[0])
        case "negative-count":
            var state = try #require(records[0]["state"] as? [String: Any]); state["unreadCount"] = -1; records[0]["state"] = state
        case "missing-receipts": records[0]["activityMessageIDs"] = nil
        case "duplicate-receipt":
            var ids = try #require(records[0]["activityMessageIDs"] as? [String]); ids.append(ids[0]); records[0]["activityMessageIDs"] = ids
        case "future-version": ledger["schemaVersion"] = 2
        default: break
        }
        ledger["records"] = records
        json["groupReadBookkeeping"] = change == "null" ? NSNull() : ledger
        let damaged = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        try damaged.write(to: file, options: .atomic)
        #expect(throws: (any Error).self) { _ = try GroupService(agents: agents, storeURL: file, activityDate: clock.date) }
        expectNoDifference(try Data(contentsOf: file), damaged)
    }

    @Test func receiptsPreventDeletedHistoryRestoreAndOlderClockReplayFromCountingAgain() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (agents, groups, group, clock) = try await fixture(root)
        let message = published(group)
        clock.set(now.addingTimeInterval(10)); try await groups.recordDelegatedMessage(message)
        clock.set(now.addingTimeInterval(5)); try await groups.recordDelegatedMessage(published(group))
        let counted = try await groups.unreadState(groupID: group.id)
        expectNoDifference(counted.unreadCount, 1)
        let file = root.appending(path: "groups.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        var saved = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: file))
        saved.roomMessages = [] // isolated historical snapshot; receipts remain
        try encode(saved, to: file)
        let reopened = try GroupService(agents: agents, storeURL: file, activityDate: clock.date)
        clock.set(now.addingTimeInterval(20)); try await reopened.recordDelegatedMessage(message)
        let restored = try await reopened.unreadState(groupID: group.id)
        expectNoDifference(restored, counted)
    }

    @Test func unreadDividerPrecedesNewestMessageAndReadTimestampsRemainMonotonic() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        var message = published(group); message = .init(id: message.id, groupID: group.id, senderID: group.memberIDs[0],
            text: message.text, createdAt: now.addingTimeInterval(50))
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(message)
        let lease = try await groups.leaseReadState(groupID: group.id); defer { lease.close() }
        _ = try await groups.updateReadState(lease, action: .read, at: now.addingTimeInterval(100))
        let unread = try await groups.updateReadState(lease, action: .unread, at: now.addingTimeInterval(200))
        #expect(unread.lastViewedAt < message.createdAt); #expect(unread.isManuallyUnread)
        let read = try await groups.updateReadState(lease, action: .read, at: now.addingTimeInterval(10))
        let older = try await groups.updateReadState(lease, action: .read, at: now.addingTimeInterval(2))
        expectNoDifference(older, read)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func nonFiniteNativeReadDatesNeverModifyTheStore(seconds: Double) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, _) = try await fixture(root)
        let lease = try await groups.leaseReadState(groupID: group.id); defer { lease.close() }
        let file = root.appending(path: "groups.json"), bytes = try Data(contentsOf: file)
        await #expect(throws: GroupReadStateError.self) {
            try await groups.updateReadState(lease, action: .unread, at: Date(timeIntervalSince1970: seconds))
        }
        expectNoDifference(try Data(contentsOf: file), bytes)
    }

    @Test func readUnknownRoomDoesNotCreateStateOrAFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let file = root.appending(path: "absent-groups.json")
        let groups = try GroupService(agents: agents, storeURL: file)
        let unknown = UUID()
        await #expect(throws: GroupReadStateError.self) { try await groups.unreadState(groupID: unknown) }
        await #expect(throws: GroupReadStateError.self) { try await groups.leaseReadState(groupID: unknown) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func backgroundSeedIsNotHumanActivityButActualGroupOutputIs() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        let scope = AgentWorkflowExecutionScope()
        let wake = GroupRoutineWake(automationID: UUID(), runID: UUID(), name: "Fixture routine", containsUntrustedEvents: false)
        clock.set(now.addingTimeInterval(1))
        _ = try await groups.postRoutineMessage("Reviewed host seed", group: group, wake: wake, lease: scope.capture(), at: now)
        let seed = try await groups.unreadState(groupID: group.id)
        expectNoDifference(seed, .init())
        clock.set(now.addingTimeInterval(2))
        _ = try await groups.run(groupID: group.id, responder: UnreadGroupResponder { _, _, publish in
            _ = try #require(try await publish(.init(text: "Actual routine publication"))); return ["PASS"]
        })
        let output = try await groups.unreadState(groupID: group.id)
        expectNoDifference(output.unreadCount, 1)
    }

    @Test func nativeReadActionsNeverAnswerPendingHumanQuestionsOrAlterGroupHistory() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        let question = try AgentQuestion.parse(Data(#"{"prompt":"Choose a fixture option","options":[{"label":"Inspect"}]}"#.utf8))
        clock.set(now.addingTimeInterval(1))
        _ = try await groups.run(groupID: group.id, responder: UnreadGroupResponder { _, _, publish in
            _ = try #require(try await publish(.init(text: question.prompt, lifetime: AgentPublicationLifetime(),
                question: .init(question: question, accountID: "fixture", memberIDs: group.memberIDs))))
            return []
        })
        let history = await groups.messages(groupID: group.id), identity = await groups.list()
        let pending = try #require(history.first?.question)
        #expect(pending.isPending)
        let lease = try await groups.leaseReadState(groupID: group.id); defer { lease.close() }
        _ = try await groups.updateReadState(lease, action: .read, at: now.addingTimeInterval(2))
        _ = try await groups.updateReadState(lease, action: .unread, at: now.addingTimeInterval(3))
        let current = try await groups.leaseReadState(groupID: group.id); defer { current.close() }
        _ = try await groups.updateReadState(current, action: .viewed(preserveManualUnread: true), at: now.addingTimeInterval(4))
        let unchanged = await groups.messages(groupID: group.id), unchangedIdentity = await groups.list()
        expectNoDifference(unchanged, history); expectNoDifference(unchangedIdentity, identity)
    }

    @Test func attachmentOnlyPublicationsCountButToolOnlyAndOutcomeRowsDoNot() throws {
        let groupID = UUID(), senderID = UUID()
        let empty = RoomMessage(groupID: groupID, senderID: senderID, text: " ", createdAt: now)
        #expect(!empty.raisesGroupActivity)
        var tool = empty; tool.toolActivities = [.init(id: "fixture", name: "fixture_read")]
        #expect(!tool.raisesGroupActivity)
        var passed = empty; passed.memberOutcome = .passed
        #expect(!passed.raisesGroupActivity)
        var failed = empty; failed.memberOutcome = .failed
        #expect(!failed.raisesGroupActivity)
        let file = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "result.txt", mimeType: "text/plain", byteCount: 20, kind: .document)
        var attached = empty; attached.files = [file]
        #expect(attached.raisesGroupActivity)
        var remote = empty; remote.remoteAttachment = try .init(url: "https://example.com/fixture", alt: "Fixture")
        #expect(remote.raisesGroupActivity)
        var image = empty; image.images = [.init(id: String(repeating: "b", count: 64), filename: "result.png", mimeType: "image/png", byteCount: 20, kind: .image)]
        #expect(image.raisesGroupActivity)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func invalidArrivalClockRollsBackWithoutConsumingTheMessage(seconds: Double) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let (_, groups, group, clock) = try await fixture(root)
        let message = published(group), file = root.appending(path: "groups.json")
        let bytes = try Data(contentsOf: file)
        clock.set(Date(timeIntervalSince1970: seconds))
        await #expect(throws: GroupReadStateError.self) { try await groups.recordDelegatedMessage(message) }
        let failed = try await groups.unreadState(groupID: group.id), failedHistory = await groups.messages(groupID: group.id)
        expectNoDifference(failed, .init()); expectNoDifference(failedHistory, [])
        expectNoDifference(try Data(contentsOf: file), bytes)
        clock.set(now.addingTimeInterval(1)); try await groups.recordDelegatedMessage(message)
        let retried = try await groups.unreadState(groupID: group.id)
        expectNoDifference(retried.unreadCount, 1)
    }
}
