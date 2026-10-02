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
    var directImages: [AttachmentMetadata] = []
    func setDirectImages(_ images: [AttachmentMetadata]) { directImages = images }
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

private struct ImageGroupSavedPublicationResponder: GroupAgentResponder {
    let run: @Sendable (@escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("GroupService must use the saved publication callback")
        return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        try await run(onSavedPublication)
    }
}

private func publishImage(_ ids: [String], text: String = "Reviewed layout", id: ToolCallID = "publish") throws -> NormalizedToolCall {
    struct Payload: Encodable { let text: String; let images: [String] }
    return try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(Payload(text: text, images: ids)))
}

private func publishStandaloneImage(_ imageID: String, id: ToolCallID = "standalone", alt: String? = nil) throws -> NormalizedToolCall {
    struct Payload: Encodable { let type = "attachment"; let image_id: String; let alt: String? }
    return try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(Payload(image_id: imageID, alt: alt)))
}

private func forwardImage(_ target: UUID, ids: [String], id: ToolCallID = "forward", priority: Bool = false) throws -> NormalizedToolCall {
    struct Payload: Encodable { let recipientID: UUID; let message = "Review these images"; let images: [String]; let priority: Bool }
    return try .init(id: id, name: "SendToAgent", argumentsJSON: JSONEncoder().encode(Payload(recipientID: target, images: ids, priority: priority)))
}

