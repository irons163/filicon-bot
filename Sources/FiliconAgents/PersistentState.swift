import Foundation

struct AgentPersistentState: Codable, Sendable {
    var schemaVersion = 2
    var agents: [AgentProfile] = []
    var sidebarVisibility: [AgentSidebarVisibility] = []
    var subagents: [SubagentRecord] = []
    var wakes: [PendingAgentWake] = []
    var messages: [AgentMessage] = []
    /// Host-owned address metadata; never supplied by SendToAgent or model prose.
    var mailboxAddresses: [UUID: String] = [:]
    var mailboxHumanInputs: Set<UUID> = []
    var groups: [AgentGroup] = []
    var roomMessages: [RoomMessage] = []
    /// Absent only in legacy envelopes. Current records may not silently reset.
    var groupReadBookkeeping: GroupReadBookkeeping?
    var reactions: [MessageReaction] = []
    var memories: [AgentMemory] = []
    var memoryTombstones: Set<AgentMemoryTombstone> = []
    var projects: [AgentProject] = []
    var memorySuggestionSettings: [AgentMemorySuggestionSettings] = []
    var memorySynthesisSettings: [AgentMemorySynthesisSettings] = []
    var memoryTemporalReviews: [AgentMemoryTemporalReview] = []
    var memoryEpisodeSettings: [AgentMemoryEpisodeSettings] = []
    var memoryEpisodes: [AgentMemoryEpisodeProgress] = []
    var memorySuggestions: [AgentMemorySuggestion] = []
    var memorySuggestionReceipts: [AgentMemorySuggestionReceipt] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, agents, subagents, wakes, messages, groups, roomMessages, reactions, memories, projects
        case memorySuggestionSettings, memorySuggestions, memorySuggestionReceipts
        case mailboxAddresses, mailboxHumanInputs
        case memoryTombstones
        case memorySynthesisSettings
        case memoryTemporalReviews
        case memoryEpisodeSettings, memoryEpisodes
        case sidebarVisibility
        case groupReadBookkeeping
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        agents = try values.decodeIfPresent([AgentProfile].self, forKey: .agents) ?? []
        sidebarVisibility = try values.decodeIfPresent([AgentSidebarVisibility].self, forKey: .sidebarVisibility) ?? []
        subagents = try values.decodeIfPresent([SubagentRecord].self, forKey: .subagents) ?? []
        wakes = try values.decodeIfPresent([PendingAgentWake].self, forKey: .wakes) ?? []
        messages = try values.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        mailboxAddresses = try values.decodeIfPresent([UUID: String].self, forKey: .mailboxAddresses) ?? [:]
        mailboxHumanInputs = try values.decodeIfPresent(Set<UUID>.self, forKey: .mailboxHumanInputs) ?? []
        groups = try values.decodeIfPresent([AgentGroup].self, forKey: .groups) ?? []
        roomMessages = try values.decodeIfPresent([RoomMessage].self, forKey: .roomMessages) ?? []
        // Explicit null is corrupt current data, not a historical envelope.
        groupReadBookkeeping = values.contains(.groupReadBookkeeping)
            ? try values.decode(GroupReadBookkeeping.self, forKey: .groupReadBookkeeping) : nil
        reactions = try values.decodeIfPresent([MessageReaction].self, forKey: .reactions) ?? []
        memories = try values.decodeIfPresent([AgentMemory].self, forKey: .memories) ?? []
        memoryTombstones = try values.decodeIfPresent(Set<AgentMemoryTombstone>.self, forKey: .memoryTombstones) ?? []
        projects = try values.decodeIfPresent([AgentProject].self, forKey: .projects) ?? []
        memorySuggestionSettings = try values.decodeIfPresent([AgentMemorySuggestionSettings].self, forKey: .memorySuggestionSettings) ?? []
        memorySynthesisSettings = try values.decodeIfPresent([AgentMemorySynthesisSettings].self, forKey: .memorySynthesisSettings) ?? []
        memoryTemporalReviews = try values.decodeIfPresent([AgentMemoryTemporalReview].self, forKey: .memoryTemporalReviews) ?? []
        memoryEpisodeSettings = try values.decodeIfPresent([AgentMemoryEpisodeSettings].self, forKey: .memoryEpisodeSettings) ?? []
        memoryEpisodes = try values.decodeIfPresent([AgentMemoryEpisodeProgress].self, forKey: .memoryEpisodes) ?? []
        guard memoryEpisodes.count <= 64 else { throw AgentMemorySuggestionError.invalid }
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
