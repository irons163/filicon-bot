import Foundation
import CoreGraphics
import ImageIO
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices

@Suite("Remote image preview preparation")
struct RemoteAttachmentImagePreparationTests {
    @Test(arguments: ["public.png", "public.jpeg", "com.compuserve.gif"])
    func actualBytesDetermineFormat(type: String) throws {
        let data = try image(type: type, frames: type == "com.compuserve.gif" ? 2 : 1)
        let reference = try RemoteAttachmentReference(url: "https://example.com/malicious.html", alt: "**Not markdown**")
        let metadata = try RemoteAttachmentImagePreparation.metadata(for: data, reference: reference, createdAt: Date(timeIntervalSince1970: 0))
        expectNoDifference(metadata.kind, .image)
        expectNoDifference(metadata.byteCount, Int64(data.count))
        expectNoDifference(metadata.altText, reference.alt)
        expectNoDifference(metadata.mimeType, type == "public.png" ? "image/png" : type == "public.jpeg" ? "image/jpeg" : "image/gif")
        #expect(!metadata.filename.contains("html"))
        let second = try RemoteAttachmentImagePreparation.metadata(for: data,
            reference: RemoteAttachmentReference(url: "https://other.example/different"), createdAt: Date(timeIntervalSince1970: 0))
        expectNoDifference(second.id, metadata.id)
        if type == "com.compuserve.gif" {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            expectNoDifference(CGImageSourceGetCount(source), 2)
        }
    }

    @Test func rejectsNonImagesEmptyAndExcessiveFrames() throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/trusted.png")
        for data in [Data("<html>not an image</html>".utf8), Data("<svg/>".utf8), Data()] {
            #expect(throws: (any Error).self) {
                try RemoteAttachmentImagePreparation.metadata(for: data, reference: reference)
            }
        }
        let excessive = try image(type: "com.compuserve.gif", frames: 201)
        #expect(throws: RemoteAttachmentImageError.decodeLimit) {
            try RemoteAttachmentImagePreparation.metadata(for: excessive, reference: reference)
        }
        let wide = try image(type: "public.png", frames: 1, width: 16_385)
        #expect(throws: RemoteAttachmentImageError.decodeLimit) {
            try RemoteAttachmentImagePreparation.metadata(for: wide, reference: reference)
        }
        let truncated = try image(type: "public.png", frames: 1).prefix(16)
        #expect(throws: (any Error).self) {
            try RemoteAttachmentImagePreparation.metadata(for: Data(truncated), reference: reference)
        }
    }

    private func image(type: String, frames: Int, width: Int = 2) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: 2, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, frames, nil))
        for index in 0..<frames {
            context.setFillColor(CGColor(red: index.isMultiple(of: 2) ? 1 : 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: 2))
            let frame = try #require(context.makeImage())
            CGImageDestinationAddImage(destination, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return bytes as Data
    }
}
