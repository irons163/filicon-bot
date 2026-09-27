import Foundation

/// A short-lived, host-owned fence issued after an exact durable binding lookup.
/// Repository mutations revoke it before changing ownership or uniqueness.
/// Operations under this lock must be synchronous and must not call the repository.
public final class ConversationBindingLease: @unchecked Sendable {
    public let conversationID: UUID
    public let binding: DirectConversationAgentBinding
    private let lock = NSLock()
    private var active = true

    public init(conversationID: UUID, binding: DirectConversationAgentBinding) {
        self.conversationID = conversationID
        self.binding = binding
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
