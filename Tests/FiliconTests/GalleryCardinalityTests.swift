import Foundation
import CoreGraphics
import ImageIO
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
import FiliconAppServices

private let cardinalityOrigin = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let cardinalitySender = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let cardinalityMessage = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
private let cardinalityReply = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
private let cardinalityRun = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
private let cardinalityDate = Date(timeIntervalSince1970: 1_000)

private actor CardinalityProbe {
    var events: [String] = []
    var reviews: [AgentGalleryPublicationTransaction.Review] = []
    var messages: [RoomMessage] = []
    var valid = true
    func record(_ event: String) { events.append(event) }
    func review(_ value: AgentGalleryPublicationTransaction.Review) { events.append("review"); reviews.append(value) }
    func save(_ value: RoomMessage) { events.append("save"); messages.append(value) }
    func revoke() { valid = false }
    func validate() throws {
        guard valid else { throw AgentGalleryPublicationTransaction.Failure.unavailable }
    }
}

private func cardinalityPNG(_ index: Int, byteCount: Int? = nil, width: Int = 1, height: Int = 1) throws -> Data {
    // Exact pixel bytes, not neighboring grayscale values which color-space
    // conversion may quantize to the same content-addressed image.
    let pixel: [UInt8] = [UInt8(truncatingIfNeeded: index + 1), UInt8(truncatingIfNeeded: (index + 1) >> 8), 0, 255]
    var pixels = Data()
    for _ in 0..<(width * height) { pixels.append(contentsOf: pixel) }
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let bytes = NSMutableData()
    let writer = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(writer, image, nil)
    try #require(CGImageDestinationFinalize(writer))
    var result = bytes as Data
    if let byteCount {
        try #require(result.count <= byteCount)
        result.append(Data(repeating: 0, count: byteCount - result.count))
    }
    expectNoDifference(try AgentImageStore.validate(result), "image/png")
    return result
}

private func cardinalityImages(_ count: Int, source: String) throws -> [AgentGalleryPublicationTransaction.Image] {
    try (0..<count).map { index in
        if source == "remote" || source == "mixed" && index.isMultiple(of: 2) {
            return .remote(try RemoteAttachmentReference(url: "https://example.com/image-\(index)", alt: "Image \(index)"))
        }
        return .local(try PreparedAgentGalleryImage(bytes: cardinalityPNG(index), filename: "image-\(index).png", altText: "Image \(index)"))
    }
}

private func cardinalityMetadata(_ image: PreparedAgentGalleryImage) -> AttachmentMetadata {
    .init(id: image.file.digest, filename: image.file.filename, mimeType: image.mimeType,
        byteCount: Int64(image.file.bytes.count), kind: .image, createdAt: cardinalityDate, altText: image.altText)
}

private func cardinalityReceipt(_ review: AgentGalleryPublicationTransaction.Review, destination: UUID? = nil) -> RoomMessage {
    var message = RoomMessage(id: cardinalityMessage, groupID: destination ?? review.conversationID, senderID: review.senderID,
        text: review.text, createdAt: cardinalityDate, images: review.localImages.map(cardinalityMetadata),
        remoteImages: review.gallery, imageGalleryLayout: review.layout)
    message.replyToMessageID = review.replyTo
    return message
}

