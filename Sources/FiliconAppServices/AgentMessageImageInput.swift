import Foundation
import FiliconDomain

/// A parsed source locator, never proof of file access or verified image bytes.
public struct AgentMessageImageInput: Equatable, Sendable {
    public enum Source: Equatable, Hashable, Sendable {
        case hostImage(String)
        case localFile(String)
        case remote(RemoteAttachmentReference)
    }
    public let source: Source
    public let alt: String?

    public init(entry: Any) throws {
        let identifier: String?
        let locator: String?
        let rawAlt: Any?
        if let value = entry as? String {
            identifier = value; locator = nil; rawAlt = nil
        } else if let value = entry as? [String: Any],
                  Set(value.keys).isSubset(of: ["image_id", "url", "alt"]),
                  (value["image_id"] != nil) != (value["url"] != nil) {
            identifier = value["image_id"] as? String
            locator = value["url"] as? String
            rawAlt = value["alt"]
            guard identifier != nil || locator != nil else { throw AgentImageError.invalid }
        } else { throw AgentImageError.invalid }
        if let rawAlt {
            guard let value = rawAlt as? String, value.count <= 500, value.utf8.count <= 2_000,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw AgentImageError.invalid
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            alt = trimmed.isEmpty ? nil : trimmed
        } else { alt = nil }
        if let identifier {
            source = .hostImage(identifier)
        } else if let locator {
            guard locator.utf8.count <= 16_384 else { throw AgentImageError.invalid }
            if locator.hasPrefix("file:") {
                guard let components = URLComponents(string: locator), components.scheme == "file",
                      components.host == nil || components.host == "",
                      components.user == nil, components.password == nil, components.port == nil,
                      components.query == nil, components.fragment == nil,
                      let path = components.percentEncodedPath.removingPercentEncoding,
                      path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 4_096,
                      !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      path.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." }),
                      let url = components.url, url.isFileURL, url.standardizedFileURL.path == path else {
                    throw AgentImageError.invalid
                }
                source = .localFile(locator)
            } else {
                source = .remote(try RemoteAttachmentReference(url: locator, alt: alt))
            }
        } else { throw AgentImageError.invalid }
    }
}
