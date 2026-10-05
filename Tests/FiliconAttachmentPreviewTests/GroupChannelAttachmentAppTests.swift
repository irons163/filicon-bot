import Foundation
import AppKit
import SwiftUI
import Vision
import Testing
import CustomDump
@testable import FiliconAppServices
import FiliconAutoReview
import FiliconChannels
import FiliconDomain
import FiliconLocalTools
import FiliconProviderKit
@testable import Filicon

private actor ChannelAttachmentProbe {
    var sent: [ChannelOutbound] = []
    var downloads: [RemoteAttachmentReference] = []
    var payload = Data("Captured HTTPS report".utf8)
    func record(_ outbound: ChannelOutbound) { sent.append(outbound) }
    func replacePayload(_ bytes: Data) { payload = bytes }
    func download(_ reference: RemoteAttachmentReference, redirect: Bool) throws -> RemoteAttachmentDownload {
        downloads.append(reference)
        if redirect, reference.url.contains("source.example") {
            throw RemoteAttachmentDownloadError.redirect("https://redirect.example/final.txt?token=exact")
        }
        return .init(reference: reference, data: payload, declaredMIMEType: "text/html")
    }
}

private struct AttachmentFixtureDownloader: RemoteAttachmentDownloading {
    let probe: ChannelAttachmentProbe
    var redirect = false
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        try await probe.download(reference, redirect: redirect)
    }
}

private final class ChannelAttachmentQuotaFault: @unchecked Sendable {
    private let lock = NSLock()
    private let ledgerURL: URL
    private let digest: String
    private var mode: String?
    private var triggered = false
    init(root: URL, digest: String) {
        ledgerURL = root.appending(path: "quota/storage-quota-v1.json"); self.digest = digest
    }
    func arm(_ mode: String) { lock.withLock { self.mode = mode } }
    var didTrigger: Bool { lock.withLock { triggered } }
    func inject(_ point: StorageQuotaFaultPoint) throws {
        try lock.withLock {
            guard let mode, point == (mode == "quota-reserve" ? .afterReservationPersist : .afterCommitPersist) else { return }
            let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: ledgerURL)) as? [String: Any])
            let encoded = state[mode == "quota-reserve" ? "reservations" : "records"]
            // UUID-keyed Codable dictionaries use an alternating key/value
            // array, while the String-keyed committed records use an object.
            let values = (encoded as? [Any])?.compactMap { $0 as? [String: Any] }
                ?? (encoded as? [String: [String: Any]]).map { Array($0.values) } ?? []
            guard values.contains(where: { entry in
                let record = mode == "quota-reserve" ? entry["record"] as? [String: Any] : entry
                return record?["scope"] as? String == "channel-attachment-blob" && record?["key"] as? String == digest
            }) else { return }
            self.mode = nil; triggered = true
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private struct AttachmentFixtureConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline attachment fixture", supportsAttachments: true)
    let probe: ChannelAttachmentProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.record(message)
    }
}

private struct AttachmentFixtureProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "channel-attachment-fixture", displayName: "Offline files", requiresAPIKey: false)
    let arguments: Data
    let expectedSuccess: Bool
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let call = try NormalizedToolCall(id: "publish-external-file", name: "SendMessage", argumentsJSON: arguments)
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    let result = try #require(request.toolExchanges.last?.results.first)
                    expectNoDifference(result.isError, !expectedSuccess)
                    expectNoDifference(result.wireText.contains("durably queued, not confirmed delivered"), expectedSuccess)
                    #expect(!result.wireText.contains("Saved message receipt:"))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Foreground channel attachment publication", .timeLimit(.minutes(1)))
@MainActor struct GroupChannelAttachmentAppTests {
    @Test(arguments: ["approve", "read-denied", "deny", "stop", "account", "members", "connection", "connector", "quota-reserve", "quota-commit", "queue-write", "corrupt", "blob-link"], [false, true])
    func capturedLocalAttachmentHasIndependentReadAndSendReviews(mode: String, automaticReviewEnabled: Bool) async throws {
        try await checkLocalAttachment(mode: mode, automaticReviewEnabled: automaticReviewEnabled)
    }

