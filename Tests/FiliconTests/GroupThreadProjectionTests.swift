import Foundation
import Testing
import CustomDump
import FiliconAgents

@Suite("Group reply thread projection")
struct GroupThreadProjectionTests {
    private let group = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let foreign = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private func id(_ value: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))! }
    private func message(_ value: Int, reply: Int? = nil) -> RoomMessage {
        var result = RoomMessage(id: id(value), groupID: group, senderID: id(99), text: "Message \(value)", createdAt: .init(timeIntervalSince1970: Double(value)))
        result.replyToMessageID = reply.map(id)
        return result
    }

    @Test func nestedRepliesFlattenUnderTheirOriginalRootInStableOrder() {
        let history = [message(1), message(2), message(3, reply: 1), message(4, reply: 3), message(5, reply: 2), message(6, reply: 1)]
        let projection = GroupThreadProjection(history: history, groupID: group)
        expectNoDifference(projection.roots.map(\.message.id), [id(1), id(2)])
        expectNoDifference(projection.replies(to: id(1)).map(\.message), [history[2], history[3], history[5]])
        expectNoDifference(projection.replies(to: id(2)).map(\.message), [history[4]])
        expectNoDifference(projection.root(containing: id(4)), id(1))
        expectNoDifference(projection.root(containing: id(3)), id(1))
        expectNoDifference(projection.root(containing: id(1)), id(1))
        #expect(projection.attentionRootIDs.isEmpty)
        // Projection never rewrites nested parent links into root links.
        expectNoDifference(projection.replies(to: id(1))[1].message.replyToMessageID, id(3))
    }

    @Test func brokenCyclesForwardSelfEmptyStatusAndDuplicateReferencesStayVisible() {
        var empty = message(10); empty.text = " \n"
        var status = message(12); status.memberOutcome = .failed
        let history = [
            message(1, reply: 2), message(2, reply: 1), // corrupt cycle
            message(3, reply: 3), message(4, reply: 100), message(5, reply: 4),
            message(6, reply: 7), message(7), // invalid forward edge
            message(8), message(8), message(9, reply: 8),
            empty, message(11, reply: 10), status, message(13, reply: 12)
        ]
        let projection = GroupThreadProjection(history: history, groupID: group)
        expectNoDifference(projection.roots.map(\.message), history)
        expectNoDifference(projection.roots.map(\.id), Array(history.indices))
        #expect(projection.root(containing: id(8)) == nil)
        #expect(history.allSatisfy { projection.replies(to: $0.id).isEmpty })
    }

    @Test func foreignHistoryCannotSupplyOrShadowAThreadTarget() {
        let outside = RoomMessage(id: id(1), groupID: foreign, senderID: nil, text: "PRIVATE")
        let outsideOnly = RoomMessage(id: id(2), groupID: foreign, senderID: nil, text: "PRIVATE")
        let projection = GroupThreadProjection(history: [outside, message(1), outsideOnly, message(3, reply: 1), message(4, reply: 2)], groupID: group)
        expectNoDifference(projection.roots.map(\.message.id), [id(1), id(4)])
        expectNoDifference(projection.replies(to: id(1)).map(\.message.id), [id(3)])
        #expect(projection.root(containing: id(2)) == nil)
    }

    @Test func pendingQuestionsAndToolsCannotBeHiddenByCollapsing() throws {
        var pending = message(3, reply: 2)
        pending.question = GroupQuestion(question: try AgentQuestion.parse(Data(#"{"prompt":"Continue?","options":[{"label":"Yes"}]}"#.utf8)), accountID: "local", memberIDs: [id(99)])
        var history = [message(1), message(2, reply: 1), pending]
        let projection = GroupThreadProjection(history: history, groupID: group)
        var state = GroupThreadPresentationState()
        expectNoDifference(projection.attentionRootIDs, [id(1)])
        #expect(state.isExpanded(id(1), in: projection))
        let original = state
        state.toggle(id(1), in: projection)
        expectNoDifference(state, original)
        history[2].question = nil
        var completed = GroupThreadProjection(history: history, groupID: group)
        #expect(!state.isExpanded(id(1), in: completed))
        history[2].toolActivities = [.init(id: "pending", name: "local__read_file", status: .pending)]
        completed = GroupThreadProjection(history: history, groupID: group)
        #expect(state.isExpanded(id(1), in: completed))
        history[2].toolActivities[0].status = .succeeded
        completed = GroupThreadProjection(history: history, groupID: group)
        #expect(!state.isExpanded(id(1), in: completed))
        expectNoDifference(state, original)
    }

    @Test func revealingReferencesExpandsOnlyTheirThreadAndFencesStaleCompletions() {
        let projection = GroupThreadProjection(history: [message(1), message(2), message(3, reply: 1), message(4, reply: 2)], groupID: group)
        var state = GroupThreadPresentationState()
        state.reveal(id(3), in: projection)
        expectNoDifference(state.expandedRootIDs, [id(1)])
        expectNoDifference(state.pendingMessageID, id(3))
        let beforeUnknown = state
        state.reveal(id(200), in: projection)
        expectNoDifference(state, beforeUnknown)
        state.reveal(id(4), in: projection)
        expectNoDifference(state.expandedRootIDs, [id(1), id(2)])
        expectNoDifference(state.pendingMessageID, id(4))
        let beforeStale = state
        state.didReveal(id(3))
        expectNoDifference(state, beforeStale)
        state.didReveal(id(4))
        #expect(state.pendingMessageID == nil)
        state.toggle(id(1), in: projection)
        state.toggle(id(2), in: projection)
        expectNoDifference(state, GroupThreadPresentationState())
    }

    @Test func longChainsAreProjectedIterativelyWithoutLosingMessages() {
        let history = (1...5_000).map { message($0, reply: $0 == 1 ? nil : $0 - 1) }
        let projection = GroupThreadProjection(history: history, groupID: group)
        expectNoDifference(projection.roots.map(\.message.id), [id(1)])
        expectNoDifference(projection.replies(to: id(1)).map(\.message), Array(history.dropFirst()))
        expectNoDifference(projection.root(containing: id(5_000)), id(1))
    }

    @Test func storedReplyRelationshipsRebuildThreadsWithoutPersistingExpansion() throws {
        let history = [message(1), message(2, reply: 1), message(3, reply: 2)]
        let restored = try JSONDecoder().decode([RoomMessage].self, from: JSONEncoder().encode(history))
        let projection = GroupThreadProjection(history: restored, groupID: group)
        expectNoDifference(projection.roots.map(\.message), [history[0]])
        expectNoDifference(projection.replies(to: id(1)).map(\.message), Array(history.dropFirst()))
        #expect(!GroupThreadPresentationState().isExpanded(id(1), in: projection))
    }
}
