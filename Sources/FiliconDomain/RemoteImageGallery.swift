import Foundation

/// Ordered image occurrences accompanying text. A URL may appear more than
/// once, with independent descriptions. This does not certify remote bytes.
public struct RemoteImageGallery: Codable, Hashable, Sendable {
    public let images: [RemoteAttachmentReference]
    public enum ValidationError: Error, Equatable, Sendable { case invalidCount, duplicateURL }
    public init(images: [RemoteAttachmentReference]) throws {
        guard !images.isEmpty else { throw ValidationError.invalidCount }
        self.images = images
    }
    private enum CodingKeys: String, CodingKey { case images }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(images: values.decode([RemoteAttachmentReference].self, forKey: .images))
    }
}
