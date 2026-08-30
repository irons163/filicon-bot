import Foundation

public struct SharedRoomIdentity: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var displayName: String
    /// Increment this when an account is signed out/re-created. Old sessions are fenced out.
    public var accountGeneration: UInt64

    public init(id: UUID = UUID(), displayName: String, accountGeneration: UInt64 = 1) {
        self.id = id
        self.displayName = displayName
        self.accountGeneration = accountGeneration
    }
}

public enum SharedRoomMemberKind: String, Codable, Sendable { case person, agent }

public struct SharedRoomMember: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var kind: SharedRoomMemberKind
    public var displayName: String
    public var accountGeneration: UInt64
    public var ownerPersonID: UUID?
    public var joinedAt: Date

    public init(id: UUID, kind: SharedRoomMemberKind, displayName: String, accountGeneration: UInt64, ownerPersonID: UUID? = nil, joinedAt: Date = .now) {
        self.id = id; self.kind = kind; self.displayName = displayName
        self.accountGeneration = accountGeneration; self.ownerPersonID = ownerPersonID; self.joinedAt = joinedAt
    }
}

public struct SharedRoomJoinRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var identity: SharedRoomIdentity
    public var requestedAt: Date
}

public struct SharedRoomTypingUser: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID { personID }
    public var personID: UUID
    public var displayName: String
    public var expiresAt: Date
}

public struct SharedRoomSnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var hostPersonID: UUID
    public var members: [SharedRoomMember]
    public var pendingJoinRequests: [SharedRoomJoinRequest]
    public var typingUsers: [SharedRoomTypingUser]
    public var createdAt: Date

    public var host: SharedRoomMember? { members.first { $0.id == hostPersonID && $0.kind == .person } }
}

public struct SharedRoomInvite: Codable, Hashable, Sendable {
    public var roomID: UUID
    public var url: URL
    public var expiresAt: Date
}

public struct SharedRoomAgentInput: Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public init(id: UUID, displayName: String) { self.id = id; self.displayName = displayName }
}

public enum SharedRoomDecision: String, Codable, Sendable { case approve, deny }

public enum SharedRoomOperation: Codable, Hashable, Sendable {
    case listRooms
    case createRoom(name: String)
    case room(id: UUID)
    case createInvite(roomID: UUID, expiresAt: Date)
    case requestJoin(token: String)
    case decideJoin(roomID: UUID, requestID: UUID, decision: SharedRoomDecision)
    case addAgent(roomID: UUID, agent: SharedRoomAgentInput)
    case removeMember(roomID: UUID, memberID: UUID)
    case leave(roomID: UUID)
    case setTyping(roomID: UUID, isTyping: Bool)
}

public struct SharedRoomRequest: Codable, Hashable, Sendable {
    public var id: UUID
    public var actor: SharedRoomIdentity
    public var operation: SharedRoomOperation
    public init(id: UUID = UUID(), actor: SharedRoomIdentity, operation: SharedRoomOperation) {
        self.id = id; self.actor = actor; self.operation = operation
    }
}

public enum SharedRoomResponse: Codable, Hashable, Sendable {
    case rooms([SharedRoomSnapshot])
    case room(SharedRoomSnapshot)
    case invite(SharedRoomInvite)
    case joinRequested(roomID: UUID, requestID: UUID)
    case acknowledged
}

public enum SharedRoomError: LocalizedError, Equatable, Sendable {
    case invalidName, invalidInvite, inviteExpired, inviteAlreadyUsed
    case roomNotFound, requestNotFound, notMember, notHost, generationFenced
    case memberLimit, pendingRequestExists, malformedState, unsupportedStateVersion
    case requestConflict
    case insecureEndpoint, originMismatch, authenticationRequired, malformedReply
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a room name."
        case .invalidInvite: "This invite is invalid."
        case .inviteExpired: "This invite has expired."
        case .inviteAlreadyUsed: "This invite was already used."
        case .roomNotFound: "The shared room no longer exists."
        case .requestNotFound: "The join request no longer exists."
        case .notMember: "You are not a member of this room."
        case .notHost: "Only the room host can do that."
        case .generationFenced: "This account session is stale. Sign in again."
        case .memberLimit: "This room has reached its member limit."
        case .pendingRequestExists: "A join request is already pending."
        case .malformedState: "Shared-room state is malformed; no changes were made."
        case .unsupportedStateVersion: "This shared-room state was created by an incompatible version."
        case .requestConflict: "This request identifier was already used for a different request."
        case .insecureEndpoint: "Shared-room servers must use HTTPS."
        case .originMismatch: "The server redirected outside its configured origin."
        case .authenticationRequired: "The shared-room server credential is unavailable."
        case .malformedReply: "The shared-room server returned a malformed reply."
        case .transport(let value): value
        }
    }
}

public protocol SharedRoomTransport: Sendable {
    func perform(_ request: SharedRoomRequest) async throws -> SharedRoomResponse
}

public actor SharedRoomClient {
    public let identity: SharedRoomIdentity
    private let transport: any SharedRoomTransport
    public private(set) var isEnabled: Bool

    public init(identity: SharedRoomIdentity, transport: any SharedRoomTransport, enabled: Bool = true) {
        self.identity = identity; self.transport = transport; self.isEnabled = enabled
    }

    public func setEnabled(_ enabled: Bool) { isEnabled = enabled }

    public func perform(_ operation: SharedRoomOperation, requestID: UUID = UUID()) async throws -> SharedRoomResponse {
        guard isEnabled else { throw SharedRoomError.transport("Shared Rooms is disabled.") }
        return try await transport.perform(.init(id: requestID, actor: identity, operation: operation))
    }
}
