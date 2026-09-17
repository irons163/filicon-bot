import Foundation
import FiliconDomain

public struct AgentProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var instructions: String
    public var providerID: ProviderID
    public var modelID: ModelID
    public var createdAt: Date
    public var archivedAt: Date?
    public var title: String
    public var updatedAt: Date
    public var status: AgentAvailabilityStatus
    public var unreadCount: Int
    public var avatar: AgentAvatar?

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        instructions: String = "",
        providerID: ProviderID = "fake",
        modelID: ModelID = "fake-stream",
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        title: String = "",
        updatedAt: Date? = nil,
        status: AgentAvailabilityStatus = .idle,
        unreadCount: Int = 0,
        avatar: AgentAvatar? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.providerID = providerID
        self.modelID = modelID
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.title = title
        self.updatedAt = updatedAt ?? createdAt
        self.status = status
        self.unreadCount = max(0, unreadCount)
        self.avatar = avatar
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, instructions, providerID, modelID, createdAt, archivedAt
        case title, updatedAt, status, unreadCount, avatar
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        summary = try values.decodeIfPresent(String.self, forKey: .summary) ?? ""
        instructions = try values.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        providerID = try values.decodeIfPresent(ProviderID.self, forKey: .providerID) ?? "fake"
        modelID = try values.decodeIfPresent(ModelID.self, forKey: .modelID) ?? "fake-stream"
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        archivedAt = try values.decodeIfPresent(Date.self, forKey: .archivedAt)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        status = try values.decodeIfPresent(AgentAvailabilityStatus.self, forKey: .status) ?? .idle
        unreadCount = max(0, try values.decodeIfPresent(Int.self, forKey: .unreadCount) ?? 0)
        avatar = try values.decodeIfPresent(AgentAvatar.self, forKey: .avatar)
    }
}

public enum AgentAvailabilityStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case idle, running, awaitingInput, failed, offline
}

public enum AgentAvatarKind: String, Codable, Hashable, Sendable { case character, image, pet }

public enum AgentPetAvatar: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, dewey, fireball, hoots, rocky, seedy, stacky, bsod
    case nullSignal = "null-signal"
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .codex: "Codex"
        case .dewey: "Dewey"
        case .fireball: "Fireball"
        case .hoots: "Hoots"
        case .rocky: "Rocky"
        case .seedy: "Seedy"
        case .stacky: "Stacky"
        case .bsod: "BSOD"
        case .nullSignal: "Null Signal"
        }
    }
}
public enum AgentAvatarShape: String, Codable, CaseIterable, Hashable, Sendable {
    case circle, roundedSquare, hexagon
}

/// A small, portable reference. Image bytes live in the avatar content-addressed store.
public struct AgentAvatar: Codable, Hashable, Sendable {
    public var kind: AgentAvatarKind
    public var character: String?
    public var colorHex: String
    public var shape: AgentAvatarShape
    public var imageHash: String?
    public var imageRelativePath: String?
    public var petID: String?

    public init(
        kind: AgentAvatarKind = .character,
        character: String? = nil,
        colorHex: String = "#5B6CFF",
        shape: AgentAvatarShape = .circle,
        imageHash: String? = nil,
        imageRelativePath: String? = nil,
        petID: String? = nil
    ) {
        self.kind = kind
        self.character = character.map { String($0.prefix(2)) }
        self.colorHex = AgentAvatar.normalizedColor(colorHex)
        self.shape = shape
        self.imageHash = imageHash
        self.imageRelativePath = imageRelativePath
        self.petID = petID
    }

    public static func character(_ value: String, colorHex: String, shape: AgentAvatarShape) -> Self {
        .init(kind: .character, character: value, colorHex: colorHex, shape: shape)
    }

    public static func image(hash: String, relativePath: String, shape: AgentAvatarShape = .circle) -> Self {
        .init(kind: .image, shape: shape, imageHash: hash, imageRelativePath: relativePath)
    }

