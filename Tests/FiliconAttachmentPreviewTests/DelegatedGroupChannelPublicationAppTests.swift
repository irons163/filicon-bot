import Foundation
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
import FiliconAutoReview
import FiliconChannels
import FiliconDomain
import FiliconLocalTools
import FiliconProviderKit
@testable import Filicon

private actor DelegatedChannelProbe {
    var requests: [InferenceRequest] = []
    var results: [NormalizedToolResult] = []
    var sent: [ChannelOutbound] = []
    var downloads: [RemoteAttachmentReference] = []
    var localReads: [LocalToolWireRequest] = []
    var bytes = Data("EXACT_DELEGATED_BYTES".utf8)
    func request(_ value: InferenceRequest) -> Int {
        requests.append(value)
        return requests.filter { $0.conversationID == value.conversationID }.count
    }
    func result(_ value: NormalizedToolResult) { results.append(value) }
    func send(_ value: ChannelOutbound) { sent.append(value) }
    func replaceBytes() { bytes = Data("UNREVIEWED_REPLACEMENT".utf8) }
    func read(_ request: LocalToolWireRequest) { localReads.append(request) }
    func download(_ reference: RemoteAttachmentReference, redirect: Bool) throws -> RemoteAttachmentDownload {
        downloads.append(reference)
        if redirect && reference.url.contains("source.example") {
            throw RemoteAttachmentDownloadError.redirect("https://redirect.example/delegated.html?signature=exact")
        }
        return .init(reference: reference, data: bytes, declaredMIMEType: "text/plain")
    }
}

private struct DelegatedChannelLocalHelper: LocalToolHelperProtocol {
    let probe: DelegatedChannelProbe
    let helper: LocalToolProcessHost
    func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        await probe.read(request)
        return await helper.perform(request)
    }
    func cancel(runID: UUID, generation: UUID) async { await helper.cancel(runID: runID, generation: generation) }
}

private struct DelegatedChannelConnector: ChannelConnector {
    var supportsAttachments = true
    var descriptor: ChannelConnectorDescriptor {
        .init(id: "slack", displayName: "Offline delegated fixture", supportsAttachments: supportsAttachments)
    }
    let probe: DelegatedChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws { await probe.send(message) }
}

private struct DelegatedChannelDownloader: RemoteAttachmentDownloading {
    let probe: DelegatedChannelProbe
    let redirect: Bool
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        try await probe.download(reference, redirect: redirect)
    }
}

