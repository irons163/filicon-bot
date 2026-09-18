import Foundation

/// The host captures the complete definition presented for approval. Runtime
/// history may advance meanwhile; definition edits invalidate this proposal.
public struct AutomationStateChange: Equatable, Sendable {
    public enum Operation: String, Sendable { case pause, resume }
    public let operation: Operation
    public let automation: Automation
    public init(operation: Operation, automation: Automation) {
        self.operation = operation; self.automation = automation
    }
    public var enabled: Bool { operation == .resume }
    public func matchesDefinition(_ current: Automation) -> Bool {
        let expected = automation
        return current.id == expected.id && current.agentID == expected.agentID
            && current.name == expected.name && current.prompt == expected.prompt
            && current.trigger == expected.trigger && current.revision == expected.revision
            && current.enabled == expected.enabled && current.guardPaused == expected.guardPaused
    }
    public var triggerJSON: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return String(decoding: try encoder.encode(automation.trigger), as: UTF8.self)
        }
    }
}

public enum AutomationStateChangeError: String, LocalizedError, Sendable {
    case invalid = "Use target routine with action pause or resume and the id of your own existing automation. Other fields and routine actions are not supported."
    case unavailable = "The automation is unavailable, belongs to another agent, or already has the requested state."
    case stale = "The automation changed while awaiting approval. Inspect it and request approval again."
    case protected = "This automation cannot be resumed by the agent. Review its spend protection and trigger in Automations."
    public var errorDescription: String? { rawValue }
}

/// Closing the originating request revokes even an already-approved actor hop.
/// Receipts distinguish a durable write from a later UI/bookkeeping failure.
public final class AutomationStateChangeLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var receipts: [(AutomationStateChange, Automation)] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committed(for change: AutomationStateChange) -> Automation? {
        lock.withLock { receipts.last(where: { $0.0 == change })?.1 }
    }
    func commit(_ change: AutomationStateChange, operation: () throws -> Automation) throws -> Automation {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            let value = try operation()
            receipts.append((change, value))
            return value
        }
    }
}
