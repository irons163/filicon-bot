import Foundation

/// A server-declared boundary. This is evidence supplied by the remote service,
/// not a claim that HTTPS itself provides sandboxing.
public struct RemoteFilesystemBoundary: Codable, Sendable, Equatable {
    public var root: String
    public var writableRoots: [String]

    public init(root: String, writableRoots: [String]) {
        self.root = root
        self.writableRoots = writableRoots
    }
}

public struct RemoteResourceCaps: Codable, Sendable, Equatable {
    public var cpuMillisecondsPerSession: UInt64
    public var memoryBytes: UInt64
    public var storageBytes: UInt64
    public var maximumSessions: UInt32

    public init(cpuMillisecondsPerSession: UInt64, memoryBytes: UInt64, storageBytes: UInt64, maximumSessions: UInt32) {
        self.cpuMillisecondsPerSession = cpuMillisecondsPerSession
        self.memoryBytes = memoryBytes
        self.storageBytes = storageBytes
        self.maximumSessions = maximumSessions
    }
}

public struct RemoteIsolationDeclaration: Codable, Sendable, Equatable {
    public var identity: String
    public var sessionGeneration: UInt64
    public var filesystem: RemoteFilesystemBoundary
    public var resourceCaps: RemoteResourceCaps

    public init(identity: String, sessionGeneration: UInt64, filesystem: RemoteFilesystemBoundary, resourceCaps: RemoteResourceCaps) {
        self.identity = identity
        self.sessionGeneration = sessionGeneration
        self.filesystem = filesystem
        self.resourceCaps = resourceCaps
    }
}

public struct RemoteIsolationPolicy: Sendable, Equatable {
    public static let conservative = RemoteIsolationPolicy(
        requiredIdentity: nil,
        requiredFilesystemRoot: "/workspace",
        minimumSessionGeneration: 1,
        maximumResourceCaps: .init(
            cpuMillisecondsPerSession: 86_400_000,
            memoryBytes: 8 * 1_024 * 1_024 * 1_024,
            storageBytes: 64 * 1_024 * 1_024 * 1_024,
            maximumSessions: 16
        )
    )

    /// When nil, the first valid HTTPS response pins the identity for this backend instance.
    public var requiredIdentity: String?
    public var requiredFilesystemRoot: String
    /// Persist the last accepted generation and supply it here to prevent rollback
    /// across application/backend instances.
    public var minimumSessionGeneration: UInt64
    public var maximumResourceCaps: RemoteResourceCaps

    public init(requiredIdentity: String?, requiredFilesystemRoot: String, minimumSessionGeneration: UInt64 = 1, maximumResourceCaps: RemoteResourceCaps) {
        self.requiredIdentity = requiredIdentity
        self.requiredFilesystemRoot = requiredFilesystemRoot
        self.minimumSessionGeneration = minimumSessionGeneration
        self.maximumResourceCaps = maximumResourceCaps
    }
}

public struct RemoteSecuritySnapshot: Sendable, Equatable {
    public enum State: String, Sendable, Equatable { case unverified, trusted, rejected }
    public var state: State
    public var declaration: RemoteIsolationDeclaration?
    public var failure: RemoteComputerError?

    public init(state: State, declaration: RemoteIsolationDeclaration? = nil, failure: RemoteComputerError? = nil) {
        self.state = state
        self.declaration = declaration
        self.failure = failure
    }
}

