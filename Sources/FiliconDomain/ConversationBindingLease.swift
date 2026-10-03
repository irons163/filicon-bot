import Foundation

/// A short-lived, host-owned fence issued after an exact durable binding lookup.
/// Repository mutations revoke it before changing ownership or uniqueness.
/// Operations under this lock must be synchronous and must not call the repository.
public final class ConversationBindingLease: @unchecked Sendable {
    public let conversationID: UUID
    public let binding: DirectConversationAgentBinding
    public let legacyHiddenAt: Date?
    private let lock = NSLock()
    private var active = true

    public init(conversationID: UUID, binding: DirectConversationAgentBinding, legacyHiddenAt: Date? = nil) {
        self.conversationID = conversationID
        self.binding = binding
        self.legacyHiddenAt = legacyHiddenAt
    }

    public var isActive: Bool { lock.withLock { active } }
    public func close() { lock.withLock { active = false } }

    public func withValidBinding<T>(_ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            return try operation()
        }
    }
}

/// A live, repository-owned read projection, not a conversation snapshot or an
/// execution grant. Synchronous consumers cannot race this repository's durable
/// read/activity publications. Independent repositories/processes are not fenced.
public final class ConversationUnreadObservation: @unchecked Sendable {
    public let conversationID: UUID
    public let binding: DirectConversationAgentBinding
    public let legacyHiddenAt: Date?
    private let lock = NSRecursiveLock()
    private var value: ConversationUnreadState?

    public init(conversationID: UUID, binding: DirectConversationAgentBinding, legacyHiddenAt: Date?, state: ConversationUnreadState) {
        self.conversationID = conversationID; self.binding = binding
        self.legacyHiddenAt = legacyHiddenAt; value = state
    }

    public var isActive: Bool { lock.withLock { value != nil } }
    public func close() { lock.withLock { value = nil } }

    /// The operation must not suspend, acquire another observation, or call its
    /// repository. The guard may synchronously save its own separate store.
    public func withReadState<Value>(_ operation: (ConversationUnreadState) throws -> Value) throws -> Value {
        try lock.withLock {
            try Task.checkCancellation()
            guard let value else { throw CancellationError() }
            return try operation(value)
        }
    }

    /// Repository publication plumbing. Recursive locking lets the repository
    /// hold all projections around its SQL transaction and then publish together.
    public func withPublicationLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        try lock.withLock(operation)
    }
    public func publish(_ state: ConversationUnreadState) {
        lock.withLock { if value != nil { value = state } }
    }
}
