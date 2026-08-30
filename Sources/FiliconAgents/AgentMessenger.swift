import Foundation

public actor AgentMessenger {
    private let service: AgentService
    private let storeURL: URL
    private var state: AgentPersistentState

    public init(service: AgentService, storeURL: URL) throws {
        self.service = service; self.storeURL = storeURL
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            state = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: storeURL))
        } else { state = .init() }
    }

    public func send(_ message: AgentMessage) async throws {
        guard message.senderID != message.recipientID else { throw AgentServiceError.selfMessage }
        guard message.text.count <= 8_000 else { throw AgentServiceError.messageTooLong }
        guard await service.profile(id: message.senderID) != nil else { throw AgentServiceError.unknownAgent(message.senderID) }
        guard await service.profile(id: message.recipientID) != nil else { throw AgentServiceError.unknownAgent(message.recipientID) }
        guard !state.messages.contains(where: { $0.id == message.id }) else { throw AgentServiceError.duplicateMessage(message.id) }
        state.messages.append(message); try persist()
    }

    public func dequeue(recipientID: UUID, at: Date = Date()) throws -> AgentMessage? {
        let candidates = state.messages.indices.filter { state.messages[$0].recipientID == recipientID && state.messages[$0].deliveredAt == nil }
        guard let index = candidates.sorted(by: {
            let lhs = state.messages[$0], rhs = state.messages[$1]
            if lhs.priority != rhs.priority { return lhs.priority == .priority }
            return lhs.createdAt < rhs.createdAt
        }).first else { return nil }
        state.messages[index].deliveredAt = at
        let value = state.messages[index]
        try persist(); return value
    }

    public func allMessages() -> [AgentMessage] { state.messages }

    private func persist() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: storeURL, options: .atomic)
    }
}
