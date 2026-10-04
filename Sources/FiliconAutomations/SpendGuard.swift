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

/// A durable host outbox record, not a widget response or execution permission.
/// The immutable destination and IDs let chat publication retry after a failed
/// database save without applying the scheduling choice a second time.
public struct AutomationSpendGuardTranscriptEntry: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let acknowledgmentID: UUID
    public let cardID: UUID
    public let agentID: UUID
    public let accountID: String
    public let conversationID: UUID
    public let isPaused: Bool
    public let createdAt: Date
    public private(set) var answer: SpendGuardAnswer?
    public private(set) var answeredAt: Date?

    init(id: UUID, acknowledgmentID: UUID, cardID: UUID, agentID: UUID, accountID: String,
         conversationID: UUID, isPaused: Bool, createdAt: Date) {
        self.id = id; self.acknowledgmentID = acknowledgmentID; self.cardID = cardID
        self.agentID = agentID; self.accountID = accountID; self.conversationID = conversationID
        self.isPaused = isPaused; self.createdAt = Self.stableDate(createdAt)
    }

    var isValid: Bool {
        !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && id != acknowledgmentID && createdAt.timeIntervalSince1970.isFinite
            && (answer == nil) == (answeredAt == nil)
            && (answeredAt?.timeIntervalSince1970.isFinite ?? true)
            && (answer.map { Self.choices(paused: isPaused).contains($0) } ?? true)
    }

    static func choices(paused: Bool) -> Set<SpendGuardAnswer> {
        paused ? [.resume, .stayPaused] : [.keep, .pause, .neverAsk]
    }

    mutating func record(_ value: SpendGuardAnswer, at date: Date) {
        answer = value; answeredAt = Self.stableDate(date)
    }

    private static func stableDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}

/// Native host ownership fence held through the synchronous guard-store write.
/// This is not Codable or a model tool argument. It must not suspend or call
/// back into the automation service or the repository that issued its lease.
public typealias AutomationSpendGuardCommitGuard = @Sendable (_ operation: () throws -> Void) throws -> Void

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
    public var isCurrent: Bool { lock.withLock { !cancelled } }
    public func commit<Value>(_ operation: () throws -> Value) throws -> Value {
        try lock.withLock {
            try Task.checkCancellation()
            guard !cancelled else { throw CancellationError() }
            return try operation()
        }
    }
}

/// Host-only classification of an already reviewed execution target. This is
/// neither Codable nor part of routine/event/model tool input. Its lifetime
/// fences account, definition and consent changes before durable admission.
public struct AutomationSpendGuardContext: Sendable {
    public let reviewedGroupBindingID: UUID?
    let activitySource: AutomationSpendGuardActivitySource?
    let lifetime: AutomationSpendGuardLifetime
    public init(reviewedGroupBindingID: UUID? = nil, lifetime: AutomationSpendGuardLifetime = .init(),
                activitySource: AutomationSpendGuardActivitySource? = nil) {
        self.reviewedGroupBindingID = reviewedGroupBindingID; self.lifetime = lifetime
        self.activitySource = activitySource
    }
    var isCurrent: Bool { lifetime.isCurrent }
    func commit<Value>(_ operation: () throws -> Value) throws -> Value { try lifetime.commit(operation) }
    func withActivity(_ operation: (AutomationSpendGuardActivity?) throws -> Void) throws {
        try lifetime.commit {
            if let activitySource {
                try activitySource { activity in
                    guard activity.lastViewedAt.timeIntervalSince1970.isFinite, activity.unreadCount >= 0 else {
                        throw AutomationServiceError.invalidDefinition
                    }
                    try operation(activity)
                }
            } else { try operation(nil) }
        }
    }
}

/// Trusted host projection of a canonical chat, not Codable/model/definition
/// input. The source holds its read-publication fence through the operation.
public struct AutomationSpendGuardActivity: Sendable {
    public let lastViewedAt: Date
    public let unreadCount: Int
    public init(lastViewedAt: Date, unreadCount: Int) {
        self.lastViewedAt = lastViewedAt; self.unreadCount = unreadCount
    }
}
public typealias AutomationSpendGuardActivitySource = @Sendable (_ operation: (AutomationSpendGuardActivity) throws -> Void) throws -> Void

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
