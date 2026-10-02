import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
import FiliconAppServices
import FiliconPersistence

private let repeatedOrigin = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
private let repeatedSender = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
private let repeatedMessage = UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
private let repeatedRun = UUID(uuidString: "00000000-0000-0000-0000-000000000074")!
private let repeatedDate = Date(timeIntervalSince1970: 1_000)

private func repeatedPNG(byteCount: Int? = nil) throws -> Data {
    var data = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNgAAAAAgABSK+kcQAAAABJRU5ErkJggg=="))
    if let byteCount {
        try #require(byteCount >= data.count)
        data.append(Data(repeating: 0, count: byteCount - data.count))
    }
    expectNoDifference(try AgentImageStore.validate(data), "image/png")
    return data
}

private func repeatedMetadata(_ image: PreparedAgentGalleryImage) -> AttachmentMetadata {
    .init(id: image.file.digest, filename: image.file.filename, mimeType: image.mimeType,
        byteCount: Int64(image.file.bytes.count), kind: .image, createdAt: repeatedDate, altText: image.altText)
}

private func repeatedSources(_ count: Int, source: String) throws -> [AgentGalleryPublicationTransaction.Image] {
    try (0..<count).map { index in
        // Exact duplicates and same-source/different-description occurrences
        // coexist. The source is deliberately not a unique UI identity.
        let alt = "Occurrence \(index / 2)"
        if source == "remote" || source == "mixed" && index.isMultiple(of: 2) {
            return .remote(try .init(url: "https://example.com/same?signature=a%2Bb", alt: alt))
        }
        return .local(try .init(bytes: repeatedPNG(), filename: "same.png", altText: alt))
    }
}

private func repeatedReceipt(_ review: AgentGalleryPublicationTransaction.Review,
                             remoteOverride: RemoteImageGallery? = nil) -> RoomMessage {
    var message = RoomMessage(id: repeatedMessage, groupID: review.conversationID, senderID: review.senderID,
        text: review.text, createdAt: repeatedDate, images: review.localImages.map(repeatedMetadata),
        remoteImages: remoteOverride ?? review.gallery, imageGalleryLayout: review.layout)
    message.replyToMessageID = review.replyTo
    return message
}

private func repeatedCall(_ sources: [AgentGalleryPublicationTransaction.Image]) throws -> NormalizedToolCall {
    let inputs = sources.map { source -> [String: String] in
        switch source {
        case let .remote(reference): ["url": reference.url, "alt": reference.alt!]
        case let .local(image): ["url": "file:///fixture/same.png", "alt": image.altText!]
        }
    }
    return try .init(id: "repeated-gallery", name: "SendMessage", argumentsJSON: JSONSerialization.data(
        withJSONObject: ["type": "text", "content": "Compare every occurrence", "images": inputs], options: [.sortedKeys]))
}

private func repeatedChat(source: String) throws -> ChatMessage {
    let sources = try repeatedSources(17, source: source)
    let local = sources.compactMap { image -> AttachmentMetadata? in
        if case let .local(value) = image { return repeatedMetadata(value) }; return nil
    }
    let remote = sources.compactMap { image -> RemoteAttachmentReference? in
        if case let .remote(value) = image { return value }; return nil
    }
    let layout = try ImageGalleryLayout(items: sources.map { image in
        switch image {
        case let .local(value): .attachment(value.file.digest)
        case let .remote(value): .remote(value)
        }
    })
    return ChatMessage(id: repeatedMessage, role: .assistant, text: "Compare every occurrence",
        createdAt: repeatedDate, attachments: local, shortAddress: "t0s0",
        remoteImages: remote.isEmpty ? nil : try RemoteImageGallery(images: remote), imageGalleryLayout: layout)
}

private actor RepeatedGalleryProbe {
    var events: [String] = []
    var reviews: [AgentGalleryPublicationTransaction.Review] = []
    var valid = true
    func record(_ value: String) { events.append(value) }
    func review(_ value: AgentGalleryPublicationTransaction.Review) { events.append("review"); reviews.append(value) }
    func revoke() { valid = false }
    func validate() throws {
        guard valid else { throw AgentGalleryPublicationTransaction.Failure.unavailable }
    }
}

