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

private actor ImagePublicationProbe {
    var values: [RoomMessage] = []
    func append(_ value: RoomMessage) { values.append(value) }
}

private struct ImageGroupPublicationResponder: GroupAgentResponder {
    let run: @Sendable (@escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("GroupService must use the publication callback")
        return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onPublication: @escaping @Sendable (GroupAgentPublication) async throws -> Void) async throws -> [String] {
        try await run(onPublication)
    }
}

private func publishImage(_ ids: [String], text: String = "Reviewed layout", id: ToolCallID = "publish") throws -> NormalizedToolCall {
    struct Payload: Encodable { let text: String; let images: [String] }
    return try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(Payload(text: text, images: ids)))
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

    @Test(arguments: ["valid", "wrong-source", "foreign-image", "missing-lifetime", "revoked", "save-failure"])
    func canonicalGroupPublicationFencesSourceRevocationAndPersistence(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.root.appending(path: "groups.json")
        let groups = try GroupService(agents: f.agents, storeURL: file)
        let group = try await groups.create(name: "Review", memberIDs: [f.sender.id])
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let foreign = try await f.store.importImage(data: peerImageBytes(shade: 0.75), filename: "foreign.png")
        let user = try await groups.postUserMessage("Review", groupID: group.id, images: [image])
        let lifetime = AgentPublicationLifetime()
        let responder = ImageGroupPublicationResponder { publish in
            if mode == "revoked" { lifetime.close() }
            let backup = f.root.appending(path: "groups.backup")
            if mode == "save-failure" {
                try FileManager.default.moveItem(at: file, to: backup)
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            }
            defer {
                if mode == "save-failure" {
                    try? FileManager.default.removeItem(at: file)
                    try? FileManager.default.moveItem(at: backup, to: file)
                }
            }
            try await publish(.init(text: "Reviewed layout", images: [mode == "foreign-image" ? foreign : image],
                                    sourceUserMessageID: mode == "wrong-source" ? UUID() : user.id,
                                    lifetime: mode == "missing-lifetime" ? nil : lifetime))
            return []
        }
        if mode == "valid" {
            let result = try await groups.run(groupID: group.id, responder: responder)
            expectNoDifference(result.map(\.senderID), [f.sender.id])
            expectNoDifference(result.map(\.groupID), [group.id])
            expectNoDifference(result.first?.images?.map(\.id), [image.id])
        } else {
            await #expect(throws: (any Error).self) { _ = try await groups.run(groupID: group.id, responder: responder) }
        }
        let messages = await groups.messages(groupID: group.id)
        let saved = messages.filter { $0.senderID != nil && $0.images?.isEmpty == false }
        expectNoDifference(saved.count, mode == "valid" ? 1 : 0)
        let reopened = try GroupService(agents: f.agents, storeURL: file)
        let restored = await reopened.messages(groupID: group.id)
        expectNoDifference(restored.filter { $0.senderID != nil && $0.images?.isEmpty == false }.map(\.id), saved.map(\.id))
    }

    @Test(arguments: ["new-request", "membership", "missing-authorizer"])
    func groupPublisherRejectsStaleImagesAndMissingApproval(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Review", memberIDs: [f.sender.id, f.recipient.id])
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let user = try await groups.postUserMessage("@Sender review", groupID: group.id, images: [image])
        let output = ImagePublicationProbe()
        let session: AgentMessagingSession
        if change == "missing-authorizer" { session = .init(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()), groups: groups, imageStore: f.store) }
        else { session = .init(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            groups: groups, imageStore: f.store, authorizePublication: { _, _, _, _, _ in
                if change == "new-request" { _ = try await groups.postUserMessage("Follow up", groupID: group.id) }
                else { try await groups.updateMembers(groupID: group.id, memberIDs: [f.recipient.id]) }
            }) }
        let tool = try await session.groupPublisher(for: f.sender.id, userMessageID: user.id) { value in
            await output.append(.init(groupID: group.id, senderID: f.sender.id, text: value.text, images: value.images))
        }
        #expect(try await tool.execute(publishImage([image.id]), context: .init(conversationID: group.id)).isError)
        let values = await output.values
        expectNoDifference(values, [])
        try await session.close()
    }

    @Test(arguments: ["approve", "deny", "revoke", "new-request"])
    func quotedImageReplyRetainsPreviewApprovalAndSourceFences(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Review", memberIDs: [f.sender.id])
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let old = try await groups.postUserMessage("Previous request", groupID: group.id)
        let user = try await groups.postUserMessage("Review this image", groupID: group.id, images: [image])
        let session = AgentMessagingSession(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            groups: groups, imageStore: f.store, authorizePublication: { _, _, images, _, _ in
                await f.probe.approve(images)
                if mode == "deny" { throw AgentMessagingError.approvalRequired }
                if mode == "new-request" { _ = try await groups.postUserMessage("Moved on", groupID: group.id) }
            })
        let responder = ImageGroupPublicationResponder { publish in
            let tool = try await session.groupPublisher(for: f.sender.id, userMessageID: user.id,
                replyHistory: [old, user], publish: publish)
            if mode == "revoke" { session.revokeProfileChanges() }
            let raw: [String: Any] = ["text": "Reviewed layout", "images": [image.id], "reply_to": old.id.uuidString]
            let call = try NormalizedToolCall(id: "quote-image", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: raw))
            if mode == "revoke" {
                await #expect(throws: CancellationError.self) { try await tool.execute(call, context: .init(conversationID: group.id)) }
            } else {
                let result = try await tool.execute(call, context: .init(conversationID: group.id))
                expectNoDifference(result.isError, mode != "approve")
            }
            return []
        }
        _ = try await groups.run(groupID: group.id, responder: responder)
        let messages = await groups.messages(groupID: group.id)
        let replies = messages.filter { $0.replyToMessageID != nil }
        expectNoDifference(replies.count, mode == "approve" ? 1 : 0)
        if mode == "approve" {
            expectNoDifference(replies.first?.replyToMessageID, old.id)
            expectNoDifference(replies.first?.images, [image])
        }
        let approvals = await f.probe.approvals
        expectNoDifference(approvals, [[image]])
        try await session.close()
    }

    @Test func groupForwardingOnlyExposesTheAddressedCurrentRequest() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Review", memberIDs: [f.sender.id, f.recipient.id])
        let other = try await groups.create(name: "Other room", memberIDs: [f.sender.id])
        let oldImage = try await f.store.importImage(data: peerImageBytes(), filename: "old.png")
        let image = try await f.store.importImage(data: peerImageBytes(shade: 0.75), filename: "current.png")
        let old = try await groups.postUserMessage("@Sender old", groupID: group.id, images: [oldImage])
        let foreign = try await groups.postUserMessage("@Sender foreign", groupID: other.id, images: [oldImage])
        let current = try await groups.postUserMessage("@Sender review", groupID: group.id, images: [image])
        let session = AgentMessagingSession(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            groups: groups, imageStore: f.store, authorizeImages: { _, _, _, images, _, _ in await f.probe.approve(images) })
        let context = ToolContext(conversationID: group.id)
        for id in [old.id, foreign.id, UUID()] {
            let tool = session.tool(for: f.sender.id, groupUserMessageID: id)
            #expect(try await tool.execute(forwardImage(f.recipient.id, ids: [image.id]), context: context).isError)
        }
        let unaddressed = session.tool(for: f.recipient.id, groupUserMessageID: current.id)
        #expect(try await unaddressed.execute(forwardImage(f.sender.id, ids: [image.id]), context: context).isError)
        let unbound = session.tool(for: f.sender.id) // Used by delegated room wakes; never inherits source images.
        #expect(try await unbound.execute(forwardImage(f.recipient.id, ids: [image.id]), context: context).isError)
        let unboundContext = try #require(unbound as? any ToolRuntimeContextProviding)
        let unboundDirectory = try await unboundContext.runtimeContext(for: context)
        #expect(!unboundDirectory.contains(image.id) && !unboundDirectory.contains(oldImage.id))
        let tool = session.tool(for: f.sender.id, groupUserMessageID: current.id)
        let runtime = try #require(tool as? any ToolRuntimeContextProviding)
        let directory = try await runtime.runtimeContext(for: context)
        #expect(directory.contains(image.id) && !directory.contains(oldImage.id))
        for id in [oldImage.id, "file:///private.png", "https://example.invalid/private.png"] {
            #expect(try await tool.execute(forwardImage(f.recipient.id, ids: [id]), context: context).isError)
        }
        #expect(try await tool.execute(forwardImage(other.id, ids: [image.id]), context: context).isError)
        let approvalsBeforeSend = await f.probe.approvals
        expectNoDifference(approvalsBeforeSend, [])
        let call = try forwardImage(f.recipient.id, ids: [image.id])
        let accepted = try await tool.execute(call, context: context)
        #expect(!accepted.isError)
        let replay = try await tool.execute(call, context: context)
        expectNoDifference(replay, accepted)
        let approvals = await f.probe.approvals
        expectNoDifference(approvals, [[image]])
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.map { $0.images?.map(\.id) }, [[image.id]])
        expectNoDifference(messages.first?.delivery?.originConversationID, group.id)
        try await session.close()
    }

    @Test(arguments: ["new-request", "membership"])
    func groupImageSourceIsRevalidatedAfterApproval(change: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Review", memberIDs: [f.sender.id, f.recipient.id])
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let current = try await groups.postUserMessage("@Sender review", groupID: group.id, images: [image])
        let session = AgentMessagingSession(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            groups: groups, imageStore: f.store, authorizeImages: { _, _, _, images, _, _ in
                await f.probe.approve(images)
                if change == "new-request" { _ = try await groups.postUserMessage("Follow up without images", groupID: group.id) }
                else { try await groups.updateMembers(groupID: group.id, memberIDs: [f.recipient.id]) }
            })
        let tool = session.tool(for: f.sender.id, groupUserMessageID: current.id)
        let result = try await tool.execute(forwardImage(f.recipient.id, ids: [image.id]), context: .init(conversationID: group.id))
        #expect(result.isError)
        let approvals = await f.probe.approvals, messages = await f.messenger.allMessages()
        expectNoDifference(approvals, [[image]])
        expectNoDifference(messages, [])
        try await session.close()
    }

    @Test func imagePublicationIsBoundedScopedAndIdempotent() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let images = try await [f.store.importImage(data: peerImageBytes(), filename: "first.png"),
                               f.store.importImage(data: peerImageBytes(shade: 0.75), filename: "second.png")]
        let output = ImagePublicationProbe(), context = ToolContext(conversationID: f.origin)
        let tool = AgentUserMessageTool(conversationID: f.origin, availableImages: images, imageStore: f.store,
            authorizeImages: { _, values, _, _ in await f.probe.approve(values) }) { text, values in
                await output.append(.init(groupID: f.origin, senderID: f.recipient.id, text: text, images: values))
            }
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?["images"] != nil)
        let runtime = try await tool.runtimeContext(for: context)
        #expect(runtime.contains(images[0].id) && !runtime.contains(f.root.path))
        for id in ["file:///private.png", "https://example.invalid/private.png", "old-image"] {
            #expect(try await tool.execute(publishImage([id]), context: context).isError)
        }
        #expect(try await tool.execute(publishImage([images[0].id, images[0].id]), context: context).isError)
        let call = try publishImage(images.map(\.id))
        let first = try await tool.execute(call, context: context)
        #expect(!first.isError)
        let replay = try await tool.execute(call, context: context)
        expectNoDifference(replay, first)
        #expect(try await tool.execute(publishImage(images.reversed().map(\.id)), context: context).isError)
        #expect(try await tool.execute(publishImage(images.reversed().map(\.id), id: "duplicate"), context: context).isError)
        let textOnly = try NormalizedToolCall(id: "text", name: "SendMessage", argumentsJSON: Data(#"{"text":"Final report"}"#.utf8))
        #expect(!(try await tool.execute(textOnly, context: context).isError))
        #expect(try await tool.execute(publishImage([images[0].id], text: "Third", id: "third"), context: context).isError)
        let approvals = await f.probe.approvals, values = await output.values
        expectNoDifference(approvals, [images])
        expectNoDifference(values.map(\.text), ["Reviewed layout", "Final report"])
        expectNoDifference(values.map { $0.images?.map(\.id) ?? [] }, [images.map(\.id), []])
    }

    @Test func missingPublicationAuthorizerDeniesImages() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let output = ImagePublicationProbe()
        let tool = AgentUserMessageTool(conversationID: f.origin, availableImages: [image], imageStore: f.store) { text, images in
            await output.append(.init(groupID: f.origin, senderID: nil, text: text, images: images))
        }
        #expect(try await tool.execute(publishImage([image.id]), context: .init(conversationID: f.origin)).isError)
        let values = await output.values; expectNoDifference(values, [])
    }

    @Test(arguments: ["completed", "failure", "projection"])
    func publicationPersistsAcrossSessionFailureAndRestart(mode: String) async throws {
        struct ProjectionFailure: Error {}
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let projected = ImagePublicationProbe()
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            imageStore: f.store, authorizePublication: { _, text, images, _, _ in
                expectNoDifference(text, "Reviewed layout"); await f.probe.approve(images)
            })
        await f.registry.register(ImagePeerProvider { request, execute in
            _ = await f.probe.request(request)
            let result = try await execute(publishImage([image.id]))
            #expect(!result.isError) // A failed mirror must not invite a duplicate of the committed publication.
            if mode == "failure" { throw ProviderError.invalidResponse }
            return "Reviewed layout" // Must not be repeated in the final projection.
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Review", images: [image])
        try await session.drain(onUpdate: { message in
            if message.images?.isEmpty == false && mode == "projection" { throw ProjectionFailure() }
            await projected.append(message)
        })
        let messages = await f.messenger.allMessages(), approvals = await f.probe.approvals
        expectNoDifference(messages.count, 1) // SendMessage never wakes a peer.
        expectNoDifference(approvals, [[image]])
        let delivery = try #require(messages.first?.delivery)
        expectNoDifference(delivery.state, mode == "completed" ? .completed : .failed)
        expectNoDifference(delivery.response, "Reviewed layout")
        expectNoDifference(delivery.publications?.map { $0.images?.map(\.id) }, [[image.id]])
        let visible = await projected.values.filter { !$0.text.isEmpty }
        expectNoDifference(visible.count, mode == "projection" ? 0 : 1)
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let restored = await reopened.allMessages()
        expectNoDifference(restored.first?.delivery?.publications?.map(\.id), delivery.publications?.map(\.id))
        let loaded = try await f.store.load(restored.first?.delivery?.publications?.first?.images ?? [])
        expectNoDifference(loaded.count, 1)
        try await session.close()
    }

    @Test func canonicalPublicationChecksIdentityRevocationAtomicSaveAndRecovery() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "review.png")
        let inbound = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Review",
            delivery: .init(chainID: UUID(), originConversationID: f.origin), images: [image])
        try await f.messenger.send(inbound)
        try await f.messenger.updateDelivery(id: inbound.id, state: .running)
        let lifetime = AgentPublicationLifetime()
        let publication = RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Reviewed", images: [image])
        let invalid = [RoomMessage(groupID: UUID(), senderID: f.recipient.id, text: "Wrong room"),
                       RoomMessage(groupID: f.origin, senderID: f.sender.id, text: "Spoofed author"),
                       RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Unknown image", images: [.init(id: "unknown", filename: "x.png", mimeType: "image/png", byteCount: 10, kind: .image)])]
        for value in invalid {
            await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publish(value, replyingTo: inbound.id, lifetime: lifetime) }
        }
        // Make only this fixture's mailbox destination unwritable as a file.
        let file = f.root.appending(path: "messages.json"), backup = f.root.appending(path: "messages.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await f.messenger.publish(publication, replyingTo: inbound.id, lifetime: lifetime) }
        let unsaved = await f.messenger.allMessages()
        expectNoDifference(unsaved.first?.delivery?.publications, nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try await f.messenger.publish(publication, replyingTo: inbound.id, lifetime: lifetime)
        try await f.messenger.publish(publication, replyingTo: inbound.id, lifetime: lifetime)
        var changed = publication; changed.text = "Changed"
        await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publish(changed, replyingTo: inbound.id, lifetime: lifetime) }
        let second = RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Follow-up")
        try await f.messenger.publish(second, replyingTo: inbound.id, lifetime: lifetime)
        let third = RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Over limit")
        await #expect(throws: AgentPublicationError.limit) { try await f.messenger.publish(third, replyingTo: inbound.id, lifetime: lifetime) }
        lifetime.close()
        await #expect(throws: CancellationError.self) { try await f.messenger.publish(publication, replyingTo: inbound.id, lifetime: lifetime) }
        let reopened = try AgentMessenger(service: f.agents, storeURL: file)
        let restored = await reopened.allMessages()
        expectNoDifference(restored.first?.delivery?.state, .cancelled)
        expectNoDifference(restored.first?.delivery?.publications?.map(\.id), [publication.id, second.id])
        expectNoDifference(restored.first?.delivery?.response, "Reviewed\n\nFollow-up")
        await #expect(throws: AgentPublicationError.invalid) {
            try await reopened.publish(third, replyingTo: inbound.id, lifetime: AgentPublicationLifetime())
        }
    }

    @Test func oldTextPublicationsAndRoomMessagesDecodeWithoutImages() throws {
        let delivery = AgentMessageDelivery(chainID: UUID(), originConversationID: UUID(), state: .completed, response: "Old reply")
        let encoded = try JSONEncoder().encode(delivery)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("publications"))
        let decoded = try JSONDecoder().decode(AgentMessageDelivery.self, from: encoded)
        expectNoDifference(decoded, delivery)
        let room = RoomMessage(groupID: UUID(), senderID: nil, text: "Old room message")
        let roomData = try JSONEncoder().encode(room)
        #expect(!String(decoding: roomData, as: UTF8.self).contains("images"))
        let restored = try JSONDecoder().decode(RoomMessage.self, from: roomData)
        expectNoDifference(restored, room)
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
