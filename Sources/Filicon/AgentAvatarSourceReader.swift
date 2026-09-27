import Foundation
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconLocalTools
import FiliconComputer

/// Host-side local source adapter. This does not authorize the avatar change:
/// folder selection, exact file-read review and image-change approval are distinct.
struct AgentAvatarSourceReader: Sendable {
    let runtime: LocalToolRuntime
    let folders: WorkspaceFolderCoordinator
    let policy: ToolPermissionPolicy
    let imageStore: AgentAvatarStore
    /// App composition must bind account generation, active origin and owner.
    let validateScope: @Sendable () async throws -> Void
    /// The regular read-file approval gate, not the image-change approval gate.
    let authorizeRead: @Sendable (LocalOperation, ToolContext, ToolCallID) async throws -> Void

    func prepare(path: String, agentID: UUID, call: NormalizedToolCall,
                 context: ToolContext) async throws -> PreparedAgentAvatar {
        try Self.validatePath(path)
        try await checkScopeAndPolicy()
        let store = runtime.workspaceStore
        let known = await store.authorizations()
        // Longest component-boundary match, never a raw string prefix match.
        let prior = known.filter { Self.relativePath(path, under: $0.path) != nil }
            .max { $0.path.count < $1.path.count }
        let root: String
        if let prior, try await store.accessState(forExactRoot: prior.path) == .ready {
            root = prior.path
        } else {
            guard let selected = try await folders.request(context: context, callID: call.id,
                root: prior?.path, requiresReauthorization: prior != nil) else {
                throw CancellationError()
            }
            // Keep the absolute file target unchanged even if another folder is selected.
            guard Self.relativePath(path, under: selected) != nil,
                  prior == nil || selected == prior?.path else { throw LocalToolError.pathEscape }
            root = selected
        }
        try await checkScopeAndPolicy()
        guard let relative = Self.relativePath(path, under: root),
              let grant = await store.authorization(forExactRoot: root),
              try await store.accessState(forExactRoot: root) == .ready else {
            throw LocalToolError.permissionMismatch
        }
        let operation = LocalOperation.readFile(root: root, relativePath: relative)
        try await authorizeRead(operation, context, call.id)
        try await checkScopeAndPolicy()
        try await validateGrant(grant)
        let result = try await runtime.perform(operation: operation, conversationID: context.conversationID,
            agentID: agentID, runID: context.runID, toolCallID: "avatar-source:\(call.id.rawValue)")
        try await checkScopeAndPolicy()
        try await validateGrant(grant)
        guard case .file(let bytes) = result else { throw AgentAvatarChangeError.invalid }
        guard !bytes.isEmpty, bytes.count <= AgentAvatarChange.maximumImageSourceBytes else {
            throw AgentAvatarChangeError.invalid
        }
        // The helper has already read through its descriptor-relative safe filesystem.
        // Decode the captured bytes, never reopen the model's original pathname.
        return try imageStore.prepareImage(data: bytes)
    }

    private func checkScopeAndPolicy() async throws {
        try Task.checkCancellation()
        try await validateScope()
        guard await policy.effectivePermission(for: .readFile) != .never else {
            throw LocalToolError.permissionMismatch
        }
    }

    private func validateGrant(_ grant: WorkspaceAuthorization) async throws {
        guard await runtime.workspaceStore.authorization(forExactRoot: grant.path) == grant,
              try await runtime.workspaceStore.accessState(forExactRoot: grant.path) == .ready else {
            throw LocalToolError.permissionMismatch
        }
    }

    private static func validatePath(_ path: String) throws {
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              URL(fileURLWithPath: path).standardizedFileURL.path == path else {
            throw LocalToolError.pathEscape
        }
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }
}

/// The backend and remote owner are captured by trusted host composition, never
/// taken from tool arguments or the UI's currently selected computer.
struct AgentRemoteAvatarSourceReader: Sendable {
    let backend: any RemoteFileBackend
    let remoteAgentID: String
    let imageStore: AgentAvatarStore
    let validateScope: @Sendable () async throws -> Void
    let authorizeRead: @Sendable (String, ToolContext, ToolCallID) async throws -> Void

    func prepare(path: String, call: NormalizedToolCall, context: ToolContext) async throws -> PreparedAgentAvatar {
        try RemoteFileTransfer.validate(path: path)
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteComputerError.invalidIdentifier
        }
        try Task.checkCancellation()
        try await validateScope()
        try await authorizeRead(path, context, call.id)
        try Task.checkCancellation()
        try await validateScope()
        let transfer = RemoteFileTransfer(backend: backend, maximumBytes: AgentAvatarChange.maximumImageSourceBytes)
        let bytes = try await transfer.download(agentID: remoteAgentID, path: path)
        try Task.checkCancellation()
        try await validateScope()
        guard !bytes.isEmpty else { throw AgentAvatarChangeError.invalid }
        return try imageStore.prepareImage(data: bytes)
    }
}
