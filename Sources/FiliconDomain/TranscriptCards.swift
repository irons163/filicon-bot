import Foundation

/// A Codable JSON tree used only at forward-compatibility boundaries. Unknown
/// card payloads remain readable by older Filicon builds without granting them
/// executable behavior.
public enum TranscriptJSONValue: Codable, Hashable, Sendable {
    case object([String: TranscriptJSONValue])
    case array([TranscriptJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([TranscriptJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: TranscriptJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Unknown extensions are data, never authority. Protect likely credential
    /// fields before they can cross the persistence boundary.
    public var redactingSensitiveFields: TranscriptJSONValue {
        switch self {
        case .object(let object):
            return .object(Dictionary(uniqueKeysWithValues: object.map { key, value in
                (key, Self.isSensitive(key) ? .string("[REDACTED]") : value.redactingSensitiveFields)
            }))
        case .array(let values): return .array(values.map(\.redactingSensitiveFields))
        default: return self
        }
    }

    private static func isSensitive(_ key: String) -> Bool {
        let value = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["secret", "password", "passwd", "token", "api_key", "private_key", "authorization", "cookie", "credential", "client_secret"].contains(where: value.contains)
    }
}

/// Raw-representable rather than a closed enum so a future lifecycle remains
/// visible instead of making the whole message undecodable.
public struct TranscriptCardLifecycle: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let pending: Self = "pending"
    public static let draft: Self = "draft"
    public static let running: Self = "running"
    public static let waiting: Self = "waiting"
    public static let approved: Self = "approved"
    public static let denied: Self = "denied"
    public static let provided: Self = "provided"
    public static let connected: Self = "connected"
    public static let sent: Self = "sent"
    public static let succeeded: Self = "succeeded"
    public static let failed: Self = "failed"
    public static let cancelled: Self = "cancelled"
    public static let retired: Self = "retired"
}

public struct WidgetTranscriptCard: Codable, Hashable, Sendable {
    public var question: GroupQuestion?
    /// Display-only bookkeeping. Buttons require a separately issued native
    /// lease and automation-store entry; decoded metadata grants no authority.
    public var automationActivity: AutomationActivityTranscriptCard?
    public var title: String
    public var body: String
    public var widgetKind: String
    public var facts: [String: String]
    public init(title: String, body: String = "", widgetKind: String = "summary", facts: [String: String] = [:], question: GroupQuestion? = nil,
                automationActivity: AutomationActivityTranscriptCard? = nil) {
        self.question = question
        self.automationActivity = automationActivity
        self.title = title; self.body = body; self.widgetKind = widgetKind; self.facts = facts
    }
}

public enum AutomationActivityTranscriptAnswer: String, Codable, Hashable, Sendable {
    case keep, pause, neverAsk, resume, stayPaused

    public var labelKey: String {
        switch self {
        case .keep: "Keep running"
        case .pause: "Pause"
        case .neverAsk: "Never ask"
        case .resume: "Resume"
        case .stayPaused: "Stay paused"
        }
    }

    public var confirmationKey: String {
        switch self {
        case .keep: "Filicon kept this agent's routines running and postponed activity checks for 30 days."
        case .pause: "Filicon paused this agent's individual routines."
        case .neverAsk: "Filicon kept this agent's routines running and disabled activity checks for this agent."
        case .resume: "Filicon resumed this agent's guarded routines and postponed activity checks for 30 days."
        case .stayPaused: "Filicon left this agent's routines paused."
        }
    }
}

public struct AutomationActivityTranscriptCard: Codable, Hashable, Sendable {
    public let entryID: UUID
    public let guardID: UUID
    public let binding: DirectConversationAgentBinding
    public let conversationID: UUID
    public let isPaused: Bool
    public let isAcknowledgment: Bool
    public let answer: AutomationActivityTranscriptAnswer?
    public init(entryID: UUID, guardID: UUID, binding: DirectConversationAgentBinding, conversationID: UUID,
                isPaused: Bool, isAcknowledgment: Bool = false, answer: AutomationActivityTranscriptAnswer? = nil) {
        self.entryID = entryID; self.guardID = guardID; self.binding = binding; self.conversationID = conversationID
        self.isPaused = isPaused; self.isAcknowledgment = isAcknowledgment; self.answer = answer
    }
    public var bodyKey: String {
        if isAcknowledgment, let answer { return answer.confirmationKey }
        return isPaused ? "Automations were paused after prolonged unviewed activity."
            : "Automations have continued while you were away. Keep them running or pause them."
    }
}

/// Host publication data, never decoded as a widget action. Both the prompt
/// update and its acknowledgment are materialized in one chat transaction.
public struct AutomationActivityTranscriptPublication: Sendable {
    public let card: AutomationActivityTranscriptCard
    public let createdAt: Date
    public let answeredAt: Date?
    public let acknowledgmentID: UUID
    public init(card: AutomationActivityTranscriptCard, createdAt: Date, answeredAt: Date?, acknowledgmentID: UUID) {
        // The outbox uses epoch milliseconds while SQLite stores epoch seconds.
        // Normalize both paths before exact host-row comparison: submillisecond
        // floating-point round trips must not make a genuine receipt stale.
        self.card = card
        self.createdAt = Self.stableDate(createdAt)
        self.answeredAt = answeredAt.map(Self.stableDate)
        self.acknowledgmentID = acknowledgmentID
    }

    private static func stableDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    public var messages: [ChatMessage] {
        var values = [promptMessage(answer: card.answer)]
        if let answer = card.answer, let answeredAt {
            let acknowledgment = AutomationActivityTranscriptCard(entryID: card.entryID, guardID: card.guardID,
                binding: card.binding, conversationID: card.conversationID, isPaused: card.isPaused,
                isAcknowledgment: true, answer: answer)
            values.append(ChatMessage(id: acknowledgmentID, role: .system, text: acknowledgment.bodyKey, createdAt: answeredAt,
                transcriptCards: [.init(id: acknowledgmentID, lifecycle: .succeeded, createdAt: answeredAt, updatedAt: answeredAt,
                    payload: .widget(.init(title: "Automation activity check", body: acknowledgment.bodyKey,
                        widgetKind: "automationActivityAcknowledgment", automationActivity: acknowledgment)))]))
        }
        return values
    }

    /// Also used to prove that an existing row is exactly the host's unanswered
    /// version before updating it. Never overwrite a colliding user/model row.
    public func promptMessage(answer: AutomationActivityTranscriptAnswer?) -> ChatMessage {
        let prompt = AutomationActivityTranscriptCard(entryID: card.entryID, guardID: card.guardID,
            binding: card.binding, conversationID: card.conversationID, isPaused: card.isPaused, answer: answer)
        return ChatMessage(id: card.entryID, role: .assistant,
            text: "Automation activity check\n" + prompt.bodyKey, createdAt: createdAt,
            transcriptCards: [.init(id: card.entryID, lifecycle: answer == nil ? .waiting : .succeeded, createdAt: createdAt,
                updatedAt: answer == nil ? createdAt : (answeredAt ?? createdAt),
                payload: .widget(.init(title: "Automation activity check", body: prompt.bodyKey,
                    widgetKind: "automationActivity", automationActivity: prompt)))])
    }
}

public struct DraftTranscriptCard: Codable, Hashable, Sendable {
    public var draftID: String
    public var channel: String
    public var recipients: [String]
    public var subject: String?
    public var body: String
    /// Exact provider-neutral delivery target. Older cards decode with these
    /// fields unset and remain displayable, but cannot acquire send authority.
    public var connectionID: UUID?
    public var channelID: String?
    public var threadID: String?
    public init(
        draftID: String, channel: String, recipients: [String] = [],
        subject: String? = nil, body: String, connectionID: UUID? = nil,
        channelID: String? = nil, threadID: String? = nil
    ) {
        self.draftID = draftID; self.channel = channel; self.recipients = recipients
        self.subject = subject; self.body = body; self.connectionID = connectionID
        self.channelID = channelID; self.threadID = threadID
    }
}

public struct AutoReviewTranscriptCard: Codable, Hashable, Sendable {
    public var reviewID: String
    public var title: String
    public var summary: String
    public var findings: [String]
    public init(reviewID: String, title: String, summary: String = "", findings: [String] = []) {
        self.reviewID = reviewID; self.title = title; self.summary = summary; self.findings = findings
    }
}

public struct ListenerTranscriptCard: Codable, Hashable, Sendable {
    public var listenerID: String
    public var connector: String
    public var event: String
    public var filterSummary: String?
    public init(listenerID: String, connector: String, event: String, filterSummary: String? = nil) {
        self.listenerID = listenerID; self.connector = connector; self.event = event; self.filterSummary = filterSummary
    }
}

/// Intentionally has no secret/value field. A credential is supplied to a
/// Keychain-backed service after the typed intent is handled, never to chat.
public struct SecretRequestTranscriptCard: Codable, Hashable, Sendable {
    /// Presence routes through the agent-bound secure submission flow only.
    /// It must never fall back to the legacy generic credential action.
    public var directRequest: DirectSecretRequest?
    public var requestID: String
    public var service: String
    public var account: String?
    public var scope: String?
    public var prompt: String
    public init(requestID: String, service: String, account: String? = nil, scope: String? = nil, prompt: String = "Credential required", directRequest: DirectSecretRequest? = nil) {
        self.directRequest = directRequest
        self.requestID = requestID; self.service = service; self.account = account; self.scope = scope; self.prompt = prompt
    }
}

public struct ConnectorTranscriptCard: Codable, Hashable, Sendable {
    public var connectorID: String
    public var service: String
    public var title: String
    public var detail: String
    public var suggestions: [String]
    /// Defense in depth: the renderer action and the application registry must
    /// both allow an action. Missing on legacy cards means no dispatch.
    public var allowedActionIDs: [String]
    public init(
        connectorID: String, service: String, title: String, detail: String = "",
        suggestions: [String] = [], allowedActionIDs: [String] = []
    ) {
        self.connectorID = connectorID; self.service = service; self.title = title
        self.detail = detail; self.suggestions = suggestions
        self.allowedActionIDs = allowedActionIDs
    }
}

public struct LocalToolPermissionTranscriptCard: Codable, Hashable, Sendable {
    public var requestID: String
    public var toolName: String
    public var scope: String
    public var reason: String
    public var retiredNotice: String?
    public init(requestID: String, toolName: String, scope: String, reason: String = "", retiredNotice: String? = nil) {
        self.requestID = requestID; self.toolName = toolName; self.scope = scope; self.reason = reason; self.retiredNotice = retiredNotice
    }
}

public struct NoticeTranscriptCard: Codable, Hashable, Sendable {
    public var title: String
    public var message: String
    public var severity: String
    public init(title: String, message: String, severity: String = "information") {
        self.title = title; self.message = message; self.severity = severity
    }
}

public struct TimelineTranscriptCard: Codable, Hashable, Sendable {
    public var eventKind: String
    public var name: String?
    public var channel: String?
    public var automation: String?
    public var detail: String
    public init(eventKind: String, name: String? = nil, channel: String? = nil, automation: String? = nil, detail: String = "") {
        self.eventKind = eventKind; self.name = name; self.channel = channel; self.automation = automation; self.detail = detail
    }
}

public struct CloudAgentTranscriptCard: Codable, Hashable, Sendable {
    /// An external reference, never a local agent navigation target. Nil for legacy local cards.
    public var externalReferenceID: String?
    public var agentID: String
    public var bcID: String?
    public var threadID: String?
    public var title: String
    public var detail: String
    public init(agentID: String, bcID: String? = nil, threadID: String? = nil, title: String, detail: String = "", externalReferenceID: String? = nil) {
        self.externalReferenceID = externalReferenceID
        self.agentID = agentID; self.bcID = bcID; self.threadID = threadID; self.title = title; self.detail = detail
    }
}

public struct FileOperationTranscriptCard: Codable, Hashable, Sendable {
    public var operationID: String
    public var operation: String
    public var path: String
    public var diff: String?
    public var isBackground: Bool
    public var streamSummary: String?
    /// Exact authorized workspace root. Legacy cards without it stay inert.
    public var workspaceRoot: String?
    public init(
        operationID: String, operation: String, path: String, diff: String? = nil,
        isBackground: Bool = false, streamSummary: String? = nil,
        workspaceRoot: String? = nil
    ) {
        self.operationID = operationID; self.operation = operation; self.path = path
        self.diff = diff; self.isBackground = isBackground
        self.streamSummary = streamSummary; self.workspaceRoot = workspaceRoot
    }
}

public struct ShellTranscriptCard: Codable, Hashable, Sendable {
    public var operationID: String
    public var commandSummary: String
    public var workingDirectory: String?
    public var exitCode: Int?
    public var isBackground: Bool
    public var streamSummary: String?
    public init(operationID: String, commandSummary: String, workingDirectory: String? = nil, exitCode: Int? = nil, isBackground: Bool = false, streamSummary: String? = nil) {
        self.operationID = operationID; self.commandSummary = commandSummary; self.workingDirectory = workingDirectory; self.exitCode = exitCode; self.isBackground = isBackground; self.streamSummary = streamSummary
    }
}

/// The authoritative provider-neutral discriminator. Unknown cases retain a
/// safely redacted JSON payload and render as inert cards.
public enum TranscriptCardPayload: Hashable, Sendable {
    case widget(WidgetTranscriptCard)
    case draft(DraftTranscriptCard)
    case autoReview(AutoReviewTranscriptCard)
    case listener(ListenerTranscriptCard)
    case secretRequest(SecretRequestTranscriptCard)
    case connector(ConnectorTranscriptCard)
    case localToolPermission(LocalToolPermissionTranscriptCard)
    case notice(NoticeTranscriptCard)
    case timeline(TimelineTranscriptCard)
    case cloudAgent(CloudAgentTranscriptCard)
    case fileOperation(FileOperationTranscriptCard)
    case shell(ShellTranscriptCard)
    case unknown(type: String, payload: TranscriptJSONValue)

    public var type: String {
        switch self {
        case .widget: "widget"
        case .draft: "draft"
        case .autoReview: "auto_review"
        case .listener: "listener"
        case .secretRequest: "secret_request"
        case .connector: "connector"
        case .localToolPermission: "local_tool_permission"
        case .notice: "notice"
        case .timeline: "timeline"
        case .cloudAgent: "cloud_agent"
        case .fileOperation: "file_operation"
        case .shell: "shell"
        case .unknown(let type, _): type
        }
    }
}

public enum LocalToolPermissionDecision: String, Codable, Hashable, Sendable { case allowOnce, alwaysAllow, deny }

/// An action emitted by the renderer. It carries only identifiers and a closed
/// decision; execution belongs to an injected application service.
public enum TranscriptCardActionIntent: Codable, Hashable, Sendable {
    case approveReview(reviewID: String)
    case rejectReview(reviewID: String)
    case sendDraft(draftID: String)
    case connectListener(listenerID: String)
    case provideSecret(requestID: String)
    case connectorAction(connectorID: String, actionID: String)
    case decideLocalToolPermission(requestID: String, decision: LocalToolPermissionDecision)
    case openCloudAgent(agentID: String, threadID: String?)
    case revealFileDiff(operationID: String)
    case cancelShell(operationID: String)
    case retry(cardID: UUID)
    case dismiss(cardID: UUID)
    case unknown(type: String, payload: TranscriptJSONValue)

    private enum Keys: String, CodingKey { case type, payload }
    private enum PayloadKeys: String, CodingKey { case reviewID, draftID, listenerID, requestID, connectorID, actionID, decision, agentID, threadID, operationID, cardID }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        let raw = (try? container.decode(TranscriptJSONValue.self, forKey: .payload)) ?? .object([:])
        let data = try JSONEncoder().encode(raw)
        let values = (try? JSONDecoder().decode([String: TranscriptJSONValue].self, from: data)) ?? [:]
        func string(_ key: String) -> String? { if case .string(let value) = values[key] { value } else { nil } }
        switch type {
        case "approve_review" where string("reviewID") != nil: self = .approveReview(reviewID: string("reviewID")!)
        case "reject_review" where string("reviewID") != nil: self = .rejectReview(reviewID: string("reviewID")!)
        case "send_draft" where string("draftID") != nil: self = .sendDraft(draftID: string("draftID")!)
        case "connect_listener" where string("listenerID") != nil: self = .connectListener(listenerID: string("listenerID")!)
        case "provide_secret" where string("requestID") != nil: self = .provideSecret(requestID: string("requestID")!)
        case "connector_action" where string("connectorID") != nil && string("actionID") != nil: self = .connectorAction(connectorID: string("connectorID")!, actionID: string("actionID")!)
        case "decide_local_tool_permission" where string("requestID") != nil && string("decision").flatMap(LocalToolPermissionDecision.init(rawValue:)) != nil:
            self = .decideLocalToolPermission(requestID: string("requestID")!, decision: LocalToolPermissionDecision(rawValue: string("decision")!)!)
        case "open_cloud_agent" where string("agentID") != nil: self = .openCloudAgent(agentID: string("agentID")!, threadID: string("threadID"))
        case "reveal_file_diff" where string("operationID") != nil: self = .revealFileDiff(operationID: string("operationID")!)
        case "cancel_shell" where string("operationID") != nil: self = .cancelShell(operationID: string("operationID")!)
        case "retry" where string("cardID").flatMap(UUID.init(uuidString:)) != nil: self = .retry(cardID: UUID(uuidString: string("cardID")!)!)
        case "dismiss" where string("cardID").flatMap(UUID.init(uuidString:)) != nil: self = .dismiss(cardID: UUID(uuidString: string("cardID")!)!)
        default: self = .unknown(type: type, payload: raw.redactingSensitiveFields)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        let type: String
        let values: [String: TranscriptJSONValue]
        switch self {
        case .approveReview(let id): type = "approve_review"; values = ["reviewID": .string(id)]
        case .rejectReview(let id): type = "reject_review"; values = ["reviewID": .string(id)]
        case .sendDraft(let id): type = "send_draft"; values = ["draftID": .string(id)]
        case .connectListener(let id): type = "connect_listener"; values = ["listenerID": .string(id)]
        case .provideSecret(let id): type = "provide_secret"; values = ["requestID": .string(id)]
        case .connectorAction(let connector, let action): type = "connector_action"; values = ["connectorID": .string(connector), "actionID": .string(action)]
        case .decideLocalToolPermission(let request, let decision): type = "decide_local_tool_permission"; values = ["requestID": .string(request), "decision": .string(decision.rawValue)]
        case .openCloudAgent(let agent, let thread): type = "open_cloud_agent"; values = ["agentID": .string(agent), "threadID": thread.map(TranscriptJSONValue.string) ?? .null]
        case .revealFileDiff(let id): type = "reveal_file_diff"; values = ["operationID": .string(id)]
        case .cancelShell(let id): type = "cancel_shell"; values = ["operationID": .string(id)]
        case .retry(let id): type = "retry"; values = ["cardID": .string(id.uuidString)]
        case .dismiss(let id): type = "dismiss"; values = ["cardID": .string(id.uuidString)]
        case .unknown(let unknownType, let payload):
            try container.encode(unknownType, forKey: .type)
            try container.encode(payload.redactingSensitiveFields, forKey: .payload)
            return
        }
        try container.encode(type, forKey: .type)
        try container.encode(TranscriptJSONValue.object(values), forKey: .payload)
    }

    public var isRendererSafe: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public struct TranscriptCardAction: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var role: String
    public var intent: TranscriptCardActionIntent
    public init(id: String, label: String, role: String = "normal", intent: TranscriptCardActionIntent) {
        self.id = id; self.label = label; self.role = role; self.intent = intent
    }
}

public struct TranscriptCard: Identifiable, Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public var id: UUID
    public var schemaVersion: Int
    public var lifecycle: TranscriptCardLifecycle
    public var createdAt: Date
    public var updatedAt: Date
    public var payload: TranscriptCardPayload
    public var actions: [TranscriptCardAction]

    public init(id: UUID = UUID(), schemaVersion: Int = currentSchemaVersion, lifecycle: TranscriptCardLifecycle, createdAt: Date = Date(), updatedAt: Date = Date(), payload: TranscriptCardPayload, actions: [TranscriptCardAction] = []) {
        self.id = id; self.schemaVersion = schemaVersion; self.lifecycle = lifecycle; self.createdAt = createdAt; self.updatedAt = updatedAt; self.payload = payload; self.actions = actions
    }

    private enum Keys: String, CodingKey { case id, schemaVersion, type, lifecycle, createdAt, updatedAt, payload, actions }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 1
        lifecycle = (try? container.decode(TranscriptCardLifecycle.self, forKey: .lifecycle)) ?? .pending
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date(timeIntervalSince1970: 0)
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? createdAt
        // A malformed/future action must not make an otherwise displayable card
        // disappear. Unknown valid actions decode inertly; invalid ones are omitted.
        actions = (try? container.decode([TranscriptCardAction].self, forKey: .actions)) ?? []
        let type = try container.decode(String.self, forKey: .type)
        let raw = ((try? container.decode(TranscriptJSONValue.self, forKey: .payload)) ?? .object([:])).redactingSensitiveFields
        payload = Self.decodePayload(type: type, raw: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(payload.type, forKey: .type)
        try container.encode(lifecycle, forKey: .lifecycle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(Self.encodePayload(payload).redactingSensitiveFields, forKey: .payload)
        try container.encode(actions, forKey: .actions)
    }

    private static func decodePayload(type: String, raw: TranscriptJSONValue) -> TranscriptCardPayload {
        func decode<T: Decodable>(_ type: T.Type) -> T? {
            guard let data = try? JSONEncoder().encode(raw) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        switch type {
        case "widget": return decode(WidgetTranscriptCard.self).map(TranscriptCardPayload.widget) ?? .unknown(type: type, payload: raw)
        case "draft": return decode(DraftTranscriptCard.self).map(TranscriptCardPayload.draft) ?? .unknown(type: type, payload: raw)
        case "auto_review": return decode(AutoReviewTranscriptCard.self).map(TranscriptCardPayload.autoReview) ?? .unknown(type: type, payload: raw)
        case "listener": return decode(ListenerTranscriptCard.self).map(TranscriptCardPayload.listener) ?? .unknown(type: type, payload: raw)
        case "secret_request": return decode(SecretRequestTranscriptCard.self).map(TranscriptCardPayload.secretRequest) ?? .unknown(type: type, payload: raw)
        case "connector": return decode(ConnectorTranscriptCard.self).map(TranscriptCardPayload.connector) ?? .unknown(type: type, payload: raw)
        case "local_tool_permission": return decode(LocalToolPermissionTranscriptCard.self).map(TranscriptCardPayload.localToolPermission) ?? .unknown(type: type, payload: raw)
        case "notice": return decode(NoticeTranscriptCard.self).map(TranscriptCardPayload.notice) ?? .unknown(type: type, payload: raw)
        case "timeline": return decode(TimelineTranscriptCard.self).map(TranscriptCardPayload.timeline) ?? .unknown(type: type, payload: raw)
        case "cloud_agent": return decode(CloudAgentTranscriptCard.self).map(TranscriptCardPayload.cloudAgent) ?? .unknown(type: type, payload: raw)
        case "file_operation": return decode(FileOperationTranscriptCard.self).map(TranscriptCardPayload.fileOperation) ?? .unknown(type: type, payload: raw)
        case "shell": return decode(ShellTranscriptCard.self).map(TranscriptCardPayload.shell) ?? .unknown(type: type, payload: raw)
        default: return .unknown(type: type, payload: raw)
        }
    }

    private static func encodePayload(_ payload: TranscriptCardPayload) -> TranscriptJSONValue {
        if case .unknown(_, let raw) = payload { return raw }
        let data: Data?
        switch payload {
        case .widget(let value): data = try? JSONEncoder().encode(value)
        case .draft(let value): data = try? JSONEncoder().encode(value)
        case .autoReview(let value): data = try? JSONEncoder().encode(value)
        case .listener(let value): data = try? JSONEncoder().encode(value)
        case .secretRequest(let value): data = try? JSONEncoder().encode(value)
        case .connector(let value): data = try? JSONEncoder().encode(value)
        case .localToolPermission(let value): data = try? JSONEncoder().encode(value)
        case .notice(let value): data = try? JSONEncoder().encode(value)
        case .timeline(let value): data = try? JSONEncoder().encode(value)
        case .cloudAgent(let value): data = try? JSONEncoder().encode(value)
        case .fileOperation(let value): data = try? JSONEncoder().encode(value)
        case .shell(let value): data = try? JSONEncoder().encode(value)
        case .unknown: data = nil
        }
        return data.flatMap { try? JSONDecoder().decode(TranscriptJSONValue.self, from: $0) } ?? .object([:])
    }
}
