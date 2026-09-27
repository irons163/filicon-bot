import CryptoKit
import Foundation
import FiliconDomain
import FiliconLocalTools

/// Immutable publication input. No source URL survives into the payload, and no
/// storage side effects occur until the host separately authorizes publication.
struct PreparedAgentPublicationFile: Sendable, Equatable {
    let bytes: Data
    let filename: String
    let digest: String

    fileprivate init(bytes: Data, filename: String) {
        self.bytes = bytes
        self.filename = filename
        self.digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct AgentPublicationFileSource: Sendable {
    let reader: AuthorizedAgentFileReader

    // Current helper transport is bounded to 10 MiB. Larger file/media transport
    // remains separate work; this is not the final publication size contract.
    static let maximumBytes = 10 * 1_024 * 1_024

    func prepare(url: String, agentID: UUID, call: NormalizedToolCall,
                 context: ToolContext) async throws -> PreparedAgentPublicationFile {
        let path = try Self.localPath(url)
        let filename = (path as NSString).lastPathComponent
        guard filename.utf8.count <= 255, !filename.contains("\\") else {
            throw LocalToolError.pathEscape
        }
        let bytes = try await reader.read(path: path, agentID: agentID, call: call, context: context,
            receiptPrefix: "publication-source", maximumBytes: Self.maximumBytes)
        return PreparedAgentPublicationFile(bytes: bytes, filename: filename)
    }

    static func localPath(_ value: String) throws -> String {
        guard value.utf8.count <= 16_384,
              let components = URLComponents(string: value), components.scheme == "file",
              components.host == nil || components.host == "",
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url, url.isFileURL else { throw LocalToolError.pathEscape }
        // Decode explicitly: Foundation's file URL path can discard embedded
        // NULs. Never authorize a normalized target different from the input.
        guard let path = components.percentEncodedPath.removingPercentEncoding else {
            throw LocalToolError.pathEscape
        }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4_096,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
              url.standardizedFileURL.path == path else { throw LocalToolError.pathEscape }
        return path
    }
}
