import Foundation
import ImageIO
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconAutoReview
import FiliconDomain
import FiliconLocalTools
import FiliconPersistence
import FiliconProviderKit
@testable import Filicon

private final class LocalGallerySaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var point: StorageQuotaFaultPoint?
    private var checkpoint = 0
    private var target = 1
    private var triggered = false

    func arm(_ mode: String) {
        lock.lock(); defer { lock.unlock() }
        point = mode.hasSuffix("reserve") ? .afterReservationPersist : .afterCommitPersist
        // Direct galleries install each captured blob in two independent
        // stores before the conversation; both physical copies are charged.
        target = mode.hasPrefix("message-") ? 5 : mode.hasPrefix("preview-") ? 2 : 1
    }
    var didTrigger: Bool { lock.lock(); defer { lock.unlock() }; return triggered }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        guard self.point == point else { return }
        checkpoint += 1
        guard checkpoint == target else { return }
        self.point = nil
        triggered = true
        throw CocoaError(.fileWriteUnknown)
    }
}

private struct LocalGalleryProvider: AIProvider {
    let images: [[String: String]]
    let bytes: [Data]
    let succeeds: Bool
    var destinationID: UUID?
    var recipientID: UUID?
    let descriptor = ProviderDescriptor(id: "local-gallery-fixture", displayName: "Gallery fixture", requiresAPIKey: false)

