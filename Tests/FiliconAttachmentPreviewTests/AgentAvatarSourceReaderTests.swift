import AppKit
import CustomDump
import Darwin
import Foundation
import Testing
@testable import Filicon
import FiliconAgents
import FiliconAppServices
import FiliconComputer
import FiliconDomain
import FiliconLocalTools

private actor AvatarSourceProbe {
    var operations: [LocalOperation] = []
    var active = true
    func record(_ operation: LocalOperation) { operations.append(operation) }
    func close() { active = false }
    func check() throws { if !active { throw CancellationError() } }
}

@MainActor
private final class AvatarFolderRequests {
    var pending: [WorkspaceFolderRequest] = []
    func first() async throws -> WorkspaceFolderRequest {
        for _ in 0..<600 {
            if let value = pending.first { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

@Suite("Authorized avatar source adapters", .timeLimit(.minutes(1)))
@MainActor
struct AgentAvatarSourceReaderTests {
    private func png() throws -> Data {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.red, atX: x, y: y) } }
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test(arguments: ["ready", "ask", "renew", "prefix-collision", "different-folder", "decline", "never", "deny-read", "revoked", "scope", "policy", "symlink", "directory", "fifo", "oversize"])
    func localReadUsesExactGrantAndOperation(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-avatar-source-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appending(path: "avatar.png")
        let bytes = try png()
        if mode == "fifo" { expectNoDifference(mkfifo(source.path, 0o600), 0) }
        else if mode == "directory" { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false) }
        else if mode == "symlink" {
            let outside = root.appending(path: "outside.png"); try bytes.write(to: outside)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        } else { try (mode == "oversize" ? Data(count: AgentAvatarChange.maximumImageSourceBytes + 1) : bytes).write(to: source) }
        let store = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        if mode == "renew" { try await store.registerBookmarkData(Data([1, 2]), url: workspace) }
        else if !["ask", "different-folder", "decline"].contains(mode) { try await store.authorize(workspace) }
        let generation = UUID(), key = Data(repeating: 42, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let host = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: store, generation: generation, sessionKey: key, helper: host)
        let requests = AvatarFolderRequests()
        let folders = WorkspaceFolderCoordinator(store: store, onChange: { requests.pending = $0 })
        let policy = ToolPermissionPolicy(choices: mode == "never" ? [.readFile: .never] : [:])
        let probe = AvatarSourceProbe()
        let cas = AgentAvatarStore(rootURL: root.appending(path: "cas"))
        let reader = AgentAvatarSourceReader(runtime: runtime, folders: folders, policy: policy, imageStore: cas,
            validateScope: { try await probe.check() }, authorizeRead: { operation, _, _ in
                await probe.record(operation)
                if mode == "deny-read" { throw CancellationError() }
                if mode == "scope" { await probe.close() }
                if mode == "policy" { try await policy.setChoice(.never, for: .readFile) }
                if mode == "revoked", let grant = await store.authorization(forExactRoot: workspace.path) {
                    try await store.remove(id: grant.id)
                }
            })
        let context = ToolContext(conversationID: UUID())
        let call = try NormalizedToolCall(id: "avatar", name: "update_state", argumentsJSON: Data("{}".utf8))
        let requestedPath = mode == "prefix-collision" ? workspace.path + "-other/avatar.png" : source.path
        let work = Task { try await reader.prepare(path: requestedPath, agentID: UUID(), call: call, context: context) }
        if ["ask", "renew", "prefix-collision", "different-folder", "decline"].contains(mode) {
            let request = try await requests.first()
            expectNoDifference(request.requestedRoot, mode == "renew" ? workspace.path : nil)
            expectNoDifference(request.requiresReauthorization, mode == "renew")
            let before = await probe.operations
            #expect(before.isEmpty)
            if mode == "decline" { folders.decline(request) }
            else {
                let selected = mode == "different-folder" ? root.appending(path: "different") : workspace
                try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
                try await folders.resolve(request, selectedURL: selected)
            }
        }
        if ["ready", "ask", "renew"].contains(mode) {
            let result = try await work.value
            expectNoDifference(result, try cas.prepareImage(data: bytes))
            let operations = await probe.operations
            expectNoDifference(operations, [.readFile(root: workspace.path, relativePath: "avatar.png")])
            expectNoDifference(try Data(contentsOf: source), bytes)
        } else { await #expect(throws: (any Error).self) { _ = try await work.value } }
        if ["never", "prefix-collision", "different-folder", "decline"].contains(mode) {
            let operations = await probe.operations
            #expect(operations.isEmpty)
        }
        #expect(requests.pending.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cas.rootURL.path))
    }

    @Test(arguments: ["success", "bad-digest", "oversize", "denied", "scope-after-download"])
    func remoteDownloadKeepsHostOwnerAndBoundedIntegrity(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-avatar-remote-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = try png(), probe = AvatarSourceProbe()
        let backend = AvatarRemoteBackend(bytes: mode == "oversize" ? Data(count: AgentAvatarChange.maximumImageSourceBytes + 1) : bytes,
            badDigest: mode == "bad-digest", afterDownload: { if mode == "scope-after-download" { await probe.close() } })
        let cas = AgentAvatarStore(rootURL: root)
        let reader = AgentRemoteAvatarSourceReader(backend: backend, remoteAgentID: "host-fixed-owner", imageStore: cas,
            validateScope: { try await probe.check() }, authorizeRead: { path, _, _ in
                expectNoDifference(path, "/workspace/avatar.png")
                if mode == "denied" { throw CancellationError() }
            })
        let call = try NormalizedToolCall(id: "avatar", name: "update_state", argumentsJSON: Data("{}".utf8))
        let context = ToolContext(conversationID: UUID())
        if mode == "success" {
            let result = try await reader.prepare(path: "/workspace/avatar.png", call: call, context: context)
            expectNoDifference(result, try cas.prepareImage(data: bytes))
        } else {
            await #expect(throws: (any Error).self) {
                _ = try await reader.prepare(path: "/workspace/avatar.png", call: call, context: context)
            }
        }
        let requests = await backend.requests
        expectNoDifference(requests, mode == "denied" ? [] : ["host-fixed-owner:/workspace/avatar.png:5242880"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}

private actor AvatarRemoteBackend: RemoteFileBackend {
    let bytes: Data
    let badDigest: Bool
    let afterDownload: @Sendable () async -> Void
    var requests: [String] = []
    init(bytes: Data, badDigest: Bool, afterDownload: @escaping @Sendable () async -> Void) {
        self.bytes = bytes; self.badDigest = badDigest; self.afterDownload = afterDownload
    }
    func upload(agentID: String, path: String, data: Data, descriptor: RemoteFileDescriptor) async throws {
        Issue.record("Avatar preparation must not upload files")
    }
    func download(agentID: String, path: String, maximumBytes: Int) async throws -> (Data, RemoteFileDescriptor) {
        requests.append("\(agentID):\(path):\(maximumBytes)")
        await afterDownload()
        return (bytes, .init(size: bytes.count, sha256: badDigest ? "bad" : RemoteFileTransfer.sha256(bytes)))
    }
}
