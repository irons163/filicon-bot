import CryptoKit
import CustomDump
import Foundation
import Testing
@testable import Filicon
import FiliconAppServices
import FiliconDomain
import FiliconLocalTools

@Suite("Publication source snapshots", .timeLimit(.minutes(1)))
@MainActor
struct AgentPublicationFileSourceTests {
    @Test(arguments: ["file:///tmp/report.txt", "file:///tmp/design%20draft.pdf", "file:///tmp/%E5%A0%B1%E5%91%8A.txt"])
    func validLocalURLs(value: String) throws {
        let path = try AgentPublicationFileSource.localPath(value)
        expectNoDifference(path, try #require(URLComponents(string: value)).path)
    }

    @Test(arguments: ["https://example.com/a", "/tmp/a", "file://server/tmp/a", "file://localhost/tmp/a",
        "file:///tmp/a?download=1", "file:///tmp/a#fragment", "file:///tmp/../a", "file:///tmp/%2e%2e/a",
        "file:///tmp/a%00b", "file:relative", "file:////tmp/a", "file:///tmp//a"])
    func rejectsAmbiguousSources(value: String) {
        #expect(throws: LocalToolError.pathEscape) { _ = try AgentPublicationFileSource.localPath(value) }
    }

    @Test(arguments: ["snapshot", "empty", "deny", "never", "revoked", "symlink", "directory", "oversize"])
    func capturesOnlyAuthorizedBytes(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "publication-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let file = workspace.appending(path: "report.txt")
        let bytes = mode == "empty" ? Data() : Data("Original artifact".utf8)
        if mode == "symlink" {
            let outside = root.appending(path: "private.txt")
            try bytes.write(to: outside)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        } else if mode == "directory" {
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        } else {
            try (mode == "oversize" ? Data(count: AgentPublicationFileSource.maximumBytes + 1) : bytes).write(to: file)
        }
        let store = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await store.authorize(workspace)
        let generation = UUID(), key = Data(repeating: 24, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: store, generation: generation, sessionKey: key, helper: helper)
        let folders = WorkspaceFolderCoordinator(store: store, onChange: { _ in })
        let policy = ToolPermissionPolicy(choices: mode == "never" ? [.readFile: .never] : [:])
        let reader = AuthorizedAgentFileReader(runtime: runtime, folders: folders, policy: policy,
            validateScope: {}, authorizeRead: { operation, _, _ in
                expectNoDifference(operation, .readFile(root: workspace.path, relativePath: "report.txt"))
                if mode == "deny" { throw CancellationError() }
                if mode == "revoked", let grant = await store.authorization(forExactRoot: workspace.path) {
                    try await store.remove(id: grant.id)
                }
            })
        let source = AgentPublicationFileSource(reader: reader)
        let call = try NormalizedToolCall(id: "publish", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let context = ToolContext(conversationID: UUID())
        if ["snapshot", "empty"].contains(mode) {
            let prepared = try await source.prepare(url: file.absoluteString, agentID: UUID(), call: call, context: context)
            try Data("Changed after preparation".utf8).write(to: file)
            expectNoDifference(prepared.bytes, bytes)
            expectNoDifference(prepared.filename, "report.txt")
            expectNoDifference(prepared.digest, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await source.prepare(url: file.absoluteString, agentID: UUID(), call: call, context: context)
            }
        }
        // Preparation never creates an attachment store or a visible message.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        expectNoDifference(names, mode == "symlink" ? ["grants.json", "private.txt", "workspace"] : ["grants.json", "workspace"])
    }
}