    public static func pet(_ pet: AgentPetAvatar, shape: AgentAvatarShape = .circle) -> Self {
        .init(kind: .pet, shape: shape, petID: pet.rawValue)
    }

    private static func normalizedColor(_ value: String) -> String {
        let candidate = value.uppercased()
        let pattern = /^#[0-9A-F]{6}$/
        return candidate.wholeMatch(of: pattern) == nil ? "#5B6CFF" : candidate
    }
}

public enum AgentRunStatus: String, Codable, Hashable, Sendable {
    case queued, running, awaitingInput, succeeded, failed, cancelled, interrupted
}

public struct SubagentRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let parentRunID: UUID
    public let parentToolCallID: String
    public let agentID: UUID
    public var title: String
    public var status: AgentRunStatus
    public let depth: Int
    public let startedAt: Date
    public var finishedAt: Date?
    public var result: String?
    public var usage: Usage
    public var taskKind: AgentTaskKind
    public var isCancellationAllowed: Bool
    public var parentAgentID: UUID?

    public init(
        id: UUID = UUID(), parentRunID: UUID, parentToolCallID: String,
        agentID: UUID, title: String, status: AgentRunStatus = .queued,
        depth: Int, startedAt: Date = Date(), finishedAt: Date? = nil,
        result: String? = nil, usage: Usage = .init(),
        taskKind: AgentTaskKind = .subagent,
        isCancellationAllowed: Bool = true,
        parentAgentID: UUID? = nil
    ) {
        self.id = id; self.parentRunID = parentRunID; self.parentToolCallID = parentToolCallID
        self.agentID = agentID; self.title = title; self.status = status; self.depth = depth
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.result = result; self.usage = usage
        self.taskKind = taskKind; self.isCancellationAllowed = isCancellationAllowed
        self.parentAgentID = parentAgentID
    }

    private enum CodingKeys: String, CodingKey {
        case id, parentRunID, parentToolCallID, agentID, title, status, depth, startedAt
        case finishedAt, result, usage, taskKind, isCancellationAllowed, parentAgentID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        parentRunID = try values.decode(UUID.self, forKey: .parentRunID)
        parentToolCallID = try values.decode(String.self, forKey: .parentToolCallID)
        agentID = try values.decode(UUID.self, forKey: .agentID)
        title = try values.decode(String.self, forKey: .title)
        status = try values.decodeIfPresent(AgentRunStatus.self, forKey: .status) ?? .queued
        depth = try values.decodeIfPresent(Int.self, forKey: .depth) ?? 0
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        finishedAt = try values.decodeIfPresent(Date.self, forKey: .finishedAt)
        result = try values.decodeIfPresent(String.self, forKey: .result)
        usage = try values.decodeIfPresent(Usage.self, forKey: .usage) ?? .init()
        taskKind = try values.decodeIfPresent(AgentTaskKind.self, forKey: .taskKind) ?? .subagent
        isCancellationAllowed = try values.decodeIfPresent(Bool.self, forKey: .isCancellationAllowed) ?? true
        parentAgentID = try values.decodeIfPresent(UUID.self, forKey: .parentAgentID)
    }
}

public enum AgentTaskKind: String, Codable, CaseIterable, Hashable, Sendable {
    case subagent, shell, cloud
}

public struct SubagentExecutionScope: Codable, Hashable, Sendable {
    public var allowedToolNames: Set<String>
    public var allowedConnectorIDs: Set<String>
    public var readableRoots: Set<String>
    public var writableRoots: Set<String>

    public init(
        allowedToolNames: Set<String> = [],
        allowedConnectorIDs: Set<String> = [],
        readableRoots: Set<String> = [],
        writableRoots: Set<String> = []
    ) {
        self.allowedToolNames = allowedToolNames
        self.allowedConnectorIDs = allowedConnectorIDs
        self.readableRoots = readableRoots
        self.writableRoots = writableRoots
    }