private func cardinalityCall(images: [[String: String]], extraText: String = "Compare every image",
                             reply: Bool = false) throws -> NormalizedToolCall {
    var arguments: [String: Any] = ["type": "text", "content": extraText, "images": images]
    if reply { arguments["reply_to"] = cardinalityReply.uuidString }
    return try .init(id: "gallery", name: "SendMessage",
        argumentsJSON: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
}

@Suite("Reviewed galleries have no arbitrary image count cap", .timeLimit(.minutes(1)))
struct GalleryCardinalityTests {
    @Test(arguments: [1, 64, 640, 1_024])
    func displayThumbnailsAreBoundedAndNeverReplaceVerifiedOriginals(dimension: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-gallery-thumbnail-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentImageStore(rootURL: root)
        let prepared = try PreparedAgentGalleryImage(bytes: cardinalityPNG(0, width: 1_600, height: 400),
            filename: "wide.png", altText: "Original wide image")
        let metadata = try await store.importCapturedGalleryImage(prepared, createdAt: cardinalityDate)
        let thumbnail = try await store.thumbnail(for: metadata, maximumDimension: dimension)
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        expectNoDifference(CGImageSourceGetType(source) as String?, "public.png")
        expectNoDifference(image.width, dimension)
        expectNoDifference(image.height, max(1, dimension / 4))
        #expect(thumbnail != prepared.file.bytes)
        let originals = try await store.loadPublishedGallery([metadata])
        expectNoDifference(originals, [.init(metadata: metadata, data: prepared.file.bytes)])
        let defaultThumbnail = try await store.thumbnail(for: metadata)
        let defaultSource = try #require(CGImageSourceCreateWithData(defaultThumbnail as CFData, nil))
        let defaultImage = try #require(CGImageSourceCreateImageAtIndex(defaultSource, 0, nil))
        expectNoDifference(defaultImage.width, 640)
        expectNoDifference(defaultImage.height, 160)
    }

    @Test(arguments: ["zero", "too-large", "corrupt", "wrong-mime", "cancelled"])
    func displayThumbnailsFailClosed(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-gallery-thumbnail-fence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentImageStore(rootURL: root)
        let prepared = try PreparedAgentGalleryImage(bytes: cardinalityPNG(0), filename: "image.png", altText: nil)
        let metadata = try await store.importCapturedGalleryImage(prepared, createdAt: cardinalityDate)
        switch mode {
        case "zero", "too-large":
            await #expect(throws: AgentImageError.invalid) {
                try await store.thumbnail(for: metadata, maximumDimension: mode == "zero" ? 0 : 1_025)
            }
        case "corrupt":
            let blob = root.appending(path: String(metadata.id.prefix(2))).appending(path: metadata.id)
            try Data(repeating: 0, count: prepared.file.bytes.count).write(to: blob)
            await #expect(throws: AttachmentStoreError.corrupt(metadata.id)) {
                try await store.thumbnail(for: metadata)
            }
        case "wrong-mime":
            let changed = AttachmentMetadata(id: metadata.id, filename: metadata.filename, mimeType: "image/jpeg",
                byteCount: metadata.byteCount, kind: metadata.kind, createdAt: metadata.createdAt)
            await #expect(throws: AgentImageError.invalid) { try await store.thumbnail(for: changed) }
        default:
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await store.thumbnail(for: metadata)
            }
            await #expect(throws: CancellationError.self) { try await task.value }
            let originals = try await store.loadPublishedGallery([metadata])
            expectNoDifference(originals.map(\.data), [prepared.file.bytes])
        }
    }

    @Test(arguments: [5, 17, 100])
    func publicationLoaderKeepsEveryVerifiedBlobButInferenceStillRejectsMoreThanFour(count: Int) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-gallery-cardinality-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentImageStore(rootURL: root)
        let prepared = try (0..<count).map {
            try PreparedAgentGalleryImage(bytes: cardinalityPNG($0), filename: "image-\($0).png", altText: "Image \($0)")
        }
        var metadata: [AttachmentMetadata] = []
        for image in prepared { metadata.append(try await store.importCapturedGalleryImage(image, createdAt: cardinalityDate)) }
        expectNoDifference(metadata, prepared.map(cardinalityMetadata))
        let reopened = AgentImageStore(rootURL: root)
        let loaded = try await reopened.loadPublishedGallery(metadata)
        expectNoDifference(loaded, zip(metadata, prepared).map { InferenceAttachment(metadata: $0, data: $1.file.bytes) })
        await #expect(throws: AgentImageError.limit) { try await reopened.load(metadata) }
        let repeated = try await reopened.loadPublishedGallery(metadata + [metadata[0]])
        expectNoDifference(repeated, loaded + [loaded[0]])
        var changed = metadata
        let original = changed[0]
        changed[0] = .init(id: original.id, filename: original.filename, mimeType: "image/jpeg",
            byteCount: original.byteCount, kind: original.kind, createdAt: original.createdAt, altText: original.altText)
        await #expect(throws: AgentImageError.invalid) { try await reopened.loadPublishedGallery(changed) }
    }

    @Test(arguments: ["too-large", "aggregate", "conflicting-size", "not-image", "corrupt"])
    func publicationLoaderRetainsBoundsTypeAndIntegrityChecks(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-gallery-loader-fence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentImageStore(rootURL: root)
        let prepared = try PreparedAgentGalleryImage(bytes: cardinalityPNG(0), filename: "image.png", altText: "Image")
        let saved = try await store.importCapturedGalleryImage(prepared, createdAt: cardinalityDate)
        var images = [saved]
        if mode == "conflicting-size" {
            images.append(.init(id: saved.id, filename: "alias.png", mimeType: saved.mimeType,
                byteCount: saved.byteCount + 1, kind: .image, createdAt: cardinalityDate))
        }
        if mode == "too-large" {
            images[0] = .init(id: saved.id, filename: saved.filename, mimeType: saved.mimeType,
                byteCount: Int64(AgentImageStore.maximumBytes + 1), kind: .image, createdAt: cardinalityDate)
        }
        if mode == "aggregate" {
            images = (0..<5).map { index in
                .init(id: String(repeating: String(index), count: 64), filename: "\(index).png", mimeType: "image/png",
                    byteCount: 3 * 1_024 * 1_024, kind: .image, createdAt: cardinalityDate)
            }
        }
        if mode == "not-image" {
            images[0] = .init(id: saved.id, filename: saved.filename, mimeType: saved.mimeType,
                byteCount: saved.byteCount, kind: .document, createdAt: cardinalityDate)
        }
        if mode == "corrupt" {
            let blob = root.appending(path: String(saved.id.prefix(2))).appending(path: saved.id)
            try Data(repeating: 0, count: prepared.file.bytes.count).write(to: blob)
            await #expect(throws: AttachmentStoreError.corrupt(saved.id)) { try await store.loadPublishedGallery(images) }
        } else {
            await #expect(throws: ["not-image", "conflicting-size"].contains(mode) ? AgentImageError.invalid : .galleryLimit) {
                try await store.loadPublishedGallery(images)
            }
        }
    }

    @Test(arguments: [5, 17, 100], ["remote", "local", "mixed"])
    func exactOrderedLayoutsAndBothMessageKindsRoundTrip(count: Int, source: String) throws {
        let images = try cardinalityImages(count, source: source)
        let references = images.compactMap { image -> RemoteAttachmentReference? in
            if case let .remote(value) = image { return value }; return nil
        }
        let remote = references.isEmpty ? nil : try RemoteImageGallery(images: references)
        let local = images.compactMap { image -> AttachmentMetadata? in
            if case let .local(value) = image { return cardinalityMetadata(value) }; return nil
        }
        let layout = try ImageGalleryLayout(items: images.map { image in
            switch image {
            case let .local(value): .attachment(value.file.digest)
            case let .remote(value): .remote(value)
            }
        })
        expectNoDifference(layout.items.count, count)
        expectNoDifference(layout.matches(attachments: local, remoteGallery: remote), true)
        let room = RoomMessage(id: cardinalityMessage, groupID: cardinalityOrigin, senderID: cardinalitySender,
            text: "Compare every image", createdAt: cardinalityDate, images: local,
            remoteImages: remote, imageGalleryLayout: layout)
        let chat = ChatMessage(id: cardinalityMessage, role: .assistant, text: room.text, createdAt: cardinalityDate,
            attachments: local, remoteImages: remote, imageGalleryLayout: layout)
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(room)), room)
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(chat)), chat)
        if local.count > 1 {
            expectNoDifference(layout.matches(attachments: Array(local.reversed()), remoteGallery: remote), false)
        }
        if references.count > 1 {
            expectNoDifference(layout.matches(attachments: local,
                remoteGallery: try RemoteImageGallery(images: Array(references.reversed()))), false)
        }
    }

    @Test(arguments: [5, 17, 100], ["remote", "local", "mixed"])
    func toolReviewsAndSavesEveryImageOnceInOrder(count: Int, source: String) async throws {
        let images = try cardinalityImages(count, source: source), probe = CardinalityProbe()
        let transaction = AgentGalleryPublicationTransaction(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            validateScope: { try await probe.validate() }, prepareLocalImage: { url, alt, _, _ in
                let index = try #require(Int(URL(string: url)?.deletingPathExtension().lastPathComponent ?? ""))
                guard case let .local(image) = images[index] else { throw AgentImageError.invalid }
                expectNoDifference(alt, image.altText)
                await probe.record("read:\(index)")
                return image
            }, authorize: { review, _, _ in await probe.review(review) }, commit: { review, _, _ in
                let message = cardinalityReceipt(review)
                await probe.save(message)
                return .init(review: review, message: message)
            })
        let prior = RoomMessage(id: cardinalityReply, groupID: cardinalityOrigin, senderID: nil,
            text: "Earlier message", createdAt: cardinalityDate)
        let tool = AgentUserMessageTool(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            replyHistory: [prior], supportsQuestions: false, galleryPublication: transaction,
            publishGroup: { _, _, _, _ in Issue.record("Gallery escaped the reviewed publisher"); return nil })
        let entries = images.enumerated().map { index, image -> [String: String] in
            switch image {
            case let .remote(reference): ["url": reference.url, "alt": reference.alt!]
            case let .local(local): ["url": "file:///fixture/\(index).png", "alt": local.altText!]
            }
        }
        let call = try cardinalityCall(images: entries, reply: true)
        let context = ToolContext(conversationID: cardinalityOrigin, runID: cardinalityRun)
        let result = try await tool.execute(call, context: context)
        expectNoDifference(result.isError, false)
        try #require(!result.isError)
        let reviews = await probe.reviews, messages = await probe.messages
        let review = try #require(reviews.first)
        expectNoDifference(reviews.count, 1)
        expectNoDifference(review.images, images)
        expectNoDifference(review.text, "Compare every image")
        expectNoDifference(review.replyTo, cardinalityReply)
        expectNoDifference(review.conversationID, cardinalityOrigin)
        expectNoDifference(review.senderID, cardinalitySender)
        expectNoDifference(messages, [cardinalityReceipt(review)])
        expectNoDifference(review.layout?.items.count, count)
        let events = await probe.events
        let replay = try await tool.execute(call, context: context)
        expectNoDifference(replay, result)
        let replayEvents = await probe.events
        expectNoDifference(replayEvents, events)
        let changed = try cardinalityCall(images: Array(entries.reversed()), reply: true)
        #expect(try await tool.execute(changed, context: context).isError)
        let changedEvents = await probe.events
        expectNoDifference(changedEvents, events)
    }

    @Test(arguments: [false, true])
    func schemaSeparatesFourIncomingIDsFromUncappedLocatorArrays(local: Bool) throws {
        let prepareLocal: AgentGalleryPublicationTransaction.PrepareLocalImage?
        if local { prepareLocal = { _, _, _, _ in throw AgentImageError.invalid } }
        else { prepareLocal = nil }
        let transaction = AgentGalleryPublicationTransaction(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            validateScope: {}, prepareLocalImage: prepareLocal,
            authorize: { _, _, _ in }, commit: { _, _, _ in throw AgentImageError.invalid })
        let metadata = AttachmentMetadata(id: "current-image", filename: "image.png", mimeType: "image/png",
            byteCount: 100, kind: .image, createdAt: cardinalityDate)
        let store = AgentImageStore(rootURL: URL(fileURLWithPath: "/unused-cardinality-fixture"))
        let tool = AgentUserMessageTool(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            replyHistory: [], supportsQuestions: false, availableImages: [metadata], imageStore: store,
            galleryPublication: transaction, publishGroup: { _, _, _, _ in nil })
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let field = try #require(properties["images"] as? [String: Any])
        #expect(field["maxItems"] == nil)
        let variants = try #require(field["anyOf"] as? [[String: Any]])
        expectNoDifference(variants.count, 2)
        expectNoDifference(variants[0]["maxItems"] as? Int, 4)
        #expect(variants[1]["maxItems"] == nil)
        expectNoDifference(variants.map { $0["type"] as? String }, ["array", "array"])
        let description = try #require(tool.descriptor.description)
        #expect(!description.contains("1-4 distinct locators"))
        let ordinary = AgentUserMessageTool(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            replyHistory: [], supportsQuestions: false, availableImages: [metadata], imageStore: store,
            publishGroup: { _, _, _, _ in nil })
        let ordinarySchema = try #require(JSONSerialization.jsonObject(with: ordinary.descriptor.inputSchema) as? [String: Any])
        let ordinaryProperties = try #require(ordinarySchema["properties"] as? [String: Any])
        let ordinaryImages = try #require(ordinaryProperties["images"] as? [String: Any])
        expectNoDifference(ordinaryImages["maxItems"] as? Int, 4)
    }

    @Test(arguments: ["at-limit", "over-limit", "argument-budget"])
    func localCaptureStopsAtAggregateBudgetBeforePublication(mode: String) async throws {
        let probe = CardinalityProbe(), mib = 1_024 * 1_024
        let transaction = AgentGalleryPublicationTransaction(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            validateScope: {}, prepareLocalImage: { url, alt, _, _ in
                let index = try #require(Int(URL(string: url)?.deletingPathExtension().lastPathComponent ?? ""))
                await probe.record("read:\(index)")
                let size = mode == "at-limit" ? 4 * mib : index < 2 ? 5 * mib : 3 * mib
                return try PreparedAgentGalleryImage(bytes: cardinalityPNG(index, byteCount: size),
                    filename: "\(index).png", altText: alt)
            }, authorize: { review, _, _ in await probe.review(review) }, commit: { review, _, _ in
                let message = cardinalityReceipt(review)
                await probe.save(message)
                return .init(review: review, message: message)
            })
        let tool = AgentUserMessageTool(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            replyHistory: [], supportsQuestions: false, galleryPublication: transaction,
            publishGroup: { _, _, _, _ in Issue.record("Unexpected fallback"); return nil })
        let localCount = mode == "at-limit" ? 3 : 4
        var entries = (0..<6).map { index in
            ["url": index < localCount ? "file:///fixture/\(index).png" : "https://example.com/\(index)", "alt": "Image \(index)"]
        }
        if mode == "argument-budget" { entries = (0..<2_000).map { ["url": "file:///fixture/\($0).png", "alt": "Image \($0)"] } }
        let result = try await tool.execute(cardinalityCall(images: entries),
            context: ToolContext(conversationID: cardinalityOrigin, runID: cardinalityRun))
        expectNoDifference(result.isError, mode != "at-limit")
        let events = await probe.events
        expectNoDifference(events, mode == "argument-budget" ? [] : mode == "at-limit"
            ? ["read:0", "read:1", "read:2", "review", "save"] : ["read:0", "read:1", "read:2"])
        let messages = await probe.messages
        expectNoDifference(messages.count, mode == "at-limit" ? 1 : 0)
        if let message = messages.first {
            expectNoDifference(message.images?.map(\.byteCount), [Int64(4 * mib), Int64(4 * mib), Int64(4 * mib)])
            expectNoDifference(message.imageGalleryLayout?.items.count, 6)
        }
    }

    @Test(arguments: ["deny", "revoke", "order", "description", "destination", "source-size", "empty"])
    func largerGalleriesKeepReviewScopeReceiptAndOccurrenceFences(mode: String) async throws {
        let probe = CardinalityProbe()
        var images = try cardinalityImages(17, source: "mixed")
        if mode == "empty" { images.removeAll() }
        let transaction = AgentGalleryPublicationTransaction(conversationID: cardinalityOrigin, senderID: cardinalitySender,
            validateScope: { try await probe.validate() }, authorize: { review, _, _ in
                await probe.review(review)
                if mode == "deny" { throw AgentGalleryPublicationTransaction.Failure.unavailable }
                if mode == "revoke" { await probe.revoke() }
            }, commit: { review, _, _ in
                var message = cardinalityReceipt(review, destination: mode == "destination" ? cardinalityRun : nil)
                if mode == "order" { message.images?.reverse() }
                if mode == "description" { message.images?[0].altText = "Not reviewed" }
                if mode == "source-size", let original = message.images?.first {
                    message.images?[0] = .init(id: original.id, filename: original.filename, mimeType: original.mimeType,
                        byteCount: original.byteCount + 1, kind: .image, createdAt: original.createdAt, altText: original.altText)
                }
                await probe.save(message)
                return .init(review: review, message: message)
            })
        let expected: AgentGalleryPublicationTransaction.Failure = ["deny", "revoke"].contains(mode) ? .unavailable
            : mode == "empty" ? .invalidGallery : .invalidReceipt
        let call = try cardinalityCall(images: [])
        let context = ToolContext(conversationID: cardinalityOrigin, runID: cardinalityRun)
        await #expect(throws: expected) {
            try await transaction.publish(text: "Compare every image", images: images, replyTo: cardinalityReply,
                call: call, context: context)
        }
        let events = await probe.events
        expectNoDifference(events, mode == "empty" ? []
            : ["deny", "revoke"].contains(mode) ? ["review"] : ["review", "save"])
        if expected == .invalidReceipt {
            await #expect(throws: AgentGalleryPublicationTransaction.Failure.uncertainCommit) {
                try await transaction.publish(text: "Compare every image", images: images, replyTo: cardinalityReply,
                    call: call, context: context)
            }
        }
    }
}
