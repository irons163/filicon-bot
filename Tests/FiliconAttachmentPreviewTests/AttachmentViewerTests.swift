import CryptoKit
import AppKit
import CustomDump
import Darwin
import Foundation
import Testing
import FiliconDomain
@testable import Filicon

@Suite("Native attachment viewers")
struct AttachmentViewerTests {
    @Test @MainActor func mainImageDecodesVerifiedSnapshotAfterPathReplacement() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: "image-snapshot-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let path = sandbox.appending(path: "image.png")
        try bytes.write(to: path)
        let metadata = AttachmentMetadata(id: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            filename: "image.png", mimeType: "image/png", byteCount: Int64(bytes.count), kind: .image,
            createdAt: Date(timeIntervalSince1970: 1))
        let file = AttachmentPreviewFile(filename: metadata.filename, fileURL: path, metadata: metadata)
        let verified = try AttachmentFileIntegrity().verifiedData(for: file)
        try Data("replaced".utf8).write(to: path, options: .atomic)
        #expect(throws: AttachmentFileIntegrityError.changed) { try AttachmentFileIntegrity().verifiedData(for: file) }
        let view = AttachmentImageView(verifiedData: verified)
        let image = try #require(view.image)
        expectNoDifference(image.size, CGSize(width: 2, height: 3))
        try FileManager.default.removeItem(at: path)
        #expect(AttachmentImageView(verifiedData: verified).image != nil)
        #expect(AttachmentImageView(verifiedData: nil).image == nil)
        #expect(AttachmentImageView(verifiedData: Data("invalid image".utf8)).image == nil)
    }

    @Test @MainActor func previewWindowPreservesIdentityAndClosesWithParent() async throws {
        let coordinator = AttachmentPreviewWindowCoordinator()
        let first = AttachmentPreviewItem(filename: "first.png", fileURL: URL(fileURLWithPath: "/nonexistent/first.png"))
        let second = AttachmentPreviewItem(filename: "second.png", fileURL: URL(fileURLWithPath: "/nonexistent/second.png"))
        var closed: [UUID] = []
        let parent = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { coordinator.observeParent(nil); coordinator.dismiss(); parent.close() }
        coordinator.observeParent(parent)
        coordinator.update(item: first, locale: Locale(identifier: "en"), dark: false, show: false) { closed.append($0) }
        let firstWindow = try #require(coordinator.window)
        #expect(firstWindow.styleMask.contains(.resizable))
        #expect(firstWindow.collectionBehavior.contains(.fullScreenPrimary))
        #expect(!firstWindow.isVisible)
        coordinator.update(item: first, locale: Locale(identifier: "fr"), dark: true, show: false) { closed.append($0) }
        #expect(coordinator.window === firstWindow)
        coordinator.update(item: second, locale: Locale(identifier: "en"), dark: false, show: false) { closed.append($0) }
        #expect(firstWindow.contentView == nil)
        #expect(closed.isEmpty)
        coordinator.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))
        expectNoDifference(coordinator.itemID, second.id)
        parent.close()
        #expect(coordinator.window == nil)
        for _ in 0..<20 where closed.isEmpty { await Task.yield() }
        expectNoDifference(closed, [second.id])
        coordinator.closeAndNotify()
        await Task.yield()
        expectNoDifference(closed, [second.id])
    }

    @Test func thumbnailVerifiesBytesAndRejectsReplacedFiles() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: "thumbnail-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let path = sandbox.appending(path: "image.png")
        let bytes = Data("original".utf8)
        let metadata = AttachmentMetadata(id: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            filename: "image.png", mimeType: "image/png", byteCount: Int64(bytes.count), kind: .image)
        let file = AttachmentPreviewFile(filename: "image.png", fileURL: path, metadata: metadata)
        try bytes.write(to: path)
        expectNoDifference(try AttachmentThumbnail.verifiedImageData(for: file), bytes)
        try Data("tampered".utf8).write(to: path)
        #expect(throws: AttachmentFileIntegrityError.changed) { try AttachmentThumbnail.verifiedImageData(for: file) }
        try FileManager.default.removeItem(at: path)
        let target = sandbox.appending(path: "target.png")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: target)
        #expect(throws: AttachmentFileIntegrityError.unsafeFile) { try AttachmentThumbnail.verifiedImageData(for: file) }
        try FileManager.default.removeItem(at: path)
        #expect(mkfifo(path.path, 0o600) == 0)
        #expect(throws: AttachmentFileIntegrityError.unsafeFile) { try AttachmentThumbnail.verifiedImageData(for: file) }
        expectNoDifference(try Data(contentsOf: target), bytes)
        let nonimage = AttachmentPreviewFile(filename: "missing.txt", fileURL: sandbox.appending(path: "missing"))
        #expect(try AttachmentThumbnail.verifiedImageData(for: nonimage) == nil)
    }

    @Test func imageZoomAccumulatesAndBoundsRepeatedGestures() {
        var zoom = AttachmentImageZoom()
        expectDifference(zoom) { zoom.finishGesture(2) } changes: { $0.scale = 2 }
        expectDifference(zoom) { zoom.finishGesture(1.5) } changes: { $0.scale = 3 }
        expectNoDifference(zoom.effectiveScale(gesture: 2), 6)
        expectDifference(zoom) { zoom.finishGesture(10) } changes: { $0.scale = 8 }
        expectDifference(zoom) { zoom.finishGesture(0.001) } changes: { $0.scale = 0.1 }
        expectNoDifference(zoom.effectiveScale(gesture: .nan), 0.1)
    }

    @Test func zoomedImageExpandsScrollableLayoutWithAspectRatio() {
        let viewport = CGSize(width: 648, height: 448)
        let image = CGSize(width: 1200, height: 800)
        expectNoDifference(AttachmentImageZoom().displaySize(image: image, viewport: viewport),
                           CGSize(width: 600, height: 400))
        expectNoDifference(AttachmentImageZoom(scale: 2).displaySize(image: image, viewport: viewport), image)
        expectNoDifference(AttachmentImageZoom().displaySize(image: CGSize(width: 400, height: 800), viewport: viewport),
                           CGSize(width: 200, height: 400))
        expectNoDifference(AttachmentImageZoom().displaySize(image: .zero, viewport: viewport), .zero)
    }

    @Test func classifiesNativeAndFallbackFormats() {
        #expect(AttachmentViewerKind.classify(filename: "photo.HEIC", mimeType: nil) == .image)
        #expect(AttachmentViewerKind.classify(filename: "clip.bin", mimeType: "video/mp4") == .audiovisual)
        #expect(AttachmentViewerKind.classify(filename: "report.pdf", mimeType: nil) == .pdf)
        #expect(AttachmentViewerKind.classify(filename: "table.xlsx", mimeType: nil) == .spreadsheet)
        #expect(AttachmentViewerKind.classify(filename: "model.usdz", mimeType: nil) == .quickLook)
    }

    @Test func parsesQuotedCSVWithoutTreatingContentAsCode() throws {
        let csv = "name,note\r\nAlice,\"line one\r\nline two\"\r\nBob,\"a \"\"quote\"\"\""
        let preview = try DelimitedTextPreviewParser().parse(data: Data(csv.utf8), delimiter: ",")

        #expect(preview.sheets[0].rows == [
            ["name", "note"],
            ["Alice", "line one\nline two"],
            ["Bob", "a \"quote\""]
        ])
    }

    @Test func parsesTSVAndEnforcesDelimitedRowLimit() throws {
        let preview = try DelimitedTextPreviewParser().parse(
            data: Data("name\tnote\nAda\tcompiler".utf8), delimiter: "\t", name: "Data"
        )
        #expect(preview.sheets[0].name == "Data")
        #expect(preview.sheets[0].rows == [["name", "note"], ["Ada", "compiler"]])

        let rows = Array(repeating: "x", count: SpreadsheetPreviewLimits.rows + 1).joined(separator: "\n")
        #expect(throws: SpreadsheetPreviewError.rowLimit) {
            _ = try DelimitedTextPreviewParser().parse(data: Data(rows.utf8), delimiter: ",")
        }
    }

    @Test func enforcesDelimitedColumnAndTextLimits() {
        let tooManyColumns = Array(repeating: "x", count: SpreadsheetPreviewLimits.columns + 1).joined(separator: ",")
        #expect(throws: SpreadsheetPreviewError.columnLimit) {
            _ = try DelimitedTextPreviewParser().parse(data: Data(tooManyColumns.utf8), delimiter: ",")
        }
        let oversizedCell = String(repeating: "x", count: SpreadsheetPreviewLimits.cellCharacters + 1)
        #expect(throws: SpreadsheetPreviewError.textLimit) {
            _ = try DelimitedTextPreviewParser().parse(data: Data(oversizedCell.utf8), delimiter: ",")
        }
    }

    @Test func rejectsTraversalAbsoluteBackslashAndExpansionBombEntries() {
        let policy = XLSXArchivePolicy()
        for unsafe in ["../escape.xml", "/absolute.xml", "C:/absolute.xml", "xl\\evil.xml", "xl/../evil.xml", "xl//evil.xml", "xl//"] {
            #expect(!policy.isSafeRelativePath(unsafe))
            #expect(throws: SpreadsheetPreviewError.unsafeArchiveEntry(unsafe)) {
                try policy.validate(
                    entries: [.init(path: unsafe, uncompressedBytes: 1, isDirectory: false)],
                    archiveBytes: 100
                )
            }
        }
        #expect(throws: SpreadsheetPreviewError.archiveExpansionLimit) {
            try policy.validate(
                entries: [.init(path: "xl/worksheets/sheet1.xml", uncompressedBytes: SpreadsheetPreviewLimits.expandedBytes + 1, isDirectory: false)],
                archiveBytes: 1_024
            )
        }
    }

    @Test func parsesSharedRichInlineCachedFormulaAndRelationshipOrderedSheets() throws {
        let fixture = try XLSXFixture.make(files: [
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>
              <sheet name="Summary" sheetId="1" r:id="rIdSummary"/>
              <sheet name="Inline" sheetId="2" r:id="rIdInline"/>
            </sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
              <Relationship Id="rIdInline" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
              <Relationship Id="rIdSummary" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
            </Relationships>
            """,
            "xl/sharedStrings.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><r><t>Hello </t></r><r><t>world</t></r></si></sst>
            """,
            "xl/worksheets/sheet1.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1">
              <c r="A1" t="inlineStr"><is><r><t>inline </t></r><r><t>text</t></r></is></c><c r="B1" t="b"><v>1</v></c>
            </row></sheetData></worksheet>
            """,
            "xl/worksheets/sheet2.xml": """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1">
              <c r="A1" t="s"><v>0</v></c><c r="B1"><f>40+2</f><v>42</v></c>
            </row></sheetData></worksheet>
            """,
        ])
        defer { fixture.remove() }

        let preview = try XLSXPreviewParser().parse(fileURL: fixture.archive)
        #expect(preview.sheets.map(\.name) == ["Summary", "Inline"])
        #expect(preview.sheets[0].rows == [["Hello world", "42"]])
        #expect(preview.sheets[1].rows == [["inline text", "TRUE"]])
    }

    @Test func rejectsUnsafeWorkbookRelationshipInsteadOfFallingBackToDiscoveredSheet() throws {
        let fixture = try XLSXFixture.make(files: [
            "xl/workbook.xml": """
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Bad" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Target="../worksheets/sheet1.xml"/></Relationships>
            """,
            "xl/worksheets/sheet1.xml": "<worksheet><sheetData/></worksheet>",
        ])
        defer { fixture.remove() }
        #expect(throws: SpreadsheetPreviewError.unsafeArchiveEntry("../worksheets/sheet1.xml")) {
            _ = try XLSXPreviewParser().parse(fileURL: fixture.archive)
        }
    }

    @Test func rejectsSymlinkInActualXLSXArchive() throws {
        let fixture = try XLSXFixture.makeSymlinkArchive()
        defer { fixture.remove() }
        do {
            _ = try XLSXPreviewParser().parse(fileURL: fixture.archive)
            Issue.record("Expected symlink archive to be rejected")
        } catch SpreadsheetPreviewError.unsafeArchiveEntry {
            // Expected: preflight rejects the link before extraction.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rejectsAbsoluteBackslashAndTraversalNamesFromActualZIPCentralDirectory() throws {
        for unsafe in ["/absolute.xml", "xl\\backslash.xml", "../traversal.xml"] {
            let fixture = try XLSXFixture.makeRawArchive(entries: [(unsafe, Data("x".utf8))])
            defer { fixture.remove() }
            #expect(throws: SpreadsheetPreviewError.unsafeArchiveEntry(unsafe)) {
                _ = try XLSXPreviewParser().parse(fileURL: fixture.archive)
            }
        }
    }

    @Test func rejectsDeclaredExpansionBombFromActualZIPCentralDirectory() throws {
        let fixture = try XLSXFixture.makeRawArchive(
            entries: [("xl/worksheets/sheet1.xml", Data("x".utf8))],
            declaredUncompressedBytes: UInt32(SpreadsheetPreviewLimits.expandedBytes + 1)
        )
        defer { fixture.remove() }
        #expect(throws: SpreadsheetPreviewError.archiveExpansionLimit) {
            _ = try XLSXPreviewParser().parse(fileURL: fixture.archive)
        }
    }

    @Test func enforcesXLSXRowColumnAndTextLimits() throws {
        let excessiveRows = (1...(SpreadsheetPreviewLimits.rows + 1)).map {
            "<row r=\"\($0)\"><c r=\"A\($0)\"><v>\($0)</v></c></row>"
        }.joined()
        let rowFixture = try XLSXFixture.singleSheet(xml: "<worksheet><sheetData>\(excessiveRows)</sheetData></worksheet>", uncompressed: true)
        defer { rowFixture.remove() }
        #expect(throws: SpreadsheetPreviewError.rowLimit) {
            _ = try XLSXPreviewParser().parse(fileURL: rowFixture.archive)
        }

        let columnFixture = try XLSXFixture.singleSheet(
            xml: "<worksheet><sheetData><row><c r=\"GS1\"><v>x</v></c></row></sheetData></worksheet>",
            uncompressed: true
        )
        defer { columnFixture.remove() }
        #expect(throws: SpreadsheetPreviewError.columnLimit) {
            _ = try XLSXPreviewParser().parse(fileURL: columnFixture.archive)
        }

        let oversized = String(repeating: "0123456789abcdef", count: SpreadsheetPreviewLimits.cellCharacters / 16 + 1)
        let textFixture = try XLSXFixture.singleSheet(
            xml: "<worksheet><sheetData><row><c t=\"inlineStr\"><is><t>\(oversized)</t></is></c></row></sheetData></worksheet>",
            uncompressed: true
        )
        defer { textFixture.remove() }
        #expect(throws: SpreadsheetPreviewError.textLimit) {
            _ = try XLSXPreviewParser().parse(fileURL: textFixture.archive)
        }
    }

    @Test func processRunnerUsesLiteralArgvTimesOutAndCleansTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FiliconRunnerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = root.appending(path: "must-not-exist")
        let literal = "$(touch \(marker.path)); --not-an-option"
        let output = try ProcessRunner.run(
            executable: "/bin/echo", arguments: [literal], timeout: 2, temporaryRoot: root
        )
        #expect(String(decoding: output, as: UTF8.self) == literal + "\n")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let start = ContinuousClock.now
        #expect(throws: SpreadsheetPreviewError.processFailed) {
            _ = try ProcessRunner.run(
                executable: "/bin/sleep", arguments: ["5"], timeout: 0.05, temporaryRoot: root
            )
        }
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func parsesXLSXValuesAndNeverEvaluatesFormula() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else { return }
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let source = sandbox.appending(path: "source", directoryHint: .isDirectory)
        let worksheetDirectory = source.appending(path: "xl/worksheets", directoryHint: .isDirectory)
        let relationshipsDirectory = source.appending(path: "xl/_rels", directoryHint: .isDirectory)
        let archive = sandbox.appending(path: "fixture.xlsx")
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: worksheetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relationshipsDirectory, withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>
        """.utf8).write(to: source.appending(path: "xl/workbook.xml"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """.utf8).write(to: relationshipsDirectory.appending(path: "workbook.xml.rels"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Name</t></si><si><t>Alice</t></si></sst>
        """.utf8).write(to: source.appending(path: "xl/sharedStrings.xml"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
          <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1"><v>7</v></c></row>
          <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><f>2+2</f><v>4</v></c></row>
        </sheetData></worksheet>
        """.utf8).write(to: worksheetDirectory.appending(path: "sheet1.xml"))

        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", archive.path, "."]
        zip.currentDirectoryURL = source
        try zip.run()
        zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)

        let preview = try XLSXPreviewParser().parse(fileURL: archive)
        #expect(preview.sheets.map(\.name) == ["Data"])
        #expect(preview.sheets[0].rows == [["Name", "7"], ["Alice", "4"]])
    }

    @Test func detectsMutationBeforeExportOrExternalOpen() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let fileURL = sandbox.appending(path: "note.txt")
        let original = Data("original".utf8)
        try original.write(to: fileURL)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let metadata = AttachmentMetadata(
            id: digest,
            filename: "note.txt",
            mimeType: "text/plain",
            byteCount: Int64(original.count),
            kind: .document
        )
        let file = AttachmentPreviewFile(filename: "note.txt", fileURL: fileURL, metadata: metadata)
        #expect(try AttachmentFileIntegrity().verifiedData(for: file) == original)

        try Data("tampered".utf8).write(to: fileURL)
        #expect(throws: AttachmentFileIntegrityError.changed) {
            _ = try AttachmentFileIntegrity().verifiedData(for: file)
        }
    }

    @Test func materializerRejectsBytesThatDoNotMatchCASMetadata() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let expected = Data("expected".utf8)
        let metadata = AttachmentMetadata(
            id: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(),
            filename: "note.txt", mimeType: "text/plain", byteCount: Int64(expected.count), kind: .document
        )
        #expect(throws: AttachmentPreviewError.integrityMismatch) {
            _ = try AttachmentPreviewMaterializer(rootURL: sandbox).materialize(
                data: Data("different".utf8), metadata: metadata
            )
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.path))
    }

    @Test func cleansEveryGalleryMaterializationButNotOutsideFiles() throws {
        let sandbox = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let materializer = AttachmentPreviewMaterializer(rootURL: sandbox)
        func metadata(_ suffix: String) -> AttachmentMetadata {
            let data = Data(suffix.utf8)
            return AttachmentMetadata(
                id: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                filename: "\(suffix).txt", mimeType: "text/plain", byteCount: Int64(data.count), kind: .document
            )
        }
        let one = try materializer.materialize(data: Data("one".utf8), metadata: metadata("one"))
        let two = try materializer.materialize(data: Data("two".utf8), metadata: metadata("two"))
        let gallery = AttachmentPreviewItem(files: [one.files[0], two.files[0]], initialFileID: two.files[0].id)
        materializer.remove(gallery)

        #expect(!FileManager.default.fileExists(atPath: one.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: two.fileURL.path))
    }
}

private struct XLSXFixture {
    let root: URL
    let archive: URL

    static func make(files: [String: String], uncompressed: Bool = false) throws -> Self {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/zip") else {
            throw SpreadsheetPreviewError.archiveToolUnavailable
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "XLSXFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let archive = root.appending(path: "fixture.xlsx")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, contents) in files {
            let url = source.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        try zip(source: source, archive: archive, uncompressed: uncompressed, preserveSymlinks: false)
        return Self(root: root, archive: archive)
    }

    static func singleSheet(xml: String, uncompressed: Bool) throws -> Self {
        try make(files: ["xl/worksheets/sheet1.xml": xml], uncompressed: uncompressed)
    }

    static func makeSymlinkArchive() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "XLSXFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let sheetDirectory = source.appending(path: "xl/worksheets", directoryHint: .isDirectory)
        let archive = root.appending(path: "fixture.xlsx")
        try FileManager.default.createDirectory(at: sheetDirectory, withIntermediateDirectories: true)
        let target = root.appending(path: "outside.xml")
        try Data("<worksheet/>".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: sheetDirectory.appending(path: "sheet1.xml"), withDestinationURL: target
        )
        try zip(source: source, archive: archive, uncompressed: false, preserveSymlinks: true)
        return Self(root: root, archive: archive)
    }

    /// Builds a minimal stored ZIP without path normalization. This lets the
    /// tests exercise central-directory names that `/usr/bin/zip` helpfully
    /// rewrites (notably absolute and `..` paths).
    static func makeRawArchive(
        entries: [(String, Data)],
        declaredUncompressedBytes: UInt32? = nil
    ) throws -> Self {
        let root = FileManager.default.temporaryDirectory.appending(path: "XLSXFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        let archive = root.appending(path: "fixture.xlsx")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var body = Data()
        var central = Data()
        for (name, contents) in entries {
            let nameData = Data(name.utf8)
            let offset = UInt32(body.count)
            let crc = crc32(contents)
            let uncompressedBytes = declaredUncompressedBytes ?? UInt32(contents.count)
            body.appendLE(UInt32(0x04034b50))
            body.appendLE(UInt16(20)); body.appendLE(UInt16(0)); body.appendLE(UInt16(0))
            body.appendLE(UInt16(0)); body.appendLE(UInt16(0)); body.appendLE(crc)
            body.appendLE(UInt32(contents.count)); body.appendLE(uncompressedBytes)
            body.appendLE(UInt16(nameData.count)); body.appendLE(UInt16(0))
            body.append(nameData); body.append(contents)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(crc)
            central.appendLE(UInt32(contents.count)); central.appendLE(uncompressedBytes)
            central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt32(0o100644) << 16); central.appendLE(offset)
            central.append(nameData)
        }
        let centralOffset = UInt32(body.count)
        body.append(central)
        body.appendLE(UInt32(0x06054b50))
        body.appendLE(UInt16(0)); body.appendLE(UInt16(0))
        body.appendLE(UInt16(entries.count)); body.appendLE(UInt16(entries.count))
        body.appendLE(UInt32(central.count)); body.appendLE(centralOffset); body.appendLE(UInt16(0))
        try body.write(to: archive)
        return Self(root: root, archive: archive)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private static func zip(source: URL, archive: URL, uncompressed: Bool, preserveSymlinks: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", uncompressed ? "-0" : "-6"] + (preserveSymlinks ? ["-y"] : []) + ["-r", archive.path, "."]
        process.currentDirectoryURL = source
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SpreadsheetPreviewError.processFailed }
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB88320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
