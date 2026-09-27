import AppKit
import CustomDump
import FiliconAgents
import Foundation
import ImageIO
import Testing

@Suite("Static SVG avatar conversion")
struct StaticSVGAvatarTests {
    private func svg(_ body: String, attributes: String = "") -> Data {
        Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"32\" height=\"32\" \(attributes)>\(body)</svg>".utf8)
    }
    private var store: AgentAvatarStore { .init(rootURL: URL(fileURLWithPath: "/unused-svg-avatar-store")) }

    @Test(arguments: [
        "<rect width=\"32\" height=\"32\" fill=\"red\"/>",
        "<g transform=\"translate(1 1)\"><path d=\"M0 0 H30 V30 H0 Z\" fill=\"blue\"/></g>",
        "<defs><linearGradient id=\"paint\"><stop offset=\"0\" stop-color=\"red\"/><stop offset=\"1\" stop-color=\"blue\"/></linearGradient></defs><rect width=\"32\" height=\"32\" fill=\"url(#paint)\"/>"
    ])
    func convertsSelfContainedVectorToPNG(body: String) throws {
        let source = svg(body)
        let prepared = try store.prepareImage(data: source)
        expectNoDifference(prepared.sourceByteCount, source.count)
        let image = try #require(NSBitmapImageRep(data: prepared.pngData))
        expectNoDifference(image.pixelsWide, 256)
        expectNoDifference(image.pixelsHigh, 256)
        let color = try #require(image.colorAt(x: 128, y: 128))
        #expect(color.alphaComponent > 0.9)
        expectNoDifference(try store.prepareImage(data: source).pngData, prepared.pngData)
    }

    @Test(arguments: [
        "<script>alert(1)</script>",
        "<image href=\"https://example.invalid/private.png\"/>",
        "<image href=\"file:///private/secret\"/>",
        "<foreignObject><body>unsafe</body></foreignObject>",
        "<style>@import 'https://example.invalid/style';</style>",
        "<rect width=\"32\" height=\"32\" style=\"fill:red\"/>",
        "<rect fill=\"url(https://example.invalid/image)\"/>",
        "<rect fill=\"url(data:image/svg+xml,anything)\"/>",
        "<rect fill=\"url(#missing)\"/>",
        "<rect onload=\"alert(1)\"/>",
        "<use href=\"#recursive\" id=\"recursive\"/>",
        "<animate attributeName=\"x\"/>",
        "<?xml-stylesheet href=\"https://example.invalid/style\"?>",
        "<g xmlns=\"https://example.invalid/namespace\"/>",
        "<rect fill=\"u&#114;l(https://example.invalid/image)\"/>",
        "<linearGradient id=\"paint\"><rect fill=\"url(#paint)\"/></linearGradient>",
        "<linearGradient id=\"paint\"/><rect id=\"paint\"/>",
        "<rect>"
    ])
    func rejectsActiveExternalRecursiveAndUnsupportedContent(body: String) {
        #expect(throws: AgentAvatarStoreError.invalidImage) { try store.prepareImage(data: svg(body)) }
    }

    @Test func rejectsEntitiesAndExcessiveComplexity() {
        let dtd = Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///private/secret'>]><svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'>&x;</svg>".utf8)
        #expect(throws: AgentAvatarStoreError.invalidImage) { try store.prepareImage(data: dtd) }
        let utf16 = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'/>".data(using: .utf16)!
        #expect(throws: AgentAvatarStoreError.invalidImage) { try store.prepareImage(data: utf16) }
        #expect(throws: AgentAvatarStoreError.invalidImage) {
            try store.prepareImage(data: svg(String(repeating: "<g>", count: 65) + String(repeating: "</g>", count: 65)))
        }
        #expect(throws: AgentAvatarStoreError.invalidImage) {
            try store.prepareImage(data: svg(String(repeating: "<rect/>", count: 4_096)))
        }
        let oversized = Data("<svg xmlns='http://www.w3.org/2000/svg' width='9999999' height='32'/>".utf8)
        #expect(throws: AgentAvatarStoreError.invalidImage) { try store.prepareImage(data: oversized) }
    }
}
