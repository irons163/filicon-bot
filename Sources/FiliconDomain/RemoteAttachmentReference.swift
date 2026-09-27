import Foundation

/// A shared remote locator, not downloaded bytes or proof of delivery from its server.
/// Constructing/decoding this value never performs I/O. Opening or fetching it
/// requires a separate host capability and network policy.
public struct RemoteAttachmentReference: Codable, Hashable, Sendable {
    public let url: String
    public let alt: String?

    public enum ValidationError: Error, Equatable, Sendable { case invalidURL, invalidAlt }

    public init(url: String, alt: String? = nil) throws {
        guard !url.isEmpty, url.utf8.count <= 16_384,
              !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !url.contains("\\"),
              let decoded = url.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: url), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil,
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let parsed = components.url, parsed.absoluteString == url else {
            throw ValidationError.invalidURL
        }
        if let alt {
            guard !alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  alt.utf8.count <= 4_096,
                  !alt.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ValidationError.invalidAlt
            }
        }
        self.url = url
        self.alt = alt
    }

    private enum CodingKeys: String, CodingKey { case url, alt }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(url: container.decode(String.self, forKey: .url),
                      alt: container.decodeIfPresent(String.self, forKey: .alt))
    }
}