    @Test(arguments: LocalGalleryFormatFixture.publicationFormats)
    func actualImageFormatsPreserveCapturedBytesThroughChannelCAS(type: String) async throws {
        try await checkLocalAttachment(mode: "approve", automaticReviewEnabled: false, type: type)
    }

    @Test func reconciliationCountsBothRetainedAndActiveChannelBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-quarantine-quota-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ChannelAttachmentProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [AttachmentFixtureConnector(probe: probe)])
        await model.bootstrap()
        let store = AttachmentStore(rootURL: root.appending(path: "channel-attachments"))
        let file = try PreparedAgentPublicationFile(bytes: Data("Retained channel file".utf8), filename: "report.txt")
        let now = Date(timeIntervalSince1970: 1_000)
        _ = try await store.ingest(prepared: file, createdAt: now)
        try await store.quarantine(id: file.digest)
        _ = try await store.ingest(prepared: file, createdAt: now)
        let inventory = try await store.inventory()
        expectNoDifference(inventory.active, [file.digest: Int64(file.bytes.count)])
        expectNoDifference(inventory.quarantined, inventory.active)
        await model.reconcileQuota()
        let ledger = try StorageQuotaLedger.live(dataRoot: root)
        let active = await ledger.record(scope: "channel-attachment-blob", key: file.digest)
        let retained = await ledger.record(scope: "channel-quarantined-attachment-blob", key: file.digest)
        expectNoDifference(active?.byteCount, Int64(file.bytes.count))
        expectNoDifference(retained?.byteCount, Int64(file.bytes.count))
    }

    private func checkLocalAttachment(mode: String, automaticReviewEnabled: Bool, type: String = "txt") async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-file-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appending(path: "workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let filename = type == "txt" ? "report.txt" : LocalGalleryFormatFixture.filename(type: type)
        let mime = type == "txt" ? "text/plain" : LocalGalleryFormatFixture.mimeType(type: type)
        let source = workspace.appending(path: filename)
        let bytes = type == "txt" ? Data("Reviewed immutable report".utf8) : try LocalGalleryFormatFixture.bytes(type: type)
        try bytes.write(to: source)
        let captured = try PreparedAgentPublicationFile(bytes: bytes, filename: filename)
        let fault = ChannelAttachmentQuotaFault(root: root, digest: captured.digest)
        let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
        try await grants.authorize(workspace)
        let generation = UUID(uuidString: "34000000-0000-0000-0000-000000000003")!, key = Data(repeating: 29, count: 32)
        let authenticator = LocalSessionAuthenticator(sessionKey: key)
        let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
            authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
        let runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key, helper: helper)
        let probe = ChannelAttachmentProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            quotaFaultInjector: { try fault.inject($0) },
            channelService: channels, channelConnectors: [AttachmentFixtureConnector(probe: probe)])
        await model.bootstrap()
        await model.registry.register(AttachmentFixtureProvider(arguments: try JSONEncoder().encode([
            "type": "attachment", "url": source.absoluteString, "alt": "Reviewed report", "channel": "slack:C_FILES"
        ]), expectedSuccess: mode == "approve"))
        let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "",
            providerID: "channel-attachment-fixture", modelID: "fixture"))
        #expect(await model.createGroup(name: "Files", summary: "", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        let connection = ChannelConnection(connectorID: "slack", displayName: "Fixture connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: sender.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        await model.setAutoReviewEnabled(automaticReviewEnabled)
        var finished = false
        let run = Task { await model.sendGroupMessage(groupID: group.id, text: "Share this report"); finished = true }
        defer { run.cancel() }
        try await eventually { !model.pendingToolApprovals.isEmpty || finished }
        let read = try #require(model.pendingToolApprovals.first)
        let beforeRead = await channels.deliveries()
        expectNoDifference(beforeRead, [])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        model.resolveLocalToolApproval(id: read.id, allowed: mode != "read-denied")
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty || finished }
        if mode == "read-denied" {
            await run.value
            let deniedQueue = await channels.deliveries(), deniedSends = await probe.sent
            expectNoDifference(deniedQueue, []); expectNoDifference(deniedSends, [])
            #expect(model.pendingAutoReviewApprovals.isEmpty && model.pendingToolApprovals.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "channel-attachments").path))
            return
        }
        let send = try #require(model.pendingAutoReviewApprovals.first)
        expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
        let details = try #require(send.action.context.metadata["agentMessage"])
        for text in ["slack:C_FILES", filename, mime, captured.digest, "Reviewed report"] { #expect(details.contains(text)) }
        let beforeSend = await channels.deliveries()
        expectNoDifference(beforeSend, [])
        if mode == "stop" { await model.stopGroup(id: group.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: group.id, memberIDs: []) }
        if mode == "connection" { try await channels.setConnectionEnabled(id: connection.id, enabled: false) }
        if mode == "connector" { await channels.register(AttachmentFixtureConnector(probe: probe)) }
        if mode.hasPrefix("quota-") { fault.arm(mode) }
        let channelState = root.appending(path: "channels.json"), backup = root.appending(path: "channels-before.json")
        if mode == "queue-write" {
            try FileManager.default.moveItem(at: channelState, to: backup)
            try FileManager.default.createDirectory(at: channelState, withIntermediateDirectories: false)
        }
        let blob = root.appending(path: "channel-attachments").appending(path: String(captured.digest.prefix(2))).appending(path: captured.digest)
        let outside = root.appending(path: "outside.txt")
        if mode == "corrupt" || mode == "blob-link" {
            try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mode == "corrupt" { try Data("Tampered CAS bytes".utf8).write(to: blob) }
            else {
                try bytes.write(to: outside)
                try FileManager.default.createSymbolicLink(at: blob, withDestinationURL: outside)
            }
        }
        try Data("Unreviewed replacement".utf8).write(to: source)
        await model.resolveGroupApproval(send, groupID: group.id, approve: mode != "deny")
        await run.value
        let deliveries = await channels.deliveries()
        let expected = ChannelAttachment(blobID: captured.digest, filename: filename, mimeType: mime, byteCount: Int64(bytes.count))
        expectNoDifference(deliveries.map(\.outbound), mode == "approve" ? [.init(text: "Reviewed report", attachments: [expected])] : [])
        if mode == "approve" {
            let store = AttachmentStore(rootURL: root.appending(path: "channel-attachments"))
            let installed = try await store.data(for: .init(id: expected.blobID, filename: expected.filename,
                mimeType: expected.mimeType, byteCount: expected.byteCount, kind: .document))
            expectNoDifference(installed, bytes)
        } else {
            let sent = await probe.sent
            expectNoDifference(sent, [])
        }
        if mode.hasPrefix("quota-") { #expect(fault.didTrigger) }
        if mode == "corrupt" { expectNoDifference(try Data(contentsOf: blob), Data("Tampered CAS bytes".utf8)) }
        if mode == "blob-link" { expectNoDifference(try Data(contentsOf: outside), bytes) }
        if mode == "queue-write" {
            try FileManager.default.removeItem(at: channelState)
            try FileManager.default.moveItem(at: backup, to: channelState)
        }
        if ["approve", "quota-reserve", "quota-commit", "queue-write"].contains(mode) {
            // Blob installation and durable queue save are not one transaction.
            // A later failure must still charge any physically installed bytes.
            let store = AttachmentStore(rootURL: root.appending(path: "channel-attachments"))
            let inventory = try await store.inventory()
            expectNoDifference(inventory.active, mode == "quota-reserve" ? [:] : [captured.digest: Int64(bytes.count)])
            expectNoDifference(inventory.temporaryFiles, [])
            await model.reconcileQuota()
            let ledger = try StorageQuotaLedger.live(dataRoot: root)
            let record = await ledger.record(scope: "channel-attachment-blob", key: captured.digest)
            expectNoDifference(record?.byteCount, mode == "quota-reserve" ? nil : Int64(bytes.count))
        }
        #expect(model.pendingToolApprovals.isEmpty && model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(group.id))
    }

    @Test(arguments: ["approve", "deny-source", "deny-send", "stop-source", "stop-send", "account-source", "account-send", "members-source", "members-send", "redirect", "redirect-denied", "first-image", "corrupt-image"], [false, true])
    func HTTPSDownloadConsentDoesNotAuthorizeChannelSend(mode: String, automaticReviewEnabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-https-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ChannelAttachmentProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let image = ["first-image", "corrupt-image"].contains(mode)
        let bytes = mode == "first-image" ? try LocalGalleryFormatFixture.bytes(type: "png") : Data("Captured HTTPS report".utf8)
        await probe.replacePayload(bytes)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [AttachmentFixtureConnector(probe: probe)])
        model.remoteAttachmentDownloader = AttachmentFixtureDownloader(probe: probe, redirect: mode.hasPrefix("redirect"))
        await model.bootstrap()
        let sourceURL = "https://source.example/\(image ? "first.png" : "report.txt")?signature=a%2Bb"
        let reference = try RemoteAttachmentReference(url: sourceURL, alt: "Reviewed caption")
        let caption = "Reviewed caption"
        let arguments: [String: Any] = image
            ? ["type": "text", "content": caption, "channel": "slack:C_FILES", "images": [
                ["url": sourceURL, "alt": "Reviewed caption"],
                ["url": "file:///never-read/not-sent.png", "alt": "EXCLUDED LOCAL"],
                ["url": "https://never.example/not-sent.png", "alt": "EXCLUDED REMOTE"]]]
            : ["type": "attachment", "url": sourceURL, "alt": caption, "channel": "slack:C_FILES"]
        let succeeds = ["approve", "redirect", "first-image"].contains(mode)
        await model.registry.register(AttachmentFixtureProvider(arguments: try JSONSerialization.data(withJSONObject: arguments), expectedSuccess: succeeds))
        let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "",
            providerID: "channel-attachment-fixture", modelID: "fixture"))
        #expect(await model.createGroup(name: "HTTPS files", summary: "", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        try await channels.saveConnection(.init(connectorID: "slack", displayName: "Fixture connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: sender.id, ownerAccountID: "local"))
        await model.setAutoReviewEnabled(automaticReviewEnabled)
        var finished = false
        let run = Task { await model.sendGroupMessage(groupID: group.id, text: "Share this HTTPS artifact"); finished = true }
        defer { run.cancel() }
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty || finished }
        let download = try #require(model.pendingAutoReviewApprovals.first)
        expectNoDifference(download.action.context.metadata["agentChannelSourceDownload"], "true")
        expectNoDifference(download.action.target, .resource(kind: "remote-attachment-source", identifier: sourceURL))
        let downloadDetails = try #require(download.action.context.metadata["agentMessage"])
        #expect(downloadDetails.contains(sourceURL))
        #expect(downloadDetails.contains(l10n("Downloading does not authorize sending the file to a channel.")))
        let beforeSource = await probe.downloads, queueBeforeSource = await channels.deliveries()
        expectNoDifference(beforeSource, []); expectNoDifference(queueBeforeSource, [])
        if mode == "stop-source" { await model.stopGroup(id: group.id) }
        if mode == "account-source" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members-source" { await model.updateGroupMembers(groupID: group.id, memberIDs: []) }
        await model.resolveGroupApproval(download, groupID: group.id, approve: mode != "deny-source")
        try await eventually { !model.pendingAutoReviewApprovals.isEmpty || finished }
        if ["deny-source", "stop-source", "account-source", "members-source", "corrupt-image"].contains(mode) {
            await run.value
            let fetched = await probe.downloads
            expectNoDifference(fetched, mode == "corrupt-image" ? [reference] : [])
        } else {
            if mode.hasPrefix("redirect") {
                let redirect = try #require(model.pendingAutoReviewApprovals.first)
                expectNoDifference(redirect.action.context.metadata["agentChannelSourceDownload"], "true")
                expectNoDifference(redirect.action.target, .resource(kind: "remote-attachment-source", identifier: "https://redirect.example/final.txt?token=exact"))
                let redirectDetails = try #require(redirect.action.context.metadata["agentMessage"])
                #expect(redirectDetails.contains(sourceURL) && redirectDetails.contains("https://redirect.example/final.txt?token=exact"))
                let beforeRedirect = await probe.downloads
                expectNoDifference(beforeRedirect, [reference])
                await model.resolveGroupApproval(redirect, groupID: group.id, approve: mode != "redirect-denied")
                try await eventually { !model.pendingAutoReviewApprovals.isEmpty || finished }
            }
            if mode == "redirect-denied" { await run.value }
            else {
                let send = try #require(model.pendingAutoReviewApprovals.first)
                expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
                let file = try PreparedAgentPublicationFile(bytes: bytes, filename: image ? "first.png" : "report.txt")
                let details = try #require(send.action.context.metadata["agentMessage"])
                for value in [sourceURL, file.filename, file.digest, caption, "slack:C_FILES", image ? "image/png" : "text/plain"] { #expect(details.contains(value)) }
                if mode == "first-image" {
                    for value in [l10n("Only the first image is sent to the channel. The remaining images are not sent."),
                        "file:///never-read/not-sent.png", "EXCLUDED LOCAL", "https://never.example/not-sent.png", "EXCLUDED REMOTE"] { #expect(details.contains(value)) }
                }
                let beforeSend = await channels.deliveries()
                expectNoDifference(beforeSend, [])
                if mode == "stop-send" { await model.stopGroup(id: group.id) }
                if mode == "account-send" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
                if mode == "members-send" { await model.updateGroupMembers(groupID: group.id, memberIDs: []) }
                await probe.replacePayload(Data("Unreviewed replacement".utf8))
                await model.resolveGroupApproval(send, groupID: group.id, approve: mode != "deny-send")
                await run.value
                if succeeds {
                    let queued = await channels.deliveries()
                    let metadata = ChannelAttachment(blobID: file.digest, filename: file.filename,
                        mimeType: image ? "image/png" : "text/plain", byteCount: Int64(bytes.count))
                    expectNoDifference(queued.map(\.outbound), [.init(text: caption, attachments: [metadata])])
                    let stored = try await AttachmentStore(rootURL: root.appending(path: "channel-attachments")).data(for:
                        .init(id: file.digest, filename: file.filename, mimeType: metadata.mimeType, byteCount: metadata.byteCount, kind: image ? .image : .document))
                    expectNoDifference(stored, bytes)
                }
            }
        }
        let fetched = await probe.downloads
        let expectedDownloads = ["deny-source", "stop-source", "account-source", "members-source"].contains(mode) ? []
            : mode == "redirect" ? [reference, try RemoteAttachmentReference(url: "https://redirect.example/final.txt?token=exact", alt: reference.alt)] : [reference]
        expectNoDifference(fetched, expectedDownloads)
        if !succeeds {
            let queued = await channels.deliveries(), sent = await probe.sent
            expectNoDifference(queued, []); expectNoDifference(sent, [])
            #expect(!FileManager.default.fileExists(atPath: root.appending(path: "channel-attachments").path))
        }
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.pendingToolApprovals.isEmpty && model.pendingWorkspaceFolders.isEmpty)
        #expect(!model.runningGroups.contains(group.id))
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [340.0, 620.0])
    func realSourceAndSendCardsKeepWholeIntent(language: String, width: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-attachment-card-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try await FiliconLocalization.$languageOverride.withValue(language) {
            let probe = ChannelAttachmentProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
            let bytes = try LocalGalleryFormatFixture.bytes(type: "png")
            await probe.replacePayload(bytes)
            let sourceURL = "https://source.example/MARKER_SOURCE_report.png?signature=a%2Bb"
            let caption = "BEGIN CAPTION\n" + String(repeating: "Complete reviewed caption. ", count: 60) + "\nEND CAPTION"
            let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
                channelService: channels, channelConnectors: [AttachmentFixtureConnector(probe: probe)])
            model.remoteAttachmentDownloader = AttachmentFixtureDownloader(probe: probe)
            await model.bootstrap()
            let arguments: [String: Any] = ["type": "text", "content": caption, "channel": "slack:C_FILES", "images": [
                ["url": sourceURL, "alt": "First image"],
                ["url": "https://unused.example/EXCLUDED_IMAGE.png", "alt": "EXCLUDED ALT"]]]
            await model.registry.register(AttachmentFixtureProvider(arguments: try JSONSerialization.data(withJSONObject: arguments), expectedSuccess: false))
            let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "",
                providerID: "channel-attachment-fixture", modelID: "fixture"))
            #expect(await model.createGroup(name: "Card fixture", summary: "", memberIDs: [sender.id]))
            let group = try #require(model.groups.first)
            try await channels.saveConnection(.init(connectorID: "slack", displayName: "Fixture connection",
                secretReference: "keychain://channels/TEST-only-never-read", agentID: sender.id, ownerAccountID: "local"))
            var finished = false
            let run = Task { await model.sendGroupMessage(groupID: group.id, text: "Review this image publication"); finished = true }
            defer { run.cancel() }
            try await eventually { !model.pendingAutoReviewApprovals.isEmpty || finished }
            let source = try #require(model.pendingAutoReviewApprovals.first)
            for dark in [false, true] {
                try await renderCard(model: model, groupID: group.id, language: language, width: width, dark: dark,
                    stage: "source", markers: ["MARKER_SOURCE_report", "signature=", "%2Bb"],
                    notices: ["Download this attachment source?", "Downloading does not authorize sending the file to a channel."])
            }
            await model.resolveGroupApproval(source, groupID: group.id, approve: true)
            try await eventually { !model.pendingAutoReviewApprovals.isEmpty || finished }
            let send = try #require(model.pendingAutoReviewApprovals.first)
            let captured = try PreparedAgentPublicationFile(bytes: bytes, filename: "MARKER_SOURCE_report.png")
            let details = try #require(send.action.context.metadata["agentMessage"])
            #expect(details.contains(caption) && details.contains(captured.digest))
            let sizeLabel = try #require(["en": "Size", "zh-Hant": "大小", "zh-Hans": "大小", "fr": "Taille",
                "es": "Tamaño", "ja": "サイズ", "ko": "크기"][language])
            let localizedBytes = ByteCountFormatStyle(style: .file, locale: Locale(identifier: language)).format(Int64(bytes.count))
            #expect(details.contains("\n\(sizeLabel): \(localizedBytes)\n"))
            if language == "ko" {
                expectNoDifference(FiliconLocalization.string("bytes"), "바이트")
                expectNoDifference(FiliconLocalization.string("Type"), "유형")
                #expect(details.contains("\n유형: image/png\n"))
            }
            for dark in [false, true] {
                try await renderCard(model: model, groupID: group.id, language: language, width: width, dark: dark,
                    stage: "send", markers: ["BEGIN CAPTION", "END CAPTION", "C_FILES", "MARKER_SOURCE_report", "SHA-256", "EXCLUDED_IMAGE", "EXCLUDED ALT"],
                    notices: ["Queue this message to an external channel?", "Only the first image is sent to the channel. The remaining images are not sent.", "Queued is not delivered. Stop does not recall a queued message."])
            }
            await model.resolveGroupApproval(send, groupID: group.id, approve: false)
            await run.value
            let queued = await channels.deliveries(), sent = await probe.sent, fetched = await probe.downloads
            expectNoDifference(queued, []); expectNoDifference(sent, [])
            expectNoDifference(fetched, [try RemoteAttachmentReference(url: sourceURL, alt: "First image")])
        }
    }

    private func renderCard(model: AppModel, groupID: UUID, language: String, width: Double, dark: Bool,
        stage: String, markers: [String], notices: [String]) async throws {
        try await withUIRenderTurn(language: language) {
            let details = try #require(model.pendingAutoReviewApprovals.first?.action.context.metadata["agentMessage"])
            for notice in notices {
                #expect(details.contains(FiliconLocalization.string(notice)))
                if language != "en" { #expect(FiliconLocalization.string(notice) != notice) }
            }
            let host = NSHostingView(rootView: GroupToolApprovalPanel(groupID: groupID)
                .environmentObject(model).foregroundStyle(FiliconTheme.textPrimary).padding(16)
                .frame(width: width).background(FiliconTheme.canvas)
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let size = host.fittingSize
            #expect(abs(size.width - CGFloat(width)) < 0.5)
            #expect(size.height > 200 && size.height < 5_000)
            host.frame = .init(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
            let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            // Compare across wrap boundaries; source identity must not vanish
            // merely because a narrow translated card splits a URL.
            let compact = visible.filter { !$0.isWhitespace }
            for marker in markers { #expect(compact.contains(marker.filter { !$0.isWhitespace })) }
            if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appending(path: "channel-attachment-\(stage)-\(language)-\(Int(width))-\(dark ? "dark" : "light").png"))
            }
        }
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
