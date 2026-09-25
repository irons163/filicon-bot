import Foundation

/// A link reference, not authority to launch, query, or control a cloud agent.
public struct CursorAgentReference: Codable, Hashable, Sendable {
    public let bcID: String
    public init(bcID: String) throws {
        guard bcID.hasPrefix("bc-"), (4...200).contains(bcID.utf8.count),
              bcID.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw AgentPublicationError.invalid
        }
        self.bcID = bcID
    }
    public var url: URL { URL(string: "https://cursor.com/agents/\(bcID)")! }
    public var summary: String { "Referenced Cursor cloud agent \(bcID)" }
    private enum CodingKeys: String, CodingKey { case bcID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(bcID: values.decode(String.self, forKey: .bcID))
    }
}
