import Foundation
import FiliconLocalTools

/// Standalone client: XCTest re-signs sandboxed services with diagnostic access.
/// This fixture deliberately runs without XCTest/testmanager or cloud services.
@main
struct XPCSmoke {
    static func main() async {
        do {
            // The smoke runner uses a legacy bare client and a packaged app
            // with different signing identifiers, not just a changed cdhash.
            #if BOOKMARK_REBUILT
            print("Bookmark client B (rebuilt)")
            #else
            print("Bookmark client A")
            #endif
            let arguments = CommandLine.arguments
            let mode = arguments.count == 3 ? arguments[1] : "--fresh"
            let fixture = (arguments.count == 3 ? URL(fileURLWithPath: arguments[2]) : FileManager.default.temporaryDirectory
                .appending(path: "filicon-strict-xpc-\(UUID().uuidString)", directoryHint: .isDirectory)
            ).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { if mode == "--fresh" { try? FileManager.default.removeItem(at: fixture) } }
            let root = fixture.appending(path: "workspace", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = WorkspaceAuthorizationStore(fileURL: fixture.appending(path: "bookmarks.json"))
            if mode == "--seed" {
                _ = try await store.authorize(root)
                guard try await store.accessState(forExactRoot: root.path) == .ready else {
                    throw LocalToolError.invalidRequest("fresh seed authorization failed")
                }
                print("BOOKMARK SEED PASSED")
                exit(0)
            }
            if mode == "--renew" {
                guard try await store.accessState(forExactRoot: root.path) == .needsRenewal else {
                    throw LocalToolError.invalidRequest("rebuilt client did not detect the invalidated grant")
                }
                do {
                    _ = try await store.transportBookmark(forExactRoot: root.path)
                    throw LocalToolError.invalidRequest("invalidated grant was silently accepted")
                } catch LocalToolError.workspaceAuthorizationNeedsRenewal {}
                print("BOOKMARK IDENTITY CHANGE DETECTED")
            }
            // Only this synthetic fixture is authorized here. In the app,
            // renewal reaches authorize exclusively after native user selection.
            let authorization = try await store.authorize(root)
            let reloaded = WorkspaceAuthorizationStore(fileURL: fixture.appending(path: "bookmarks.json"))
            let runtime = LocalToolRuntime(workspaceStore: reloaded)
            let conversation = UUID(), run = UUID()
            let bytes = Data("Filicon strict Xcode XPC fixture\n".utf8)
            _ = try await runtime.perform(
                operation: .writeFile(root: root.path, relativePath: "fixture.txt", data: bytes, replace: false),
                conversationID: conversation, agentID: conversation, runID: run, toolCallID: "write"
            )
            let result = try await runtime.perform(
                operation: .readFile(root: root.path, relativePath: "fixture.txt"),
                conversationID: conversation, agentID: conversation, runID: run, toolCallID: "read"
            )
            guard result == .file(bytes), try Data(contentsOf: root.appending(path: "fixture.txt")) == bytes else {
                throw LocalToolError.invalidRequest("file contents did not match")
            }
            _ = try await runtime.perform(
                operation: .listDirectory(root: root.path, relativePath: "."),
                conversationID: conversation, agentID: conversation, runID: run, toolCallID: "list"
            )
            do {
                _ = try await runtime.perform(
                    operation: .listDirectory(root: fixture.path, relativePath: "."),
                    conversationID: conversation, agentID: conversation, runID: run, toolCallID: "unapproved"
                )
                throw LocalToolError.invalidRequest("unapproved root was accepted")
            } catch LocalToolError.permissionMismatch {}
            try await reloaded.remove(id: authorization.id)
            do {
                _ = try await runtime.perform(
                    operation: .readFile(root: root.path, relativePath: "fixture.txt"),
                    conversationID: conversation, agentID: conversation, runID: run, toolCallID: "revoked"
                )
                throw LocalToolError.invalidRequest("revoked root was accepted")
            } catch LocalToolError.permissionMismatch {}
            print("STRICT XPC PASSED: list, write, read, unapproved root, revoked root")
            exit(0)
        } catch {
            print("STRICT XPC FAILED: \(error)")
            exit(1)
        }
    }
}