    func models() async throws -> [AIModel] {
        [.init(id: "vision", capabilities: .init(inputModalities: [.text, .image]))]
    }

    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let name: ToolName
                    let arguments: [String: Any]
                    if request.messages.last(where: { $0.role == .user })?.text == "Inspect previous gallery" {
                        let prior = try #require(request.messages.last(where: { $0.text == "Reviewed designs" }))
                        expectNoDifference(request.attachmentsByMessageID[prior.id]?.map(\.data), Optional(bytes))
                        name = "SendMessage"
                        arguments = ["text": "Gallery bytes verified"]
                    } else if let recipientID, request.messages.first?.text.contains("You are Sender,") == true {
                        name = "SendToAgent"
                        arguments = ["recipientID": recipientID.uuidString, "message": "Publish designs"]
                    } else if let destinationID, request.messages.first?.text.contains("Your name is Designer,") != true {
                        name = "SendToAgent"
                        arguments = ["recipientID": destinationID.uuidString, "message": "Publish designs"]
                    } else {
                        name = "SendMessage"
                        arguments = ["type": "text", "content": "Reviewed designs", "images": images]
                    }
                    let call = try NormalizedToolCall(id: "publish-gallery", name: name,
                        argumentsJSON: JSONSerialization.data(withJSONObject: arguments))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    if let exchange = request.toolExchanges.last, exchange.calls.first?.name == "SendMessage" {
                        let result = try #require(exchange.results.first)
                        expectNoDifference(result.isError, !succeeds)
                        expectNoDifference(result.wireText.contains("Saved message receipt:"), succeeds)
                        if succeeds { #expect(!result.isError, "\(result.wireText)") }
                    }
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

private struct SavedLocalGallery: Equatable {
    let id: UUID
    let text: String
    let images: [AttachmentMetadata]
    let remote: RemoteImageGallery?
    let layout: ImageGalleryLayout?

    init(_ message: ChatMessage) {
        id = message.id; text = message.text; images = message.attachments
        remote = message.remoteImages; layout = message.imageGalleryLayout
    }
    init(_ message: RoomMessage) {
        id = message.id; text = message.text; images = message.images ?? []
        remote = message.remoteImages; layout = message.imageGalleryLayout
    }
}

@Suite("App local and mixed image galleries", .timeLimit(.minutes(1)))
@MainActor struct LocalImageGalleryAppTests {
    @Test(arguments: ["approve", "deny", "stop", "account", "source-changed", "read-deny", "quota-unavailable", "misleading-name"],
        ["local-direct", "mixed-direct", "local-group", "mixed-group", "local-background", "mixed-background",
         "local-mailbox", "mixed-mailbox", "local-peer", "mixed-peer"])
    func localAndMixedSourcesUseCanonicalPublication(mode: String, scenario: String) async throws {
        try await exercise(mode: mode, scenario: scenario)
    }

    @Test(arguments: ["members", "destination-stop"],
        ["local-group", "mixed-group", "local-background", "mixed-background"])
    func groupRevocationPreventsLocalGalleryPublication(mode: String, scenario: String) async throws {
        try await exercise(mode: mode, scenario: scenario)
    }

    @Test(arguments: ["blob-reserve", "blob-late", "preview-reserve", "preview-late", "message-reserve", "message-late"],
        ["local-direct", "mixed-direct"])
    func directSaveFailuresRequireDurablePublication(mode: String, scenario: String) async throws {
        try await exercise(mode: mode, scenario: scenario)
    }

    @Test(arguments: ["blob-reserve", "blob-late"],
        ["local-group", "mixed-group", "local-background", "mixed-background",
         "local-mailbox", "mixed-mailbox", "local-peer", "mixed-peer"])
    func sessionImageSaveFailuresPreventPublication(mode: String, scenario: String) async throws {
        try await exercise(mode: mode, scenario: scenario)
    }

    private func exercise(mode: String, scenario: String) async throws {
        let route = String(scenario.split(separator: "-").last!), mixed = scenario.hasPrefix("mixed-")
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-local-gallery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let bytes = try [png(red: 0, blue: 1), png(red: 1, blue: 0)]
        let sources = [workspace.appending(path: mode == "misleading-name" ? "初稿 image.txt" : "初稿 image.png"),
            workspace.appending(path: mode == "misleading-name" ? "second" : "second.png")]
        for (source, data) in zip(sources, bytes) { try data.write(to: source) }
        let prepared = try zip(sources, bytes).enumerated().map { index, pair in
            try PreparedAgentGalleryImage(bytes: pair.1, filename: pair.0.lastPathComponent, altText: "Local \(index + 1)")
        }
        let remote = try RemoteImageGallery(images: [
            RemoteAttachmentReference(url: "https://example.com/a?signature=a%2Bb", alt: "Remote A"),
            RemoteAttachmentReference(url: "https://example.com/b", alt: "Remote B")])
        let inputs = sources.enumerated().map { ["url": $0.element.absoluteString, "alt": "Local \($0.offset + 1)"] }
        let imageInputs = mixed
            ? [["url": remote.images[0].url, "alt": "Remote A"], inputs[0],
               ["url": remote.images[1].url, "alt": "Remote B"], inputs[1]] : inputs
        let layout = try ImageGalleryLayout(items: mixed
            ? [.remote(remote.images[0]), .attachment(prepared[0].file.digest),
               .remote(remote.images[1]), .attachment(prepared[1].file.digest)]
            : prepared.map { .attachment($0.file.digest) })
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await grants.authorize(workspace)
        let generation = UUID(), key = Data(repeating: 13, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        if mode == "quota-unavailable" {
            let quotaRoot = root.appending(path: "quota")
            try FileManager.default.createDirectory(at: quotaRoot, withIntermediateDirectories: true)
            try Data("Invalid quota state".utf8).write(to: quotaRoot.appending(path: "storage-quota-v1.json"))
        }
        let saveFault = LocalGallerySaveFault()
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            quotaFaultInjector: { try saveFault.inject($0) })
        await model.bootstrap()
        try await model.localToolPermissionPolicy.setChoice(mode == "read-deny" ? .never : .always, for: .readFile)
        let succeeds = ["approve", "source-changed", "message-late", "misleading-name"].contains(mode)
        var provider = LocalGalleryProvider(images: imageInputs, bytes: bytes, succeeds: succeeds)
        await model.registry.register(provider)
        let senderValue = await model.createAgent(name: "Sender", summary: "", instructions: "",
            providerID: provider.descriptor.id, modelID: "vision")
        let sender = try #require(senderValue)
        var originID = try #require(model.selection), destinationID = originID
        var recipient: AgentProfile?
        if route == "group" || route == "background" {
            #expect(await model.createGroup(name: "Source", summary: "", memberIDs: [sender.id]))
            originID = try #require(model.groups.first(where: { $0.name == "Source" })).id
            destinationID = originID
            if route == "background" {
                let designerValue = await model.createAgent(name: "Designer", summary: "", instructions: "",
                    providerID: provider.descriptor.id, modelID: "vision")
                let designer = try #require(designerValue)
                #expect(await model.createGroup(name: "Destination", summary: "", memberIDs: [sender.id, designer.id]))
                destinationID = try #require(model.groups.first(where: { $0.name == "Destination" })).id
                provider.destinationID = destinationID
            }
        } else if route == "mailbox" || route == "peer" {
            let value = await model.createAgent(name: "Recipient", summary: "", instructions: "",
                providerID: provider.descriptor.id, modelID: "vision")
            recipient = try #require(value)
            if route == "peer" {
                originID = try #require(await model.addConversation(agentID: sender.id))
                provider.recipientID = recipient?.id
            }
        } else {
            let index = try #require(model.conversations.firstIndex(where: { $0.id == originID }))
            model.conversations[index].providerID = provider.descriptor.id
            model.conversations[index].modelID = "vision"
        }
        await model.registry.register(provider)
        await model.refreshModels()
        let mailboxRecipientID = recipient?.id
        let started = Task {
            if route == "group" || route == "background" {
                await model.sendGroupMessage(groupID: originID, text: "Publish designs")
            } else if route == "mailbox" {
                if let mailboxRecipientID {
                    #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: mailboxRecipientID, text: "Publish designs"))
                } else { Issue.record("Missing fixture recipient") }
            } else {
                model.draft = "Publish designs"
                model.send()
            }
        }
        defer { started.cancel() }
        var delegationID: String?
        if route == "background" || route == "peer" {
            let delegation = try await approval(model)
            delegationID = delegation.id
            expectNoDifference(delegation.action.context.metadata["tool"], "SendToAgent")
            if route == "peer" { model.handleTranscriptCardIntent(.approveReview(reviewID: delegation.id)) }
            else { await model.resolveGroupApproval(delegation, groupID: originID, approve: true) }
        }
        if !["read-deny", "quota-unavailable"].contains(mode) {
            let pending = try await approval(model, excluding: delegationID)
            originID = pending.action.context.conversationID
            expectNoDifference(pending.action.context.metadata["agentGalleryPublication"], "true")
            let details = try #require(pending.action.context.metadata["agentMessage"])
            for item in prepared {
                #expect(details.contains(item.file.filename))
                #expect(details.contains(item.file.digest))
                let alt = try #require(item.altText)
                #expect(details.contains(alt))
            }
            if mixed { for reference in remote.images { #expect(details.contains(reference.url)) } }
            #expect(model.conversations.flatMap(\.messages).allSatisfy { $0.imageGalleryLayout == nil })
            #expect(model.groupMessages.values.flatMap { $0 }.allSatisfy { $0.imageGalleryLayout == nil })
            #expect(model.agentMessages.flatMap { $0.delivery?.publications ?? [] }.allSatisfy { $0.imageGalleryLayout == nil })
            if mode == "source-changed" { for source in sources { try Data("Unreviewed replacement".utf8).write(to: source) } }
            if mode == "stop" {
                if route == "group" || route == "background" { await model.stopGroup(id: originID) }
                else if route == "mailbox" { await model.stopAgentMessages(scopeID: originID) }
                else { model.cancel() }
            }
            if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
            if mode == "members" { await model.updateGroupMembers(groupID: destinationID, memberIDs: []) }
            if mode == "destination-stop" { await model.stopGroup(id: destinationID) }
            if isSaveFailure(mode) { saveFault.arm(mode) }
            if route == "direct" {
                model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: pending.id) : .approveReview(reviewID: pending.id))
            } else { await model.resolveGroupApproval(pending, groupID: originID, approve: mode != "deny") }
        }
        await started.value
        try await waitForIdle(model)
        expectNoDifference(model.pendingAutoReviewApprovals.isEmpty, true)
        if isSaveFailure(mode) {
            expectNoDifference(saveFault.didTrigger, true)
            if route == "direct" || route == "peer" {
                let index = try AttachmentReferenceRepository(databaseURL: root.appending(path: "attachment-index.sqlite"))
                for image in prepared {
                    let references = try await index.referenceCount(blobID: image.file.digest)
                    expectNoDifference(references, succeeds ? 1 : 0)
                }
            }
        }
        let imageStore = AgentImageStore(rootURL: root.appending(path: "agent-message-images"))
        let inventory = try await imageStore.storageInventory()
        var expectedImageSizes: [String: Int64] = [:]
        if succeeds { expectedImageSizes = Dictionary(uniqueKeysWithValues: prepared.map { ($0.file.digest, Int64($0.file.bytes.count)) }) }
        else if mode == "preview-late" || (mode == "blob-late" && route != "direct") {
            expectedImageSizes[prepared[0].file.digest] = Int64(prepared[0].file.bytes.count)
        } else if mode.hasPrefix("message-") {
            expectedImageSizes = Dictionary(uniqueKeysWithValues: prepared.map { ($0.file.digest, Int64($0.file.bytes.count)) })
        }
        expectNoDifference(inventory, AttachmentStoreInventory(active: expectedImageSizes, quarantined: [:], temporaryFiles: []))
        if mode != "quota-unavailable" {
            let beforeReconcile = try StorageQuotaLedger.live(dataRoot: root)
            for image in prepared {
                let record = await beforeReconcile.record(scope: "agent-image-blob", key: image.file.digest)
                expectNoDifference(record?.byteCount, expectedImageSizes[image.file.digest])
            }
            await model.reconcileQuota()
            let reopenedLedger = try StorageQuotaLedger.live(dataRoot: root)
            for image in prepared {
                let record = await reopenedLedger.record(scope: "agent-image-blob", key: image.file.digest)
                let expected = expectedImageSizes[image.file.digest].map {
                    StorageQuotaRecord(scope: "agent-image-blob", key: image.file.digest, byteCount: $0, generation: 1)
                }
                expectNoDifference(record, expected)
            }
            let usage = await reopenedLedger.usage()
            expectNoDifference(usage.reservationCount, 0)
        }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let snapshots: [SavedLocalGallery]
        if route == "group" || route == "background" {
            let groups = try GroupService(agents: agents, storeURL: root.appending(path: "groups.json"))
            snapshots = await groups.messages(groupID: destinationID).filter { $0.imageGalleryLayout != nil }.map(SavedLocalGallery.init)
            if route == "background" {
                #expect(await groups.messages(groupID: originID).allSatisfy { $0.imageGalleryLayout == nil })
            }
        } else if route == "mailbox" || route == "peer" {
            let messenger = try AgentMessenger(service: agents, storeURL: root.appending(path: "agent-messages.json"))
            snapshots = await messenger.allMessages().flatMap { $0.delivery?.publications ?? [] }
                .filter { $0.imageGalleryLayout != nil }.map(SavedLocalGallery.init)
        } else {
            snapshots = try await store.conversation(id: originID)?.messages.filter { $0.imageGalleryLayout != nil }.map(SavedLocalGallery.init) ?? []
        }
        expectNoDifference(snapshots.count, succeeds ? 1 : 0)
        if let saved = snapshots.first {
            let expectedImages = zip(prepared, saved.images).map { image, actual in
                AttachmentMetadata(id: image.file.digest, filename: image.file.filename, mimeType: image.mimeType,
                    byteCount: Int64(image.file.bytes.count), kind: .image, createdAt: actual.createdAt, altText: image.altText)
            }
            expectNoDifference(saved.images, expectedImages)
            expectNoDifference(saved.text, "Reviewed designs")
            expectNoDifference(saved.remote, mixed ? remote : nil)
            expectNoDifference(saved.layout, layout)
            let imageStore = AgentImageStore(rootURL: root.appending(path: "agent-message-images"))
            let loaded = try await imageStore.load(saved.images)
            expectNoDifference(loaded.map(\.data), bytes)
            if route == "direct" || route == "peer" {
                if route == "peer" {
                    let destination = try #require(model.conversations.first(where: { $0.agentBinding?.agentID == recipient?.id }))
                    destinationID = destination.id
                } else { destinationID = originID }
                let destination = try #require(try await store.conversation(id: destinationID))
                let projected = try #require(destination.messages.first(where: { $0.id == saved.id }))
                for (projectedImage, image) in zip(projected.attachments, saved.images) {
                    #expect(abs(projectedImage.createdAt.timeIntervalSince(image.createdAt)) < 0.000001)
                }
                var comparable = projected
                comparable.attachments = zip(projected.attachments, saved.images).map { actual, canonical in
                    AttachmentMetadata(id: actual.id, filename: actual.filename, mimeType: actual.mimeType,
                        byteCount: actual.byteCount, kind: actual.kind, createdAt: canonical.createdAt, altText: actual.altText)
                }
                expectNoDifference(SavedLocalGallery(comparable), saved)
                let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
                for (image, expected) in zip(saved.images, bytes) {
                    let data = try await lifecycle.data(for: image,
                        owner: .init(conversationID: destinationID, messageID: saved.id))
                    expectNoDifference(data, expected)
                }
                // A second inference must load the captured bytes, even after
                // the original workspace file was replaced following review.
                if route == "direct" {
                    model.selection = destinationID
                    await model.refreshModels()
                    model.draft = "Inspect previous gallery"
                    model.send()
                    try await waitForIdle(model)
                    #expect(model.conversations.first(where: { $0.id == destinationID })?.messages.contains(where: { $0.text == "Gallery bytes verified" }) == true)
                } else {
                    #expect(await model.recoverDirectPeerMessages(conversationID: originID))
                    #expect(await model.recoverDirectPeerMessages(conversationID: originID))
                    expectNoDifference(model.conversations.flatMap(\.messages).filter { $0.id == saved.id }.count, 1)
                }
            }
        }
    }

    private func isSaveFailure(_ mode: String) -> Bool {
        mode.hasPrefix("blob-") || mode.hasPrefix("preview-") || mode.hasPrefix("message-")
    }

    private func approval(_ model: AppModel, excluding priorID: String? = nil) async throws -> PendingApproval {
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.pendingAutoReviewApprovals.contains(where: { $0.id != priorID }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingAutoReviewApprovals.first(where: { $0.id != priorID }), "\(model.errorMessage ?? "Missing gallery approval")")
    }

    private func waitForIdle(_ model: AppModel) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !model.running.isEmpty || !model.runningGroups.isEmpty || !model.runningAgentMessageScopes.isEmpty,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        expectNoDifference(model.running.isEmpty, true)
        expectNoDifference(model.runningGroups.isEmpty, true)
        expectNoDifference(model.runningAgentMessageScopes.isEmpty, true)
    }

    private func png(red: CGFloat, blue: CGFloat) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0.2, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
        let data = NSMutableData()
        let output = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(output))
        return data as Data
    }
}
