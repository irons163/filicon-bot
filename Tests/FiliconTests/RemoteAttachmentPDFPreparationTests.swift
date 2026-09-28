import CoreGraphics
import Foundation
import PDFKit
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices

@Suite("Remote PDF preview preparation")
struct RemoteAttachmentPDFPreparationTests {
    @Test(arguments: ["valid", "oversized", "locked"])
    func parsesActualPDFAndRejectsUnsafeDocuments(mode: String) throws {
        let bytes = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: mode == "oversized" ? 14_401 : 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        context.endPDFPage()
        context.closePDF()
        var data = bytes as Data
        if mode == "locked" {
            let document = try #require(PDFDocument(data: data))
            data = try #require(document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "fixture-user", PDFDocumentWriteOption.ownerPasswordOption: "fixture-owner"]))
            let locked = try #require(PDFDocument(data: data))
            #expect(locked.isLocked)
        }
        let reference = try RemoteAttachmentReference(url: "https://example.com/misleading.jpg", alt: "PDF report")
        if mode != "valid" {
            let expected: RemoteAttachmentPDFError = mode == "locked" ? .locked : .boundsExceeded
            #expect(throws: expected) {
                try RemoteAttachmentPreviewPreparation.metadata(for: data, reference: reference)
            }
        } else {
            let metadata = try RemoteAttachmentPreviewPreparation.metadata(for: data, reference: reference)
            expectNoDifference(metadata.mimeType, "application/pdf")
            expectNoDifference(metadata.filename, "remote-document.pdf")
            expectNoDifference(metadata.kind, .document)
            expectNoDifference(metadata.altText, reference.alt)
            expectNoDifference(metadata.byteCount, Int64(bytes.length))
        }
    }

    @Test func forgedPDFIsNotAValidPreview() throws {
        let reference = try RemoteAttachmentReference(url: "https://example.com/report.pdf")
        #expect(throws: RemoteAttachmentPDFError.invalidDocument) {
            try RemoteAttachmentPreviewPreparation.metadata(for: Data("%PDF-1.7\nnot a document".utf8), reference: reference)
        }
    }
}
