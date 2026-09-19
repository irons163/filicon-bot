import Foundation

/// The host captures the complete definition presented for approval. Runtime
/// history may advance meanwhile; definition edits invalidate this proposal.
public struct AutomationStateChange: Equatable, Sendable {
    public enum Operation: String, Sendable { case pause, resume, delete, create, update }
    public let operation: Operation
    public let automation: Automation
    public let previous: Automation?
    public init(operation: Operation, automation: Automation, previous: Automation? = nil) {
        self.operation = operation; self.automation = automation; self.previous = previous
    }
    public var isDefinitionWrite: Bool { operation == .create || operation == .update }
    public var enabled: Bool { isDefinitionWrite ? automation.enabled : operation == .resume }
    public func matchesDefinition(_ current: Automation) -> Bool {
        let expected = previous ?? automation
        return current.id == expected.id && current.agentID == expected.agentID
            && current.createdAt == expected.createdAt
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
    case invalid = "Use target routine with action pause, resume or delete and the id of your own existing automation. Other fields and routine actions are not supported."
    case unavailable = "The automation is unavailable, belongs to another agent, or already has the requested state."
    case stale = "The automation changed while awaiting approval. Inspect it and request approval again."
    case protected = "This automation cannot be resumed by the agent. Review its spend protection and trigger in Automations."
    case invalidDefinition = "Routine create needs name, prompt and schedule; update needs your own id and at least one changed field. Only name, prompt, schedule and boolean enabled are supported."
    case unsupportedSchedule = "Agent routine writes support time schedules only, with an explicit valid time zone. Intervals must be between one minute and 366 days. Review other triggers in Automations."
    case protectedDefinition = "The agent cannot create enabled routines or edit protected routines while spend protection applies. Review Automations first."
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
