import Foundation

public struct ProviderID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public struct ModelID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}

public enum MessageRole: String, Codable, Sendable { case system, user, assistant, tool }

public enum MessageDeliveryStatus: String, Codable, Hashable, Sendable {
    case queued, streaming, succeeded, failed, cancelled
}

public struct ChatReaction: Codable, Hashable, Sendable {
    public var emoji: String
    public var actorID: String

    public init(emoji: String, actorID: String) {
        self.emoji = emoji
        self.actorID = actorID
    }
}

public enum ToolActivityStatus: String, Codable, Hashable, Sendable {
    case running, succeeded, failed
}

public struct ToolActivity: Identifiable, Codable, Hashable, Sendable {
    public var id: ToolCallID
    public var name: ToolName
    public var argumentsJSON: String
    public var status: ToolActivityStatus
    public var result: String?

    public init(
        id: ToolCallID,
        name: ToolName,
        argumentsJSON: String = "",
        status: ToolActivityStatus = .running,
        result: String? = nil
    ) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.status = status
        self.result = result
    }
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var role: MessageRole
    public var text: String
    public var createdAt: Date
    public var attachments: [AttachmentMetadata]
    public var deliveryStatus: MessageDeliveryStatus
    public var deliveryError: String?
    public var reasoningText: String
    public var toolActivities: [ToolActivity]
    public var transcriptCards: [TranscriptCard]
    public var replyToMessageID: UUID?
    public var reactions: [ChatReaction]
    /// Host-assigned reference identity; never derived from a paginated view.
    public var shortAddress: String?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String,
        createdAt: Date = Date(),
        attachments: [AttachmentMetadata] = [],
        deliveryStatus: MessageDeliveryStatus = .succeeded,
        deliveryError: String? = nil,
        reasoningText: String = "",
        toolActivities: [ToolActivity] = [],
        transcriptCards: [TranscriptCard] = [],
        replyToMessageID: UUID? = nil,
        reactions: [ChatReaction] = [],
        shortAddress: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.attachments = attachments
        self.deliveryStatus = deliveryStatus
        self.deliveryError = deliveryError
        self.reasoningText = reasoningText
        self.toolActivities = toolActivities
        self.transcriptCards = transcriptCards
        self.replyToMessageID = replyToMessageID
        self.reactions = reactions
        self.shortAddress = shortAddress
    }

    public mutating func toggleReaction(emoji: String, actorID: String) -> Bool {
        let normalized = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !actorID.isEmpty else { return false }
        if let index = reactions.firstIndex(where: { $0.emoji == normalized && $0.actorID == actorID }) {
            reactions.remove(at: index)
            return false
        }
        reactions.append(ChatReaction(emoji: normalized, actorID: actorID))
        return true
    }

    public mutating func prepareForResend() {
        text = ""
        reasoningText = ""
        toolActivities = []
        transcriptCards = []
        deliveryStatus = .queued
        deliveryError = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, createdAt, attachments, deliveryStatus, deliveryError
        case reasoningText, toolActivities, transcriptCards, replyToMessageID, reactions, shortAddress
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(MessageRole.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        attachments = try values.decodeIfPresent([AttachmentMetadata].self, forKey: .attachments) ?? []
        deliveryStatus = try values.decodeIfPresent(MessageDeliveryStatus.self, forKey: .deliveryStatus) ?? .succeeded
        deliveryError = try values.decodeIfPresent(String.self, forKey: .deliveryError)
        reasoningText = try values.decodeIfPresent(String.self, forKey: .reasoningText) ?? ""
        toolActivities = try values.decodeIfPresent([ToolActivity].self, forKey: .toolActivities) ?? []
        transcriptCards = (try? values.decode([TranscriptCard].self, forKey: .transcriptCards)) ?? []
        replyToMessageID = try values.decodeIfPresent(UUID.self, forKey: .replyToMessageID)
        shortAddress = try values.decodeIfPresent(String.self, forKey: .shortAddress)
        reactions = try values.decodeIfPresent([ChatReaction].self, forKey: .reactions) ?? []
    }
}

