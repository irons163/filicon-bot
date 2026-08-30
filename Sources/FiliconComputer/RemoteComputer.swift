import Foundation

public struct RemoteComputerCredential: Sendable, Equatable {
    public var headerName: String
    public var value: String

    public init(headerName: String = "Authorization", value: String) {
        self.headerName = headerName
        self.value = value
    }
}

/// Credentials are referenced by opaque names so profiles never need to persist secrets.
public protocol RemoteComputerCredentialResolver: Sendable {
    func resolve(reference: String) async throws -> RemoteComputerCredential
}

public struct RemoteComputerCapabilities: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let lifecycle = Self(rawValue: 1 << 0)
    public static let recreate = Self(rawValue: 1 << 1)
    public static let update = Self(rawValue: 1 << 2)
    public static let terminal = Self(rawValue: 1 << 3)
    public static let fileTransfer = Self(rawValue: 1 << 4)
    public static let egress = Self(rawValue: 1 << 5)
}

public struct RemoteComputerProfile: Sendable, Equatable {
    public var endpoint: URL
    public var credentialReference: String?
    public var capabilities: RemoteComputerCapabilities
    public var isolationPolicy: RemoteIsolationPolicy

    public init(endpoint: URL, credentialReference: String? = nil, capabilities: RemoteComputerCapabilities, isolationPolicy: RemoteIsolationPolicy = .conservative) throws {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw RemoteComputerError.invalidEndpoint
        }
        if components.path.isEmpty { components.path = "/" }
        else if !components.path.hasSuffix("/") { components.path += "/" }
        guard let normalized = components.url else { throw RemoteComputerError.invalidEndpoint }
        if let credentialReference {
            guard !credentialReference.isEmpty, credentialReference.utf8.count <= 256,
                  credentialReference.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) || [45, 46, 47, 58, 95].contains(byte)
                  }) else { throw RemoteComputerError.credentialUnavailable }
        }
        self.endpoint = normalized
        self.credentialReference = credentialReference
        self.capabilities = capabilities
        self.isolationPolicy = isolationPolicy
    }

    public func require(_ capability: RemoteComputerCapabilities) throws {
        guard capabilities.contains(capability) else { throw RemoteComputerError.unsupportedCapability }
    }
}

public enum RemoteComputerError: Error, LocalizedError, Sendable, Equatable {
    case invalidEndpoint
    case invalidResponse
    case crossOriginRedirect
    case authenticationRedirect
    case credentialUnavailable
    case unsupportedCapability
    case requestTooLarge(limit: Int)
    case responseTooLarge(limit: Int)
    case integrityMismatch
    case invalidIdentifier
    case invalidCursor
    case ownershipMismatch
    case operationBusy
    case operationCancelled
    case missingIsolationDeclaration
    case invalidIsolationDeclaration
    case isolationIdentityMismatch
    case isolationGenerationRollback(expected: UInt64, actual: UInt64)
    case isolationGenerationChanged(expected: UInt64, actual: UInt64)
    case isolationBoundaryChanged
    case isolationResourceCapsExceeded
    case isolationResourceCapsChanged
    case operationFailed(status: Int, message: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint: "Enter a valid HTTPS remote-computer endpoint."
        case .invalidResponse: "The remote computer returned an invalid response."
        case .crossOriginRedirect: "The remote computer attempted an untrusted redirect."
        case .authenticationRedirect: "The remote computer redirected to a sign-in page; update its credential."
        case .credentialUnavailable: "The remote-computer credential is unavailable or invalid."
        case .unsupportedCapability: "The remote computer does not advertise this capability."
        case .requestTooLarge(let limit): "The remote-computer request exceeds \(limit) bytes."
        case .responseTooLarge(let limit): "The remote-computer response exceeds \(limit) bytes."
        case .integrityMismatch: "Remote file bytes failed their SHA-256 integrity check."
        case .invalidIdentifier: "A remote identifier or path is invalid."
        case .invalidCursor: "The remote terminal output cursor is stale or invalid."
        case .ownershipMismatch: "This terminal belongs to another task."
        case .operationBusy: "A remote-computer operation is already active."
        case .operationCancelled: "The remote-computer operation was cancelled."
        case .missingIsolationDeclaration: "The remote service did not declare its isolation and resource boundaries."
        case .invalidIsolationDeclaration: "The remote service declared invalid or excessive isolation resource boundaries."
        case .isolationIdentityMismatch: "The remote isolation identity changed or did not match the configured identity."
        case .isolationGenerationRollback: "The remote isolation session generation rolled back."
        case .isolationGenerationChanged: "The remote isolation session generation changed; create a new trusted connection."
        case .isolationBoundaryChanged: "The remote filesystem boundary changed."
        case .isolationResourceCapsExceeded: "The remote service resource caps exceed the configured safety limits."
        case .isolationResourceCapsChanged: "The remote isolation resource caps changed."
        case .operationFailed(let status, let message): message ?? "Remote-computer operation failed with HTTP \(status)."
        }
    }
}

