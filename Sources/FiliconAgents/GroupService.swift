import Foundation

public protocol GroupAgentResponder: Sendable {
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String]
}

public actor GroupService {
    public static let maximumMembers = 6
    public static let maximumRounds = 3
    public static let maximumMemberMessages = 10
    public static let maximumMessagesPerMemberTurn = 2
    private let agents: AgentService
    private let storeURL: URL
    private var state: AgentPersistentState
    private var epochs: [UUID: UInt64] = [:]

    public init(agents: AgentService, storeURL: URL) throws {
        self.agents = agents; self.storeURL = storeURL
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            state = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: storeURL))
        } else { state = .init() }
    }

    public func create(name: String, summary: String = "", memberIDs: [UUID]) async throws -> AgentGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        guard memberIDs.count <= Self.maximumMembers else { throw AgentServiceError.groupMemberLimit }
        guard Set(memberIDs).count == memberIDs.count else { throw AgentServiceError.duplicateMember }
        for id in memberIDs where await agents.profile(id: id) == nil { throw AgentServiceError.unknownAgent(id) }
        let group = AgentGroup(name: String(name.prefix(120)), summary: String(summary.prefix(2_000)), memberIDs: memberIDs)
        state.groups.append(group); try persist(); return group
    }

    public func list() -> [AgentGroup] { state.groups }

    /// Save the inspector's fields together, after validating the entire draft.
    public func update(groupID: UUID, name: String, summary: String, memberIDs: [UUID]) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        guard memberIDs.count <= Self.maximumMembers else { throw AgentServiceError.groupMemberLimit }
        guard Set(memberIDs).count == memberIDs.count else { throw AgentServiceError.duplicateMember }
        for id in memberIDs where await agents.profile(id: id) == nil { throw AgentServiceError.unknownAgent(id) }
        guard let index = state.groups.firstIndex(where: { $0.id == groupID }) else { throw AgentServiceError.unknownGroup(groupID) }
        let previous = state.groups[index]
        var updated = previous
        updated.name = String(name.prefix(120))
        updated.summary = String(summary.prefix(2_000))
        updated.memberIDs = memberIDs
        if previous.memberIDs != memberIDs { updated.nextSpeakerOffset = 0 }
        state.groups[index] = updated
        do { try persist() }
        catch { state.groups[index] = previous; throw error }
        if previous.memberIDs != memberIDs { epochs[groupID, default: 0] &+= 1 }
    }

    public func updateMembers(groupID: UUID, memberIDs: [UUID]) async throws {
        guard let index = state.groups.firstIndex(where: { $0.id == groupID }) else {
            throw AgentServiceError.unknownGroup(groupID)
        }
        guard memberIDs.count <= Self.maximumMembers else { throw AgentServiceError.groupMemberLimit }
        guard Set(memberIDs).count == memberIDs.count else { throw AgentServiceError.duplicateMember }
        for id in memberIDs where await agents.profile(id: id) == nil { throw AgentServiceError.unknownAgent(id) }
        state.groups[index].memberIDs = memberIDs
        state.groups[index].nextSpeakerOffset = 0
        epochs[groupID, default: 0] &+= 1
        try persist()
    }

    public func postUserMessage(_ text: String, groupID: UUID) throws -> RoomMessage {
        guard state.groups.contains(where: { $0.id == groupID }) else { throw AgentServiceError.unknownGroup(groupID) }
        let message = RoomMessage(groupID: groupID, senderID: nil, text: String(text.prefix(8_000)))
        state.roomMessages.append(message); try persist(); return message
    }

    public func run(
        groupID: UUID,
        responder: any GroupAgentResponder,
        onAgentChange: @escaping @Sendable (UUID?) async -> Void = { _ in },
        onMessage: @escaping @Sendable (RoomMessage) async -> Void = { _ in }
    ) async throws -> [RoomMessage] {
        guard let groupIndex = state.groups.firstIndex(where: { $0.id == groupID }) else { throw AgentServiceError.unknownGroup(groupID) }
        let group = state.groups[groupIndex]
        guard !group.memberIDs.isEmpty else { return [] }
        epochs[groupID, default: 0] &+= 1
        let epoch = epochs[groupID]!
        let members = await resolveMembers(group.memberIDs)
        var produced: [RoomMessage] = []
        var total = 0
        var successfulTurns = 0
        var attemptedMemberIDs: Set<UUID> = []
        var firstFailure: (any Error)?
        for round in 0..<Self.maximumRounds {
            guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
            let responderIDs = Self.resolveResponderIDs(members: members, history: state.roomMessages.filter { $0.groupID == groupID })
            let rotation = Self.rotated(responderIDs, by: round).filter { !attemptedMemberIDs.contains($0) }
            guard !rotation.isEmpty else { break }
            var messagesThisRound = 0
            for memberID in rotation {
                guard total < Self.maximumMemberMessages,
                      epochs[groupID] == epoch,
                      !Task.isCancelled,
                      let agent = members.first(where: { $0.id == memberID }) else { return produced }
                attemptedMemberIDs.insert(memberID)
                let history = state.roomMessages.filter { $0.groupID == groupID }
                let responses: [String]
                await onAgentChange(agent.id)
                do {
                    responses = try await responder.respond(agent: agent, history: history)
                    successfulTurns += 1
                } catch {
                    await onAgentChange(nil)
                    if firstFailure == nil { firstFailure = error }
                    continue
                }
                await onAgentChange(nil)
                guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
                var sentThisTurn = 0
                for text in responses {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Self.isPass(trimmed) else { continue }
                    let message = RoomMessage(groupID: groupID, senderID: memberID, text: String(trimmed.prefix(8_000)))
                    state.roomMessages.append(message)
                    produced.append(message)
                    await onMessage(message)
                    total += 1
                    messagesThisRound += 1
                    sentThisTurn += 1
                    if total >= Self.maximumMemberMessages || sentThisTurn >= Self.maximumMessagesPerMemberTurn { break }
                }
            }
            if messagesThisRound == 0 || total >= Self.maximumMemberMessages { break }
        }
        if successfulTurns == 0, let firstFailure { throw firstFailure }
        try persist()
        return produced
    }

    public func stop(groupID: UUID) { epochs[groupID, default: 0] &+= 1 }

    public func toggleReaction(messageID: UUID, actorID: UUID, emoji: String) throws -> Bool {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty, emoji.count <= 32, state.roomMessages.contains(where: { $0.id == messageID }) else { throw AgentServiceError.invalidReaction }
        if let index = state.reactions.firstIndex(where: { $0.messageID == messageID && $0.actorID == actorID && $0.emoji == emoji }) {
            state.reactions.remove(at: index); try persist(); return false
        }
        state.reactions.append(.init(messageID: messageID, actorID: actorID, emoji: emoji)); try persist(); return true
    }

    public func messages(groupID: UUID) -> [RoomMessage] { state.roomMessages.filter { $0.groupID == groupID } }
    public func reactions(messageID: UUID) -> [MessageReaction] { state.reactions.filter { $0.messageID == messageID } }

    private func persist() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: storeURL, options: .atomic)
    }

    private func resolveMembers(_ ids: [UUID]) async -> [AgentProfile] {
        var values: [AgentProfile] = []
        for id in ids {
            if let profile = await agents.profile(id: id), profile.archivedAt == nil { values.append(profile) }
        }
        return values
    }

    public static func mentionHandles(for name: String) -> [String] {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return [] }
        var handles = [lower, lower.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)]
        if let first = lower.split(whereSeparator: \.isWhitespace).first { handles.append(String(first)) }
        var seen: Set<String> = []
        return handles.filter { seen.insert($0).inserted }
    }

    public static func parseMentions(in text: String, members: [AgentProfile]) -> (everyone: Bool, memberIDs: [UUID]) {
        let lower = text.lowercased()
        let everyone = lower.range(of: #"(?:^|[^a-z0-9])@(everyone|all)\b"#, options: .regularExpression) != nil
        var ids: [UUID] = []
        for member in members {
            let matched = mentionHandles(for: member.name).contains { handle in
                let escaped = NSRegularExpression.escapedPattern(for: handle)
                return lower.range(of: "(?:^|[^a-z0-9])@\(escaped)(?![a-z0-9])", options: .regularExpression) != nil
            }
            if matched && !ids.contains(member.id) { ids.append(member.id) }
        }
        return (everyone, ids)
    }

    public static func isPass(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.range(of: #"^\(?\s*pass\s*\)?\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func resolveResponderIDs(members: [AgentProfile], history: [RoomMessage]) -> [UUID] {
        let start = history.lastIndex(where: { $0.senderID == nil }) ?? history.startIndex
        var everyone = false
        var mentioned: Set<UUID> = []
        if !history.isEmpty {
            for message in history[start...] {
                let targets = parseMentions(in: message.text, members: members)
                everyone = everyone || targets.everyone
                mentioned.formUnion(targets.memberIDs)
            }
        }
        if everyone || mentioned.isEmpty { return members.map(\.id) }
        return members.compactMap { mentioned.contains($0.id) ? $0.id : nil }
    }

    private static func rotated<T>(_ values: [T], by offset: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let normalized = ((offset % values.count) + values.count) % values.count
        return Array(values[normalized...]) + Array(values[..<normalized])
    }
}
