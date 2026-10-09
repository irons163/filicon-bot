import Foundation
import FiliconDomain

/// Public room identity only. Never include another member's private instructions
/// or one-to-one history in the shared roster.
public struct GroupMemberIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let title: String
    public let summary: String

    public init(_ profile: AgentProfile) {
        id = profile.id; name = profile.name; title = profile.title; summary = profile.summary
    }
}

/// Process-local attestation of one native member attempt. A public context or
/// a provider error cannot construct it, and it grants no tool permissions.
public final class GroupMemberExecutionAttempt: @unchecked Sendable {
    public let number: Int
    let agentID: UUID
    private let scope = AgentWorkflowExecutionScope()
    private let lease: AgentWorkflowExecutionScope.Lease
    private let admissionLease: AgentWorkflowExecutionScope.Lease
    private let validateSource: @Sendable () async throws -> Void
    private let reactionLock = NSLock()
    private var reacted = false
    private var started = false

    fileprivate init(number: Int, agentID: UUID, inherited: AgentWorkflowExecutionScope.Lease,
                     admissionLease: AgentWorkflowExecutionScope.Lease,
                     validateSource: @escaping @Sendable () async throws -> Void) throws {
        self.number = number; self.agentID = agentID
        self.lease = try scope.capture(inheriting: inherited)
        self.admissionLease = admissionLease
        self.validateSource = validateSource
    }

    public func validate() async throws {
        try lease.check()
        if !reactionLock.withLock({ started }) { try admissionLease.check() }
        try await validateSource()
        if !reactionLock.withLock({ started }) { try admissionLease.check() }
        try lease.check()
    }

    /// Only the native scheduler calls this after actual lane admission. A
    /// queued attempt must retain its original complete public/private persona;
    /// an admitted turn may finish after a reviewed public name/summary edit.
    func beginExecution() async throws {
        try await validate()
        try admissionLease.commit { reactionLock.withLock { started = true } }
        try await validate()
    }

    func commit<Value>(_ operation: () throws -> Value) throws -> Value { try lease.commit(operation) }
    func close() { scope.invalidate() }
    fileprivate func markReaction() { reactionLock.withLock { reacted = true } }
    fileprivate var hasReacted: Bool { reactionLock.withLock { reacted } }
    fileprivate var hasBegun: Bool { reactionLock.withLock { started } }
}

public struct GroupTurnContext: Sendable {
    public let group: AgentGroup
    public let members: [GroupMemberIdentity]
    public let respondingMemberIDs: [UUID]
    public let round: Int
    public let newMessageIDs: Set<UUID>
    public let executionAttempt: GroupMemberExecutionAttempt?
    public let reactToMessage: (@Sendable (UUID, String) async throws -> Bool)?

    public init(group: AgentGroup, members: [GroupMemberIdentity], respondingMemberIDs: [UUID], round: Int, newMessageIDs: Set<UUID>) {
        self.group = group; self.members = members; self.respondingMemberIDs = respondingMemberIDs
        self.round = round; self.newMessageIDs = newMessageIDs
        self.executionAttempt = nil
        self.reactToMessage = nil
    }

    fileprivate init(group: AgentGroup, members: [GroupMemberIdentity], respondingMemberIDs: [UUID],
                     round: Int, newMessageIDs: Set<UUID>, executionAttempt: GroupMemberExecutionAttempt,
                     reactToMessage: @escaping @Sendable (UUID, String) async throws -> Bool) {
        self.group = group; self.members = members; self.respondingMemberIDs = respondingMemberIDs
        self.round = round; self.newMessageIDs = newMessageIDs
        self.executionAttempt = executionAttempt
        self.reactToMessage = reactToMessage
    }
}

/// Host attestation that immutable bytes have been stored and reviewed for this
/// recipient. Not Codable: model arguments must never construct this envelope.
/// The host remains responsible for blob ownership and quota before publishing.
public struct ReviewedGroupFile: Sendable {
    public let messageID: UUID
    public let metadata: AttachmentMetadata
    public let groupID: UUID
    public let senderID: UUID
    public let lifetime: AgentPublicationLifetime

    public init(metadata: AttachmentMetadata, groupID: UUID, senderID: UUID, lifetime: AgentPublicationLifetime, messageID: UUID = UUID()) throws {
        try Self.validate(metadata)
        self.metadata = metadata; self.groupID = groupID; self.senderID = senderID; self.lifetime = lifetime
        self.messageID = messageID
    }

    static func validate(_ metadata: AttachmentMetadata) throws {
        guard metadata.id.utf8.count == 64,
              metadata.id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !metadata.filename.isEmpty, metadata.filename != ".", metadata.filename != "..",
              metadata.filename.utf8.count <= 255,
              !metadata.filename.contains("/"), !metadata.filename.contains("\\"),
              !metadata.filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              metadata.byteCount >= 0, metadata.byteCount <= AttachmentLimits.byteLimit(filename: metadata.filename, mimeType: metadata.mimeType),
              !metadata.mimeType.isEmpty, metadata.mimeType.utf8.count <= 255,
              !metadata.mimeType.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              metadata.hasValidAltText else { throw AgentPublicationError.invalid }
    }
}

/// Host-only publication envelope. The model supplies text/image IDs, never
/// the source request, lifetime, room, or author of the resulting message.
public struct ReviewedGroupRemoteAttachment: Sendable {
    public let messageID: UUID
    public let reference: RemoteAttachmentReference
    public let groupID: UUID
    public let senderID: UUID
    public let lifetime: AgentPublicationLifetime
    public init(reference: RemoteAttachmentReference, groupID: UUID, senderID: UUID,
                lifetime: AgentPublicationLifetime, messageID: UUID = UUID()) {
        self.reference = reference; self.groupID = groupID; self.senderID = senderID
        self.lifetime = lifetime; self.messageID = messageID
    }
}

public struct ReviewedGroupImageGallery: Sendable {
    public let messageID: UUID
    public let text: String
    public let images: [AttachmentMetadata]
    public let gallery: RemoteImageGallery?
    public let imageGalleryLayout: ImageGalleryLayout?
    public let groupID: UUID
    public let senderID: UUID
    public let replyTo: UUID?
    public let lifetime: AgentPublicationLifetime
    public init(text: String, gallery: RemoteImageGallery, groupID: UUID, senderID: UUID,
                replyTo: UUID? = nil, lifetime: AgentPublicationLifetime, messageID: UUID = UUID()) {
        self.init(text: text, images: [], gallery: gallery,
            imageGalleryLayout: try? ImageGalleryLayout(items: gallery.images.map(ImageGalleryLayout.Item.remote)),
            groupID: groupID, senderID: senderID, replyTo: replyTo, lifetime: lifetime, messageID: messageID)
    }
    public init(text: String, images: [AttachmentMetadata], gallery: RemoteImageGallery?,
                imageGalleryLayout: ImageGalleryLayout?, groupID: UUID, senderID: UUID,
                replyTo: UUID? = nil, lifetime: AgentPublicationLifetime, messageID: UUID = UUID()) {
        self.text = text; self.images = images; self.gallery = gallery
        self.imageGalleryLayout = imageGalleryLayout; self.groupID = groupID; self.senderID = senderID
        self.replyTo = replyTo; self.lifetime = lifetime; self.messageID = messageID
    }
}