/// Call only with the complete, canonical message history, never a page.
public enum DirectMessageAddressing {
    private static let limit = 1_000_000_000
    private static func number(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              value.count == 1 || value.first != "0", let n = Int(value), n < limit else { return nil }
        return n
    }
    private static func parse(_ address: String) -> (turn: Int?, response: Int?)? {
        guard address.first == "t", address.utf8.count <= 22 else { return nil }
        let body = address.dropFirst()
        if body.last == "u", let turn = number(body.dropLast()) { return (turn, nil) }
        let parts = body.split(separator: "s", omittingEmptySubsequences: false)
        guard parts.count == 2, let response = number(parts[1]) else { return nil }
        if parts[0] == "b" { return (nil, response) }
        guard let turn = number(parts[0]) else { return nil }
        return (turn, response)
    }
    public static func assignMissing(in conversation: inout Conversation) {
        // Reserve imports first, even when invalid or ambiguous. Resolution
        // rejects ambiguity; allocation must not silently repair identity.
        for message in conversation.messages {
            if let address = message.shortAddress,
               conversation.messageAddressReservations[message.id.uuidString] == nil {
                conversation.messageAddressReservations[message.id.uuidString] = address
            }
        }
        var reserved = Set(conversation.messageAddressReservations.values)
        var nextTurn = 0
        var nextResponse: [String: Int] = [:]
        for address in reserved {
            guard let parsed = parse(address) else { continue }
            if let turn = parsed.turn { nextTurn = max(nextTurn, turn + 1) }
            if let response = parsed.response {
                let prefix = "t\(parsed.turn.map(String.init) ?? "b")"
                nextResponse[prefix] = max(nextResponse[prefix, default: 0], response + 1)
            }
        }
        var turn: Int?
        var turnKnown = true
        for index in conversation.messages.indices {
            let message = conversation.messages[index]
            guard message.role == .user || message.role == .assistant else { continue }
            let key = message.id.uuidString
            var address = conversation.messageAddressReservations[key] ?? message.shortAddress
            if address == nil, message.role == .user || !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !message.attachments.isEmpty {
                if message.role == .user, nextTurn < limit {
                    address = "t\(nextTurn)u"
                    nextTurn += 1
                } else if message.role == .assistant, turnKnown {
                    let prefix = "t\(turn.map(String.init) ?? "b")"
                    let next = nextResponse[prefix, default: 0]
                    if next < limit { address = "\(prefix)s\(next)"; nextResponse[prefix] = next + 1 }
                }
            }
            if let address {
                conversation.messageAddressReservations[key] = address
                conversation.messages[index].shortAddress = address
                reserved.insert(address)
            }
            if message.role == .user {
                if let address, let parsed = parse(address), parsed.response == nil {
                    turn = parsed.turn; turnKnown = true
                } else { turnKnown = false }
            }
        }
    }
}

public struct Conversation: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var providerID: ProviderID
    public var modelID: ModelID
    public var reasoningEffort: ReasoningEffort
    public var messages: [ChatMessage]
    public var updatedAt: Date
    public var hiddenAt: Date?
    /// Includes deleted messages so old references can never name new content.
    public var messageAddressReservations: [String: String] = [:]
    public init(id: UUID = UUID(), title: String = "New conversation", providerID: ProviderID = "fake", modelID: ModelID = "fake-stream", reasoningEffort: ReasoningEffort = .disabled, messages: [ChatMessage] = [], updatedAt: Date = Date(), hiddenAt: Date? = nil) {
        self.id = id; self.title = title; self.providerID = providerID; self.modelID = modelID; self.reasoningEffort = reasoningEffort; self.messages = messages; self.updatedAt = updatedAt; self.hiddenAt = hiddenAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, providerID, modelID, reasoningEffort, messages, updatedAt, hiddenAt, messageAddressReservations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        providerID = try values.decode(ProviderID.self, forKey: .providerID)
        modelID = try values.decode(ModelID.self, forKey: .modelID)
        reasoningEffort = try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? .disabled
        messages = try values.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        hiddenAt = try values.decodeIfPresent(Date.self, forKey: .hiddenAt)
        messageAddressReservations = try values.decodeIfPresent([String: String].self, forKey: .messageAddressReservations) ?? [:]
    }

    @discardableResult
    public mutating func toggleReaction(messageID: UUID, emoji: String, actorID: String) -> Bool? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return nil }
        return messages[index].toggleReaction(emoji: emoji, actorID: actorID)
    }

    @discardableResult
    public mutating func deleteMessage(id: UUID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages.remove(at: index)
        for messageIndex in messages.indices where messages[messageIndex].replyToMessageID == id {
            messages[messageIndex].replyToMessageID = nil
        }
        updatedAt = Date()
        return true
    }
}

