import Foundation

struct AgentPersistentState: Codable, Sendable {
    var schemaVersion = 2
    var agents: [AgentProfile] = []
    var subagents: [SubagentRecord] = []
    var wakes: [PendingAgentWake] = []
    var messages: [AgentMessage] = []
    var groups: [AgentGroup] = []
    var roomMessages: [RoomMessage] = []
    var reactions: [MessageReaction] = []
    var memories: [AgentMemory] = []
    var projects: [AgentProject] = []
    var memorySuggestionSettings: [AgentMemorySuggestionSettings] = []
    var memorySuggestions: [AgentMemorySuggestion] = []
    var memorySuggestionReceipts: [AgentMemorySuggestionReceipt] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, agents, subagents, wakes, messages, groups, roomMessages, reactions, memories, projects
        case memorySuggestionSettings, memorySuggestions, memorySuggestionReceipts
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        agents = try values.decodeIfPresent([AgentProfile].self, forKey: .agents) ?? []
        subagents = try values.decodeIfPresent([SubagentRecord].self, forKey: .subagents) ?? []
        wakes = try values.decodeIfPresent([PendingAgentWake].self, forKey: .wakes) ?? []
        messages = try values.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        groups = try values.decodeIfPresent([AgentGroup].self, forKey: .groups) ?? []
        roomMessages = try values.decodeIfPresent([RoomMessage].self, forKey: .roomMessages) ?? []
        reactions = try values.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
        memories = try values.decodeIfPresent([AgentMemory].self, forKey: .memories) ?? []
        projects = try values.decodeIfPresent([AgentProject].self, forKey: .projects) ?? []
        memorySuggestionSettings = try values.decodeIfPresent([AgentMemorySuggestionSettings].self, forKey: .memorySuggestionSettings) ?? []
        memorySuggestions = try values.decodeIfPresent([AgentMemorySuggestion].self, forKey: .memorySuggestions) ?? []
        memorySuggestionReceipts = try values.decodeIfPresent([AgentMemorySuggestionReceipt].self, forKey: .memorySuggestionReceipts) ?? []
        schemaVersion = 2
    }
}

actor AgentStateStore {
    private let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> AgentPersistentState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        return try JSONDecoder.agents.decode(AgentPersistentState.self, from: Data(contentsOf: url))
    }

    func save(_ state: AgentPersistentState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.agents.encode(state).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}

private extension JSONEncoder {
    static var agents: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.prettyPrinted, .sortedKeys]; value.dateEncodingStrategy = .millisecondsSince1970; return value }
}
private extension JSONDecoder {
    static var agents: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value }
}
