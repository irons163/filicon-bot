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
    public let event: String
    public let primaryIDs: Set<String>
    public let secondaryIDs: Set<String>
    public init(event: String, allowedEvents: Set<String>, primaryIDs: Set<String> = [], secondaryIDs: Set<String> = []) throws {
        guard allowedEvents.contains(event) else { throw AutomationServiceError.invalidDefinition }
        self.event = event; self.primaryIDs = primaryIDs; self.secondaryIDs = secondaryIDs
    }
}

public enum PlatformAutomationTrigger: Codable, Hashable, Sendable {
    case slack(SlackAutomationTrigger)
    case github(GitHubAutomationTrigger)
    case microsoftTeams(TeamsAutomationTrigger)
    case linear(CaseAutomationTrigger)
    case sentry(CaseAutomationTrigger)
    case pagerDuty(CaseAutomationTrigger)

    public var platform: String {
        switch self { case .slack: "slack"; case .github: "github"; case .microsoftTeams: "microsoftTeams"; case .linear: "linear"; case .sentry: "sentry"; case .pagerDuty: "pagerduty" }
    }

    public func matches(_ event: AutomationEvent) -> Bool {
        guard let payload = try? JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any] else { return false }
        switch self {
        case .slack(let trigger):
            guard event.kind == "slack", let channel = payload["channel"] as? String,
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
            }
            if !trigger.userAllowlist.isEmpty {
                guard let actor = (payload["actor"] as? String)?.lowercased(), trigger.userAllowlist.contains(actor) else { return false }
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
        case .linear(let trigger): return Self.matchesCase(trigger, event: event, payload: payload, kind: "linear")
        case .sentry(let trigger): return Self.matchesCase(trigger, event: event, payload: payload, kind: "sentry")
        case .pagerDuty(let trigger): return Self.matchesCase(trigger, event: event, payload: payload, kind: "pagerduty")
        }
    }

    private static func matchesCase(_ trigger: CaseAutomationTrigger, event: AutomationEvent, payload: [String: Any], kind: String) -> Bool {
        guard event.kind == kind, payload["event"] as? String == trigger.event else { return false }
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
