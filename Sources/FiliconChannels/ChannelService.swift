import Foundation

public protocol ChannelConnector: Sendable {
    var descriptor: ChannelConnectorDescriptor { get }
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error>
    func send(
        _ message: ChannelOutbound,
        to address: ChannelAddress,
        connection: ChannelConnection,
        idempotencyKey: UUID
    ) async throws
    func profile(connection: ChannelConnection) async throws -> ChannelProfile?
    func addReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws
    func removeReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws
}

public extension ChannelConnector {
    func profile(connection: ChannelConnection) async throws -> ChannelProfile? { nil }
    func addReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws {
        throw ChannelServiceError.unsupportedCapability("reactions")
    }
    func removeReaction(_ emoji: String, eventID: String, address: ChannelAddress, connection: ChannelConnection) async throws {
        throw ChannelServiceError.unsupportedCapability("reactions")
    }
}

private struct ChannelPersistentState: Codable, Sendable {
    var schemaVersion = 1
    var connections: [ChannelConnection] = []
    var inbound: [ChannelEnvelope] = []
    var deliveries: [ChannelDelivery] = []
    var failureWakes: [ChannelFailureWake] = []
}

public actor ChannelService {
    public static let maximumMessageCharacters = 8_000
    public static let maximumAttempts = 3
    public static let maximumRetainedInboundEvents = 10_000

    private let storeURL: URL
    private var state: ChannelPersistentState
    private var connectors: [String: any ChannelConnector] = [:]
    private var listeners: [UUID: Task<Void, Never>] = [:]

    public init(storeURL: URL) throws {
        self.storeURL = storeURL
        if FileManager.default.fileExists(atPath: storeURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            state = try decoder.decode(ChannelPersistentState.self, from: Data(contentsOf: storeURL))
            for index in state.deliveries.indices where state.deliveries[index].status == .sending {
                state.deliveries[index].status = .retrying
            }
            try Self.save(state, to: storeURL)
        } else {
            state = .init()
        }
    }

    deinit { for task in listeners.values { task.cancel() } }

    public func register(_ connector: any ChannelConnector) {
        connectors[connector.descriptor.id] = connector
    }

    public func connectorDescriptors() -> [ChannelConnectorDescriptor] {
        connectors.values.map(\.descriptor).sorted { $0.displayName < $1.displayName }
    }

    @discardableResult
    public func saveConnection(_ connection: ChannelConnection) throws -> ChannelConnection {
        guard let connectorID = ChannelCompatibility.safePlatformIdentifier(connection.connectorID),
              connection.secretReference.hasPrefix("keychain://channels/"),
              connection.secretReference.count > "keychain://channels/".count else {
            throw ChannelServiceError.invalidConnection
        }
        var connection = connection
        connection.displayName = ChannelCompatibility.normalizedLabel(connection.displayName, platform: connectorID)
        if let index = state.connections.firstIndex(where: { $0.id == connection.id }) {
            state.connections[index] = connection
        } else {
            state.connections.append(connection)
        }
        try persist()
        return connection
    }

    public func connections() -> [ChannelConnection] {
        state.connections.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    @discardableResult
    public func refreshProfile(connectionID: UUID) async throws -> ChannelProfile? {
        guard let index = state.connections.firstIndex(where: { $0.id == connectionID }) else { throw ChannelServiceError.unknownConnection(connectionID) }
        guard let connector = connectors[state.connections[index].connectorID] else { throw ChannelServiceError.unknownConnector(state.connections[index].connectorID) }
        let value = try await connector.profile(connection: state.connections[index])
        state.connections[index].profile = value
        state.connections[index].accountID = value?.workspaceID ?? value?.id
        try persist()
        return value
    }

    public func setReaction(_ emoji: String, eventID: String, address: ChannelAddress, connectionID: UUID, removing: Bool = false) async throws {
        guard let connection = state.connections.first(where: { $0.id == connectionID }) else { throw ChannelServiceError.unknownConnection(connectionID) }
        guard let connector = connectors[connection.connectorID] else { throw ChannelServiceError.unknownConnector(connection.connectorID) }
        if removing { try await connector.removeReaction(emoji, eventID: eventID, address: address, connection: connection) }
        else { try await connector.addReaction(emoji, eventID: eventID, address: address, connection: connection) }
    }

    public func setConnectionEnabled(id: UUID, enabled: Bool) throws {
        guard let index = state.connections.firstIndex(where: { $0.id == id }) else { throw ChannelServiceError.unknownConnection(id) }
        state.connections[index].enabled = enabled
        if !enabled { listeners.removeValue(forKey: id)?.cancel() }
        try persist()
    }

    @discardableResult
    public func removeConnection(id: UUID) throws -> ChannelConnection {
        guard let value = state.connections.first(where: { $0.id == id }) else { throw ChannelServiceError.unknownConnection(id) }
        listeners.removeValue(forKey: id)?.cancel()
        state.connections.removeAll { $0.id == id }
        state.inbound.removeAll { $0.connectionID == id }
        state.deliveries.removeAll { $0.connectionID == id }
        state.failureWakes.removeAll { $0.connectionID == id }
        try persist()
        return value
    }

    public func start(
        connectionID: UUID,
        onInbound: @escaping @Sendable (ChannelEnvelope) async -> Void
    ) throws {
        guard let connection = state.connections.first(where: { $0.id == connectionID }) else {
            throw ChannelServiceError.unknownConnection(connectionID)
        }
        guard connection.enabled else { throw ChannelServiceError.disabledConnection(connectionID) }
        guard let connector = connectors[connection.connectorID] else {
            throw ChannelServiceError.unknownConnector(connection.connectorID)
        }
        listeners[connectionID]?.cancel()
        listeners[connectionID] = Task { [weak self] in
            do {
                for try await envelope in connector.inbound(connection: connection) {
                    guard !Task.isCancelled else { return }
                    if await self?.ingestFromListener(envelope) == true { await onInbound(envelope) }
                }
            } catch {
                await self?.recordListenerFailure(connectionID: connectionID, error: error)
            }
        }
    }

    public func stop(connectionID: UUID) {
        listeners.removeValue(forKey: connectionID)?.cancel()
    }

    @discardableResult
    public func ingest(_ envelope: ChannelEnvelope) throws -> Bool {
        guard state.connections.contains(where: { $0.id == envelope.connectionID }),
              !envelope.externalEventID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !envelope.address.channelID.isEmpty,
              !envelope.address.platform.isEmpty else {
            throw ChannelServiceError.invalidEnvelope
        }
        guard !state.inbound.contains(where: {
            $0.connectionID == envelope.connectionID && $0.externalEventID == envelope.externalEventID
        }) else { return false }
        state.inbound.append(envelope)
        if state.inbound.count > Self.maximumRetainedInboundEvents {
            state.inbound.removeFirst(state.inbound.count - Self.maximumRetainedInboundEvents)
        }
        if let index = state.connections.firstIndex(where: { $0.id == envelope.connectionID }) {
            state.connections[index].cursor = envelope.cursor ?? state.connections[index].cursor
            state.connections[index].lastActivityAt = envelope.timestamp
        }
        try persist()
        return true
    }

    public func inboundEvents(connectionID: UUID? = nil) -> [ChannelEnvelope] {
        state.inbound.filter { connectionID == nil || $0.connectionID == connectionID }
    }

    @discardableResult
    public func enqueue(
        _ outbound: ChannelOutbound,
        to address: ChannelAddress,
        connectionID: UUID,
        idempotencyKey: UUID = UUID(),
        at: Date = Date()
    ) throws -> ChannelDelivery {
        guard state.connections.contains(where: { $0.id == connectionID }) else {
            throw ChannelServiceError.unknownConnection(connectionID)
        }
        let text = outbound.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !outbound.attachments.isEmpty), text.count <= Self.maximumMessageCharacters,
              !address.platform.isEmpty, !address.channelID.isEmpty else {
            throw ChannelServiceError.invalidOutbound
        }
        if let existing = state.deliveries.first(where: { $0.idempotencyKey == idempotencyKey }) {
            return existing
        }
        let delivery = ChannelDelivery(
            connectionID: connectionID,
            address: address,
            outbound: .init(text: text, attachments: outbound.attachments),
            idempotencyKey: idempotencyKey,
            nextAttemptAt: at,
            createdAt: at
        )
        state.deliveries.append(delivery)
        try persist()
        return delivery
    }

    public func flush(now: Date = Date()) async {
        let dueIDs = state.deliveries.filter {
            ($0.status == .queued || $0.status == .retrying) && $0.nextAttemptAt <= now
        }.map(\.id)
        for id in dueIDs { await attempt(id: id, now: now) }
    }

    public func deliveries() -> [ChannelDelivery] { state.deliveries }

    /// Returns the authoritative persisted delivery record for one enqueue.
    /// Callers must not infer delivery merely because `enqueue` succeeded.
    public func delivery(id: UUID) -> ChannelDelivery? {
        state.deliveries.first(where: { $0.id == id })
    }
    public func failureWakes() -> [ChannelFailureWake] { state.failureWakes }

    public func acknowledgeFailureWake(id: UUID) throws {
        state.failureWakes.removeAll { $0.id == id }
        try persist()
    }

    private func attempt(id: UUID, now: Date) async {
        guard let index = state.deliveries.firstIndex(where: { $0.id == id }) else { return }
        let delivery = state.deliveries[index]
        guard let connection = state.connections.first(where: { $0.id == delivery.connectionID }), connection.enabled else {
            deadLetter(index: index, error: ChannelServiceError.disabledConnection(delivery.connectionID).localizedDescription, now: now)
            return
        }
        guard let connector = connectors[connection.connectorID] else {
            scheduleFailure(index: index, error: ChannelServiceError.unknownConnector(connection.connectorID).localizedDescription, now: now)
            return
        }
        state.deliveries[index].status = .sending
        state.deliveries[index].attemptCount += 1
        try? persist()
        do {
            try await connector.send(delivery.outbound, to: delivery.address, connection: connection, idempotencyKey: delivery.idempotencyKey)
            guard let liveIndex = state.deliveries.firstIndex(where: { $0.id == id }) else { return }
            state.deliveries[liveIndex].status = .delivered
            state.deliveries[liveIndex].deliveredAt = now
            state.deliveries[liveIndex].lastError = nil
            if let connectionIndex = state.connections.firstIndex(where: { $0.id == delivery.connectionID }) {
                state.connections[connectionIndex].lastActivityAt = now
            }
            try? persist()
        } catch {
            guard let liveIndex = state.deliveries.firstIndex(where: { $0.id == id }) else { return }
            if case ChannelServiceError.authExpired = error {
                deadLetter(index: liveIndex, error: error.localizedDescription, now: now)
            } else {
                scheduleFailure(index: liveIndex, error: error.localizedDescription, now: now)
            }
        }
    }

    private func scheduleFailure(index: Int, error: String, now: Date) {
        state.deliveries[index].lastError = error
        if state.deliveries[index].attemptCount >= Self.maximumAttempts {
            deadLetter(index: index, error: error, now: now)
        } else {
            state.deliveries[index].status = .retrying
            let delay = pow(2.0, Double(max(0, state.deliveries[index].attemptCount - 1)))
            state.deliveries[index].nextAttemptAt = now.addingTimeInterval(delay)
            try? persist()
        }
    }

    private func deadLetter(index: Int, error: String, now: Date) {
        state.deliveries[index].status = .deadLetter
        state.deliveries[index].lastError = error
        let delivery = state.deliveries[index]
        if !state.failureWakes.contains(where: { $0.deliveryID == delivery.id }) {
            state.failureWakes.append(.init(connectionID: delivery.connectionID, deliveryID: delivery.id, error: error, createdAt: now))
        }
        try? persist()
    }

    private func ingestFromListener(_ envelope: ChannelEnvelope) -> Bool {
        (try? ingest(envelope)) == true
    }

    private func recordListenerFailure(connectionID: UUID, error: Error) {
        guard !Task.isCancelled else { return }
        let deliveryID = UUID()
        state.failureWakes.append(.init(connectionID: connectionID, deliveryID: deliveryID, error: error.localizedDescription))
        try? persist()
    }

    private func persist() throws { try Self.save(state, to: storeURL) }

    private static func save(_ state: ChannelPersistentState, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
