import Foundation

public protocol GroupAgentResponder: Sendable {
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage], onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String]
}

public extension GroupAgentResponder {
    func respond(agent: AgentProfile, history: [RoomMessage], onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String] {
        try await respond(agent: agent, history: history)
    }
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
    private var activeResponses: [UUID: Task<[String], any Error>] = [:]

    public init(agents: AgentService, storeURL: URL) throws {
        self.agents = agents; self.storeURL = storeURL
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            state = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: storeURL))
        } else { state = .init() }
        // A process restart cannot resume an in-flight tool or its approval.
        for index in state.roomMessages.indices {
            for toolIndex in state.roomMessages[index].toolActivities.indices where state.roomMessages[index].toolActivities[toolIndex].status == .pending {
                state.roomMessages[index].toolActivities[toolIndex].status = .cancelled
            }
        }
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
        if previous.memberIDs != memberIDs { stop(groupID: groupID) }
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
        stop(groupID: groupID)
        try persist()
    }

    public func postUserMessage(_ text: String, groupID: UUID) async throws -> RoomMessage {
        guard let group = state.groups.first(where: { $0.id == groupID }) else { throw AgentServiceError.unknownGroup(groupID) }
        let members = await resolveMembers(group.memberIDs)
        if let unknown = Self.unknownMentions(in: text, members: members).first {
            throw AgentServiceError.unknownGroupMention(unknown)
        }
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
        activeResponses[groupID]?.cancel()
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
                let activityMessage = RoomMessage(groupID: groupID, senderID: memberID, text: "")
                await onAgentChange(agent.id)
                guard epochs[groupID] == epoch, !Task.isCancelled else {
                    await onAgentChange(nil)
                    return produced
                }
                let responseTask = Task {
                    try Task.checkCancellation()
                    return try await responder.respond(agent: agent, history: history) { tools in
                        try await self.recordTools(tools, message: activityMessage, epoch: epoch, onMessage: onMessage)
                    }
                }
                activeResponses[groupID] = responseTask
                do {
                    responses = try await withTaskCancellationHandler {
                        try await responseTask.value
                    } onCancel: { responseTask.cancel() }
                    successfulTurns += 1
                } catch {
                    try await finishPendingTools(messageID: activityMessage.id, cancelled: error is CancellationError || epochs[groupID] != epoch || Task.isCancelled, onMessage: onMessage)
                    await onAgentChange(nil)
                    guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
                    if firstFailure == nil { firstFailure = error }
                    continue
                }
                guard epochs[groupID] == epoch, !Task.isCancelled else {
                    try await finishPendingTools(messageID: activityMessage.id, cancelled: true, onMessage: onMessage)
                    return produced
                }
                activeResponses[groupID] = nil
                await onAgentChange(nil)
                guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
                var sentThisTurn = 0
                for text in responses {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Self.isPass(trimmed) else { continue }
                    var message = RoomMessage(groupID: groupID, senderID: memberID, text: String(trimmed.prefix(8_000)))
                    if sentThisTurn == 0, let index = state.roomMessages.firstIndex(where: { $0.id == activityMessage.id }) {
                        state.roomMessages[index].text = message.text
                        message = state.roomMessages[index]
                    } else { state.roomMessages.append(message) }
                    try persist()
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
        if epochs[groupID] == epoch { activeResponses[groupID] = nil }
        if successfulTurns == 0, let firstFailure { throw firstFailure }
        try persist()
        return produced
    }

    public func stop(groupID: UUID) {
        epochs[groupID, default: 0] &+= 1
        activeResponses.removeValue(forKey: groupID)?.cancel()
    }

    private func recordTools(_ tools: [RoomToolActivity], message: RoomMessage, epoch: UInt64, onMessage: @Sendable (RoomMessage) async -> Void) async throws {
        try Task.checkCancellation()
        guard epochs[message.groupID] == epoch else { throw CancellationError() }
        var updated = message
        updated.toolActivities = tools
        if let index = state.roomMessages.firstIndex(where: { $0.id == message.id }) {
            state.roomMessages[index] = updated
        } else { state.roomMessages.append(updated) }
        try persist()
        await onMessage(updated)
    }

    private func finishPendingTools(messageID: UUID, cancelled: Bool, onMessage: @Sendable (RoomMessage) async -> Void) async throws {
        guard let index = state.roomMessages.firstIndex(where: { $0.id == messageID }) else { return }
        for toolIndex in state.roomMessages[index].toolActivities.indices where state.roomMessages[index].toolActivities[toolIndex].status == .pending {
            state.roomMessages[index].toolActivities[toolIndex].status = cancelled ? .cancelled : .failed
        }
        try persist()
        await onMessage(state.roomMessages[index])
    }

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
        let everyone = ["everyone", "all"].contains { matchesMention($0, in: lower) }
        var ids: [UUID] = []
        for member in members {
            let matched = mentionHandles(for: member.name).contains { handle in
                matchesMention(handle, in: lower)
            }
            if matched && !ids.contains(member.id) { ids.append(member.id) }
        }
        return (everyone, ids)
    }

    private static func matchesMention(_ handle: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: handle)
        return text.range(of: #"(?<![\p{L}\p{N}._%+\-])@"# + escaped + #"(?![\p{L}\p{N}_\-])"#, options: .regularExpression) != nil
    }

    public static func unknownMentions(in text: String, members: [AgentProfile]) -> [String] {
        let lower = text.lowercased()
        // Remove complete known handles first (including names containing spaces).
        var remainder = lower
        let handles = (["everyone", "all"] + members.flatMap { mentionHandles(for: $0.name) }).sorted { $0.count > $1.count }
        for handle in handles {
            let escaped = NSRegularExpression.escapedPattern(for: handle)
            let pattern = #"(?<![\p{L}\p{N}._%+\-])@"# + escaped + #"(?![\p{L}\p{N}_\-])"#
            remainder = remainder.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        let regex = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}._%+\-])@([\p{L}\p{N}_\-]+)"#)
        return regex.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder)).compactMap {
            Range($0.range(at: 1), in: remainder).map { String(remainder[$0]) }
        }
    }

    public static func isPass(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.range(of: #"^\(?\s*pass\s*\)?\.?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func resolveResponderIDs(members: [AgentProfile], history: [RoomMessage]) -> [UUID] {
        // Only the user's address controls recipients, not an assistant quoting
        // another handle or escalating a private mention to @everyone.
        let text = history.last(where: { $0.senderID == nil })?.text ?? ""
        guard unknownMentions(in: text, members: members).isEmpty else { return [] }
        let targets = parseMentions(in: text, members: members)
        if targets.everyone || targets.memberIDs.isEmpty { return members.map(\.id) }
        return targets.memberIDs
    }

    private static func rotated<T>(_ values: [T], by offset: Int) -> [T] {
        guard !values.isEmpty else { return [] }
        let normalized = ((offset % values.count) + values.count) % values.count
        return Array(values[normalized...]) + Array(values[..<normalized])
    }
}
