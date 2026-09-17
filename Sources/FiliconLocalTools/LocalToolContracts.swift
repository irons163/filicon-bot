import Foundation
import FiliconDomain

/// Identifies the policy decision that authorized one exact local operation.
/// The app owns validation/signing of the receipt; the helper treats it as
/// opaque evidence bound into the authenticated envelope.
public struct LocalPermissionReceipt: Codable, Hashable, Sendable {
    public let approvalID: UUID
    public let action: LocalToolAction
    public let canonicalTarget: String
    public let directionEpoch: UInt64
    public let expiresAt: Date
    public let signedReceipt: Data

    public init(approvalID: UUID, action: LocalToolAction, canonicalTarget: String, directionEpoch: UInt64, expiresAt: Date, signedReceipt: Data) {
        self.approvalID = approvalID
        self.action = action
        self.canonicalTarget = canonicalTarget
        self.directionEpoch = directionEpoch
        self.expiresAt = expiresAt
        self.signedReceipt = signedReceipt
    }
}

public struct LocalRequestScope: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let generation: UUID
    public let agentID: UUID
    public let runID: UUID
    public let toolCallID: String
    public let nonce: UUID
    public let expiresAt: Date
    public let permissionReceipt: LocalPermissionReceipt?
    /// Security-scoped bookmark data for user-approved filesystem roots. The
    /// shipping sandboxed XPC service requires this for filesystem operations.
    public let securityScopedBookmarks: [Data]

    public init(requestID: UUID = UUID(), generation: UUID, agentID: UUID, runID: UUID, toolCallID: String, nonce: UUID = UUID(), expiresAt: Date, permissionReceipt: LocalPermissionReceipt? = nil, securityScopedBookmarks: [Data] = []) {
        self.requestID = requestID
        self.generation = generation
        self.agentID = agentID
        self.runID = runID
        self.toolCallID = toolCallID
        self.nonce = nonce
        self.expiresAt = expiresAt
        self.permissionReceipt = permissionReceipt
        self.securityScopedBookmarks = securityScopedBookmarks
    }

    private enum CodingKeys: String, CodingKey {
        case requestID, generation, agentID, runID, toolCallID, nonce, expiresAt, permissionReceipt, securityScopedBookmarks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        generation = try values.decode(UUID.self, forKey: .generation)
        agentID = try values.decode(UUID.self, forKey: .agentID)
        runID = try values.decode(UUID.self, forKey: .runID)
        toolCallID = try values.decode(String.self, forKey: .toolCallID)
        nonce = try values.decode(UUID.self, forKey: .nonce)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        permissionReceipt = try values.decodeIfPresent(LocalPermissionReceipt.self, forKey: .permissionReceipt)
        securityScopedBookmarks = try values.decodeIfPresent([Data].self, forKey: .securityScopedBookmarks) ?? []
    }
}

public struct LocalCommand: Codable, Hashable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectoryRoot: String
    public let workingDirectory: String
    public let environment: [String: String]
    public let timeoutMilliseconds: UInt64

    /// `arguments` are passed directly to `posix_spawn`; no shell is inserted.
    public init(executable: String, arguments: [String] = [], workingDirectoryRoot: String, workingDirectory: String = ".", environment: [String: String] = [:], timeoutMilliseconds: UInt64 = 30_000) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectoryRoot = workingDirectoryRoot
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public enum LocalOperation: Codable, Hashable, Sendable {
    case runCommand(LocalCommand)
    case readProcess(sessionID: UUID, offset: Int)
    case sendInput(sessionID: UUID, data: Data, closeAfterWrite: Bool)
    case terminate(sessionID: UUID)
    case readFile(root: String, relativePath: String)
    case listDirectory(root: String, relativePath: String)
    case writeFile(root: String, relativePath: String, data: Data, replace: Bool)

    public var permissionAction: LocalToolAction {
        switch self {
        case .runCommand, .readProcess, .terminate: .runCommand
        case .sendInput: .sendInput
        case .readFile: .readFile
        case .listDirectory: .listDirectory
        case .writeFile: .writeFile
        }
    }
}

public struct LocalProcessSnapshot: Codable, Hashable, Sendable {
    public let sessionID: UUID
    public let processID: Int32
    public let output: Data
    public let nextOffset: Int
    public let isRunning: Bool
    public let exitStatus: Int32?
    public let truncated: Bool
    public let terminationError: LocalToolError?

    public init(sessionID: UUID, processID: Int32, output: Data, nextOffset: Int, isRunning: Bool, exitStatus: Int32?, truncated: Bool, terminationError: LocalToolError? = nil) {
        self.sessionID = sessionID
        self.processID = processID
        self.output = output
        self.nextOffset = nextOffset
        self.isRunning = isRunning
        self.exitStatus = exitStatus
        self.truncated = truncated
        self.terminationError = terminationError
    }
}

public enum LocalOperationResult: Codable, Hashable, Sendable {
    case process(LocalProcessSnapshot)
    case file(Data)
    case directory([String])
    case acknowledged
}

public struct LocalToolWireRequest: Codable, Hashable, Sendable {
    public let scope: LocalRequestScope
    public let operation: LocalOperation
    /// HMAC/session binding supplied and verified by app-bundle XPC wiring.
    public let authenticationTag: Data

    public init(scope: LocalRequestScope, operation: LocalOperation, authenticationTag: Data = Data()) {
        self.scope = scope
        self.operation = operation
        self.authenticationTag = authenticationTag
    }
}

public struct LocalToolWireResponse: Codable, Hashable, Sendable {
    public let requestID: UUID
    public let result: LocalOperationResult?
    public let error: LocalToolError?

    public init(requestID: UUID, result: LocalOperationResult?, error: LocalToolError?) {
        self.requestID = requestID
        self.result = result
        self.error = error
    }
}

public enum LocalToolError: Error, Codable, Hashable, Sendable, LocalizedError {
    case invalidRequest(String)
    case expiredRequest
    case staleGeneration
    case replayedRequest
    case permissionMismatch
    case workspaceAuthorizationNeedsRenewal
    case pathEscape
    case unsupportedFileType
    case processNotFound
    case processExited
    case outputLimitExceeded
    case timedOut
    case ioFailure(String)

    public var errorDescription: String? {
        if self == .workspaceAuthorizationNeedsRenewal {
            return "The saved workspace authorization is no longer valid for this app. Ask the user to choose the folder again in the chat. No file operation ran; this is not a project file format error."
        }
        return String(describing: self)
    }
}

/// Same semantic surface as the eventual NSXPC interface, kept free of XPC
/// types so it can be exercised by SwiftPM and transported over another IPC.
public protocol LocalToolHelperProtocol: Sendable {
    func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse
    func cancel(runID: UUID, generation: UUID) async
}
