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
            normalized = [
                "channel": source["channel"] ?? "",
                "text": source["text"] ?? "",
                "reaction": source["reaction"] as Any,
                "isMention": (source["type"] as? String) == "app_mention",
                "isSelf": source["is_self"] ?? false,
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
        case ("pull_request", "closed") where (object["pull_request"] as? [String: Any])?["merged"] as? Bool == true: "pr-merged"
        case ("pull_request_review", "submitted"):
            switch ((object["review"] as? [String: Any])?["state"] as? String)?.lowercased() {
            case "approved": "review-approved"
            case "changes_requested": "review-changes-requested"
            default: "review-commented"
            }
        case ("issue_comment", _): "pr-comment"
        case ("pull_request_review_comment", _): "inline-review-comment"
        case ("issues", "assigned"): "issue-assigned"
        case ("workflow_run", "completed"):
            ((object["workflow_run"] as? [String: Any])?["conclusion"] as? String) == "success" ? "ci-passed" : "ci-failed"
        case ("push", _): "pr-pushed"
        default: "\(event)-\(action ?? "event")"
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
