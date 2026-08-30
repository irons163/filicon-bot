import Foundation

public struct AgentAsyncTask: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: AgentTaskKind
    public let agentID: UUID
    public let parentAgentID: UUID?
    public let title: String
    public let status: AgentRunStatus
    public let startedAt: Date
    public let finishedAt: Date?
    public let result: String?
    public let isCancellationAllowed: Bool

    public init(record: SubagentRecord) {
        id = record.id
        kind = record.taskKind
        agentID = record.agentID
        parentAgentID = record.parentAgentID
        title = record.title
        status = record.status
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        result = record.result
        isCancellationAllowed = record.isCancellationAllowed && status.isInFlight
    }

    public func elapsed(at now: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }
}

public extension AgentRunStatus {
    var isInFlight: Bool { self == .queued || self == .running || self == .awaitingInput }
}

public enum AgentRosterSectionID: String, CaseIterable, Sendable { case pinned, active, archived }

public struct AgentRosterSection: Identifiable, Equatable, Sendable {
    public let id: AgentRosterSectionID
    public let agents: [AgentProfile]

    public static func build(profiles: [AgentProfile], pinnedIDs: Set<UUID>) -> [Self] {
        let order: (AgentProfile, AgentProfile) -> Bool = {
            if $0.unreadCount != $1.unreadCount { return $0.unreadCount > $1.unreadCount }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
        let pinned = profiles.filter { pinnedIDs.contains($0.id) }.sorted(by: order)
        let active = profiles.filter { $0.archivedAt == nil && !pinnedIDs.contains($0.id) }.sorted(by: order)
        let archived = profiles.filter { $0.archivedAt != nil && !pinnedIDs.contains($0.id) }.sorted(by: order)
        return [
            .init(id: .pinned, agents: pinned),
            .init(id: .active, agents: active),
            .init(id: .archived, agents: archived),
        ].filter { !$0.agents.isEmpty }
    }
}

public struct AgentChartPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct AgentOrgChartNode: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let profile: AgentProfile
    public let position: AgentChartPoint
    public let level: Int
}

public struct AgentOrgChartEdge: Identifiable, Hashable, Sendable {
    public var id: String { "\(parentID.uuidString):\(childID.uuidString)" }
    public let parentID: UUID
    public let childID: UUID
}

public struct AgentOrgChartLayout: Hashable, Sendable {
    public let nodes: [AgentOrgChartNode]
    public let edges: [AgentOrgChartEdge]
    public let width: Double
    public let height: Double

    /// Stable layout: ranks by shortest parent path, then orders every rank by name and UUID.
    public static func make(profiles: [AgentProfile], tasks: [AgentAsyncTask]) -> Self {
        let profileByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let edgePairs = Set(tasks.compactMap { task -> Pair? in
            guard let parent = task.parentAgentID, parent != task.agentID,
                  profileByID[parent] != nil, profileByID[task.agentID] != nil else { return nil }
            return Pair(parent: parent, child: task.agentID)
        })
        let edges = edgePairs.sorted {
            ($0.parent.uuidString, $0.child.uuidString) < ($1.parent.uuidString, $1.child.uuidString)
        }.map { AgentOrgChartEdge(parentID: $0.parent, childID: $0.child) }
        var incoming: [UUID: Int] = [:]
        var children: [UUID: [UUID]] = [:]
        for edge in edges {
            incoming[edge.childID, default: 0] += 1
            children[edge.parentID, default: []].append(edge.childID)
        }
        let stableIDs = profiles.sorted(by: stableProfileOrder).map(\.id)
        var levels: [UUID: Int] = [:]
        var queue = stableIDs.filter { incoming[$0, default: 0] == 0 }.map { ($0, 0) }
        if queue.isEmpty, let first = stableIDs.first { queue = [(first, 0)] }
        var offset = 0
        while offset < queue.count {
            let (id, level) = queue[offset]; offset += 1
            guard levels[id] == nil else { continue }
            levels[id] = level
            let ordered = (children[id] ?? []).sorted { stableIDOrder($0, $1, profiles: profileByID) }
            queue.append(contentsOf: ordered.map { ($0, level + 1) })
        }
        // Cycles or disconnected cyclic components remain inspectable on a deterministic root row.
        for id in stableIDs where levels[id] == nil { levels[id] = 0 }
        let maxLevel = levels.values.max() ?? 0
        let horizontalSpacing = 220.0, verticalSpacing = 150.0, margin = 90.0
        var nodes: [AgentOrgChartNode] = []
        var widest = 1
        for level in 0...maxLevel {
            let ids = stableIDs.filter { levels[$0] == level }
            widest = max(widest, ids.count)
            for (column, id) in ids.enumerated() {
                guard let profile = profileByID[id] else { continue }
                let centeredColumn = Double(column) - Double(ids.count - 1) / 2
                nodes.append(.init(
                    id: id,
                    profile: profile,
                    position: .init(x: margin + Double(widest - 1) * horizontalSpacing / 2 + centeredColumn * horizontalSpacing,
                                    y: margin + Double(level) * verticalSpacing),
                    level: level
                ))
            }
        }
        // Recenter after the actual widest rank is known.
        let center = margin + Double(widest - 1) * horizontalSpacing / 2
        nodes = nodes.map { node in
            let rank = nodes.filter { $0.level == node.level }.sorted { stableProfileOrder($0.profile, $1.profile) }
            let column = rank.firstIndex(where: { $0.id == node.id }) ?? 0
            return .init(id: node.id, profile: node.profile,
                         position: .init(x: center + (Double(column) - Double(rank.count - 1) / 2) * horizontalSpacing,
                                         y: node.position.y), level: node.level)
        }.sorted { ($0.level, $0.position.x, $0.id.uuidString) < ($1.level, $1.position.x, $1.id.uuidString) }
        return .init(nodes: nodes, edges: edges,
                     width: max(360, margin * 2 + Double(widest - 1) * horizontalSpacing),
                     height: max(240, margin * 2 + Double(maxLevel) * verticalSpacing))
    }

    private struct Pair: Hashable { let parent: UUID; let child: UUID }
    private static func stableProfileOrder(_ lhs: AgentProfile, _ rhs: AgentProfile) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
    private static func stableIDOrder(_ lhs: UUID, _ rhs: UUID, profiles: [UUID: AgentProfile]) -> Bool {
        guard let left = profiles[lhs], let right = profiles[rhs] else { return lhs.uuidString < rhs.uuidString }
        return stableProfileOrder(left, right)
    }
}
