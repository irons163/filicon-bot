import CryptoKit
import Foundation

public struct LocalSessionAuthenticator: Sendable {
    private let key: SymmetricKey

    public init(sessionKey: Data) {
        key = SymmetricKey(data: sessionKey)
    }

    public func tag(for request: LocalToolWireRequest) throws -> Data {
        let unsigned = LocalToolWireRequest(scope: request.scope, operation: request.operation, authenticationTag: Data())
        let encoded = try Self.encoder.encode(unsigned)
        return Data(HMAC<SHA256>.authenticationCode(for: encoded, using: key))
    }

    public func verify(_ request: LocalToolWireRequest) -> Bool {
        guard let encoded = try? Self.encoder.encode(LocalToolWireRequest(scope: request.scope, operation: request.operation, authenticationTag: Data())) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(request.authenticationTag, authenticating: encoded, using: key)
    }

    public func tag(for receipt: LocalPermissionReceipt) throws -> Data {
        let unsigned = LocalPermissionReceipt(
            approvalID: receipt.approvalID,
            action: receipt.action,
            canonicalTarget: receipt.canonicalTarget,
            directionEpoch: receipt.directionEpoch,
            expiresAt: receipt.expiresAt,
            signedReceipt: Data()
        )
        return Data(HMAC<SHA256>.authenticationCode(for: try Self.encoder.encode(unsigned), using: key))
    }

    public func verify(_ receipt: LocalPermissionReceipt) -> Bool {
        let unsigned = LocalPermissionReceipt(
            approvalID: receipt.approvalID,
            action: receipt.action,
            canonicalTarget: receipt.canonicalTarget,
            directionEpoch: receipt.directionEpoch,
            expiresAt: receipt.expiresAt,
            signedReceipt: Data()
        )
        guard let encoded = try? Self.encoder.encode(unsigned) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(receipt.signedReceipt, authenticating: encoded, using: key)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

/// Concrete helper-side implementation. This type deliberately contains all
/// file descriptors and process handles; the future NSXPC service should own
/// one instance and expose only encoded `LocalToolWireRequest/Response` data.
public actor LocalToolProcessHost: LocalToolHelperProtocol {
    public typealias Authenticator = @Sendable (LocalToolWireRequest) -> Bool

    private let guardState: LocalRequestGuard
    private let authenticate: Authenticator
    private let requiresSecurityScopedRoots: Bool
    private let requiresPermissionReceipts: Bool
    private let verifyReceipt: (@Sendable (LocalPermissionReceipt) -> Bool)?
    private let fileSystem = SafeFileSystem()
    private let processes = LocalProcessSupervisor()

    public init(
        generation: UUID,
        requiresSecurityScopedRoots: Bool = false,
        requiresPermissionReceipts: Bool = false,
        authenticate: @escaping Authenticator,
        verifyReceipt: (@Sendable (LocalPermissionReceipt) -> Bool)? = nil
    ) {
        guardState = LocalRequestGuard(generation: generation)
        self.requiresSecurityScopedRoots = requiresSecurityScopedRoots
        self.requiresPermissionReceipts = requiresPermissionReceipts
        self.authenticate = authenticate
        self.verifyReceipt = verifyReceipt
    }

    public func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        do {
            guard authenticate(request) else { throw LocalToolError.invalidRequest("invalid session authentication") }
            try await guardState.consume(request.scope)
            try validateReceipt(request)
            let scopedURLs = try openSecurityScopes(for: request)
            defer { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
            let result = try await execute(request.operation, scope: request.scope)
            return LocalToolWireResponse(requestID: request.scope.requestID, result: result, error: nil)
        } catch let error as LocalToolError {
            return LocalToolWireResponse(requestID: request.scope.requestID, result: nil, error: error)
        } catch {
            return LocalToolWireResponse(requestID: request.scope.requestID, result: nil, error: .ioFailure(error.localizedDescription))
        }
    }

    private func openSecurityScopes(for request: LocalToolWireRequest) throws -> [URL] {
        guard let requiredRoot = filesystemRoot(for: request.operation) else { return [] }
        var opened: [URL] = []
        for bookmark in request.scope.securityScopedBookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ), !stale else { continue }
            let standardized = url.standardizedFileURL
            guard standardized.path == URL(fileURLWithPath: requiredRoot).standardizedFileURL.path,
                  standardized.startAccessingSecurityScopedResource() else { continue }
            opened.append(standardized)
        }
        if requiresSecurityScopedRoots, opened.isEmpty {
            throw LocalToolError.permissionMismatch
        }
        return opened
    }

    private func filesystemRoot(for operation: LocalOperation) -> String? {
        switch operation {
        case .runCommand(let command): command.workingDirectoryRoot
        case .readFile(let root, _), .listDirectory(let root, _), .writeFile(let root, _, _, _): root
        case .readProcess, .sendInput, .terminate: nil
        }
    }

    public func cancel(runID: UUID, generation: UUID) async {
        await processes.cancel(runID: runID, generation: generation)
    }

    public func advanceDirectionEpoch(to epoch: UInt64) async {
        await guardState.advanceDirectionEpoch(to: epoch)
    }

    private func execute(_ operation: LocalOperation, scope: LocalRequestScope) async throws -> LocalOperationResult {
        switch operation {
        case .runCommand(let command):
            return .process(try await processes.start(command, scope: scope))
        case .readProcess(let sessionID, let offset):
            return .process(try await processes.read(sessionID: sessionID, offset: offset, generation: scope.generation))
        case .sendInput(let sessionID, let data, let close):
            try await processes.sendInput(sessionID: sessionID, data: data, closeAfterWrite: close, generation: scope.generation)
            return .acknowledged
        case .terminate(let sessionID):
            try await processes.terminate(sessionID: sessionID, generation: scope.generation)
            return .acknowledged
        case .readFile(let root, let path):
            return .file(try fileSystem.read(root: root, relativePath: path))
        case .listDirectory(let root, let path):
            return .directory(try fileSystem.list(root: root, relativePath: path))
        case .writeFile(let root, let path, let data, let replace):
            try fileSystem.write(root: root, relativePath: path, data: data, replace: replace)
            return .acknowledged
        }
    }

    private func validateReceipt(_ request: LocalToolWireRequest) throws {
        guard let receipt = request.scope.permissionReceipt else {
            if requiresPermissionReceipts { throw LocalToolError.permissionMismatch }
            return
        }
        guard receipt.action == request.operation.permissionAction,
              receipt.canonicalTarget == (try operationTarget(request.operation)),
              !requiresPermissionReceipts || verifyReceipt?(receipt) == true else {
            throw LocalToolError.permissionMismatch
        }
    }

    private func operationTarget(_ operation: LocalOperation) throws -> String {
        switch operation {
        case .runCommand(let command):
            let executable = URL(fileURLWithPath: command.executable).standardizedFileURL.path
            let arguments = try String(decoding: JSONEncoder().encode(command.arguments), as: UTF8.self)
            return "\(executable) \(arguments)"
        case .readProcess(let id, _), .sendInput(let id, _, _), .terminate(let id):
            return "process:\(id.uuidString.lowercased())"
        case .readFile(let root, let path), .listDirectory(let root, let path), .writeFile(let root, let path, _, _):
            return try fileSystem.canonicalTarget(root: root, relativePath: path)
        }
    }
}
