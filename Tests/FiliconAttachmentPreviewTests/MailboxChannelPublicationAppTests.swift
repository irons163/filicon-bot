import Foundation
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
import FiliconAutoReview
import FiliconChannels
import FiliconDomain
import FiliconPersistence
import FiliconProviderKit
import FiliconLocalTools
@testable import Filicon

private actor AppMailboxChannelProbe {
    var requests: [InferenceRequest] = []
    var results: [NormalizedToolResult] = []
    var sent: [ChannelOutbound] = []
    var downloads: [RemoteAttachmentReference] = []
    var reads: [LocalToolWireRequest] = []
    var bytes = Data("EXACT_CAPTURED_PEER_FILE".utf8)
    func request(_ value: InferenceRequest) { requests.append(value) }
    func result(_ value: NormalizedToolResult) { results.append(value) }
    func send(_ value: ChannelOutbound) { sent.append(value) }
    func read(_ value: LocalToolWireRequest) { reads.append(value) }
    func replaceBytes() { bytes = Data("UNREVIEWED_REPLACEMENT".utf8) }
    func download(_ reference: RemoteAttachmentReference) -> RemoteAttachmentDownload {
        downloads.append(reference)
        return .init(reference: reference, data: bytes, declaredMIMEType: "text/plain")
    }
}

private struct AppMailboxChannelDownloader: RemoteAttachmentDownloading {
    let probe: AppMailboxChannelProbe
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        await probe.download(reference)
    }
}

private struct AppMailboxChannelLocalHelper: LocalToolHelperProtocol {
    let probe: AppMailboxChannelProbe
    let helper: LocalToolProcessHost
    func perform(_ request: LocalToolWireRequest) async -> LocalToolWireResponse {
        await probe.read(request); return await helper.perform(request)
    }
    func cancel(runID: UUID, generation: UUID) async { await helper.cancel(runID: runID, generation: generation) }
}

private struct AppMailboxChannelConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline peer channel", supportsAttachments: true)
    let probe: AppMailboxChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws { await probe.send(message) }
}

