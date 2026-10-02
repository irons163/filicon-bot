import Foundation

/// Process-local lifecycle fencing, NOT a tool permission or persisted account grant.
/// Hosts suspend synchronously before an account transition so work waiting in
/// another actor cannot capture a new lease until that transition has finished.
public final class AgentWorkflowExecutionScope: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var suspensionCount = 0

    public init() {}

    public struct Lease: Hashable, Sendable {
        private struct Ticket: Hashable, Sendable {
            let scope: AgentWorkflowExecutionScope
            let generation: UInt64

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.scope === rhs.scope && lhs.generation == rhs.generation
            }
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(scope)); hasher.combine(generation)
            }
        }
        private let tickets: [Ticket]

        fileprivate init(scope: AgentWorkflowExecutionScope, generation: UInt64, inherited: Lease?) {
            let current = Ticket(scope: scope, generation: generation)
            var tickets = inherited?.tickets ?? []
            if !tickets.contains(current) { tickets.append(current) }
            self.tickets = tickets
        }

        public func check() throws {
            try commit {}
        }

        /// Hold all scope locks through a final synchronous state save. The
        /// operation must not call capture, check, or lifecycle mutation again.
        public func commit<Value>(_ operation: () throws -> Value) throws -> Value {
            var unique: [ObjectIdentifier: AgentWorkflowExecutionScope] = [:]
            for ticket in tickets { unique[ObjectIdentifier(ticket.scope)] = ticket.scope }
            let scopes = unique.values.sorted {
                UInt(bitPattern: ObjectIdentifier($0)) < UInt(bitPattern: ObjectIdentifier($1))
            }
            for scope in scopes { scope.lock.lock() }
            defer { for scope in scopes.reversed() { scope.lock.unlock() } }
            try Task.checkCancellation()
            guard tickets.allSatisfy({ $0.scope.suspensionCount == 0 && $0.scope.generation == $0.generation }) else {
                throw CancellationError()
            }
            return try operation()
        }
    }

    /// An upstream dispatch fence supplements this scope; it never replaces it.
    public func capture(inheriting lease: Lease? = nil) throws -> Lease {
        try Task.checkCancellation()
        let captured = try lock.withLock {
            guard suspensionCount == 0 else { throw CancellationError() }
            return Lease(scope: self, generation: generation, inherited: lease)
        }
        try captured.check()
        return captured
    }

    /// Revokes every captured lease, including dispatches not yet in the runtime.
    public func invalidate() { lock.withLock { generation &+= 1 } }

    public func suspend() {
        lock.withLock { generation &+= 1; suspensionCount += 1 }
    }

    /// Balance each suspension. Only future captures become valid after the
    /// last overlapping transition finishes; old leases stay revoked.
    public func resume() { lock.withLock { if suspensionCount > 0 { suspensionCount -= 1 } } }
}
