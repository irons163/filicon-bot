import AppKit
import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAppServices
import FiliconProviderKit
@testable import Filicon

private final class DirectImageSaveFault: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    let point: StorageQuotaFaultPoint
    init(_ point: StorageQuotaFaultPoint) { self.point = point }
    func arm() { lock.lock(); defer { lock.unlock() }; armed = true }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        lock.lock(); defer { lock.unlock() }
        if armed && point == self.point { armed = false; throw CocoaError(.fileWriteUnknown) }
    }
}

private struct DirectImageProvider: AIProvider {
    let standalone: Bool
    let unknown: Bool
    let fault: DirectImageSaveFault?
    let descriptor = ProviderDescriptor(id: "direct-image", displayName: "Image test", requiresAPIKey: false)
    func models() async throws -> [AIModel] { [.init(id: "vision", capabilities: .init(inputModalities: [.text, .image]))] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    fault?.arm()
                    let source = try #require(request.messages.last(where: { $0.role == .user }))
                    let image = try #require(request.attachmentsByMessageID[source.id]?.first?.metadata)
                    let entry = ["image_id": unknown ? String(repeating: "0", count: 64) : image.id, "alt": "Selected image"]
                    let arguments: [String: Any] = standalone
                        ? ["type": "attachment", "image_id": entry["image_id"]!, "alt": "Selected image", "reply_to": source.id.uuidString]
                        : ["type": "text", "content": "Here it is", "images": [entry], "reply_to": source.id.uuidString]
                    let call = try NormalizedToolCall(id: "publish-image", name: "SendMessage",
                        argumentsJSON: JSONSerialization.data(withJSONObject: arguments))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    let result = try #require(request.toolExchanges.first?.results.first)
                    if !result.isError { #expect(result.wireText.contains("Saved message receipt:")) }
                    if fault != nil {
                        #expect(result.isError)
                        #expect(!result.wireText.contains("Saved message receipt:"))
                    }
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Direct image publications", .timeLimit(.minutes(1)))
@MainActor struct DirectImagePublicationTests {
    @Test(arguments: ["approve", "deny", "corrupt", "unknown", "stop", "account", "save-temp", "save-reserve", "save-commit"], [false, true])
    func publicationRequiresCurrentImageApprovalAndDurableReachability(mode: String, standalone: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-image-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.representation(using: .png, properties: [:]))
        let storage = AttachmentStore(rootURL: root.appending(path: "attachments"))
        let image = try await storage.ingest(data: bytes, filename: "sample.png", declaredMIMEType: "image/png")
        let point: StorageQuotaFaultPoint? = mode == "save-temp" ? .afterTemporaryWriteBeforeRename : mode == "save-reserve" ? .afterReservationPersist : mode == "save-commit" ? .afterCommitPersist : nil
        let fault = point.map(DirectImageSaveFault.init)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, quotaFaultInjector: { try fault?.inject($0) })
        await model.bootstrap()
        await model.registry.register(DirectImageProvider(standalone: standalone, unknown: mode == "unknown", fault: fault))
        let id = try #require(model.selection)
        let ci = try #require(model.conversations.firstIndex(where: { $0.id == id }))
        model.conversations[ci].providerID = "direct-image"
        model.conversations[ci].modelID = "vision"
        await model.refreshModels()
        model.pendingAttachments = [image]
        model.draft = ""
        model.send()
        for _ in 0..<600 {
            if !model.pendingAutoReviewApprovals.isEmpty || !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        if mode != "unknown" {
            let approval = try #require(model.pendingAutoReviewApprovals.first)
            expectNoDifference(approval.action.context.metadata["tool"], "SendMessage")
            let visibleApproval = try #require(model.conversations[ci].messages.flatMap(\.transcriptCards).compactMap { card -> AutoReviewTranscriptCard? in
                if case .autoReview(let value) = card.payload { return value }; return nil
            }.last)
            #expect(visibleApproval.findings.contains("sample.png — Selected image"))
            if !standalone { #expect(visibleApproval.findings.contains("Here it is")) }
            #expect(model.conversations[ci].messages.allSatisfy { $0.role != .assistant || $0.attachments.isEmpty })
            if mode == "corrupt" {
                try Data(repeating: 0, count: Int(image.byteCount)).write(to: root.appending(path: "attachments/\(image.id.prefix(2))/\(image.id)"))
            }
            if mode == "stop" { model.cancel() }
            if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
            model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: approval.id) : .approveReview(reviewID: approval.id))
        } else { #expect(model.pendingAutoReviewApprovals.isEmpty) }
        for _ in 0..<600 {
            if !model.running.contains(id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.running.contains(id))
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let saved = try #require(try await store.conversation(id: id))
        let publications = saved.messages.filter { $0.role == .assistant && !$0.attachments.isEmpty }
        expectNoDifference(publications.count, mode == "approve" ? 1 : 0)
        if let publication = publications.first {
            let source = try #require(saved.messages.first(where: { $0.role == .user }))
            expectNoDifference(publication.text, standalone ? "" : "Here it is")
            expectNoDifference(publication.replyToMessageID, source.id)
            expectNoDifference(publication.attachments.first?.altText, "Selected image")
            let lifecycle = try AttachmentLifecycle.live(applicationSupportDirectory: root)
            let metadata = try #require(publication.attachments.first)
            let owner = AttachmentReferenceOwner(conversationID: id, messageID: publication.id)
            let loaded = try await lifecycle.data(for: metadata, owner: owner)
            expectNoDifference(loaded, bytes)
            try await lifecycle.removeReference(blobID: image.id, owner: .init(conversationID: id, messageID: source.id))
            let retained = try await lifecycle.data(for: metadata, owner: owner)
            expectNoDifference(retained, bytes)
        }
    }
}