@Suite("Peer image storage and delivery", .timeLimit(.minutes(1)))
struct AgentImageMessagingTests {
    @Test(arguments: ["valid", "misleading", "root-link", "shard-link", "blob-link", "corrupt-existing"])
    func capturedGalleryStorageRejectsUnsafeCAS(mode: String) async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appending(path: "filicon-captured-gallery-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let imageRoot = root.appending(path: "images"), outside = root.appending(path: "outside")
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appending(path: "marker")
        let markerBytes = Data("Must remain unchanged".utf8)
        try markerBytes.write(to: marker)
        let bytes = try peerImageBytes()
        let prepared = try PreparedAgentGalleryImage(bytes: bytes,
            filename: mode == "misleading" ? "image.txt" : "image.png", altText: "Captured image")
        let shard = imageRoot.appending(path: String(prepared.file.digest.prefix(2)))
        if mode == "root-link" {
            try manager.createSymbolicLink(at: imageRoot, withDestinationURL: outside)
        } else {
            try manager.createDirectory(at: imageRoot, withIntermediateDirectories: true)
            if mode == "shard-link" {
                try manager.createSymbolicLink(at: shard, withDestinationURL: outside)
            } else if ["blob-link", "corrupt-existing"].contains(mode) {
                try manager.createDirectory(at: shard, withIntermediateDirectories: true)
                let blob = shard.appending(path: prepared.file.digest)
                if mode == "blob-link" { try manager.createSymbolicLink(at: blob, withDestinationURL: marker) }
                else { try Data(repeating: 0, count: bytes.count).write(to: blob) }
            }
        }
        let store = AgentImageStore(rootURL: imageRoot), createdAt = Date(timeIntervalSince1970: 1_000)
        if ["valid", "misleading"].contains(mode) {
            let expected = AttachmentMetadata(id: prepared.file.digest, filename: prepared.file.filename,
                mimeType: "image/png", byteCount: Int64(bytes.count), kind: .image,
                createdAt: createdAt, altText: prepared.altText)
            let saved = try await store.importCapturedGalleryImage(prepared, createdAt: createdAt)
            expectNoDifference(saved, expected)
            let repeated = try await store.importCapturedGalleryImage(prepared, createdAt: createdAt)
            expectNoDifference(repeated, expected)
            let loaded = try await store.load([saved])
            expectNoDifference(loaded, [InferenceAttachment(metadata: expected, data: bytes)])
            let inventory = try await store.storageInventory()
            expectNoDifference(inventory, AttachmentStoreInventory(active: [prepared.file.digest: Int64(bytes.count)],
                quarantined: [:], temporaryFiles: []))
        } else {
            await #expect(throws: (any Error).self) {
                try await store.importCapturedGalleryImage(prepared, createdAt: createdAt)
            }
        }
        expectNoDifference(try Data(contentsOf: marker), markerBytes)
        expectNoDifference(try manager.contentsOfDirectory(atPath: outside.path), ["marker"])
    }

    @Test func capturedGalleryImageMIMEMustMatchDecodedBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-captured-mime-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try PreparedAgentPublicationFile(bytes: peerImageBytes(), filename: "misleading.jpeg")
        let store = AttachmentStore(rootURL: root)
        await #expect(throws: AttachmentStoreError.self) {
            try await store.ingest(prepared: prepared, createdAt: Date(timeIntervalSince1970: 1_000),
                verifiedImageMIMEType: "image/jpeg")
        }
        expectNoDifference(FileManager.default.fileExists(atPath: root.path), false)
    }

    private actor FileDispatchFence {
        var active = true
        func revoke() { active = false }
        func check() throws { if !active { throw CancellationError() } }
    }

    @Test(arguments: ["valid", "denied", "revoked", "wrong-incoming", "wrong-origin", "wrong-sender", "missing", "projection", "failure", "duplicate-call"])
    func mailboxGalleryTransactionPublishesCanonicalReceipt(mode: String) async throws {
        struct ProjectionFailure: Error {}
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let fence = FileDispatchFence()
        let projected = ImagePublicationProbe()
        let gallery = try RemoteImageGallery(images: [RemoteAttachmentReference(url: "https://example.com/a", alt: "A"),
            RemoteAttachmentReference(url: "https://example.com/b", alt: "B")])
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            supportsMailboxQuestions: true, mailboxGallery: { inbound in
                if mode == "missing" { return nil }
                return AgentMailboxGalleryServices(incomingID: mode == "wrong-incoming" ? UUID() : inbound.id,
                    originID: mode == "wrong-origin" ? UUID() : f.origin,
                    senderID: mode == "wrong-sender" ? f.sender.id : f.recipient.id,
                    validate: { try await fence.check() }, authorize: { sender, review, _, context in
                        expectNoDifference(sender.id, f.recipient.id)
                        expectNoDifference(review.text, "Designs")
                        expectNoDifference(review.gallery, Optional(gallery))
                        expectNoDifference(context.conversationID, f.origin)
                        if mode == "denied" { throw CancellationError() }
                        if mode == "revoked" { await fence.revoke() }
                    })
            })
        let succeeds = ["valid", "projection", "failure", "duplicate-call"].contains(mode)
        await f.registry.register(ImagePeerProvider { _, execute in
            let args: [String: Any] = ["type": "text", "content": "Designs",
                "images": [["url": "https://example.com/a", "alt": "A"], ["url": "https://example.com/b", "alt": "B"]]]
            let call = try NormalizedToolCall(id: "gallery", name: "SendMessage",
                argumentsJSON: JSONSerialization.data(withJSONObject: args))
            let result = try await execute(call)
            expectNoDifference(result.isError, !succeeds)
            if succeeds {
                let messages = await f.messenger.allMessages()
                let incoming = try #require(messages.first)
                let saved = try #require(incoming.delivery?.publications?.first)
                expectNoDifference(saved.remoteImages, gallery)
                expectNoDifference(saved.text, "Designs")
                let directory = try await f.messenger.replyDirectory(replyingTo: incoming.id)
                let address = try #require(directory.first(where: { $0.id == saved.id })?.shortAddress)
                #expect(result.wireText.contains(address))
            }
            if mode == "duplicate-call" {
                let replay = try await execute(call)
                expectNoDifference(replay, result)
            }
            if mode == "failure" { throw ProviderError.invalidResponse }
            return "PASS"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Share designs")
        do { try await session.drain(onUpdate: { message in
            if message.remoteImages != nil {
                if mode == "projection" { throw ProjectionFailure() }
                await projected.append(message)
            }
        }) }
        catch { #expect(["denied", "revoked"].contains(mode) && error is CancellationError) }
        let messages = await f.messenger.allMessages()
        let galleries = messages.flatMap { $0.delivery?.publications ?? [] }.compactMap(\.remoteImages)
        expectNoDifference(galleries, succeeds ? [gallery] : [])
        let visible = await projected.values
        expectNoDifference(visible.compactMap(\.remoteImages), succeeds && mode != "projection" ? [gallery] : [])
        if mode == "projection" || mode == "failure" {
            expectNoDifference(messages.first?.delivery?.state, .failed)
        }
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let restored = await reopened.allMessages()
        expectNoDifference(restored.flatMap { $0.delivery?.publications ?? [] }.compactMap(\.remoteImages), galleries)
        try await session.close()
    }

    @Test(arguments: ["valid", "denied", "revoked", "wrong-incoming", "wrong-origin", "wrong-sender", "missing", "failure", "duplicate-call"])
    func mailboxRemoteTransactionPublishesCanonicalReceipt(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let fence = FileDispatchFence()
        let reference = try RemoteAttachmentReference(url: "https://example.com/report?sig=a%2Bb", alt: "報表")
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            supportsMailboxQuestions: true, mailboxRemote: { inbound in
                if mode == "missing" { return nil }
                return AgentMailboxRemoteServices(incomingID: mode == "wrong-incoming" ? UUID() : inbound.id,
                    originID: mode == "wrong-origin" ? UUID() : f.origin,
                    senderID: mode == "wrong-sender" ? f.sender.id : f.recipient.id,
                    validate: { try await fence.check() }, authorize: { sender, review, _, context in
                        expectNoDifference(sender.id, f.recipient.id)
                        expectNoDifference(review.reference, reference)
                        expectNoDifference(context.conversationID, f.origin)
                        if mode == "denied" { throw CancellationError() }
                        if mode == "revoked" { await fence.revoke() }
                    })
            })
        let succeeds = ["valid", "failure", "duplicate-call"].contains(mode)
        await f.registry.register(ImagePeerProvider { _, execute in
            let call = try NormalizedToolCall(id: "remote", name: "SendMessage",
                argumentsJSON: JSONSerialization.data(withJSONObject: ["type": "attachment", "url": reference.url, "alt": "報表"]))
            let result = try await execute(call)
            expectNoDifference(result.isError, !succeeds)
            if succeeds {
                let messages = await f.messenger.allMessages()
                let incoming = try #require(messages.first)
                let saved = try #require(incoming.delivery?.publications?.first)
                let directory = try await f.messenger.replyDirectory(replyingTo: incoming.id)
                let address = try #require(directory.first(where: { $0.id == saved.id })?.shortAddress)
                #expect(result.wireText.contains(address))
            }
            if mode == "duplicate-call" { _ = try await execute(call) }
            if mode == "failure" { throw ProviderError.invalidResponse }
            return "PASS"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Share report")
        do { try await session.drain(onUpdate: { _ in }) }
        catch { #expect(["denied", "revoked"].contains(mode) && error is CancellationError) }
        let messages = await f.messenger.allMessages()
        let remotes = messages.flatMap { $0.delivery?.publications ?? [] }.compactMap(\.remoteAttachment)
        expectNoDifference(remotes, succeeds ? [reference] : [])
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let restored = await reopened.allMessages()
        expectNoDifference(restored.flatMap { $0.delivery?.publications ?? [] }.compactMap(\.remoteAttachment), remotes)
        try await session.close()
    }

    @Test(arguments: ["valid", "denied", "revoked", "wrong-incoming", "wrong-origin", "wrong-sender", "missing", "projection", "failure", "duplicate-call"])
    func mailboxFileTransactionPublishesCanonicalReceipt(mode: String) async throws {
        struct ProjectionFailure: Error {}
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let prepared = try PreparedAgentPublicationFile(bytes: Data("Mailbox report".utf8), filename: "report.txt")
        let store = AttachmentStore(rootURL: f.root.appending(path: "files"))
        let fence = FileDispatchFence()
        let projected = ImagePublicationProbe()
        let services = AgentFilePublicationServices(prepare: { sender, _, _, context in
            expectNoDifference(sender.id, f.recipient.id)
            expectNoDifference(context.conversationID, f.origin)
            return prepared
        }, authorize: { _, review, _, _ in
            expectNoDifference(review.conversationID, f.origin)
            if mode == "denied" { throw CancellationError() }
            if mode == "revoked" { await fence.revoke() }
        }, commit: { review, _, _, save in
            let metadata = try await store.ingest(prepared: review.file, createdAt: Date(timeIntervalSince1970: 123))
            return try await save(metadata, UUID())
        })
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            supportsMailboxQuestions: true, mailboxFiles: { inbound in
                if mode == "missing" { return nil }
                return AgentMailboxFileServices(incomingID: mode == "wrong-incoming" ? UUID() : inbound.id,
                    originID: mode == "wrong-origin" ? UUID() : f.origin,
                    senderID: mode == "wrong-sender" ? f.sender.id : f.recipient.id, services: services,
                    validate: { try await fence.check() })
            })
        let succeeds = ["valid", "projection", "failure", "duplicate-call"].contains(mode)
        await f.registry.register(ImagePeerProvider { _, execute in
            let call = try NormalizedToolCall(id: "file", name: "SendMessage",
                argumentsJSON: Data(#"{"type":"attachment","url":"file:///report.txt"}"#.utf8))
            let result = try await execute(call)
            expectNoDifference(result.isError, !succeeds)
            if succeeds {
                let messages = await f.messenger.allMessages()
                let incoming = try #require(messages.first)
                let saved = try #require(incoming.delivery?.publications?.first)
                let directory = try await f.messenger.replyDirectory(replyingTo: incoming.id)
                let address = try #require(directory.first(where: { $0.id == saved.id })?.shortAddress)
                #expect(result.wireText.contains(address))
            }
            if mode == "duplicate-call" { _ = try await execute(call) }
            if mode == "failure" { throw ProviderError.invalidResponse }
            return "PASS"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Send file")
        do { try await session.drain(onUpdate: { message in
            if message.files?.isEmpty == false {
                if mode == "projection" { throw ProjectionFailure() }
                await projected.append(message)
            }
        }) } catch { #expect(["denied", "revoked"].contains(mode) && error is CancellationError) }
        let messages = await f.messenger.allMessages()
        let files = messages.flatMap { $0.delivery?.publications ?? [] }.filter { $0.files?.isEmpty == false }
        expectNoDifference(files.count, succeeds ? 1 : 0)
        let visible = await projected.values
        expectNoDifference(visible.count, succeeds && mode != "projection" ? 1 : 0)
        if let saved = files.first, let metadata = saved.files?.first {
            let bytes = try await store.data(for: metadata)
            expectNoDifference(bytes, prepared.bytes)
            expectNoDifference(messages.first?.delivery?.state, mode == "valid" ? .completed : .failed)
            let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
            let directory = try await reopened.replyDirectory(replyingTo: messages[0].id)
            #expect(directory.contains(where: { $0.id == saved.id && $0.shortAddress != nil }))
        }
        try await session.close()
    }

    @Test(arguments: ["valid", "denied", "members", "closed", "revoked", "wrong-origin", "wrong-destination", "wrong-context", "missing"])
    func backgroundFilesSeparateOriginAndDestination(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Destination", memberIDs: [f.sender.id])
        let prepared = try PreparedAgentPublicationFile(bytes: Data("Background report".utf8), filename: "report.txt")
        let store = AttachmentStore(rootURL: f.root.appending(path: "files"))
        let fence = FileDispatchFence()
        let services = AgentGroupFilePublicationServices(prepare: { _, _, _, context in
            expectNoDifference(context.conversationID, f.origin)
            return prepared
        }, authorize: { _, review, _, context in
            expectNoDifference(context.conversationID, f.origin)
            expectNoDifference(review.conversationID, group.id)
            if mode == "denied" { throw CancellationError() }
            if mode == "revoked" { await fence.revoke() }
            if mode == "members" { try await groups.updateMembers(groupID: group.id, memberIDs: []) }
        }, commit: { review, _, _, save in
            let metadata = try await store.ingest(prepared: review.file, createdAt: Date(timeIntervalSince1970: 123))
            return try await save(metadata, UUID())
        })
        let capability = AgentBackgroundGroupFileServices(originID: mode == "wrong-origin" ? UUID() : f.origin,
            groupID: mode == "wrong-destination" ? UUID() : group.id, services: services,
            validate: { try await fence.check() })
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()), groups: groups)
        let responder = ImageGroupSavedPublicationResponder { publish in
            do {
                let tool = try await session.savedBackgroundGroupPublisher(for: f.sender.id, groupID: group.id,
                    memberIDs: [f.sender.id], replyHistory: [], fileServices: mode == "missing" ? nil : capability, publish: publish)
                if mode == "closed" { try await session.close() }
                let context = ToolContext(conversationID: mode == "wrong-context" ? group.id : f.origin)
                if mode == "valid" {
                    let image = try await tool.execute(publishStandaloneImage("unrelated-human-image"), context: context)
                    #expect(image.isError)
                }
                let call = try NormalizedToolCall(id: "file", name: "SendMessage",
                    argumentsJSON: Data(#"{"type":"attachment","url":"file:///report.txt"}"#.utf8))
                let result = try await tool.execute(call, context: context)
                expectNoDifference(result.isError, mode != "valid")
                if mode == "valid" {
                    let replay = try await tool.execute(call, context: context)
                    expectNoDifference(replay, result)
                    #expect(result.wireText.contains("tbs0"))
                }
            } catch { #expect(mode != "valid") }
            return ["PASS"]
        }
        do { _ = try await groups.run(groupID: group.id, responder: responder) }
        catch { #expect(mode == "members") }
        let history = await groups.messages(groupID: group.id)
        let files = history.filter { $0.files?.isEmpty == false }
        expectNoDifference(files.count, mode == "valid" ? 1 : 0)
        let originMessages = await groups.messages(groupID: f.origin)
        expectNoDifference(originMessages, [])
        if let file = files.first?.files?.first {
            let bytes = try await store.data(for: file)
            expectNoDifference(bytes, prepared.bytes)
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: group.id)
            expectNoDifference(restored.first(where: { $0.files != nil })?.files, [file])
        }
        try await session.close()
    }

    @Test(arguments: ["valid", "denied", "stale-review", "stale-save", "bad-metadata", "closed", "unavailable"])
    func groupFileTransactionUsesSessionAndDurablePublication(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Files", memberIDs: [f.sender.id])
        let user = try await groups.postUserMessage("Send report", groupID: group.id)
        let prepared = try PreparedAgentPublicationFile(bytes: Data("Report".utf8), filename: "report.txt")
        let store = AttachmentStore(rootURL: f.root.appending(path: "attachments"))
        let services = AgentGroupFilePublicationServices(prepare: { sender, url, _, _ in
            expectNoDifference(sender.id, f.sender.id)
            expectNoDifference(url, "file:///review/report.txt")
            return prepared
        }, authorize: { sender, review, _, _ in
            expectNoDifference(review.senderID, sender.id)
            expectNoDifference(review.conversationID, group.id)
            expectNoDifference(review.file, prepared)
            if mode == "denied" { throw AgentMessagingError.approvalRequired }
            if mode == "stale-review" { _ = try await groups.postUserMessage("New request", groupID: group.id) }
        }, commit: { review, _, _, save in
            let metadata = try await store.ingest(prepared: review.file, createdAt: Date(timeIntervalSince1970: 123))
            if mode == "stale-save" { _ = try await groups.postUserMessage("New request", groupID: group.id) }
            if mode == "bad-metadata" {
                return try await save(.init(id: metadata.id, filename: "different.txt", mimeType: metadata.mimeType,
                    byteCount: metadata.byteCount, kind: metadata.kind, createdAt: metadata.createdAt), UUID())
            }
            return try await save(metadata, UUID())
        })
        let session = AgentMessagingSession(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            groups: groups, groupFiles: mode == "unavailable" ? nil : services)
        let responder = ImageGroupSavedPublicationResponder { publish in
            let tool = try await session.savedGroupPublisher(for: f.sender.id, userMessageID: user.id,
                replyHistory: [user], questionAccountID: nil, memberIDs: [f.sender.id], publish: publish)
            if mode == "closed" { try await session.close() }
            let call = try NormalizedToolCall(id: "report", name: "SendMessage",
                argumentsJSON: Data(#"{"type":"attachment","url":"file:///review/report.txt"}"#.utf8))
            do {
                let context = ToolContext(conversationID: group.id)
                let result = try await tool.execute(call, context: context)
                expectNoDifference(result.isError, mode != "valid")
                if mode == "valid" {
                    let replay = try await tool.execute(call, context: context)
                    expectNoDifference(replay.wireText, result.wireText)
                    #expect(result.wireText.contains("t0s0"))
                    let followup = try NormalizedToolCall(id: "report-followup", name: "SendMessage",
                        argumentsJSON: Data(#"{"type":"text","content":"Report notes","reply_to":"t0s0"}"#.utf8))
                    let followupResult = try await tool.execute(followup, context: context)
                    #expect(!followupResult.isError)
                }
            } catch {
                #expect(mode != "valid")
            }
            return ["PASS"]
        }
        _ = try await groups.run(groupID: group.id, responder: responder)
        let history = await groups.messages(groupID: group.id)
        let files = history.filter { $0.files?.isEmpty == false }
        expectNoDifference(files.count, mode == "valid" ? 1 : 0)
        if let metadata = files.first?.files?.first {
            let bytes = try await store.data(for: metadata)
            expectNoDifference(bytes, prepared.bytes)
            expectNoDifference(files.first?.shortAddress, "t0s0")
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: group.id).filter { $0.files?.isEmpty == false }
            expectNoDifference(restored.first?.files, files.first?.files)
            expectNoDifference(history.first(where: { $0.text == "Report notes" })?.replyToMessageID, files.first?.id)
            let resumed = try await session.savedGroupPublisher(for: f.sender.id, userMessageID: user.id,
                replyHistory: restored, questionAccountID: nil, memberIDs: [f.sender.id], publish: { _ in nil })
            let directory = try await resumed.runtimeContext(for: .init(conversationID: group.id))
            #expect(directory.contains("t0s0"))
        }
        try await session.close()
    }

    @Test(arguments: ["valid", "stale", "denied", "wrong-owner", "wrong-account", "foreign-image", "no-directory", "closed"])
    func directImagesRequireCurrentHostDirectoryAndFreshApproval(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let bytes = try peerImageBytes()
        let image = try await f.store.importImage(data: bytes, filename: "current.png")
        let foreign = try await f.store.importImage(data: peerImageBytes(shade: 0.75), filename: "old.png")
        await f.probe.setDirectImages(mode == "no-directory" ? [] : [image])
        await f.registry.register(ImagePeerProvider { request, _ in
            _ = await f.probe.request(request)
            let attached = request.messages.filter { !$0.attachments.isEmpty }
            let transport = try #require(attached.last)
            expectNoDifference(request.attachmentsByMessageID[transport.id]?.map(\.data), [bytes])
            return "Reviewed"
        })
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents,
            messenger: f.messenger, registry: f.registry,
            coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            directOriginBinding: .init(accountID: mode == "wrong-account" ? "other" : "local",
                agentID: mode == "wrong-owner" ? f.recipient.id : f.sender.id),
            directRequestImages: { await f.probe.directImages }, imageStore: f.store,
            authorizeImages: { _, _, _, images, _, _ in
                await f.probe.approve(images)
                if mode == "denied" { throw AgentMessagingError.approvalRequired }
                if mode == "stale" { await f.probe.setDirectImages([]) }
            })
        if mode == "closed" { try await session.close() }
        let call = try forwardImage(f.recipient.id, ids: [mode == "foreign-image" ? foreign.id : image.id])
        if ["wrong-account", "closed"].contains(mode) {
            await #expect(throws: AgentMessagingError.self) {
                _ = try await session.tool(for: f.sender.id).execute(call, context: .init(conversationID: f.origin))
            }
        } else {
            let result = try await session.tool(for: f.sender.id).execute(call, context: .init(conversationID: f.origin))
            expectNoDifference(result.isError, mode != "valid")
        }
        if mode == "valid" { try await session.drain() }
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.count, mode == "valid" ? 1 : 0)
        let requests = await f.probe.requests, approvals = await f.probe.approvals
        expectNoDifference(requests.count, mode == "valid" ? 1 : 0)
        expectNoDifference(approvals.count, ["valid", "stale", "denied"].contains(mode) ? 1 : 0)
    }

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

    @Test func standaloneImageRequiresCurrentHandleApprovalAndKeepsEmptyTextDistinct() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "current.png")
        let foreign = try await f.store.importImage(data: peerImageBytes(shade: 0.75), filename: "foreign.png")
        let output = ImagePublicationProbe(), context = ToolContext(conversationID: f.origin)
        let tool = AgentUserMessageTool(conversationID: f.origin, availableImages: [image], imageStore: f.store,
            authorizeImages: { text, values, _, _ in
                expectNoDifference(text, "")
                await f.probe.approve(values)
            }) { text, values in
                await output.append(.init(groupID: f.origin, senderID: f.recipient.id, text: text, images: values))
            }
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["image_id"] != nil && properties["type"] != nil)
        for invalid in [foreign.id, "file:///private.png", "https://example.invalid/private.png"] {
            #expect(try await tool.execute(publishStandaloneImage(invalid, id: ToolCallID(rawValue: invalid)), context: context).isError)
        }
        let mixed = try NormalizedToolCall(id: "mixed", name: "SendMessage",
            argumentsJSON: Data("{\"type\":\"attachment\",\"image_id\":\"\(image.id)\",\"text\":\"hidden\"}".utf8))
        #expect(try await tool.execute(mixed, context: context).isError)
        let call = try publishStandaloneImage(image.id)
        let result = try await tool.execute(call, context: context)
        #expect(!result.isError)
        let replay = try await tool.execute(call, context: context)
        expectNoDifference(replay, result)
        #expect(try await tool.execute(publishStandaloneImage(image.id, id: "repeat"), context: context).isError)
        let approvals = await f.probe.approvals, values = await output.values
        expectNoDifference(approvals, [[image]])
        expectNoDifference(values.map(\.text), [""])
        expectNoDifference(values.first?.images, [image])
        let publishedTexts = await tool.publishedTexts
        expectNoDifference(publishedTexts, [""])
    }

    @Test(arguments: ["approved", "denied", "stale"], [nil, "版面配置：導覽與商品卡片"] as [String?])
    func standaloneGroupImagePersistsOnlyAfterCurrentTurnApproval(mode: String, alt: String?) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let groups = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
        let group = try await groups.create(name: "Review", memberIDs: [f.sender.id])
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "current.png")
        let user = try await groups.postUserMessage("Show the image", groupID: group.id, images: [image])
        var annotated = image
        annotated.altText = alt
        let session = AgentMessagingSession(originConversationID: group.id, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            groups: groups, imageStore: f.store, authorizePublication: { _, text, values, _, _ in
                expectNoDifference(text, "")
                await f.probe.approve(values)
                if mode == "denied" { throw AgentMessagingError.approvalRequired }
                if mode == "stale" { _ = try await groups.postUserMessage("New request", groupID: group.id) }
            })
        let responder = ImageGroupSavedPublicationResponder { publish in
            let tool = try await session.savedGroupPublisher(for: f.sender.id, userMessageID: user.id,
                replyHistory: [user], questionAccountID: nil, memberIDs: [f.sender.id], publish: publish)
            let call = try publishStandaloneImage(image.id, alt: alt)
            let result = try await tool.execute(call, context: .init(conversationID: group.id))
            expectNoDifference(result.isError, mode != "approved")
            if mode == "approved" {
                #expect(result.wireText.contains("t0s0"))
                let publishedTexts = await tool.publishedTexts
                expectNoDifference(publishedTexts, [""])
            }
            return ["PASS"]
        }
        _ = try await groups.run(groupID: group.id, responder: responder)
        let history = await groups.messages(groupID: group.id)
        let saved = history.filter { $0.senderID == f.sender.id && $0.images?.isEmpty == false }
        expectNoDifference(saved.count, mode == "approved" ? 1 : 0)
        if mode == "approved" {
            expectNoDifference(saved.first?.text, "")
            expectNoDifference(saved.first?.images, [annotated])
            expectNoDifference(saved.first?.shortAddress, "t0s0")
            let reopened = try GroupService(agents: f.agents, storeURL: f.root.appending(path: "groups.json"))
            let restored = await reopened.messages(groupID: group.id).filter { $0.senderID == f.sender.id && $0.images?.isEmpty == false }
            expectNoDifference(restored.map(\.id), saved.map(\.id))
            expectNoDifference(restored.first?.images?.map(\.id), [image.id])
            expectNoDifference(restored.first?.images?.map(\.altText), [alt])
            expectNoDifference(restored.first?.shortAddress, "t0s0")
        }
        let approvals = await f.probe.approvals
        expectNoDifference(approvals, [[annotated]])
        try await session.close()
    }

    @Test(arguments: [false, true], [false, true])
    func mailboxImageDescriptionIsDurableWithoutDuplicateFinalText(inline: Bool, referenceText: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "current.png")
        var annotated = image
        annotated.altText = "Mailbox image description"
        let projected = ImagePublicationProbe()
        let session = AgentMessagingSession(originConversationID: f.origin, agents: f.agents, messenger: f.messenger,
            registry: f.registry, coordinator: TurnCoordinator(registry: f.registry, toolCatalog: ToolCatalog()),
            imageStore: f.store, authorizePublication: { _, text, values, _, _ in
                expectNoDifference(text, inline ? "Reviewed image" : "")
                await f.probe.approve(values)
            })
        await f.registry.register(ImagePeerProvider { _, execute in
            let call: NormalizedToolCall
            if inline {
                var fields: [String: Any] = referenceText ? ["type": "text", "content": "Reviewed image"] : ["text": "Reviewed image"]
                fields["images"] = [["image_id": image.id, "alt": "Mailbox image description"]]
                call = try .init(id: "inline", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: fields))
            } else { call = try publishStandaloneImage(image.id, alt: "Mailbox image description") }
            let result = try await execute(call)
            #expect(!result.isError)
            return "Do not repeat this final text"
        })
        try await session.enqueueUserMessage(senderID: f.sender.id, recipientID: f.recipient.id,
            text: "Return this image", images: [image])
        try await session.drain(onUpdate: { await projected.append($0) })
        let messages = await f.messenger.allMessages()
        expectNoDifference(messages.count, 1)
        let delivery = try #require(messages.first?.delivery)
        expectNoDifference(delivery.state, .completed)
        expectNoDifference(delivery.response, inline ? "Reviewed image" : "")
        expectNoDifference(delivery.publications?.map(\.text), [inline ? "Reviewed image" : ""])
        expectNoDifference(delivery.publications?.first?.images, [annotated])
        let approvals = await f.probe.approvals
        expectNoDifference(approvals, [[annotated]])
        let visible = await projected.values.filter { $0.images?.isEmpty == false }
        expectNoDifference(visible.map(\.text), [inline ? "Reviewed image" : ""])
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let restored = await reopened.allMessages()
        expectNoDifference(restored.first?.delivery?.publications?.first?.images?.map(\.id), [image.id])
        expectNoDifference(restored.first?.delivery?.publications?.first?.images?.map(\.altText), [annotated.altText])
        try await session.close()
    }

    @Test func standaloneDescriptionIsBoundedApprovedAndReplayProtected() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let image = try await f.store.importImage(data: peerImageBytes(), filename: "current.png")
        let output = ImagePublicationProbe(), context = ToolContext(conversationID: f.origin)
        let tool = AgentUserMessageTool(conversationID: f.origin, availableImages: [image], imageStore: f.store,
            authorizeImages: { _, values, _, _ in await f.probe.approve(values) }) { text, values in
                await output.append(.init(groupID: f.origin, senderID: nil, text: text, images: values))
            }
        for invalid in [String(repeating: "a", count: 501), "line\nbreak", "hidden\u{0000}text"] {
            #expect(try await tool.execute(publishStandaloneImage(image.id, alt: invalid), context: context).isError)
        }
        let call = try publishStandaloneImage(image.id, alt: "  商品卡片  ")
        let result = try await tool.execute(call, context: context)
        #expect(!result.isError)
        let replay = try await tool.execute(call, context: context)
        expectNoDifference(replay, result)
        #expect(try await tool.execute(publishStandaloneImage(image.id, alt: "changed"), context: context).isError)
        #expect(try await tool.execute(publishStandaloneImage(image.id, id: "repeat", alt: "changed"), context: context).isError)
        var annotated = image
        annotated.altText = "商品卡片"
        let approvals = await f.probe.approvals, values = await output.values
        expectNoDifference(approvals, [[annotated]])
        expectNoDifference(values.first?.images, [annotated])
        expectNoDifference(values.count, 1)
        #expect(annotated.isAnnotation(of: image))
        let altered = AttachmentMetadata(id: image.id, filename: "changed.png", mimeType: image.mimeType,
            byteCount: image.byteCount, kind: image.kind, createdAt: image.createdAt, altText: "商品卡片")
        #expect(!altered.isAnnotation(of: image))
        annotated.altText = "invalid\ncaption"
        #expect(!annotated.isAnnotation(of: image))
        let legacy = try JSONEncoder().encode(image)
        expectNoDifference(try JSONDecoder().decode(AttachmentMetadata.self, from: legacy).altText, nil)
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

    @Test(arguments: [true, false], [true, false])
    func inlineDescriptionsRequireApprovalAndPreserveLegacyEntries(approved: Bool, referenceText: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await f.store.importImage(data: peerImageBytes(), filename: "first.png")
        let second = try await f.store.importImage(data: peerImageBytes(shade: 0.75), filename: "second.png")
        let output = ImagePublicationProbe(), context = ToolContext(conversationID: f.origin)
        let tool = AgentUserMessageTool(conversationID: f.origin, availableImages: [first, second], imageStore: f.store,
            authorizeImages: { _, values, _, _ in
                await f.probe.approve(values)
                if !approved { throw AgentMessagingError.approvalRequired }
            }) { text, values in
                await output.append(.init(groupID: f.origin, senderID: nil, text: text, images: values))
            }
        func call(_ entries: [Any], id: ToolCallID = "inline") throws -> NormalizedToolCall {
            var fields: [String: Any] = referenceText ? ["type": "text", "content": "Review these layouts"] : ["text": "Review these layouts"]
            fields["images"] = entries
            return try .init(id: id, name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: fields))
        }
        let invalid: [[Any]] = [
            [["image_id": first.id, "alt": String(repeating: "a", count: 501)]],
            [["image_id": first.id, "alt": String(repeating: "\u{0301}", count: 1001)]],
            [["image_id": first.id, "alt": "line\nbreak"]],
            [["image_id": first.id, "alt": 42]],
            [["image_id": first.id, "url": "https://example.invalid/a.png"]],
            [["image_id": "file:///private.png", "alt": "outside"]],
            [first.id, ["image_id": first.id, "alt": "duplicate"]],
        ]
        for entries in invalid {
            #expect(try await tool.execute(call(entries), context: context).isError)
        }
        let before = await f.probe.approvals
        expectNoDifference(before, [])
        let request = try call([["image_id": first.id, "alt": "  商品卡片  "], second.id])
        let result = try await tool.execute(request, context: context)
        expectNoDifference(result.isError, !approved)
        if approved {
            let replay = try await tool.execute(request, context: context)
            expectNoDifference(replay, result)
            #expect(try await tool.execute(call([["image_id": first.id, "alt": "changed"], second.id]), context: context).isError)
            #expect(try await tool.execute(call([["image_id": first.id, "alt": "changed"], second.id], id: "repeat"), context: context).isError)
        }
        var annotated = first
        annotated.altText = "商品卡片"
        let approvals = await f.probe.approvals, values = await output.values
        expectNoDifference(approvals, [[annotated, second]])
        expectNoDifference(values.count, approved ? 1 : 0)
        if approved { expectNoDifference(values.first?.images, [annotated, second]) }
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
                       RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Unreviewed file", files: [image]),
                       RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Mixed file", images: [image], files: [image]),
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

    @Test func reviewedMailboxFileIsScopedReplayableAndReplyable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let inbound = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "File",
            delivery: .init(chainID: UUID(), originConversationID: f.origin))
        try await f.messenger.send(inbound)
        try await f.messenger.updateDelivery(id: inbound.id, state: .running)
        let metadata = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "report.txt",
                                          mimeType: "text/plain", byteCount: 4, kind: .document)
        let lifetime = AgentPublicationLifetime()
        let reviewed = try ReviewedMailboxFile(metadata: metadata, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: UUID(), lifetime: lifetime)
        for (incoming, origin, sender) in [(UUID(), f.origin, f.recipient.id),
                                          (inbound.id, UUID(), f.recipient.id),
                                          (inbound.id, f.origin, f.sender.id)] {
            let invalid = try ReviewedMailboxFile(metadata: metadata, incomingID: incoming, originID: origin,
                senderID: sender, messageID: UUID(), lifetime: lifetime)
            await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishFile(invalid) }
        }
        let file = f.root.appending(path: "messages.json"), backup = f.root.appending(path: "file.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await f.messenger.publishFile(reviewed) }
        let unsaved = await f.messenger.allMessages()
        expectNoDifference(unsaved.first?.delivery?.publications, nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let saved = try await f.messenger.publishFile(reviewed)
        let replay = try await f.messenger.publishFile(reviewed)
        expectNoDifference(saved, replay)
        expectNoDifference(saved.files, [metadata])
        #expect(saved.shortAddress != nil)
        let reused = try ReviewedMailboxFile(metadata: metadata, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: inbound.id, lifetime: lifetime)
        await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishFile(reused) }
        let changed = try ReviewedMailboxFile(metadata: metadata, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: saved.id, replyToMessageID: inbound.id, lifetime: lifetime)
        await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishFile(changed) }
        let directory = try await f.messenger.replyDirectory(replyingTo: inbound.id)
        #expect(directory.contains(where: { $0.id == saved.id }))
        await #expect(throws: AgentPublicationError.invalid) {
            try await f.messenger.publish(saved, replyingTo: inbound.id, lifetime: lifetime)
        }
        var reply = RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "See file")
        reply.replyToMessageID = saved.id
        try await f.messenger.publish(reply, replyingTo: inbound.id, lifetime: lifetime)
        let extra = try ReviewedMailboxFile(metadata: metadata, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: UUID(), lifetime: lifetime)
        await #expect(throws: AgentPublicationError.limit) { try await f.messenger.publishFile(extra) }
        lifetime.close()
        await #expect(throws: CancellationError.self) { try await f.messenger.publishFile(reviewed) }
        let reopened = try AgentMessenger(service: f.agents, storeURL: file)
        let restored = try await reopened.replyDirectory(replyingTo: inbound.id)
        expectNoDifference(restored.first(where: { $0.id == saved.id })?.files?.map(\.id), [metadata.id])
    }

    @Test func reviewedMailboxRemoteIsScopedReplayableAndReplyable() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let inbound = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Remote",
            delivery: .init(chainID: UUID(), originConversationID: f.origin))
        try await f.messenger.send(inbound)
        try await f.messenger.updateDelivery(id: inbound.id, state: .running)
        let reference = try RemoteAttachmentReference(url: "https://example.com/report?sig=a%2Bb", alt: "報表")
        let lifetime = AgentPublicationLifetime()
        let reviewed = ReviewedMailboxRemoteAttachment(reference: reference, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: UUID(), lifetime: lifetime)
        for (incoming, origin, sender) in [(UUID(), f.origin, f.recipient.id),
                                          (inbound.id, UUID(), f.recipient.id),
                                          (inbound.id, f.origin, f.sender.id)] {
            let invalid = ReviewedMailboxRemoteAttachment(reference: reference, incomingID: incoming, originID: origin,
                senderID: sender, messageID: UUID(), lifetime: lifetime)
            await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishRemoteAttachment(invalid) }
        }
        await #expect(throws: AgentPublicationError.invalid) {
            try await f.messenger.publish(reviewed.publication, replyingTo: inbound.id, lifetime: lifetime)
        }
        let file = f.root.appending(path: "messages.json"), backup = f.root.appending(path: "remote.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await f.messenger.publishRemoteAttachment(reviewed) }
        let unsaved = await f.messenger.allMessages()
        expectNoDifference(unsaved.first?.delivery?.publications, nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let saved = try await f.messenger.publishRemoteAttachment(reviewed)
        let replay = try await f.messenger.publishRemoteAttachment(reviewed)
        expectNoDifference(saved, replay)
        expectNoDifference(saved.remoteAttachment, reference)
        #expect(saved.shortAddress != nil)
        let changed = ReviewedMailboxRemoteAttachment(reference: reference, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: saved.id, replyToMessageID: inbound.id, lifetime: lifetime)
        await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishRemoteAttachment(changed) }
        let directory = try await f.messenger.replyDirectory(replyingTo: inbound.id)
        #expect(directory.contains(where: { $0.id == saved.id }))
        var reply = RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "See report")
        reply.replyToMessageID = saved.id
        try await f.messenger.publish(reply, replyingTo: inbound.id, lifetime: lifetime)
        let extra = ReviewedMailboxRemoteAttachment(reference: reference, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: UUID(), lifetime: lifetime)
        await #expect(throws: AgentPublicationError.limit) { try await f.messenger.publishRemoteAttachment(extra) }
        lifetime.close()
        await #expect(throws: CancellationError.self) { try await f.messenger.publishRemoteAttachment(reviewed) }
        let reopened = try AgentMessenger(service: f.agents, storeURL: file)
        let restored = try await reopened.replyDirectory(replyingTo: inbound.id)
        expectNoDifference(restored.first(where: { $0.id == saved.id })?.remoteAttachment, reference)
        let afterRestart = ReviewedMailboxRemoteAttachment(reference: reference, incomingID: inbound.id, originID: f.origin,
            senderID: f.recipient.id, messageID: UUID(), lifetime: AgentPublicationLifetime())
        await #expect(throws: AgentPublicationError.invalid) {
            try await reopened.publishRemoteAttachment(afterRestart)
        }
    }

    @Test(arguments: ["remote", "local", "mixed"])
    func reviewedMailboxGallerySurvivesPeerTranscriptRecovery(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let binding = DirectConversationAgentBinding(accountID: "local", agentID: f.sender.id)
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let inbound = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Review designs",
            createdAt: createdAt,
            delivery: .init(chainID: UUID(), originConversationID: f.origin, directOriginBinding: binding))
        try await f.messenger.send(inbound)
        try await f.messenger.updateDelivery(id: inbound.id, state: .running, at: createdAt)
        let images: [AttachmentMetadata] = mode == "remote" ? [] : [
            .init(id: String(repeating: "a", count: 64), filename: "a.png", mimeType: "image/png",
                byteCount: 100, kind: .image, createdAt: createdAt, altText: "Local A"),
            .init(id: String(repeating: "b", count: 64), filename: "b.png", mimeType: "image/png",
                byteCount: 100, kind: .image, createdAt: createdAt, altText: "Local B")]
        let reference = try RemoteAttachmentReference(url: "https://example.com/design", alt: "Remote")
        let gallery = mode == "local" ? nil : try RemoteImageGallery(images: [reference])
        let items: [ImageGalleryLayout.Item] = switch mode {
        case "remote": [.remote(reference)]
        case "local": images.map { .attachment($0.id) }
        default: [.attachment(images[0].id), .remote(reference), .attachment(images[1].id)]
        }
        let layout = try ImageGalleryLayout(items: items)
        let lifetime = AgentPublicationLifetime()
        let reviewed = ReviewedMailboxImageGallery(text: "Reviewed designs", images: images, gallery: gallery,
            imageGalleryLayout: layout, incomingID: inbound.id, originID: f.origin, senderID: f.recipient.id,
            messageID: UUID(), replyToMessageID: inbound.id, lifetime: lifetime)
        _ = try await f.messenger.publishImageGallery(reviewed)
        try await f.messenger.updateDelivery(id: inbound.id, state: .completed, at: createdAt)
        lifetime.close()
        let reopened = try AgentMessenger(service: f.agents, storeURL: f.root.appending(path: "messages.json"))
        let canonical = try #require(await reopened.allMessages().first?.delivery?.publications?.first)
        var expectedPublication = canonical
        expectedPublication.shortAddress = nil
        let expectedMessages = [RoomMessage(id: inbound.id, groupID: f.origin, senderID: f.sender.id,
            text: inbound.text, createdAt: createdAt), expectedPublication]
        let expectedSources = try [AgentMessageSource.Kind.incoming, .publication].map { kind in
            try AgentMessageSource(accountID: "local", originConversationID: f.origin, deliveryID: inbound.id,
                senderAgentID: f.sender.id, recipientAgentID: f.recipient.id, kind: kind)
        }
        let recovered = try await reopened.directPeerTranscript(originID: f.origin, binding: binding)
        expectNoDifference(recovered.map(\.message), expectedMessages)
        expectNoDifference(recovered.map(\.source), expectedSources)
        let repeated = try await reopened.directPeerTranscript(originID: f.origin, binding: binding)
        expectNoDifference(repeated, recovered)
    }

    @Test func plainMailboxFinalReportCannotSmuggleGalleryLayout() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let inbound = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Report",
            delivery: .init(chainID: UUID(), originConversationID: f.origin))
        try await f.messenger.send(inbound)
        try await f.messenger.updateDelivery(id: inbound.id, state: .running)
        let before = await f.messenger.allMessages()
        let report = RoomMessage(groupID: f.origin, senderID: f.recipient.id, text: "Plain report",
            imageGalleryLayout: try ImageGalleryLayout(items: [.remote(RemoteAttachmentReference(url: "https://example.com/unreviewed"))]))
        await #expect(throws: AgentPublicationError.invalid) {
            try await f.messenger.updateDelivery(id: inbound.id, state: .completed,
                response: report.text, finalPublication: report)
        }
        let after = await f.messenger.allMessages()
        expectNoDifference(after, before)
    }

    @Test func reviewedMailboxGalleryPreservesAtomicContentAndRejectsBypasses() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let binding = DirectConversationAgentBinding(accountID: "local", agentID: f.sender.id)
        let inbound = AgentMessage(senderID: f.sender.id, recipientID: f.recipient.id, text: "Images",
            delivery: .init(chainID: UUID(), originConversationID: f.origin, directOriginBinding: binding))
        try await f.messenger.send(inbound)
        try await f.messenger.updateDelivery(id: inbound.id, state: .running)
        let gallery = try RemoteImageGallery(images: [
            RemoteAttachmentReference(url: "https://example.com/first?sig=a%2Bb", alt: "第一張"),
            RemoteAttachmentReference(url: "https://example.com/second", alt: "第二張")
        ])
        let lifetime = AgentPublicationLifetime()
        let reviewed = ReviewedMailboxImageGallery(text: "Two designs", gallery: gallery,
            incomingID: inbound.id, originID: f.origin, senderID: f.recipient.id,
            messageID: UUID(), replyToMessageID: inbound.id, lifetime: lifetime)
        await #expect(throws: AgentPublicationError.invalid) {
            try await f.messenger.publish(reviewed.publication, replyingTo: inbound.id, lifetime: lifetime)
        }
        let unreviewedReport = RoomMessage(groupID: f.origin, senderID: f.recipient.id,
            text: "Final report", remoteImages: gallery)
        await #expect(throws: AgentPublicationError.invalid) {
            try await f.messenger.updateDelivery(id: inbound.id, state: .completed,
                response: unreviewedReport.text, finalPublication: unreviewedReport)
        }
        for (incoming, origin, sender, text) in [
            (UUID(), f.origin, f.recipient.id, "Designs"),
            (inbound.id, UUID(), f.recipient.id, "Designs"),
            (inbound.id, f.origin, f.sender.id, "Designs"),
            (inbound.id, f.origin, f.recipient.id, " \n")
        ] {
            let invalid = ReviewedMailboxImageGallery(text: text, gallery: gallery, incomingID: incoming,
                originID: origin, senderID: sender, messageID: UUID(), lifetime: lifetime)
            await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishImageGallery(invalid) }
        }
        let file = f.root.appending(path: "messages.json"), backup = f.root.appending(path: "gallery.backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await f.messenger.publishImageGallery(reviewed) }
        let unsaved = await f.messenger.allMessages()
        expectNoDifference(unsaved.first?.delivery?.publications, nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        let saved = try await f.messenger.publishImageGallery(reviewed)
        let replay = try await f.messenger.publishImageGallery(reviewed)
        expectNoDifference(replay, saved)
        expectNoDifference(saved.remoteImages, gallery)
        expectNoDifference(saved.text, "Two designs")
        #expect(saved.shortAddress != nil)
        let changed = ReviewedMailboxImageGallery(text: "Changed", gallery: gallery, incomingID: inbound.id,
            originID: f.origin, senderID: f.recipient.id, messageID: saved.id, lifetime: lifetime)
        await #expect(throws: AgentPublicationError.invalid) { try await f.messenger.publishImageGallery(changed) }
        lifetime.close()
        await #expect(throws: CancellationError.self) { try await f.messenger.publishImageGallery(reviewed) }
        try await f.messenger.updateDelivery(id: inbound.id, state: .completed)
        let reopened = try AgentMessenger(service: f.agents, storeURL: file)
        let transcript = try await reopened.directPeerTranscript(originID: f.origin, binding: binding)
        let restored = try #require(transcript.first(where: { $0.message.id == saved.id }))
        expectNoDifference(restored.message.remoteImages, gallery)
        expectNoDifference(restored.message.text, saved.text)
        expectNoDifference(restored.message.replyToMessageID, inbound.id)
        expectNoDifference(transcript.filter { $0.message.id == saved.id }.count, 1)
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
