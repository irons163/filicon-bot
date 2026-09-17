import CustomDump
import Foundation
import Testing
@testable import Filicon
import FiliconLocalTools

/// Hosted by the real Xcode-built app, with its actual embedded, sandboxed XPC
/// service. No fake helper, cloud provider, or user workspace is involved.
@Suite(.serialized)
struct PackagedLocalToolTests {
    @Test func bundleHasIdentityResourcesAndEmbeddedExecutables() throws {
        expectNoDifference(Bundle.main.bundleIdentifier, "com.filicon.app")
        expectNoDifference(Bundle.main.bundleURL.pathExtension, "app")
        let root = Bundle.main.bundleURL
        for path in [
            "Contents/XPCServices/FiliconLocalToolService.xpc/Contents/MacOS/FiliconLocalToolXPCService",
            "Contents/Helpers/FiliconLocalToolHelper",
            "Contents/Helpers/FiliconUpdateHelper",
        ] {
            #expect(FileManager.default.isExecutableFile(atPath: root.appending(path: path).path))
        }
        for locale in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            #expect(Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: locale) != nil)
        }
        #expect(Bundle.main.url(forResource: "codex", withExtension: "webp", subdirectory: "PetAvatars") != nil)
        let override = try #require(ProcessInfo.processInfo.environment["FILICON_DATA_ROOT"])
        #expect(override.hasSuffix("/FiliconXcodeTestData"))
        #expect(!override.contains("$("))
        #expect(!override.contains("Application Support/Filicon"))
    }

    @Test func realXPCWritesReadsListsAndRejectsUnapprovedRoots() async throws {
        // A fresh throwaway directory; never authorize a user's actual project.
        let fixture = FileManager.default.temporaryDirectory
            .appending(path: "filicon-xcode-xpc-\(UUID().uuidString)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let root = fixture.appending(path: "workspace", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceAuthorizationStore(fileURL: fixture.appending(path: "bookmarks.json"))
        _ = try await store.authorize(root)
        let runtime = LocalToolRuntime(workspaceStore: store)
        let conversation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let run = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let bytes = Data("Filicon Xcode real XPC fixture\n".utf8)
        _ = try await runtime.perform(
            operation: .writeFile(root: root.path, relativePath: "fixture.txt", data: bytes, replace: false),
            conversationID: conversation, agentID: conversation, runID: run, toolCallID: "write"
        )
        let result = try await runtime.perform(
            operation: .readFile(root: root.path, relativePath: "fixture.txt"),
            conversationID: conversation, agentID: conversation, runID: run, toolCallID: "read"
        )
        expectNoDifference(result, .file(bytes))
        expectNoDifference(try Data(contentsOf: root.appending(path: "fixture.txt")), bytes)
        _ = try await runtime.perform(
            operation: .listDirectory(root: root.path, relativePath: "."),
            conversationID: conversation, agentID: conversation, runID: run, toolCallID: "list"
        )
        await #expect(throws: LocalToolError.permissionMismatch) {
            _ = try await runtime.perform(
                operation: .listDirectory(root: fixture.path, relativePath: "."),
                conversationID: conversation, agentID: conversation, runID: run, toolCallID: "unapproved"
            )
        }
    }
}
