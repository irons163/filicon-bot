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
    case invalidDefinition = "Routine create needs name, prompt and either schedule or a cron/GitHub/Slack/Linear/Sentry/PagerDuty trigger, never both. Update needs your own id and at least one changed field. Only name, prompt, schedule, trigger and boolean enabled are supported."
    case invalidGitHubTrigger = "Each GitHub condition needs a concrete owner/repo, known events, optional userAllowlist (up to 50 logins) and ciBranch. CI events require one valid branch. Unknown fields, events and invalid filters are rejected."
    case invalidSlackTrigger = "Use one Slack trigger with a conversation ID (C/G/D...) or *, and match kind mention, message, keyword (up to 120 characters), or reaction (up to 8 emoji names). Channel/user names and bySelf true are unsupported. Unknown fields and invalid filters are rejected."
    case invalidLinearTrigger = "Linear supports issueCreated, statusChanged and endOfCycle. Use up to 50 UUIDs per list; empty means any. statusIds is only for statusChanged; cycleIds is only for endOfCycle. Cycles have no project relationship, so projectIds must be omitted or empty. Names, unknown fields and invalid filters are rejected."
    case invalidSentryTrigger = "Sentry supports issueCreated, issueResolved, issueAssigned, issueArchived, issueUnresolved or issueAny, with optional projectIds (up to 50 exact decimal ID strings, 1 to 200 digits each). Empty means any project. Names, unknown fields and invalid filters are rejected."
    case invalidPagerDutyTrigger = "PagerDuty supports incidentTriggered, incidentAcknowledged, incidentResolved, incidentEscalated or incidentAny, with optional serviceIds (up to 50 exact case-sensitive ID strings, 1 to 200 characters each). Empty means any service. No name lookup or wildcard IDs. Whitespace, control characters, unknown fields and invalid filters are rejected."
    case invalidEventGroup = "Use 1 to 8 flat cron, GitHub, Slack, Linear, Sentry or PagerDuty conditions. Any one can trigger the same task. Nested groups and other platforms are not supported. No invalid condition is ignored."
    case unsupportedSchedule = "Routine writes support time schedules, GitHub/Slack/Linear/Sentry/PagerDuty events, or flat groups of up to eight time/event conditions. Each time condition needs a valid explicit time zone and a next run within 366 days; intervals must be between one minute and 366 days."
    case protectedDefinition = "The agent cannot create enabled routines or edit protected routines while spend protection applies. Review Automations first."
    public var errorDescription: String? { rawValue }
}

public enum AutomationEditError: String, LocalizedError, Sendable {
    case invalidText = "Enter a nonempty name (up to 80 characters) and instruction (up to 32,000 characters)."
    case stale = "This routine changed or was deleted while editing. Close the editor and reopen the latest version. Your draft has not been saved."
    case unsupportedTrigger = "This trigger cannot be edited here. Its original definition is preserved; you can still edit the name and instruction."
    case unavailable = "This editor is no longer active, or its agent is unavailable. Close it and reopen the routine."
    case invalidTeamsScope = "Teams needs one tenant UUID and 1 to 50 team IDs. Channel IDs are optional (up to 50). Use Graph team UUIDs or exact Bot team IDs; no name lookup. IDs must be 1 to 200 UTF-8 bytes, without whitespace, control characters, commas or wildcards. Empty comma items are invalid."
    case invalidTeamsText = "Enter a literal Teams message filter of 1 to 120 characters, without control characters. Empty filters and regular expressions cannot be edited here."
    case unsupportedTeamsPolicy = "This editor preserves the Teams signed-in-user restriction and supports literal text only. Existing conditions with a different policy or regex remain read-only; name and instruction edits preserve them."
    public var errorDescription: String? { rawValue }
}

extension AutomationTrigger {
    /// A deliberately bounded manual editor. Other formats can be renamed
    /// without being rewritten, normalized or stripped of unknown fields.
    public func validateForManualEditing() throws {
        switch self {
        case .cron(let expression, let zoneID):
            guard !expression.isEmpty, expression.count <= 256,
                  zoneID == nil || zoneID.flatMap(TimeZone.init(identifier:)) != nil else {
                throw AutomationEditError.unsupportedTrigger
            }
            if let interval = AutomationSchedule.parseEvery(expression) {
                guard interval.isFinite, interval >= 60, interval <= 366 * 86_400 else {
                    throw AutomationStateChangeError.unsupportedSchedule
                }
            } else {
                _ = try AutomationSchedule.compile(expression, defaultTimeZone: zoneID.flatMap(TimeZone.init(identifier:)))
            }
        case .event(let value): try value.validateFilters()
        case .platform(.github(let value)): try value.validateForAgentWrite()
        case .platform(.slack(let value)): try value.validateForAgentWrite()
        case .platform(.microsoftTeams(let value)): try value.validateForManualEditing()
        case .platform(.linear(let value)): try value.validateForAgentWrite()
        case .platform(.sentry(let value)): try value.validateForSentryAgentWrite()
        case .platform(.pagerDuty(let value)): try value.validateForPagerDutyAgentWrite()
        case .anyOf(let members):
            guard (2...AutomationService.maximumListeners).contains(members.count), Set(members).count == members.count else {
                throw AutomationStateChangeError.invalidEventGroup
            }
            for member in members {
                if case .anyOf = member { throw AutomationEditError.unsupportedTrigger }
                try member.validateForManualEditing()
            }
        default: throw AutomationEditError.unsupportedTrigger
        }
    }
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