public struct GroupAgentPublication: Sendable {
    public let text: String
    public let images: [AttachmentMetadata]
    public let sourceUserMessageID: UUID?
    public let lifetime: AgentPublicationLifetime?
    public let question: GroupQuestion?
    public let cursorAgent: CursorAgentReference?
    public let replyToMessageID: UUID?
    public let file: ReviewedGroupFile?
    public let remoteAttachment: ReviewedGroupRemoteAttachment?
    public let remoteImages: ReviewedGroupImageGallery?
    public let externalPublication: ExternalChannelTranscriptPublication?

    public init(text: String, images: [AttachmentMetadata] = [], sourceUserMessageID: UUID? = nil,
                lifetime: AgentPublicationLifetime? = nil, question: GroupQuestion? = nil, replyToMessageID: UUID? = nil,
                cursorAgent: CursorAgentReference? = nil, file: ReviewedGroupFile? = nil,
                remoteAttachment: ReviewedGroupRemoteAttachment? = nil, remoteImages: ReviewedGroupImageGallery? = nil,
                externalPublication: ExternalChannelTranscriptPublication? = nil) {
        self.text = text; self.images = images
        self.sourceUserMessageID = sourceUserMessageID; self.lifetime = lifetime
        self.question = question
        self.cursorAgent = cursorAgent
        self.replyToMessageID = replyToMessageID
        self.file = file
        self.remoteAttachment = remoteAttachment
        self.remoteImages = remoteImages
        self.externalPublication = externalPublication
    }
}

public enum GroupReplyError: LocalizedError, Equatable, Sendable {
    case unavailable
    public var errorDescription: String? { "Choose an available message in this group to reply to. Nothing was sent." }
}

public protocol GroupAgentResponder: Sendable {
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage], onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext, onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onMessage: @escaping @Sendable (String) async throws -> Void) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onPublication: @escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String]
}

public extension GroupAgentResponder {
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        try await respond(agent: agent, history: history, context: context, onTools: onTools,
                          onPublication: { _ = try await onSavedPublication($0) })
    }

    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onPublication: @escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> [String] {
        try await respond(agent: agent, history: history, context: context, onTools: onTools,
                          onMessage: { try await onPublication(.init(text: $0)) })
    }

    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onMessage: @escaping @Sendable (String) async throws -> Void) async throws -> [String] {
        try await respond(agent: agent, history: history, context: context, onTools: onTools)
    }

    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext, onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String] {
        try await respond(agent: agent, history: history, onTools: onTools)
    }

    func respond(agent: AgentProfile, history: [RoomMessage], onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void) async throws -> [String] {
        try await respond(agent: agent, history: history)
    }
}

