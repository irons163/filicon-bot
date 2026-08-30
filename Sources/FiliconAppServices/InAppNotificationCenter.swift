import Foundation

public enum NotificationArgumentValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([NotificationArgumentValue])
    case object([String: NotificationArgumentValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([NotificationArgumentValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: NotificationArgumentValue].self) { self = .object(value) }
        else { throw NotificationTrayError.invalidArguments }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite else { throw NotificationTrayError.invalidArguments }
            try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public enum NotificationTrayAction: Codable, Hashable, Sendable {
    case openURL(label: String, url: URL)
    case dashboard(label: String, action: String, arguments: [String: NotificationArgumentValue], successMessage: String?)

    public static func openURL(label: String, rawURL: String) throws -> Self {
        guard let url = URL(string: rawURL) else { throw NotificationTrayError.unsafeURL }
        return try validated(.openURL(label: label, url: url))
    }

    public static func validatedDashboard(
        label: String,
        action: String,
        arguments: [String: NotificationArgumentValue] = [:],
        successMessage: String? = nil
    ) throws -> Self {
        try validated(.dashboard(label: label, action: action, arguments: arguments, successMessage: successMessage))
    }

    public static func validated(_ action: Self) throws -> Self {
        switch action {
        case .openURL(let label, let url):
            try requireLabel(label)
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false,
                  url.user == nil,
                  url.password == nil
            else { throw NotificationTrayError.unsafeURL }
        case .dashboard(let label, let action, let arguments, let successMessage):
            try requireLabel(label)
            let trimmed = action.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
                  trimmed.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
            else { throw NotificationTrayError.invalidAction }
            if let successMessage, successMessage.utf8.count > 1_024 { throw NotificationTrayError.boundsExceeded }
            let data = try JSONEncoder().encode(NotificationArgumentValue.object(arguments))
            guard data.count <= 32 * 1_024 else { throw NotificationTrayError.boundsExceeded }
        }
        return action
    }

    private static func requireLabel(_ label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 128 else { throw NotificationTrayError.invalidAction }
    }
}

public struct NotificationTrayDraft: Hashable, Sendable {
    public var agentID: String?
    public var title: String
    public var detail: String
    public var requestID: String?
    public var errorKind: String?
    public var rawDetail: String?
    public var actions: [NotificationTrayAction]
    public var dedupeKey: String?
    public var count: Int?

    public init(
        agentID: String? = nil,
        title: String,
        detail: String,
        requestID: String? = nil,
        errorKind: String? = nil,
        rawDetail: String? = nil,
        actions: [NotificationTrayAction] = [],
        dedupeKey: String? = nil,
        count: Int? = nil
    ) {
        self.agentID = agentID
        self.title = title
        self.detail = detail
        self.requestID = requestID
        self.errorKind = errorKind
        self.rawDetail = rawDetail
        self.actions = actions
        self.dedupeKey = dedupeKey
        self.count = count
    }
}

public struct InAppNotificationTray: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let agentID: String?
    public let title: String
    public let detail: String
    public let requestID: String?
    public let createdAt: Date
    public let errorKind: String?
    public let rawDetail: String?
    public let actions: [NotificationTrayAction]
    public let dedupeKey: String?
    public let count: Int?
}

public enum NotificationTrayEvent: Hashable, Sendable {
    case pushed(InAppNotificationTray)
    case dismissed(UUID)
    case cleared
}

public enum NotificationTrayError: Error, Equatable, LocalizedError, Sendable {
    case invalidTitle
    case boundsExceeded
    case invalidCount
    case invalidAction
    case invalidArguments
    case unsafeURL

    public var errorDescription: String? {
        switch self {
        case .invalidTitle: "Notification title must not be empty."
        case .boundsExceeded: "Notification data exceeds its safety limit."
        case .invalidCount: "Notification occurrence count must be positive."
        case .invalidAction: "Notification action is invalid."
        case .invalidArguments: "Notification action arguments are invalid."
        case .unsafeURL: "Notification links must use credential-free HTTP or HTTPS."
        }
    }
}

public actor InAppNotificationCenter {
    public static let maximumTrays = 20

    private var trays: [InAppNotificationTray] = []
    private var listeners: [UUID: AsyncStream<NotificationTrayEvent>.Continuation] = [:]
    private let makeID: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    public init(
        makeID: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.makeID = makeID
        self.now = now
    }

    public func list() -> [InAppNotificationTray] { trays }

    @discardableResult
    public func pushError(_ draft: NotificationTrayDraft) throws -> InAppNotificationTray {
        let validated = try validate(draft)
        let timestamp = now()
        if let key = validated.dedupeKey,
           let index = trays.firstIndex(where: { $0.dedupeKey == key }) {
            let existing = trays[index]
            let updated = InAppNotificationTray(
                id: existing.id,
                agentID: existing.agentID,
                title: validated.title,
                detail: validated.detail,
                requestID: validated.requestID,
                createdAt: timestamp,
                errorKind: validated.errorKind,
                rawDetail: validated.rawDetail,
                actions: validated.actions,
                dedupeKey: existing.dedupeKey,
                count: validated.count ?? (existing.count ?? 1) + 1
            )
            trays[index] = updated
            emit(.pushed(updated))
            return updated
        }

        let tray = InAppNotificationTray(
            id: makeID(),
            agentID: validated.agentID,
            title: validated.title,
            detail: validated.detail,
            requestID: validated.requestID,
            createdAt: timestamp,
            errorKind: validated.errorKind,
            rawDetail: validated.rawDetail,
            actions: validated.actions,
            dedupeKey: validated.dedupeKey,
            count: validated.dedupeKey == nil ? nil : (validated.count ?? 1)
        )
        trays.append(tray)
        emit(.pushed(tray))
        enforceCap()
        return tray
    }

    @discardableResult
    public func dismiss(id: UUID) -> Bool {
        guard let index = trays.firstIndex(where: { $0.id == id }) else { return false }
        trays.remove(at: index)
        emit(.dismissed(id))
        return true
    }

    public func clearAll() {
        guard !trays.isEmpty else { return }
        trays.removeAll()
        emit(.cleared)
    }

    public func clear(agentID: String) {
        let removed = trays.filter { $0.agentID == agentID }
        guard !removed.isEmpty else { return }
        trays.removeAll { $0.agentID == agentID }
        for tray in removed { emit(.dismissed(tray.id)) }
    }

    public func events() -> AsyncStream<NotificationTrayEvent> {
        let listenerID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.maximumTrays * 2)) { continuation in
            listeners[listenerID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeListener(listenerID) }
            }
        }
    }

    private func validate(_ draft: NotificationTrayDraft) throws -> NotificationTrayDraft {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw NotificationTrayError.invalidTitle }
        guard title.utf8.count <= 512,
              draft.detail.utf8.count <= 16 * 1_024,
              (draft.rawDetail?.utf8.count ?? 0) <= 32 * 1_024,
              (draft.agentID?.utf8.count ?? 0) <= 256,
              (draft.requestID?.utf8.count ?? 0) <= 512,
              (draft.errorKind?.utf8.count ?? 0) <= 128,
              (draft.dedupeKey?.utf8.count ?? 0) <= 512,
              draft.actions.count <= 3
        else { throw NotificationTrayError.boundsExceeded }
        if let count = draft.count, count < 1 { throw NotificationTrayError.invalidCount }
        var result = draft
        result.title = title
        result.actions = try draft.actions.map(NotificationTrayAction.validated)
        return result
    }

    private func enforceCap() {
        guard trays.count > Self.maximumTrays else { return }
        let dropped = trays.prefix(trays.count - Self.maximumTrays)
        trays.removeFirst(trays.count - Self.maximumTrays)
        for tray in dropped { emit(.dismissed(tray.id)) }
    }

    private func emit(_ event: NotificationTrayEvent) {
        for continuation in listeners.values { continuation.yield(event) }
    }

    private func removeListener(_ id: UUID) { listeners.removeValue(forKey: id) }
}
