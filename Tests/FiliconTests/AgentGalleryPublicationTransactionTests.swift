import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
import FiliconAppServices

private func galleryTestPNG() throws -> Data {
    let data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
    expectNoDifference(try AgentImageStore.validate(data), "image/png")
    return data
}

private actor GalleryPublicationProbe {
    var events: [String] = []
    var valid = true
    func record(_ event: String) { events.append(event) }
    func revoke() { valid = false }
    func validate() throws {
        guard valid else { throw AgentGalleryPublicationTransaction.Failure.unavailable }
    }
}

@Suite("Atomic reviewed text and image gallery", .timeLimit(.minutes(1)))
struct AgentGalleryPublicationTransactionTests {
    @Test(arguments: ["valid", "legacy", "local-order", "missing-local", "remote-url", "non-image"])
    func persistedJSONGalleryMustMatchCanonicalImages(mode: String) throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var images = [
            AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "a.png", mimeType: "image/png",
                byteCount: 100, kind: .image, createdAt: createdAt),
            AttachmentMetadata(id: String(repeating: "b", count: 64), filename: "b.png", mimeType: "image/png",
                byteCount: 100, kind: .image, createdAt: createdAt)]
        let reference = try RemoteAttachmentReference(url: "https://example.com/image", alt: "Remote")
        var remote = try RemoteImageGallery(images: [reference])
        let layout = try ImageGalleryLayout(items: [.attachment(images[0].id), .remote(reference), .attachment(images[1].id)])
        if mode == "local-order" { images.reverse() }
        if mode == "missing-local" { images.removeLast() }
        if mode == "remote-url" {
            remote = try RemoteImageGallery(images: [RemoteAttachmentReference(url: "https://example.com/changed", alt: "Remote")])
        }
        if mode == "non-image" {
            images[0] = .init(id: images[0].id, filename: images[0].filename, mimeType: "text/plain",
                byteCount: images[0].byteCount, kind: .document, createdAt: createdAt)
        }
        let room = RoomMessage(groupID: UUID(), senderID: UUID(), text: "Reviewed gallery", createdAt: createdAt,
            images: images, remoteImages: remote, imageGalleryLayout: mode == "legacy" ? nil : layout)
        let chat = ChatMessage(role: .assistant, text: room.text, createdAt: createdAt,
            attachments: images, remoteImages: remote, imageGalleryLayout: mode == "legacy" ? nil : layout)
        let roomJSON = try JSONEncoder().encode(room), chatJSON = try JSONEncoder().encode(chat)
        if ["valid", "legacy"].contains(mode) {
            expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: roomJSON), room)
            expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: chatJSON), chat)
        } else {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(RoomMessage.self, from: roomJSON) }
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChatMessage.self, from: chatJSON) }
        }
    }

    @Test(arguments: ["success", "legacy", "deny", "unavailable", "wrong-scope", "mixed", "local", "duplicate", "http", "invalid-receipt"])
    func messageToolPublishesOneReviewedGallery(mode: String) async throws {
        let origin = UUID(), sender = UUID(), messageID = UUID(), probe = GalleryPublicationProbe()
        let preparedLocal = mode == "local"
            ? try PreparedAgentGalleryImage(bytes: try galleryTestPNG(), filename: "a.png", altText: "Local A")
            : nil
        let prepareLocalImage: AgentGalleryPublicationTransaction.PrepareLocalImage?
        if let preparedLocal {
            prepareLocalImage = { url, alt, _, _ in
                #expect(url == "file:///tmp/a.png")
                #expect(alt == "Local A")
                return preparedLocal
            }
        } else { prepareLocalImage = nil }
        let transaction = AgentGalleryPublicationTransaction(conversationID: mode == "wrong-scope" ? UUID() : origin,
            senderID: sender, validateScope: {}, prepareLocalImage: prepareLocalImage, authorize: { review, _, _ in
                await probe.record("review")
                expectNoDifference(review.text, "Designs")
                expectNoDifference(review.gallery?.images.map(\.alt), mode == "local" ? ["A"] : ["A", "B"])
                if mode == "local" {
                    expectNoDifference(review.images.count, 2)
                    let remote = try RemoteAttachmentReference(url: "https://example.com/a", alt: "A")
                    let expected = try ImageGalleryLayout(items: [.remote(remote), .attachment(try #require(preparedLocal).file.digest)])
                    expectNoDifference(review.layout, Optional(expected))
                    expectNoDifference(review.images, [.remote(remote), .local(try #require(preparedLocal))])
                }
                if mode == "deny" { throw AgentMessagingError.approvalRequired }
            }, commit: { review, _, _ in
                await probe.record("save")
                let localImages = review.localImages.map { image in
                    AttachmentMetadata(id: image.file.digest, filename: image.file.filename, mimeType: image.mimeType,
                        byteCount: Int64(image.file.bytes.count), kind: .image, altText: image.altText)
                }
                var saved = RoomMessage(id: messageID, groupID: origin, senderID: sender,
                    text: mode == "invalid-receipt" ? "Wrong" : review.text, images: localImages,
                    remoteImages: review.gallery, imageGalleryLayout: review.layout)
                saved.replyToMessageID = review.replyTo
                return .init(review: review, message: saved)
            })
        let tool = AgentUserMessageTool(conversationID: origin, senderID: sender, replyHistory: [], supportsQuestions: false,
            galleryPublication: mode == "unavailable" ? nil : transaction,
            publishGroup: { text, _, reply, _ in
                var message = RoomMessage(groupID: origin, senderID: sender, text: text)
                message.replyToMessageID = reply
                return message
            })
        var images: [[String: String]] = [["url": "https://example.com/a", "alt": "A"],
                                        ["url": "https://example.com/b", "alt": "B"]]
        if mode == "mixed" { images[1] = ["image_id": "host-image"] }
        if mode == "local" { images[1] = ["url": "file:///tmp/a.png", "alt": "Local A"] }
        if mode == "duplicate" { images[1]["url"] = images[0]["url"] }
        if mode == "http" { images[0]["url"] = "http://example.com/a" }
        var args: [String: Any] = mode == "legacy" ? ["text": "Designs"] : ["type": "text", "content": "Designs"]
        args["images"] = images
        let call = try NormalizedToolCall(id: "gallery", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: args))
        let context = ToolContext(conversationID: origin)
        let result = try await tool.execute(call, context: context)
        let succeeds = ["success", "legacy", "local"].contains(mode)
        expectNoDifference(result.isError, !succeeds)
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        expectNoDifference(properties["images"] != nil, !["unavailable", "wrong-scope"].contains(mode))
        if succeeds {
            let replay = try await tool.execute(call, context: context)
            expectNoDifference(replay, result)
            args[mode == "legacy" ? "text" : "content"] = "Changed"
            let changed = try NormalizedToolCall(id: "gallery", name: "SendMessage", argumentsJSON: JSONSerialization.data(withJSONObject: args))
            #expect(try await tool.execute(changed, context: context).isError)
            let reply = try NormalizedToolCall(id: "reply", name: "SendMessage", argumentsJSON:
                JSONSerialization.data(withJSONObject: ["text": "See designs", "reply_to": messageID.uuidString]))
            #expect(try await !tool.execute(reply, context: context).isError)
            let third = try NormalizedToolCall(id: "third", name: "SendMessage", argumentsJSON: Data(#"{"text":"Third"}"#.utf8))
            #expect(try await tool.execute(third, context: context).isError)
        }
        if mode == "invalid-receipt" {
            #expect(try await tool.execute(call, context: context).isError)
        }
        let events = await probe.events
        expectNoDifference(events, succeeds || mode == "invalid-receipt" ? ["review", "save"] : mode == "deny" ? ["review"] : [])
    }

    @Test(arguments: ["success", "deny", "revoke", "wrong-scope", "empty", "uncertain",
                      "text", "order", "description", "reply", "sender", "destination", "mixed"])
    func wholeMessageMustMatchApproval(mode: String) async throws {
        let origin = UUID(), destination = UUID(), sender = UUID(), reply = UUID()
        let gallery = try RemoteImageGallery(images: [RemoteAttachmentReference(url: "https://example.com/a", alt: "A"),
            RemoteAttachmentReference(url: "https://example.com/b", alt: "B")])
        let probe = GalleryPublicationProbe()
        let transaction = AgentGalleryPublicationTransaction(conversationID: origin, senderID: sender,
            destinationConversationID: destination, validateScope: { try await probe.validate() },
            authorize: { review, _, _ in
                await probe.record("approve")
                expectNoDifference(review.text, "Compare these")
                expectNoDifference(review.gallery, Optional(gallery))
                expectNoDifference(review.conversationID, destination)
                expectNoDifference(review.replyTo, reply)
                if mode == "deny" { throw AgentGalleryPublicationTransaction.Failure.unavailable }
                if mode == "revoke" { await probe.revoke() }
            }, commit: { review, _, _ in
                await probe.record("commit")
                if mode == "uncertain" { throw AgentGalleryPublicationTransaction.Failure.uncertainCommit }
                var images = try #require(review.gallery).images
                if mode == "order" { images.reverse() }
                if mode == "description" { images[0] = try RemoteAttachmentReference(url: images[0].url, alt: "Changed") }
                var message = RoomMessage(groupID: mode == "destination" ? UUID() : review.conversationID,
                    senderID: mode == "sender" ? UUID() : review.senderID,
                    text: mode == "text" ? "Changed" : review.text,
                    remoteAttachment: mode == "mixed" ? images[0] : nil,
                    remoteImages: try RemoteImageGallery(images: images), imageGalleryLayout: review.layout)
                message.replyToMessageID = mode == "reply" ? nil : review.replyTo
                return .init(review: review, message: message)
            })
        let context = ToolContext(conversationID: mode == "wrong-scope" ? UUID() : origin)
        let call = try NormalizedToolCall(id: "gallery", name: "SendMessage", argumentsJSON: Data("{}".utf8))
        let text = mode == "empty" ? " " : "Compare these"
        do {
            let receipt = try await transaction.publish(text: text, gallery: gallery, replyTo: reply, call: call, context: context)
            expectNoDifference(mode, "success")
            expectNoDifference(receipt.message.remoteImages, gallery)
            await transaction.close()
            let replay = try await transaction.publish(text: text, gallery: gallery, replyTo: reply, call: call, context: context)
            expectNoDifference(replay, receipt)
            await #expect(throws: AgentGalleryPublicationTransaction.Failure.duplicateCall) {
                try await transaction.publish(text: "Changed", gallery: gallery, replyTo: reply, call: call, context: context)
            }
        } catch let error as AgentGalleryPublicationTransaction.Failure {
            #expect(mode != "success")
            let expected: AgentGalleryPublicationTransaction.Failure = switch mode {
            case "deny", "revoke", "wrong-scope": .unavailable
            case "empty": .invalidText
            case "uncertain": .uncertainCommit
            default: .invalidReceipt
            }
            expectNoDifference(error, expected)
            if expected == .invalidReceipt || expected == .uncertainCommit {
                await #expect(throws: AgentGalleryPublicationTransaction.Failure.uncertainCommit) {
                    try await transaction.publish(text: text, gallery: gallery, replyTo: reply, call: call, context: context)
                }
            }
        }
        let events = await probe.events
        expectNoDifference(events, ["empty", "wrong-scope"].contains(mode) ? [] :
            ["deny", "revoke"].contains(mode) ? ["approve"] : ["approve", "commit"])
    }
}