private struct AppMailboxChannelProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "app-mailbox-channel", displayName: "Offline peer inference", requiresAPIKey: false)
    let probe: AppMailboxChannelProbe
    let peerID: UUID
    let channelArguments: [String: String]
    var returnToOwnerID: UUID? = nil
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await probe.request(request)
                    let incoming = request.messages.last?.text.hasPrefix("Incoming peer message") == true
                    let returning = incoming && returnToOwnerID != nil && request.messages.contains {
                        $0.role == .system && $0.text.contains("agent:\(peerID.uuidString)")
                    }
                    let recipient = returning ? try #require(returnToOwnerID) : peerID
                    let call = try NormalizedToolCall(id: returning ? "return-to-owner" : incoming ? "peer-channel" : "delegate",
                        name: incoming && !returning ? "SendMessage" : "SendToAgent",
                        argumentsJSON: JSONEncoder().encode(incoming && !returning ? channelArguments : [
                            "recipientID": recipient.uuidString,
                            "message": returning ? "EXACT_RETURNED_TASK" : "EXACT_SHARED_TASK"
                        ]))
                    let result = try await executeTool(call)
                    await probe.result(result)
                    continuation.yield(.textDelta(incoming ? "PRIVATE_PEER_DRAFT" : "Owner dispatched the reviewed peer task"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Actual App direct-peer channel publication", .serialized, .timeLimit(.minutes(1)))
@MainActor struct MailboxChannelPublicationAppTests {
    private let originID = UUID(uuidString: "39000000-0000-0000-0000-000000000001")!
    private let otherID = UUID(uuidString: "39000000-0000-0000-0000-000000000002")!
    private let date = Date(timeIntervalSince1970: 1_600)
    private struct Fixture {
        let root: URL
        let model: AppModel
        let channels: ChannelService
        let probe: AppMailboxChannelProbe
        let owner: AgentProfile
        let peer: AgentProfile
        let ownerConnection: ChannelConnection
        let peerConnection: ChannelConnection
        let other: Conversation
        let localSource: URL?
    }
    private func fixture(automatic: Bool, arguments: [String: String]? = nil, localFile: Bool = false,
                         returnToOwner: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-app-mailbox-channel-\(UUID())")
        let profiles = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await profiles.create(name: "Origin owner", instructions: "OWNER_PRIVATE_PERSONA",
            providerID: "app-mailbox-channel", modelID: "fixture", at: date)
        let peer = try await profiles.create(name: "Actual peer", instructions: "PEER_PRIVATE_PERSONA",
            providerID: "app-mailbox-channel", modelID: "fixture", at: date)
        var origin = Conversation(id: originID, title: "Origin", providerID: owner.providerID, modelID: owner.modelID,
            messages: [.init(role: .user, text: "OWNER_PRIVATE_HISTORY", createdAt: date)], updatedAt: date)
        origin.agentBinding = .init(accountID: "local", agentID: owner.id)
        let other = Conversation(id: otherID, title: "Unrelated", messages: [
            .init(role: .user, text: "UNRELATED_PRIVATE_HISTORY", createdAt: date)
        ], updatedAt: date)
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save([origin, other])
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json")), probe = AppMailboxChannelProbe()
        let ownerConnection = ChannelConnection(connectorID: "slack", displayName: "Owner connection must not be borrowed",
            secretReference: "keychain://channels/TEST-owner-never-read", agentID: owner.id, ownerAccountID: "local")
        let peerConnection = ChannelConnection(connectorID: "slack", displayName: "Actual peer connection",
            secretReference: "keychain://channels/TEST-peer-never-read", agentID: peer.id, ownerAccountID: "local")
        try await channels.saveConnection(ownerConnection); try await channels.saveConnection(peerConnection)
        let runtime: LocalToolRuntime?, source: URL?
        if localFile {
            let workspace = root.appending(path: "workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let file = workspace.appending(path: "peer.html")
            try Data("EXACT_CAPTURED_PEER_FILE".utf8).write(to: file)
            let grants = WorkspaceAuthorizationStore(fileURL: root.appending(path: "grants.json"))
            try await grants.authorize(workspace)
            let generation = UUID(), key = Data(repeating: 51, count: 32)
            let authenticator = LocalSessionAuthenticator(sessionKey: key)
            let helper = LocalToolProcessHost(generation: generation, requiresPermissionReceipts: true,
                authenticate: { _ in true }, verifyReceipt: { authenticator.verify($0) })
            runtime = LocalToolRuntime(workspaceStore: grants, generation: generation, sessionKey: key,
                helper: AppMailboxChannelLocalHelper(probe: probe, helper: helper))
            source = file
        } else { runtime = nil; source = nil }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false, localToolRuntime: runtime,
            channelService: channels, channelConnectors: [AppMailboxChannelConnector(probe: probe)])
        model.remoteAttachmentDownloader = AppMailboxChannelDownloader(probe: probe)
        await model.registry.register(AppMailboxChannelProvider(probe: probe, peerID: peer.id,
            channelArguments: source.map { ["type": "attachment", "channel": "slack:C_PEER", "url": $0.absoluteString, "alt": "Reviewed peer file"] }
                ?? arguments ?? ["type": "text", "channel": "slack:C_PEER", "content": "EXACT_PEER_EXTERNAL_RESULT"],
            returnToOwnerID: returnToOwner ? owner.id : nil))
        await model.bootstrap()
        await model.setAutomationRuntimeActive(false); model.setWorkflowRuntimeActive(false)
        await model.setAutoReviewEnabled(automatic)
        await model.setAutoReviewRules(allow: ["SendToAgent", "SendMessage"], ask: [])
        try await model.loadAllMessages(for: originID)
        model.selectRoute(.conversation(originID)); await model.refreshModels()
        try await eventually { !model.isLoadingModels && model.modelCatalogConversationID == originID
            && model.modelCatalogProviderID == owner.providerID && model.availableModels.contains { $0.id == owner.modelID } }
        model.draft = "Ask the peer to publish the shared result"
        return .init(root: root, model: model, channels: channels, probe: probe, owner: owner, peer: peer,
            ownerConnection: ownerConnection, peerConnection: peerConnection, other: other, localSource: source)
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("The isolated peer channel did not reach its expected boundary")
    }
    private func channelReview(_ f: Fixture, sourceDownload: Bool = false) async throws -> PendingApproval {
        for _ in 0..<1_000 {
            if let pending = f.model.pendingAutoReviewApprovals.first(where: {
                $0.action.context.metadata[sourceDownload ? "agentChannelSourceDownload" : "agentChannelPublication"] == "true"
            }) { return pending }
            if let pending = f.model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["tool"] == "SendToAgent" }) {
                await f.model.resolveGroupApproval(pending, groupID: originID, approve: true)
            }
            if !f.model.running.contains(originID) { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await f.probe.requests, results = await f.probe.results
        var diagnostic = "Missing peer review: "
        customDump((f.model.errorMessage, f.model.agentMessages,
            requests.map { ($0.conversationID, $0.messages.last?.text, $0.tools.map(\.name)) }, results), to: &diagnostic)
        Issue.record(Comment(rawValue: diagnostic))
        throw PendingApprovalError.stale("The peer must expose its own reviewed channel capability")
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "origin-ABA", "target-ABA", "origin-route-ABA",
                       "target-route-ABA", "owner-persona-ABA", "peer-persona-ABA", "connection", "navigation",
                       "owner-archive", "peer-archive", "origin-delete", "target-delete", "target-stop"], [false, true])
    func nativeReviewUsesOriginalScopeAndOnlyActualPeerChatReceivesReceipt(mode: String, automatic: Bool) async throws {
        let f = try await fixture(automatic: automatic)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        f.model.send()
        let review = try await channelReview(f)
        expectNoDifference(review.action.context.conversationID, originID)
        let details = try #require(review.action.context.metadata["agentMessage"])
        #expect(details.contains("EXACT_PEER_EXTERNAL_RESULT") && details.contains(f.peerConnection.displayName))
        #expect(!details.contains(f.ownerConnection.displayName) && !details.contains(f.peerConnection.secretReference))
        let recipient = try #require(f.model.conversations.first { $0.agentBinding?.agentID == f.peer.id })
        let recipientID = recipient.id
        #expect(recipientID != originID && recipientID != otherID)
        expectNoDifference(recipient.messages.filter { $0.agentMessageSource?.kind == .incoming }.map(\.text), ["EXACT_SHARED_TASK"])
        let before = await f.channels.deliveries(), sentBefore = await f.probe.sent
        expectNoDifference(before, []); expectNoDifference(sentBefore, [])
        let originIndex = try #require(f.model.conversations.firstIndex { $0.id == originID })
        let targetIndex = try #require(f.model.conversations.firstIndex { $0.id == recipientID })
        if mode == "stop" { f.model.cancel() }
        if mode == "account" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "owner-archive" || mode == "peer-archive" {
            await f.model.archiveAgent(id: mode == "owner-archive" ? f.owner.id : f.peer.id)
        }
        if mode == "origin-delete" { f.model.deleteConversation(id: originID) }
        if mode == "target-delete" { f.model.deleteConversation(id: recipientID) }
        if mode == "target-stop" { f.model.selectRoute(.conversation(recipientID)); f.model.cancel() }
        if mode == "origin-ABA" || mode == "target-ABA" {
            let index = mode == "origin-ABA" ? originIndex : targetIndex
            let original = f.model.conversations[index].agentBinding
            f.model.conversations[index].agentBinding = nil; f.model.conversations[index].agentBinding = original
        }
        if mode == "origin-route-ABA" || mode == "target-route-ABA" {
            let index = mode == "origin-route-ABA" ? originIndex : targetIndex
            f.model.conversations[index].modelID = "changed-route"; f.model.conversations[index].modelID = "fixture"
        }
        if mode == "owner-persona-ABA" || mode == "peer-persona-ABA" {
            let id = mode == "owner-persona-ABA" ? f.owner.id : f.peer.id
            let index = try #require(f.model.agents.firstIndex { $0.id == id })
            let original = f.model.agents[index].instructions
            f.model.agents[index].instructions = "CHANGED_PERSONA"; f.model.agents[index].instructions = original
        }
        if mode == "connection" { try await f.channels.setConnectionEnabled(id: f.peerConnection.id, enabled: false) }
        if mode == "navigation" {
            f.model.selectRoute(.conversation(otherID))
            f.model.handleTranscriptCardIntent(.approveReview(reviewID: review.id))
            let beforeReturn = await f.channels.deliveries()
            expectNoDifference(beforeReturn, [])
            f.model.selectRoute(.conversation(originID))
        }
        f.model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: review.id) : .approveReview(reviewID: review.id))
        try await eventually { !f.model.running.contains(originID) }
        let deliveries = await f.channels.deliveries(), succeeds = mode == "approve" || mode == "navigation"
        expectNoDifference(deliveries.map(\.outbound), succeeds ? [.init(text: "EXACT_PEER_EXTERNAL_RESULT")] : [])
        expectNoDifference(deliveries.compactMap { $0.authorization?.agentID }, succeeds ? [f.peer.id] : [])
        expectNoDifference(deliveries.map(\.connectionID), succeeds ? [f.peerConnection.id] : [])
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let recipientAfter = try await store.conversation(id: recipientID)
        let saved = mode == "target-delete" ? recipient : try #require(recipientAfter)
        if mode == "target-delete" { expectNoDifference(recipientAfter, nil) }
        let expected = deliveries.compactMap { ChannelTranscriptProjection.publication(for: $0) }
        expectNoDifference(saved.messages.compactMap(\.externalChannelPublication), expected)
        expectNoDifference(expected.map(\.conversationID), succeeds ? [recipientID] : [])
        expectNoDifference(expected.map(\.senderID), succeeds ? [recipientID] : [])
        expectNoDifference(expected.map(\.owner), succeeds ? [.init(accountID: "local", agentID: f.peer.id)] : [])
        let originPublications = try await store.conversation(id: originID)?.messages.compactMap(\.externalChannelPublication)
        let other = try await store.conversation(id: otherID)
        expectNoDifference(originPublications ?? [], []); expectNoDifference(other, f.other)
        #expect(!saved.messages.map(\.text).joined().contains("PRIVATE_PEER_DRAFT"))
        let peerRequest = try #require(await f.probe.requests.first { $0.messages.last?.text.hasPrefix("Incoming peer message") == true })
        #expect(!peerRequest.messages.map(\.text).joined().contains("OWNER_PRIVATE_HISTORY"))
        #expect(!peerRequest.messages.map(\.text).joined().contains("UNRELATED_PRIVATE_HISTORY"))
        let incoming = try #require(f.model.agentMessages.first { $0.recipientID == f.peer.id })
        expectNoDifference(incoming.delivery?.publications ?? [], [])
        if succeeds {
            #expect(incoming.delivery?.response?.contains("NOT a local mailbox message") == true)
            #expect(incoming.delivery?.response?.contains(recipientID.uuidString) == true)
            expectNoDifference(incoming.delivery?.state, .completed)
        }
        let sentAfter = await f.probe.sent
        expectNoDifference(sentAfter, [])
        let reopened = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let restored = try await reopened.conversation(id: recipientID)
        let recovered = try await ChannelService(storeURL: f.root.appending(path: "channels.json")).deliveries()
        // The outbox wire format stores milliseconds, not Date's full binary
        // fractional precision. Compare the entire canonical persisted value.
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970; decoder.dateDecodingStrategy = .millisecondsSince1970
        let persisted = try decoder.decode([ChannelDelivery].self, from: encoder.encode(deliveries))
        expectNoDifference(restored, mode == "target-delete" ? nil : saved); expectNoDifference(recovered, persisted)
    }

    @Test(arguments: [false, true])
    func peerReturnToOriginOwnerPublishesInOriginalCanonicalChat(automatic: Bool) async throws {
        let f = try await fixture(automatic: automatic, arguments: ["type": "text", "channel": "slack:C_OWNER",
            "content": "EXACT_OWNER_EXTERNAL_RESULT"], returnToOwner: true)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        f.model.send()
        let review = try await channelReview(f)
        expectNoDifference(review.action.context.conversationID, originID)
        let details = try #require(review.action.context.metadata["agentMessage"])
        #expect(details.contains(f.ownerConnection.displayName) && !details.contains(f.peerConnection.displayName))
        let before = await f.channels.deliveries()
        expectNoDifference(before, [])
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: review.id))
        try await eventually { !f.model.running.contains(originID) }
        let deliveries = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(deliveries.map(\.outbound), [.init(text: "EXACT_OWNER_EXTERNAL_RESULT")])
        expectNoDifference(deliveries.map(\.connectionID), [f.ownerConnection.id])
        expectNoDifference(deliveries.compactMap { $0.authorization?.agentID }, [f.owner.id])
        let expected = deliveries.compactMap { ChannelTranscriptProjection.publication(for: $0) }
        expectNoDifference(expected.map(\.conversationID), [originID]); expectNoDifference(expected.map(\.senderID), [originID])
        let stored = try #require(try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).conversation(id: originID))
        expectNoDifference(stored.messages.compactMap(\.externalChannelPublication), expected)
        expectNoDifference(f.model.conversations.filter { $0.id != originID }.flatMap(\.messages).compactMap(\.externalChannelPublication), [])
        let incoming = f.model.agentMessages
        expectNoDifference(incoming.map(\.recipientID), [f.peer.id, f.owner.id])
        #expect(incoming.allSatisfy { $0.delivery?.state == .completed && $0.delivery?.publications?.isEmpty != false })
        expectNoDifference(sent, [])
    }

    @Test(arguments: [false, true], ["approve", "deny-source", "deny-send", "stop-source", "stop-send", "persona-ABA-source"])
    func localAndHTTPSAttachmentsRetainIndependentSourceAndSendConsent(local: Bool, mode: String) async throws {
        let reference = try RemoteAttachmentReference(url: "https://source.example/peer.html?signature=exact", alt: "Reviewed peer file")
        let f = try await fixture(automatic: true, arguments: ["type": "attachment", "channel": "slack:C_PEER",
            "url": reference.url, "alt": reference.alt ?? ""], localFile: local)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        f.model.send()
        if local {
            try await eventually {
                if let delegation = f.model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["tool"] == "SendToAgent" }) {
                    await f.model.resolveGroupApproval(delegation, groupID: originID, approve: true)
                }
                return !f.model.pendingToolApprovals.isEmpty
            }
            let read = try #require(f.model.pendingToolApprovals.first)
            expectNoDifference(read.conversationID, originID)
            let before = await f.probe.reads
            expectNoDifference(before, [])
            if mode == "stop-source" { f.model.cancel() }
            if mode == "persona-ABA-source" {
                var changed = f.peer; changed.instructions = "UNREVIEWED_PERSONA"
                #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(f.peer))
            }
            f.model.resolveLocalToolApproval(id: read.id, allowed: mode != "deny-source")
        } else {
            let source = try await channelReview(f, sourceDownload: true)
            expectNoDifference(source.action.context.conversationID, originID)
            let before = await f.probe.downloads
            expectNoDifference(before, [])
            if mode == "stop-source" { f.model.cancel() }
            if mode == "persona-ABA-source" {
                var changed = f.peer; changed.instructions = "UNREVIEWED_PERSONA"
                #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(f.peer))
            }
            f.model.handleTranscriptCardIntent(mode == "deny-source" ? .rejectReview(reviewID: source.id) : .approveReview(reviewID: source.id))
        }
        if !["deny-source", "stop-source", "persona-ABA-source"].contains(mode) {
            let send = try await channelReview(f)
            expectNoDifference(send.action.context.conversationID, originID)
            let before = await f.channels.deliveries()
            expectNoDifference(before, [])
            if let source = f.localSource { try Data("UNREVIEWED_REPLACEMENT".utf8).write(to: source) }
            await f.probe.replaceBytes()
            if mode == "stop-send" { f.model.cancel() }
            f.model.handleTranscriptCardIntent(mode == "deny-send" ? .rejectReview(reviewID: send.id) : .approveReview(reviewID: send.id))
        }
        try await eventually { !f.model.running.contains(originID) }
        let bytes = Data("EXACT_CAPTURED_PEER_FILE".utf8)
        let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "peer.html")
        let attachment = ChannelAttachment(blobID: prepared.digest, filename: prepared.filename,
            mimeType: "application/octet-stream", byteCount: Int64(bytes.count))
        let queue = await f.channels.deliveries(), downloads = await f.probe.downloads, reads = await f.probe.reads
        let succeeds = mode == "approve", acquired = !["deny-source", "stop-source", "persona-ABA-source"].contains(mode)
        expectNoDifference(queue.map(\.outbound), succeeds ? [.init(text: "Reviewed peer file", attachments: [attachment])] : [])
        expectNoDifference(downloads, !local && acquired ? [reference] : [])
        expectNoDifference(reads.count, local && acquired ? 1 : 0)
        if let source = f.localSource {
            expectNoDifference(reads.map(\.operation), acquired ? [.readFile(root: source.deletingLastPathComponent().path,
                relativePath: source.lastPathComponent)] : [])
        }
        expectNoDifference(reads.map(\.scope.agentID), local && acquired ? [f.peer.id] : [])
        let publications = f.model.conversations.flatMap(\.messages).compactMap(\.externalChannelPublication)
        expectNoDifference(publications, queue.compactMap { ChannelTranscriptProjection.publication(for: $0) })
        if succeeds {
            let metadata = AttachmentMetadata(id: prepared.digest, filename: prepared.filename,
                mimeType: attachment.mimeType, byteCount: attachment.byteCount, kind: .document)
            let stored = try await AttachmentStore(rootURL: f.root.appending(path: "channel-attachments")).data(for: metadata)
            expectNoDifference(stored, bytes)
            let actual = try #require(publications.first)
            expectNoDifference(actual.sources, [.init(url: local ? try #require(f.localSource).absoluteString : reference.url, alt: "Reviewed peer file")])
            expectNoDifference(actual.owner, .init(accountID: "local", agentID: f.peer.id))
            #expect(actual.conversationID != originID)
        } else { #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "channel-attachments").path)) }
        let sent = await f.probe.sent
        expectNoDifference(sent, [])
    }
}
