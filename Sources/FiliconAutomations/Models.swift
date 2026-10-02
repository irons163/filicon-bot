import Foundation

public struct AutomationEventTrigger: Codable, Hashable, Sendable {
    public let connectorID: UUID
    public let kind: String
    public let filtersJSON: Data
    public init(connectorID: UUID, kind: String, filtersJSON: Data = Data("{}".utf8)) {
        self.connectorID = connectorID
        self.kind = kind
        self.filtersJSON = filtersJSON
    }
}

public enum AutomationTrigger: Codable, Hashable, Sendable {
    case cron(expression: String, timeZoneIdentifier: String?)
    case event(AutomationEventTrigger)
    case platform(PlatformAutomationTrigger)
    case anyOf([AutomationTrigger])
    case unknown(kind: String, payloadJSON: Data)

    /// Every platform involved, including OR members, for complete disclosure.
    public var platformSources: Set<String> {
        switch self {
        case .platform(let value): [value.platform]
        case .anyOf(let values): values.reduce(into: []) { $0.formUnion($1.platformSources) }
        case .cron, .event, .unknown: []
        }
    }

    public var containsTimeTrigger: Bool {
        switch self {
        case .cron: true
        case .anyOf(let members): members.contains(where: \.containsTimeTrigger)
        case .event, .platform, .unknown: false
        }
    }
}

public struct Automation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let agentID: UUID
    public var name: String
    public var prompt: String
    public var trigger: AutomationTrigger
    public var enabled: Bool
    public let createdAt: Date
    public var lastRunAt: Date?
    public var nextRunAt: Date?
    public var revision: Int64
    public var guardPaused: Bool

    public init(
        id: UUID = UUID(), agentID: UUID, name: String, prompt: String,
        trigger: AutomationTrigger, enabled: Bool = true,
        createdAt: Date = Date(), lastRunAt: Date? = nil,
        nextRunAt: Date? = nil, revision: Int64 = 1, guardPaused: Bool = false
    ) {
        self.id = id; self.agentID = agentID; self.name = name; self.prompt = prompt
        self.trigger = trigger; self.enabled = enabled; self.createdAt = createdAt
        self.lastRunAt = lastRunAt; self.nextRunAt = nextRunAt
        self.revision = revision; self.guardPaused = guardPaused
    }
}

public enum AutomationRunOrigin: String, Codable, Hashable, Sendable { case schedule, manual, event }
public enum AutomationRunStatus: String, Codable, Hashable, Sendable { case running, ok, error, interrupted, cancelled }

public struct AutomationRun: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let automationID: UUID
    public let trigger: AutomationRunOrigin
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: AutomationRunStatus
    public var detail: String?
    public var coalescedEventIDs: [String]
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var actualCost: Decimal?

    public init(
        id: UUID = UUID(), automationID: UUID, trigger: AutomationRunOrigin,
        startedAt: Date = Date(), finishedAt: Date? = nil,
        status: AutomationRunStatus = .running, detail: String? = nil,
        coalescedEventIDs: [String] = [], inputTokens: Int? = nil,
        outputTokens: Int? = nil, actualCost: Decimal? = nil
    ) {
        self.id = id; self.automationID = automationID; self.trigger = trigger
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.status = status
        self.detail = detail; self.coalescedEventIDs = coalescedEventIDs
        self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.actualCost = actualCost
    }
}

public struct AutomationEvent: Codable, Hashable, Sendable {
    public let connectorID: UUID
    public let kind: String
    public let externalEventID: String
    public let payloadJSON: Data
    public let occurredAt: Date
    public init(connectorID: UUID, kind: String, externalEventID: String, payloadJSON: Data, occurredAt: Date = Date()) {
        self.connectorID = connectorID; self.kind = kind; self.externalEventID = externalEventID
        self.payloadJSON = payloadJSON; self.occurredAt = occurredAt
    }
}

public struct AutomationWake: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let agentID: UUID
    public let runID: UUID
    public let status: AutomationRunStatus
    public let detail: String
    public let createdAt: Date
    public init(id: UUID = UUID(), agentID: UUID, runID: UUID, status: AutomationRunStatus, detail: String, createdAt: Date = Date()) {
        self.id = id; self.agentID = agentID; self.runID = runID
        self.status = status; self.detail = detail; self.createdAt = createdAt
    }
}

public struct AutomationExecutionResult: Hashable, Sendable {
    public let detail: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let actualCost: Decimal?
    public init(detail: String, inputTokens: Int? = nil, outputTokens: Int? = nil, actualCost: Decimal? = nil) {
        self.detail = detail; self.inputTokens = inputTokens
        self.outputTokens = outputTokens; self.actualCost = actualCost
    }
}

public protocol AutomationExecutor: Sendable {
    func execute(automation: Automation, prompt: String, events: [AutomationEvent]) async throws -> AutomationExecutionResult
}

/// Host-created after the durable running record is saved. Definitions and
/// external event payloads cannot choose a run ID or claim its origin.
public struct AutomationRunRequest: Sendable {
    public let automation: Automation
    public let run: AutomationRun
    public let prompt: String
    public let events: [AutomationEvent]

    public init(automation: Automation, run: AutomationRun, prompt: String, events: [AutomationEvent]) {
        self.automation = automation; self.run = run; self.prompt = prompt; self.events = events
    }
}

/// Opt-in refinement, preserving existing text-only executors. Session routing
/// is a host decision, not an authority field on an imported routine.
public protocol AutomationRunExecutor: AutomationExecutor {
    func execute(_ request: AutomationRunRequest) async throws -> AutomationExecutionResult
}

public enum AutomationServiceError: LocalizedError, Equatable, Sendable {
    case invalidDefinition, unknownAutomation(UUID), maximumDefinitions(Int)
    case listenerLimit, unsupportedTrigger(String), duplicateClaim, agentBusy(UUID)
    public var errorDescription: String? {
        switch self {
        case .invalidDefinition: "Invalid automation definition."
        case .unknownAutomation(let id): "Unknown automation \(id)."
        case .maximumDefinitions(let value): "An agent supports at most \(value) automations."
        case .listenerLimit: "An automation supports at most eight listeners."
        case .unsupportedTrigger(let kind): "Automation trigger \(kind) is unavailable."
        case .duplicateClaim: "This automation firing was already claimed."
        case .agentBusy(let id): "Agent \(id) already has an active run."
        }
    }
}