    public func contains(_ child: Self) -> Bool {
        allowedToolNames.isSuperset(of: child.allowedToolNames)
            && allowedConnectorIDs.isSuperset(of: child.allowedConnectorIDs)
            && readableRoots.isSuperset(of: child.readableRoots)
            && writableRoots.isSuperset(of: child.writableRoots)
    }
}

public struct SubagentSpec: Hashable, Sendable {
    public let agentID: UUID
    public let title: String
    public let prompt: String
    public let parentToolCallID: String
    public let depth: Int
    public let ancestorAgentIDs: [UUID]
    public let scope: SubagentExecutionScope
    public let maximumTokens: Int?
    public let parentAgentID: UUID?
    public let taskKind: AgentTaskKind

    public init(
        agentID: UUID,
        title: String,
        prompt: String,
        parentToolCallID: String,
        depth: Int,
        ancestorAgentIDs: [UUID] = [],
        scope: SubagentExecutionScope = .init(),
        maximumTokens: Int? = nil,
        parentAgentID: UUID? = nil,
        taskKind: AgentTaskKind = .subagent
    ) {
        self.agentID = agentID
        self.title = title
        self.prompt = prompt
        self.parentToolCallID = parentToolCallID
        self.depth = depth
        self.ancestorAgentIDs = ancestorAgentIDs
        self.scope = scope
        self.maximumTokens = maximumTokens
        self.parentAgentID = parentAgentID
        self.taskKind = taskKind
    }
}

public enum AgentWakeState: String, Codable, Hashable, Sendable { case armed, ready }

public struct PendingAgentWake: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let parentRunID: UUID
    public let workID: UUID
    public var state: AgentWakeState
    public var status: AgentRunStatus?
    public var result: String?
    public let createdAt: Date
    public var readyAt: Date?

    public init(
        id: UUID = UUID(), parentRunID: UUID, workID: UUID,
        state: AgentWakeState = .armed, status: AgentRunStatus? = nil,
        result: String? = nil, createdAt: Date = Date(), readyAt: Date? = nil
    ) {
        self.id = id
        self.parentRunID = parentRunID
        self.workID = workID
        self.state = state
        self.status = status
        self.result = result
        self.createdAt = createdAt
        self.readyAt = readyAt
    }
}

public enum AgentMessagePriority: String, Codable, Hashable, Sendable { case normal, priority }

/// Execution state is separate from the mailbox's read/unread marker.
public struct AgentMessageDelivery: Codable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case queued, running, completed, failed, cancelled }
    public let chainID: UUID
    public let originConversationID: UUID
    public var state: State
    public var response: String?

    public init(chainID: UUID, originConversationID: UUID, state: State = .queued, response: String? = nil) {
        self.chainID = chainID; self.originConversationID = originConversationID
        self.state = state; self.response = response
    }
}

public struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let senderID: UUID
    public let recipientID: UUID
    public let text: String
    public let priority: AgentMessagePriority
    public let createdAt: Date
    public var deliveredAt: Date?
    public var delivery: AgentMessageDelivery?

    public init(id: UUID = UUID(), senderID: UUID, recipientID: UUID, text: String,
                priority: AgentMessagePriority = .normal, createdAt: Date = Date(), deliveredAt: Date? = nil,
                delivery: AgentMessageDelivery? = nil) {
        self.id = id; self.senderID = senderID; self.recipientID = recipientID
        self.text = text; self.priority = priority; self.createdAt = createdAt; self.deliveredAt = deliveredAt
        self.delivery = delivery
    }
}

public struct AgentGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var memberIDs: [UUID]
    public var nextSpeakerOffset: Int

    public init(id: UUID = UUID(), name: String, summary: String = "", memberIDs: [UUID], nextSpeakerOffset: Int = 0) {
        self.id = id; self.name = name; self.summary = summary
        self.memberIDs = memberIDs; self.nextSpeakerOffset = nextSpeakerOffset
    }
}