@Suite("Reviewed galleries preserve repeated source occurrences", .timeLimit(.minutes(1)))
struct RepeatedImageGalleryTests {
    @Test(arguments: [2, 5, 17], ["remote", "local", "mixed"])
    func orderedRepeatedSourcesRoundTripWithoutLosingCaptions(count: Int, source: String) throws {
        let images = try repeatedSources(count, source: source)
        let locals = images.compactMap { image -> AttachmentMetadata? in
            if case let .local(value) = image { return repeatedMetadata(value) }; return nil
        }
        let references = images.compactMap { image -> RemoteAttachmentReference? in
            if case let .remote(value) = image { return value }; return nil
        }
        let gallery = references.isEmpty ? nil : try RemoteImageGallery(images: references)
        let layout = try ImageGalleryLayout(items: images.map { image in
            switch image {
            case let .local(value): .attachment(value.file.digest)
            case let .remote(value): .remote(value)
            }
        })
        expectNoDifference(layout.items.count, count)
        expectNoDifference(layout.matches(attachments: locals, remoteGallery: gallery), true)
        var localIndex = 0
        let expected = images.map { image -> ImageGalleryLayout.ResolvedItem in
            switch image {
            case let .local(value):
                let index = localIndex
                localIndex += 1
                return .attachment(repeatedMetadata(value), index: index)
            case let .remote(value):
                return .remote(value)
            }
        }
        expectNoDifference(layout.resolvedItems(attachments: locals, remoteGallery: gallery), expected)
        expectNoDifference(gallery?.images.count, images.count - locals.count == 0 ? nil : images.count - locals.count)
        let room = RoomMessage(id: repeatedMessage, groupID: repeatedOrigin, senderID: repeatedSender,
            text: "Compare every occurrence", createdAt: repeatedDate, images: locals, remoteImages: gallery, imageGalleryLayout: layout)
        let chat = ChatMessage(id: repeatedMessage, role: .assistant, text: room.text, createdAt: repeatedDate,
            attachments: locals, remoteImages: gallery, imageGalleryLayout: layout)
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(room)), room)
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(chat)), chat)
        expectNoDifference(layout.matches(attachments: Array(locals.dropLast()), remoteGallery: gallery), locals.isEmpty)
        if let gallery, gallery.images.count > 1 {
            expectNoDifference(layout.matches(attachments: locals,
                remoteGallery: try RemoteImageGallery(images: Array(gallery.images.dropLast()))), false)
        }
    }

    @Test func repeatedCapturedBytesHaveOneBlobAndOccurrenceLocalMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-image-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AgentImageStore(rootURL: root)
        let bytes = try repeatedPNG()
        let images = try (0..<5).map {
            try PreparedAgentGalleryImage(bytes: bytes, filename: "alias-\($0).png", altText: "Caption \($0)")
        }
        var saved: [AttachmentMetadata] = []
        for image in images { saved.append(try await store.importCapturedGalleryImage(image, createdAt: repeatedDate)) }
        expectNoDifference(saved, images.map(repeatedMetadata))
        expectNoDifference(Set(saved.map(\.id)).count, 1)
        let inventory = try await store.storageInventory()
        expectNoDifference(inventory, .init(active: [saved[0].id: Int64(bytes.count)], quarantined: [:], temporaryFiles: []))
        let reopened = AgentImageStore(rootURL: root)
        let loaded = try await reopened.loadPublishedGallery(saved)
        expectNoDifference(loaded, saved.map { .init(metadata: $0, data: bytes) })
        await #expect(throws: AgentImageError.limit) { try await reopened.load(Array(saved.prefix(2))) }
        var changed = saved
        changed[1] = .init(id: saved[1].id, filename: saved[1].filename, mimeType: "image/jpeg",
            byteCount: saved[1].byteCount, kind: .image, createdAt: repeatedDate, altText: saved[1].altText)
        await #expect(throws: AgentImageError.invalid) { try await reopened.loadPublishedGallery(changed) }
    }

    @Test(arguments: ["remote", "local", "mixed"])
    func toolReviewsEveryOccurrenceAndExactReplayDoesNotReadOrSaveAgain(source: String) async throws {
        let images = try repeatedSources(5, source: source), probe = RepeatedGalleryProbe()
        let transaction = AgentGalleryPublicationTransaction(conversationID: repeatedOrigin, senderID: repeatedSender,
            validateScope: { try await probe.validate() }, prepareLocalImage: { url, alt, _, _ in
                expectNoDifference(url, "file:///fixture/same.png")
                await probe.record("read:\(alt ?? "")")
                return try .init(bytes: repeatedPNG(), filename: "same.png", altText: alt)
            }, authorize: { review, _, _ in await probe.review(review) }, commit: { review, _, _ in
                await probe.record("save")
                return .init(review: review, message: repeatedReceipt(review))
            })
        let tool = AgentUserMessageTool(conversationID: repeatedOrigin, senderID: repeatedSender,
            replyHistory: [], supportsQuestions: false, galleryPublication: transaction,
            publishGroup: { _, _, _, _ in Issue.record("Unreviewed fallback"); return nil })
        let context = ToolContext(conversationID: repeatedOrigin, runID: repeatedRun), call = try repeatedCall(images)
        let result = try await tool.execute(call, context: context)
        expectNoDifference(result.isError, false)
        try #require(!result.isError)
        let reviews = await probe.reviews
        expectNoDifference(reviews.count, 1)
        let review = try #require(reviews.first)
        expectNoDifference(review.conversationID, repeatedOrigin)
        expectNoDifference(review.senderID, repeatedSender)
        expectNoDifference(review.text, "Compare every occurrence")
        expectNoDifference(review.images, images)
        expectNoDifference(review.replyTo, nil)
        let events = await probe.events
        expectNoDifference(events, images.compactMap { image -> String? in
            if case let .local(value) = image { return "read:\(value.altText!)" }; return nil
        } + ["review", "save"])
        let replay = try await tool.execute(call, context: context)
        expectNoDifference(replay, result)
        let replayEvents = await probe.events
        expectNoDifference(replayEvents, events)
        #expect(try await tool.execute(repeatedCall(Array(images.reversed())), context: context).isError)
        let changedEvents = await probe.events
        expectNoDifference(changedEvents, events)
        let otherCall = try NormalizedToolCall(id: "different-call", name: call.name, argumentsJSON: call.argumentsJSON)
        await #expect(throws: AgentGalleryPublicationTransaction.Failure.duplicateCall) {
            try await transaction.publish(text: "Compare every occurrence", images: images, replyTo: nil,
                call: otherCall, context: context)
        }
        let otherCallEvents = await probe.events
        expectNoDifference(otherCallEvents, events)
    }

    @Test(arguments: ["read-deny", "review-deny", "revoke"])
    func repeatedSourcesDoNotBypassReadPublicationOrAccountApproval(mode: String) async throws {
        let probe = RepeatedGalleryProbe(), images = try repeatedSources(5, source: "local")
        let transaction = AgentGalleryPublicationTransaction(conversationID: repeatedOrigin, senderID: repeatedSender,
            validateScope: { try await probe.validate() }, prepareLocalImage: { _, alt, _, _ in
                await probe.record("read")
                if mode == "read-deny" { throw AgentMessagingError.approvalRequired }
                return try .init(bytes: repeatedPNG(), filename: "same.png", altText: alt)
            }, authorize: { review, _, _ in
                await probe.review(review)
                if mode == "review-deny" { throw AgentMessagingError.approvalRequired }
                if mode == "revoke" { await probe.revoke() }
            }, commit: { review, _, _ in
                await probe.record("save")
                return .init(review: review, message: repeatedReceipt(review))
            })
        let tool = AgentUserMessageTool(conversationID: repeatedOrigin, senderID: repeatedSender,
            replyHistory: [], supportsQuestions: false, galleryPublication: transaction,
            publishGroup: { _, _, _, _ in Issue.record("Unreviewed fallback"); return nil })
        #expect(try await tool.execute(repeatedCall(images), context: .init(conversationID: repeatedOrigin, runID: repeatedRun)).isError)
        let events = await probe.events
        expectNoDifference(events, mode == "read-deny" ? ["read"] : Array(repeating: "read", count: 5) + ["review"])
    }

    @Test(arguments: ["local-order", "filename", "remote-alt", "drop"])
    func receiptMustPreserveEachOccurrenceAndFailedCommitCannotBeRetried(mode: String) async throws {
        let probe = RepeatedGalleryProbe(), images = try repeatedSources(5, source: "mixed")
        let transaction = AgentGalleryPublicationTransaction(conversationID: repeatedOrigin, senderID: repeatedSender,
            validateScope: {}, authorize: { review, _, _ in await probe.review(review) }, commit: { review, _, _ in
                var message = repeatedReceipt(review)
                if mode == "local-order" { message.images?.reverse() }
                if mode == "filename", let original = message.images?.first {
                    message.images?[0] = .init(id: original.id, filename: "Not reviewed.png", mimeType: original.mimeType,
                        byteCount: original.byteCount, kind: .image, createdAt: original.createdAt, altText: original.altText)
                }
                if mode == "remote-alt" {
                    var references = try #require(message.remoteImages?.images)
                    references[1] = try .init(url: references[1].url, alt: "Not reviewed")
                    message = repeatedReceipt(review, remoteOverride: try .init(images: references))
                }
                if mode == "drop" { message.images?.removeLast() }
                await probe.record("save")
                return .init(review: review, message: message)
            })
        let call = try repeatedCall(images), context = ToolContext(conversationID: repeatedOrigin, runID: repeatedRun)
        await #expect(throws: AgentGalleryPublicationTransaction.Failure.invalidReceipt) {
            try await transaction.publish(text: "Compare every occurrence", images: images, replyTo: nil, call: call, context: context)
        }
        await #expect(throws: AgentGalleryPublicationTransaction.Failure.uncertainCommit) {
            try await transaction.publish(text: "Compare every occurrence", images: images, replyTo: nil, call: call, context: context)
        }
        let events = await probe.events
        expectNoDifference(events, ["review", "save"])
    }

    @Test(arguments: [4, 5])
    func repeatedBytesStillCountTowardThePublicationMemoryBudget(count: Int) async throws {
        let image = try PreparedAgentGalleryImage(bytes: repeatedPNG(byteCount: 3 * 1_024 * 1_024),
            filename: "same.png", altText: "Repeated")
        let images = Array(repeating: AgentGalleryPublicationTransaction.Image.local(image), count: count)
        let metadata = Array(repeating: repeatedMetadata(image), count: count), probe = RepeatedGalleryProbe()
        let transaction = AgentGalleryPublicationTransaction(conversationID: repeatedOrigin, senderID: repeatedSender,
            validateScope: {}, authorize: { review, _, _ in await probe.review(review) }, commit: { review, _, _ in
                await probe.record("save")
                return .init(review: review, message: repeatedReceipt(review))
            })
        let context = ToolContext(conversationID: repeatedOrigin, runID: repeatedRun), call = try repeatedCall(images)
        if count == 4 {
            try AgentImageStore.validatePublishedGalleryMetadata(metadata)
            let receipt = try await transaction.publish(text: "Compare", images: images, replyTo: nil, call: call, context: context)
            expectNoDifference(receipt.message.images, metadata)
        } else {
            #expect(throws: AgentImageError.galleryLimit) { try AgentImageStore.validatePublishedGalleryMetadata(metadata) }
            await #expect(throws: AgentGalleryPublicationTransaction.Failure.invalidGallery) {
                try await transaction.publish(text: "Compare", images: images, replyTo: nil, call: call, context: context)
            }
        }
        let events = await probe.events
        expectNoDifference(events, count == 4 ? ["review", "save"] : [])
    }

    @Test func locatorSchemaPermitsRepeatsButHostImageIDsStayUnique() async throws {
        let image = try PreparedAgentGalleryImage(bytes: repeatedPNG(), filename: "same.png", altText: "Caption")
        let metadata = repeatedMetadata(image)
        let transaction = AgentGalleryPublicationTransaction(conversationID: repeatedOrigin, senderID: repeatedSender,
            validateScope: {}, authorize: { _, _, _ in }, commit: { _, _, _ in throw AgentImageError.invalid })
        let tool = AgentUserMessageTool(conversationID: repeatedOrigin, senderID: repeatedSender,
            replyHistory: [], supportsQuestions: false, availableImages: [metadata],
            imageStore: AgentImageStore(rootURL: URL(fileURLWithPath: "/unused-repeated-gallery-fixture")),
            galleryPublication: transaction, publishGroup: { _, _, _, _ in Issue.record("Host duplicates published"); return nil })
        let schema = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let field = try #require(properties["images"] as? [String: Any])
        let variants = try #require(field["anyOf"] as? [[String: Any]])
        expectNoDifference(variants[0]["uniqueItems"] as? Bool, true)
        expectNoDifference(variants[0]["maxItems"] as? Int, 4)
        #expect(variants[1]["uniqueItems"] as? Bool != true)
        #expect(variants[1]["maxItems"] == nil)
        let call = try NormalizedToolCall(id: "host-duplicates", name: "SendMessage", argumentsJSON: JSONSerialization.data(
            withJSONObject: ["text": "Do not publish", "images": [metadata.id, metadata.id]]))
        #expect(try await tool.execute(call, context: .init(conversationID: repeatedOrigin, runID: repeatedRun)).isError)
    }

    @Test func repeatedCapturesShareReachabilityWithoutSharingNamesOrCaptions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-references-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = try AttachmentReferenceRepository(databaseURL: root.appending(path: "index.sqlite"))
        let store = AttachmentStore(rootURL: root.appending(path: "attachments"))
        let lifecycle = AttachmentLifecycle(store: store, references: index, clock: { repeatedDate })
        let owner = AttachmentReferenceOwner(conversationID: repeatedOrigin, messageID: repeatedMessage)
        let bytes = try repeatedPNG()
        var metadata: [AttachmentMetadata] = []
        for ordinal in 0..<5 {
            let image = try PreparedAgentGalleryImage(bytes: bytes, filename: "alias-\(ordinal).png", altText: "Caption \(ordinal)")
            let upload = try await lifecycle.stage(prepared: image.file, verifiedImageMIMEType: image.mimeType)
            var saved = try await lifecycle.commit(upload, to: owner)
            saved.altText = image.altText
            expectNoDifference(saved, repeatedMetadata(image))
            metadata.append(saved)
        }
        let references = try await index.references(owner: owner)
        expectNoDifference(references, [.init(blobID: metadata[0].id, owner: owner)])
        let usage = try await lifecycle.usage()
        expectNoDifference(usage, .init(activeBytes: Int64(bytes.count), quarantinedBytes: 0, stagedBytes: 0, uniqueBlobCount: 1))
        for image in metadata {
            let loaded = try await lifecycle.data(for: image, owner: owner)
            expectNoDifference(loaded, bytes)
        }
        let pending = try await lifecycle.stage(prepared: .init(bytes: bytes, filename: "pending.png"), verifiedImageMIMEType: "image/png")
        try await lifecycle.abort(pending)
        let referencedAfterAbort = try await index.referenceCount(blobID: metadata[0].id)
        expectNoDifference(referencedAfterAbort, 1)
        let inventory = try await store.inventory()
        expectNoDifference(inventory, .init(active: [metadata[0].id: Int64(bytes.count)], quarantined: [:], temporaryFiles: []))
        try await lifecycle.removeReferences(owner: owner)
        let removed = try await index.references(owner: owner)
        expectNoDifference(removed, [])
        let quarantined = try await store.inventory()
        expectNoDifference(quarantined, .init(active: [:], quarantined: [metadata[0].id: Int64(bytes.count)], temporaryFiles: []))
    }

    @Test(arguments: ["size", "mime", "kind", "missing"])
    func oneDigestCannotResolveToConflictingCanonicalSources(mode: String) throws {
        let prepared = try PreparedAgentGalleryImage(bytes: repeatedPNG(), filename: "same.png", altText: "First")
        let first = repeatedMetadata(prepared)
        let second = AttachmentMetadata(id: first.id, filename: "alias.png",
            mimeType: mode == "mime" ? "image/jpeg" : first.mimeType,
            byteCount: mode == "size" ? first.byteCount + 1 : first.byteCount,
            kind: mode == "kind" ? .document : .image, createdAt: first.createdAt, altText: "Second")
        let layout = try ImageGalleryLayout(items: [.attachment(first.id), .attachment(first.id)])
        let images = mode == "missing" ? [first] : [first, second]
        expectNoDifference(layout.matches(attachments: images, remoteGallery: nil), false)
        expectNoDifference(layout.resolvedItems(attachments: images, remoteGallery: nil), nil)
        let chat = ChatMessage(id: repeatedMessage, role: .assistant, text: "Compare",
            createdAt: repeatedDate, attachments: images, imageGalleryLayout: layout)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(chat)) }
    }

    @Test(arguments: ["remote", "local", "mixed"])
    func sqliteReopenAndPagingKeepEveryRepeatedOccurrence(source: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-sqlite-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let images = try repeatedSources(17, source: source)
        let local = images.compactMap { image -> AttachmentMetadata? in
            if case let .local(value) = image { return repeatedMetadata(value) }; return nil
        }
        let remote = images.compactMap { image -> RemoteAttachmentReference? in
            if case let .remote(value) = image { return value }; return nil
        }
        let gallery = remote.isEmpty ? nil : try RemoteImageGallery(images: remote)
        let layout = try ImageGalleryLayout(items: images.map { image in
            switch image {
            case let .local(value): .attachment(value.file.digest)
            case let .remote(value): .remote(value)
            }
        })
        let message = ChatMessage(id: repeatedMessage, role: .assistant, text: "Compare every occurrence",
            createdAt: repeatedDate, attachments: local, shortAddress: "t0s0", remoteImages: gallery, imageGalleryLayout: layout)
        let conversation = Conversation(id: repeatedOrigin, messages: [message])
        let url = root.appending(path: "conversation.sqlite3")
        let repository = try ConversationRepository(databaseURL: url)
        try await repository.save([conversation])
        let reopened = try ConversationRepository(databaseURL: url)
        let loaded = try await reopened.load()
        expectNoDifference(loaded.first?.messages, [message])
        let page = try await reopened.messagePage(conversationID: repeatedOrigin, request: .init(limit: 1))
        expectNoDifference(page.items, [message])
        try await reopened.save(loaded)
        let secondReopen = try ConversationRepository(databaseURL: url)
        let second = try await secondReopen.load()
        expectNoDifference(second.first?.messages, [message])
    }

    @Test(arguments: ["remote", "local", "mixed"])
    func storeReopenPreservesTranscriptOccurrencesAndBoundedMemorySourceIDs(source: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-transcript-store-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "conversations.json")
        let user = ChatMessage(id: repeatedSender, role: .user, text: "Compare", createdAt: repeatedDate)
        let message = try repeatedChat(source: source)
        let conversation = Conversation(id: repeatedOrigin, messages: [user, message])
        let store = ConversationStore(fileURL: url)
        try await store.upsert(conversation, replacingLoadedMessageIDs: [], historyComplete: true)
        let initial = try await store.subscribeTranscript(conversationID: repeatedOrigin)
        expectNoDifference(initial.snapshot.messages, conversation.messages)
        let memory = try await store.recordFinalAssistantTurn(conversationID: repeatedOrigin,
            userMessageID: user.id, assistantMessageID: message.id)
        // The transcript retains every occurrence. Bounded recall deliberately
        // stores unique content IDs, not duplicate copies of the same blob.
        expectNoDifference(memory.attachments, Array(message.attachments.prefix(1)))
        expectNoDifference(memory.attachmentIDs, message.attachments.first.map { [$0.id] } ?? [])
        let reopened = ConversationStore(fileURL: url)
        let loaded = try await reopened.conversation(id: repeatedOrigin)
        expectNoDifference(loaded?.messages, conversation.messages)
        let replica = try await reopened.subscribeTranscript(conversationID: repeatedOrigin)
        expectNoDifference(replica.snapshot.messages, conversation.messages)
        let recoveredMemory = try await reopened.recentTurnMemory(conversationID: repeatedOrigin)
        expectNoDifference(recoveredMemory, [memory])
        let repeatedMemory = try await reopened.recordFinalAssistantTurn(conversationID: repeatedOrigin,
            userMessageID: user.id, assistantMessageID: message.id)
        expectNoDifference(repeatedMemory, memory)
    }

    @Test(arguments: ["remote", "local", "mixed"], ["normal", "afterJournal", "afterCheckpoint"])
    func transcriptJournalReplaysEveryOccurrenceExactlyOnce(source: String, stage: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fault = TranscriptCommitStage(rawValue: stage)
        let hub = try TranscriptEventHub(conversationID: repeatedOrigin, replicaDirectoryURL: root, faultAt: fault)
        let message = try repeatedChat(source: source)
        if let fault {
            await #expect(throws: TranscriptHubError.injectedFailure(fault)) { try await hub.append(message) }
        } else {
            let subscription = await hub.subscribe()
            var events = subscription.events.makeAsyncIterator()
            let append = try await hub.append(message)
            let observedAppend = try await events.next()
            expectNoDifference(observedAppend, append)
            var changed = message
            changed.text = "Updated comparison"
            for index in changed.attachments.indices { changed.attachments[index].altText = "Updated \(index)" }
            let update = try await hub.update(changed)
            let observedUpdate = try await events.next()
            expectNoDifference(observedUpdate, update)
            _ = try await hub.update(message)
        }
        let recovered = try TranscriptEventHub(conversationID: repeatedOrigin, replicaDirectoryURL: root)
        let snapshot = await recovered.snapshot()
        expectNoDifference(snapshot.messages, [message])
        let reopenedAgain = try TranscriptEventHub(conversationID: repeatedOrigin, replicaDirectoryURL: root)
        let secondSnapshot = await reopenedAgain.snapshot()
        expectNoDifference(secondSnapshot.messages, [message])
    }

    @Test(arguments: ["ordinary", "size", "mime", "kind", "missing", "remote"])
    func transcriptRejectsUnorderedDuplicatesAndConflictingGallerySources(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-repeated-gallery-invalid-journal-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let hub = try TranscriptEventHub(conversationID: repeatedOrigin, replicaDirectoryURL: root)
        var message = try repeatedChat(source: "mixed")
        switch mode {
        case "ordinary": message.imageGalleryLayout = nil
        case "size", "mime", "kind":
            let original = message.attachments[1]
            message.attachments[1] = .init(id: original.id, filename: original.filename,
                mimeType: mode == "mime" ? "image/jpeg" : original.mimeType,
                byteCount: original.byteCount + (mode == "size" ? 1 : 0),
                kind: mode == "kind" ? .document : original.kind, createdAt: original.createdAt, altText: original.altText)
        case "missing": message.attachments.removeLast()
        case "remote": message.remoteImages = nil
        default: Issue.record("Invalid fixture")
        }
        await #expect(throws: TranscriptHubError.self) { try await hub.append(message) }
        let snapshot = await hub.snapshot()
        expectNoDifference(snapshot.messages, [])
        expectNoDifference(snapshot.fence.throughSequence, 0)
        let reopened = try TranscriptEventHub(conversationID: repeatedOrigin, replicaDirectoryURL: root)
        let reopenedSnapshot = await reopened.snapshot()
        expectNoDifference(reopenedSnapshot.messages, [])
    }
}
