import Foundation
import AppKit
import SwiftUI
import Vision
import CSQLite
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
import FiliconAutoReview
import FiliconAutomations
import FiliconChannels
import FiliconDomain
import FiliconLocalTools
import FiliconProviderKit
@testable import Filicon

private actor DirectChannelProbe {
    var sent: [ChannelOutbound] = []
    var results: [NormalizedToolResult] = []
    var channelCapabilities: [Bool] = []
    var downloads: [RemoteAttachmentReference] = []
    var payload = Data("Reviewed HTTPS direct report".utf8)
    func record(_ outbound: ChannelOutbound) { sent.append(outbound) }
    func recordResult(_ result: NormalizedToolResult) { results.append(result) }
    func recordCapability(_ available: Bool) { channelCapabilities.append(available) }
    func replacePayload(_ bytes: Data) { payload = bytes }
    func download(_ reference: RemoteAttachmentReference, redirect: Bool) throws -> RemoteAttachmentDownload {
        downloads.append(reference)
        if redirect, reference.url.contains("source.example") {
            throw RemoteAttachmentDownloadError.redirect("https://redirect.example/final.txt?token=exact")
        }
        return .init(reference: reference, data: payload, declaredMIMEType: "text/html")
    }
}

private struct DirectChannelDownloader: RemoteAttachmentDownloading {
    let probe: DirectChannelProbe
    var redirect = false
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        try await probe.download(reference, redirect: redirect)
    }
}

/// Entirely offline: no credential resolver or platform HTTP transport exists.
private struct DirectChannelConnector: ChannelConnector {
    var supportsAttachments = true
    var descriptor: ChannelConnectorDescriptor {
        .init(id: "slack", displayName: "Offline direct fixture", supportsAttachments: supportsAttachments)
    }
    let probe: DirectChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.record(message)
    }
}