public struct Usage: Codable, Hashable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costMicros: Int64

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        costMicros: Int64 = 0
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.cacheWriteTokens = max(0, cacheWriteTokens)
        self.costMicros = max(0, costMicros)
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, costMicros
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            inputTokens: try values.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0,
            outputTokens: try values.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0,
            cacheReadTokens: try values.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0,
            cacheWriteTokens: try values.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0,
            costMicros: try values.decodeIfPresent(Int64.self, forKey: .costMicros) ?? 0
        )
    }

    /// Provider usage events are cumulative snapshots or disjoint partial snapshots,
    /// never deltas. Max-merge avoids double counting repeated terminal usage frames.
    public mutating func mergeCumulative(_ other: Usage) {
        inputTokens = max(inputTokens, other.inputTokens)
        outputTokens = max(outputTokens, other.outputTokens)
        cacheReadTokens = max(cacheReadTokens, other.cacheReadTokens)
        cacheWriteTokens = max(cacheWriteTokens, other.cacheWriteTokens)
        costMicros = max(costMicros, other.costMicros)
    }
}

public struct ToolDefinition: Codable, Hashable, Sendable {
    public let name: String
    public let description: String?
    public let inputSchema: Data
    public init(name: String, description: String? = nil, inputSchema: Data) { self.name = name; self.description = description; self.inputSchema = inputSchema }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
    public init(id: String, name: String, argumentsJSON: String) { self.id = id; self.name = name; self.argumentsJSON = argumentsJSON }
}

public struct InferenceRequest: Sendable {
    public let conversationID: UUID
    public let modelID: ModelID
    public let messages: [ChatMessage]
    public let tools: [ToolDescriptor]
    public let toolExchanges: [ToolExchange]
    public let attachmentsByMessageID: [UUID: [InferenceAttachment]]
    public let reasoningEffort: ReasoningEffort
    public init(conversationID: UUID, modelID: ModelID, messages: [ChatMessage], tools: [ToolDescriptor] = [], toolExchanges: [ToolExchange] = [], attachmentsByMessageID: [UUID: [InferenceAttachment]] = [:], reasoningEffort: ReasoningEffort = .disabled) {
        self.conversationID = conversationID; self.modelID = modelID; self.messages = messages; self.tools = tools; self.toolExchanges = toolExchanges; self.attachmentsByMessageID = attachmentsByMessageID; self.reasoningEffort = reasoningEffort
    }
}

public struct InferenceAttachment: Sendable, Hashable {
    public let metadata: AttachmentMetadata
    public let data: Data
    public init(metadata: AttachmentMetadata, data: Data) { self.metadata = metadata; self.data = data }
}

public enum FinishReason: String, Codable, Hashable, Sendable { case stop, length, toolUse, cancelled, unknown }

public enum InferenceEvent: Hashable, Sendable {
    case responseStarted(id: String?)
    case textDelta(String)
    case reasoningDelta(String)
    case toolCallStarted(id: ToolCallID, name: ToolName)
    case toolCallArgumentsDelta(id: ToolCallID, delta: String)
    case toolCallCompleted(NormalizedToolCall)
    case toolResult(NormalizedToolResult)
    case usage(Usage)
    case completed(FinishReason)
}

