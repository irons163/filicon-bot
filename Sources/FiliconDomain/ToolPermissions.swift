import Foundation

public enum LocalToolPermission: String, Codable, CaseIterable, Hashable, Sendable {
    case always
    case ask
    case never

    public var rank: Int {
        switch self {
        case .never: 0
        case .ask: 1
        case .always: 2
        }
    }

    public func constrained(by adminCeiling: LocalToolPermission?) -> LocalToolPermission {
        guard let adminCeiling else { return self }
        return rank <= adminCeiling.rank ? self : adminCeiling
    }
}
public enum LocalToolAction: String, Codable, CaseIterable, Hashable, Sendable {
    case runCommand = "run-command"
    case sendInput = "send-input"
    case readFile = "read-file"
    case listDirectory = "list-directory"
    case writeFile = "write-file"
}

public struct ToolApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let conversationID: UUID
    public let toolCallID: String
    public let action: LocalToolAction
    public let title: String
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        toolCallID: String,
        action: LocalToolAction,
        title: String,
        reason: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.action = action
        self.title = title
        self.reason = reason
        self.createdAt = createdAt
    }
}

public enum ToolPermissionDecision: Equatable, Sendable {
    case allowed
    case requiresApproval(ToolApprovalRequest)
    case denied
}
