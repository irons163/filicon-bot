import Foundation
import Testing
import CustomDump
@testable import FiliconRichContent

@Suite("Pinned public Mermaid resource validation", .timeLimit(.minutes(1)))
struct MermaidAssetTests {
    @Test func installedPublicResourcesPreserveTheVerifiedEngineWithoutEvaluatingIt() throws {
        let root = try #require(Bundle.module.url(forResource: "Mermaid", withExtension: nil))
        let assets = try #require(OfflineMermaidResources.load(root: root))
        expectNoDifference(assets.script, try String(contentsOf: root.appendingPathComponent("mermaid.min.js"), encoding: .utf8))
        expectNoDifference(OfflineMermaidResources.engineVersion, "11.16.0")
        #expect(OfflineMermaidResources.verified != nil)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let components = try #require(manifest["components"] as? [[String: Any]])
        #expect(components.count == 72)
        #expect(components.contains { $0["name"] as? String == "langium" && $0["version"] as? String == "4.2.0" })
        #expect(components.contains { $0["name"] as? String == "dompurify" && $0["version"] as? String == "3.4.0" })
        #expect((manifest["provenance"] as? String)?.contains("no opaque shipped-byte equivalence") == true)
    }

    @Test func everyRequiredFileAndNoticeIsPinnedAndAbsenceFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("manifest.json"))) as? [String: Any])
        let files = try #require(manifest["files"] as? [String: [String: Any]])
        #expect(files.count == 74)
        for path in (Array(files.keys) + ["manifest.json"]).sorted() {
            let resource = fixture.root.appendingPathComponent(path)
            let bytes = try Data(contentsOf: resource)
            try (bytes + Data([0])).write(to: resource)
            #expect(OfflineMermaidResources.load(root: fixture.root) == nil, "Changed resource must reject: \(path)")
            try FileManager.default.removeItem(at: resource)
            #expect(OfflineMermaidResources.load(root: fixture.root) == nil, "Missing resource must reject: \(path)")
            try bytes.write(to: resource)
        }
        #expect(OfflineMermaidResources.load(root: fixture.root) != nil)
    }

    @Test(arguments: ["manifest.json", "mermaid.min.js", "LICENSE", "notices/dompurify-3.4.0/LICENSE", "notices/langium-4.2.0/LICENSE"])
    func symlinkedFilesCannotSubstituteEvenIdenticalVerifiedBytes(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resource = fixture.root.appendingPathComponent(path)
        let bytes = try Data(contentsOf: resource)
        let external = fixture.directory.appendingPathComponent("external.fixture")
        try bytes.write(to: external)
        try FileManager.default.removeItem(at: resource)
        try FileManager.default.createSymbolicLink(at: resource, withDestinationURL: external)
        #expect(OfflineMermaidResources.load(root: fixture.root) == nil)
        expectNoDifference(try Data(contentsOf: external), bytes)
    }

    @Test(arguments: ["root", "notices", "notices/dompurify-3.4.0"])
    func symlinkedRootAndEveryNoticeDirectoryLevelAreRejected(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("external-directory")
        if path == "root" {
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: fixture.root)
            #expect(OfflineMermaidResources.load(root: target) == nil)
        } else {
            let directory = fixture.root.appendingPathComponent(path)
            try FileManager.default.moveItem(at: directory, to: target)
            try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
            #expect(OfflineMermaidResources.load(root: fixture.root) == nil)
        }
    }

    @Test func missingAndDamagedPreferredBundlesDoNotTrapOrBorrowAnotherInstall() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(OfflineMermaidResources.load(searchRoots: [fixture.directory]) == nil)
        let bundle = fixture.directory.appendingPathComponent("Filicon_FiliconRichContent.bundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.root, to: bundle.appendingPathComponent("Mermaid"))
        #expect(OfflineMermaidResources.load(searchRoots: [fixture.directory]) != nil)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Mermaid/LICENSE"))
        #expect(OfflineMermaidResources.load(searchRoots: [fixture.directory, Bundle.module.bundleURL.deletingLastPathComponent()]) == nil)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Mermaid"))
        #expect(OfflineMermaidResources.load(searchRoots: [fixture.directory, Bundle.module.bundleURL.deletingLastPathComponent()]) == nil)
        try FileManager.default.removeItem(at: bundle)
        try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: Bundle.module.bundleURL)
        #expect(OfflineMermaidResources.load(searchRoots: [fixture.directory]) == nil)
    }

    private struct Fixture {
        let directory: URL
        var root: URL { directory.appendingPathComponent("Mermaid") }
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("filicon-mermaid-assets-\(UUID())")
            let source = try #require(Bundle.module.url(forResource: "Mermaid", withExtension: nil))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do { try FileManager.default.copyItem(at: source, to: root) }
            catch { try? FileManager.default.removeItem(at: directory); throw error }
        }
        func remove() { try? FileManager.default.removeItem(at: directory) }
    }
}