/// Execution metadata comes from the host, never from the assistant's prose.
/// Arguments and results are deliberately excluded from the persisted group history.
public struct RoomToolActivity: Identifiable, Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, succeeded, failed, cancelled }
    public let id: String
    public let name: String
    public var status: Status
    public init(id: String, name: String, status: Status = .pending) {
        self.id = id; self.name = name; self.status = status
    }
}

/// Host-authored status, separate from model prose and tool results.
public enum RoomMemberOutcome: String, Codable, Hashable, Sendable { case passed, failed }

public struct RoomMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let groupID: UUID
    public let senderID: UUID?
    public var text: String
    public let createdAt: Date
    public var toolActivities: [RoomToolActivity]
    public var memberOutcome: RoomMemberOutcome?
    public init(id: UUID = UUID(), groupID: UUID, senderID: UUID?, text: String, createdAt: Date = Date(), toolActivities: [RoomToolActivity] = [], memberOutcome: RoomMemberOutcome? = nil) {
        self.id = id; self.groupID = groupID; self.senderID = senderID; self.text = text; self.createdAt = createdAt
        self.toolActivities = toolActivities
        self.memberOutcome = memberOutcome
    }

    private enum CodingKeys: String, CodingKey { case id, groupID, senderID, text, createdAt, toolActivities, memberOutcome }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        groupID = try values.decode(UUID.self, forKey: .groupID)
        senderID = try values.decodeIfPresent(UUID.self, forKey: .senderID)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        toolActivities = try values.decodeIfPresent([RoomToolActivity].self, forKey: .toolActivities) ?? []
        memberOutcome = try values.decodeIfPresent(RoomMemberOutcome.self, forKey: .memberOutcome)
    }
}

public struct MessageReaction: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(messageID.uuidString):\(actorID.uuidString):\(emoji)" }
    public let messageID: UUID
    public let actorID: UUID
    public let emoji: String
    public init(messageID: UUID, actorID: UUID, emoji: String) { self.messageID = messageID; self.actorID = actorID; self.emoji = emoji }
}

public enum AgentServiceError: LocalizedError, Equatable, Sendable {
    case limitExceeded(Int), invalidName, unknownAgent(UUID), unknownGroup(UUID)
    case duplicateMember, groupMemberLimit, selfMessage, messageTooLong
    case unknownGroupMention(String)
    case duplicateMessage(UUID), depthLimit, concurrencyLimit, invalidReaction
    case invalidSubagent, subagentNotRunning(UUID), cycleDetected, scopeEscalation
    case tokenBudgetExceeded
    public var errorDescription: String? {
        switch self {
        case .limitExceeded(let value): "Agent limit exceeded (maximum \(value))."
        case .invalidName: "A non-empty agent or group name is required."
        case .unknownAgent(let id): "Unknown agent \(id)."
        case .unknownGroup(let id): "Unknown group \(id)."
        case .duplicateMember: "A group cannot contain duplicate members."
        case .unknownGroupMention(let name): "No group member matches @\(name). Add the member or choose an existing name."
        case .groupMemberLimit: "Groups support at most six members."
        case .selfMessage: "Agents cannot message themselves."
        case .messageTooLong: "Agent messages are limited to 8,000 characters."
        case .duplicateMessage(let id): "Duplicate agent message \(id)."
        case .depthLimit: "Subagent depth limit reached."
        case .concurrencyLimit: "Subagent concurrency limit reached."
        case .invalidReaction: "Invalid reaction."
        case .invalidSubagent: "The subagent request is invalid."
        case .subagentNotRunning(let id): "Subagent \(id) is not running."
        case .cycleDetected: "Subagent lineage contains an agent cycle."
        case .scopeEscalation: "A subagent cannot gain permissions outside its parent scope."
        case .tokenBudgetExceeded: "Subagent token budget was exceeded."
        }
    }
}
