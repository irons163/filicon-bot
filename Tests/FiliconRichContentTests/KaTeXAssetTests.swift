import Foundation
import Testing
import CustomDump
@testable import FiliconRichContent

@Suite("Pinned KaTeX resource validation", .timeLimit(.minutes(1)))
struct KaTeXAssetTests {
    @Test func installedResourcesAreVerifiedBeforeTheirEngineIsEvaluated() throws {
        let root = try #require(Bundle.module.url(forResource: "KaTeX", withExtension: nil))
        let assets = try #require(KaTeXAssets.load(root: root))
        expectNoDifference(assets.script, try String(contentsOf: root.appendingPathComponent("katex.min.js"), encoding: .utf8))
        #expect(assets.stylesheet.contains("data:font/woff2;base64,"))
        #expect(!assets.stylesheet.contains("url(fonts/"))
    }

    @Test(arguments: ["manifest.json", "katex.min.js", "katex.min.css", "LICENSE", "fonts/KaTeX_Main-Regular.woff2"],
          ["missing", "modified", "symlink"])
    func missingChangedOrSymlinkedResourcesAreNeverEvaluated(path: String, damage: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resource = fixture.root.appendingPathComponent(path)
        let original = try Data(contentsOf: resource)
        switch damage {
        case "missing": try FileManager.default.removeItem(at: resource)
        case "modified": try (original + Data([0])).write(to: resource)
        default:
            let target = fixture.directory.appendingPathComponent("external.fixture")
            try original.write(to: target)
            try FileManager.default.removeItem(at: resource)
            try FileManager.default.createSymbolicLink(at: resource, withDestinationURL: target)
        }
        #expect(KaTeXAssets.load(root: fixture.root) == nil)
    }

    @Test func missingWholeBundleAndDamagedPreferredBundleFailClosedWithoutBorrowingAnotherCopy() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(KaTeXAssets.load(searchRoots: [fixture.directory]) == nil)
        let bundle = fixture.directory.appendingPathComponent("Filicon_FiliconRichContent.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.root, to: bundle.appendingPathComponent("KaTeX"))
        #expect(KaTeXAssets.load(searchRoots: [fixture.directory]) != nil)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("KaTeX/LICENSE"))
        #expect(KaTeXAssets.load(searchRoots: [fixture.directory, Bundle.module.bundleURL.deletingLastPathComponent()]) == nil)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("KaTeX"))
        #expect(KaTeXAssets.load(searchRoots: [fixture.directory, Bundle.module.bundleURL.deletingLastPathComponent()]) == nil)
    }

    @Test func symlinkedRootAndFontsDirectoryAreRejectedEvenWhenBytesMatch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        #expect(KaTeXAssets.load(root: alias) == nil)
        let fonts = fixture.root.appendingPathComponent("fonts")
        let target = fixture.directory.appendingPathComponent("external-fonts")
        try FileManager.default.moveItem(at: fonts, to: target)
        try FileManager.default.createSymbolicLink(at: fonts, withDestinationURL: target)
        #expect(KaTeXAssets.load(root: fixture.root) == nil)
    }

    private struct Fixture {
        let directory: URL
        var root: URL { directory.appendingPathComponent("KaTeX") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-katex-assets-\(UUID())")
            let source = try #require(Bundle.module.url(forResource: "KaTeX", withExtension: nil))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do { try FileManager.default.copyItem(at: source, to: root) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
