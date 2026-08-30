import Foundation

public struct AgentNotificationSnapshot: Hashable, Sendable {
    public var id: String
    public var name: String
    public var isRunning: Bool
    public var awaitingReason: String?
    public var notifyEnabled: Bool
    public var isHidden: Bool
    public var lastMessageID: String?
    public var lastMessagePreview: String?

    public init(
        id: String,
        name: String,
        isRunning: Bool,
        awaitingReason: String? = nil,
        notifyEnabled: Bool = true,
        isHidden: Bool = false,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil
    ) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
        self.awaitingReason = awaitingReason
        self.notifyEnabled = notifyEnabled
        self.isHidden = isHidden
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
    }
}

public struct AgentNotificationTransition: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case needsInput, done }
    public var agentID: String
    public var agentName: String
    public var kind: Kind
    public var reason: String?
    public var notifyEnabled: Bool
    public var isHidden: Bool
    public var lastMessageID: String?
    public var lastMessagePreview: String?

    public init(
        agentID: String,
        agentName: String,
        kind: Kind,
        reason: String? = nil,
        notifyEnabled: Bool = true,
        isHidden: Bool = false,
        lastMessageID: String? = nil,
        lastMessagePreview: String? = nil
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.kind = kind
        self.reason = reason
        self.notifyEnabled = notifyEnabled
        self.isHidden = isHidden
        self.lastMessageID = lastMessageID
        self.lastMessagePreview = lastMessagePreview
    }

    public var content: (title: String, body: String) {
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "Your agent" : name
        switch kind {
        case .needsInput:
            let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ("\(safeName) needs you", Self.truncate(reason.isEmpty ? "Waiting for your input." : reason))
        case .done:
            let preview = lastMessagePreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (safeName, Self.truncate(preview.isEmpty ? "Open Filicon to see what it did." : preview))
        }
    }

    private static func truncate(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard collapsed.count > 140 else { return collapsed }
        return String(collapsed.prefix(139)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

public struct AgentNotificationDecider: Sendable {
    public let throttleInterval: TimeInterval
    private var previous: [String: AgentNotificationSnapshot] = [:]
    private var lastNotifiedAt: [ThrottleKey: Date] = [:]
    private var accountedMessageID: [String: String?] = [:]

    public init(throttleInterval: TimeInterval = 5) { self.throttleInterval = throttleInterval }

    public mutating func seedBaseline(_ agents: [AgentNotificationSnapshot]) {
        for agent in agents {
            if previous[agent.id] == nil { previous[agent.id] = agent }
            if !accountedMessageID.keys.contains(agent.id) { accountedMessageID[agent.id] = agent.lastMessageID }
        }
    }

    public mutating func decide(
        agents: [AgentNotificationSnapshot],
        isWindowFocused: Bool,
        now: Date = Date()
    ) -> [AgentNotificationTransition] {
        let transitions = agents.compactMap(transition)
        let accepted = gate(transitions, isWindowFocused: isWindowFocused, now: now)
        var next: [String: AgentNotificationSnapshot] = [:]
        for agent in agents {
            if !accountedMessageID.keys.contains(agent.id) { accountedMessageID[agent.id] = agent.lastMessageID }
            next[agent.id] = agent
        }
        previous = next
        return accepted
    }

    public mutating func decide(
        agent: AgentNotificationSnapshot,
        isWindowFocused: Bool,
        now: Date = Date()
    ) -> [AgentNotificationTransition] {
        let transitions = transition(agent).map { [$0] } ?? []
        let accepted = gate(transitions, isWindowFocused: isWindowFocused, now: now)
        if !accountedMessageID.keys.contains(agent.id) { accountedMessageID[agent.id] = agent.lastMessageID }
        previous[agent.id] = agent
        return accepted
    }

    public mutating func observe(_ agent: AgentNotificationSnapshot) {
        if !accountedMessageID.keys.contains(agent.id) { accountedMessageID[agent.id] = agent.lastMessageID }
        previous[agent.id] = agent
    }

    public mutating func forget(agentID: String) {
        previous.removeValue(forKey: agentID)
        accountedMessageID.removeValue(forKey: agentID)
        lastNotifiedAt.removeValue(forKey: .init(agentID: agentID, kind: .done))
        lastNotifiedAt.removeValue(forKey: .init(agentID: agentID, kind: .needsInput))
    }

    public mutating func reset() {
        previous.removeAll()
        accountedMessageID.removeAll()
        lastNotifiedAt.removeAll()
    }

    private func transition(_ agent: AgentNotificationSnapshot) -> AgentNotificationTransition? {
        guard let before = previous[agent.id] else { return nil }
        let becameAwaiting = agent.awaitingReason != nil && before.awaitingReason == nil
        let finished = before.isRunning && !agent.isRunning && agent.awaitingReason == nil
        guard becameAwaiting || finished else { return nil }
        return .init(
            agentID: agent.id,
            agentName: agent.name,
            kind: becameAwaiting ? .needsInput : .done,
            reason: becameAwaiting ? agent.awaitingReason : nil,
            notifyEnabled: agent.notifyEnabled,
            isHidden: agent.isHidden,
            lastMessageID: agent.lastMessageID,
            lastMessagePreview: agent.lastMessagePreview
        )
    }

    private mutating func gate(
        _ transitions: [AgentNotificationTransition],
        isWindowFocused: Bool,
        now: Date
    ) -> [AgentNotificationTransition] {
        var result: [AgentNotificationTransition] = []
        for transition in transitions {
            let accounted = accountedMessageID[transition.agentID] ?? nil
            if transition.kind == .done,
               (transition.lastMessageID == nil || transition.lastMessageID == accounted) { continue }
            accountedMessageID[transition.agentID] = transition.lastMessageID
            let key = ThrottleKey(agentID: transition.agentID, kind: transition.kind)
            guard !transition.agentID.isEmpty,
                  transition.notifyEnabled,
                  !transition.isHidden,
                  !isWindowFocused,
                  lastNotifiedAt[key].map({ now.timeIntervalSince($0) >= throttleInterval }) ?? true
            else { continue }
            lastNotifiedAt[key] = now
            result.append(transition)
        }
        return result
    }

    private struct ThrottleKey: Hashable, Sendable {
        var agentID: String
        var kind: AgentNotificationTransition.Kind
    }
}

public struct DockBadgeAgentSnapshot: Hashable, Sendable {
    public var id: String
    public var hasUnread: Bool
    public var unreadCount: Int?
    public var isHidden: Bool
    public var epoch: String
    public var sequence: UInt64

    public init(id: String, hasUnread: Bool, unreadCount: Int? = nil, isHidden: Bool = false, epoch: String = "", sequence: UInt64 = 0) {
        self.id = id
        self.hasUnread = hasUnread
        self.unreadCount = unreadCount
        self.isHidden = isHidden
        self.epoch = epoch
        self.sequence = sequence
    }
}

public struct DockBadgeProjector: Sendable {
    private var agents: [String: DockBadgeAgentSnapshot] = [:]
    public private(set) var count = 0

    public init() {}

    @discardableResult
    public mutating func apply(roster: [DockBadgeAgentSnapshot]) -> Int {
        if roster.isEmpty, !agents.isEmpty { return count }
        let newest = roster.max { lhs, rhs in lhs.sequence < rhs.sequence }
        var next: [String: DockBadgeAgentSnapshot] = [:]
        for agent in roster {
            if let existing = agents[agent.id], isStale(agent, comparedWith: existing) { next[agent.id] = existing }
            else { next[agent.id] = agent }
        }
        if let newest {
            for (id, existing) in agents where next[id] == nil && existing.epoch == newest.epoch && existing.sequence > newest.sequence {
                next[id] = existing
            }
        }
        agents = next
        return project()
    }

    @discardableResult
    public mutating func upsert(_ agent: DockBadgeAgentSnapshot) -> Int {
        if let existing = agents[agent.id], isStale(agent, comparedWith: existing) { return count }
        agents[agent.id] = agent
        return project()
    }

    @discardableResult
    public mutating func forget(id: String) -> Int {
        agents.removeValue(forKey: id)
        return project()
    }

    @discardableResult
    public mutating func reset() -> Int {
        agents.removeAll()
        return project()
    }

    private func isStale(_ incoming: DockBadgeAgentSnapshot, comparedWith existing: DockBadgeAgentSnapshot) -> Bool {
        existing.epoch == incoming.epoch && incoming.sequence < existing.sequence
    }

    private mutating func project() -> Int {
        count = agents.values.reduce(into: 0) { total, agent in
            guard !agent.isHidden, agent.hasUnread else { return }
            total += max(1, agent.unreadCount ?? 1)
        }
        return count
    }
}
