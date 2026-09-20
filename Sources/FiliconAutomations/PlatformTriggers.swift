import Foundation

public enum SlackMatch: Codable, Hashable, Sendable {
    case mention
    case message
    case keyword(String)
    case reaction(emoji: [String], bySelf: Bool)
}

public struct SlackAutomationTrigger: Codable, Hashable, Sendable {
    public let channel: String
    public let match: SlackMatch
    public init(channel: String, match: SlackMatch) throws {
        let channel = String(channel.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(80))
        guard !channel.isEmpty else { throw AutomationServiceError.invalidDefinition }
        if case .keyword(let raw) = match {
            let value = String(raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces).prefix(120))
            guard !value.isEmpty else { throw AutomationServiceError.invalidDefinition }
            self.match = .keyword(value)
        } else if case .reaction(let raw, let bySelf) = match {
            let values = raw.compactMap(Self.normalizeEmoji).uniqued().prefix(8)
            self.match = .reaction(emoji: Array(values), bySelf: bySelf)
        } else { self.match = match }
        self.channel = channel
    }

    public static func normalizeEmoji(_ raw: String) -> String? {
        let bare = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let value = (bare.components(separatedBy: "::").first ?? bare).lowercased()
        guard !value.isEmpty, value.range(of: "^[a-z0-9_+\\-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }

    /// No name lookup or authenticated human identity exists in the ingress yet.
    /// Reject those proposals instead of silently broadening their scope.
    public func validateForAgentWrite() throws {
        guard channel.count <= 80, channel == "*" || channel.range(of: #"^[CGD][A-Z0-9]+$"#, options: .regularExpression) != nil else {
            throw AutomationStateChangeError.invalidSlackTrigger
        }
        switch match {
        case .mention, .message: break
        case .keyword(let keyword):
            guard !keyword.isEmpty, keyword.count <= 120, keyword == keyword.trimmingCharacters(in: .whitespacesAndNewlines),
                  keyword.rangeOfCharacter(from: .controlCharacters) == nil else { throw AutomationStateChangeError.invalidSlackTrigger }
        case .reaction(let emoji, let bySelf):
            guard !bySelf, emoji.count <= 8, Set(emoji).count == emoji.count,
                  emoji.allSatisfy({ !$0.isEmpty && $0.count <= 80 && Self.normalizeEmoji($0) == $0 }) else {
                throw AutomationStateChangeError.invalidSlackTrigger
            }
        }
    }
}

public struct GitHubAutomationTrigger: Codable, Hashable, Sendable {
    public static let knownEvents: Set<String> = [
        "pr-opened", "pr-pushed", "pr-merged", "review-requested", "review-approved",
        "review-changes-requested", "review-commented", "pr-comment", "inline-review-comment",
        "review-thread-resolved", "review-thread-unresolved", "issue-assigned", "ci-passed", "ci-failed",
    ]
    public let repo: String
    public let events: Set<String>
    public let ciBranch: String?
    public let userAllowlist: [String]

    private enum CodingKeys: String, CodingKey { case repo, events, ciBranch, userAllowlist }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repo, forKey: .repo)
        // Keep storage and before/after approval previews stable across Set seeds.
        try container.encode(events.sorted(), forKey: .events)
        try container.encodeIfPresent(ciBranch, forKey: .ciBranch)
        try container.encode(userAllowlist, forKey: .userAllowlist)
    }

    public init(repo: String, events: [String], ciBranch: String? = nil, userAllowlist: [String] = []) throws {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repo.range(of: "^[^\\s/]+/[^\\s/]+$", options: .regularExpression) != nil else { throw AutomationServiceError.invalidDefinition }
        var allowed = Set(events.map { $0.lowercased() }).intersection(Self.knownEvents)
        let branch = ciBranch?.trimmingCharacters(in: .whitespacesAndNewlines)
        if branch?.isEmpty != false || branch?.range(of: #"[\s~^:?*\[\\\]]|^[-/]|/$|\.\.|@\{"#, options: .regularExpression) != nil {
            allowed.subtract(["ci-passed", "ci-failed"])
        }
        guard !allowed.isEmpty else { throw AutomationServiceError.invalidDefinition }
        var seen: Set<String> = []
        self.userAllowlist = userAllowlist.compactMap { raw in
            let value = raw.drop(while: { $0 == "@" }).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }.prefix(50).map { $0 }
        self.repo = repo; self.events = allowed; self.ciBranch = branch?.isEmpty == false ? branch : nil
    }

    /// Model writes fail closed instead of silently dropping invalid filters.
    public func validateForAgentWrite() throws {
        guard repo.count <= 140,
              repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              ![".", ".."].contains(String(repo.split(separator: "/").last ?? "")),
              !events.isEmpty, events.isSubset(of: Self.knownEvents), userAllowlist.count <= 50,
              userAllowlist.allSatisfy({ $0.count <= 80 && $0.range(of: #"^[a-z0-9][a-z0-9-]*(\[bot\])?$"#, options: .regularExpression) != nil }) else {
            throw AutomationStateChangeError.invalidGitHubTrigger
        }
        if let branch = ciBranch {
            guard !branch.isEmpty, branch.count <= 200, branch != "@",
                  branch == branch.trimmingCharacters(in: .whitespacesAndNewlines),
                  branch.range(of: #"[\s~^:?*\[\\\]\x00-\x1f\x7f]|^[-/]|/$|\.$|\.\.|@\{|//|(^|/)\.|\.lock($|/)"#, options: .regularExpression) == nil else {
                throw AutomationStateChangeError.invalidGitHubTrigger
            }
        }
        if !events.isDisjoint(with: ["ci-passed", "ci-failed"]), ciBranch == nil {
            throw AutomationStateChangeError.invalidGitHubTrigger
        }
    }
}

public struct TeamsAutomationTrigger: Codable, Hashable, Sendable {
    public let tenantID: String
    public let teamIDs: Set<String>
    public let channelIDs: Set<String>
    public let messageContains: String?
    public let messageContainsIsRegex: Bool
    public let blockUnauthenticatedUsers: Bool
    public init(tenantID: String, teamIDs: Set<String>, channelIDs: Set<String> = [], messageContains: String? = nil, messageContainsIsRegex: Bool = false, blockUnauthenticatedUsers: Bool = true) throws {
        let tenant = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tenant.isEmpty, !teamIDs.isEmpty else { throw AutomationServiceError.invalidDefinition }
        if messageContainsIsRegex, let messageContains { _ = try NSRegularExpression(pattern: messageContains) }
        self.tenantID = tenant; self.teamIDs = teamIDs; self.channelIDs = channelIDs
        self.messageContains = messageContains?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.messageContainsIsRegex = messageContainsIsRegex; self.blockUnauthenticatedUsers = blockUnauthenticatedUsers
    }
}

public struct CaseAutomationTrigger: Codable, Hashable, Sendable {
    public static let sentryEvents: Set<String> = ["issueCreated", "issueResolved", "issueAssigned", "issueArchived", "issueUnresolved", "issueAny"]
    public static let pagerDutyEvents: Set<String> = ["incidentTriggered", "incidentAcknowledged", "incidentResolved", "incidentEscalated", "incidentAny"]
    public let event: String
    public let primaryIDs: Set<String>
    public let secondaryIDs: Set<String>
    public init(event: String, allowedEvents: Set<String>, primaryIDs: Set<String> = [], secondaryIDs: Set<String> = []) throws {
        guard allowedEvents.contains(event) else { throw AutomationServiceError.invalidDefinition }
        self.event = event; self.primaryIDs = primaryIDs; self.secondaryIDs = secondaryIDs
    }
    private enum CodingKeys: String, CodingKey { case event, primaryIDs, secondaryIDs }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(primaryIDs.sorted(), forKey: .primaryIDs)
        try container.encode(secondaryIDs.sorted(), forKey: .secondaryIDs)
    }
    public static func isSentryProjectID(_ value: String) -> Bool {
        (1...200).contains(value.utf8.count) && value.utf8.allSatisfy { (48...57).contains($0) }
    }
    public func validateForSentryAgentWrite() throws {
        guard Self.sentryEvents.contains(event), secondaryIDs.isEmpty, primaryIDs.count <= 50,
              primaryIDs.allSatisfy(Self.isSentryProjectID) else { throw AutomationStateChangeError.invalidSentryTrigger }
    }
    public static func isPagerDutyServiceID(_ value: String) -> Bool {
        (1...200).contains(value.count) && value != "*"
            && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
    public func validateForPagerDutyAgentWrite() throws {
        guard Self.pagerDutyEvents.contains(event), secondaryIDs.isEmpty, primaryIDs.count <= 50,
              primaryIDs.allSatisfy(Self.isPagerDutyServiceID) else { throw AutomationStateChangeError.invalidPagerDutyTrigger }
    }
}

/// Cases backed by the documented Sentry issue webhook, not every resource
/// that happens to share an action such as "created".
enum SentryIssueEvent: String {
    case created = "issueCreated"
    case resolved = "issueResolved"
    case assigned = "issueAssigned"
    case archived = "issueArchived"
    case unresolved = "issueUnresolved"

    init?(action: String?) {
        switch action {
        case "created": self = .created
        case "resolved": self = .resolved
        case "assigned": self = .assigned
        case "archived": self = .archived
        case "unresolved": self = .unresolved
        default: return nil
        }
    }
}

/// The four V3 incident events supported by the reference. "Any" does not
/// include unrelated service events or other incident event types.
enum PagerDutyIncidentEvent: String {
    case triggered = "incidentTriggered"
    case acknowledged = "incidentAcknowledged"
    case resolved = "incidentResolved"
    case escalated = "incidentEscalated"

    init?(eventType: String?) {
        switch eventType {
        case "incident.triggered": self = .triggered
        case "incident.acknowledged": self = .acknowledged
        case "incident.resolved": self = .resolved
        case "incident.escalated": self = .escalated
        default: return nil
        }
    }
}

/// Keeps the legacy Linear storage keys while isolating Linear-only filters
/// from Sentry/PagerDuty. Missing statusIDs/cycleIDs means no such filter.
public struct LinearAutomationTrigger: Codable, Hashable, Sendable {
    public let event: String
    public let primaryIDs: Set<String> // Team IDs (legacy storage key).
    public let secondaryIDs: Set<String> // Project IDs (legacy storage key).
    public let statusIDs: Set<String>
    public let cycleIDs: Set<String>
    private enum CodingKeys: String, CodingKey { case event, primaryIDs, secondaryIDs, statusIDs, cycleIDs }

    public init(event: String, allowedEvents: Set<String>, primaryIDs: Set<String> = [],
                secondaryIDs: Set<String> = [], statusIDs: Set<String> = []) throws {
        try self.init(event: event, allowedEvents: allowedEvents, primaryIDs: primaryIDs,
                      secondaryIDs: secondaryIDs, statusIDs: statusIDs, cycleIDs: [])
    }
    public init(event: String, allowedEvents: Set<String>, primaryIDs: Set<String> = [],
                secondaryIDs: Set<String> = [], statusIDs: Set<String> = [], cycleIDs: Set<String>) throws {
        guard allowedEvents.contains(event) else { throw AutomationServiceError.invalidDefinition }
        self.event = event; self.primaryIDs = primaryIDs; self.secondaryIDs = secondaryIDs; self.statusIDs = statusIDs
        self.cycleIDs = cycleIDs
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        event = try container.decode(String.self, forKey: .event)
        primaryIDs = try container.decode(Set<String>.self, forKey: .primaryIDs)
        secondaryIDs = try container.decode(Set<String>.self, forKey: .secondaryIDs)
        // Null is not omission: a malformed persisted filter must not broaden.
        statusIDs = container.contains(.statusIDs) ? try container.decode(Set<String>.self, forKey: .statusIDs) : []
        cycleIDs = container.contains(.cycleIDs) ? try container.decode(Set<String>.self, forKey: .cycleIDs) : []
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(event, forKey: .event)
        try container.encode(primaryIDs.sorted(), forKey: .primaryIDs)
        try container.encode(secondaryIDs.sorted(), forKey: .secondaryIDs)
        try container.encode(statusIDs.sorted(), forKey: .statusIDs)
        // Preserve existing issue-only JSON when there is no cycle filter.
        if !cycleIDs.isEmpty { try container.encode(cycleIDs.sorted(), forKey: .cycleIDs) }
    }
    public func validateForAgentWrite() throws {
        guard ["issueCreated", "statusChanged", "endOfCycle"].contains(event),
              event == "endOfCycle" || cycleIDs.isEmpty,
              event != "endOfCycle" || secondaryIDs.isEmpty,
              event == "statusChanged" || statusIDs.isEmpty,
              [primaryIDs, secondaryIDs, statusIDs, cycleIDs].allSatisfy({ ids in
                  ids.count <= 50 && ids.allSatisfy { UUID(uuidString: $0) != nil && $0.count == 36 }
              }) else { throw AutomationStateChangeError.invalidLinearTrigger }
    }
    fileprivate func matches(_ event: AutomationEvent, payload: [String: Any]) -> Bool {
        let key = ["issueCreated", "statusChanged", "endOfCycle"].contains(self.event) ? "eventCase" : "event"
        guard event.kind == "linear", payload[key] as? String == self.event,
              self.event == "statusChanged" || statusIDs.isEmpty,
              self.event == "endOfCycle" || cycleIDs.isEmpty else { return false }
        // A native Cycle webhook has a team but no project association. Do not
        // drop a requested project restriction or fabricate one from issues.
        if self.event == "endOfCycle", !secondaryIDs.isEmpty { return false }
        // Canonical UUID comparison accepts letter case differences, while
        // preserving exact matching for old non-UUID manual definitions.
        func matches(_ ids: Set<String>, key: String) -> Bool {
            guard !ids.isEmpty else { return true }
            guard let actual = payload[key] as? String else { return false }
            if let uuid = UUID(uuidString: actual) { return ids.contains { UUID(uuidString: $0) == uuid } }
            return ids.contains(actual)
        }
        return matches(primaryIDs, key: "primaryId") && matches(secondaryIDs, key: "secondaryId")
            && matches(statusIDs, key: "statusId") && matches(cycleIDs, key: "cycleId")
    }
}

public enum PlatformAutomationTrigger: Codable, Hashable, Sendable {
    case slack(SlackAutomationTrigger)
    case github(GitHubAutomationTrigger)
    case microsoftTeams(TeamsAutomationTrigger)
    case linear(LinearAutomationTrigger)
    case sentry(CaseAutomationTrigger)
    case pagerDuty(CaseAutomationTrigger)

    public var platform: String {
        switch self { case .slack: "slack"; case .github: "github"; case .microsoftTeams: "microsoftTeams"; case .linear: "linear"; case .sentry: "sentry"; case .pagerDuty: "pagerduty" }
    }

    public func matches(_ event: AutomationEvent) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any] else { return false }
        switch self {
        case .slack(let trigger):
            guard event.kind == "slack", payload["supportedEvent"] as? Bool != false,
                  let channel = payload["channel"] as? String, !channel.isEmpty,
                  trigger.channel == "*" || trigger.channel.caseInsensitiveCompare(channel) == .orderedSame else { return false }
            let reaction = payload["reaction"] as? String
            switch trigger.match {
            case .message: return reaction == nil
            case .mention: return reaction == nil && payload["isMention"] as? Bool == true
            case .keyword(let keyword): return reaction == nil && (payload["text"] as? String)?.localizedCaseInsensitiveContains(keyword) == true
            case .reaction(let emoji, let bySelf):
                guard let reaction = reaction.flatMap(SlackAutomationTrigger.normalizeEmoji) else { return false }
                return (emoji.isEmpty || emoji.contains(reaction)) && (!bySelf || payload["isSelf"] as? Bool == true)
            }
        case .github(let trigger):
            guard event.kind == "github", (payload["repo"] as? String)?.caseInsensitiveCompare(trigger.repo) == .orderedSame,
                  let kind = payload["event"] as? String, trigger.events.contains(kind) else { return false }
            if kind == "ci-passed" || kind == "ci-failed" {
                guard let branch = trigger.ciBranch, payload["branch"] as? String == branch else { return false }
                // CI is branch-scoped, never user-gated in the reference.
                return true
            }
            if !trigger.userAllowlist.isEmpty {
                func allowed(_ key: String) -> Bool {
                    guard let value = (payload[key] as? String)?.lowercased() else { return false }
                    return trigger.userAllowlist.contains(value)
                }
                switch kind {
                case "pr-opened", "pr-pushed", "pr-merged", "pr-comment", "inline-review-comment":
                    guard allowed("prOwner") else { return false }
                case "review-requested", "review-approved", "review-changes-requested", "review-commented", "review-thread-resolved", "review-thread-unresolved":
                    guard allowed("actor"), allowed("prOwner") else { return false }
                default: guard allowed("actor") else { return false }
                }
            }
            return payload["subjectPresent"] as? Bool != false || payload["admitMissingSubject"] as? Bool == true
        case .microsoftTeams(let trigger):
            guard event.kind == "microsoftTeams", payload["tenantId"] as? String == trigger.tenantID,
                  let team = payload["teamId"] as? String, trigger.teamIDs.contains(team) else { return false }
            if !trigger.channelIDs.isEmpty {
                guard let channel = payload["channelId"] as? String, trigger.channelIDs.contains(channel) else { return false }
            }
            if trigger.blockUnauthenticatedUsers, payload["authenticated"] as? Bool != true { return false }
            guard let needle = trigger.messageContains else { return true }
            let text = payload["text"] as? String ?? ""
            return trigger.messageContainsIsRegex ? text.range(of: needle, options: .regularExpression) != nil : text.localizedCaseInsensitiveContains(needle)
        case .linear(let trigger):
            return trigger.matches(event, payload: payload)
        case .sentry(let trigger):
            if trigger.event == "issueAny" || SentryIssueEvent(rawValue: trigger.event) != nil {
                guard event.kind == "sentry", let eventCase = payload["eventCase"] as? String,
                      SentryIssueEvent(rawValue: eventCase) != nil,
                      trigger.event == "issueAny" || eventCase == trigger.event,
                      trigger.secondaryIDs.isEmpty else { return false }
                guard !trigger.primaryIDs.isEmpty else { return true }
                guard let projectID = payload["projectId"] as? String else { return false }
                return trigger.primaryIDs.contains(projectID)
            }
            // Existing raw-action definitions keep their old storage and payload
            // keys. Do not silently reinterpret a legacy slug filter as an ID.
            return Self.matchesCase(trigger, event: event, payload: payload, kind: "sentry")
        case .pagerDuty(let trigger):
            if trigger.event == "incidentAny" || PagerDutyIncidentEvent(rawValue: trigger.event) != nil {
                guard event.kind == "pagerduty", let eventCase = payload["eventCase"] as? String,
                      PagerDutyIncidentEvent(rawValue: eventCase) != nil,
                      trigger.event == "incidentAny" || eventCase == trigger.event,
                      trigger.secondaryIDs.isEmpty else { return false }
                guard !trigger.primaryIDs.isEmpty else { return true }
                guard let serviceID = payload["serviceId"] as? String else { return false }
                return trigger.primaryIDs.contains(serviceID)
            }
            // Raw event-type definitions retain their existing exact filters.
            return Self.matchesCase(trigger, event: event, payload: payload, kind: "pagerduty")
        }
    }

    private static func matchesCase(_ trigger: CaseAutomationTrigger, event: AutomationEvent, payload: [String: Any], kind: String,
                                    eventKey: String = "event") -> Bool {
        guard event.kind == kind, payload[eventKey] as? String == trigger.event else { return false }
        if !trigger.primaryIDs.isEmpty {
            guard let id = payload["primaryId"] as? String, trigger.primaryIDs.contains(id) else { return false }
        }
        if !trigger.secondaryIDs.isEmpty {
            guard let id = payload["secondaryId"] as? String, trigger.secondaryIDs.contains(id) else { return false }
        }
        return true
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen: Set<Element> = []; return filter { seen.insert($0).inserted } }
}
private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
