import AppKit
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import Foundation
import Testing

private actor ImageAvatarTrace {
    var events: [String] = []
    func append(_ event: String) { events.append(event) }
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { waiter = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

@Suite("Host-gated image avatar proposals", .timeLimit(.minutes(1)))
struct AgentImageAvatarChangeTests {
    private func image(_ store: AgentAvatarStore, paddedTo size: Int? = nil) throws -> PreparedAgentAvatar {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { rep.setColor(.blue, atX: x, y: y) } }
        var bytes = try #require(rep.representation(using: .png, properties: [:]))
        if let size { bytes.append(Data(count: size - bytes.count)) }
        return try store.prepareImage(data: bytes)
    }

    private func request(_ path: String = "/workspace/avatar.png", id: ToolCallID = "image") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: JSONEncoder().encode([
            "target": "avatar", "action": "set", "path": path,
        ]))
    }

    @Test(arguments: ["save", "receipt", "denied", "archived", "stale", "closed", "missing-store", "disk-failure"])
    func exactImageApprovalAndFencedPersistence(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-image-proposal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "agents.json")
        let agents = try AgentService(storeURL: file)
        let owner = try await agents.create(name: "Designer", instructions: "private", avatar: .pet(.dewey))
        let store = AgentAvatarStore(rootURL: root.appending(path: "avatars"))
        let prepared = try image(store)
        let context = ToolContext(conversationID: UUID())
        let trace = ImageAvatarTrace()
        let session = AgentManagementSession(originID: context.conversationID, agents: agents,
            authorizeAvatar: { _, _, _, _ in Issue.record("Pet approval must not authorize an image") },
            commitAvatar: { change, lifetime in
                await trace.append("commit")
                if mode == "closed" { lifetime.close() }
                let saved = try await agents.applyAvatarChange(change, lifetime: lifetime,
                    imageStore: mode == "missing-store" ? nil : store)
                if mode == "receipt" { throw AgentAvatarChangeError.invalid }
                return saved
            },
            prepareAvatarImage: { path, sender, _, receivedContext in
                expectNoDifference(path, "/workspace/avatar.png")
                expectNoDifference(sender.id, owner.id)
                expectNoDifference(receivedContext.conversationID, context.conversationID)
                await trace.append("read")
                return prepared
            },
            authorizeAvatarImage: { sender, change, _, _ in
                await trace.append("preview")
                expectNoDifference(change.image, prepared)
                expectNoDifference(change.previousAvatar, owner.avatar)
                expectNoDifference(sender, owner)
                #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
                if mode == "denied" { throw AgentMessagingError.approvalRequired }
                if mode == "archived" { try await agents.archive(id: owner.id) }
                if mode == "stale" {
                    var edited = owner; edited.avatar = .pet(.hoots); try await agents.update(edited)
                }
                if mode == "disk-failure" {
                    try FileManager.default.moveItem(at: file, to: root.appending(path: "backup"))
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                }
            })
        #expect(session.supportsImageAvatars)
        let tool = session.tools(for: owner.id)[2], call = try request()
        if mode == "save" || mode == "receipt" {
            let result = try await tool.execute(call, context: context)
            let replay = try await tool.execute(call, context: context)
            expectNoDifference(replay, result)
            let events = await trace.events
            expectNoDifference(events, ["read", "preview", "commit"])
            let durable = try AgentService(storeURL: file)
            let profile = try #require(await durable.profile(id: owner.id))
            expectNoDifference(profile.avatar, prepared.avatar)
            expectNoDifference(profile.instructions, owner.instructions)
            let url = try #require(store.imageURL(for: prepared.avatar))
            expectNoDifference(try Data(contentsOf: url), prepared.pngData)
            await #expect(throws: AgentProfileChangeError.duplicate) {
                _ = try await tool.execute(request("/workspace/other.png"), context: context)
            }
        } else {
            await #expect(throws: (any Error).self) { _ = try await tool.execute(call, context: context) }
            let actual = await agents.profile(id: owner.id)
            expectNoDifference(actual?.avatar, mode == "stale" ? .pet(.hoots) : owner.avatar)
            if mode != "disk-failure" { #expect(!FileManager.default.fileExists(atPath: store.rootURL.path)) }
        }
        session.close()
    }

    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7])
    func capabilityRequiresAllThreeHostAdapters(mask: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-image-capability-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner")
        let context = ToolContext(conversationID: UUID())
        let prepare: AgentManagementSession.AvatarImagePreparer = { _, _, _, _ in throw AgentMessagingError.approvalRequired }
        let approve: AgentManagementSession.AvatarAuthorizer = { _, _, _, _ in throw AgentMessagingError.approvalRequired }
        let commit: AgentManagementSession.AvatarCommitter = { _, _ in throw AgentMessagingError.approvalRequired }
        let session = AgentManagementSession(originID: context.conversationID, agents: agents,
            commitAvatar: mask & 1 == 0 ? nil : commit,
            prepareAvatarImage: mask & 2 == 0 ? nil : prepare,
            authorizeAvatarImage: mask & 4 == 0 ? nil : approve)
        expectNoDifference(session.supportsImageAvatars, mask == 7)
        let tool = session.tools(for: owner.id)[2]
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        expectNoDifference(properties["path"] != nil, mask == 7)
        if mask != 7 {
            await #expect(throws: AgentAvatarChangeError.invalid) { _ = try await tool.execute(request(), context: context) }
        }
        session.close()
    }

    @Test func invalidSourcesAndModelSizeBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-image-bounds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner")
        let store = AgentAvatarStore(rootURL: root.appending(path: "avatars"))
        let context = ToolContext(conversationID: UUID())
        let limit = AgentAvatarChange.maximumImageSourceBytes
        for size in [limit, limit + 1] {
            let prepared = try image(store, paddedTo: size)
            let session = AgentManagementSession(originID: context.conversationID, agents: agents,
                commitAvatar: { change, lifetime in try await agents.applyAvatarChange(change, lifetime: lifetime, imageStore: store) },
                prepareAvatarImage: { _, _, _, _ in prepared }, authorizeAvatarImage: { _, _, _, _ in })
            let tool = session.tools(for: owner.id)[2]
            for path in ["", "relative.png", "https://example.invalid/a.png", "//server/file", "/a/../b", "/a\u{0}b"] {
                await #expect(throws: AgentAvatarChangeError.invalid) { _ = try await tool.execute(request(path), context: context) }
            }
            for fields in [
                ["target": "avatar", "action": "clear", "path": "/a"],
                ["target": "avatar", "action": "set", "path": "/a", "pet_id": "hoots"],
                ["target": "avatar", "action": "set", "path": "/a", "agent_id": owner.id.uuidString],
            ] {
                await #expect(throws: AgentAvatarChangeError.invalid) {
                    _ = try await tool.execute(.init(id: "bad", name: "update_state", argumentsJSON: JSONEncoder().encode(fields)), context: context)
                }
            }
            if size == limit { _ = try await tool.execute(request(), context: context) }
            else { await #expect(throws: AgentAvatarChangeError.invalid) { _ = try await tool.execute(request(), context: context) } }
            session.close()
        }
    }

    @Test(arguments: [false, true])
    func stopDuringReadOrImageApprovalNeverInstalls(duringApproval: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-image-stop-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner")
        let store = AgentAvatarStore(rootURL: root.appending(path: "avatars"))
        let prepared = try image(store), trace = ImageAvatarTrace()
        let context = ToolContext(conversationID: UUID())
        let session = AgentManagementSession(originID: context.conversationID, agents: agents,
            commitAvatar: { change, lifetime in
                await trace.append("commit")
                return try await agents.applyAvatarChange(change, lifetime: lifetime, imageStore: store)
            },
            prepareAvatarImage: { _, _, _, _ in
                await trace.append("read")
                if !duringApproval { await trace.hold() }
                return prepared
            }, authorizeAvatarImage: { _, _, _, _ in
                await trace.append("preview")
                if duringApproval { await trace.hold() }
            })
        let tool = session.tools(for: owner.id)[2]
        let work = Task { try await tool.execute(request(), context: context) }
        await trace.waitForEntry()
        await #expect(throws: AgentProfileChangeError.duplicate) {
            _ = try await tool.execute(request(), context: context)
        }
        session.close()
        await trace.release()
        await #expect(throws: CancellationError.self) { _ = try await work.value }
        let events = await trace.events, actual = await agents.profile(id: owner.id)
        expectNoDifference(events, duringApproval ? ["read", "preview"] : ["read"])
        expectNoDifference(actual, owner)
        #expect(!FileManager.default.fileExists(atPath: store.rootURL.path))
    }
}
