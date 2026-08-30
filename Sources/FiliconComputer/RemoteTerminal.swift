import Foundation

public struct RemoteTerminalStart: Codable, Sendable, Equatable {
    public var command: [String]
    public var environment: [String: String]
    public var columns: Int
    public var rows: Int
    public init(command: [String], environment: [String: String] = [:], columns: Int = 80, rows: Int = 24) {
        self.command = command; self.environment = environment; self.columns = columns; self.rows = rows
    }
}

public struct RemoteTerminalSession: Codable, Sendable, Equatable {
    public var id: String
    public var ownerID: String
    public init(id: String, ownerID: String) { self.id = id; self.ownerID = ownerID }
}

public struct RemoteTerminalOutput: Codable, Sendable, Equatable {
    public var data: Data
    public var nextCursor: UInt64
    public var exitCode: Int32?
    public init(data: Data, nextCursor: UInt64, exitCode: Int32? = nil) { self.data = data; self.nextCursor = nextCursor; self.exitCode = exitCode }
}

public protocol RemoteTerminalBackend: Sendable {
    func start(agentID: String, ownerID: String, request: RemoteTerminalStart) async throws -> RemoteTerminalSession
    func input(agentID: String, sessionID: String, data: Data) async throws
    func resize(agentID: String, sessionID: String, columns: Int, rows: Int) async throws
    func output(agentID: String, sessionID: String, cursor: UInt64, limit: Int) async throws -> RemoteTerminalOutput
    func cancel(agentID: String, sessionID: String) async throws
}

public actor RemoteTerminalController {
    public static let maximumInputBytes = 64 * 1024
    public static let maximumOutputBytes = 1024 * 1024
    private let backend: any RemoteTerminalBackend
    private var sessions: [String: RemoteTerminalSession] = [:]
    private var cursors: [String: UInt64] = [:]
    private var cancelled: Set<String> = []

    public init(backend: any RemoteTerminalBackend) { self.backend = backend }

    public func start(agentID: String, ownerID: String, request: RemoteTerminalStart) async throws -> RemoteTerminalSession {
        let environmentBytes = request.environment.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        guard !ownerID.isEmpty, ownerID.utf8.count <= 256, !ownerID.contains("\0"),
              request.columns > 0, request.columns <= 1_000,
              request.rows > 0, request.rows <= 1_000,
              !request.command.isEmpty, request.command.count <= 256,
              request.command.reduce(0, { $0 + $1.utf8.count }) <= 128 * 1024,
              request.command.allSatisfy({ $0.utf8.count <= 32_768 && !$0.contains("\0") }),
              request.environment.count <= 256, environmentBytes <= 128 * 1024,
              request.environment.allSatisfy({ key, value in
                  key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil && !value.contains("\0")
              }) else { throw RemoteComputerError.invalidResponse }
        let session = try await backend.start(agentID: agentID, ownerID: ownerID, request: request)
        guard session.ownerID == ownerID, !session.id.isEmpty else { throw RemoteComputerError.ownershipMismatch }
        sessions[session.id] = session; cursors[session.id] = 0; cancelled.remove(session.id)
        return session
    }

    public func input(agentID: String, sessionID: String, ownerID: String, text: String) async throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maximumInputBytes else { throw RemoteComputerError.requestTooLarge(limit: Self.maximumInputBytes) }
        try owned(sessionID, ownerID)
        try await backend.input(agentID: agentID, sessionID: sessionID, data: data)
    }

    public func resize(agentID: String, sessionID: String, ownerID: String, columns: Int, rows: Int) async throws {
        try owned(sessionID, ownerID)
        guard (1...1_000).contains(columns), (1...1_000).contains(rows) else { throw RemoteComputerError.invalidResponse }
        try await backend.resize(agentID: agentID, sessionID: sessionID, columns: columns, rows: rows)
    }

    public func output(agentID: String, sessionID: String, ownerID: String, cursor: UInt64? = nil, limit: Int = maximumOutputBytes) async throws -> RemoteTerminalOutput {
        try owned(sessionID, ownerID)
        guard limit > 0, limit <= Self.maximumOutputBytes else { throw RemoteComputerError.responseTooLarge(limit: Self.maximumOutputBytes) }
        let expected = cursors[sessionID] ?? 0
        let requested = cursor ?? expected
        guard requested == expected else { throw RemoteComputerError.invalidCursor }
        let result = try await backend.output(agentID: agentID, sessionID: sessionID, cursor: requested, limit: limit)
        guard result.data.count <= limit, result.nextCursor >= requested,
              result.nextCursor - requested == UInt64(result.data.count),
              String(data: result.data, encoding: .utf8) != nil else { throw RemoteComputerError.invalidResponse }
        cursors[sessionID] = result.nextCursor
        if result.exitCode != nil { sessions.removeValue(forKey: sessionID); cursors.removeValue(forKey: sessionID) }
        return result
    }

    public func cancel(agentID: String, sessionID: String, ownerID: String) async throws {
        if cancelled.contains(sessionID) { return }
        try owned(sessionID, ownerID)
        try await backend.cancel(agentID: agentID, sessionID: sessionID)
        cancelled.insert(sessionID); sessions.removeValue(forKey: sessionID); cursors.removeValue(forKey: sessionID)
    }

    private func owned(_ sessionID: String, _ ownerID: String) throws {
        guard let session = sessions[sessionID], session.ownerID == ownerID else { throw RemoteComputerError.ownershipMismatch }
    }
}
