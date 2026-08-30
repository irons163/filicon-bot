import Foundation
import CryptoKit
import Security
import Darwin

private struct StoredInvite: Codable, Hashable {
    var tokenHash: String
    var roomID: UUID
    var expiresAt: Date
    var usedAt: Date?
}

private struct StoredProcessedRequest: Codable {
    var requestHash: String
    /// Nil is a deliberately redacted, return-once response (currently an invite).
    var response: SharedRoomResponse?
}

private struct SharedRoomFileState: Codable {
    var version = 1
    var rooms: [SharedRoomSnapshot] = []
    var invites: [StoredInvite] = []
    var accountGenerations: [UUID: UInt64] = [:]
    var processed: [UUID: StoredProcessedRequest] = [:]

    private enum CodingKeys: String, CodingKey {
        case version, rooms, invites, accountGenerations, processed
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        rooms = try values.decodeIfPresent([SharedRoomSnapshot].self, forKey: .rooms) ?? []
        invites = try values.decodeIfPresent([StoredInvite].self, forKey: .invites) ?? []
        accountGenerations = try values.decodeIfPresent([UUID: UInt64].self, forKey: .accountGenerations) ?? [:]
        if !values.contains(.processed) {
            processed = [:]
        } else if let current = try? values.decode([UUID: StoredProcessedRequest].self, forKey: .processed) {
            // A sensitive response is never valid durable state, even if a future
            // malformed writer manages to put one in this cache.
            processed = current.mapValues { entry in
                if case .invite? = entry.response {
                    return StoredProcessedRequest(requestHash: entry.requestHash, response: nil)
                }
                return entry
            }
        } else if (try? values.decode([UUID: SharedRoomResponse].self, forKey: .processed)) != nil {
            // Version 1 briefly stored response-only entries. They cannot be bound
            // to an actor/operation safely and may contain raw invite tokens.
            processed = [:]
        } else {
            throw DecodingError.dataCorruptedError(forKey: .processed, in: values, debugDescription: "Invalid processed-request cache.")
        }
    }
}