private struct DirectChannelProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "direct-channel-fixture", displayName: "Offline direct publication", requiresAPIKey: false)
    let arguments: Data
    let probe: DirectChannelProbe
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if request.toolExchanges.isEmpty {
                        let tool = try #require(request.tools.first { $0.name == "SendMessage" })
                        let schema = try #require(JSONSerialization.jsonObject(with: tool.inputSchema) as? [String: Any])
                        await probe.recordCapability((schema["properties"] as? [String: Any])?["channel"] != nil)
                        let call = try NormalizedToolCall(id: "direct-external-publication", name: "SendMessage", argumentsJSON: arguments)
                        continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                        continuation.yield(.toolCallCompleted(call))
                        continuation.yield(.completed(.toolUse))
                    } else {
                        let results = request.toolExchanges.last?.results ?? []
                        for result in results { await probe.recordResult(result) }
                        continuation.yield(.completed(.stop))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Foreground bound direct channel publication", .timeLimit(.minutes(1)))
@MainActor struct DirectChannelPublicationAppTests {
    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func savedReviewTranslatesOnlyHostWrappersAndTypedActions(language: String) {
        let id = UUID(uuidString: "35000000-0000-0000-0000-000000000004")!
        let date = Date(timeIntervalSince1970: 0)
        let target = "https://example.invalid/Approval%20required?signature=a%2Bb&literal={0}"
        let card = TranscriptCard(id: id, lifecycle: .waiting, createdAt: date, updatedAt: date,
            payload: .autoReview(.init(reviewID: "fixed-review", title: "Approval required", summary: "Approve",
                findings: ["Approval required", "Target: " + target, "Approval required"])), actions: [
                    .init(id: "approve", label: "Approve", intent: .approveReview(reviewID: "fixed-review")),
                    .init(id: "reject", label: "Reject", role: "destructive", intent: .rejectReview(reviewID: "fixed-review")),
                    .init(id: "arbitrary", label: "Approve", intent: .connectorAction(connectorID: "fixture", actionID: "fixture"))
                ])
        // A saved raw card can switch display language without rewriting its
        // outgoing payload, URL placeholders, IDs, or unrelated button labels.
        for selected in [language, language == "en" ? "zh-Hant" : "en"] {
            FiliconLocalization.$languageOverride.withValue(selected) {
                let expected = TranscriptCardPresentation(kind: .autoReview, title: l10n("Approval required"),
                    subtitle: l10n("Auto-review · \(l10n("Waiting"))"), symbolName: "checkmark.seal", detail: "Approve",
                    fields: [(l10n("Finding \(1)"), l10n("Approval required")),
                             (l10n("Finding \(2)"), l10n("Target") + ": " + target),
                             (l10n("Finding \(3)"), "Approval required")], longTextTitle: nil, longText: nil)
                expectNoDifference(TranscriptCardPresenter.presentation(for: card), expected)
                expectNoDifference(card.actions.map(\.rendererLabel), [l10n("Approve"), l10n("Reject"), "Approve"])
                var custom = card
                custom.payload = .autoReview(.init(reviewID: "fixed-review", title: "Approve", summary: "Reject"))
                expectNoDifference(TranscriptCardPresenter.presentation(for: custom).title, "Approve")
            }
        }
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "binding-ABA", "route-ABA", "archive", "delete", "connection", "connector", "navigation"], [false, true])
    func boundConversationReviewsWholeOutgoingTextBeforeQueueing(mode: String, automaticReviewEnabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-direct-channel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = DirectChannelProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [DirectChannelConnector(probe: probe)])
        await model.bootstrap()
        let content = "BEGIN exact direct payload\n" + String(repeating: "Review every word. ", count: 100) + "\nEND exact direct payload"
        await model.registry.register(DirectChannelProvider(arguments: try JSONEncoder().encode([
            "type": "text", "content": content, "channel": "slack:C_DIRECT"
        ]), probe: probe))
        let sender = try #require(await model.createAgent(name: "Bound sender", summary: "", instructions: "",
            providerID: "direct-channel-fixture", modelID: "fixture"))
        let id = try #require(model.selection)
        let index = try #require(model.conversations.firstIndex { $0.id == id })
        model.conversations[index].providerID = "direct-channel-fixture"
        model.conversations[index].modelID = "fixture"
        model.conversations[index].agentBinding = .init(accountID: "local", agentID: sender.id)
        await model.refreshModels()
        let connection = ChannelConnection(connectorID: "slack", displayName: "Own fixture connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: sender.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        await model.setAutoReviewEnabled(automaticReviewEnabled)
        model.draft = "Review and queue this external result"
        model.send()
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty || !model.running.contains(id) }
        let pending = try #require(model.pendingAutoReviewApprovals.first, "A bound direct turn must expose its independent channel approval")
        let details = try #require(pending.action.context.metadata["agentMessage"])
        #expect(details.contains(content) && details.contains("slack:C_DIRECT") && details.contains(connection.displayName))
        #expect(!details.contains(connection.secretReference))
        let card = try #require(model.conversations.first { $0.id == id }?.messages.flatMap(\.transcriptCards).first {
            if case .autoReview(let value) = $0.payload { return value.reviewID == pending.id }
            return false
        })
        if case .autoReview(let value) = card.payload { #expect(value.findings.contains(details)) }
        let before = await channels.deliveries(), sent = await probe.sent
        expectNoDifference(before, []); expectNoDifference(sent, [])
        if mode == "stop" { model.cancel() }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "archive" { await model.archiveAgent(id: sender.id) }
        if mode == "delete" { model.deleteConversation(id: id) }
        if mode == "binding-ABA" {
            let original = model.conversations[index].agentBinding
            model.conversations[index].agentBinding = nil
            model.conversations[index].agentBinding = original
        }
        if mode == "route-ABA" {
            model.conversations[index].modelID = "changed-route"
            model.conversations[index].modelID = "fixture"
        }
        if mode == "connection" { try await channels.setConnectionEnabled(id: connection.id, enabled: false) }
        if mode == "connector" { await channels.register(DirectChannelConnector(probe: probe)) }
        if mode == "navigation" {
            model.selection = nil
            model.handleTranscriptCardIntent(.approveReview(reviewID: pending.id))
            // An action in a different selected chat cannot approve this card.
            try await Task.sleep(for: .milliseconds(20))
            let beforeReturn = await channels.deliveries()
            expectNoDifference(beforeReturn, [])
            model.selection = id
        }
        model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: pending.id) : .approveReview(reviewID: pending.id))
        try await eventually { !model.running.contains(id) }
        let queued = await channels.deliveries()
        let succeeds = mode == "approve" || mode == "navigation"
        expectNoDifference(queued.map(\.outbound), succeeds ? [.init(text: content)] : [])
        expectNoDifference(queued.compactMap { $0.authorization?.agentID }, succeeds ? [sender.id] : [])
        if succeeds {
            let delivery = try #require(queued.first)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(delivery)) as? [String: Any])
            let origin = try #require(encoded["origin"] as? [String: Any], "The durable queue must retain its host-bound conversation source")
            expectNoDifference(origin["conversationID"] as? String, id.uuidString)
            expectNoDifference(origin["senderID"] as? String, id.uuidString)
            expectNoDifference(origin["senderName"] as? String, sender.name)
            expectNoDifference(origin["route"] as? String, "directConversation")
            expectNoDifference(origin["callID"] as? String, "direct-external-publication")
            let publication = try #require(model.conversations.first { $0.id == id }?.messages.first { $0.id == delivery.id },
                "The approved external message must have a canonical entry in its original direct chat")
            expectNoDifference(publication.text, content)
        }
        let capabilities = await probe.channelCapabilities
        expectNoDifference(capabilities, [true])
        let results = await probe.results
        expectNoDifference(results.contains { !$0.isError && $0.wireText.contains("durably queued, not confirmed delivered") }, succeeds)
        expectNoDifference(results.contains { $0.wireText.contains("Saved message receipt:") }, succeeds)
        if !succeeds { let finalSent = await probe.sent; expectNoDifference(finalSent, []) }
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        if mode != "delete" {
            let saved = try #require(try await ConversationStore(fileURL: root.appending(path: "conversations.json")).conversation(id: id))
            expectNoDifference(saved.messages.filter { $0.externalChannelPublication != nil }.map(\.text), succeeds ? [content] : [])
            #expect(saved.messages.filter { $0.role == .assistant && $0.externalChannelPublication == nil }.allSatisfy { $0.text.isEmpty })
        }
    }

    @Test(arguments: ["unbound", "no-connection", "peer", "foreign-account", "ambiguous", "attachment-unsupported"])
    func unavailableDestinationNeverReadsSourcesQueuesOrFallsBack(mode: String) async throws {
        let root = temporaryRoot("unavailable")
        defer { try? FileManager.default.removeItem(at: root) }
        let arguments = mode == "attachment-unsupported"
            ? ["type": "attachment", "url": "file:///never-read/report.txt", "channel": "slack:C_DIRECT"]
            : ["type": "text", "content": "PRIVATE EXTERNAL ONLY", "channel": "slack:C_DIRECT"]
        let f = try await fixture(root: root, arguments: JSONEncoder().encode(arguments), bound: mode != "unbound",
            supportsAttachments: mode != "attachment-unsupported")
        defer { f.model.cancel() }
        if mode == "no-connection" { _ = try await f.channels.removeConnection(id: f.connection.id) }
        if mode == "peer" || mode == "foreign-account" {
            _ = try await f.channels.removeConnection(id: f.connection.id)
            try await f.channels.saveConnection(.init(connectorID: "slack", displayName: "Other owner",
                secretReference: "keychain://channels/TEST-other-only", agentID: mode == "peer"
                    ? UUID(uuidString: "35000000-0000-0000-0000-000000000002")! : f.sender.id,
                ownerAccountID: mode == "foreign-account" ? "other" : "local"))
        }
        if mode == "ambiguous" {
            try await f.channels.saveConnection(.init(connectorID: "slack", displayName: "Ambiguous second",
                secretReference: "keychain://channels/TEST-second-only", agentID: f.sender.id, ownerAccountID: "local"))
        }
        start(f)
        try await eventually { !f.model.running.contains(f.id) }
        let queued = await f.channels.deliveries(), sent = await f.probe.sent
        let downloads = await f.probe.downloads, capabilities = await f.probe.channelCapabilities
        expectNoDifference(queued, []); expectNoDifference(sent, [])
        expectNoDifference(downloads, []); expectNoDifference(capabilities, [mode != "unbound"])
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty && f.model.pendingWorkspaceFolders.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "channel-attachments").path))
        #expect(f.model.conversations.first { $0.id == f.id }?.messages.filter { $0.role == .assistant }.allSatisfy { $0.text.isEmpty } == true)
        #expect(await f.probe.results.allSatisfy { $0.isError && !$0.wireText.contains("Saved message receipt:") })
    }

    @Test(arguments: ["approve", "deny-read", "deny-send", "stop-read", "stop-send", "account-send", "binding-ABA-send", "revoked-read", "connection"], [false, true])
    func localCapturedBytesHaveSeparateReadAndExternalSendConsent(mode: String, automaticReviewEnabled: Bool) async throws {
        let root = temporaryRoot("local")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let source = workspace.appending(path: "report.txt"), bytes = Data("IMMUTABLE APPROVED DIRECT REPORT".utf8)
        try bytes.write(to: source)
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        let grant = try await grants.authorize(workspace)
        let generation = UUID(uuidString: "35000000-0000-0000-0000-000000000003")!, key = Data(repeating: 31, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        let f = try await fixture(root: root, arguments: JSONEncoder().encode([
            "type": "attachment", "url": source.absoluteString, "alt": "Reviewed direct report", "channel": "slack:C_DIRECT"
        ]), runtime: runtime)
        defer { f.model.cancel() }
        await f.model.setAutoReviewEnabled(automaticReviewEnabled)
        start(f)
        try await eventually { !f.model.pendingToolApprovals.isEmpty || !f.model.running.contains(f.id) }
        let read = try #require(f.model.pendingToolApprovals.first)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty)
        let beforeRead = await f.channels.deliveries()
        expectNoDifference(beforeRead, [])
        if mode == "stop-read" { f.model.cancel() }
        if mode == "revoked-read" { try await grants.remove(id: grant.id) }
        f.model.resolveLocalToolApproval(id: read.id, allowed: mode != "deny-read")
        try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty || !f.model.running.contains(f.id) }
        if ["deny-read", "stop-read", "revoked-read"].contains(mode) {
            #expect(f.model.pendingAutoReviewApprovals.isEmpty)
        } else {
            let pending = try #require(f.model.pendingAutoReviewApprovals.first)
            expectNoDifference(pending.action.context.metadata["agentChannelPublication"], "true")
            let captured = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
            let details = try #require(pending.action.context.metadata["agentMessage"])
            for marker in [source.absoluteString, captured.digest, "text/plain", "Reviewed direct report", "slack:C_DIRECT"] { #expect(details.contains(marker)) }
            try assertWholeCard(f, pending: pending, details: details)
            let beforeSend = await f.channels.deliveries()
            expectNoDifference(beforeSend, [])
            if mode == "stop-send" { f.model.cancel() }
            if mode == "account-send" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other") }
            if mode == "binding-ABA-send" { rebindAndRestore(f) }
            if mode == "connection" { try await f.channels.setConnectionEnabled(id: f.connection.id, enabled: false) }
            try Data("UNREVIEWED FILE REPLACEMENT".utf8).write(to: source)
            f.model.handleTranscriptCardIntent(mode == "deny-send" ? .rejectReview(reviewID: pending.id) : .approveReview(reviewID: pending.id))
        }
        try await eventually { !f.model.running.contains(f.id) }
        let captured = try PreparedAgentPublicationFile(bytes: bytes, filename: "report.txt")
        let metadata = ChannelAttachment(blobID: captured.digest, filename: captured.filename, mimeType: "text/plain", byteCount: Int64(bytes.count))
        let queued = await f.channels.deliveries()
        expectNoDifference(queued.map(\.outbound), mode == "approve" ? [.init(text: "Reviewed direct report", attachments: [metadata])] : [])
        if mode == "approve" {
            let stored = try await AttachmentStore(rootURL: root.appending(path: "channel-attachments")).data(for:
                .init(id: captured.digest, filename: captured.filename, mimeType: "text/plain", byteCount: metadata.byteCount, kind: .document))
            expectNoDifference(stored, bytes)
            let ledger = try StorageQuotaLedger.live(dataRoot: root)
            let record = await ledger.record(scope: "channel-attachment-blob", key: captured.digest)
            expectNoDifference(record?.byteCount, Int64(bytes.count))
        } else {
            let sent = await f.probe.sent
            expectNoDifference(sent, [])
            if mode == "connection" {
                // A connection can retire after the immutable blob was installed
                // but before the queue's final revision check. Retained bytes
                // are charged, not described as a sent message or rolled back.
                await f.model.reconcileQuota()
                let inventory = try await AttachmentStore(rootURL: root.appending(path: "channel-attachments")).inventory()
                let ledger = try StorageQuotaLedger.live(dataRoot: root)
                let record = await ledger.record(scope: "channel-attachment-blob", key: captured.digest)
                expectNoDifference(record?.byteCount, inventory.active[captured.digest])
            } else { #expect(!FileManager.default.fileExists(atPath: root.appending(path: "channel-attachments").path)) }
        }
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty && f.model.pendingWorkspaceFolders.isEmpty)
    }

    @Test(arguments: ["approve", "deny-source", "deny-send", "stop-source", "stop-send", "account-source", "account-send", "binding-ABA-source", "binding-ABA-send", "redirect", "redirect-denied", "first-image", "corrupt-image"], [false, true])
    func HTTPSAndRedirectConsentAreIndependentOfExternalSend(mode: String, automaticReviewEnabled: Bool) async throws {
        let root = temporaryRoot("https")
        defer { try? FileManager.default.removeItem(at: root) }
        let image = mode == "first-image" || mode == "corrupt-image"
        let bytes = mode == "first-image" ? try LocalGalleryFormatFixture.bytes(type: "png") : Data("Reviewed HTTPS direct report".utf8)
        let sourceURL = "https://source.example/\(image ? "report.png" : "report.txt")?signature=a%2Bb"
        let caption = "Reviewed HTTPS caption"
        let arguments: [String: Any] = image
            ? ["type": "text", "content": caption, "channel": "slack:C_DIRECT", "images": [
                ["url": sourceURL, "alt": "First image"],
                ["url": "file:///never-read/EXCLUDED_LOCAL.png", "alt": "EXCLUDED LOCAL"],
                ["url": "https://never.example/EXCLUDED_REMOTE.png", "alt": "EXCLUDED REMOTE"]]]
            : ["type": "attachment", "url": sourceURL, "alt": caption, "channel": "slack:C_DIRECT"]
        let f = try await fixture(root: root, arguments: JSONSerialization.data(withJSONObject: arguments))
        defer { f.model.cancel() }
        f.model.remoteAttachmentDownloader = DirectChannelDownloader(probe: f.probe, redirect: mode.hasPrefix("redirect"))
        await f.probe.replacePayload(bytes)
        await f.model.setAutoReviewEnabled(automaticReviewEnabled)
        start(f)
        let source = try await pending(f)
        expectNoDifference(source.action.context.metadata["agentChannelSourceDownload"], "true")
        expectNoDifference(source.action.target, .resource(kind: "remote-attachment-source", identifier: sourceURL))
        try assertWholeCard(f, pending: source, details: try #require(source.action.context.metadata["agentMessage"]))
        let beforeSourceDownloads = await f.probe.downloads, beforeSourceQueue = await f.channels.deliveries()
        expectNoDifference(beforeSourceDownloads, []); expectNoDifference(beforeSourceQueue, [])
        if mode == "stop-source" { f.model.cancel() }
        if mode == "account-source" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "binding-ABA-source" { rebindAndRestore(f) }
        f.model.handleTranscriptCardIntent(mode == "deny-source" ? .rejectReview(reviewID: source.id) : .approveReview(reviewID: source.id))
        try await nextBoundary(f, after: source.id)
        if !["deny-source", "stop-source", "account-source", "binding-ABA-source", "corrupt-image"].contains(mode) {
            if mode.hasPrefix("redirect") {
                let redirect = try await pending(f)
                expectNoDifference(redirect.action.context.metadata["agentChannelSourceDownload"], "true")
                let details = try #require(redirect.action.context.metadata["agentMessage"])
                #expect(details.contains(sourceURL) && details.contains("https://redirect.example/final.txt?token=exact"))
                try assertWholeCard(f, pending: redirect, details: details)
                let beforeRedirect = await f.probe.downloads
                expectNoDifference(beforeRedirect, [try RemoteAttachmentReference(url: sourceURL, alt: caption)])
                f.model.handleTranscriptCardIntent(mode == "redirect-denied" ? .rejectReview(reviewID: redirect.id) : .approveReview(reviewID: redirect.id))
                try await nextBoundary(f, after: redirect.id)
            }
            if mode != "redirect-denied" {
                let send = try await pending(f), captured = try PreparedAgentPublicationFile(bytes: bytes, filename: image ? "report.png" : "report.txt")
                expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
                let details = try #require(send.action.context.metadata["agentMessage"])
                for marker in [sourceURL, caption, captured.digest, "slack:C_DIRECT", image ? "image/png" : "text/plain"] { #expect(details.contains(marker)) }
                if mode == "first-image" {
                    for marker in ["EXCLUDED_LOCAL.png", "EXCLUDED_REMOTE.png", "EXCLUDED LOCAL", "EXCLUDED REMOTE",
                        l10n("Only the first image is sent to the channel. The remaining images are not sent.")] { #expect(details.contains(marker)) }
                }
                try assertWholeCard(f, pending: send, details: details)
                let beforeSend = await f.channels.deliveries()
                expectNoDifference(beforeSend, [])
                if mode == "stop-send" { f.model.cancel() }
                if mode == "account-send" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other") }
                if mode == "binding-ABA-send" { rebindAndRestore(f) }
                await f.probe.replacePayload(Data("UNREVIEWED DOWNLOAD REPLACEMENT".utf8))
                f.model.handleTranscriptCardIntent(mode == "deny-send" ? .rejectReview(reviewID: send.id) : .approveReview(reviewID: send.id))
            }
        }
        try await eventually { !f.model.running.contains(f.id) }
        let succeeds = ["approve", "redirect", "first-image"].contains(mode)
        let captured = try PreparedAgentPublicationFile(bytes: bytes, filename: image ? "report.png" : "report.txt")
        let metadata = ChannelAttachment(blobID: captured.digest, filename: captured.filename,
            mimeType: image ? "image/png" : "text/plain", byteCount: Int64(bytes.count))
        let queued = await f.channels.deliveries()
        expectNoDifference(queued.map(\.outbound), succeeds ? [.init(text: caption, attachments: [metadata])] : [])
        let first = try RemoteAttachmentReference(url: sourceURL, alt: image ? "First image" : caption)
        let expectedDownloads = ["deny-source", "stop-source", "account-source", "binding-ABA-source"].contains(mode) ? []
            : mode == "redirect" ? [first, try RemoteAttachmentReference(url: "https://redirect.example/final.txt?token=exact", alt: first.alt)] : [first]
        let downloads = await f.probe.downloads
        expectNoDifference(downloads, expectedDownloads)
        if succeeds {
            let stored = try await AttachmentStore(rootURL: root.appending(path: "channel-attachments")).data(for:
                .init(id: captured.digest, filename: captured.filename, mimeType: metadata.mimeType, byteCount: metadata.byteCount, kind: image ? .image : .document))
            expectNoDifference(stored, bytes)
        } else {
            let sent = await f.probe.sent
            expectNoDifference(sent, [])
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "channel-attachments").path))
        }
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty && f.model.pendingWorkspaceFolders.isEmpty)
    }

    private struct Fixture {
        let model: AppModel
        let id: UUID
        let sender: AgentProfile
        let connection: ChannelConnection
        let channels: ChannelService
        let probe: DirectChannelProbe
    }

    @Test func reviewedBackgroundDirectSessionDoesNotInheritForegroundPublicationConsent() async throws {
        let root = temporaryRoot("background")
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try await fixture(root: root, arguments: JSONEncoder().encode([
            "type": "text", "content": "NO IMPLICIT BACKGROUND CHANNEL GRANT", "channel": "slack:C_DIRECT"
        ]))
        defer { f.model.cancel() }
        await f.model.setAutomationRuntimeActive(false)
        let conversation = try #require(f.model.conversations.first { $0.id == f.id })
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).upsert(conversation,
            replacingLoadedMessageIDs: Set(conversation.messages.map(\.id)), historyComplete: true)
        await f.model.createAutomation(agentID: f.sender.id, name: "Isolated direct routine", prompt: "Inspect this fixture",
            trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"))
        let routine = try #require(f.model.automations.first), edit = try #require(f.model.beginRoutineDirectSessionEdit(routine))
        #expect(await f.model.saveRoutineDirectSession(edit, conversationID: f.id, memoryAccess: .none))
        let work = Task { await f.model.runAutomationNow(id: routine.id) }
        defer { work.cancel() }
        // The task has not necessarily entered the runner when it is created.
        // Observe the fake provider start before treating an idle chat as done.
        let deadline = ContinuousClock.now + .seconds(10)
        while await f.probe.channelCapabilities.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await f.probe.channelCapabilities
        expectNoDifference(started, [true])
        let review = try await pending(f)
        let before = await f.channels.deliveries(), sentBefore = await f.probe.sent
        expectNoDifference(before, []); expectNoDifference(sentBefore, [])
        f.model.handleTranscriptCardIntent(.rejectReview(reviewID: review.id))
        await work.value
        let capabilities = await f.probe.channelCapabilities, queued = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(capabilities, [true]); expectNoDifference(queued, []); expectNoDifference(sent, [])
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty)
        #expect(!f.model.running.contains(f.id))
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [340.0, 620.0])
    func realDirectApprovalCardsRetainWholeIntent(language: String, width: Double) async throws {
        let root = temporaryRoot("cards")
        defer { try? FileManager.default.removeItem(at: root) }
        try await FiliconLocalization.$languageOverride.withValue(language) {
            let sourceURL = "https://source.example/MARKER_SOURCE_report.png?signature=a%2Bb"
            let caption = "BEGIN CAPTION\n" + String(repeating: "Complete reviewed caption. ", count: 70) + "\nEND CAPTION"
            let arguments: [String: Any] = ["type": "text", "content": caption, "channel": "slack:C_DIRECT", "images": [
                ["url": sourceURL, "alt": "First image"],
                ["url": "https://unused.example/EXCLUDED_IMAGE.png", "alt": "EXCLUDED ALT"]]]
            let f = try await fixture(root: root, arguments: JSONSerialization.data(withJSONObject: arguments))
            defer { f.model.cancel() }
            let bytes = try LocalGalleryFormatFixture.bytes(type: "png")
            await f.probe.replacePayload(bytes)
            start(f)
            let source = try await pending(f)
            for dark in [false, true] {
                try await renderCard(f, pending: source, language: language, width: width, dark: dark,
                    stage: "source", markers: ["MARKER_SOURCE_report", "signature="],
                    notices: ["Download this attachment source?", "Downloading does not authorize sending the file to a channel."])
            }
            f.model.handleTranscriptCardIntent(.approveReview(reviewID: source.id))
            try await nextBoundary(f, after: source.id)
            let send = try await pending(f)
            expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
            let details = try #require(send.action.context.metadata["agentMessage"])
            #expect(details.contains(caption))
            for dark in [false, true] {
                try await renderCard(f, pending: send, language: language, width: width, dark: dark,
                    stage: "send", markers: ["BEGIN CAPTION", "END CAPTION", "C_DIRECT", "MARKER_SOURCE_report", "SHA-256", "EXCLUDED_IMAGE", "EXCLUDED ALT"],
                    notices: ["Queue this message to an external channel?", "Only the first image is sent to the channel. The remaining images are not sent.", "Queued is not delivered. Stop does not recall a queued message."])
            }
            f.model.handleTranscriptCardIntent(.rejectReview(reviewID: send.id))
            try await eventually { !f.model.running.contains(f.id) }
            let queued = await f.channels.deliveries(), sent = await f.probe.sent
            expectNoDifference(queued, []); expectNoDifference(sent, [])
        }
    }

    @Test(arguments: ["missing-row", "save-failure", "foreign-owner", "deleted"])
    func outboxRecoveryOnlyRepairsTheOriginalCanonicalChatWithoutSending(mode: String) async throws {
        let root = temporaryRoot("recovery"); defer { try? FileManager.default.removeItem(at: root) }
        let f = try await fixture(root: root, arguments: Data("{}".utf8))
        let chat = try #require(f.model.conversations.first { $0.id == f.id })
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.upsert(chat, replacingLoadedMessageIDs: Set(chat.messages.map(\.id)), historyComplete: true)
        let proposal = try await f.channels.proposePublication(agentID: f.sender.id, accountID: "local",
            outbound: .init(text: "Preserve exact original outgoing caption"), to: .init(platform: "slack", channelID: "C_DIRECT"))
        let delivery = try await f.channels.enqueueApprovedPublication(proposal, lifetime: .init(), idempotencyKey: UUID(), at: Date(),
            origin: .init(route: .directConversation, conversationID: f.id, senderID: f.id, senderName: f.sender.name,
                runID: UUID(), callID: "recovery-fixture", replyToMessageID: nil,
                intent: .init(kind: .text, text: proposal.outbound.text, sources: [])))
        if mode == "foreign-owner" {
            var changed = chat; changed.agentBinding = .init(accountID: "other", agentID: f.sender.id)
            try await store.upsert(changed, replacingLoadedMessageIDs: [], historyComplete: true)
        }
        if mode == "deleted" { try await store.delete(id: f.id) }
        func sql(_ statement: String) throws {
            var handle: OpaquePointer?
            try #require(sqlite3_open(root.appending(path: "conversations.sqlite3").path, &handle) == SQLITE_OK)
            defer { sqlite3_close(handle) }
            try #require(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
        }
        if mode == "save-failure" {
            try sql("CREATE TRIGGER reject_external_projection BEFORE INSERT ON messages WHEN NEW.transcript_cards_json LIKE '%externalChannelPublication%' BEGIN SELECT RAISE(ABORT,'isolated projection failure'); END")
            await f.model.reconcileChannelPublications()
            let failed = try await store.conversation(id: f.id)
            #expect(failed?.messages.contains { $0.id == delivery.id } == false)
            try sql("DROP TRIGGER reject_external_projection")
        }
        let sendsBefore = await f.probe.sent
        await f.model.reconcileChannelPublications()
        let repaired = try await store.conversation(id: f.id)
        let rows = repaired?.messages.filter { $0.id == delivery.id } ?? []
        let shouldRepair = ["missing-row", "save-failure"].contains(mode)
        expectNoDifference(rows.count, shouldRepair ? 1 : 0)
        if shouldRepair {
            let row = try #require(rows.first), value = try #require(ChannelTranscriptProjection.publication(for: delivery))
            #expect(row.matchesExternalPublication(value))
            expectNoDifference(row.externalChannelPublication?.delivery.status, .queued)
        }
        // A second repair reuses IDs and status; no
        // publication/source/model callback or implicit queue flush is involved.
        await f.model.reconcileChannelPublications()
        let replay = try await store.conversation(id: f.id), sendsAfter = await f.probe.sent
        expectNoDifference(replay, repaired)
        expectNoDifference(sendsAfter, sendsBefore)
        let queue = await f.channels.deliveries()
        expectNoDifference(queue.map(\.id), [delivery.id])
        let downloads = await f.probe.downloads
        expectNoDifference(downloads, [])
    }

    private func renderCard(_ f: Fixture, pending: PendingApproval, language: String, width: Double, dark: Bool,
        stage: String, markers: [String], notices: [String]) async throws {
        try await withUIRenderTurn(language: language) {
            let details = try #require(pending.action.context.metadata["agentMessage"])
            for notice in notices {
                #expect(details.contains(FiliconLocalization.string(notice)))
                if language != "en" { #expect(FiliconLocalization.string(notice) != notice) }
            }
            let card = try approvalCard(f, pending: pending)
            try assertWholeCard(f, pending: pending, details: details)
            let presentation = TranscriptCardPresenter.presentation(for: card)
            expectNoDifference(presentation.title, l10n("Approval required"))
            expectNoDifference(presentation.fields.first?.value, l10n("Approval required"))
            expectNoDifference(presentation.fields.last?.value, details)
            expectNoDifference(card.rendererActions.map(\.rendererLabel), [l10n("Approve"), l10n("Reject")])
            // The URL query must be byte-for-byte intact in the rendered value.
            // OCR is used for clipping markers, not to decide whether the
            // glyphs '2' and 'Z' represent the exact percent escape.
            #expect(presentation.fields.last?.value.contains("signature=a%2Bb") == true)
            let host = NSHostingView(rootView: TranscriptCardRow(card: card, onAction: { f.model.handleTranscriptCardIntent($0) })
                .foregroundStyle(FiliconTheme.textPrimary).padding(16).frame(width: width)
                .background(FiliconTheme.canvas).environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            #expect(abs(size.width - CGFloat(width)) < 0.5)
            #expect(size.height > 180 && size.height < 8_000)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
            let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            let compact = visible.filter { !$0.isWhitespace }
            for marker in markers { #expect(compact.contains(marker.filter { !$0.isWhitespace })) }
            if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appending(path: "direct-channel-\(stage)-\(language)-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func fixture(root: URL, arguments: Data, bound: Bool = true, supportsAttachments: Bool = true,
        runtime: LocalToolRuntime? = nil) async throws -> Fixture {
        let probe = DirectChannelProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            channelService: channels, channelConnectors: [DirectChannelConnector(supportsAttachments: supportsAttachments, probe: probe)])
        model.remoteAttachmentDownloader = DirectChannelDownloader(probe: probe)
        await model.bootstrap()
        await model.registry.register(DirectChannelProvider(arguments: arguments, probe: probe))
        let sender = try #require(await model.createAgent(name: "Bound sender", summary: "", instructions: "",
            providerID: "direct-channel-fixture", modelID: "fixture"))
        let id = try #require(model.selection), index = try #require(model.conversations.firstIndex { $0.id == id })
        model.conversations[index].providerID = "direct-channel-fixture"
        model.conversations[index].modelID = "fixture"
        model.conversations[index].agentBinding = bound ? .init(accountID: "local", agentID: sender.id) : nil
        await model.refreshModels()
        let connection = ChannelConnection(id: UUID(uuidString: "35000000-0000-0000-0000-000000000001")!,
            connectorID: "slack", displayName: "Own direct fixture connection", secretReference: "keychain://channels/TEST-only-never-read",
            agentID: sender.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        return .init(model: model, id: id, sender: sender, connection: connection, channels: channels, probe: probe)
    }

    private func temporaryRoot(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "filicon-direct-channel-\(label)-\(UUID())")
    }

    private func start(_ f: Fixture) { f.model.draft = "Review this external publication"; f.model.send() }

    private func rebindAndRestore(_ f: Fixture) {
        guard let index = f.model.conversations.firstIndex(where: { $0.id == f.id }) else { return }
        let original = f.model.conversations[index].agentBinding
        f.model.conversations[index].agentBinding = nil
        f.model.conversations[index].agentBinding = original
    }

    private func pending(_ f: Fixture) async throws -> PendingApproval {
        try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty || !f.model.running.contains(f.id) }
        return try #require(f.model.pendingAutoReviewApprovals.first)
    }

    private func nextBoundary(_ f: Fixture, after reviewID: String) async throws {
        try await eventually {
            !f.model.pendingAutoReviewApprovals.contains { $0.id == reviewID }
                && (!f.model.pendingAutoReviewApprovals.isEmpty || !f.model.running.contains(f.id))
        }
    }

    private func assertWholeCard(_ f: Fixture, pending: PendingApproval, details: String) throws {
        let card = try approvalCard(f, pending: pending)
        if case .autoReview(let value) = card.payload { #expect(value.findings.contains(details)) }
        #expect(!details.contains(f.connection.secretReference))
    }

    private func approvalCard(_ f: Fixture, pending: PendingApproval) throws -> TranscriptCard {
        try #require(f.model.conversations.first { $0.id == f.id }?.messages.flatMap(\.transcriptCards).first {
            if case .autoReview(let value) = $0.payload { return value.reviewID == pending.id }
            return false
        })
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
