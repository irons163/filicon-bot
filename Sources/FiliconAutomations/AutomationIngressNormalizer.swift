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
            let issueID = object["type"] as? String == "Issue" ? linearID(data?["id"]) : nil
            let cycle = linearCycleCompletion(object, now: now)
            normalized = ["event": (object["type"] as? String ?? object["action"] as? String ?? "unknown").lowercased(),
                          // Keep the legacy entity event alongside explicit reference cases.
                          // Missing team IDs must never fall back to the issue's own ID.
                          "eventCase": (cycle != nil ? "endOfCycle" : linearEventCase(object)) as Any,
                          "primaryId": linearID(data?["teamId"]) as Any,
                          "secondaryId": linearID(data?["projectId"]) as Any,
                          "issueId": issueID as Any,
                          "statusId": (issueID != nil ? linearID(data?["stateId"]) : nil) as Any,
                          "cycleId": cycle?.id as Any,
                          "raw": object].compactMapValues { Self.nonNil($0) }
            let deliveryID: String?
            if let delivery = request.headers["linear-delivery"] {
                guard let valid = linearID(delivery) else { throw AutomationIngressError.invalidRequest }
                deliveryID = valid
            } else { deliveryID = nil }
            if let cycle {
                // Cycle completion is a logical transition, not a delivery.
                // Signed retries with new delivery IDs/timestamps must not run
                // the same completion again while execution history is retained.
                let milliseconds = Int64((cycle.completedAt.timeIntervalSince1970 * 1_000).rounded())
                externalID = "linear-cycle-end:\(cycle.id):\(milliseconds)"
            } else {
                // webhookId identifies the configured webhook, NOT a delivery.
                // The verifier supplies a digest of the signed body as fallback.
                externalID = deliveryID ?? nonce
            }
        case .sentry:
            let data = object["data"] as? [String: Any]
            let legacyProject = data?["project"] as? [String: Any]
            let issue = data?["issue"] as? [String: Any]
            let project = issue?["project"] as? [String: Any]
            let issueID = sentryID(issue?["id"])
            let eventCase = request.headers["sentry-hook-resource"] == "issue" && issueID != nil
                ? SentryIssueEvent(action: object["action"] as? String)?.rawValue : nil
            // Request-ID is documented by Sentry; accept the old Filicon header
            // only as a diagnostic alias. Neither is covered by the signature.
            for name in ["request-id", "sentry-hook-request-id"] {
                if let value = request.headers[name] {
                    guard !value.isEmpty, value.count <= 200,
                          value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                        throw AutomationIngressError.invalidRequest
                    }
                }
            }
            normalized = ["event": object["action"] ?? request.headers["sentry-hook-resource"] ?? "unknown",
                          "eventCase": eventCase as Any,
                          "projectId": sentryID(project?["id"]) as Any,
                          "issueId": issueID as Any,
                          "deliveryId": (request.headers["request-id"] ?? request.headers["sentry-hook-request-id"]) as Any,
                          "primaryId": legacyProject?["slug"] ?? legacyProject?["id"] as Any,
                          "secondaryId": object["installation"] as Any, "raw": object].compactMapValues { Self.nonNil($0) }
            // Sentry has no signed delivery ID/timestamp. Keep the body digest
            // as event identity too, so retained run history cannot be bypassed
            // by relabeling a request after the ingress replay window expires.
            externalID = nonce
        case .pagerDuty:
            let envelope = object["event"] as? [String: Any]
            let event = envelope ?? object
            let data = event["data"] as? [String: Any]
            let service = data?["service"] as? [String: Any]
            let eventID = pagerDutyID(event["id"])
            if event["id"] != nil && eventID == nil { throw AutomationIngressError.invalidRequest }
            let incidentID = data?["type"] as? String == "incident" ? pagerDutyID(data?["id"]) : nil
            let eventCase = envelope != nil && eventID != nil && event["resource_type"] as? String == "incident" && incidentID != nil
                ? PagerDutyIncidentEvent(eventType: event["event_type"] as? String)?.rawValue : nil
            for name in ["x-webhook-id", "x-pagerduty-delivery"] {
                if let value = request.headers[name], pagerDutyID(value) == nil { throw AutomationIngressError.invalidRequest }
            }
            normalized = ["event": event["event_type"] ?? object["event_type"] ?? "unknown",
                          "eventCase": eventCase as Any,
                          "serviceId": (service?["type"] as? String == "service_reference" ? pagerDutyID(service?["id"]) : nil) as Any,
                          "incidentId": incidentID as Any,
                          "deliveryId": (request.headers["x-webhook-id"] ?? request.headers["x-pagerduty-delivery"]) as Any,
                          // Preserve the legacy raw-event filter keys.
                          "primaryId": service?["id"] as Any,
                          "secondaryId": data?["id"] as Any, "raw": object].compactMapValues { Self.nonNil($0) }
            // event.id is the signed V3 event identity, not an incident or
            // subscription ID. Missing legacy IDs fall back to body digest.
            externalID = eventID ?? nonce
        }
        return AutomationEvent(connectorID: route.id, kind: route.provider.eventKind,
                               externalEventID: String(externalID.prefix(200)),
                               payloadJSON: try JSONSerialization.data(withJSONObject: normalized, options: [.sortedKeys]), occurredAt: now)
    }

    private static func linearEventCase(_ object: [String: Any]) -> String? {
        guard object["type"] as? String == "Issue", let data = object["data"] as? [String: Any],
              linearID(data["id"]) != nil else { return nil }
        switch object["action"] as? String {
        case "create": return "issueCreated"
        case "update":
            guard let status = linearID(data["stateId"]),
                  let previous = object["updatedFrom"] as? [String: Any],
                  let previousStatus = previous["stateId"] else { return nil }
            // updatedFrom contains only changed properties. A title update or
            // unchanged/malformed state is not evidence of a status transition.
            guard previousStatus is NSNull || (linearID(previousStatus).map { $0 != status } ?? false) else { return nil }
            return "statusChanged"
        default: return nil
        }
    }

    private static func linearCycleCompletion(_ object: [String: Any], now: Date) -> (id: String, completedAt: Date)? {
        guard object["type"] as? String == "Cycle", object["action"] as? String == "update",
              let data = object["data"] as? [String: Any],
              let rawID = data["id"] as? String, rawID.count == 36, let id = UUID(uuidString: rawID),
              let team = data["teamId"] as? String, team.count == 36, UUID(uuidString: team) != nil,
              let previous = object["updatedFrom"] as? [String: Any], previous["completedAt"] is NSNull,
              let rawDate = data["completedAt"] as? String, rawDate.count <= 40,
              rawDate.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\z"#, options: .regularExpression) != nil else {
            return nil
        }
        // Linear documents completedAt=null as unfinished. endsAt alone (even
        // in the past), archive/progress changes or a missing prior value do
        // not prove completion. This is a native webhook adaptation, not the
        // reference cloud backend's already-classified endOfCycle event.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.isLenient = false
        formatter.dateFormat = rawDate.contains(".") ? "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSXXXXX" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        guard let date = formatter.date(from: rawDate), date.timeIntervalSince1970.isFinite, date <= now else { return nil }
        return (id.uuidString.lowercased(), date)
    }

    private static func linearID(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 200,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return value
    }

    private static func sentryID(_ value: Any?) -> String? {
        // The issue webhook serializes IDs as decimal strings. Never coerce a
        // Boolean/number (or fall back to a name/slug) into a project filter.
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 200,
              value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return value
    }

    private static func pagerDutyID(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.count <= 200,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        return value
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