/// A real, process-safe single-Mac collaboration transport. Multiple app instances or
/// test identities can point at the same file. The file contains invite hashes only.
public actor FileSharedRoomTransport: SharedRoomTransport {
    public nonisolated let stateURL: URL
    public nonisolated let typingLifetime: TimeInterval
    public nonisolated let memberLimit: Int

    public init(stateURL: URL, typingLifetime: TimeInterval = 8, memberLimit: Int = 64) {
        self.stateURL = stateURL
        self.typingLifetime = max(0, typingLifetime)
        self.memberLimit = max(1, memberLimit)
    }

    public func perform(_ request: SharedRoomRequest) async throws -> SharedRoomResponse {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockURL = stateURL.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw SharedRoomError.transport("Could not open shared-room lock.") }
        defer { close(fd) }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { throw SharedRoomError.transport("Could not secure shared-room lock.") }
        guard flock(fd, LOCK_EX) == 0 else { throw SharedRoomError.transport("Could not lock shared-room state.") }
        defer { flock(fd, LOCK_UN) }

        var state = try loadState()
        var effectiveRequest = request
        let actorName = String(request.actor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !actorName.isEmpty else { throw SharedRoomError.invalidName }
        effectiveRequest.actor.displayName = actorName
        try advanceAccountGeneration(for: effectiveRequest.actor, state: &state)
        let requestHash = try Self.hash(request)
        if let processed = state.processed[request.id] {
            guard Self.constantTimeEqual(processed.requestHash, requestHash) else { throw SharedRoomError.requestConflict }
            guard let response = processed.response else { throw SharedRoomError.inviteAlreadyUsed }
            return response
        }
        let now = Date()
        let response = try apply(effectiveRequest, state: &state, now: now)
        // An invite token is deliberately return-once. Its request ID is persisted
        // so retries cannot mint extra invites, but the sensitive response is not.
        if case .invite = response {
            state.processed[request.id] = .init(requestHash: requestHash, response: nil)
        } else {
            state.processed[request.id] = .init(requestHash: requestHash, response: response)
        }
        if state.processed.count > 512 {
            for key in state.processed.keys.sorted(by: { $0.uuidString < $1.uuidString }).prefix(state.processed.count - 512) {
                state.processed.removeValue(forKey: key)
            }
        }
        try save(state)
        return response
    }

    private func loadState() throws -> SharedRoomFileState {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return SharedRoomFileState() }
        do {
            let data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
            guard data.count <= 8 * 1_024 * 1_024 else { throw SharedRoomError.malformedState }
            var state = try JSONDecoder.sharedRooms.decode(SharedRoomFileState.self, from: data)
            guard state.version == 1 else { throw SharedRoomError.unsupportedStateVersion }
            try normalizeAndValidate(&state)
            return state
        } catch let error as SharedRoomError { throw error }
        catch { throw SharedRoomError.malformedState }
    }

    private func normalizeAndValidate(_ state: inout SharedRoomFileState) throws {
        guard state.rooms.count <= 10_000,
              state.invites.count <= 100_000,
              state.processed.count <= 10_000,
              Set(state.rooms.map(\.id)).count == state.rooms.count
        else { throw SharedRoomError.malformedState }

        var known = state.accountGenerations
        for room in state.rooms {
            guard !room.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  room.name.count <= 100,
                  room.members.count <= memberLimit,
                  Set(room.members.map(\.id)).count == room.members.count,
                  room.members.contains(where: { $0.kind == .person && $0.id == room.hostPersonID }),
                  Set(room.pendingJoinRequests.map(\.id)).count == room.pendingJoinRequests.count,
                  Set(room.pendingJoinRequests.map { $0.identity.id }).count == room.pendingJoinRequests.count,
                  Set(room.typingUsers.map(\.personID)).count == room.typingUsers.count
            else { throw SharedRoomError.malformedState }
            let people = Set(room.members.filter { $0.kind == .person }.map(\.id))
            for member in room.members {
                guard !member.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      member.displayName.count <= 100
                else { throw SharedRoomError.malformedState }
                if member.kind == .person {
                    guard member.ownerPersonID == nil else { throw SharedRoomError.malformedState }
                    known[member.id] = max(known[member.id] ?? 0, member.accountGeneration)
                } else {
                    guard let owner = member.ownerPersonID, people.contains(owner) else { throw SharedRoomError.malformedState }
                }
            }
            for pending in room.pendingJoinRequests {
                guard !people.contains(pending.identity.id) else { throw SharedRoomError.malformedState }
                known[pending.identity.id] = max(known[pending.identity.id] ?? 0, pending.identity.accountGeneration)
            }
            guard room.typingUsers.allSatisfy({ people.contains($0.personID) }) else { throw SharedRoomError.malformedState }
        }
        let roomIDs = Set(state.rooms.map(\.id))
        guard state.invites.allSatisfy({ roomIDs.contains($0.roomID) && Self.isSHA256($0.tokenHash) }),
              state.processed.values.allSatisfy({ Self.isSHA256($0.requestHash) })
        else { throw SharedRoomError.malformedState }

        // Older states did not have a generation high-water map. Reconcile them
        // to the greatest generation observed, then consistently fence older actors.
        state.accountGenerations = known
        for roomIndex in state.rooms.indices {
            for memberIndex in state.rooms[roomIndex].members.indices {
                let member = state.rooms[roomIndex].members[memberIndex]
                if member.kind == .person, let generation = known[member.id] {
                    state.rooms[roomIndex].members[memberIndex].accountGeneration = generation
                }
            }
        }
    }

    private func advanceAccountGeneration(for actor: SharedRoomIdentity, state: inout SharedRoomFileState) throws {
        if let known = state.accountGenerations[actor.id] {
            guard actor.accountGeneration >= known else { throw SharedRoomError.generationFenced }
            guard actor.accountGeneration > known else { return }
            for roomIndex in state.rooms.indices {
                state.rooms[roomIndex].typingUsers.removeAll { $0.personID == actor.id }
                state.rooms[roomIndex].pendingJoinRequests.removeAll { $0.identity.id == actor.id }
                for memberIndex in state.rooms[roomIndex].members.indices {
                    let member = state.rooms[roomIndex].members[memberIndex]
                    if member.kind == .person && member.id == actor.id {
                        state.rooms[roomIndex].members[memberIndex].accountGeneration = actor.accountGeneration
                        state.rooms[roomIndex].members[memberIndex].displayName = actor.displayName
                    } else if member.kind == .agent && member.ownerPersonID == actor.id {
                        state.rooms[roomIndex].members[memberIndex].accountGeneration = actor.accountGeneration
                    }
                }
            }
        }
        state.accountGenerations[actor.id] = actor.accountGeneration
    }

    private func save(_ state: SharedRoomFileState) throws {
        let data = try JSONEncoder.sharedRooms.encode(state)
        let temporary = stateURL.deletingLastPathComponent().appending(path: ".\(stateURL.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: [.atomic, .completeFileProtectionUnlessOpen])
            guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
                throw SharedRoomError.transport("Could not secure shared-room state.")
            }
            if FileManager.default.fileExists(atPath: stateURL.path) {
                _ = try FileManager.default.replaceItemAt(stateURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: stateURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw SharedRoomError.transport("Could not save shared-room state: \(error.localizedDescription)")
        }
    }

    private func apply(_ request: SharedRoomRequest, state: inout SharedRoomFileState, now: Date) throws -> SharedRoomResponse {
        prune(&state, now: now)
        switch request.operation {
        case .listRooms:
            return .rooms(state.rooms.filter { room in
                room.members.contains { $0.kind == .person && $0.id == request.actor.id && $0.accountGeneration == request.actor.accountGeneration }
            })
        case .createRoom(let name):
            let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !clean.isEmpty else { throw SharedRoomError.invalidName }
            let host = SharedRoomMember(id: request.actor.id, kind: .person, displayName: request.actor.displayName, accountGeneration: request.actor.accountGeneration, joinedAt: now)
            let room = SharedRoomSnapshot(id: UUID(), name: clean, hostPersonID: request.actor.id, members: [host], pendingJoinRequests: [], typingUsers: [], createdAt: now)
            state.rooms.append(room)
            return .room(room)
        case .room(let id):
            let index = try memberRoomIndex(id, actor: request.actor, state: state)
            return .room(state.rooms[index])
        case .createInvite(let roomID, let expiresAt):
            let index = try hostRoomIndex(roomID, actor: request.actor, state: state)
            guard expiresAt > now, expiresAt <= now.addingTimeInterval(30 * 24 * 3600) else { throw SharedRoomError.inviteExpired }
            let token = try Self.generateToken()
            state.invites.append(.init(tokenHash: Self.hash(token), roomID: state.rooms[index].id, expiresAt: expiresAt, usedAt: nil))
            guard let url = URL(string: "filicon://shared-room/join?token=\(token)") else { throw SharedRoomError.invalidInvite }
            return .invite(.init(roomID: roomID, url: url, expiresAt: expiresAt))
        case .requestJoin(let rawToken):
            let token = Self.extractToken(rawToken)
            guard Self.isValidInviteToken(token),
                  let inviteIndex = state.invites.firstIndex(where: { Self.constantTimeEqual($0.tokenHash, Self.hash(token)) })
            else { throw SharedRoomError.invalidInvite }
            guard state.invites[inviteIndex].usedAt == nil else { throw SharedRoomError.inviteAlreadyUsed }
            guard state.invites[inviteIndex].expiresAt > now else { throw SharedRoomError.inviteExpired }
            guard let roomIndex = state.rooms.firstIndex(where: { $0.id == state.invites[inviteIndex].roomID }) else { throw SharedRoomError.roomNotFound }
            if let member = state.rooms[roomIndex].members.first(where: { $0.kind == .person && $0.id == request.actor.id }) {
                guard member.accountGeneration == request.actor.accountGeneration else { throw SharedRoomError.generationFenced }
                state.invites[inviteIndex].usedAt = now
                return .room(state.rooms[roomIndex])
            }
            guard !state.rooms[roomIndex].pendingJoinRequests.contains(where: { $0.identity.id == request.actor.id }) else { throw SharedRoomError.pendingRequestExists }
            let join = SharedRoomJoinRequest(id: UUID(), identity: request.actor, requestedAt: now)
            state.rooms[roomIndex].pendingJoinRequests.append(join)
            state.invites[inviteIndex].usedAt = now
            return .joinRequested(roomID: state.rooms[roomIndex].id, requestID: join.id)
        case .decideJoin(let roomID, let joinID, let decision):
            let roomIndex = try hostRoomIndex(roomID, actor: request.actor, state: state)
            guard let joinIndex = state.rooms[roomIndex].pendingJoinRequests.firstIndex(where: { $0.id == joinID }) else { throw SharedRoomError.requestNotFound }
            let join = state.rooms[roomIndex].pendingJoinRequests.remove(at: joinIndex)
            if decision == .approve {
                guard state.rooms[roomIndex].members.count < memberLimit else { throw SharedRoomError.memberLimit }
                state.rooms[roomIndex].members.append(.init(id: join.identity.id, kind: .person, displayName: join.identity.displayName, accountGeneration: join.identity.accountGeneration, joinedAt: now))
            }
            return .room(state.rooms[roomIndex])
        case .addAgent(let roomID, let agent):
            let roomIndex = try memberRoomIndex(roomID, actor: request.actor, state: state)
            guard state.rooms[roomIndex].members.count < memberLimit else { throw SharedRoomError.memberLimit }
            if let existing = state.rooms[roomIndex].members.first(where: { $0.id == agent.id }) {
                guard existing.kind == .agent && existing.ownerPersonID == request.actor.id else { throw SharedRoomError.notMember }
                return .room(state.rooms[roomIndex])
            }
            let name = String(agent.displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            guard !name.isEmpty else { throw SharedRoomError.invalidName }
            state.rooms[roomIndex].members.append(.init(id: agent.id, kind: .agent, displayName: name, accountGeneration: request.actor.accountGeneration, ownerPersonID: request.actor.id, joinedAt: now))
            return .room(state.rooms[roomIndex])
        case .removeMember(let roomID, let memberID):
            let roomIndex = try memberRoomIndex(roomID, actor: request.actor, state: state)
            guard let member = state.rooms[roomIndex].members.first(where: { $0.id == memberID }) else { return .room(state.rooms[roomIndex]) }
            if member.kind == .person {
                guard state.rooms[roomIndex].hostPersonID == request.actor.id else { throw SharedRoomError.notHost }
                guard member.id != state.rooms[roomIndex].hostPersonID else { throw SharedRoomError.notHost }
                state.rooms[roomIndex].members.removeAll { $0.id == memberID || $0.ownerPersonID == memberID }
            } else {
                guard member.ownerPersonID == request.actor.id || state.rooms[roomIndex].hostPersonID == request.actor.id else { throw SharedRoomError.notMember }
                state.rooms[roomIndex].members.removeAll { $0.id == memberID }
            }
            return .room(state.rooms[roomIndex])
        case .leave(let roomID):
            let roomIndex = try memberRoomIndex(roomID, actor: request.actor, state: state)
            if state.rooms[roomIndex].hostPersonID == request.actor.id {
                let people = state.rooms[roomIndex].members.filter { $0.kind == .person && $0.id != request.actor.id }.sorted { $0.joinedAt < $1.joinedAt }
                guard let successor = people.first else { state.rooms.remove(at: roomIndex); state.invites.removeAll { $0.roomID == roomID }; return .acknowledged }
                state.rooms[roomIndex].hostPersonID = successor.id
            }
            state.rooms[roomIndex].members.removeAll { $0.id == request.actor.id || $0.ownerPersonID == request.actor.id }
            state.rooms[roomIndex].typingUsers.removeAll { $0.personID == request.actor.id }
            return .acknowledged
        case .setTyping(let roomID, let typing):
            let roomIndex = try memberRoomIndex(roomID, actor: request.actor, state: state)
            state.rooms[roomIndex].typingUsers.removeAll { $0.personID == request.actor.id }
            if typing { state.rooms[roomIndex].typingUsers.append(.init(personID: request.actor.id, displayName: request.actor.displayName, expiresAt: now.addingTimeInterval(typingLifetime))) }
            return .room(state.rooms[roomIndex])
        }
    }

    private func memberRoomIndex(_ id: UUID, actor: SharedRoomIdentity, state: SharedRoomFileState) throws -> Int {
        guard let index = state.rooms.firstIndex(where: { $0.id == id }) else { throw SharedRoomError.roomNotFound }
        guard let member = state.rooms[index].members.first(where: { $0.kind == .person && $0.id == actor.id }) else { throw SharedRoomError.notMember }
        guard member.accountGeneration == actor.accountGeneration else { throw SharedRoomError.generationFenced }
        return index
    }

    private func hostRoomIndex(_ id: UUID, actor: SharedRoomIdentity, state: SharedRoomFileState) throws -> Int {
        let index = try memberRoomIndex(id, actor: actor, state: state)
        guard state.rooms[index].hostPersonID == actor.id else { throw SharedRoomError.notHost }
        return index
    }

    private func prune(_ state: inout SharedRoomFileState, now: Date) {
        for index in state.rooms.indices { state.rooms[index].typingUsers.removeAll { $0.expiresAt <= now } }
        state.invites.removeAll { $0.expiresAt <= now.addingTimeInterval(-24 * 3600) }
    }

    private static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SharedRoomError.transport("Secure random generation failed.") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func hash(_ token: String) -> String { Data(SHA256.hash(data: Data(token.utf8))).base64EncodedString() }
    private static func hash(_ request: SharedRoomRequest) throws -> String {
        let encoder = JSONEncoder.sharedRooms
        return Data(SHA256.hash(data: try encoder.encode(request))).base64EncodedString()
    }
    private static func isSHA256(_ value: String) -> Bool {
        guard let data = Data(base64Encoded: value) else { return false }
        return data.count == SHA256.byteCount
    }
    private static func isValidInviteToken(_ token: String) -> Bool {
        guard token.count == 43,
              token.unicodeScalars.allSatisfy({
                  let value = $0.value
                  return (65...90).contains(value) || (97...122).contains(value) ||
                      (48...57).contains(value) || value == 45 || value == 95
              })
        else { return false }
        let base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        return Data(base64Encoded: base64)?.count == 32
    }
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8); guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func extractToken(_ raw: String) -> String {
        if let url = URL(string: raw), let components = URLComponents(url: url, resolvingAgainstBaseURL: false), components.scheme == "filicon" {
            guard components.host == "shared-room", components.path == "/join",
                  components.user == nil, components.password == nil, components.fragment == nil,
                  let items = components.queryItems, items.count == 1, items[0].name == "token"
            else { return "" }
            return items[0].value ?? ""
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension JSONEncoder {
    static var sharedRooms: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .deferredToDate; value.outputFormatting = [.sortedKeys]; return value }
}
private extension JSONDecoder {
    static var sharedRooms: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid shared-room date.")
        }
        return value
    }
}
