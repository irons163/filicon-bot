import Foundation
import FiliconDomain

enum GroupReadStateError: Error { case invalidState }

/// Durable host bookkeeping, not a group snapshot, account identity or permission.
/// Receipts survive edits/replays; legacy history is seeded without new arrivals.
struct GroupReadBookkeeping: Codable, Sendable {
    let schemaVersion: Int
    var records: [GroupReadRecord]

    init(groups: [AgentGroup], history: [RoomMessage]) throws {
        schemaVersion = 1
        records = groups.map { group in
            .init(groupID: group.id, state: .init(), activityMessageIDs: Set(history.filter {
                $0.groupID == group.id && $0.raisesGroupActivity
            }.map(\.id)))
        }
        try validate(groupIDs: groups.map(\.id))
    }

    func validate(groupIDs: [UUID]) throws {
        guard schemaVersion == 1, Set(groupIDs).count == groupIDs.count,
              Set(records.map(\.groupID)).count == records.count,
              Set(records.map(\.groupID)) == Set(groupIDs) else { throw GroupReadStateError.invalidState }
    }

    mutating func recordActivity(groups: [AgentGroup], history: [RoomMessage], at: Date) throws {
        try validate(groupIDs: groups.map(\.id))
        guard at.timeIntervalSince1970.isFinite else { throw GroupReadStateError.invalidState }
        let idsByGroup = Dictionary(grouping: history.filter(\.raisesGroupActivity), by: \.groupID)
            .mapValues { Set($0.map(\.id)) }
        for index in records.indices {
            let ids = idsByGroup[records[index].groupID] ?? []
            let new = ids.subtracting(records[index].activityMessageIDs)
            records[index].activityMessageIDs.formUnion(ids)
            records[index].state.markActivity(at: at, count: new.count)
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, records }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        records = try values.decode([GroupReadRecord].self, forKey: .records)
        guard schemaVersion == 1, Set(records.map(\.groupID)).count == records.count else {
            throw GroupReadStateError.invalidState
        }
    }
}

struct GroupReadRecord: Codable, Equatable, Sendable {
    let groupID: UUID
    var state: ConversationUnreadState
    var activityMessageIDs: Set<UUID>

    init(groupID: UUID, state: ConversationUnreadState, activityMessageIDs: Set<UUID> = []) {
        self.groupID = groupID; self.state = state; self.activityMessageIDs = activityMessageIDs
    }

    private enum CodingKeys: String, CodingKey { case groupID, state, activityMessageIDs }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        groupID = try values.decode(UUID.self, forKey: .groupID)
        state = try values.decode(ConversationUnreadState.self, forKey: .state)
        let ids = try values.decode([UUID].self, forKey: .activityMessageIDs)
        guard Set(ids).count == ids.count else { throw GroupReadStateError.invalidState }
        activityMessageIDs = Set(ids)
    }
    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(groupID, forKey: .groupID)
        try values.encode(state, forKey: .state)
        try values.encode(activityMessageIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .activityMessageIDs)
    }
}

/// Not Codable and not model-constructible. A queued native action keeps the
/// original store, room membership and optionally an inherited host/account life.
public final class GroupReadStateLease: Sendable {
    public let groupID: UUID
    public let memberIDs: [UUID]
    public let messageIDs: [UUID]
    public var state: ConversationUnreadState { originalRecord.state }
    public var isActive: Bool { (try? lease.check()) != nil }
    let storeID: UUID
    let originalRecord: GroupReadRecord
    let lease: AgentWorkflowExecutionScope.Lease
    private let scope = AgentWorkflowExecutionScope()

    init(storeID: UUID, group: AgentGroup, record: GroupReadRecord, messageIDs: [UUID],
         membershipLease: AgentWorkflowExecutionScope.Lease) throws {
        self.storeID = storeID; groupID = group.id; memberIDs = group.memberIDs; originalRecord = record
        self.messageIDs = messageIDs
        lease = try scope.capture(inheriting: membershipLease)
    }

    /// Derive a separately cancellable native action synchronously, before a
    /// UI Task is queued. Never recapture newer membership/account authority.
    public func scoped(inheriting hostLease: AgentWorkflowExecutionScope.Lease? = nil) throws -> GroupReadStateLease {
        try .init(copying: self, inheriting: hostLease)
    }

    private init(copying original: GroupReadStateLease, inheriting hostLease: AgentWorkflowExecutionScope.Lease?) throws {
        storeID = original.storeID; groupID = original.groupID; memberIDs = original.memberIDs
        originalRecord = original.originalRecord; messageIDs = original.messageIDs
        var parent = original.lease
        if let hostLease { parent = try parent.inheriting(hostLease) }
        lease = try scope.capture(inheriting: parent)
    }

    public func close() { scope.invalidate() }
}

extension RoomMessage {
    /// Visible publications and actual human replies, not tool-only updates,
    /// PASS/failure notices or the host's non-human background task seed.
    var raisesGroupActivity: Bool {
        guard routineWake == nil else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(images ?? []).isEmpty || !(files ?? []).isEmpty
            || remoteAttachment != nil || remoteImages != nil || question != nil || secretRequest != nil
    }
}
