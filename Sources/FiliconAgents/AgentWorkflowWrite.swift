import Foundation

public struct AgentWorkflowLibrarySnapshot: Sendable {
    public let revision: UUID
    public let workflows: [AgentWorkflow]
}

/// A complete, explicitly reviewed prompt replacement, never arbitrary workflow JSON.
public struct AgentWorkflowWrite: Sendable, Equatable {
    public static let maximumBodyBytes = 8_000
    public let requesterID: UUID
    public let expectedRevision: UUID
    public let previous: AgentWorkflow?
    public let proposed: AgentWorkflow

    public init(requesterID: UUID, expectedRevision: UUID, previous: AgentWorkflow?, proposed: AgentWorkflow) {
        self.requesterID = requesterID; self.expectedRevision = expectedRevision
        self.previous = previous; self.proposed = proposed
    }

    public static func isEditable(_ workflow: AgentWorkflow, by agentID: UUID) -> Bool {
        guard workflow.agentID == agentID, workflow.trigger == .manual,
              workflow.sourceReference == nil, workflow.id != "learn-from-demonstration",
              workflow.steps.count == 1, case .prompt(let body) = workflow.steps[0] else { return false }
        return body.utf8.count <= maximumBodyBytes
    }
}

public enum AgentWorkflowWriteError: LocalizedError, Equatable, Sendable {
    case invalid, unavailable, stale
    public var errorDescription: String? {
        switch self {
        case .invalid: "Workflow write requires name, description and body within the supported limits, with no execution or permission fields."
        case .unavailable: "Only your own local manual single-prompt workflows can be rewritten. Source-linked, managed and other agents' workflows are not writable here."
        case .stale: "The workflow library changed while awaiting approval. Request approval again."
        }
    }
}

/// Stop/account changes fence the synchronous atomic save itself, not just the
/// async call before it. Receipts distinguish a saved write from bookkeeping failure.
public final class AgentWorkflowWriteLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var receipts: [(AgentWorkflowWrite, AgentWorkflow)] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committed(for change: AgentWorkflowWrite) -> AgentWorkflow? {
        lock.withLock { receipts.last(where: { $0.0 == change })?.1 }
    }
    func commit(_ change: AgentWorkflowWrite, operation: () throws -> AgentWorkflow) throws -> AgentWorkflow {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            let saved = try operation()
            receipts.append((change, saved))
            return saved
        }
    }
}

/// Deletion reviews one exact definition and the same library revision as writes.
/// It is deliberately separate from a write so approved text cannot imply removal.
public struct AgentWorkflowDeletion: Sendable, Equatable {
    public let requesterID: UUID
    public let expectedRevision: UUID
    public let workflow: AgentWorkflow
    public init(requesterID: UUID, expectedRevision: UUID, workflow: AgentWorkflow) {
        self.requesterID = requesterID; self.expectedRevision = expectedRevision; self.workflow = workflow
    }
}

public enum AgentWorkflowDeletionError: LocalizedError, Equatable, Sendable {
    case invalid, unavailable
    public var errorDescription: String? {
        switch self {
        case .invalid: "Workflow deletion requires only target, action and an exact workflow ID."
        case .unavailable: "Only your own local manual single-prompt workflows within the review limit can be deleted here. Source-linked, managed and other agents' workflows are protected."
        }
    }
}

public final class AgentWorkflowDeletionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var receipts: [AgentWorkflowDeletion] = []
    public init() {}
    public func close() { lock.withLock { active = false } }
    public func check() throws {
        try lock.withLock { if !active { throw CancellationError() } }
        try Task.checkCancellation()
    }
    public func committed(_ change: AgentWorkflowDeletion) -> Bool { lock.withLock { receipts.contains(change) } }
    func commit(_ change: AgentWorkflowDeletion, operation: () throws -> Void) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            try Task.checkCancellation()
            try operation()
            receipts.append(change)
        }
    }
}
