import Foundation

public enum AutomationIngressEventNormalizer {
    public static func event(route: AutomationIngressRoute, request: AutomationHTTPRequest,
                             nonce: String, now: Date = Date()) throws -> AutomationEvent {
        guard let object = try JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            throw AutomationIngressError.invalidRequest
        }
        let normalized: [String: Any]
        let externalID: String
        switch route.provider {
        case .generic:
            let kind = object["kind"] as? String ?? "generic"
            externalID = object["externalEventID"] as? String ?? nonce
            let payload = object["payload"] as? [String: Any] ?? object
            return AutomationEvent(connectorID: route.id, kind: String(kind.prefix(100)), externalEventID: String(externalID.prefix(200)),
                                   payloadJSON: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), occurredAt: now)
        case .slack:
            let source = object["event"] as? [String: Any] ?? object
            let kind = source["type"] as? String
            let item = source["item"] as? [String: Any]
            let isMessage = (kind == "message" || kind == "app_mention") && source["subtype"] == nil
                && source["hidden"] as? Bool != true && source["bot_id"] == nil
                && (source["user"] as? String)?.isEmpty == false && source["text"] is String
            let reaction = kind == "reaction_added" && item?["type"] as? String == "message"
                ? (source["reaction"] as? String).flatMap(SlackAutomationTrigger.normalizeEmoji) : nil
            let supported = isMessage || (reaction != nil && (source["user"] as? String)?.isEmpty == false)
            normalized = [
                "channel": reaction != nil ? item?["channel"] ?? "" : source["channel"] ?? "",
                "text": isMessage ? source["text"] ?? "" : "",
                "sender": source["user"] ?? "",
                "reaction": reaction as Any,
                "supportedEvent": supported,
                "isMention": isMessage && kind == "app_mention",
                // Slack's signed envelope does not identify the Filicon user.
                "isSelf": false,
                "raw": object,
            ].compactMapValues { Self.nonNil($0) }
            externalID = object["event_id"] as? String ?? nonce
        case .github:
            let repository = object["repository"] as? [String: Any]
            let sender = object["sender"] as? [String: Any]
            let headerEvent = request.headers["x-github-event"] ?? "unknown"
            normalized = [
                "repo": repository?["full_name"] ?? "",
                "event": githubEvent(headerEvent, action: object["action"] as? String, object: object),
                "branch": githubBranch(object) as Any,
                "actor": sender?["login"] ?? "",
                "prOwner": githubPROwner(object) as Any,
                "subjectPresent": object["pull_request"] != nil || object["issue"] != nil || object["workflow_run"] != nil,
                "raw": object,
            ].compactMapValues { Self.nonNil($0) }
            externalID = request.headers["x-github-delivery"] ?? nonce
        case .microsoftTeams:
            let channel = object["channelData"] as? [String: Any]
            let tenant = channel?["tenant"] as? [String: Any]
            let team = channel?["team"] as? [String: Any]
            let targetChannel = channel?["channel"] as? [String: Any]
            normalized = ["tenantId": tenant?["id"] as Any,
                          "teamId": team?["id"] as Any,
                          "channelId": targetChannel?["id"] as Any,
                          "text": object["text"] ?? "", "authenticated": true, "raw": object].compactMapValues { Self.nonNil($0) }
            externalID = object["id"] as? String ?? nonce
        case .linear:
            let data = object["data"] as? [String: Any]
            normalized = ["event": (object["type"] as? String ?? object["action"] as? String ?? "unknown").lowercased(),
                          "primaryId": data?["teamId"] ?? data?["id"] as Any,
                          "secondaryId": data?["projectId"] as Any, "raw": object].compactMapValues { Self.nonNil($0) }
            externalID = object["webhookId"] as? String ?? nonce
        case .sentry:
            let data = object["data"] as? [String: Any]
            let project = data?["project"] as? [String: Any]
            normalized = ["event": object["action"] ?? request.headers["sentry-hook-resource"] ?? "unknown",
                          "primaryId": project?["slug"] ?? project?["id"] as Any,
                          "secondaryId": object["installation"] as Any, "raw": object].compactMapValues { Self.nonNil($0) }
            externalID = request.headers["sentry-hook-request-id"] ?? nonce
        case .pagerDuty:
            let event = object["event"] as? [String: Any] ?? object
            let data = event["data"] as? [String: Any]
            let service = data?["service"] as? [String: Any]
            normalized = ["event": event["event_type"] ?? object["event_type"] ?? "unknown",
                          "primaryId": service?["id"] as Any,
                          "secondaryId": data?["id"] as Any, "raw": object].compactMapValues { Self.nonNil($0) }
            externalID = event["id"] as? String ?? nonce
        }
        return AutomationEvent(connectorID: route.id, kind: route.provider.eventKind,
                               externalEventID: String(externalID.prefix(200)),
                               payloadJSON: try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]), occurredAt: now)
    }

    private static func githubEvent(_ event: String, action: String?, object: [String: Any]) -> String {
        return switch (event, action) {
        case ("pull_request", "opened"): "pr-opened"
        case ("pull_request", "synchronize"): "pr-pushed"
        case ("pull_request", "review_requested"): "review-requested"
        case ("pull_request", "closed") where (object["pull_request"] as? [String: Any])?["merged"] as? Bool == true: "pr-merged"
        case ("pull_request_review", "submitted"):
            switch ((object["review"] as? [String: Any])?["state"] as? String)?.lowercased() {
            case "approved": "review-approved"
            case "changes_requested": "review-changes-requested"
            case "commented": "review-commented"
            default: "unknown"
            }
        case ("issue_comment", "created") where (object["issue"] as? [String: Any])?["pull_request"] != nil: "pr-comment"
        case ("pull_request_review_comment", "created"): "inline-review-comment"
        case ("pull_request_review_thread", "resolved"): "review-thread-resolved"
        case ("pull_request_review_thread", "unresolved"): "review-thread-unresolved"
        case ("issues", "assigned"): "issue-assigned"
        case ("workflow_run", "completed"):
            githubWorkflowConclusion(object)
        default: "\(event)-\(action ?? "event")"
        }
    }
    private static func githubPROwner(_ object: [String: Any]) -> String? {
        if let pr = object["pull_request"] as? [String: Any] { return (pr["user"] as? [String: Any])?["login"] as? String }
        if let issue = object["issue"] as? [String: Any], issue["pull_request"] != nil {
            return (issue["user"] as? [String: Any])?["login"] as? String
        }
        return nil
    }
    private static func githubWorkflowConclusion(_ object: [String: Any]) -> String {
        guard let workflow = object["workflow_run"] as? [String: Any], workflow["event"] as? String == "push",
              workflow["status"] as? String == "completed",
              let repository = (object["repository"] as? [String: Any])?["full_name"] as? String,
              let headRepository = (workflow["head_repository"] as? [String: Any])?["full_name"] as? String,
              repository.caseInsensitiveCompare(headRepository) == .orderedSame else { return "unknown" }
        // A single workflow completion, not an aggregate checks/polling engine.
        switch workflow["conclusion"] as? String {
        case "success": return "ci-passed"
        case "failure", "timed_out": return "ci-failed"
        default: return "unknown"
        }
    }
    private static func githubBranch(_ object: [String: Any]) -> Any? {
        if let workflow = object["workflow_run"] as? [String: Any] { return workflow["head_branch"] }
        if let reference = object["ref"] as? String { return reference.replacingOccurrences(of: "refs/heads/", with: "") }
        return nil
    }
    private static func nonNil(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional && mirror.children.isEmpty ? nil : value
    }
}