public extension ChatMessage {
    mutating func consume(_ event: InferenceEvent) {
        switch event {
        case .responseStarted:
            deliveryStatus = .streaming
        case .textDelta(let delta):
            deliveryStatus = .streaming
            text += delta
        case .reasoningDelta(let delta):
            deliveryStatus = .streaming
            reasoningText += delta
        case .toolCallStarted(let id, let name):
            deliveryStatus = .streaming
            if !toolActivities.contains(where: { $0.id == id }) {
                toolActivities.append(.init(id: id, name: name))
            }
        case .toolCallArgumentsDelta(let id, let delta):
            if let index = toolActivities.firstIndex(where: { $0.id == id }) {
                toolActivities[index].argumentsJSON += delta
            }
        case .toolCallCompleted(let call):
            let arguments = String(decoding: call.argumentsJSON, as: UTF8.self)
            if let index = toolActivities.firstIndex(where: { $0.id == call.id }) {
                toolActivities[index].name = call.name
                toolActivities[index].argumentsJSON = arguments
            } else {
                toolActivities.append(.init(id: call.id, name: call.name, argumentsJSON: arguments))
            }
        case .toolResult(let result):
            if let index = toolActivities.firstIndex(where: { $0.id == result.callID }) {
                toolActivities[index].status = result.isError ? .failed : .succeeded
                toolActivities[index].result = result.wireText
            } else {
                toolActivities.append(.init(
                    id: result.callID,
                    name: ToolName(rawValue: "tool"),
                    status: result.isError ? .failed : .succeeded,
                    result: result.wireText
                ))
            }
        case .completed(let reason):
            deliveryStatus = reason == .cancelled ? .cancelled : .succeeded
        case .usage:
            break
        }
    }
}

public struct ProviderDescriptor: Identifiable, Hashable, Sendable {
    public var id: ProviderID
    public var displayName: String
    public var requiresAPIKey: Bool
    /// Whether Filicon may add its own tool catalog to requests for this provider.
    /// Providers that own their own tool runtime (or accept text only) should set
    /// this to false so the app does not inject incompatible tool schemas.
    public var supportsToolCalling: Bool
    public init(
        id: ProviderID,
        displayName: String,
        requiresAPIKey: Bool,
        supportsToolCalling: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.requiresAPIKey = requiresAPIKey
        self.supportsToolCalling = supportsToolCalling
    }
}

public struct AIModel: Identifiable, Hashable, Sendable {
    public var id: ModelID
    public var displayName: String
    public var capabilities: AIModelCapabilities
    public var contextWindow: Int?
    public var maximumOutputTokens: Int?
    public var isDeprecated: Bool
    public init(id: ModelID, displayName: String? = nil, capabilities: AIModelCapabilities = .safeTextOnly,
                contextWindow: Int? = nil, maximumOutputTokens: Int? = nil, isDeprecated: Bool = false) {
        self.id = id; self.displayName = displayName ?? id.rawValue; self.capabilities = capabilities
        self.contextWindow = contextWindow; self.maximumOutputTokens = maximumOutputTokens; self.isDeprecated = isDeprecated
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Hashable, Sendable {
    case disabled, minimal, low, medium, high, xhigh
}

public enum AIModelModality: String, Codable, CaseIterable, Hashable, Sendable {
    case text, image, audio, video, document, tools
}

public struct AIModelCapabilities: Codable, Hashable, Sendable {
    public var inputModalities: Set<AIModelModality>
    public var outputModalities: Set<AIModelModality>
    public var reasoningEfforts: Set<ReasoningEffort>
    public init(inputModalities: Set<AIModelModality> = [.text], outputModalities: Set<AIModelModality> = [.text],
                reasoningEfforts: Set<ReasoningEffort> = [.disabled]) {
        self.inputModalities = inputModalities; self.outputModalities = outputModalities
        self.reasoningEfforts = reasoningEfforts.union([.disabled])
    }
    public static let safeTextOnly = AIModelCapabilities()
    public func supports(_ effort: ReasoningEffort) -> Bool { reasoningEfforts.contains(effort) }
}
