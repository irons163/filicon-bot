import CryptoKit
import Foundation

public struct RemoteFileDescriptor: Codable, Sendable, Equatable {
    public var size: Int
    public var sha256: String
    public init(size: Int, sha256: String) { self.size = size; self.sha256 = sha256 }
}

public protocol RemoteFileBackend: Sendable {
    func upload(agentID: String, path: String, data: Data, descriptor: RemoteFileDescriptor) async throws
    func download(agentID: String, path: String, maximumBytes: Int) async throws -> (Data, RemoteFileDescriptor)
}

public struct RemoteFileTransfer: Sendable {
    public static let defaultMaximumBytes = 64 * 1024 * 1024
    private let backend: any RemoteFileBackend
    private let maximumBytes: Int
    public init(backend: any RemoteFileBackend, maximumBytes: Int = defaultMaximumBytes) {
        self.backend = backend; self.maximumBytes = max(1, maximumBytes)
    }
    public func upload(agentID: String, path: String, data: Data) async throws -> RemoteFileDescriptor {
        try Self.validate(path: path)
        guard data.count <= maximumBytes else { throw RemoteComputerError.requestTooLarge(limit: maximumBytes) }
        let descriptor = RemoteFileDescriptor(size: data.count, sha256: Self.sha256(data))
        try await backend.upload(agentID: agentID, path: path, data: data, descriptor: descriptor)
        return descriptor
    }
    public func download(agentID: String, path: String) async throws -> Data {
        try Self.validate(path: path)
        let (data, descriptor) = try await backend.download(agentID: agentID, path: path, maximumBytes: maximumBytes)
        guard data.count <= maximumBytes else { throw RemoteComputerError.responseTooLarge(limit: maximumBytes) }
        guard descriptor.size == data.count, descriptor.sha256.lowercased() == Self.sha256(data) else { throw RemoteComputerError.integrityMismatch }
        return data
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validate(path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 4_096, path.first == "/", !path.contains("\0"), !path.contains("\\"),
              parts.count > 1, parts.first?.isEmpty == true,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RemoteComputerError.invalidIdentifier
        }
    }
}
