import AppKit
import CustomDump
import FiliconAgents
import Foundation
import Testing

@Suite("Immutable avatar preparation")
struct PreparedAgentAvatarTests {
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
