import Foundation

/// Ordered image locators accompanying text. This does not certify remote bytes as images.
public struct RemoteImageGallery: Codable, Hashable, Sendable {
    public let images: [RemoteAttachmentReference]
    public enum ValidationError: Error, Equatable, Sendable { case invalidCount, duplicateURL }
    public init(images: [RemoteAttachmentReference]) throws {
        guard (1...4).contains(images.count) else { throw ValidationError.invalidCount }
        guard Set(images.map(\.url)).count == images.count else { throw ValidationError.duplicateURL }
        self.images = images
    }
    private enum CodingKeys: String, CodingKey { case images }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(images: values.decode([RemoteAttachmentReference].self, forKey: .images))
    }
}