public actor RemoteIsolationVerifier {
    private enum Record { case trusted(RemoteIsolationDeclaration), rejected(RemoteComputerError, RemoteIsolationDeclaration?) }
    private let policy: RemoteIsolationPolicy
    private var records: [String: Record] = [:]

    public init(policy: RemoteIsolationPolicy = .conservative) { self.policy = policy }

    public func validate(_ declaration: RemoteIsolationDeclaration?, agentID: String) throws {
        if case .rejected(let error, _)? = records[agentID] { throw error }
        guard let declaration else { try reject(.missingIsolationDeclaration, agentID: agentID, declaration: nil) }
        guard Self.validIdentity(declaration.identity), declaration.sessionGeneration > 0,
              Self.validFilesystem(declaration.filesystem, requiredRoot: policy.requiredFilesystemRoot),
              Self.validCaps(declaration.resourceCaps) else {
            try reject(.invalidIsolationDeclaration, agentID: agentID, declaration: declaration)
        }
        guard Self.within(declaration.resourceCaps, policy.maximumResourceCaps) else {
            try reject(.isolationResourceCapsExceeded, agentID: agentID, declaration: declaration)
        }
        guard declaration.sessionGeneration >= policy.minimumSessionGeneration else {
            try reject(.isolationGenerationRollback(expected: policy.minimumSessionGeneration, actual: declaration.sessionGeneration), agentID: agentID, declaration: declaration)
        }
        if let requiredIdentity = policy.requiredIdentity, declaration.identity != requiredIdentity {
            try reject(.isolationIdentityMismatch, agentID: agentID, declaration: declaration)
        }
        if case .trusted(let pinned)? = records[agentID] {
            if declaration.identity != pinned.identity {
                try reject(.isolationIdentityMismatch, agentID: agentID, declaration: declaration)
            }
            if declaration.sessionGeneration < pinned.sessionGeneration {
                try reject(.isolationGenerationRollback(expected: pinned.sessionGeneration, actual: declaration.sessionGeneration), agentID: agentID, declaration: declaration)
            }
            if declaration.sessionGeneration != pinned.sessionGeneration {
                try reject(.isolationGenerationChanged(expected: pinned.sessionGeneration, actual: declaration.sessionGeneration), agentID: agentID, declaration: declaration)
            }
            if declaration.filesystem != pinned.filesystem {
                try reject(.isolationBoundaryChanged, agentID: agentID, declaration: declaration)
            }
            if declaration.resourceCaps != pinned.resourceCaps {
                try reject(.isolationResourceCapsChanged, agentID: agentID, declaration: declaration)
            }
        } else {
            records[agentID] = .trusted(declaration)
        }
    }

    public func expectedBinding(agentID: String) throws -> RemoteIsolationDeclaration? {
        switch records[agentID] {
        case .trusted(let declaration): declaration
        case .rejected(let error, _): throw error
        case nil: nil
        }
    }

    public func snapshot(agentID: String) -> RemoteSecuritySnapshot {
        switch records[agentID] {
        case .trusted(let declaration): .init(state: .trusted, declaration: declaration)
        case .rejected(let error, let declaration): .init(state: .rejected, declaration: declaration, failure: error)
        case nil: .init(state: .unverified)
        }
    }

    private func reject(_ error: RemoteComputerError, agentID: String, declaration: RemoteIsolationDeclaration?) throws -> Never {
        records[agentID] = .rejected(error, declaration)
        throw error
    }

    private static func validIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value != 0x7f }
    }

    private static func validFilesystem(_ boundary: RemoteFilesystemBoundary, requiredRoot: String) -> Bool {
        guard validAbsolutePath(boundary.root), boundary.root == requiredRoot,
              boundary.writableRoots.count <= 64 else { return false }
        return boundary.writableRoots.allSatisfy { validAbsolutePath($0) && isWithin($0, root: boundary.root) }
    }

    private static func validAbsolutePath(_ path: String) -> Bool {
        guard path.first == "/", path.utf8.count <= 4_096, !path.contains("\0"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return components.dropFirst().allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isWithin(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func validCaps(_ caps: RemoteResourceCaps) -> Bool {
        caps.cpuMillisecondsPerSession > 0 && caps.memoryBytes > 0 && caps.storageBytes > 0 && caps.maximumSessions > 0
    }

    private static func within(_ caps: RemoteResourceCaps, _ maximum: RemoteResourceCaps) -> Bool {
        caps.cpuMillisecondsPerSession <= maximum.cpuMillisecondsPerSession && caps.memoryBytes <= maximum.memoryBytes &&
        caps.storageBytes <= maximum.storageBytes && caps.maximumSessions <= maximum.maximumSessions
    }
}
