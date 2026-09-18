import Foundation
import Testing
@testable import FiliconSharedRooms

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class HTTPSObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var _reference: String?
    private var _authorization: String?
    private var _request: SharedRoomRequest?

    func setReference(_ value: String) { lock.withLock { _reference = value } }
    func record(_ request: URLRequest) {
        lock.withLock {
            _authorization = request.value(forHTTPHeaderField: "Authorization")
            var data = request.httpBody
            if data == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var collected = Data()
                var buffer = [UInt8](repeating: 0, count: 4_096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    collected.append(buffer, count: count)
                }
                data = collected
            }
            if let data { _request = try? JSONDecoder.http.decode(SharedRoomRequest.self, from: data) }
        }
    }
    var values: (String?, String?, SharedRoomRequest?) { lock.withLock { (_reference, _authorization, _request) } }
}

private func makeTransport(typingLifetime: TimeInterval = 8) -> (FileSharedRoomTransport, URL) {
    let root = FileManager.default.temporaryDirectory.appending(path: "FiliconSharedRoomTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    return (FileSharedRoomTransport(stateURL: root.appending(path: "rooms.json"), typingLifetime: typingLifetime), root)
}

private actor LockOperationProbe {
    private(set) var started = false
    private(set) var completed = false

    func markStarted() { started = true }
    func markCompleted() { completed = true }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}

private func room(from response: SharedRoomResponse) throws -> SharedRoomSnapshot {
    guard case .room(let value) = response else { throw SharedRoomError.malformedReply }
    return value
}

private func invite(from response: SharedRoomResponse) throws -> SharedRoomInvite {
    guard case .invite(let value) = response else { throw SharedRoomError.malformedReply }
    return value
}

@Test func twoIdentitiesCanJoinThroughHashedSingleUseInvite() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let alice = SharedRoomIdentity(displayName: "Alice")
    let bob = SharedRoomIdentity(displayName: "Bob")
    let created = try room(from: await transport.perform(.init(actor: alice, operation: .createRoom(name: "Launch"))))
    let issued = try invite(from: await transport.perform(.init(actor: alice, operation: .createInvite(roomID: created.id, expiresAt: .now.addingTimeInterval(3600)))))

    let stateText = try String(contentsOf: transport.stateURL, encoding: .utf8)
    #expect(!stateText.contains(issued.url.absoluteString))
    let token = URLComponents(url: issued.url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
    #expect(!stateText.contains(token))
    #expect(token.count == 43)
    let decodedToken = Data(base64Encoded: token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=")
    #expect(decodedToken?.count == 32)
    await #expect(throws: SharedRoomError.invalidInvite) {
        try await transport.perform(.init(actor: bob, operation: .requestJoin(token: "filicon://other/join?token=\(token)")))
    }

    let joinResponse = try await transport.perform(.init(actor: bob, operation: .requestJoin(token: issued.url.absoluteString)))
    guard case .joinRequested(let roomID, let requestID) = joinResponse else { Issue.record("Expected pending join"); return }
    #expect(roomID == created.id)
    let approved = try room(from: await transport.perform(.init(actor: alice, operation: .decideJoin(roomID: roomID, requestID: requestID, decision: .approve))))
    #expect(approved.members.contains { $0.id == bob.id })
    await #expect(throws: SharedRoomError.inviteAlreadyUsed) {
        try await transport.perform(.init(actor: SharedRoomIdentity(displayName: "Eve"), operation: .requestJoin(token: issued.url.absoluteString)))
    }
}

@Test func expiredInviteCannotCreateAJoinRequest() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let alice = SharedRoomIdentity(displayName: "Alice"), bob = SharedRoomIdentity(displayName: "Bob")
    let created = try room(from: await transport.perform(.init(actor: alice, operation: .createRoom(name: "Expiry"))))
    let issued = try invite(from: await transport.perform(.init(actor: alice, operation: .createInvite(roomID: created.id, expiresAt: .now.addingTimeInterval(0.03)))))
    try await Task.sleep(for: .milliseconds(50))
    await #expect(throws: SharedRoomError.inviteExpired) {
        try await transport.perform(.init(actor: bob, operation: .requestJoin(token: issued.url.absoluteString)))
    }
}

