import Foundation

/// Durable display order for a message that can mix stored images and remote
/// image locators. Attachment IDs are content-addressed host metadata; remote
/// references remain unverified locators.
public struct ImageGalleryLayout: Codable, Hashable, Sendable {
    public enum Item: Codable, Hashable, Sendable {
        case attachment(String)
        case remote(RemoteAttachmentReference)
    }

    public let items: [Item]

    public init(items: [Item]) throws {
        guard (1...4).contains(items.count) else { throw ValidationError.invalidCount }
        var identities = Set<String>()
        for item in items {
            let identity: String
            switch item {
            case let .attachment(id):
                guard !id.isEmpty, id.utf8.count <= 128 else { throw ValidationError.invalidItem }
                identity = "attachment:\(id)"
            case let .remote(reference):
                identity = "remote:\(reference.url)"
            }
            guard identities.insert(identity).inserted else { throw ValidationError.duplicateItem }
        }
        self.items = items
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidCount, invalidItem, duplicateItem
    }

    public func matches(attachments: [AttachmentMetadata], remoteGallery: RemoteImageGallery?) -> Bool {
        let expected = items.compactMap { item -> String? in
            if case let .attachment(id) = item { return id }
            return nil
        }
        let actualRemote = items.compactMap { item -> RemoteAttachmentReference? in
            if case let .remote(reference) = item { return reference }
            return nil
        }
        let actual = remoteGallery?.images ?? []
        return expected == attachments.map(\.id) && actualRemote == actual
            && attachments.allSatisfy { $0.kind == .image }
            && Set(attachments.map(\.id)).count == attachments.count
    }

    private enum CodingKeys: String, CodingKey { case items }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do { try self.init(items: values.decode([Item].self, forKey: .items)) }
        catch {
            throw DecodingError.dataCorruptedError(forKey: .items, in: values,
                debugDescription: "Invalid image gallery layout")
        }
    }
}
