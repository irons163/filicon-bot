import Foundation

public actor AgentMessenger {
    private let service: AgentService
    private let storeURL: URL
    private var state: AgentPersistentState

    public init(service: AgentService, storeURL: URL) throws {
        self.service = service; self.storeURL = storeURL
        var loaded: AgentPersistentState
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            loaded = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: storeURL))
        } else { loaded = .init() }
        // An old acknowledgement is not permission to rerun work after restart.
        var recovered = false
        for index in loaded.messages.indices where loaded.messages[index].delivery?.state == .queued || loaded.messages[index].delivery?.state == .running {
            loaded.messages[index].delivery?.state = .cancelled
            recovered = true
        }
        if recovered { try Self.save(loaded, to: storeURL) }
        state = loaded
    }

    public func send(_ message: AgentMessage) async throws {
        guard message.senderID != message.recipientID else { throw AgentServiceError.selfMessage }
        guard message.text.count <= 8_000 else { throw AgentServiceError.messageTooLong }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentServiceError.invalidName }
        guard let sender = await service.profile(id: message.senderID), sender.archivedAt == nil else { throw AgentServiceError.unknownAgent(message.senderID) }
        guard let recipient = await service.profile(id: message.recipientID), recipient.archivedAt == nil else { throw AgentServiceError.unknownAgent(message.recipientID) }
        try Task.checkCancellation()
        guard !state.messages.contains(where: { $0.id == message.id }) else { throw AgentServiceError.duplicateMessage(message.id) }
        state.messages.append(message)
        do { try persist() } catch { state.messages.removeLast(); throw error }
    }

    public func dequeue(recipientID: UUID, at: Date = Date()) throws -> AgentMessage? {
        let candidates = state.messages.indices.filter { state.messages[$0].recipientID == recipientID && state.messages[$0].deliveredAt == nil }
        guard let index = candidates.sorted(by: {
            let lhs = state.messages[$0], rhs = state.messages[$1]
            if lhs.priority != rhs.priority { return lhs.priority == .priority }
            return lhs.createdAt < rhs.createdAt
        }).first else { return nil }
        let previous = state.messages[index]
        state.messages[index].deliveredAt = at
        let value = state.messages[index]
        do { try persist() } catch { state.messages[index] = previous; throw error }
        return value
    }

    public func allMessages() -> [AgentMessage] { state.messages }

    public func updateDelivery(id: UUID, state deliveryState: AgentMessageDelivery.State, response: String? = nil) throws {
        guard let index = state.messages.firstIndex(where: { $0.id == id }), state.messages[index].delivery != nil else { return }
        let previous = state.messages[index]
        // Terminal results cannot be resurrected by a late provider event.
        guard previous.delivery?.state == .queued || previous.delivery?.state == .running else { return }
        state.messages[index].delivery?.state = deliveryState
        // A state-only transition (especially Stop) must not erase a report
        // already published through SendMessage.
        if let response { state.messages[index].delivery?.response = String(response.prefix(8_000)) }
        do { try persist() } catch { state.messages[index] = previous; throw error }
    }

    private func persist() throws {
        try Self.save(state, to: storeURL)
    }

    private static func save(_ state: AgentPersistentState, to storeURL: URL) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: storeURL, options: .atomic)
    }
}