@Test func hostAuthorizationOwnAgentsLeaveAndSuccession() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let alice = SharedRoomIdentity(displayName: "Alice"), bob = SharedRoomIdentity(displayName: "Bob")
    let roomID = try room(from: await transport.perform(.init(actor: alice, operation: .createRoom(name: "Pair")))).id
    let inviteURL = try invite(from: await transport.perform(.init(actor: alice, operation: .createInvite(roomID: roomID, expiresAt: .now.addingTimeInterval(60))))).url
    let pending = try await transport.perform(.init(actor: bob, operation: .requestJoin(token: inviteURL.absoluteString)))
    guard case .joinRequested(_, let requestID) = pending else { return }
    _ = try await transport.perform(.init(actor: alice, operation: .decideJoin(roomID: roomID, requestID: requestID, decision: .approve)))

    await #expect(throws: SharedRoomError.notHost) {
        try await transport.perform(.init(actor: bob, operation: .createInvite(roomID: roomID, expiresAt: .now.addingTimeInterval(60))))
    }
    let agent = SharedRoomAgentInput(id: UUID(), displayName: "Bob's Agent")
    var snapshot = try room(from: await transport.perform(.init(actor: bob, operation: .addAgent(roomID: roomID, agent: agent))))
    #expect(snapshot.members.first(where: { $0.id == agent.id })?.ownerPersonID == bob.id)
    _ = try await transport.perform(.init(actor: alice, operation: .leave(roomID: roomID)))
    snapshot = try room(from: await transport.perform(.init(actor: bob, operation: .room(id: roomID))))
    #expect(snapshot.hostPersonID == bob.id)
    _ = try await transport.perform(.init(actor: bob, operation: .leave(roomID: roomID)))
    await #expect(throws: SharedRoomError.roomNotFound) {
        try await transport.perform(.init(actor: bob, operation: .room(id: roomID)))
    }
}

@Test func accountGenerationFencesOldSessionAndRequestsAreIdempotent() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let current = SharedRoomIdentity(displayName: "Alice", accountGeneration: 9)
    let requestID = UUID()
    let first = try await transport.perform(.init(id: requestID, actor: current, operation: .createRoom(name: "Once")))
    let replay = try await transport.perform(.init(id: requestID, actor: current, operation: .createRoom(name: "Once")))
    #expect(first == replay)
    let roomID = try room(from: first).id
    let stale = SharedRoomIdentity(id: current.id, displayName: current.displayName, accountGeneration: 8)
    await #expect(throws: SharedRoomError.generationFenced) {
        try await transport.perform(.init(actor: stale, operation: .room(id: roomID)))
    }

    let refreshed = SharedRoomIdentity(id: current.id, displayName: "Alice Again", accountGeneration: 10)
    _ = try await transport.perform(.init(actor: refreshed, operation: .listRooms))
    await #expect(throws: SharedRoomError.generationFenced) {
        try await transport.perform(.init(actor: current, operation: .room(id: roomID)))
    }
    #expect(try room(from: await transport.perform(.init(actor: refreshed, operation: .room(id: roomID)))).host?.accountGeneration == 10)
}

@Test func requestIDsAreBoundToActorAndOperationAndInviteReplayIsRedacted() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let alice = SharedRoomIdentity(displayName: "Alice")
    let bob = SharedRoomIdentity(displayName: "Bob")
    let createID = UUID()
    let created = try room(from: await transport.perform(.init(id: createID, actor: alice, operation: .createRoom(name: "Bound"))))
    await #expect(throws: SharedRoomError.requestConflict) {
        try await transport.perform(.init(id: createID, actor: alice, operation: .createRoom(name: "Other")))
    }
    await #expect(throws: SharedRoomError.requestConflict) {
        try await transport.perform(.init(id: createID, actor: bob, operation: .listRooms))
    }

    let inviteID = UUID()
    let issued = try invite(from: await transport.perform(.init(id: inviteID, actor: alice, operation: .createInvite(roomID: created.id, expiresAt: .now.addingTimeInterval(120)))))
    await #expect(throws: SharedRoomError.inviteAlreadyUsed) {
        try await transport.perform(.init(id: inviteID, actor: alice, operation: .createInvite(roomID: created.id, expiresAt: issued.expiresAt)))
    }
    let token = URLComponents(url: issued.url, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
    let persisted = try String(contentsOf: transport.stateURL, encoding: .utf8)
    #expect(!persisted.contains(token))
    #expect(!persisted.contains(issued.url.absoluteString))
}

