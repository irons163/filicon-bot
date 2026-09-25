import Foundation

/// A link reference, not authority to launch, query, or control a cloud agent.
public struct CursorAgentReference: Codable, Hashable, Sendable {
    public let bcID: String
    private static let summaryPrefix = "Referenced Cursor cloud agent "
    public static let maximumIDBytes = 8_000 - summaryPrefix.utf8.count
    public init(bcID: String) throws {
        let bcID = bcID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bcID.isEmpty, bcID != ".", bcID != "..", bcID.utf8.count <= Self.maximumIDBytes,
              !bcID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AgentPublicationError.invalid
        }
        self.bcID = bcID
    }
    public var url: URL {
        // Encode the opaque ID as exactly one path segment. Never interpret it
        // as a URL, already-encoded path, query, fragment, or authority.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let segment = bcID.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(string: "https://cursor.com/agents/\(segment)")!
    }
    public var summary: String { Self.summaryPrefix + bcID }
    private enum CodingKeys: String, CodingKey { case bcID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bcID: values.decode(String.self, forKey: .bcID))
    }
}
