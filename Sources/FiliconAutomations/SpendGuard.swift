import Foundation

public struct AutomationSpendGuardState: Codable, Hashable, Sendable {
    public var lastViewedAt: Date
    public var unreadCount: Int
    public var firesSinceViewed: Int
    public var nudgedAt: Date?
    public var snoozedUntil: Date?
    public var optedOut: Bool
    public var guardPausedAutomationIDs: Set<UUID>
    public var cardID: UUID?

    public init(
        lastViewedAt: Date = Date(), unreadCount: Int = 0, firesSinceViewed: Int = 0,
        nudgedAt: Date? = nil, snoozedUntil: Date? = nil, optedOut: Bool = false,
        guardPausedAutomationIDs: Set<UUID> = [], cardID: UUID? = nil
    ) {
        self.lastViewedAt = lastViewedAt; self.unreadCount = unreadCount
        self.firesSinceViewed = firesSinceViewed; self.nudgedAt = nudgedAt
        self.snoozedUntil = snoozedUntil; self.optedOut = optedOut
        self.guardPausedAutomationIDs = guardPausedAutomationIDs; self.cardID = cardID
    }
}

public enum SpendGuardDecision: String, Codable, Hashable, Sendable {
    case optedOut, userActive, snoozed, pause, awaitingAcknowledgement, nudge, belowThresholds
}
public enum SpendGuardAnswer: String, Codable, Hashable, Sendable { case keep, pause, neverAsk, resume, stayPaused }

public enum SpendGuardError: String, Error, LocalizedError, Sendable {
    case staleCard = "This automation activity check is no longer current."
    public var errorDescription: String? { rawValue }
}

/// A host lifecycle fence, not permission to resume a routine. The saved card
/// and its exact agent are still checked inside the service actor.
public final class AutomationSpendGuardLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.withLock { cancelled = true } }
    public func commit<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return try operation()
        }
    }
}

public enum AutomationSpendGuard {
    public static let idleInterval: TimeInterval = 3 * 24 * 60 * 60
    public static let pauseDelay: TimeInterval = 3 * 24 * 60 * 60
    public static let snoozeInterval: TimeInterval = 30 * 24 * 60 * 60
    public static let minimumUnreadCount = 15
    public static let minimumFiresSinceViewed = 20

    public static func evaluate(_ state: AutomationSpendGuardState, now: Date) -> SpendGuardDecision {
        if state.optedOut { return .optedOut }
        if now.timeIntervalSince(state.lastViewedAt) < idleInterval { return .userActive }
        if let snoozedUntil = state.snoozedUntil, now < snoozedUntil { return .snoozed }
        if let nudgedAt = state.nudgedAt, nudgedAt > state.lastViewedAt {
            return now.timeIntervalSince(nudgedAt) >= pauseDelay ? .pause : .awaitingAcknowledgement
        }
        if state.unreadCount >= minimumUnreadCount || state.firesSinceViewed >= minimumFiresSinceViewed { return .nudge }
        return .belowThresholds
    }
}