@Test func typingExpiresAndMalformedStateFailsClosed() async throws {
    let (transport, root) = makeTransport(typingLifetime: 0.03); defer { try? FileManager.default.removeItem(at: root) }
    let alice = SharedRoomIdentity(displayName: "Alice")
    let roomID = try room(from: await transport.perform(.init(actor: alice, operation: .createRoom(name: "Typing")))).id
    var snapshot = try room(from: await transport.perform(.init(actor: alice, operation: .setTyping(roomID: roomID, isTyping: true))))
    #expect(snapshot.typingUsers.count == 1)
    try await Task.sleep(for: .milliseconds(50))
    snapshot = try room(from: await transport.perform(.init(actor: alice, operation: .room(id: roomID))))
    #expect(snapshot.typingUsers.isEmpty)

    try Data("{broken".utf8).write(to: transport.stateURL, options: .atomic)
    await #expect(throws: SharedRoomError.malformedState) {
        try await transport.perform(.init(actor: alice, operation: .listRooms))
    }
    #expect(try String(contentsOf: transport.stateURL, encoding: .utf8) == "{broken")
}

@Test func separateFileTransportInstancesSerializeUpdatesAndPreserveSubseconds() async throws {
    let (first, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let second = FileSharedRoomTransport(stateURL: first.stateURL)
    let alice = SharedRoomIdentity(displayName: "Alice")
    let requestID = UUID()
    let initial = try await first.perform(.init(id: requestID, actor: alice, operation: .createRoom(name: "Processes")))
    #expect(initial == (try await second.perform(.init(id: requestID, actor: alice, operation: .createRoom(name: "Processes")))))

    let rooms = try await withThrowingTaskGroup(of: SharedRoomResponse.self) { group in
        for index in 0..<20 {
            let transport = index.isMultiple(of: 2) ? first : second
            group.addTask { try await transport.perform(.init(actor: alice, operation: .createRoom(name: "Room \(index)"))) }
        }
        return try await group.reduce(into: []) { $0.append($1) }
    }
    #expect(rooms.count == 20)
    guard case .rooms(let snapshots) = try await second.perform(.init(actor: alice, operation: .listRooms)) else { return }
    #expect(snapshots.count == 21)
    #expect(snapshots.contains { $0.createdAt.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0 })
}

@Test func fileTransportHonorsALockHeldByAnotherProcess() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let signalURL = root.appending(path: "locked")
    let releaseURL = root.appending(path: "release")
    let process = Process()
    let (exits, exitContinuation) = AsyncStream<Int32>.makeStream()
    process.terminationHandler = { task in
        exitContinuation.yield(task.terminationStatus)
        exitContinuation.finish()
    }
    process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    process.arguments = [
        "-e",
        "use Fcntl qw(:flock); open(my $lock, '>>', $ARGV[0]) or die; flock($lock, LOCK_EX) or die; open(my $signal, '>', $ARGV[1]) or die; print $signal 'ready'; close($signal); while (!-e $ARGV[2]) { select(undef, undef, undef, 0.01); }",
        transport.stateURL.appendingPathExtension("lock").path,
        signalURL.path,
        releaseURL.path,
    ]
    try process.run()
    defer {
        if process.isRunning { process.terminate() }
        exitContinuation.finish()
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: signalURL.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(FileManager.default.fileExists(atPath: signalURL.path))

    let probe = LockOperationProbe()
    let operation = Task {
        await probe.markStarted()
        do {
            let response = try await transport.perform(.init(actor: SharedRoomIdentity(displayName: "Alice"), operation: .createRoom(name: "Cross Process")))
            await probe.markCompleted()
            return response
        } catch {
            await probe.markCompleted()
            throw error
        }
    }
    await probe.waitUntilStarted()
    #expect(await probe.completed == false)

    try Data("release".utf8).write(to: releaseURL, options: .atomic)
    _ = try await operation.value
    #expect(await probe.completed)
    // waitUntilExit() spins a Foundation run loop and can hang here on a Swift
    // concurrency worker even after the child exited. Join via its notification.
    var exitIterator = exits.makeAsyncIterator()
    _ = await exitIterator.next()
}

@Test func agentsRemovalDenialAndMemberCascadeAreAuthorized() async throws {
    let (transport, root) = makeTransport(); defer { try? FileManager.default.removeItem(at: root) }
    let alice = SharedRoomIdentity(displayName: "Alice"), bob = SharedRoomIdentity(displayName: "Bob")
    let created = try room(from: await transport.perform(.init(actor: alice, operation: .createRoom(name: "Control"))))

    func request(_ identity: SharedRoomIdentity) async throws -> UUID {
        let inviteURL = try invite(from: await transport.perform(.init(actor: alice, operation: .createInvite(roomID: created.id, expiresAt: .now.addingTimeInterval(60))))).url
        guard case .joinRequested(_, let id) = try await transport.perform(.init(actor: identity, operation: .requestJoin(token: inviteURL.absoluteString))) else {
            throw SharedRoomError.malformedReply
        }
        return id
    }

    let denied = SharedRoomIdentity(displayName: "Denied")
    let deniedID = try await request(denied)
    _ = try await transport.perform(.init(actor: alice, operation: .decideJoin(roomID: created.id, requestID: deniedID, decision: .deny)))
    await #expect(throws: SharedRoomError.notMember) {
        try await transport.perform(.init(actor: denied, operation: .room(id: created.id)))
    }

    let bobID = try await request(bob)
    _ = try await transport.perform(.init(actor: alice, operation: .decideJoin(roomID: created.id, requestID: bobID, decision: .approve)))
    let bobAgent = SharedRoomAgentInput(id: UUID(), displayName: "Bob Agent")
    _ = try await transport.perform(.init(actor: bob, operation: .addAgent(roomID: created.id, agent: bobAgent)))
    _ = try await transport.perform(.init(actor: alice, operation: .removeMember(roomID: created.id, memberID: bobAgent.id)))
    _ = try await transport.perform(.init(actor: bob, operation: .addAgent(roomID: created.id, agent: bobAgent)))
    _ = try await transport.perform(.init(actor: alice, operation: .removeMember(roomID: created.id, memberID: bob.id)))
    let remaining = try room(from: await transport.perform(.init(actor: alice, operation: .room(id: created.id))))
    #expect(!remaining.members.contains { $0.id == bob.id || $0.id == bobAgent.id })
}

