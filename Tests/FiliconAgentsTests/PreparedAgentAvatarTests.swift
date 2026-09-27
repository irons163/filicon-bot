import AppKit
import CustomDump
import FiliconAgents
import Foundation
import ImageIO
import Testing

@Suite("Immutable avatar preparation")
struct PreparedAgentAvatarTests {
    private func frame(red: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return try #require(context.makeImage())
    }

    @Test(arguments: ["public.png", "public.jpeg", "com.compuserve.gif"])
    func rasterFormatsBecomeSingleFramePNGs(type: String) throws {
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try frame(red: 1, blue: 0), nil)
        #expect(CGImageDestinationFinalize(destination))
        let prepared = try AgentAvatarStore(rootURL: URL(fileURLWithPath: "/unused-avatar-format-store"))
            .prepareImage(data: bytes as Data)
        let result = try #require(CGImageSourceCreateWithData(prepared.pngData as CFData, nil))
        expectNoDifference(CGImageSourceGetType(result) as String?, "public.png")
        expectNoDifference(CGImageSourceGetCount(result), 1)
        let image = try #require(CGImageSourceCreateImageAtIndex(result, 0, nil))
        expectNoDifference(image.width, 256)
        expectNoDifference(image.height, 256)
        expectNoDifference(prepared.sourceByteCount, bytes.length)
    }

    @Test func animatedGIFFreezesTheFirstFrame() throws {
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try frame(red: 1, blue: 0), nil)
        CGImageDestinationAddImage(destination, try frame(red: 0, blue: 1), nil)
        #expect(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(bytes, nil))
        expectNoDifference(CGImageSourceGetCount(source), 2)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let firstPNG = try #require(NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:]))
        let store = AgentAvatarStore(rootURL: URL(fileURLWithPath: "/unused-avatar-format-store"))
        expectNoDifference(try store.prepareImage(data: bytes as Data).pngData,
                           try store.prepareImage(data: firstPNG).pngData)
    }

    private func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<8 { for y in 0..<8 { rep.setColor(.red, atX: x, y: y) } }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func preparationHasNoWritesAndInstallsExactPreviewAfterSourceChanges() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-avatar-prepared-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAvatarStore(rootURL: root.appending(path: "cas"))
        var source = try png()
        let prepared = try store.prepareImage(data: source, shape: .hexagon)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        source = Data("source was replaced after preview".utf8)
        let installed = try store.install(prepared)
        expectNoDifference(installed, prepared.avatar)
        let file = try #require(store.imageURL(for: installed))
        expectNoDifference(try Data(contentsOf: file), prepared.pngData)
        let bitmap = try #require(NSBitmapImageRep(data: prepared.pngData))
        expectNoDifference(bitmap.pixelsWide, 256)
        expectNoDifference(bitmap.pixelsHigh, 256)
        expectNoDifference(try store.install(prepared), installed)
        let reopened = AgentAvatarStore(rootURL: store.rootURL)
        expectNoDifference(reopened.imageURL(for: installed), file)
        // A blob under the right digest filename is not proof of its contents.
        try source.write(to: file)
        expectNoDifference(reopened.imageURL(for: installed), nil)
        #expect(throws: AgentAvatarStoreError.invalidImage) { try reopened.install(prepared) }
        expectNoDifference(try Data(contentsOf: file), source)
    }

    @Test func rejectsEmptyOversizedInvalidAndSymlinkSources() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-avatar-input-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentAvatarStore(rootURL: root.appending(path: "cas"))
        for bytes in [Data(), Data("not an image".utf8)] {
            #expect(throws: AgentAvatarStoreError.invalidImage) { try store.prepareImage(data: bytes) }
        }
        #expect(throws: AgentAvatarStoreError.fileTooLarge) {
            try store.prepareImage(data: Data(count: AgentAvatarStore.maximumInputBytes))
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "source.png"), link = root.appending(path: "link.png")
        try png().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: AgentAvatarStoreError.unsafePath) { try store.importImage(at: link, crop: .init()) }
        #expect(throws: AgentAvatarStoreError.unsafePath) {
            try store.importImage(at: URL(string: "https://example.invalid/image.png")!, crop: .init())
        }
        #expect(throws: AgentAvatarStoreError.invalidImage) { try store.importImage(at: root, crop: .init()) }
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
    }
}