private struct DelegatedChannelProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "delegated-channel-fixture", displayName: "Offline delegated publication", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> Void
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, executeTool)
                    continuation.yield(.textDelta("PRIVATE_UNPUBLISHED_DRAFT"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Reviewed delegated group channel publication", .serialized, .timeLimit(.minutes(1)))
@MainActor struct DelegatedGroupChannelPublicationAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let channels: ChannelService
        let probe: DelegatedChannelProbe
        let origin: UUID
        let source: AgentGroup
        let target: AgentGroup
        let sender: AgentProfile
        let recipient: AgentProfile
        let connection: ChannelConnection
        let quote: RoomMessage
        let other: Conversation
        let direct: Bool
        let localSource: URL?
    }

    private func fixture(direct: Bool = false, attachment: Bool = false, redirect: Bool = false,
                         supportsAttachments: Bool = true, localFile: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-delegated-channel-\(UUID())")
        let probe = DelegatedChannelProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let connector = DelegatedChannelConnector(supportsAttachments: supportsAttachments, probe: probe)
        let profiles = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await profiles.create(name: "Engineer", instructions: "ORIGIN_PRIVATE_PERSONA",
            providerID: "delegated-channel-fixture", modelID: "fixture")
        let recipient = try await profiles.create(name: "Designer", instructions: "RECIPIENT_PERSONA",
            providerID: "delegated-channel-fixture", modelID: "fixture")
        let groupStore = try GroupService(agents: profiles, storeURL: root.appending(path: "groups.json"))
        let source = try await groupStore.create(name: "Source", memberIDs: [sender.id])
        let target = try await groupStore.create(name: "Destination", memberIDs: [sender.id, recipient.id])
        let quote = try await groupStore.postUserMessage("TARGET_QUOTE_ONLY", groupID: target.id)
        var directSource = Conversation(title: "Bound source", providerID: sender.providerID, modelID: sender.modelID)
        directSource.agentBinding = .init(accountID: "local", agentID: sender.id)
        let origin = direct ? directSource.id : source.id
        let other = Conversation(title: "Unrelated", messages: [.init(role: .user, text: "UNRELATED_PRIVATE_HISTORY")])
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save((direct ? [directSource] : []) + [other])
        let localSource: URL?, runtime: LocalToolRuntime?
        if localFile {
            let workspace = root.appending(path: "workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let source = workspace.appending(path: "delegated.html")
            try Data("EXACT_DELEGATED_BYTES".utf8).write(to: source)
            let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
            try await grants.authorize(workspace)
            let generation = UUID(), key = Data(repeating: 41, count: 32)
            let authenticator = LocalSessionAuthenticator(sessionKey: key)
            let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
                authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
            runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key,
                helper: DelegatedChannelLocalHelper(probe: probe, helper: helper))
            localSource = source
        } else { localSource = nil; runtime = nil }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            localToolRuntime: runtime,
            channelService: channels, channelConnectors: [connector])
        await model.bootstrap()
        try await model.loadAllMessages(for: other.id)
        let connection = ChannelConnection(connectorID: "slack", displayName: "Recipient's own connection",
            secretReference: "keychain://channels/NEVER_READ_OFFLINE", agentID: recipient.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        // Foreground owner's credential must never be substituted for recipient.
        try await channels.saveConnection(.init(connectorID: "slack", displayName: "Sender's unrelated connection",
            secretReference: "keychain://channels/NEVER_READ_ORIGIN", agentID: sender.id, ownerAccountID: "local"))
        model.remoteAttachmentDownloader = DelegatedChannelDownloader(probe: probe, redirect: redirect)
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["SendToAgent", "SendMessage"], ask: [])
        let targetID = target.id, quoteID = quote.id
        await model.registry.register(DelegatedChannelProvider { request, execute in
            if request.conversationID == origin {
                let call = try NormalizedToolCall(id: "delegate", name: "SendToAgent", argumentsJSON: JSONEncoder().encode([
                    "recipientID": targetID.uuidString, "message": "EXACT_SHARED_TASK"
                ]))
                await probe.result(try await execute(call))
                return
            }
            let count = await probe.request(request)
            expectNoDifference(request.conversationID, targetID)
            #expect(request.messages[0].text.contains(recipient.id.uuidString))
            #expect(request.messages.allSatisfy { !$0.text.contains("ORIGIN_PRIVATE_PERSONA") && !$0.text.contains("UNRELATED_PRIVATE_HISTORY") && !$0.text.contains("ORIGIN_ONLY_INPUT") })
            if count > 1 { return }
            let descriptor = try #require(request.tools.first { $0.name == "SendMessage" })
            let schema = try #require(JSONSerialization.jsonObject(with: descriptor.inputSchema) as? [String: Any])
            #expect((schema["properties"] as? [String: Any])?["channel"] != nil)
            var arguments = attachment || localFile
                ? ["type": "attachment", "url": localSource?.absoluteString ?? "https://source.example/delegated.html?signature=exact", "alt": "EXACT_CAPTION", "channel": "slack:C_DELEGATED"]
                : ["type": "text", "content": "EXACT_PUBLIC_RESULT", "channel": "slack:C_DELEGATED"]
            arguments["reply_to"] = quoteID.uuidString
            let call = try NormalizedToolCall(id: "delegated-publication", name: "SendMessage", argumentsJSON: JSONEncoder().encode(arguments))
            let result = try await execute(call)
            await probe.result(result)
            if !result.isError {
                let replay = try await execute(call)
                expectNoDifference(replay, result)
            }
        })
        if direct { model.selectRoute(.conversation(origin)); await model.refreshModels() }
        let currentOther = try #require(model.conversations.first { $0.id == other.id })
        return .init(root: root, model: model, channels: channels, probe: probe, origin: origin,
            source: source, target: target, sender: sender, recipient: recipient, connection: connection,
            quote: quote, other: currentOther, direct: direct, localSource: localSource)
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("Isolated delegated publication did not reach expected state")
    }
    private func review(_ f: Fixture, after id: String? = nil) async throws -> PendingApproval {
        try await eventually { f.model.pendingAutoReviewApprovals.contains { $0.id != id } }
        return try #require(f.model.pendingAutoReviewApprovals.first { $0.id != id })
    }
    private func resolve(_ f: Fixture, _ pending: PendingApproval, approve: Bool = true) async {
        if f.direct {
            f.model.selectRoute(.conversation(f.origin))
            f.model.handleTranscriptCardIntent(approve ? .approveReview(reviewID: pending.id) : .rejectReview(reviewID: pending.id))
        } else { await f.model.resolveGroupApproval(pending, groupID: f.origin, approve: approve) }
    }
    private func start(_ f: Fixture) async throws -> Task<Void, Never> {
        let work: Task<Void, Never>
        if f.direct {
            f.model.selectRoute(.conversation(f.origin)); f.model.draft = "ORIGIN_ONLY_INPUT: delegate the exact shared task"
            f.model.send()
            work = Task { try? await eventually { !f.model.isConversationWorking(f.origin) } }
        } else {
            work = Task { await f.model.sendGroupMessage(groupID: f.origin, text: "ORIGIN_ONLY_INPUT: delegate the exact shared task") }
        }
        let delegation = try await review(f)
        expectNoDifference(delegation.action.context.metadata["tool"], "SendToAgent")
        let before = await f.channels.deliveries()
        expectNoDifference(before, [])
        await resolve(f, delegation)
        try await eventually { !f.model.pendingAutoReviewApprovals.contains { $0.id == delegation.id } }
        return work
    }

    @Test(arguments: [false, true], [false, true])
    func independentSendReviewSavesOnlyInDestinationGroup(direct: Bool, approve: Bool) async throws {
        let f = try await fixture(direct: direct); defer { try? FileManager.default.removeItem(at: f.root) }
        let work = try await start(f); defer { work.cancel() }
        let pending = try await review(f)
        expectNoDifference(pending.action.context.conversationID, f.origin)
        expectNoDifference(pending.action.context.metadata["agentChannelPublication"], "true")
        expectNoDifference(pending.action.target, .resource(kind: "channel", identifier: f.connection.id.uuidString))
        let details = try #require(pending.action.context.metadata["agentMessage"])
        #expect(details.contains("EXACT_PUBLIC_RESULT") && details.contains("slack:C_DELEGATED") && details.contains(f.quote.id.uuidString))
        #expect(!details.contains(f.connection.secretReference))
        let before = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(before, []); expectNoDifference(sent, [])
        await resolve(f, pending, approve: approve)
        await work.value
        try await eventually { f.model.runningGroups.isEmpty && !f.model.isConversationWorking(f.origin) }
        let deliveries = await f.channels.deliveries()
        expectNoDifference(deliveries.map(\.outbound), approve ? [.init(text: "EXACT_PUBLIC_RESULT")] : [])
        expectNoDifference(deliveries.compactMap { $0.authorization?.agentID }, approve ? [f.recipient.id] : [])
        let canonical = f.model.groupMessages[f.target.id, default: []].filter { $0.externalPublication != nil }
        expectNoDifference(canonical.count, approve ? 1 : 0)
        if approve {
            let row = try #require(canonical.first), delivery = try #require(deliveries.first)
            expectNoDifference(row.id, delivery.id); expectNoDifference(row.senderID, f.recipient.id)
            expectNoDifference(row.replyToMessageID, f.quote.id)
            expectNoDifference(delivery.origin?.conversationID, f.target.id)
            expectNoDifference(delivery.origin?.senderID, f.recipient.id)
            expectNoDifference(delivery.origin?.route, .groupConversation)
            var expected = RoomMessage.externalChannelMessage(try #require(ChannelTranscriptProjection.publication(for: delivery)))
            expected.shortAddress = row.shortAddress
            expectNoDifference(row, expected)
            let result = try #require(await f.probe.results.last)
            #expect(!result.isError && result.wireText.contains("durably queued, not confirmed delivered"))
            #expect(result.wireText.contains("Saved message receipt:") && result.wireText.contains(row.id.uuidString))
            let reopened = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false,
                channelService: f.channels, channelConnectors: [DelegatedChannelConnector(probe: f.probe)])
            await reopened.reloadWorkspaceData()
            expectNoDifference(reopened.groupMessages[f.target.id]?.filter { $0.externalPublication != nil }, canonical)
        }
        #expect(f.model.groupMessages[f.source.id, default: []].allSatisfy { $0.externalPublication == nil })
        #expect(f.model.conversations.flatMap(\.messages).allSatisfy { $0.externalChannelPublication == nil && !$0.text.contains("PRIVATE_UNPUBLISHED_DRAFT") })
        expectNoDifference(f.model.conversations.first { $0.id == f.other.id }, f.other)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test(arguments: ["stop-origin", "stop-target", "account", "members", "members-ABA", "profile-ABA", "origin-profile-ABA", "origin-group-ABA", "connection", "connector", "presence", "navigation"])
    func invalidatedReviewCannotReviveAfterRestore(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let work = try await start(f); defer { work.cancel() }
        let pending = try await review(f)
        switch mode {
        case "stop-origin": await f.model.stopGroup(id: f.origin)
        case "stop-target": await f.model.stopGroup(id: f.target.id)
        case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "members": await f.model.updateGroupMembers(groupID: f.target.id, memberIDs: [f.sender.id])
        case "members-ABA", "origin-group-ABA":
            let groupID = mode == "members-ABA" ? f.target.id : f.source.id
            let index = try #require(f.model.groups.firstIndex { $0.id == groupID })
            let original = f.model.groups[index]
            f.model.groups[index].summary = "UNREVIEWED_DESCRIPTION"
            f.model.groups[index] = original
        case "profile-ABA", "origin-profile-ABA":
            let profile = mode == "profile-ABA" ? f.recipient : f.sender
            var changed = profile; changed.instructions = "UNREVIEWED_PERSONA"
            #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(profile))
        case "connection": try await f.channels.setConnectionEnabled(id: f.connection.id, enabled: false)
        case "connector": await f.channels.register(DelegatedChannelConnector(probe: f.probe))
        case "presence":
            var changed = f.recipient; changed.unreadCount = 8; changed.updatedAt = Date().addingTimeInterval(50)
            #expect(await f.model.updateAgent(changed))
        case "navigation": f.model.selectRoute(.conversation(f.other.id))
        default: break
        }
        if !["connection", "connector", "presence", "navigation"].contains(mode) {
            // Invalid host scopes retire the waiter without requiring another
            // click or waiting for the five-minute human review expiry.
            try await eventually { f.model.pendingAutoReviewApprovals.isEmpty }
        }
        await resolve(f, pending)
        await work.value
        let beforeLateClick = await f.channels.deliveries()
        let succeeds = mode == "presence" || mode == "navigation"
        expectNoDifference(beforeLateClick.map(\.outbound), succeeds ? [.init(text: "EXACT_PUBLIC_RESULT")] : [])
        await resolve(f, pending)
        let afterLateClick = await f.channels.deliveries()
        expectNoDifference(afterLateClick, beforeLateClick)
        expectNoDifference(f.model.groupMessages[f.target.id, default: []].filter { $0.externalPublication != nil }.count, succeeds ? 1 : 0)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.runningGroups.isEmpty)
    }

    @Test(arguments: ["binding-ABA", "route-ABA"])
    func staleNativeDirectCardDoesNotRestoreOrPublish(mode: String) async throws {
        let f = try await fixture(direct: true); defer { try? FileManager.default.removeItem(at: f.root) }
        let work = try await start(f); defer { work.cancel() }
        let pending = try await review(f)
        let index = try #require(f.model.conversations.firstIndex { $0.id == f.origin })
        let original = f.model.conversations[index]
        if mode == "binding-ABA" { f.model.conversations[index].agentBinding = .init(accountID: "local", agentID: f.recipient.id) }
        else { f.model.conversations[index].modelID = "UNREVIEWED_MODEL" }
        f.model.conversations[index] = original
        try await eventually { f.model.pendingAutoReviewApprovals.isEmpty }
        await resolve(f, pending)
        await work.value
        let queue = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(queue, []); expectNoDifference(sent, [])
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.runningGroups.isEmpty)
    }

    @Test(arguments: ["approve", "deny-source", "deny-send", "redirect", "deny-redirect", "stop-source", "stop-send", "unsupported"])
    func sourceAndRedirectConsentAreSeparateFromCapturedPublication(mode: String) async throws {
        let f = try await fixture(attachment: true, redirect: mode == "redirect" || mode == "deny-redirect", supportsAttachments: mode != "unsupported")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let work = try await start(f); defer { work.cancel() }
        if mode != "unsupported" {
            let source = try await review(f)
            expectNoDifference(source.action.context.metadata["agentChannelSourceDownload"], "true")
            expectNoDifference(source.action.context.conversationID, f.origin)
            let before = await f.probe.downloads, queue = await f.channels.deliveries()
            expectNoDifference(before, []); expectNoDifference(queue, [])
            if mode == "stop-source" { await f.model.stopGroup(id: f.target.id) }
            await resolve(f, source, approve: mode != "deny-source")
            if !["deny-source", "stop-source"].contains(mode) {
                var previous = source.id
                if mode == "redirect" || mode == "deny-redirect" {
                    let redirect = try await review(f, after: previous)
                    expectNoDifference(redirect.action.context.metadata["agentChannelSourceDownload"], "true")
                    previous = redirect.id
                    await resolve(f, redirect, approve: mode != "deny-redirect")
                }
                if mode != "deny-redirect" {
                    let send = try await review(f, after: previous)
                    expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
                    await f.probe.replaceBytes()
                    if mode == "stop-send" { await f.model.stopGroup(id: f.target.id) }
                    await resolve(f, send, approve: mode != "deny-send")
                }
            }
        }
        await work.value
        let succeeds = mode == "approve" || mode == "redirect"
        let prepared = try PreparedAgentPublicationFile(bytes: Data("EXACT_DELEGATED_BYTES".utf8), filename: "delegated.html")
        // Active document formats remain inert binary downloads even if the
        // downloader claims text/plain. Assert installed metadata and bytes.
        let attachment = ChannelAttachment(blobID: prepared.digest, filename: prepared.filename, mimeType: "application/octet-stream", byteCount: Int64(prepared.bytes.count))
        let queue = await f.channels.deliveries(), downloads = await f.probe.downloads, sent = await f.probe.sent
        expectNoDifference(queue.map(\.outbound), succeeds ? [.init(text: "EXACT_CAPTION", attachments: [attachment])] : [])
        let original = try RemoteAttachmentReference(url: "https://source.example/delegated.html?signature=exact", alt: "EXACT_CAPTION")
        let expectedDownloads = ["unsupported", "deny-source", "stop-source"].contains(mode) ? []
            : mode == "redirect" ? [original, try .init(url: "https://redirect.example/delegated.html?signature=exact", alt: original.alt)] : [original]
        expectNoDifference(downloads, expectedDownloads)
        expectNoDifference(sent, [])
        if succeeds {
            let bytes = try await AttachmentStore(rootURL: f.root.appending(path: "channel-attachments")).data(for:
                .init(id: prepared.digest, filename: prepared.filename, mimeType: "application/octet-stream", byteCount: attachment.byteCount, kind: .document))
            expectNoDifference(bytes, prepared.bytes)
            let delivery = try #require(queue.first)
            let publication = try #require(ChannelTranscriptProjection.publication(for: delivery))
            expectNoDifference(publication.sources, [.init(url: original.url, alt: original.alt)])
            expectNoDifference(publication.senderID, f.recipient.id)
            expectNoDifference(publication.conversationID, f.target.id)
            let row = try #require(f.model.groupMessages[f.target.id]?.first { $0.id == delivery.id })
            var expected = RoomMessage.externalChannelMessage(publication); expected.shortAddress = row.shortAddress
            expectNoDifference(row, expected)
        } else { #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "channel-attachments").path)) }
        expectNoDifference(f.model.groupMessages[f.target.id, default: []].filter { $0.externalPublication != nil }.count, succeeds ? 1 : 0)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.runningGroups.isEmpty)
    }

    @Test(arguments: [false, true], ["approve", "deny-read", "deny-send", "stop-read", "stop-send", "persona-ABA-read"])
    func localReadRemainsSeparateAndUsesOriginalScope(direct: Bool, mode: String) async throws {
        let f = try await fixture(direct: direct, localFile: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        let work = try await start(f); defer { work.cancel() }
        try await eventually { !f.model.pendingToolApprovals.isEmpty }
        let read = try #require(f.model.pendingToolApprovals.first), source = try #require(f.localSource)
        expectNoDifference(read.conversationID, f.origin)
        let before = await f.probe.localReads, queueBefore = await f.channels.deliveries()
        expectNoDifference(before, []); expectNoDifference(queueBefore, [])
        #expect(f.model.pendingAutoReviewApprovals.isEmpty)
        if mode == "stop-read" { await f.model.stopGroup(id: f.target.id) }
        if mode == "persona-ABA-read" {
            var changed = f.recipient; changed.instructions = "UNREVIEWED_PERSONA"
            #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(f.recipient))
        }
        f.model.resolveLocalToolApproval(id: read.id, allowed: mode != "deny-read")
        if !["deny-read", "stop-read", "persona-ABA-read"].contains(mode) {
            let send = try await review(f)
            expectNoDifference(send.action.context.conversationID, f.origin)
            expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
            try Data("UNREVIEWED_REPLACEMENT".utf8).write(to: source)
            if mode == "stop-send" { await f.model.stopGroup(id: f.target.id) }
            await resolve(f, send, approve: mode != "deny-send")
        }
        await work.value
        let reads = await f.probe.localReads, downloads = await f.probe.downloads, sent = await f.probe.sent
        let expectedRead = !["deny-read", "stop-read", "persona-ABA-read"].contains(mode)
        expectNoDifference(reads.map(\.operation), expectedRead ? [.readFile(root: source.deletingLastPathComponent().path, relativePath: source.lastPathComponent)] : [])
        expectNoDifference(reads.map(\.scope.agentID), expectedRead ? [f.recipient.id] : [])
        expectNoDifference(downloads, []); expectNoDifference(sent, [])
        let prepared = try PreparedAgentPublicationFile(bytes: Data("EXACT_DELEGATED_BYTES".utf8), filename: source.lastPathComponent)
        let metadata = ChannelAttachment(blobID: prepared.digest, filename: prepared.filename, mimeType: "application/octet-stream", byteCount: Int64(prepared.bytes.count))
        let queue = await f.channels.deliveries()
        expectNoDifference(queue.map(\.outbound), mode == "approve" ? [.init(text: "EXACT_CAPTION", attachments: [metadata])] : [])
        if mode == "approve" {
            let delivery = try #require(queue.first), publication = try #require(ChannelTranscriptProjection.publication(for: delivery))
            expectNoDifference(publication.sources, [.init(url: source.absoluteString, alt: "EXACT_CAPTION")])
            let row = try #require(f.model.groupMessages[f.target.id]?.first { $0.id == delivery.id })
            var expected = RoomMessage.externalChannelMessage(publication); expected.shortAddress = row.shortAddress
            expectNoDifference(row, expected)
            let bytes = try await AttachmentStore(rootURL: f.root.appending(path: "channel-attachments")).data(for:
                .init(id: prepared.digest, filename: prepared.filename, mimeType: metadata.mimeType, byteCount: metadata.byteCount, kind: .document))
            expectNoDifference(bytes, prepared.bytes)
        }
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty && f.model.runningGroups.isEmpty)
        expectNoDifference(f.model.conversations.first { $0.id == f.other.id }, f.other)
    }
}