@Test func httpsTransportRejectsInsecureOrCredentialBearingEndpoints() {
    let resolver = ClosureSharedRoomAuthTokenResolver { _ in "secret" }
    #expect(throws: SharedRoomError.insecureEndpoint) {
        _ = try HTTPSSharedRoomTransport(endpoint: URL(string: "http://rooms.example/rpc")!, credentialReference: "ref", resolver: resolver)
    }
    #expect(throws: SharedRoomError.insecureEndpoint) {
        _ = try HTTPSSharedRoomTransport(endpoint: URL(string: "https://secret@rooms.example/rpc")!, credentialReference: "ref", resolver: resolver)
    }
}

@Test func httpsTransportResolvesAuthReferenceAndEnforcesExactOrigin() async throws {
    let observation = HTTPSObservation()
    let resolver = ClosureSharedRoomAuthTokenResolver { reference in
        observation.setReference(reference)
        return "resolved-secret"
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let endpoint = URL(string: "https://rooms.example:443/rpc")!
    let actor = SharedRoomIdentity(displayName: "Alice")
    let request = SharedRoomRequest(actor: actor, operation: .listRooms)
    StubURLProtocol.handler = { urlRequest in
        observation.record(urlRequest)
        let data = try JSONEncoder.http.encode(SharedRoomResponse.rooms([]))
        return (HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, data)
    }
    let transport = try HTTPSSharedRoomTransport(endpoint: endpoint, credentialReference: "keychain://shared-rooms", resolver: resolver, configuration: configuration)
    #expect(try await transport.perform(request) == .rooms([]))
    let values = observation.values
    #expect(values.0 == "keychain://shared-rooms")
    #expect(values.1 == "Bearer resolved-secret")
    #expect(values.2 == request)

    StubURLProtocol.handler = { _ in
        let data = try JSONEncoder.http.encode(SharedRoomResponse.acknowledged)
        let other = URL(string: "https://other.example/rpc")!
        return (HTTPURLResponse(url: other, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, data)
    }
    await #expect(throws: SharedRoomError.originMismatch) {
        try await transport.perform(.init(actor: actor, operation: .listRooms))
    }
    StubURLProtocol.handler = nil
}

private extension JSONEncoder {
    static var http: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}
private extension JSONDecoder {
    static var http: JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }
}