public enum RemoteComputerState: String, Codable, Sendable, Equatable {
    case off, hibernated, pulling, running, failed
}

public struct RemoteComputerStatus: Codable, Sendable, Equatable {
    public var state: RemoteComputerState
    public var vncURL: URL?
    public var pullPercent: Double?
    public var imageUpdateAvailable: Bool?
    public var operationID: String?
    /// Minimum Filicon app version required by this backend/gateway.
    /// Optional for compatibility with older lifecycle services.
    public var minimumAppVersion: String?

    public init(state: RemoteComputerState, vncURL: URL? = nil, pullPercent: Double? = nil, imageUpdateAvailable: Bool? = nil, operationID: String? = nil, minimumAppVersion: String? = nil) {
        self.state = state
        self.vncURL = vncURL
        self.pullPercent = pullPercent.map { min(100, max(0, $0)) }
        self.imageUpdateAvailable = imageUpdateAvailable
        self.operationID = operationID
        self.minimumAppVersion = minimumAppVersion
    }
}

public struct RemoteRecreateRequest: Codable, Sendable, Equatable {
    public var preserveData: Bool
    public var force: Bool
    public init(preserveData: Bool, force: Bool = false) { self.preserveData = preserveData; self.force = force }
}

public struct RemoteOperation: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled }
    public var id: String
    public var state: State
    public var message: String?
    public init(id: String, state: State, message: String? = nil) { self.id = id; self.state = state; self.message = message }
}

public protocol RemoteComputerBackend: Sendable {
    func status(agentID: String) async throws -> RemoteComputerStatus
    func ensure(agentID: String) async throws -> RemoteComputerStatus
    func recreate(agentID: String, request: RemoteRecreateRequest) async throws -> RemoteOperation
    func operation(agentID: String, operationID: String) async throws -> RemoteOperation
    func cancel(agentID: String, operationID: String) async throws
}

public actor RemoteComputerLifecycle {
    private let backend: any RemoteComputerBackend
    private let clock: any ComputerClock
    private var generation: UInt64 = 0
    private var active: (generation: UInt64, id: String)?
    private var startingGeneration: UInt64?

    public init(backend: any RemoteComputerBackend, clock: any ComputerClock = SystemComputerClock()) {
        self.backend = backend; self.clock = clock
    }

    public func status(agentID: String) async throws -> RemoteComputerStatus { try await backend.status(agentID: agentID) }
    public func ensure(agentID: String) async throws -> RemoteComputerStatus { try await backend.ensure(agentID: agentID) }
    public func reset(agentID: String, force: Bool = false) async throws -> RemoteOperation {
        try await recreate(agentID: agentID, preserveData: false, force: force)
    }
    public func update(agentID: String, force: Bool = false) async throws -> RemoteOperation {
        try await recreate(agentID: agentID, preserveData: true, force: force)
    }
    public func recreate(agentID: String, preserveData: Bool, force: Bool = false) async throws -> RemoteOperation {
        guard active == nil, startingGeneration == nil else { throw RemoteComputerError.operationBusy }
        generation &+= 1
        let token = generation
        startingGeneration = token
        let result: RemoteOperation
        do {
            result = try await backend.recreate(agentID: agentID, request: .init(preserveData: preserveData, force: force))
        } catch {
            if startingGeneration == token { startingGeneration = nil }
            throw error
        }
        guard generation == token else { throw RemoteComputerError.operationCancelled }
        startingGeneration = nil
        if result.state == .queued || result.state == .running { active = (token, result.id) }
        return result
    }

    public func poll(agentID: String, operationID: String, intervalMilliseconds: Int64 = 1_000, maximumAttempts: Int = 120) async throws -> RemoteOperation {
        guard maximumAttempts > 0 else { throw RemoteComputerError.invalidResponse }
        let token = active?.id == operationID ? active!.generation : generation
        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            guard generation == token else { throw RemoteComputerError.operationCancelled }
            let value = try await backend.operation(agentID: agentID, operationID: operationID)
            guard generation == token else { throw RemoteComputerError.operationCancelled }
            if value.state != .queued && value.state != .running {
                if active?.id == operationID { active = nil }
                return value
            }
            if attempt + 1 < maximumAttempts { try await clock.sleep(milliseconds: intervalMilliseconds) }
        }
        throw ComputerSessionError.statusTimedOut
    }

    public func cancel(agentID: String) async throws {
        generation &+= 1
        startingGeneration = nil
        guard let operation = active else { return }
        active = nil
        do { try await backend.cancel(agentID: agentID, operationID: operation.id) }
        catch {
            active = (generation, operation.id)
            throw error
        }
    }
}
