import CoreGraphics
import CryptoKit
import Foundation
import FiliconDomain

public enum RemoteAttachmentPDFError: Error, Equatable, Sendable {
    case invalidDocument
    case locked
    case boundsExceeded
}

/// Verified format and bounded document structure, not a malware scan.
public enum RemoteAttachmentPreviewPreparation {
    public static let maximumBytes = RemoteAttachmentImagePreparation.maximumBytes

    public static func metadata(for data: Data, reference: RemoteAttachmentReference,
                                createdAt: Date = Date()) throws -> AttachmentMetadata {
        try Task.checkCancellation()
        guard data.starts(with: Data("%PDF-".utf8)) else {
            return try RemoteAttachmentImagePreparation.metadata(for: data, reference: reference, createdAt: createdAt)
        }
        guard data.count <= maximumBytes else { throw RemoteAttachmentPDFError.boundsExceeded }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else {
            throw RemoteAttachmentPDFError.invalidDocument
        }
        guard document.isUnlocked else { throw RemoteAttachmentPDFError.locked }
        guard document.numberOfPages > 0, document.numberOfPages <= 1_000 else {
            throw RemoteAttachmentPDFError.boundsExceeded
        }
        for index in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw RemoteAttachmentPDFError.invalidDocument }
            let bounds = page.getBoxRect(.mediaBox)
            guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
                  bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0,
                  bounds.width <= 14_400, bounds.height <= 14_400 else {
                throw RemoteAttachmentPDFError.boundsExceeded
            }
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return AttachmentMetadata(id: digest, filename: "remote-document.pdf", mimeType: "application/pdf",
            byteCount: Int64(data.count), kind: .document, createdAt: createdAt, altText: reference.alt)
    }
}
