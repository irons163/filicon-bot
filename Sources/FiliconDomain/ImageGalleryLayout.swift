import Foundation

/// Durable display order for a message that can mix stored images and remote
/// image locators. Attachment IDs are content-addressed host metadata; remote
/// references remain unverified locators. Position, not source, identifies an
/// occurrence: one blob or URL may have multiple message-local descriptions.
public struct ImageGalleryLayout: Codable, Hashable, Sendable {
    public enum Item: Codable, Hashable, Sendable {
        case attachment(String)
        case remote(RemoteAttachmentReference)
    }

    public enum ResolvedItem: Hashable, Sendable {
        /// Index in the canonical local metadata array, not in the mixed grid.
        case attachment(AttachmentMetadata, index: Int)
        case remote(RemoteAttachmentReference)
    }

    public let items: [Item]

    public init(items: [Item]) throws {
        guard !items.isEmpty else { throw ValidationError.invalidCount }
        for item in items {
            switch item {
            case let .attachment(id):
                guard !id.isEmpty, id.utf8.count <= 128 else { throw ValidationError.invalidItem }
            case .remote:
                break
            }
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
        guard expected == attachments.map(\.id), actualRemote == actual else { return false }
        var sources: [String: AttachmentMetadata] = [:]
        for attachment in attachments {
            guard attachment.kind == .image else { return false }
            if let previous = sources[attachment.id],
               previous.byteCount != attachment.byteCount || previous.mimeType != attachment.mimeType {
                return false
            }
            sources[attachment.id] = attachment
        }
        return true
    }

    /// Resolves each occurrence against the exact ordered saved arrays. Looking
    /// up the first matching digest would silently reuse the first caption.
    public func resolvedItems(attachments: [AttachmentMetadata], remoteGallery: RemoteImageGallery?) -> [ResolvedItem]? {
        guard matches(attachments: attachments, remoteGallery: remoteGallery) else { return nil }
        var attachmentIndex = 0
        return items.map { item in
            switch item {
            case .attachment:
                let index = attachmentIndex
                attachmentIndex += 1
                return .attachment(attachments[index], index: index)
            case let .remote(reference):
                return .remote(reference)
            }
        }
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
