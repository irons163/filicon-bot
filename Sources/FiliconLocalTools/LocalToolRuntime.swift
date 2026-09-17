import CryptoKit
import Foundation
import Security
import FiliconDomain

/// App-side session for the shipping local-tool XPC service. Every instance
/// uses a fresh generation and 256-bit HMAC key and issues a receipt bound to
/// one exact operation before forwarding it to the helper.
public actor LocalToolRuntime {
    public let generation: UUID
    public nonisolated let workspaceStore: WorkspaceAuthorizationStore

    private let helper: any LocalToolHelperProtocol
    private let authenticator: LocalSessionAuthenticator
    private var directionEpoch: UInt64 = 1
    private var runsByConversation: [UUID: Set<UUID>] = [:]
    private var liveShellRunsByConversation: [UUID: Set<UUID>] = [:]

    public init(
        workspaceStore: WorkspaceAuthorizationStore,
        generation: UUID = UUID(),
        sessionKey: Data = LocalToolRuntime.randomSessionKey(),
        helper: (any LocalToolHelperProtocol)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.generation = generation
        authenticator = LocalSessionAuthenticator(sessionKey: sessionKey)
        self.helper = helper ?? LocalToolXPCClient(generation: generation, sessionKey: sessionKey)
    }

    public static func randomSessionKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            preconditionFailure("Unable to create a local-tool session key")
        }
        return Data(bytes)
    }

    public func authorizationTarget(for operation: LocalOperation) throws -> String {
        try Self.canonicalTarget(for: operation)
    }

    public func perform(
        operation: LocalOperation,
        conversationID: UUID,
        agentID: UUID,
        runID: UUID,
        toolCallID: String,
        now: Date = Date()
    ) async throws -> LocalOperationResult {
        try Task.checkCancellation()
        let target = try Self.canonicalTarget(for: operation)
        let bookmarks: [Data]
        if let root = Self.root(for: operation) {
            bookmarks = [try await workspaceStore.transportBookmark(forExactRoot: root)]
        } else {
            bookmarks = []
        }

        let expiresAt = now.addingTimeInterval(120)
        let unsigned = LocalPermissionReceipt(
            approvalID: UUID(),
            action: operation.permissionAction,
            canonicalTarget: target,
            directionEpoch: directionEpoch,
            expiresAt: expiresAt,
            signedReceipt: Data()
        )
        let receipt = LocalPermissionReceipt(
            approvalID: unsigned.approvalID,
            action: unsigned.action,
            canonicalTarget: unsigned.canonicalTarget,
            directionEpoch: unsigned.directionEpoch,
            expiresAt: unsigned.expiresAt,
            signedReceipt: try authenticator.tag(for: unsigned)
        )
        let scope = LocalRequestScope(
            generation: generation,
            agentID: agentID,
            runID: runID,
            toolCallID: toolCallID,
            expiresAt: expiresAt,
            permissionReceipt: receipt,
            securityScopedBookmarks: bookmarks
        )
        runsByConversation[conversationID, default: []].insert(runID)
        if case .runCommand = operation {
            liveShellRunsByConversation[conversationID, default: []].insert(runID)
        }
        let response = await helper.perform(.init(scope: scope, operation: operation))
        try Task.checkCancellation()
        if let error = response.error {
            liveShellRunsByConversation[conversationID]?.remove(runID)
            throw error
        }
        guard let result = response.result else {
            liveShellRunsByConversation[conversationID]?.remove(runID)
            throw LocalToolError.invalidRequest("helper returned no result")
        }
        if case .runCommand = operation {
            guard case .process(let snapshot) = result, snapshot.isRunning else {
                liveShellRunsByConversation[conversationID]?.remove(runID)
                return result
            }
        }
        return result
    }

    public func cancel(conversationID: UUID) async {
        let runIDs = runsByConversation.removeValue(forKey: conversationID) ?? []
        liveShellRunsByConversation.removeValue(forKey: conversationID)
        directionEpoch &+= 1
        for runID in runIDs { await helper.cancel(runID: runID, generation: generation) }
    }

    public func cancel(runID: UUID) async {
        for key in runsByConversation.keys {
            runsByConversation[key]?.remove(runID)
        }
        await helper.cancel(runID: runID, generation: generation)
    }

    /// Cancels only a currently registered run owned by the exact
    /// conversation. This is the authority boundary used by transcript cards;
    /// an arbitrary UUID must never be reported as a successful cancellation.
    @discardableResult
    public func cancel(runID: UUID, conversationID: UUID) async -> Bool {
        guard liveShellRunsByConversation[conversationID]?.contains(runID) == true else { return false }
        liveShellRunsByConversation[conversationID]?.remove(runID)
        runsByConversation[conversationID]?.remove(runID)
        await helper.cancel(runID: runID, generation: generation)
        return true
    }

    private static func root(for operation: LocalOperation) -> String? {
        switch operation {
        case .runCommand(let command): command.workingDirectoryRoot
        case .readFile(let root, _), .listDirectory(let root, _), .writeFile(let root, _, _, _): root
        case .readProcess, .sendInput, .terminate: nil
        }
    }

    private static func canonicalTarget(for operation: LocalOperation) throws -> String {
        switch operation {
        case .runCommand(let command):
            let executable = URL(fileURLWithPath: command.executable).standardizedFileURL.path
            let arguments = try String(decoding: JSONEncoder().encode(command.arguments), as: UTF8.self)
            return "\(executable) \(arguments)"
        case .readProcess(let id, _), .sendInput(let id, _, _), .terminate(let id):
            return "process:\(id.uuidString.lowercased())"
        case .readFile(let root, let path), .listDirectory(let root, let path), .writeFile(let root, let path, _, _):
            return try SafeFileSystem().canonicalTarget(root: root, relativePath: path)
        }
    }
}