public actor GroupService {
    public static let maximumMembers = 6
    public static let maximumRounds = 3
    public static let maximumMemberMessages = 10
    public static let maximumMessagesPerMemberTurn = 2
    public static let maximumMemberPreemptionAttempts = 3
    public static let localUserReactionActorID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    private let agents: AgentService
    private let storeURL: URL
    private let activityDate: @Sendable () -> Date
    private let readStoreID = UUID()
    private var groupReadScopes: [UUID: AgentWorkflowExecutionScope] = [:]
    private var state: AgentPersistentState
    private var persistedState: AgentPersistentState
    private var epochs: [UUID: UInt64] = [:]
    private var activeResponses: [UUID: Task<[String], any Error>] = [:]
    private var groupExecutionScopes: [UUID: AgentWorkflowExecutionScope] = [:]
    private var activeAttempts: [UUID: GroupMemberExecutionAttempt] = [:]
    private var explicitReplies: [UUID: [RoomMessage]] = [:]

    public init(agents: AgentService, storeURL: URL, activityDate: @escaping @Sendable () -> Date = { Date() }) throws {
        self.agents = agents; self.storeURL = storeURL; self.activityDate = activityDate
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            state = try decoder.decode(AgentPersistentState.self, from: Data(contentsOf: storeURL))
        } else { state = .init() }
        if let bookkeeping = state.groupReadBookkeeping { try bookkeeping.validate(groupIDs: state.groups.map(\.id)) }
        else { state.groupReadBookkeeping = try .init(groups: state.groups, history: state.roomMessages) }
        GroupMessageAddressing.assignMissing(in: &state.roomMessages)
        // A process restart cannot resume an in-flight tool or its approval.
        for index in state.roomMessages.indices {
            for toolIndex in state.roomMessages[index].toolActivities.indices where state.roomMessages[index].toolActivities[toolIndex].status == .pending {
                state.roomMessages[index].toolActivities[toolIndex].status = .cancelled
            }
        }
        persistedState = state
    }

    public func create(name: String, summary: String = "", memberIDs: [UUID]) async throws -> AgentGroup {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AgentServiceError.invalidName }
        guard memberIDs.count <= Self.maximumMembers else { throw AgentServiceError.groupMemberLimit }
        guard Set(memberIDs).count == memberIDs.count else { throw AgentServiceError.duplicateMember }
        for id in memberIDs where await agents.profile(id: id) == nil { throw AgentServiceError.unknownAgent(id) }
        let group = AgentGroup(name: String(name.prefix(120)), summary: String(summary.prefix(2_000)), memberIDs: memberIDs)
        state.groups.append(group)
        state.groupReadBookkeeping?.records.append(.init(groupID: group.id, state: .init()))
        try persist()
        return group
    }

    public func list() -> [AgentGroup] { state.groups }

    /// Host-bound image handles for this request only. Being a room member is
    /// insufficient: the user must also have addressed this member in this turn.
    public func imagesForCurrentUserRequest(groupID: UUID, messageID: UUID, memberID: UUID) async throws -> [AttachmentMetadata] {
        guard let group = state.groups.first(where: { $0.id == groupID }), group.memberIDs.contains(memberID),
              let message = state.roomMessages.last(where: { $0.groupID == groupID && $0.senderID == nil }),
              message.id == messageID else { throw AgentGroupPostError.changed }
        let epoch = epochs[groupID]
        let members = await resolveMembers(group.memberIDs)
        // A choice answer resumes its authenticated asker, not a name typed
        // inside the answer. Match the routing used by run(groupID:...).
        let questionRecipient = message.questionReplyTo.flatMap { questionID in
            state.roomMessages.first(where: {
                $0.groupID == groupID && $0.id == questionID && $0.question?.responseMessageID == message.id
            })?.senderID
        }
        let addressed = questionRecipient.map { $0 == memberID }
            ?? Self.resolveResponderIDs(members: members, history: [message]).contains(memberID)
        try Task.checkCancellation()
        guard epochs[groupID] == epoch,
              state.groups.first(where: { $0.id == groupID })?.memberIDs == group.memberIDs,
              state.roomMessages.last(where: { $0.groupID == groupID && $0.senderID == nil }) == message,
              addressed else {
            throw AgentGroupPostError.changed
        }
        return message.images ?? []
    }

    public func audience(groupID: UUID, senderID: UUID) async throws -> AgentGroupAudience {
        guard let group = state.groups.first(where: { $0.id == groupID }), group.memberIDs.contains(senderID) else {
            throw AgentGroupPostError.unavailable
        }
        let members = await resolveMembers(group.memberIDs)
        guard members.contains(where: { $0.id == senderID }), members.count > 1,
              members.count == group.memberIDs.count else { throw AgentGroupPostError.unavailable }
        guard state.groups.first(where: { $0.id == groupID }) == group else { throw AgentGroupPostError.changed }
        return .init(group: group, members: members.map(GroupMemberIdentity.init))
    }

    public func postAgentMessage(_ message: RoomMessage, audience expected: AgentGroupAudience,
                                 lifetime: AgentGroupPostLifetime) async throws {
        var message = message
        message.shortAddress = nil
        guard let senderID = message.senderID, message.groupID == expected.id,
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.text.count <= 8_000,
              message.toolActivities.isEmpty, message.memberOutcome == nil,
              message.question == nil, message.secretRequest == nil, message.questionReplyTo == nil, message.replyToMessageID == nil else { throw AgentGroupPostError.unavailable }
        let current = try await audience(groupID: expected.id, senderID: senderID)
        guard current == expected else { throw AgentGroupPostError.changed }
        try lifetime.commit {
            guard let group = state.groups.first(where: { $0.id == expected.id }),
                  group.name == expected.name, group.memberIDs == expected.memberIDs else { throw AgentGroupPostError.changed }
            guard !state.roomMessages.contains(where: { $0.id == message.id }) else { throw AgentServiceError.duplicateMessage(message.id) }
            state.roomMessages.append(message)
            try persist()
        }
    }

    /// Host-only reports from approved cross-agent wakes. The app fences these
    /// to the originating request; they are not new user messages or @mentions.
    public func recordDelegatedMessage(_ message: RoomMessage) throws {
        guard message.question == nil, message.secretRequest == nil, message.questionReplyTo == nil, message.replyToMessageID == nil else { throw AgentQuestionError.unavailable }
        guard message.senderID != nil, state.groups.contains(where: { $0.id == message.groupID }) else {
            throw AgentServiceError.unknownGroup(message.groupID)
        }
        var message = message
        message.shortAddress = state.roomMessages.first(where: { $0.id == message.id && $0.groupID == message.groupID })?.shortAddress
        if let index = state.roomMessages.firstIndex(where: { $0.id == message.id && $0.groupID == message.groupID }) {
            state.roomMessages[index] = message
        } else { state.roomMessages.append(message) }
        try persist()
    }

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
        if previous.memberIDs != memberIDs { retireQuestions(groupID: groupID) }
        try persist()
        if previous.memberIDs != memberIDs {
            groupReadScopes[groupID]?.invalidate()
        }
        if previous.name != updated.name || previous.summary != updated.summary || previous.memberIDs != memberIDs {
            stop(groupID: groupID)
        }
    }

    public func updateMembers(groupID: UUID, memberIDs: [UUID]) async throws {
        guard let group = state.groups.first(where: { $0.id == groupID }) else {
            throw AgentServiceError.unknownGroup(groupID)
        }
        try await update(groupID: groupID, name: group.name, summary: group.summary, memberIDs: memberIDs)
    }

    /// A host-reviewed whole-group wake. Event mentions cannot retarget it;
    /// oversized seeds are rejected intact, never truncated into a new task.
    public func postRoutineMessage(_ text: String, group: AgentGroup, wake: GroupRoutineWake,
                                   lease: AgentWorkflowExecutionScope.Lease, at: Date) throws -> RoomMessage {
        guard !text.isEmpty, text.utf8.count <= 100_000, !wake.name.isEmpty, wake.name.count <= 80 else {
            throw AgentServiceError.messageTooLong
        }
        return try lease.commit {
            guard let current = state.groups.first(where: { $0.id == group.id }),
                  current.name == group.name, current.summary == group.summary,
                  current.memberIDs == group.memberIDs, !current.memberIDs.isEmpty else { throw CancellationError() }
            var message = RoomMessage(id: wake.runID, groupID: group.id, senderID: nil, text: text, createdAt: at)
            message.routineWake = wake
            guard !state.roomMessages.contains(where: { $0.id == wake.runID }) else { throw CancellationError() }
            retireQuestions(groupID: group.id, onlyMoveOn: true)
            state.roomMessages.append(message)
            try persist()
            return state.roomMessages.last(where: { $0.id == message.id }) ?? message
        }
    }

    public func postUserMessage(_ text: String, groupID: UUID, images: [AttachmentMetadata] = [],
                                expectedMemberIDs: [UUID]? = nil, replyToMessageID: UUID? = nil) async throws -> RoomMessage {
        // Truncating can remove a trailing @mention and turn a targeted image
        // request into a broadcast. Reject oversized input without posting it.
        guard text.count <= 8_000 else { throw AgentServiceError.messageTooLong }
        guard let group = state.groups.first(where: { $0.id == groupID }) else { throw AgentServiceError.unknownGroup(groupID) }
        if let expectedMemberIDs, group.memberIDs != expectedMemberIDs { throw CancellationError() }
        let epoch = epochs[groupID]
        let members = await resolveMembers(group.memberIDs)
        try Task.checkCancellation()
        guard epochs[groupID] == epoch, state.groups.first(where: { $0.id == groupID })?.memberIDs == group.memberIDs else {
            throw CancellationError()
        }
        if let unknown = Self.unknownMentions(in: text, members: members).first {
            throw AgentServiceError.unknownGroupMention(unknown)
        }
        if let replyToMessageID {
            guard GroupThreadProjection(history: state.roomMessages, groupID: groupID).canReply(to: replyToMessageID) else {
                throw GroupReplyError.unavailable
            }
        }
        var message = RoomMessage(groupID: groupID, senderID: nil, text: text, images: images)
        message.replyToMessageID = replyToMessageID
        retireQuestions(groupID: groupID, onlyMoveOn: true)
        state.roomMessages.append(message)
        try persist()
        stop(groupID: groupID)
        return state.roomMessages.last(where: { $0.id == message.id }) ?? message
    }

    public func answerQuestion(groupID: UUID, messageID: UUID, answer: AgentQuestionAnswer,
                               accountID: String, lifetime: AgentPublicationLifetime) async throws -> RoomMessage {
        guard let original = state.roomMessages.first(where: { $0.groupID == groupID && $0.id == messageID }),
              let card = original.question, card.isPending, card.accountID == accountID,
              let senderID = original.senderID,
              state.groups.first(where: { $0.id == groupID })?.memberIDs == card.memberIDs,
              card.memberIDs.contains(senderID) else { throw AgentQuestionError.unavailable }
        let text = try card.question.reply(for: answer)
        let epoch = epochs[groupID]
        guard let agent = await agents.profile(id: senderID), agent.archivedAt == nil else { throw AgentQuestionError.unavailable }
        try Task.checkCancellation()
        guard epochs[groupID] == epoch,
              state.groups.first(where: { $0.id == groupID })?.memberIDs == card.memberIDs,
              let index = state.roomMessages.firstIndex(where: { $0 == original }) else { throw AgentQuestionError.unavailable }
        var reply = RoomMessage(groupID: groupID, senderID: nil, text: text)
        reply.questionReplyTo = original.id
        if original.replyToMessageID != nil,
           GroupThreadProjection(history: state.roomMessages, groupID: groupID).canReply(to: original.id) {
            reply.replyToMessageID = original.id
        }
        try lifetime.commit {
            state.roomMessages[index].question?.answer = answer
            state.roomMessages[index].question?.responseMessageID = reply.id
            state.roomMessages.append(reply)
            try persist()
        }
        return state.roomMessages.last(where: { $0.id == reply.id }) ?? reply
    }

    private func retireQuestions(groupID: UUID, onlyMoveOn: Bool = false) {
        for index in state.roomMessages.indices where state.roomMessages[index].groupID == groupID {
            guard let question = state.roomMessages[index].question, question.isPending,
                  !onlyMoveOn || question.question.dismissOnMoveOn == true else { continue }
            state.roomMessages[index].question?.retired = true
        }
    }

    public func run(
        groupID: UUID,
        responder: any GroupAgentResponder,
        delegatedAudience: AgentGroupAudience? = nil,
        delegatedSenderID: UUID? = nil,
        executionLease: AgentWorkflowExecutionScope.Lease? = nil,
        onReaction: @escaping @Sendable ([MessageReaction]) async -> Void = { _ in },
        onAgentChange: @escaping @Sendable (UUID?) async -> Void = { _ in },
        onMessage: @escaping @Sendable (RoomMessage) async -> Void = { _ in }
    ) async throws -> [RoomMessage] {
        guard let groupIndex = state.groups.firstIndex(where: { $0.id == groupID }) else { throw AgentServiceError.unknownGroup(groupID) }
        let group = state.groups[groupIndex]
        if let delegatedAudience {
            guard group.id == delegatedAudience.id, group.memberIDs == delegatedAudience.memberIDs else { throw AgentGroupPostError.changed }
        }
        guard !group.memberIDs.isEmpty else { return [] }
        try executionLease?.check()
        activeAttempts.removeValue(forKey: groupID)?.close()
        activeResponses[groupID]?.cancel()
        let groupScope = groupExecutionScopes[groupID] ?? AgentWorkflowExecutionScope()
        groupExecutionScopes[groupID] = groupScope
        groupScope.invalidate()
        let groupLease = try groupScope.capture(inheriting: executionLease)
        epochs[groupID, default: 0] &+= 1
        let epoch = epochs[groupID]!
        let members = await resolveMembers(group.memberIDs)
        try groupLease.check()
        try validateMemberSource(group: group, epoch: epoch)
        var produced: [RoomMessage] = []
        var total = 0
        var successfulTurns = 0
        // A successful member can return when a peer has contributed something
        // new. Failed members are not retried automatically in the same run.
        var failedMemberIDs: Set<UUID> = []
        var seenMessageCounts: [UUID: Int] = [:]
        var publishedTexts: [UUID: Set<ReplyFingerprint>] = [:]
        var firstFailure: (any Error)?
        let initialHistory = state.roomMessages.filter { $0.groupID == groupID }
        let threadTarget = delegatedAudience == nil
            ? GroupThreadProjection(history: initialHistory, groupID: groupID).defaultReplyTargetID : nil
        let questionRecipient: UUID? = initialHistory.last(where: { $0.senderID == nil }).flatMap { reply in
            guard let questionID = reply.questionReplyTo,
                  let question = initialHistory.first(where: { $0.id == questionID }),
                  question.question?.responseMessageID == reply.id else { return nil }
            return question.senderID
        }
        let responderIDs = delegatedAudience.map { audience in
            members.filter { agent in audience.members.contains(where: { $0.id == agent.id }) && agent.id != delegatedSenderID }.map(\.id)
        } ?? questionRecipient.map { recipient in members.filter { $0.id == recipient }.map(\.id) }
          ?? Self.resolveResponderIDs(members: members, history: initialHistory)
        guard !responderIDs.isEmpty else { return [] }
        // Rotate the starting member between requests as well as between rounds.
        state.groups[groupIndex].nextSpeakerOffset = (group.nextSpeakerOffset + 1) % responderIDs.count
        try persist()
        for round in 0..<Self.maximumRounds {
            guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
            let rotation = Self.rotated(responderIDs, by: group.nextSpeakerOffset + round).filter { !failedMemberIDs.contains($0) }
            guard !rotation.isEmpty else { break }
            var messagesThisRound = 0
            for memberID in rotation {
                guard total < Self.maximumMemberMessages,
                      epochs[groupID] == epoch,
                      !Task.isCancelled else { return produced }
                // Keep this request's participant IDs fixed, but refresh public
                // profiles/personas between turns after approved profile edits.
                let currentMembers = await resolveMembers(group.memberIDs)
                guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
                guard let agent = currentMembers.first(where: { $0.id == memberID }) else { continue }
                let history = state.roomMessages.filter { $0.groupID == groupID }
                let previousSpeech = history.lastIndex { $0.senderID == memberID && (!$0.text.isEmpty || !($0.images ?? []).isEmpty || !($0.files ?? []).isEmpty || $0.remoteAttachment != nil) }
                let unread = history.dropFirst(seenMessageCounts[memberID] ?? previousSpeech.map { $0 + 1 } ?? 0)
                if seenMessageCounts[memberID] != nil,
                   !unread.contains(where: { $0.senderID != memberID && (!$0.text.isEmpty || !($0.images ?? []).isEmpty || !($0.files ?? []).isEmpty || $0.remoteAttachment != nil || !$0.toolActivities.isEmpty) }) {
                    continue
                }
                let personaLease = try await agents.captureGroupMemberIdentity(agent)
                let memberLease = try groupLease.inheriting(personaLease)
                let turnPersonaLease = try await agents.captureGroupMemberTurnIdentity(agent)
                let turnLease = try groupLease.inheriting(turnPersonaLease)
                var responses: [String] = []
                var responseSucceeded = false
                var activityMessage = RoomMessage(groupID: groupID, senderID: memberID, text: "")
                var attemptActivities: [UUID] = []
                var attemptTickets: [GroupMemberExecutionAttempt] = []
                let remainingBudget = Self.maximumMemberMessages - total
                let previousTexts = publishedTexts[memberID, default: []]
                defer {
                    for id in attemptActivities { explicitReplies[id] = nil }
                    for ticket in attemptTickets { ticket.close() }
                    if attemptTickets.contains(where: { activeAttempts[groupID] === $0 }) { activeAttempts[groupID] = nil }
                }
                for attempt in 1...Self.maximumMemberPreemptionAttempts {
                    try memberLease.check()
                    let ticket = try GroupMemberExecutionAttempt(number: attempt, agentID: agent.id, inherited: turnLease,
                        admissionLease: memberLease) {
                        try await self.validateMemberSource(group: group, epoch: epoch)
                    }
                    attemptTickets.append(ticket)
                    activeAttempts[groupID] = ticket
                    let attemptHistory = state.roomMessages.filter { $0.groupID == groupID }
                    let context = GroupTurnContext(group: group, members: currentMembers.map(GroupMemberIdentity.init),
                        respondingMemberIDs: responderIDs, round: round, newMessageIDs: Set(unread.map(\.id)), executionAttempt: ticket,
                        reactToMessage: { messageID, emoji in
                            let applied = try await self.toggleMemberReaction(messageID: messageID, emoji: emoji,
                                group: group, epoch: epoch, attempt: ticket, history: attemptHistory)
                            let reactions = await self.reactions(groupID: groupID)
                            await onReaction(reactions)
                            return applied
                        })
                    var activity = RoomMessage(groupID: groupID, senderID: memberID, text: "")
                    activity.replyToMessageID = threadTarget
                    let currentActivity = activity
                    activityMessage = currentActivity
                    attemptActivities.append(currentActivity.id)
                    await onAgentChange(agent.id)
                    guard epochs[groupID] == epoch, !Task.isCancelled, memberLease.isActive else {
                        await onAgentChange(nil)
                        return produced
                    }
                    let responseTask = Task {
                        try await ticket.validate()
                        return try await responder.respond(agent: agent, history: attemptHistory, context: context, onTools: { tools in
                            try await self.recordTools(tools, message: currentActivity, epoch: epoch, attempt: ticket, onMessage: onMessage)
                        }, onSavedPublication: { publication in
                            try await self.recordExplicitReply(publication, activity: currentActivity, epoch: epoch, attempt: ticket,
                                remainingBudget: remainingBudget, previousTexts: previousTexts, onMessage: onMessage)
                        })
                    }
                    activeResponses[groupID] = responseTask
                    do {
                        responses = try await withTaskCancellationHandler {
                            try await responseTask.value
                        } onCancel: { responseTask.cancel() }
                        try await ticket.validate()
                        successfulTurns += 1
                        responseSucceeded = true
                        break
                    } catch {
                        let published = explicitReplies[currentActivity.id] ?? []
                        let priorityInterruption = (error as? AgentExecutionSuperseded)?.groupMemberAttempt === ticket
                        ticket.close()
                        try await finishPendingTools(messageID: currentActivity.id,
                            cancelled: error is CancellationError || error is AgentExecutionSuperseded || epochs[groupID] != epoch || Task.isCancelled,
                            onMessage: onMessage)
                        await onAgentChange(nil)
                        guard epochs[groupID] == epoch, !Task.isCancelled, turnLease.isActive,
                              ticket.hasBegun || memberLease.isActive else { return produced + published }
                        activeResponses[groupID] = nil
                        if priorityInterruption {
                            // Only the scheduler's exact native attempt can resume.
                            // Fresh contexts/publishers/tools are created on every
                            // retry, never replaying an old approval or callback.
                            if published.isEmpty, !ticket.hasReacted, memberLease.isActive,
                               attempt < Self.maximumMemberPreemptionAttempts { continue }
                            successfulTurns += 1
                            responseSucceeded = true
                            responses = []
                            break
                        }
                        produced += published
                        total += published.count
                        messagesThisRound += published.count
                        if published.contains(where: { $0.question != nil }) { return produced }
                        failedMemberIDs.insert(memberID)
                        try await recordOutcome(.failed, message: currentActivity, onMessage: onMessage)
                        if firstFailure == nil { firstFailure = error }
                        break
                    }
                }
                guard responseSucceeded else { continue }
                guard epochs[groupID] == epoch, !Task.isCancelled else {
                    try await finishPendingTools(messageID: activityMessage.id, cancelled: true, onMessage: onMessage)
                    return produced
                }
                activeResponses[groupID] = nil
                await onAgentChange(nil)
                guard epochs[groupID] == epoch, !Task.isCancelled else { return produced }
                let published = explicitReplies[activityMessage.id] ?? []
                produced += published
                if published.contains(where: { $0.question != nil }) {
                    try await finishPendingTools(messageID: activityMessage.id, cancelled: true, onMessage: onMessage)
                    return produced
                }
                total += published.count
                messagesThisRound += published.count
                for message in published {
                    publishedTexts[memberID, default: []].insert(Self.replyFingerprint(message.text, images: message.images ?? [], files: message.files ?? [], remote: message.remoteAttachment, gallery: message.remoteImages, layout: message.imageGalleryLayout, external: message.externalPublication))
                }
                var sentThisTurn = published.count
                for text in responses.filter({ !Self.isPass($0) }).prefix(Self.maximumMessagesPerMemberTurn) {
                    guard sentThisTurn < Self.maximumMessagesPerMemberTurn, total < Self.maximumMemberMessages else { break }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !Self.isPass(trimmed) else { continue }
                    let boundedText = String(trimmed.prefix(8_000))
                    let fingerprint = Self.replyFingerprint(boundedText, images: [])
                    guard publishedTexts[memberID, default: []].insert(fingerprint).inserted else { continue }
                    var message = RoomMessage(groupID: groupID, senderID: memberID, text: boundedText)
                    message.replyToMessageID = threadTarget
                    if sentThisTurn == 0, let index = state.roomMessages.firstIndex(where: { $0.id == activityMessage.id }) {
                        try attemptTickets.last?.commit {
                            state.roomMessages[index].text = message.text
                            message = state.roomMessages[index]
                            try persist()
                        }
                    } else {
                        try attemptTickets.last?.commit { state.roomMessages.append(message); try persist() }
                    }
                    message = state.roomMessages.last(where: { $0.id == message.id }) ?? message
                    produced.append(message)
                    await onMessage(message)
                    total += 1
                    messagesThisRound += 1
                    sentThisTurn += 1
                    if total >= Self.maximumMemberMessages || sentThisTurn >= Self.maximumMessagesPerMemberTurn { break }
                }
                // Tool-only work is still useful input for peers. A genuine PASS
                // is visible once, but never feeds back as new work for the loop.
                if sentThisTurn == 0 {
                    if state.roomMessages.contains(where: { $0.id == activityMessage.id && !$0.toolActivities.isEmpty }) {
                        messagesThisRound += 1
                    } else if seenMessageCounts[memberID] == nil {
                        try await recordOutcome(.passed, message: activityMessage, onMessage: onMessage)
                    }
                }
                seenMessageCounts[memberID] = state.roomMessages.filter { $0.groupID == groupID }.count
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
        groupExecutionScopes[groupID]?.invalidate()
        activeAttempts.removeValue(forKey: groupID)?.close()
        activeResponses.removeValue(forKey: groupID)?.cancel()
    }

    private func validateMemberSource(group: AgentGroup, epoch: UInt64) throws {
        try Task.checkCancellation()
        guard epochs[group.id] == epoch,
              let current = state.groups.first(where: { $0.id == group.id }),
              current.name == group.name, current.summary == group.summary,
              current.memberIDs == group.memberIDs else { throw CancellationError() }
    }

    private struct GalleryImageFingerprint: Hashable {
        let id: String
        let filename: String
        let mimeType: String
        let byteCount: Int64
        let altText: String?
        init(_ image: AttachmentMetadata) {
            id = image.id; filename = image.filename; mimeType = image.mimeType
            byteCount = image.byteCount; altText = image.altText
        }
    }

    private enum ReplyFingerprint: Hashable {
        case external(UUID)
        case text(String)
        case imageIDs([String])
        case fileIDs([String])
        case remoteURL(String)
        case gallery(String, [GalleryImageFingerprint], RemoteImageGallery?, ImageGalleryLayout?)
    }

    private static func replyFingerprint(_ text: String, images: [AttachmentMetadata], files: [AttachmentMetadata] = [], remote: RemoteAttachmentReference? = nil, gallery: RemoteImageGallery? = nil, layout: ImageGalleryLayout? = nil, external: ExternalChannelTranscriptPublication? = nil) -> ReplyFingerprint {
        if let external { return .external(external.deliveryID) }
        if gallery != nil || layout != nil {
            // Reimporting the same bytes changes createdAt, not the message's
            // reviewed content. It must not bypass the round duplicate fence.
            return .gallery(text, images.map(GalleryImageFingerprint.init), gallery, layout)
        }
        if let remote { return .remoteURL(remote.url) }
        if !files.isEmpty { return .fileIDs(files.map(\.id)) }
        let normalized = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return normalized.isEmpty ? .imageIDs(images.map(\.id)) : .text(normalized)
    }

    private func recordExplicitReply(_ publication: GroupAgentPublication, activity: RoomMessage, epoch: UInt64,
                                     attempt: GroupMemberExecutionAttempt, remainingBudget: Int,
                                     previousTexts: Set<ReplyFingerprint>, onMessage: @Sendable (RoomMessage) async -> Void) async throws -> RoomMessage {
        try Task.checkCancellation()
        guard epochs[activity.groupID] == epoch else { throw CancellationError() }
        let text = publication.text, images = publication.images
        let files = publication.file.map { [$0.metadata] } ?? []
        if let external = publication.externalPublication {
            guard external.isValid, external.route == .groupConversation,
                  external.conversationID == activity.groupID, external.senderID == activity.senderID,
                  external.text == text, external.replyToMessageID == publication.replyToMessageID,
                  publication.lifetime != nil, publication.sourceUserMessageID == nil,
                  images.isEmpty, files.isEmpty, publication.remoteImages == nil, publication.remoteAttachment == nil,
                  publication.question == nil, publication.cursorAgent == nil,
                  state.roomMessages.first(where: { $0.id == external.deliveryID }).map({ existing in
                      existing.externalPublication.map { $0.samePublication(as: external) && existing.matchesExternalPublication($0) } == true
                  }) ?? true,
                  state.groups.first(where: { $0.id == activity.groupID })?.memberIDs.contains(external.senderID) == true else {
                throw AgentPublicationError.invalid
            }
        }
        if let reviewed = publication.remoteImages {
            guard reviewed.groupID == activity.groupID, reviewed.senderID == activity.senderID,
                  !state.roomMessages.contains(where: { $0.id == reviewed.messageID }),
                  state.groups.first(where: { $0.id == activity.groupID })?.memberIDs.contains(reviewed.senderID) == true,
                  text == reviewed.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  publication.replyToMessageID == reviewed.replyTo,
                  images == reviewed.images, files.isEmpty, publication.remoteAttachment == nil,
                  reviewed.imageGalleryLayout?.matches(attachments: reviewed.images, remoteGallery: reviewed.gallery) == true,
                  publication.question == nil, publication.cursorAgent == nil,
                  publication.lifetime == nil, publication.sourceUserMessageID == nil else {
                throw AgentPublicationError.invalid
            }
            for image in images {
                guard image.kind == .image else { throw AgentPublicationError.invalid }
                try ReviewedGroupFile.validate(image)
            }
        }
        if let remote = publication.remoteAttachment {
            guard remote.groupID == activity.groupID, remote.senderID == activity.senderID,
                  !state.roomMessages.contains(where: { $0.id == remote.messageID }),
                  state.groups.first(where: { $0.id == activity.groupID })?.memberIDs.contains(remote.senderID) == true,
                  text.isEmpty, images.isEmpty, files.isEmpty, publication.question == nil,
                  publication.cursorAgent == nil, publication.lifetime == nil,
                  publication.sourceUserMessageID == nil else { throw AgentPublicationError.invalid }
        }
        if let file = publication.file {
            guard file.groupID == activity.groupID, file.senderID == activity.senderID,
                  !state.roomMessages.contains(where: { $0.id == file.messageID }),
                  state.groups.first(where: { $0.id == activity.groupID })?.memberIDs.contains(file.senderID) == true,
                  images.isEmpty, publication.question == nil, publication.cursorAgent == nil,
                  publication.lifetime == nil, publication.sourceUserMessageID == nil else {
                throw AgentPublicationError.invalid
            }
        }
        if let reference = publication.cursorAgent {
            guard text == reference.summary, images.isEmpty, publication.question == nil,
                  publication.lifetime != nil else { throw AgentPublicationError.invalid }
        }
        if let replyID = publication.replyToMessageID {
            guard publication.lifetime != nil || publication.file != nil || publication.remoteAttachment != nil || publication.remoteImages != nil, replyID != activity.id,
                  GroupThreadProjection(history: state.roomMessages, groupID: activity.groupID).canReply(to: replyID) else {
                throw GroupReplyError.unavailable
            }
        }
        if let card = publication.question {
            try card.question.validate()
            guard publication.lifetime != nil, images.isEmpty, card.isPending, card.responseMessageID == nil,
                  text == card.question.prompt,
                  state.groups.first(where: { $0.id == activity.groupID })?.memberIDs == card.memberIDs else {
                throw AgentQuestionError.unavailable
            }
        }
        if !images.isEmpty && publication.remoteImages == nil {
            guard publication.lifetime != nil, images.count <= 4, Set(images.map(\.id)).count == images.count,
                  let user = state.roomMessages.last(where: { $0.groupID == activity.groupID && $0.senderID == nil }),
                  user.id == publication.sourceUserMessageID,
                  images.allSatisfy({ image in user.images?.contains(where: { image.isAnnotation(of: $0) }) == true }),
                  let senderID = activity.senderID,
                  state.groups.first(where: { $0.id == activity.groupID })?.memberIDs.contains(senderID) == true else {
                throw AgentPublicationError.invalid
            }
        }
        let replies = explicitReplies[activity.id] ?? []
        let fingerprint = Self.replyFingerprint(text, images: images, files: files, remote: publication.remoteAttachment?.reference, gallery: publication.remoteImages?.gallery, layout: publication.remoteImages?.imageGalleryLayout, external: publication.externalPublication)
        guard (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !files.isEmpty || publication.remoteAttachment != nil || publication.externalPublication != nil), text.count <= 8_000,
              replies.count < min(remainingBudget, Self.maximumMessagesPerMemberTurn),
              !previousTexts.contains(fingerprint), !replies.contains(where: { Self.replyFingerprint($0.text, images: $0.images ?? [], files: $0.files ?? [], remote: $0.remoteAttachment, gallery: $0.remoteImages, layout: $0.imageGalleryLayout, external: $0.externalPublication) == fingerprint }) else {
            throw AgentServiceError.invalidName
        }
        var draft = RoomMessage(id: publication.externalPublication?.deliveryID ?? publication.remoteImages?.messageID ?? publication.remoteAttachment?.messageID ?? publication.file?.messageID ?? UUID(), groupID: activity.groupID, senderID: activity.senderID, text: text, createdAt: publication.externalPublication?.queuedAt ?? Date(), images: images, files: files,
            externalPublication: publication.externalPublication)
        draft.remoteAttachment = publication.remoteAttachment?.reference
        draft.remoteImages = publication.remoteImages?.gallery
        draft.imageGalleryLayout = publication.remoteImages?.imageGalleryLayout
        draft.question = publication.question
        draft.cursorAgent = publication.cursorAgent
        draft.replyToMessageID = publication.externalPublication != nil ? publication.replyToMessageID : publication.replyToMessageID ?? activity.replyToMessageID
        let message = publication.externalPublication.flatMap { value in state.roomMessages.first { $0.id == value.deliveryID } } ?? draft
        let commit = {
            if !self.state.roomMessages.contains(where: { $0.id == message.id }) {
                self.state.roomMessages.append(message)
                try self.persist()
            }
            let saved = self.state.roomMessages.last(where: { $0.id == message.id }) ?? message
            self.explicitReplies[activity.id, default: []].append(saved)
        }
        try attempt.commit {
            if let lifetime = publication.remoteImages?.lifetime ?? publication.remoteAttachment?.lifetime ?? publication.file?.lifetime ?? publication.lifetime { try lifetime.commit(commit) }
            else { try commit() }
        }
        // Capture the durable identity before yielding to UI callbacks. Never
        // acknowledge the pre-save draft, which has no assigned short address.
        let saved = state.roomMessages.last(where: { $0.id == message.id }) ?? message
        await onMessage(saved)
        return saved
    }

    /// Recovery of durable outbox evidence. It never enters a member turn,
    /// consumes a reply budget, invokes a model, or performs an external send.
    public func projectExternalChannel(_ publication: ExternalChannelTranscriptPublication,
        commit: @Sendable (_ operation: () throws -> Void) throws -> Void = { try $0() }) throws -> RoomMessage {
        guard publication.isValid, publication.route == .groupConversation,
              state.groups.first(where: { $0.id == publication.conversationID })?.memberIDs.contains(publication.senderID) == true else {
            throw CancellationError()
        }
        let message: RoomMessage
        if let index = state.roomMessages.firstIndex(where: { $0.id == publication.deliveryID }) {
            let existing = state.roomMessages[index]
            guard let previous = existing.externalPublication, previous.samePublication(as: publication),
                  existing.matchesExternalPublication(previous) else { throw CancellationError() }
            if publication.shouldAdvance(from: previous) {
                try commit { self.state.roomMessages[index].externalPublication = publication; try self.persist() }
            } else { try commit {} }
            message = state.roomMessages[index]
        } else {
            try commit { self.state.roomMessages.append(.externalChannelMessage(publication)); try self.persist() }
            guard let saved = state.roomMessages.first(where: { $0.id == publication.deliveryID }) else { throw CancellationError() }
            message = saved
        }
        return message
    }

    private func recordTools(_ tools: [RoomToolActivity], message: RoomMessage, epoch: UInt64,
                             attempt: GroupMemberExecutionAttempt, onMessage: @Sendable (RoomMessage) async -> Void) async throws {
        try Task.checkCancellation()
        guard epochs[message.groupID] == epoch else { throw CancellationError() }
        var updated = message
        updated.toolActivities = tools
        try attempt.commit {
            if let index = state.roomMessages.firstIndex(where: { $0.id == message.id }) {
                updated.shortAddress = state.roomMessages[index].shortAddress
                state.roomMessages[index] = updated
            } else { state.roomMessages.append(updated) }
            try persist()
        }
        await onMessage(state.roomMessages.last(where: { $0.id == updated.id }) ?? updated)
    }

    private func finishPendingTools(messageID: UUID, cancelled: Bool, onMessage: @Sendable (RoomMessage) async -> Void) async throws {
        guard let index = state.roomMessages.firstIndex(where: { $0.id == messageID }) else { return }
        for toolIndex in state.roomMessages[index].toolActivities.indices where state.roomMessages[index].toolActivities[toolIndex].status == .pending {
            state.roomMessages[index].toolActivities[toolIndex].status = cancelled ? .cancelled : .failed
        }
        try persist()
        await onMessage(state.roomMessages[index])
    }

    private func recordOutcome(_ outcome: RoomMemberOutcome, message: RoomMessage, onMessage: @Sendable (RoomMessage) async -> Void) async throws {
        var updated = message
        if let index = state.roomMessages.firstIndex(where: { $0.id == message.id }) {
            state.roomMessages[index].memberOutcome = outcome
            updated = state.roomMessages[index]
        } else {
            updated.memberOutcome = outcome
            state.roomMessages.append(updated)
        }
        try persist()
        await onMessage(updated)
    }

    public func toggleReaction(messageID: UUID, actorID: UUID, emoji: String) throws -> Bool {
        let emoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !emoji.isEmpty, emoji.count <= 32, state.roomMessages.contains(where: { $0.id == messageID }) else { throw AgentServiceError.invalidReaction }
        if let index = state.reactions.firstIndex(where: { $0.messageID == messageID && $0.actorID == actorID && $0.emoji == emoji }) {
            state.reactions.remove(at: index); try persist()
            markMemberReaction(messageID: messageID, actorID: actorID)
            return false
        }
        state.reactions.append(.init(messageID: messageID, actorID: actorID, emoji: emoji)); try persist()
        markMemberReaction(messageID: messageID, actorID: actorID)
        return true
    }

    private func toggleMemberReaction(messageID: UUID, emoji: String, group: AgentGroup, epoch: UInt64,
                                      attempt: GroupMemberExecutionAttempt, history: [RoomMessage]) throws -> Bool {
        try validateMemberSource(group: group, epoch: epoch)
        guard activeAttempts[group.id] === attempt, attempt.hasBegun,
              attempt.agentID != Self.localUserReactionActorID,
              group.memberIDs.contains(attempt.agentID),
              let expected = history.first(where: { $0.id == messageID && $0.groupID == group.id }),
              GroupReactionDirectory(history: history, groupID: group.id, actorID: attempt.agentID).contains(messageID),
              state.roomMessages.filter({ $0.id == messageID }).count == 1,
              state.roomMessages.filter({ $0.id == messageID && $0.groupID == group.id }) == [expected]
        else { throw AgentServiceError.invalidReaction }
        return try attempt.commit { try toggleReaction(messageID: messageID, actorID: attempt.agentID, emoji: emoji) }
    }

    public func toggleUserReaction(groupID: UUID, messageID: UUID, emoji: String,
                                   executionLease: AgentWorkflowExecutionScope.Lease) throws -> Bool {
        try executionLease.commit {
            guard state.groups.contains(where: { $0.id == groupID }),
                  state.roomMessages.filter({ $0.id == messageID }).count == 1,
                  state.roomMessages.filter({ $0.id == messageID && $0.groupID == groupID }).count == 1,
                  state.roomMessages.contains(where: { $0.id == messageID && $0.groupID == groupID && $0.memberOutcome == nil })
            else { throw AgentServiceError.invalidReaction }
            return try toggleReaction(messageID: messageID, actorID: Self.localUserReactionActorID, emoji: emoji)
        }
    }

    private func markMemberReaction(messageID: UUID, actorID: UUID) {
        guard let message = state.roomMessages.first(where: { $0.id == messageID }),
              actorID != Self.localUserReactionActorID,
              let attempt = activeAttempts[message.groupID], attempt.agentID == actorID else { return }
        attempt.markReaction()
    }

    public func messages(groupID: UUID) -> [RoomMessage] { state.roomMessages.filter { $0.groupID == groupID } }
    public func reactions(messageID: UUID) -> [MessageReaction] { state.reactions.filter { $0.messageID == messageID } }
    public func reactions(groupID: UUID) -> [MessageReaction] {
        let counts = Dictionary(grouping: state.roomMessages, by: \.id).mapValues(\.count)
        let ids = Set(state.roomMessages.filter { $0.groupID == groupID && counts[$0.id] == 1 }.map(\.id))
        return state.reactions.filter { ids.contains($0.messageID) }
    }

    public func unreadState(groupID: UUID) throws -> ConversationUnreadState {
        guard state.groups.contains(where: { $0.id == groupID }),
              let record = state.groupReadBookkeeping?.records.first(where: { $0.groupID == groupID }) else {
            throw GroupReadStateError.invalidState
        }
        return record.state
    }

    public func leaseReadState(groupID: UUID, inheriting hostLease: AgentWorkflowExecutionScope.Lease? = nil) throws -> GroupReadStateLease {
        guard let group = state.groups.first(where: { $0.id == groupID }),
              let record = state.groupReadBookkeeping?.records.first(where: { $0.groupID == groupID }) else {
            throw GroupReadStateError.invalidState
        }
        let scope = groupReadScopes[groupID] ?? AgentWorkflowExecutionScope()
        groupReadScopes[groupID] = scope
        return try .init(storeID: readStoreID, group: group, record: record,
            messageIDs: state.roomMessages.filter { $0.groupID == groupID }.map(\.id),
            membershipLease: scope.capture(inheriting: hostLease))
    }

    /// Final synchronous save under the original host/membership lifetime. A
    /// stale automatic view cannot clear newer arrivals or a manual unread flag.
    /// Explicit read/unread are native bookkeeping, not routine/card answers.
    @discardableResult
    public func updateReadState(_ lease: GroupReadStateLease, action: ConversationReadAction, at: Date) throws -> ConversationUnreadState {
        guard at.timeIntervalSince1970.isFinite else { throw GroupReadStateError.invalidState }
        return try lease.lease.commit {
            guard lease.storeID == readStoreID,
                  state.groups.first(where: { $0.id == lease.groupID })?.memberIDs == lease.memberIDs,
                  let index = state.groupReadBookkeeping?.records.firstIndex(where: { $0.groupID == lease.groupID }) else {
                throw CancellationError()
            }
            var saved = state
            guard var bookkeeping = saved.groupReadBookkeeping else { throw GroupReadStateError.invalidState }
            var value = bookkeeping.records[index].state
            switch action {
            case .viewed(let preserve):
                guard bookkeeping.records[index] == lease.originalRecord else { throw CancellationError() }
                // Reference markViewed does no IO for a preserved manual flag
                // or a repeated/older view. Still validate the original lease
                // above; a no-op must not resurrect a revoked native action.
                guard value.markViewed(at: at, preserveManualUnread: preserve) else { return value }
            case .read: value.markRead(at: at)
            case .unread:
                value.markUnread(at: at, newestMessageAt: state.roomMessages.filter { $0.groupID == lease.groupID }.map(\.createdAt).max())
            }
            bookkeeping.records[index].state = value
            saved.groupReadBookkeeping = bookkeeping
            try writePrepared(saved)
            return try unreadState(groupID: lease.groupID)
        }
    }

    private func persist() throws {
        do {
            var saved = state
            guard var bookkeeping = saved.groupReadBookkeeping else { throw GroupReadStateError.invalidState }
            try bookkeeping.recordActivity(groups: saved.groups, history: saved.roomMessages, at: activityDate())
            saved.groupReadBookkeeping = bookkeeping
            try writePrepared(saved)
        } catch {
            // The whole envelope rolls back, not only whichever message array
            // a particular caller happened to restore. A later native read save
            // must never publish a failed reaction, membership or speaker edit.
            state = persistedState
            throw error
        }
    }

    private func writePrepared(_ value: AgentPersistentState) throws {
        var saved = value
        GroupMessageAddressing.assignMissing(in: &saved.roomMessages)
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: storeURL, options: .atomic)
        state = saved
        persistedState = saved
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
        let request = history.last(where: { $0.senderID == nil })
        if request?.routineWake != nil { return members.map(\.id) }
        let text = request?.text ?? ""
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
