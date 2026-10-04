import Foundation
import Testing
import CustomDump
import CSQLite
import FiliconDomain
import FiliconPersistence
import FiliconAppServices

@Suite("Canonical conversation unread state")
struct ConversationUnreadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private var binding: DirectConversationAgentBinding { .init(accountID: "fixture", agentID: id(1)) }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "filicon-unread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func chat(_ n: Int = 10) -> Conversation {
        var value = Conversation(id: id(n), title: "Isolated unread fixture", messages: [], updatedAt: now)
        value.agentBinding = binding
        return value
    }
    private func message(_ n: Int = 20, status: MessageDeliveryStatus = .succeeded) -> ChatMessage {
        .init(id: id(n), role: .assistant, text: "Published result", createdAt: now, deliveryStatus: status)
    }
    private func sql(_ statement: String, at url: URL) throws {
        var handle: OpaquePointer?
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        try #require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
    }

    private func activityPublication(answer: AutomationActivityTranscriptAnswer? = nil) -> AutomationActivityTranscriptPublication {
        .init(card: .init(entryID: id(1001), guardID: id(1002), binding: binding, conversationID: id(10),
            isPaused: true, answer: answer), createdAt: now.addingTimeInterval(1),
            answeredAt: answer == nil ? nil : now.addingTimeInterval(2), acknowledgmentID: id(1003))
    }

    @Test func activityEntriesPreserveCanonicalHistoryReactionsSearchAndUnreadOnReplay() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        var value = chat()
        value.messages = (0..<120).map { message(2000 + $0) }
        DirectMessageAddressing.assignMissing(in: &value)
        try await store.upsert(value, replacingLoadedMessageIDs: [], historyComplete: true, activityAt: now)
        let lease = try await store.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: value.id)
        defer { lease.close() }
        let issued = try await store.publishAutomationActivity(activityPublication(), expectedHiddenAt: nil,
            activityAt: now.addingTimeInterval(1), commit: { try lease.withValidBinding($0) })
        expectNoDifference(issued.messages.count, 121)
        expectNoDifference(Array(issued.messages.prefix(120)), value.messages)
        let issuedUnread = try await store.unreadState(conversationID: value.id)
        expectNoDifference(issuedUnread?.unreadCount, 121)
        _ = try await store.updateReadState(conversationID: value.id, action: .read, at: now.addingTimeInterval(1.5), expectedBinding: binding)
        var changed = issued
        changed.messages[120].reactions = [.init(emoji: "👍", actorID: "human")]
        changed.messages[0].text = "Latest canonical edit, not a paged snapshot"
        try await store.upsert(changed, replacingLoadedMessageIDs: Set(issued.messages.map(\.id)), historyComplete: true)
        let answered = try await store.publishAutomationActivity(activityPublication(answer: .resume), expectedHiddenAt: nil,
            activityAt: now.addingTimeInterval(2), commit: { try lease.withValidBinding($0) })
        expectNoDifference(answered.messages.count, 122)
        expectNoDifference(answered.messages[0], changed.messages[0])
        expectNoDifference(answered.messages[120].reactions, changed.messages[120].reactions)
        expectNoDifference(answered.messages[120].shortAddress, issued.messages[120].shortAddress)
        expectNoDifference(answered.messages.last?.role, .system)
        let state = try await store.unreadState(conversationID: value.id)
        expectNoDifference(state?.unreadCount, 0)
        let page = try await store.messagePage(conversationID: value.id, limit: 100)
        #expect(page.continuation != nil)
        let reopened = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let replay = try await reopened.publishAutomationActivity(activityPublication(answer: .resume), expectedHiddenAt: nil,
            activityAt: now.addingTimeInterval(100))
        expectNoDifference(replay, answered)
        let replayUnread = try await reopened.unreadState(conversationID: value.id)
        expectNoDifference(replayUnread, state)
        let searchRepository = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        let search = try await searchRepository.searchMessages("resumed")
        expectNoDifference(search.map(\.messageID), [id(1003)])
    }

    @Test func activityReceiptFailureRollsBackThePromptUpdateAndAcknowledgmentTogether() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.sqlite3")
        let repo = try ConversationRepository(databaseURL: file)
        try await repo.save([chat()], activityAt: now)
        let issued = try await repo.publishAutomationActivity(activityPublication(), expectedHiddenAt: nil, activityAt: now.addingTimeInterval(1))
        let unread = try await repo.unreadState(conversationID: issued.id)
        try sql("CREATE TRIGGER reject_activity_ack BEFORE INSERT ON messages WHEN NEW.role='system' BEGIN SELECT RAISE(ABORT,'isolated acknowledgment failure'); END", at: file)
        await #expect(throws: (any Error).self) {
            try await repo.publishAutomationActivity(activityPublication(answer: .resume), expectedHiddenAt: nil, activityAt: now.addingTimeInterval(2))
        }
        let failed = try #require(try await repo.conversation(id: issued.id))
        let failedUnread = try await repo.unreadState(conversationID: issued.id)
        expectNoDifference(failed, issued); expectNoDifference(failedUnread, unread)
        try sql("DROP TRIGGER reject_activity_ack", at: file)
        let recovered = try await repo.publishAutomationActivity(activityPublication(answer: .resume), expectedHiddenAt: nil, activityAt: now.addingTimeInterval(2))
        expectNoDifference(recovered.messages.map(\.id), [id(1001), id(1003)])
    }

    @Test(arguments: [0.000001, 0.123456789, 0.333333333, 0.9999999])
    func activityEntriesCanBeAnsweredAfterFractionalTimestampsRoundTrip(fraction: Double) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        try await repo.save([chat()], activityAt: now)
        let metadata = activityPublication().card
        let issuedAt = now.addingTimeInterval(fraction)
        _ = try await repo.publishAutomationActivity(.init(card: metadata, createdAt: issuedAt, answeredAt: nil,
            acknowledgmentID: id(1003)), expectedHiddenAt: nil, activityAt: issuedAt)
        let answered = AutomationActivityTranscriptCard(entryID: metadata.entryID, guardID: metadata.guardID,
            binding: binding, conversationID: metadata.conversationID, isPaused: true, answer: .resume)
        let resumed = try await repo.publishAutomationActivity(.init(card: answered, createdAt: issuedAt,
            answeredAt: now.addingTimeInterval(2 + fraction), acknowledgmentID: id(1003)), expectedHiddenAt: nil, activityAt: issuedAt)
        expectNoDifference(resumed.messages.map(\.id), [id(1001), id(1003)])
    }

    @Test(arguments: ["human-collision", "foreign-collision", "wrong-answer", "closed-lease", "hidden", "duplicate", "rebound"])
    func hostActivityPublicationCannotOverwriteOrCrossAnOwnershipBoundary(change: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat(); var values = [value]
        if change == "human-collision" { value.messages = [message(1001)]; values = [value] }
        if change == "foreign-collision" {
            var other = chat(11); other.agentBinding = .init(accountID: "other", agentID: id(2)); other.messages = [message(1001)]
            values.append(other)
        }
        try await repo.save(values, activityAt: now)
        let lease = try await repo.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: value.id)
        defer { lease.close() }
        var publication = activityPublication()
        switch change {
        case "wrong-answer": publication = activityPublication(answer: .keep)
        case "closed-lease": lease.close()
        case "hidden": value.hiddenAt = now; try await repo.save([value], activityAt: now)
        case "duplicate": try await repo.save([value, chat(11)], activityAt: now)
        case "rebound": value.agentBinding = .init(accountID: "other", agentID: id(2)); try await repo.save([value], activityAt: now)
        default: break
        }
        let before = try await repo.load(), unread = try await repo.unreadState(conversationID: value.id)
        await #expect(throws: (any Error).self) {
            try await repo.publishAutomationActivity(publication, expectedHiddenAt: nil, activityAt: now.addingTimeInterval(1),
                commit: { try lease.withValidBinding($0) })
        }
        let after = try await repo.load(), afterUnread = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(after, before); expectNoDifference(afterUnread, unread)
    }

    @Test func liveUnreadObservationTracksOnlyDurableReadAndArrivalPublications() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat(); value.messages = [message()]
        try await repo.save([value], activityAt: now)
        let observation = try #require(try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID))
        expectNoDifference(try observation.withReadState { $0 }, .init(lastActivityAt: now, unreadCount: 1))
        let read = try await repo.updateReadState(conversationID: value.id, action: .read,
            at: now.addingTimeInterval(1), expectedBinding: binding)
        expectNoDifference(try observation.withReadState { $0 }, read)
        value.messages.append(message(21))
        try await repo.save([value], activityAt: now.addingTimeInterval(2))
        let arrival = try #require(try await repo.unreadState(conversationID: value.id))
        expectNoDifference(try observation.withReadState { $0 }, arrival)
        expectNoDifference(arrival.unreadCount, 1)
        let manual = try await repo.updateReadState(conversationID: value.id, action: .unread,
            at: now.addingTimeInterval(3), expectedBinding: binding)
        expectNoDifference(try observation.withReadState { $0 }, manual)
        _ = try await repo.updateReadState(conversationID: value.id, action: .viewed(preserveManualUnread: true),
            at: now.addingTimeInterval(4), expectedBinding: binding)
        expectNoDifference(try observation.withReadState { $0 }, manual)
    }

    @Test(arguments: ["rebind-cycle", "duplicate", "delete", "hide"])
    func liveUnreadObservationCannotSurviveOwnerOrUniquenessRevocation(change: String) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat(); value.messages = [message()]
        try await repo.save([value], activityAt: now)
        let observation = try #require(try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID))
        switch change {
        case "rebind-cycle":
            value.agentBinding = .init(accountID: "other", agentID: id(2))
            try await repo.save([value], activityAt: now.addingTimeInterval(1))
            value.agentBinding = binding
            try await repo.save([value], activityAt: now.addingTimeInterval(2))
        case "duplicate": try await repo.save([value, chat(11)], activityAt: now.addingTimeInterval(1))
        case "delete": try await repo.delete(id: value.id)
        case "hide": value.hiddenAt = now; try await repo.save([value], activityAt: now.addingTimeInterval(1))
        default: break
        }
        expectNoDifference(observation.isActive, false)
        #expect(throws: CancellationError.self) { try observation.withReadState { $0 } }
    }

    @Test func aFailedSQLPublicationKeepsEveryLiveUnreadProjectionUnchanged() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        var peer = chat(11); peer.agentBinding = .init(accountID: "peer", agentID: id(2)); peer.messages = [message(22)]
        try await repo.save([value, peer], activityAt: now)
        let first = try #require(try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID))
        let second = try #require(try await repo.observeUniqueUnreadState(accountID: "peer", agentID: id(2)))
        let sameOwner = try #require(try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID))
        expectNoDifference(first === sameOwner, true)
        let before = try first.withReadState { $0 }
        try sql("CREATE TRIGGER reject_read_publication BEFORE UPDATE ON conversation_read_state BEGIN SELECT RAISE(ABORT, 'fixture failure'); END", at: url)
        await #expect(throws: (any Error).self) {
            try await repo.updateReadState(conversationID: value.id, action: .read, at: now.addingTimeInterval(1), expectedBinding: binding)
        }
        value.messages.append(message(21))
        await #expect(throws: (any Error).self) { try await repo.save([value, peer], activityAt: now.addingTimeInterval(2)) }
        expectNoDifference(try first.withReadState { $0 }, before)
        expectNoDifference(try second.withReadState { $0 }, before)
        let durable = try await repo.unreadState(conversationID: value.id), content = try await repo.load()
        expectNoDifference(durable, before)
        expectNoDifference(content.first { $0.id == value.id }?.messages.map(\.id), [id(20)])
    }

    @Test(arguments: ["manual", "same", "older"], [true, false])
    func unchangedAutomaticViewsDoNotWriteReadState(reason: String, isBound: Bool) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        if !isBound { value.agentBinding = nil }
        var peer = chat(11); peer.agentBinding = .init(accountID: "peer", agentID: id(2)); peer.messages = [message(22)]
        try await repo.save([value, peer], activityAt: now)
        let owner = value.agentBinding, viewedAt = now.addingTimeInterval(5)
        _ = try await repo.updateReadState(conversationID: value.id,
            action: reason == "manual" ? .unread : .read, at: viewedAt, expectedBinding: owner)
        let before = try #require(try await repo.unreadState(conversationID: value.id))
        let content = try await repo.load()
        var ownObservation: ConversationUnreadObservation?
        if isBound {
            let observation = try #require(try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID))
            ownObservation = observation
        }
        let peerObservation = try #require(try await repo.observeUniqueUnreadState(accountID: "peer", agentID: id(2)))
        let peerBefore = try peerObservation.withReadState { $0 }
        try sql("CREATE TRIGGER reject_noop_read_write BEFORE UPDATE ON conversation_read_state BEGIN SELECT RAISE(ABORT, 'isolated read write failure'); END", at: url)
        let at = reason == "manual" ? now.addingTimeInterval(10)
            : (reason == "same" ? viewedAt : viewedAt.addingTimeInterval(-1))
        let unchanged = try await repo.updateReadState(conversationID: value.id,
            action: .viewed(preserveManualUnread: true), at: at, expectedBinding: owner)
        expectNoDifference(unchanged, before)

        // A changed view and explicit human choices still use the durable write
        // path; ignoring all persistence errors would incorrectly pass the no-op.
        for action in [ConversationReadAction.viewed(preserveManualUnread: false), .read, .unread] {
            await #expect(throws: PersistenceError.self) {
                try await repo.updateReadState(conversationID: value.id, action: action,
                    at: now.addingTimeInterval(20), expectedBinding: owner)
            }
        }
        let durable = try await repo.unreadState(conversationID: value.id), afterContent = try await repo.load()
        expectNoDifference(durable, before); expectNoDifference(afterContent, content)
        if let ownObservation { expectNoDifference(try ownObservation.withReadState { $0 }, before) }
        expectNoDifference(try peerObservation.withReadState { $0 }, peerBefore)
        try sql("DROP TRIGGER reject_noop_read_write", at: url)
        let retried = try await repo.updateReadState(conversationID: value.id,
            action: .viewed(preserveManualUnread: false), at: now.addingTimeInterval(20), expectedBinding: owner)
        expectNoDifference(retried, .init(lastActivityAt: now, lastViewedAt: now.addingTimeInterval(20)))
        if let ownObservation { expectNoDifference(try ownObservation.withReadState { $0 }, retried) }
        expectNoDifference(try peerObservation.withReadState { $0 }, peerBefore)
        let reopened = try ConversationRepository(databaseURL: url)
        let reopenedState = try await reopened.unreadState(conversationID: value.id)
        let reopenedContent = try await reopened.load()
        expectNoDifference(reopenedState, retried); expectNoDifference(reopenedContent, content)
    }

    enum AutomaticViewRejection: Sendable, CaseIterable {
        case closedLease, rebindCycle, wrongBinding, rejectedHost, missing, invalid, deleted
        case notANumber, positiveInfinity, negativeInfinity
    }

    @Test(arguments: AutomaticViewRejection.allCases)
    func unchangedViewsStillRequireOriginalAuthorityAndValidCanonicalState(reason: AutomaticViewRejection) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        var peer = chat(11); peer.agentBinding = .init(accountID: "peer", agentID: id(2)); peer.messages = [message(22)]
        try await repo.save([value, peer], activityAt: now)
        let manual = try await repo.updateReadState(conversationID: value.id,
            action: .unread, at: now.addingTimeInterval(5), expectedBinding: binding)
        let observation = try #require(try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID))
        let peerObservation = try #require(try await repo.observeUniqueUnreadState(accountID: "peer", agentID: id(2)))
        let peerBefore = try peerObservation.withReadState { $0 }
        let lease = try await repo.leaseUniqueBinding(accountID: binding.accountID, agentID: binding.agentID, conversationID: value.id)
        defer { lease.close() }
        var expectedBinding: DirectConversationAgentBinding? = binding
        var at = now.addingTimeInterval(10)
        switch reason {
        case .closedLease: lease.close()
        case .rebindCycle:
            value.agentBinding = .init(accountID: "other", agentID: id(2))
            try await repo.save([value, peer], activityAt: now.addingTimeInterval(1))
            value.agentBinding = binding
            try await repo.save([value, peer], activityAt: now.addingTimeInterval(2))
            at = Date(timeIntervalSince1970: 0)
        case .wrongBinding: expectedBinding = nil
        case .missing: try sql("DELETE FROM conversation_read_state WHERE conversation_id='\(value.id.uuidString)'", at: url)
        case .invalid:
            try sql("PRAGMA ignore_check_constraints=1; UPDATE conversation_read_state SET unread_count=-1 WHERE conversation_id='\(value.id.uuidString)'; PRAGMA ignore_check_constraints=0", at: url)
        case .deleted: try await repo.delete(id: value.id)
        case .notANumber: at = Date(timeIntervalSince1970: .nan)
        case .positiveInfinity: at = Date(timeIntervalSince1970: .infinity)
        case .negativeInfinity: at = Date(timeIntervalSince1970: -.infinity)
        case .rejectedHost: break
        }
        let contentBefore = try await repo.load()
        let damaged = reason == .missing || reason == .invalid
        let stateBefore = damaged ? nil : try await repo.unreadState(conversationID: value.id)
        let commit: ConversationCommitGuard = { operation in
            guard reason != .rejectedHost else { throw CancellationError() }
            try lease.withValidBinding(operation)
        }
        switch reason {
        case .missing, .invalid, .notANumber, .positiveInfinity, .negativeInfinity:
            await #expect(throws: PersistenceError.self) {
                try await repo.updateReadState(conversationID: value.id, action: .viewed(preserveManualUnread: true),
                    at: at, expectedBinding: expectedBinding, commit: commit)
            }
        default:
            await #expect(throws: CancellationError.self) {
                try await repo.updateReadState(conversationID: value.id, action: .viewed(preserveManualUnread: true),
                    at: at, expectedBinding: expectedBinding, commit: commit)
            }
        }
        let contentAfter = try await repo.load()
        expectNoDifference(contentAfter, contentBefore)
        if damaged {
            await #expect(throws: PersistenceError.self) { try await repo.unreadState(conversationID: value.id) }
        } else {
            let stateAfter = try await repo.unreadState(conversationID: value.id)
            expectNoDifference(stateAfter, stateBefore)
        }
        if reason == .rebindCycle || reason == .deleted {
            expectNoDifference(observation.isActive, false)
            #expect(throws: CancellationError.self) { try observation.withReadState { $0 } }
        } else {
            expectNoDifference(try observation.withReadState { $0 }, manual)
        }
        expectNoDifference(try peerObservation.withReadState { $0 }, peerBefore)
    }

    @Test func canonicalObservationRejectsMissingStateInsteadOfInventingAnEmptyChat() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        try await repo.save([chat()], activityAt: now)
        try sql("DELETE FROM conversation_read_state", at: url)
        await #expect(throws: PersistenceError.self) { try await repo.observeUniqueUnreadState(accountID: binding.accountID, agentID: binding.agentID) }
        let absent = try await repo.observeUniqueUnreadState(accountID: "absent", agentID: binding.agentID)
        expectNoDifference(absent == nil, true)
    }

    @Test func manualUnreadSurvivesAutomaticViewsAndExplicitReadIsMonotonic() {
        var state = ConversationUnreadState()
        state.markActivity(at: now, count: 2)
        state.markViewed(at: now.addingTimeInterval(1))
        state.markUnread(at: now.addingTimeInterval(2), newestMessageAt: now)
        let manual = state
        state.markViewed(at: now.addingTimeInterval(3), preserveManualUnread: true)
        expectNoDifference(state, manual)
        expectNoDifference(state.isManuallyUnread, true)
        expectNoDifference(state.unreadCount, 1)
        expectNoDifference(state.lastViewedAt, now.addingTimeInterval(-0.001))
        state.markRead(at: now.addingTimeInterval(4))
        let read = state
        state.markRead(at: now)
        expectNoDifference(state, read)
        expectNoDifference(read, .init(lastActivityAt: now, lastViewedAt: now.addingTimeInterval(4)))
    }

    @Test func delayedActivityAndViewsCannotRegressOrOverflow() {
        var state = ConversationUnreadState(unreadCount: Int.max - 1)
        state.markActivity(at: now, count: 2)
        expectNoDifference(state.unreadCount, Int.max)
        let current = state
        state.markActivity(at: now, count: 2)
        state.markActivity(at: now.addingTimeInterval(-1))
        state.markActivity(at: Date(timeIntervalSince1970: .infinity))
        state.markViewed(at: Date(timeIntervalSince1970: .nan))
        expectNoDifference(state, current)
        state.markViewed(at: now.addingTimeInterval(5))
        let read = state
        state.markViewed(at: now)
        expectNoDifference(state, read)
    }

    @Test func codecRejectsInvalidCountersAndNonpreservingViewsStayMonotonic() throws {
        let state = ConversationUnreadState(lastActivityAt: now, lastViewedAt: now.addingTimeInterval(5),
            isManuallyUnread: true, unreadCount: 3)
        let encoded = try JSONEncoder().encode(state)
        expectNoDifference(try JSONDecoder().decode(ConversationUnreadState.self, from: encoded), state)
        var object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unreadCount"] = -1
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ConversationUnreadState.self, from: invalid) }
        var viewed = state
        viewed.markViewed(at: now, preserveManualUnread: false)
        expectNoDifference(viewed, .init(lastActivityAt: now, lastViewedAt: now.addingTimeInterval(5)))
    }

    @Test func canonicalPublicationAndReadMarkerPersistWithoutTouchingContent() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        try await repo.save([value], activityAt: now)
        let initial = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(initial, .init(lastActivityAt: now, unreadCount: 1))
        let manual = try await repo.updateReadState(conversationID: value.id, action: .unread,
            at: now.addingTimeInterval(1), expectedBinding: binding)
        try await repo.save([value], activityAt: now.addingTimeInterval(2))
        let reopened = try ConversationRepository(databaseURL: url)
        let saved = try await reopened.unreadState(conversationID: value.id), content = try await reopened.load()
        expectNoDifference(saved, manual); expectNoDifference(content, [value])
        let viewed = try await reopened.updateReadState(conversationID: value.id, action: .viewed(preserveManualUnread: true),
            at: now.addingTimeInterval(3), expectedBinding: binding)
        expectNoDifference(viewed, manual)
        let read = try await reopened.updateReadState(conversationID: value.id, action: .read,
            at: now.addingTimeInterval(4), expectedBinding: binding)
        expectNoDifference(read, .init(lastActivityAt: now, lastViewedAt: now.addingTimeInterval(4)))
    }

    @Test func streamCompletionCountsOnceAndRestoredMessageIDsCannotCountAgain() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat(); value.messages = [message(status: .streaming)]
        try await repo.save([value], activityAt: now)
        let streaming = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(streaming, .init())
        value.messages[0].text += " completed"; value.messages[0].deliveryStatus = .succeeded
        try await repo.save([value], activityAt: now.addingTimeInterval(1))
        let completed = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(completed, .init(lastActivityAt: now.addingTimeInterval(1), unreadCount: 1))
        value.messages[0].text += " edited"; value.messages[0].reactions = [.init(emoji: "👍", actorID: "fixture")]
        try await repo.save([value], activityAt: now.addingTimeInterval(2))
        let savedMessage = value.messages.removeFirst()
        try await repo.save([value], activityAt: now.addingTimeInterval(3))
        value.messages = [savedMessage]
        try await repo.save([value], activityAt: now.addingTimeInterval(4))
        let restored = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(restored, completed)
    }

    @Test func incomingPeersAndPrivateOrUnfinishedRowsAreNotUserActivity() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat()
        var incoming = message(23)
        incoming.agentMessageSource = try .init(accountID: binding.accountID, originConversationID: id(30),
            deliveryID: id(31), senderAgentID: id(2), recipientAgentID: binding.agentID, kind: .incoming)
        value.messages = [message(20, status: .queued), message(21, status: .failed), message(22, status: .cancelled),
            incoming, .init(id: id(24), role: .tool, text: "Tool detail", createdAt: now),
            .init(id: id(25), role: .system, text: "Host state", createdAt: now),
            .init(id: id(26), role: .assistant, text: "", createdAt: now)]
        try await repo.save([value], activityAt: now)
        let excluded = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(excluded, .init())
        var own = message(27); own.agentMessageSource = try .init(accountID: binding.accountID,
            originConversationID: id(30), deliveryID: id(31), senderAgentID: id(2), recipientAgentID: binding.agentID, kind: .publication)
        value.messages.append(own)
        value.messages.append(.init(id: id(28), role: .user, text: "Human message", createdAt: now))
        try await repo.save([value], activityAt: now.addingTimeInterval(1))
        let published = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(published, .init(lastActivityAt: now.addingTimeInterval(1), unreadCount: 2))
    }

    @Test func bindingChangesCannotTransferManualUnreadOrOldContentToTheNewOwner() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat(); value.messages = [message()]
        try await repo.save([value], activityAt: now)
        _ = try await repo.updateReadState(conversationID: value.id, action: .unread, at: now, expectedBinding: binding)
        value.agentBinding = .init(accountID: "other-fixture", agentID: id(2))
        try await repo.save([value], activityAt: now.addingTimeInterval(1))
        let rebound = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(rebound, .init())
        await #expect(throws: CancellationError.self) {
            try await repo.updateReadState(conversationID: value.id, action: .read, at: now, expectedBinding: binding)
        }
        value.messages.append(message(21))
        try await repo.save([value], activityAt: now.addingTimeInterval(2))
        let arrival = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(arrival, .init(lastActivityAt: now.addingTimeInterval(2), unreadCount: 1))
    }

    @Test func aReadFenceRejectionAndDatabaseFailureAreAtomic() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); try await repo.save([value], activityAt: now)
        await #expect(throws: CancellationError.self) {
            try await repo.updateReadState(conversationID: value.id, action: .unread, at: now,
                expectedBinding: binding, commit: { _ in throw CancellationError() })
        }
        let rejected = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(rejected, .init())
        try sql("CREATE TRIGGER reject_unread BEFORE UPDATE ON conversation_read_state BEGIN SELECT RAISE(ABORT,'isolated unread write denied'); END", at: url)
        value.messages = [message()]
        await #expect(throws: PersistenceError.self) { try await repo.save([value], activityAt: now) }
        let stored = try #require(try await repo.conversation(id: value.id))
        expectNoDifference(stored.messages, [])
        let failed = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(failed, .init())
        try sql("DROP TRIGGER reject_unread", at: url)
        try await repo.save([value], activityAt: now)
        let retried = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(retried, .init(lastActivityAt: now, unreadCount: 1))
    }

    @Test func migrationAndHistoricalImportDoNotInventUnreadArrivals() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        try await repo.save([value], activityAt: now, historicalImport: true)
        let imported = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(imported, .init())
        try sql("DROP TABLE conversation_read_state; DROP TABLE conversation_activity_receipts; UPDATE schema_version SET version=16", at: url)
        let migrated = try ConversationRepository(databaseURL: url)
        let schema = try await migrated.schemaVersion(), migratedState = try await migrated.unreadState(conversationID: value.id)
        expectNoDifference(schema, 17); expectNoDifference(migratedState, .init())
        try await migrated.save([value], activityAt: now.addingTimeInterval(1))
        let unchanged = try await migrated.unreadState(conversationID: value.id)
        expectNoDifference(unchanged, .init())
        value.messages.append(message(21))
        try await migrated.save([value], activityAt: now.addingTimeInterval(2))
        let arrival = try await migrated.unreadState(conversationID: value.id)
        expectNoDifference(arrival, .init(lastActivityAt: now.addingTimeInterval(2), unreadCount: 1))
    }

    @Test func deletionCannotReviveReadMarkersAndOtherChatsStayIsolated() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var first = chat(), second = chat(11); first.messages = [message()]; second.messages = [message(21)]
        try await repo.save([first, second], activityAt: now)
        let peerBefore = try await repo.unreadState(conversationID: second.id)
        _ = try await repo.updateReadState(conversationID: first.id, action: .unread, at: now, expectedBinding: binding)
        let peerAfter = try await repo.unreadState(conversationID: second.id)
        expectNoDifference(peerAfter, peerBefore)
        try await repo.delete(id: first.id)
        let deleted = try await repo.unreadState(conversationID: first.id)
        expectNoDifference(deleted, nil)
        var handle: OpaquePointer?
        let url = root.appending(path: "conversations.sqlite3")
        try #require(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var rows: OpaquePointer?
        try #require(sqlite3_prepare_v2(handle, "SELECT (SELECT COUNT(*) FROM conversation_read_state WHERE conversation_id=?1)+(SELECT COUNT(*) FROM conversation_activity_receipts WHERE conversation_id=?1)", -1, &rows, nil) == SQLITE_OK)
        defer { sqlite3_finalize(rows) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try #require(sqlite3_bind_text(rows, 1, first.id.uuidString, -1, transient) == SQLITE_OK)
        try #require(sqlite3_step(rows) == SQLITE_ROW)
        expectNoDifference(sqlite3_column_int(rows, 0), 0)
        await #expect(throws: CancellationError.self) {
            try await repo.updateReadState(conversationID: first.id, action: .unread, at: now, expectedBinding: binding)
        }
    }

    @Test func missingReadAuthorityCannotBeInventedByALiveReadOrContentSave() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); try await repo.save([value], activityAt: now)
        try sql("DELETE FROM conversation_read_state WHERE conversation_id='\(value.id.uuidString)'", at: url)
        await #expect(throws: PersistenceError.self) { try await repo.unreadState(conversationID: value.id) }
        await #expect(throws: PersistenceError.self) {
            try await repo.updateReadState(conversationID: value.id, action: .read, at: now, expectedBinding: binding)
        }
        value.messages = [message()]
        await #expect(throws: PersistenceError.self) { try await repo.save([value], activityAt: now.addingTimeInterval(1)) }
        let content = try #require(try await repo.conversation(id: value.id))
        expectNoDifference(content.messages, [])
    }

    enum ReadDamage: Sendable { case invalid, missing }
    @Test(arguments: [ReadDamage.invalid, .missing])
    func damagedReadAuthorityIsQuarantinedAndNeverRecoveredAsRead(_ damage: ReadDamage) async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        try await repo.save([value], activityAt: now)
        switch damage {
        case .invalid:
            try sql("PRAGMA ignore_check_constraints=1; UPDATE conversation_read_state SET unread_count=-1; PRAGMA ignore_check_constraints=0", at: url)
        case .missing: try sql("DELETE FROM conversation_read_state", at: url)
        }
        let reopened = try ConversationRepository(databaseURL: url)
        let report = try #require(reopened.initialRecoveryReport)
        expectNoDifference(report.kind, .salvaged)
        #expect(report.rejectedRows.contains { $0.table == "conversation_read_state" && $0.rowIdentifier == value.id.uuidString })
        let quarantine = URL(fileURLWithPath: try #require(report.quarantineDirectory))
        #expect(FileManager.default.fileExists(atPath: quarantine.appending(path: "conversations.sqlite3").path))
        let state = try await reopened.unreadState(conversationID: value.id), content = try await reopened.load()
        expectNoDifference(state, .init(isManuallyUnread: true, unreadCount: 1))
        expectNoDifference(content, [value])
        let automatic = try await reopened.updateReadState(conversationID: value.id,
            action: .viewed(preserveManualUnread: true), at: now.addingTimeInterval(1), expectedBinding: binding)
        expectNoDifference(automatic, state)
    }

    @Test func salvagePreservesManualUnreadAndDeletedOrRejectedMessageReceipts() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), repo = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message(20), message(21), message(22)]
        let deleted = value.messages[0], rejected = value.messages[1]
        try await repo.save([value], activityAt: now)
        let manual = try await repo.updateReadState(conversationID: value.id, action: .unread, at: now, expectedBinding: binding)
        value.messages.removeFirst()
        try await repo.save([value], activityAt: now.addingTimeInterval(1))
        try sql("UPDATE messages SET attachments_json='{' WHERE id='\(rejected.id.uuidString)'", at: url)
        let reopened = try ConversationRepository(databaseURL: url)
        let report = try #require(reopened.initialRecoveryReport)
        expectNoDifference(report.kind, .salvaged)
        var restored = try #require(try await reopened.conversation(id: value.id))
        expectNoDifference(restored.messages, [value.messages[1]])
        let state = try await reopened.unreadState(conversationID: value.id)
        expectNoDifference(state, manual)
        restored.messages.append(contentsOf: [deleted, rejected])
        try await reopened.save([restored], activityAt: now.addingTimeInterval(2))
        let repeated = try await reopened.unreadState(conversationID: value.id)
        expectNoDifference(repeated, manual)
    }

    @Test func exactUnboundOrBoundReadOwnerIsRequired() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var unbound = chat(11); unbound.agentBinding = nil
        let bound = chat()
        try await repo.save([unbound, bound], activityAt: now)
        _ = try await repo.updateReadState(conversationID: unbound.id, action: .unread, at: now, expectedBinding: nil)
        await #expect(throws: CancellationError.self) {
            try await repo.updateReadState(conversationID: bound.id, action: .read, at: now, expectedBinding: nil)
        }
        await #expect(throws: CancellationError.self) {
            try await repo.updateReadState(conversationID: unbound.id, action: .read, at: now, expectedBinding: binding)
        }
        let state = try await repo.unreadState(conversationID: unbound.id)
        expectNoDifference(state, .init(lastActivityAt: now, lastViewedAt: Date(timeIntervalSince1970: 0),
            isManuallyUnread: true, unreadCount: 1))
    }

    @Test func canonicalSecretRequestIsActivityButForeignOrBookkeepingCardsAreNot() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat()
        let request = try AgentSecretRequest.parse(Data(#"{"label":"Isolated fixture token","connector":"slack","field":"token"}"#.utf8))
        func secret(_ n: Int, conversationID: UUID, owner: DirectConversationAgentBinding) -> ChatMessage {
            let metadata = DirectSecretRequest(requestID: id(n + 100), request: request, binding: owner,
                conversationID: conversationID, connectionID: id(200))
            var message = ChatMessage(id: id(n), role: .assistant, text: "", createdAt: now)
            message.transcriptCards = [.init(id: metadata.requestID, lifecycle: .waiting,
                payload: .secretRequest(.init(requestID: metadata.requestID.uuidString, service: "slack", directRequest: metadata)))]
            return message
        }
        var bookkeeping = ChatMessage(id: id(24), role: .assistant, text: "", createdAt: now)
        bookkeeping.transcriptCards = [.init(id: id(124), lifecycle: .succeeded,
            payload: .unknown(type: "fixture-bookkeeping", payload: .object([:])))]
        value.messages = [secret(20, conversationID: value.id, owner: binding),
            secret(21, conversationID: id(11), owner: binding),
            secret(22, conversationID: value.id, owner: .init(accountID: "other-fixture", agentID: binding.agentID)), bookkeeping]
        try await repo.save([value], activityAt: now)
        let state = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(state, .init(lastActivityAt: now, unreadCount: 1))
    }

    @Test func importedUnfinishedDraftIsNotAnOldPublishedReceipt() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let repo = try ConversationRepository(databaseURL: root.appending(path: "conversations.sqlite3"))
        var value = chat(); value.messages = [message(20), message(21, status: .streaming)]
        try await repo.save([value], activityAt: now, historicalImport: true)
        value.messages[1].deliveryStatus = .succeeded
        try await repo.save([value], activityAt: now.addingTimeInterval(1))
        let state = try await repo.unreadState(conversationID: value.id)
        expectNoDifference(state, .init(lastActivityAt: now.addingTimeInterval(1), unreadCount: 1))
    }

    @Test func legacyStoreImportAndPagedResavePreserveCanonicalReadAuthority() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.json")
        var value = chat(); value.messages = [message(20), message(21)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode([value]).write(to: url, options: .atomic)
        let store = ConversationStore(fileURL: url)
        let loaded = try await store.load(), imported = try await store.unreadState(conversationID: value.id)
        expectNoDifference(loaded, [value]); expectNoDifference(imported, .init())
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "conversations.json.migrated-backup").path))
        let page = try await store.messagePage(conversationID: value.id, limit: 1)
        var paged = value; paged.messages = page.items
        try await store.upsert(paged, replacingLoadedMessageIDs: Set(page.items.map(\.id)), historyComplete: false, activityAt: now)
        let resaved = try await store.unreadState(conversationID: value.id)
        expectNoDifference(resaved, .init())
        let manual = try await store.updateReadState(conversationID: value.id, action: .unread, at: now, expectedBinding: binding)
        paged.messages.append(message(22))
        try await store.upsert(paged, replacingLoadedMessageIDs: Set(page.items.map(\.id)), historyComplete: false,
            expectedBinding: binding, activityAt: now.addingTimeInterval(1))
        let state = try await store.unreadState(conversationID: value.id), canonical = try await store.conversation(id: value.id)
        expectNoDifference(state, .init(lastActivityAt: now.addingTimeInterval(1), lastViewedAt: manual.lastViewedAt,
            isManuallyUnread: true, unreadCount: 2))
        expectNoDifference(canonical?.messages.map(\.id), [id(20), id(21), id(22)])
        let reopened = ConversationStore(fileURL: url)
        let reopenedState = try await reopened.unreadState(conversationID: value.id)
        expectNoDifference(reopenedState, state)
    }

    @Test func peerRepositoryContentSavesCannotOverwriteReadStateAndReadTimesOnlyAdvance() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "conversations.sqlite3"), first = try ConversationRepository(databaseURL: url)
        var value = chat(); value.messages = [message()]
        try await first.save([value], activityAt: now)
        let peer = try ConversationRepository(databaseURL: url)
        let conversationID = value.id, owner = binding
        let earlierDate = now.addingTimeInterval(1), laterDate = now.addingTimeInterval(2)
        async let older: ConversationUnreadState = first.updateReadState(conversationID: conversationID, action: .read,
            at: earlierDate, expectedBinding: owner)
        async let newer: ConversationUnreadState = peer.updateReadState(conversationID: conversationID, action: .read,
            at: laterDate, expectedBinding: owner)
        _ = try await (older, newer)
        let read = try await first.unreadState(conversationID: value.id)
        expectNoDifference(read, .init(lastActivityAt: now, lastViewedAt: now.addingTimeInterval(2)))
        let manual = try await peer.updateReadState(conversationID: value.id, action: .unread,
            at: now.addingTimeInterval(3), expectedBinding: binding)
        try await first.save([value], activityAt: now.addingTimeInterval(4))
        let afterStaleContent = try await peer.unreadState(conversationID: value.id)
        expectNoDifference(afterStaleContent, manual)
    }
}
