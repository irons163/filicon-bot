import Foundation
import CoreGraphics
import ImageIO
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit

private func peerImageBytes(type: String = "public.png", shade: CGFloat = 0.25) throws -> Data {
    let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(CGColor(gray: shade, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    let image = try #require(context.makeImage()), data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct ImagePeerProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "image-peer", displayName: "Image fixture", requiresAPIKey: false)
    var supportsImages = true
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] {
        [.init(id: "test", capabilities: .init(inputModalities: supportsImages ? [.text, .image] : [.text]))]
    }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ImagePeerProbe {
    var requests: [InferenceRequest] = []
    var approvals: [[AttachmentMetadata]] = []
    func request(_ value: InferenceRequest) -> Int { requests.append(value); return requests.count }
    func approve(_ images: [AttachmentMetadata]) { approvals.append(images) }
}

private func forwardImage(_ target: UUID, ids: [String], id: ToolCallID = "forward", priority: Bool = false) throws -> NormalizedToolCall {
    struct Payload: Encodable { let recipientID: UUID; let message = "Review these images"; let images: [String]; let priority: Bool }
    return try .init(id: id, name: "SendToAgent", argumentsJSON: JSONEncoder().encode(Payload(recipientID: target, images: ids, priority: priority)))
}

@Suite("Peer image storage and delivery", .timeLimit(.minutes(1)))
struct AgentImageMessagingTests {
    private struct Fixture {
        let root: URL
        let agents: AgentService
        let sender: AgentProfile
        let recipient: AgentProfile
        let messenger: AgentMessenger
        let store: AgentImageStore
        let registry = ProviderRegistry()
        let origin = UUID()
        let probe = ImagePeerProbe()
        func session(approve: Bool = true, groups: GroupService? = nil) -> AgentMessagingSession {
            .init(originConversationID: origin, agents: agents, messenger: messenger, registry: registry,
                coordinator: TurnCoordinator(registry: registry, toolCatalog: ToolCatalog()), groups: groups,
                imageStore: store, authorizeImages: { _, _, _, images, _, _ in
                    await probe.approve(images)
                    if !approve { throw AgentMessagingError.approvalRequired }
                })
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-peer-images-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", providerID: "image-peer", modelID: "test")
        let recipient = try await agents.create(name: "Recipient", providerID: "image-peer", modelID: "test")
        return try .init(root: root, agents: agents, sender: sender, recipient: recipient,
            messenger: AgentMessenger(service: agents, storeURL: root.appending(path: "messages.json")),
            store: AgentImageStore(rootURL: root.appending(path: "images")))
    }

    @Test(arguments: ["public.png", "public.jpeg"])
    func bytesNotExtensionDetermineImageTypeAndSurviveRestart(type: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try peerImageBytes(type: type)
        let file = f.root.appending(path: "not-an-image.txt")
        try bytes.write(to: file)
        let metadata = try await f.store.importImage(fileURL: file)
        expectNoDifference(metadata.mimeType, type == "public.png" ? "image/png" : "image/jpeg")
        let restored = AgentImageStore(rootURL: f.root.appending(path: "images"))
        let loaded = try await restored.load([metadata])
        expectNoDifference(loaded.map(\.data), [bytes])
        #expect(!String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self).contains(f.root.path))
        let session = f.session()
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Image", images: [metadata])
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let messages = await reopened.allMessages()
        expectNoDifference(messages.first?.images?.map(\.id), [metadata.id])
        expectNoDifference(messages.first?.delivery?.state, .cancelled)
        try await session.close()
    }

    @Test func invalidOversizedSymlinkRemoteDuplicateAndAggregateInputsAreRejected() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        await #expect(throws: AgentImageError.invalid) { _ = try await f.store.importImage(data: Data("not a png".utf8), filename: "fake.png") }
        await #expect(throws: AgentImageError.limit) { _ = try await f.store.importImage(data: Data(count: AgentImageStore.maximumBytes + 1), filename: "huge.png") }
        await #expect(throws: AgentImageError.invalid) { _ = try await f.store.importImage(fileURL: URL(string: "https://example.invalid/private.png")!) }
        let file = f.root.appending(path: "image.png"), link = f.root.appending(path: "link.png")
        try peerImageBytes().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: AgentImageError.invalid) { _ = try await f.store.importImage(fileURL: link) }
        await #expect(throws: AgentImageError.invalid) { _ = try await f.store.importImage(fileURL: f.root) }
        let image = try await f.store.importImage(fileURL: file)
        await #expect(throws: AgentImageError.limit) { _ = try await f.store.load([image, image]) }
        let oversizedTotal = (0..<3).map { index in
            AttachmentMetadata(id: "\(index)", filename: "x.png", mimeType: "image/png", byteCount: Int64(AgentImageStore.maximumBytes), kind: .image)
        }
        await #expect(throws: AgentImageError.limit) { _ = try await f.store.load(oversizedTotal) }
        await #expect(throws: AgentImageError.limit) { _ = try await f.store.load(Array(repeating: image, count: 5)) }
    }

    @Test func corruptStoredBytesAndMismatchedMimeCannotReachInference() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "real.png")
        let spoof = AttachmentMetadata(id: image.id, filename: image.filename, mimeType: "image/jpeg", byteCount: image.byteCount, kind: .image)
        await #expect(throws: AgentImageError.invalid) { _ = try await f.store.load([spoof]) }
        let blob = f.root.appending(path: "images/\(image.id.prefix(2))/\(image.id)")
        try Data(repeating: 0, count: Int(image.byteCount)).write(to: blob)
        await #expect(throws: AttachmentStoreError.corrupt(image.id)) { _ = try await f.store.load([image]) }
        await #expect(throws: AttachmentStoreError.corrupt(image.id)) {
            try await f.session().enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Must fail", images: [image])
        }
        let messages = await f.messenger.allMessages(); expectNoDifference(messages, [])
    }

    @Test(arguments: ["valid", "exact", "reordered", "priority"])
    func actualImageBytesReachPeerAndApprovedReplyExactlyOnceButNotLaterHistory(replay: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try peerImageBytes(), other = try peerImageBytes(shade: 0.75)
        let images = try await [f.store.importImage(data: bytes, filename: "first.png"), f.store.importImage(data: other, filename: "second.png")]
        let session = f.session()
        await f.registry.register(ImagePeerProvider { request, tool in
            let count = await f.probe.request(request)
            let attached = request.messages.filter { !$0.attachments.isEmpty }
            if count <= 2 {
                let transport = try #require(attached.first)
                expectNoDifference(transport.role, .user)
                #expect(transport.text.contains("NOT a new user request"))
                expectNoDifference(request.attachmentsByMessageID[transport.id]?.map(\.data), [bytes, other])
                expectNoDifference(request.messages.last?.role, .assistant)
                #expect(!request.messages.map(\.text).joined().contains(f.root.path))
            } else {
                expectNoDifference(attached.count, 0)
                expectNoDifference(request.attachmentsByMessageID.count, 0)
            }
            if count == 1 {
                let call = try forwardImage(f.sender.id, ids: images.map(\.id))
                let sent = try await tool(call); #expect(!sent.isError)
                // The real ToolLoop rejects every repeated call ID before the
                // executor. Already accepted sends must still run exactly once.
                if replay == "exact" {
                    _ = try await tool(call)
                } else if replay == "reordered" {
                    _ = try await tool(forwardImage(f.sender.id, ids: images.reversed().map(\.id)))
                } else if replay == "priority" {
                    _ = try await tool(forwardImage(f.sender.id, ids: images.map(\.id), priority: true))
                }
                #expect(try await tool(forwardImage(f.sender.id, ids: images.map(\.id), id: "duplicate")).isError)
            } else if count == 2 {
                let reply = try await tool(forwardImage(f.recipient.id, ids: [], id: "text-reply")); #expect(!reply.isError)
            } else {
                let stale = try await tool(forwardImage(f.sender.id, ids: images.map(\.id), id: "stale"))
                #expect(stale.isError && stale.wireText.contains(AgentImageError.unavailable.rawValue))
            }
            return "PASS"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Look at these", images: images)
        try await session.drain()
        let requests = await f.probe.requests, approvals = await f.probe.approvals, messages = await f.messenger.allMessages()
        expectNoDifference(requests.count, 3)
        expectNoDifference(approvals, [images]) // Even a reply needs fresh image approval.
        expectNoDifference(messages.map { $0.images?.map(\.id) ?? [] }, [images.map(\.id), images.map(\.id), []])
        // The outer ToolLoop flags a reused call ID as a
        // failed turn, while retaining and delivering the original approved send.
        expectNoDifference(messages.map { $0.delivery?.state }, [replay == "valid" ? .completed : .failed, .completed, .completed])
        if replay != "valid" { #expect(messages.first?.delivery?.response?.contains("Duplicate tool call ID") == true) }
        try await session.close()
    }

    @Test func missingCurrentCapabilityDeniedApprovalAndGroupTargetDoNotForward() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Team", memberIDs: [f.sender.id, f.recipient.id])
        let session = f.session(approve: false, groups: groups)
        let outside = try await session.tool(for: f.sender.id).execute(forwardImage(f.recipient.id, ids: [image.id]), context: .init(conversationID: f.origin))
        #expect(outside.isError) // Stored blobs do not themselves grant forwarding authority.
        await f.registry.register(ImagePeerProvider { _, tool in
            for invalid in ["file:///private.png", "https://example.invalid/image", "data:image/png;base64,AAAA", "other-message-id"] {
                #expect(try await tool(forwardImage(f.sender.id, ids: [invalid], id: ToolCallID(rawValue: invalid))).isError)
            }
            let grouped = try await tool(forwardImage(group.id, ids: [image.id], id: "group"))
            #expect(grouped.isError && grouped.wireText.contains(AgentImageError.group.rawValue))
            #expect(try await tool(forwardImage(f.sender.id, ids: [image.id])).isError)
            return "PASS"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Look", images: [image])
        try await session.drain()
        let messages = await f.messenger.allMessages(), approvals = await f.probe.approvals
        expectNoDifference(messages.count, 1); expectNoDifference(approvals.count, 1)
        try await session.close()
    }

    @Test func textOnlyModelFailsExplicitlyWithoutInferenceOrImageLoss() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png"), session = f.session()
        await f.registry.register(ImagePeerProvider(supportsImages: false) { request, _ in
            _ = await f.probe.request(request); return "SHOULD NOT RUN"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Look", images: [image])
        try await session.drain()
        let messages = await f.messenger.allMessages(), requests = await f.probe.requests
        expectNoDifference(requests.count, 0)
        expectNoDifference(messages.first?.delivery?.state, .failed)
        expectNoDifference(messages.first?.delivery?.response, AgentImageError.unsupported.rawValue)
        expectNoDifference(messages.first?.images?.map(\.id), [image.id])
        try await session.close()
    }

    @Test func oldMessageWithoutImageFieldStillDecodes() throws {
        let old = AgentMessage(senderID: UUID(), recipientID: UUID(), text: "Old text")
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data, as: UTF8.self).contains("images"))
        let restored = try JSONDecoder().decode(AgentMessage.self, from: data)
        expectNoDifference(restored.images, nil); expectNoDifference(restored.text, old.text)
    }
}
