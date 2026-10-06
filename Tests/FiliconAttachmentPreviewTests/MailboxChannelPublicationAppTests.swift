import Foundation
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
import FiliconAutoReview
@testable import FiliconChannels
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
    var failureAttempts = 0
    var latePeerAttempts = 0
    private var latePeerGateClaimed = false
    var protocolRejections: [ToolLoopError] = []
    var bytes = Data("EXACT_CAPTURED_PEER_FILE".utf8)
    func request(_ value: InferenceRequest) { requests.append(value) }
    func result(_ value: NormalizedToolResult) { results.append(value) }
    func send(_ value: ChannelOutbound) { sent.append(value) }
    func read(_ value: LocalToolWireRequest) { reads.append(value) }
    func attemptedFailurePublication() { failureAttempts += 1 }
    func attemptedLatePeerPublication() { latePeerAttempts += 1 }
    func claimLatePeerGate() -> Bool {
        guard !latePeerGateClaimed else { return false }
        latePeerGateClaimed = true
        return true
    }
    func rejected(_ value: ToolLoopError) { protocolRejections.append(value) }
    func replaceBytes() { bytes = Data("UNREVIEWED_REPLACEMENT".utf8) }
    func download(_ reference: RemoteAttachmentReference) -> RemoteAttachmentDownload {
        downloads.append(reference)
        return .init(reference: reference, data: bytes, declaredMIMEType: "text/plain")
    }
}

private actor AppMailboxChannelFailureGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isWaiting: Bool { !waiters.isEmpty }
    func wait() async {
        if !opened { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        opened = true
        let values = waiters; waiters.removeAll()
        for value in values { value.resume() }
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
    var fails = false
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.send(message)
        if fails { throw ChannelServiceError.authExpired("PRIVATE_PEER_CONNECTOR_TOKEN") }
    }
}

private struct AppMailboxChannelProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "app-mailbox-channel", displayName: "Offline peer inference", requiresAPIKey: false)
    let probe: AppMailboxChannelProbe
    let peerID: UUID
    let channelArguments: [String: String]
    var returnToOwnerID: UUID? = nil
    var failureGate: AppMailboxChannelFailureGate? = nil
    var triesExternalFailureRetry = false
    var queuesSibling = false
    var latePeerGate: AppMailboxChannelFailureGate? = nil
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
                    if request.messages.contains(where: { $0.role == .system && $0.text == ChannelFailureFollowUpNotice.instructions }) {
                        // Deliberately permit a late callback after Stop. The
                        // actual shared host must fence it, not this provider.
                        await failureGate?.wait()
                        await probe.attemptedFailurePublication()
                        var arguments = ["type": "text", "content": "The reviewed peer channel message was not delivered; a new send needs a new human request and approval."]
                        if triesExternalFailureRetry { arguments["channel"] = "slack:C_PEER" }
                        let result = try await executeTool(.init(id: "peer-failure-correction", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(arguments)))
                        await probe.result(result)
                        continuation.yield(.textDelta("PRIVATE_FAILURE_DRAFT"))
                        continuation.yield(.completed(.stop)); continuation.finish()
                        return
                    }
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
                    if incoming && !returning, let latePeerGate, await probe.claimLatePeerGate() {
                        // The provider deliberately ignores cancellation after
                        // the reviewed call unwinds and tries a late callback.
                        do { await probe.result(try await executeTool(call)) }
                        catch { if let error = error as? ToolLoopError { await probe.rejected(error) } }
                        await latePeerGate.wait()
                        await probe.attemptedLatePeerPublication()
                        do {
                            await probe.result(try await executeTool(.init(id: "late-peer-channel", name: "SendMessage",
                                argumentsJSON: JSONEncoder().encode(channelArguments))))
                        } catch { if let error = error as? ToolLoopError { await probe.rejected(error) } }
                    } else { await probe.result(try await executeTool(call)) }
                    if !incoming && queuesSibling {
                        await probe.result(try await executeTool(.init(id: "queued-sibling", name: "SendToAgent",
                            argumentsJSON: JSONEncoder().encode(["recipientID": peerID.uuidString,
                                "message": "EXACT_QUEUED_SIBLING_TASK"]))))
                    }
                    continuation.yield(.textDelta(incoming ? "PRIVATE_PEER_DRAFT" : "Owner dispatched the reviewed peer task"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch {
                    if let error = error as? ToolLoopError { await probe.rejected(error) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Actual App direct/group-origin peer channel publication", .serialized, .timeLimit(.minutes(1)))
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
        let group: AgentGroup?
        let existingPeer: Conversation?
    }
    private func fixture(automatic: Bool, arguments: [String: String]? = nil, localFile: Bool = false,
                         returnToOwner: Bool = false, failsDelivery: Bool = false,
                         failureGate: AppMailboxChannelFailureGate? = nil, triesExternalFailureRetry: Bool = false,
                         groupOrigin: Bool = false, queuesSibling: Bool = false,
                         latePeerGate: AppMailboxChannelFailureGate? = nil,
                         manual: Bool = false, existingPeer: Bool = false) async throws -> Fixture {
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
        var peerChat = Conversation(id: UUID(uuidString: "39000000-0000-0000-0000-000000000003")!, title: "Existing peer chat",
            providerID: peer.providerID, modelID: peer.modelID,
            messages: [.init(role: .user, text: "EXISTING_PEER_PRIVATE_HISTORY", createdAt: date)], updatedAt: date)
        peerChat.agentBinding = .init(accountID: "local", agentID: peer.id)
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save(
            ((groupOrigin || manual) ? [other] : [origin, other]) + (existingPeer ? [peerChat] : []))
        let group: AgentGroup?
        if groupOrigin {
            let groups = try GroupService(agents: profiles, storeURL: root.appending(path: "groups.json"))
            group = try await groups.create(name: "Actual source group", summary: "SOURCE_GROUP_PRIVATE", memberIDs: [owner.id])
        } else { group = nil }
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
            channelService: channels, channelConnectors: [AppMailboxChannelConnector(probe: probe, fails: failsDelivery)])
        model.remoteAttachmentDownloader = AppMailboxChannelDownloader(probe: probe)
        await model.registry.register(AppMailboxChannelProvider(probe: probe, peerID: peer.id,
            channelArguments: source.map { ["type": "attachment", "channel": "slack:C_PEER", "url": $0.absoluteString, "alt": "Reviewed peer file"] }
                ?? arguments ?? ["type": "text", "channel": "slack:C_PEER", "content": "EXACT_PEER_EXTERNAL_RESULT"],
            returnToOwnerID: returnToOwner ? owner.id : nil, failureGate: failureGate,
            triesExternalFailureRetry: triesExternalFailureRetry, queuesSibling: queuesSibling, latePeerGate: latePeerGate))
        await model.bootstrap()
        await model.setAutomationRuntimeActive(false); model.setWorkflowRuntimeActive(false)
        await model.setAutoReviewEnabled(automatic)
        await model.setAutoReviewRules(allow: ["SendToAgent", "SendMessage"], ask: [])
        if manual { model.selectRoute(.conversation(otherID)) }
        else if let group { model.selectGroup(id: group.id) }
        else {
            try await model.loadAllMessages(for: originID)
            model.selectRoute(.conversation(originID)); await model.refreshModels()
            try await eventually { !model.isLoadingModels && model.modelCatalogConversationID == originID
                && model.modelCatalogProviderID == owner.providerID && model.availableModels.contains { $0.id == owner.modelID } }
        }
        model.draft = "Ask the peer to publish the shared result"
        return .init(root: root, model: model, channels: channels, probe: probe, owner: owner, peer: peer,
            ownerConnection: ownerConnection, peerConnection: peerConnection, other: other, localSource: source, group: group,
            existingPeer: existingPeer ? peerChat : nil)
    }
    private func eventually(_ message: String = "The isolated peer channel did not reach its expected boundary", _ condition: () async -> Bool) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale(message)
    }
    private func channelReview(_ f: Fixture, sourceDownload: Bool = false) async throws -> PendingApproval {
        let origin = f.group?.id ?? originID
        for _ in 0..<1_000 {
            if let pending = f.model.pendingAutoReviewApprovals.first(where: {
                $0.action.context.metadata[sourceDownload ? "agentChannelSourceDownload" : "agentChannelPublication"] == "true"
            }) { return pending }
            if let pending = f.model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["tool"] == "SendToAgent" }) {
                await f.model.resolveGroupApproval(pending, groupID: origin, approve: true)
            }
            if !f.model.running.contains(origin) && !f.model.runningGroups.contains(origin)
                && f.model.runningAgentMessageScopes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let requests = await f.probe.requests, results = await f.probe.results
        var diagnostic = "Missing peer review: "
        customDump((f.model.errorMessage, f.model.agentMessages,
            requests.map { ($0.conversationID, $0.messages.last?.text, $0.tools.map(\.name)) }, results), to: &diagnostic)
        Issue.record(Comment(rawValue: diagnostic))
        throw PendingApprovalError.stale("The peer must expose its own reviewed channel capability")
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "sender-persona-ABA", "peer-persona-ABA",
                      "target-ABA", "target-hidden-ABA", "target-delete", "target-stop", "connection", "navigation"], [false, true])
    func manualMailboxPublishesToItsActualRecipientWithoutBorrowingPrivateHistory(mode: String, existing: Bool) async throws {
        let f = try await fixture(automatic: true, manual: true, existingPeer: existing)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        #expect(await f.model.sendAgentMessage(senderID: f.owner.id, recipientID: f.peer.id, text: "EXACT_MANUAL_TASK"))
        let review = try await channelReview(f)
        let sourceID = review.action.context.conversationID
        #expect(sourceID != originID && sourceID != otherID)
        let peer = try #require(f.model.conversations.first { $0.agentBinding?.agentID == f.peer.id })
        if let existingPeer = f.existingPeer { expectNoDifference(peer.id, existingPeer.id) }
        expectNoDifference(peer.messages.map(\.text), (existing ? ["EXISTING_PEER_PRIVATE_HISTORY"] : []) + ["EXACT_MANUAL_TASK"])
        let before = await f.channels.deliveries(), sentBefore = await f.probe.sent
        expectNoDifference(before, []); expectNoDifference(sentBefore, [])
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        var expected = try #require(try await store.conversation(id: peer.id))
        let incoming = try #require(f.model.agentMessages.first { $0.recipientID == f.peer.id })
        let source = try AgentMessageSource(accountID: "local", originConversationID: sourceID,
            deliveryID: incoming.id, senderAgentID: f.owner.id, recipientAgentID: f.peer.id, kind: .incoming)
        var initial = f.existingPeer ?? Conversation(id: peer.id, title: f.peer.name,
            providerID: f.peer.providerID, modelID: f.peer.modelID, updatedAt: incoming.createdAt)
        initial.agentBinding = .init(accountID: "local", agentID: f.peer.id)
        initial.messages.append(.init(id: incoming.id, role: .assistant, text: "EXACT_MANUAL_TASK",
            createdAt: incoming.createdAt, agentMessageSource: source))
        initial.updatedAt = max(initial.updatedAt, incoming.createdAt)
        DirectMessageAddressing.assignMissing(in: &initial)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970; decoder.dateDecodingStrategy = .secondsSince1970
        func persisted(_ value: Conversation?) throws -> Conversation? {
            guard let value else { return nil }
            return try decoder.decode(Conversation.self, from: encoder.encode(value))
        }
        expectNoDifference(try persisted(expected), try persisted(initial))
        #expect(f.model.isConversationWorking(peer.id))
        let index = try #require(f.model.conversations.firstIndex { $0.id == peer.id })
        if mode == "stop" { await f.model.stopAgentMessages(scopeID: sourceID) }
        if mode == "account" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "sender-persona-ABA" || mode == "peer-persona-ABA" {
            let id = mode == "sender-persona-ABA" ? f.owner.id : f.peer.id
            let agentIndex = try #require(f.model.agents.firstIndex { $0.id == id })
            let instructions = f.model.agents[agentIndex].instructions
            f.model.agents[agentIndex].instructions = "CHANGED_MANUAL_PERSONA"
            f.model.agents[agentIndex].instructions = instructions
        }
        if mode == "target-ABA" {
            let binding = f.model.conversations[index].agentBinding
            f.model.conversations[index].agentBinding = nil
            f.model.conversations[index].agentBinding = binding
        }
        if mode == "target-hidden-ABA" {
            f.model.conversations[index].hiddenAt = date
            f.model.conversations[index].hiddenAt = nil
        }
        if mode == "target-delete" { f.model.deleteConversation(id: peer.id) }
        if mode == "target-stop" { f.model.selectRoute(.conversation(peer.id)); f.model.cancel() }
        if mode == "connection" { try await f.channels.setConnectionEnabled(id: f.peerConnection.id, enabled: false) }
        if mode == "navigation" { f.model.selectRoute(.conversation(otherID)) }
        await f.model.resolveGroupApproval(review, groupID: sourceID, approve: mode != "deny")
        try await eventually { f.model.runningAgentMessageScopes.isEmpty }
        let queue = await f.channels.deliveries()
        let succeeds = mode == "approve" || mode == "navigation"
        expectNoDifference(queue.map(\.connectionID), succeeds ? [f.peerConnection.id] : [])
        expectNoDifference(queue.map(\.outbound), succeeds ? [.init(text: "EXACT_PEER_EXTERNAL_RESULT")] : [])
        let publications = queue.compactMap { ChannelTranscriptProjection.publication(for: $0) }
        expectNoDifference(publications.map(\.conversationID), succeeds ? [peer.id] : [])
        expectNoDifference(publications.map(\.senderID), succeeds ? [peer.id] : [])
        expectNoDifference(publications.map(\.owner), succeeds ? [.init(accountID: "local", agentID: f.peer.id)] : [])
        for publication in publications {
            expected.messages.append(publication.directMessage)
            expected.updatedAt = max(expected.updatedAt, publication.queuedAt)
        }
        DirectMessageAddressing.assignMissing(in: &expected)
        let stored = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
        expectNoDifference(try persisted(stored.first { $0.id == peer.id }), mode == "target-delete" ? nil : try persisted(expected))
        expectNoDifference(stored.first { $0.id == otherID }, f.other)
        expectNoDifference(stored.filter { $0.agentBinding?.agentID == f.peer.id }.count, mode == "target-delete" ? 0 : 1)
        expectNoDifference(stored.first { $0.id == sourceID }, nil)
        let requests = await f.probe.requests
        let request = try #require(requests.first { $0.messages.last?.text.hasPrefix("Incoming peer message") == true })
        #expect(!request.messages.contains { $0.text.contains("EXISTING_PEER_PRIVATE_HISTORY") || $0.text.contains("UNRELATED_PRIVATE_HISTORY") })
        let sent = await f.probe.sent
        expectNoDifference(sent, [])
        let reopened = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
        expectNoDifference(reopened, stored)
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "membership-ABA", "actual-membership-ABA",
                      "group-summary-ABA", "owner-persona-ABA", "peer-persona-ABA", "target-ABA",
                      "target-hidden-ABA", "target-delete", "target-stop", "connection", "navigation"], [false, true])
    func groupOriginPeerRequiresNewReviewAndSavesOnlyItsOwnCanonicalPublication(mode: String, automatic: Bool) async throws {
        let f = try await fixture(automatic: automatic, groupOrigin: true)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        let group = try #require(f.group)
        let work = Task { await f.model.sendGroupMessage(groupID: group.id, text: "GROUP_HUMAN_PRIVATE: delegate the shared task") }
        defer { work.cancel() }
        try await eventually { f.model.runningGroups.contains(group.id) }
        let review = try await channelReview(f)
        expectNoDifference(review.action.context.conversationID, group.id)
        let details = try #require(review.action.context.metadata["agentMessage"])
        #expect(details.contains(f.peerConnection.displayName) && !details.contains(f.ownerConnection.displayName))
        let peer = try #require(f.model.conversations.first { $0.agentBinding?.agentID == f.peer.id })
        expectNoDifference(peer.messages.map(\.text), ["EXACT_SHARED_TASK"])
        let before = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(before, []); expectNoDifference(sent, [])
        let groupIndex = try #require(f.model.groups.firstIndex { $0.id == group.id })
        let peerIndex = try #require(f.model.conversations.firstIndex { $0.id == peer.id })
        if mode == "stop" { await f.model.stopGroup(id: group.id) }
        if mode == "account" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "membership-ABA" {
            f.model.groups[groupIndex].memberIDs = [f.owner.id, f.peer.id]
            f.model.groups[groupIndex].memberIDs = group.memberIDs
        }
        if mode == "actual-membership-ABA" {
            await f.model.updateGroupMembers(groupID: group.id, memberIDs: [f.owner.id, f.peer.id])
            await f.model.updateGroupMembers(groupID: group.id, memberIDs: group.memberIDs)
        }
        if mode == "group-summary-ABA" {
            f.model.groups[groupIndex].summary = "CHANGED_GROUP_SCOPE"
            f.model.groups[groupIndex].summary = group.summary
        }
        if mode == "owner-persona-ABA" || mode == "peer-persona-ABA" {
            let id = mode == "owner-persona-ABA" ? f.owner.id : f.peer.id
            let index = try #require(f.model.agents.firstIndex { $0.id == id })
            let instructions = f.model.agents[index].instructions
            f.model.agents[index].instructions = "CHANGED_PERSONA"
            f.model.agents[index].instructions = instructions
        }
        if mode == "target-ABA" {
            let binding = f.model.conversations[peerIndex].agentBinding
            f.model.conversations[peerIndex].agentBinding = nil
            f.model.conversations[peerIndex].agentBinding = binding
        }
        if mode == "target-hidden-ABA" {
            f.model.conversations[peerIndex].hiddenAt = date
            f.model.conversations[peerIndex].hiddenAt = nil
        }
        if mode == "target-delete" { f.model.deleteConversation(id: peer.id) }
        if mode == "target-stop" { f.model.selectRoute(.conversation(peer.id)); f.model.cancel() }
        if mode == "connection" { try await f.channels.setConnectionEnabled(id: f.peerConnection.id, enabled: false) }
        if mode == "navigation" { f.model.selectRoute(.conversation(otherID)) }
        await f.model.resolveGroupApproval(review, groupID: group.id, approve: mode != "deny")
        await work.value
        let deliveries = await f.channels.deliveries()
        let succeeds = mode == "approve" || mode == "navigation"
        expectNoDifference(deliveries.map(\.outbound), succeeds ? [.init(text: "EXACT_PEER_EXTERNAL_RESULT")] : [])
        expectNoDifference(deliveries.map(\.connectionID), succeeds ? [f.peerConnection.id] : [])
        let expected = deliveries.compactMap { ChannelTranscriptProjection.publication(for: $0) }
        expectNoDifference(expected.map(\.owner), succeeds ? [.init(accountID: "local", agentID: f.peer.id)] : [])
        expectNoDifference(expected.map(\.conversationID), succeeds ? [peer.id] : [])
        expectNoDifference(expected.map(\.senderID), succeeds ? [peer.id] : [])
        let stored = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
        let restoredPeer = stored.first { $0.id == peer.id }
        if mode == "target-delete" { expectNoDifference(restoredPeer, nil) }
        else {
            let saved = try #require(restoredPeer)
            expectNoDifference(saved.messages.compactMap(\.externalChannelPublication), expected)
        }
        expectNoDifference(stored.first { $0.id == otherID }, f.other)
        expectNoDifference(stored.filter { $0.id != peer.id }.flatMap(\.messages).compactMap(\.externalChannelPublication), [])
        expectNoDifference(f.model.groupMessages[group.id]?.compactMap(\.externalPublication) ?? [], [])
        let requests = await f.probe.requests
        let request = try #require(requests.first { $0.messages.last?.text.hasPrefix("Incoming peer message") == true })
        #expect(!request.messages.contains { $0.text.contains("GROUP_HUMAN_PRIVATE") || $0.text.contains("SOURCE_GROUP_PRIVATE") || $0.text.contains("UNRELATED_PRIVATE_HISTORY") })
        let incoming = try #require(f.model.agentMessages.first { $0.recipientID == f.peer.id })
        if succeeds { expectNoDifference(incoming.delivery?.state, .completed) }
        expectNoDifference(incoming.delivery?.publications ?? [], [])
        if succeeds { #expect(incoming.delivery?.response?.contains(peer.id.uuidString) == true) }
        let sentAfter = await f.probe.sent
        expectNoDifference(sentAfter, [])
        let reloaded = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
        expectNoDifference(reloaded, stored)
    }

    @Test(arguments: ["approve", "target-stop"])
    func groupThenManualUsesTheSameCanonicalChatButDifferentPrivateContext(mode: String) async throws {
        let f = try await fixture(automatic: true, groupOrigin: true)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        let first = try await reviewedPeerDelivery(f)
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let destinationID = try #require(first.origin?.conversationID)
        let original = try #require(try await store.conversation(id: destinationID))
        let requestsBefore = await f.probe.requests
        let oldRequest = try #require(requestsBefore.first { $0.messages.last?.text.hasPrefix("Incoming peer message") == true })
        let oldMessages = f.model.agentMessages
        #expect(await f.model.sendAgentMessage(senderID: f.owner.id, recipientID: f.peer.id, text: "EXACT_MANUAL_TASK"))
        let review = try await channelReview(f)
        let sourceID = review.action.context.conversationID
        #expect(sourceID != f.group?.id && sourceID != destinationID)
        let incoming = try #require(f.model.agentMessages.first { candidate in
            candidate.recipientID == f.peer.id && !oldMessages.contains { $0.id == candidate.id }
        })
        let source = try AgentMessageSource(accountID: "local", originConversationID: sourceID,
            deliveryID: incoming.id, senderAgentID: f.owner.id, recipientAgentID: f.peer.id, kind: .incoming)
        var expected = original
        expected.messages.append(.init(id: incoming.id, role: .assistant, text: "EXACT_MANUAL_TASK",
            createdAt: incoming.createdAt, agentMessageSource: source))
        expected.updatedAt = max(expected.updatedAt, incoming.createdAt)
        DirectMessageAddressing.assignMissing(in: &expected)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970; decoder.dateDecodingStrategy = .secondsSince1970
        func persisted(_ value: Conversation?) throws -> Conversation? {
            guard let value else { return nil }
            return try decoder.decode(Conversation.self, from: encoder.encode(value))
        }
        let pending = try await store.conversation(id: original.id)
        expectNoDifference(try persisted(pending), try persisted(expected))
        #expect(f.model.isConversationWorking(original.id))
        if mode == "target-stop" { f.model.selectRoute(.conversation(original.id)); f.model.cancel() }
        await f.model.resolveGroupApproval(review, groupID: sourceID, approve: true)
        try await eventually { f.model.runningAgentMessageScopes.isEmpty }
        let queue = await f.channels.deliveries()
        expectNoDifference(queue.filter { $0.id == first.id }, [first])
        let second = queue.filter { $0.id != first.id }
        expectNoDifference(second.map(\.outbound), mode == "approve" ? [.init(text: "EXACT_PEER_EXTERNAL_RESULT")] : [])
        if let publication = second.first.flatMap({ ChannelTranscriptProjection.publication(for: $0) }) {
            expectNoDifference(publication.owner, .init(accountID: "local", agentID: f.peer.id))
            expectNoDifference(publication.conversationID, original.id)
            expected.messages.append(publication.directMessage)
            expected.updatedAt = max(expected.updatedAt, publication.queuedAt)
            DirectMessageAddressing.assignMissing(in: &expected)
        }
        let stored = try await store.load()
        expectNoDifference(try persisted(stored.first { $0.id == original.id }), try persisted(expected))
        expectNoDifference(stored.filter { $0.agentBinding?.agentID == f.peer.id }.count, 1)
        expectNoDifference(stored.first { $0.id == otherID }, f.other)
        let requests = await f.probe.requests
        let current = try #require(requests.last { $0.messages.last?.text.hasPrefix("Incoming peer message") == true })
        #expect(current.conversationID != oldRequest.conversationID && current.conversationID != original.id)
        #expect(!current.messages.contains { $0.text.contains("EXACT_SHARED_TASK") || $0.text.contains("GROUP_HUMAN_PRIVATE")
            || $0.text.contains("SOURCE_GROUP_PRIVATE") || $0.text.contains("UNRELATED_PRIVATE_HISTORY") || $0.text.contains("PRIVATE_PEER_DRAFT") })
        let reopened = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
        expectNoDifference(reopened, stored)
    }

    @Test(arguments: ["origin", "target"], [false, true])
    func manualStopFencesOldCallbacksAfterFreshSameScopeWake(stopAt: String, existing: Bool) async throws {
        let gate = AppMailboxChannelFailureGate()
        defer { Task { await gate.open() } }
        let f = try await fixture(automatic: true, latePeerGate: gate, manual: true, existingPeer: existing)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        #expect(await f.model.sendAgentMessage(senderID: f.owner.id, recipientID: f.peer.id, text: "EXACT_MANUAL_TASK"))
        let review = try await channelReview(f), sourceID = review.action.context.conversationID
        let peer = try #require(f.model.conversations.first { $0.agentBinding?.agentID == f.peer.id })
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let before = try await store.load(), oldMessages = f.model.agentMessages
        if stopAt == "origin" { await f.model.stopAgentMessages(scopeID: sourceID) }
        else { f.model.selectRoute(.conversation(peer.id)); f.model.cancel() }
        try await eventually("The cancelled provider must reach its deliberate late-callback gate") { await gate.isWaiting }
        if f.model.runningAgentMessageScopes.contains(sourceID) {
            // Origin Stop may still be unwinding the cancelled stream. Only
            // then wait for cleanup; an awaited send could legally start a
            // fresh chain if cleanup finished during its profile lookups.
            await gate.open()
            try await eventually("The cancelled original mailbox must finish unwinding") { f.model.runningAgentMessageScopes.isEmpty }
        }
        #expect(await f.model.sendAgentMessage(senderID: f.owner.id, recipientID: f.peer.id, text: "FRESH_SAME_SCOPE_TASK"))
        let freshReview = try await channelReview(f)
        expectNoDifference(freshReview.action.context.conversationID, sourceID)
        #expect(freshReview.id != review.id)
        let fresh = try #require(f.model.agentMessages.first { $0.text == "FRESH_SAME_SCOPE_TASK" })
        #expect(fresh.delivery?.chainID != oldMessages.first?.delivery?.chainID)
        let pendingStore = try await store.load()
        await f.model.resolveGroupApproval(review, groupID: sourceID, approve: true)
        await gate.open()
        try await eventually("Exactly one original late callback must be rejected before the fresh review") { await f.probe.latePeerAttempts == 1 }
        #expect(f.model.runningAgentMessageScopes.contains(sourceID))
        #expect(f.model.pendingAutoReviewApprovals.contains { $0.id == freshReview.id })
        let afterOldCallback = try await store.load(), queuedAfterOld = await f.channels.deliveries()
        expectNoDifference(afterOldCallback, pendingStore); expectNoDifference(queuedAfterOld, [])
        let old = try #require(f.model.agentMessages.first { $0.id == oldMessages.first?.id })
        expectNoDifference(old.delivery?.state, .cancelled)
        await f.model.resolveGroupApproval(freshReview, groupID: sourceID, approve: false)
        try await eventually("The denied fresh mailbox must unwind without resurrecting the old review") {
            f.model.runningAgentMessageScopes.isEmpty && f.model.pendingAutoReviewApprovals.isEmpty
        }
        await f.model.resolveGroupApproval(review, groupID: sourceID, approve: true)
        let queue = await f.channels.deliveries(), sent = await f.probe.sent, attempts = await f.probe.latePeerAttempts
        expectNoDifference(queue, []); expectNoDifference(sent, []); expectNoDifference(attempts, 1)
        let saved = try await store.load()
        expectNoDifference(saved, pendingStore)
        expectNoDifference(saved.first { $0.id == otherID }, before.first { $0.id == otherID })
        let originalPeer = try #require(before.first { $0.id == peer.id })
        expectNoDifference(saved.first { $0.id == peer.id }?.messages.prefix(originalPeer.messages.count).map { $0 }, originalPeer.messages)
        expectNoDifference(f.model.agentMessages.map(\.id), oldMessages.map(\.id) + [fresh.id])
        let reopened = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
        expectNoDifference(reopened, saved)
    }

    @Test(arguments: ["approve", "target-stop"], [false, true])
    func repeatedGroupPeerWakeKeepsExistingChatAndOwnsCurrentStop(mode: String, automatic: Bool) async throws {
        let f = try await fixture(automatic: automatic, groupOrigin: true)
        let group = try #require(f.group)
        defer {
            f.model.selectGroup(id: group.id); f.model.cancel()
            try? FileManager.default.removeItem(at: f.root)
        }
        let first = try await reviewedPeerDelivery(f)
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let destinationID = try #require(first.origin?.conversationID)
        let original = try #require(try await store.conversation(id: destinationID))
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970; decoder.dateDecodingStrategy = .secondsSince1970
        // Canonical SQL dates round-trip epoch seconds. Compare every field in
        // that wire form rather than Date's extra in-memory fractional bits.
        func persisted(_ value: Conversation?) throws -> Conversation? {
            guard let value else { return nil }
            return try decoder.decode(Conversation.self, from: encoder.encode(value))
        }
        let firstMessages = f.model.agentMessages
        let groupMessages = f.model.groupMessages[group.id] ?? []
        let work = Task { await f.model.sendGroupMessage(groupID: group.id, text: "SECOND_GROUP_HUMAN_PRIVATE: delegate again") }
        defer { work.cancel() }
        try await eventually { f.model.runningGroups.contains(group.id) }
        let review = try await channelReview(f)
        let incoming = try #require(f.model.agentMessages.first { candidate in
            candidate.recipientID == f.peer.id && !firstMessages.contains { $0.id == candidate.id }
        })
        let source = try AgentMessageSource(accountID: "local", originConversationID: group.id,
            deliveryID: incoming.id, senderAgentID: f.owner.id, recipientAgentID: f.peer.id, kind: .incoming)
        var expected = original
        let position = expected.messages.firstIndex { $0.createdAt > incoming.createdAt } ?? expected.messages.endIndex
        expected.messages.insert(.init(id: incoming.id, role: .assistant, text: "EXACT_SHARED_TASK",
            createdAt: incoming.createdAt, agentMessageSource: source), at: position)
        expected.updatedAt = max(expected.updatedAt, incoming.createdAt)
        DirectMessageAddressing.assignMissing(in: &expected)
        let beforeApproval = try await store.conversation(id: original.id)
        expectNoDifference(try persisted(beforeApproval), try persisted(expected))
        expectNoDifference(try persisted(f.model.conversations.first { $0.id == original.id }), try persisted(expected))
        #expect(f.model.isConversationWorking(original.id))
        let queuedBeforeApproval = await f.channels.deliveries()
        expectNoDifference(queuedBeforeApproval, [first])
        if mode == "target-stop" {
            f.model.selectRoute(.conversation(original.id)); f.model.cancel()
            try await eventually { !f.model.runningGroups.contains(group.id) }
        }
        await f.model.resolveGroupApproval(review, groupID: group.id, approve: true)
        await work.value
        let deliveries = await f.channels.deliveries()
        expectNoDifference(deliveries.filter { $0.id == first.id }, [first])
        let second = deliveries.filter { $0.id != first.id }
        expectNoDifference(second.map(\.outbound), mode == "approve" ? [.init(text: "EXACT_PEER_EXTERNAL_RESULT")] : [])
        if mode == "approve" {
            let publication = try #require(second.first.flatMap { ChannelTranscriptProjection.publication(for: $0) })
            expectNoDifference(publication.owner, .init(accountID: "local", agentID: f.peer.id))
            expectNoDifference(publication.conversationID, original.id)
            expectNoDifference(publication.senderID, original.id)
            expected.messages.append(publication.directMessage)
            expected.updatedAt = max(expected.updatedAt, publication.queuedAt)
            DirectMessageAddressing.assignMissing(in: &expected)
        }
        let saved = try await store.conversation(id: original.id)
        expectNoDifference(try persisted(saved), try persisted(expected))
        let reopened = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).conversation(id: original.id)
        expectNoDifference(try persisted(reopened), try persisted(expected))
        expectNoDifference(f.model.groupMessages[group.id]?.prefix(groupMessages.count).map { $0 } ?? [], groupMessages)
        let unrelated = try await store.conversation(id: otherID)
        expectNoDifference(unrelated, f.other)
        #expect(!f.model.isConversationWorking(original.id))
        let requests = await f.probe.requests.filter { $0.messages.last?.text.hasPrefix("Incoming peer message") == true }
        #expect(requests.count == 2)
        let lastRequest = try #require(requests.last)
        #expect(!lastRequest.messages.contains { $0.text.contains("SECOND_GROUP_HUMAN_PRIVATE")
            || $0.text.contains("SOURCE_GROUP_PRIVATE") || $0.text.contains("UNRELATED_PRIVATE_HISTORY") })
        let sent = await f.probe.sent
        expectNoDifference(sent, [])
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

    private func reviewedPeerDelivery(_ f: Fixture) async throws -> ChannelDelivery {
        let work: Task<Void, Never>?
        if let group = f.group {
            work = Task { await f.model.sendGroupMessage(groupID: group.id, text: "GROUP_HUMAN_PRIVATE: delegate the shared task") }
            try await eventually { f.model.runningGroups.contains(group.id) }
        } else { work = nil; f.model.send() }
        defer { work?.cancel() }
        let review = try await channelReview(f)
        if let group = f.group { await f.model.resolveGroupApproval(review, groupID: group.id, approve: true) }
        else { f.model.handleTranscriptCardIntent(.approveReview(reviewID: review.id)) }
        if let work { await work.value }
        else { try await eventually { !f.model.running.contains(originID) } }
        return try #require(await f.channels.deliveries().first)
    }

    private func failureRequests(_ f: Fixture) async -> [InferenceRequest] {
        await f.probe.requests.filter { request in
            request.messages.contains { $0.role == .system && $0.text == ChannelFailureFollowUpNotice.instructions }
        }
    }

    private func failAndReconcile(_ f: Fixture, delivery: ChannelDelivery) async {
        await f.channels.flush(now: delivery.createdAt.addingTimeInterval(1))
        await f.model.reconcileChannelPublications()
        await f.model.reconcileChannelFailureFollowUps()
    }

    @Test(arguments: [(false, "origin"), (false, "target"), (true, "origin"), (true, "target")], [false, true])
    func stopFencesQueuedSiblingAndNoncooperativeLatePeerCallback(scenario: (Bool, String), automatic: Bool) async throws {
        let (groupOrigin, stopAt) = scenario
        let gate = AppMailboxChannelFailureGate()
        defer { Task { await gate.open() } }
        let f = try await fixture(automatic: automatic, groupOrigin: groupOrigin, queuesSibling: true, latePeerGate: gate)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        let work: Task<Void, Never>?
        if let group = f.group {
            work = Task { await f.model.sendGroupMessage(groupID: group.id, text: "GROUP_HUMAN_PRIVATE: delegate the shared task") }
            try await eventually { f.model.runningGroups.contains(group.id) }
        } else { work = nil; f.model.send() }
        defer { work?.cancel() }
        let review = try await channelReview(f)
        let target = try #require(f.model.conversations.first { $0.agentBinding?.agentID == f.peer.id })
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let before = try #require(try await store.conversation(id: target.id))
        let beforeGroupMessages = f.group.map { f.model.groupMessages[$0.id] ?? [] }
        let incoming = f.model.agentMessages.filter { $0.recipientID == f.peer.id }.sorted { $0.createdAt < $1.createdAt }
        expectNoDifference(incoming.map(\.text), ["EXACT_SHARED_TASK", "EXACT_QUEUED_SIBLING_TASK"])
        expectNoDifference(incoming.map { $0.delivery?.state }, [.running, .queued])
        expectNoDifference(before.messages.map(\.text), ["EXACT_SHARED_TASK"])
        if stopAt == "target" {
            f.model.selectRoute(.conversation(target.id)); f.model.cancel()
        } else if let group = f.group { await f.model.stopGroup(id: group.id) }
        else { f.model.cancel() }
        try await eventually { await gate.isWaiting }
        await gate.open()
        if let work { await work.value }
        else { try await eventually { !f.model.running.contains(originID) } }
        try await eventually { await f.probe.latePeerAttempts == 1 && f.model.pendingAutoReviewApprovals.isEmpty }
        // A stale native approval cannot revive the stopped chain either.
        await f.model.resolveGroupApproval(review, groupID: f.group?.id ?? originID, approve: true)
        let requests = await f.probe.requests
        expectNoDifference(requests.filter { $0.messages.last?.text.hasPrefix("Incoming peer message") == true }.count, 1)
        let deliveries = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(deliveries, []); expectNoDifference(sent, [])
        let terminal = f.model.agentMessages.filter { $0.recipientID == f.peer.id }.sorted { $0.createdAt < $1.createdAt }
        expectNoDifference(terminal.map(\.text), incoming.map(\.text))
        expectNoDifference(terminal.map { $0.delivery?.state }, [.cancelled, .cancelled])
        let saved = try await store.conversation(id: target.id), other = try await store.conversation(id: otherID)
        expectNoDifference(saved, before); expectNoDifference(other, f.other)
        expectNoDifference(f.group.map { f.model.groupMessages[$0.id] ?? [] }, beforeGroupMessages)
        let reopened = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let restored = try await reopened.conversation(id: target.id)
        expectNoDifference(restored, saved)
    }

    @Test(arguments: [(false, "available", false), (false, "busy", false), (false, "off-page", false),
                       (true, "available", false), (true, "busy", false), (true, "off-page", false),
                       (false, "available", true), (false, "busy", true), (false, "off-page", true),
                       (true, "available", true), (true, "busy", true), (true, "off-page", true)], [false, true])
    func actualPeerDeliveryFailureUsesItsCanonicalOwnerWithoutResending(scenario: (Bool, String, Bool), automatic: Bool) async throws {
        let (ownerRecipient, mode, groupOrigin) = scenario
        let f = try await fixture(automatic: automatic, returnToOwner: ownerRecipient, failsDelivery: true, groupOrigin: groupOrigin)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        let queued = try await reviewedPeerDelivery(f)
        let target = try #require(queued.origin?.conversationID)
        defer { f.model.selectRoute(.conversation(target)); f.model.cancel() }
        let actual = ownerRecipient ? f.owner : f.peer
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        var untouched: [Conversation] = []
        for id in groupOrigin ? [otherID] : [originID, otherID] where id != target {
            untouched.append(try #require(try await store.conversation(id: id)))
        }
        let mailbox = f.model.agentMessages
        let groupMessages = f.group.map { f.model.groupMessages[$0.id] ?? [] }
        f.model.selectRoute(.conversation(otherID))
        if mode == "busy" { f.model.running.insert(target) }
        if mode == "off-page" { f.model.conversations.removeAll { $0.id == target } }
        await failAndReconcile(f, delivery: queued)
        if mode == "busy" {
            let before = await f.channels.failureFollowUps(), requests = await failureRequests(f)
            expectNoDifference(before, []); #expect(diff(requests, [InferenceRequest]()) == nil)
            f.model.running.remove(target)
            await f.model.reconcileChannelFailureFollowUps()
        }
        try await eventually {
            let values = await f.channels.failureFollowUps()
            return values.count == 1 && values[0].status != .running && !f.model.isConversationWorking(target)
        }
        let requests = await failureRequests(f), followUps = await f.channels.failureFollowUps()
        expectNoDifference(requests.count, 1)
        let request = try #require(requests.first), claim = try #require(followUps.first)
        expectNoDifference(request.conversationID, target)
        expectNoDifference(claim.deliveryID, queued.id); expectNoDifference(claim.connectionID, queued.connectionID)
        expectNoDifference(claim.accountID, "local"); expectNoDifference(claim.agentID, actual.id)
        expectNoDifference(claim.conversationID, target); expectNoDifference(claim.status, .completed)
        #expect(request.messages.contains { $0.role == .system && $0.text.contains(actual.instructions) })
        #expect(!request.messages.contains { $0.text.contains("UNRELATED_PRIVATE_HISTORY") || $0.text.contains("PRIVATE_PEER_CONNECTOR_TOKEN") })
        if !ownerRecipient { #expect(!request.messages.contains { $0.text.contains("OWNER_PRIVATE_HISTORY") }) }
        #expect(request.messages.last?.text.contains(ChannelFailureReason.authorizationExpired.descriptionForModel) == true)
        let terminal = try #require(await f.channels.delivery(id: queued.id))
        expectNoDifference(terminal.status, .deadLetter)
        let saved = try #require(try await store.conversation(id: target))
        expectNoDifference(saved.messages.compactMap(\.externalChannelPublication), [try #require(ChannelTranscriptProjection.publication(for: terminal))])
        expectNoDifference(saved.messages.filter { $0.text.hasPrefix("The reviewed peer channel message") }.map(\.text),
            ["The reviewed peer channel message was not delivered; a new send needs a new human request and approval."])
        #expect(!saved.messages.contains { $0.text == "PRIVATE_FAILURE_DRAFT" || ($0.role == .user && $0.text.contains("Host failure facts")) })
        let sends = await f.probe.sent, deliveries = await f.channels.deliveries()
        expectNoDifference(sends, [queued.outbound]); expectNoDifference(deliveries, [terminal])
        expectNoDifference(f.model.agentMessages, mailbox); expectNoDifference(f.model.selection, otherID)
        expectNoDifference(f.group.map { f.model.groupMessages[$0.id] ?? [] }, groupMessages)
        for before in untouched {
            let after = try await store.conversation(id: before.id)
            expectNoDifference(after, before)
        }
        for _ in 0..<3 { await f.model.reconcileChannelFailureFollowUps() }
        let finalRequests = await failureRequests(f), finalSends = await f.probe.sent
        #expect(diff(requests, finalRequests) == nil); expectNoDifference(finalSends, sends)
        let reopened = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let restored = try await reopened.conversation(id: target)
        expectNoDifference(restored, saved)
        let restoredChannels = try ChannelService(storeURL: f.root.appending(path: "channels.json"))
        let restarted = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false,
            channelService: restoredChannels, channelConnectors: [AppMailboxChannelConnector(probe: f.probe, fails: true)])
        defer { restarted.selectRoute(.conversation(target)); restarted.cancel() }
        await restarted.registry.register(AppMailboxChannelProvider(probe: f.probe, peerID: f.peer.id,
            channelArguments: ["type": "text", "channel": "slack:C_PEER", "content": "FORBIDDEN_REOPEN_SEND"],
            returnToOwnerID: ownerRecipient ? f.owner.id : nil))
        await restarted.bootstrap(); await restarted.setAutomationRuntimeActive(false); restarted.setWorkflowRuntimeActive(false)
        await restarted.reconcileChannelFailureFollowUps()
        let afterReopenRequests = await failureRequests(f), afterReopenSends = await f.probe.sent
        #expect(diff(requests, afterReopenRequests) == nil); expectNoDifference(afterReopenSends, sends)
        let afterReopenClaims = await restoredChannels.failureFollowUps()
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970; decoder.dateDecodingStrategy = .millisecondsSince1970
        expectNoDifference(afterReopenClaims, try decoder.decode([ChannelFailureFollowUp].self, from: encoder.encode(followUps)))
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)], ["stop", "persona-ABA", "account-ABA"])
    func revokedActualPeerFailureRejectsLateCorrection(scenario: (Bool, Bool), mode: String) async throws {
        let (ownerRecipient, groupOrigin) = scenario
        let gate = AppMailboxChannelFailureGate()
        defer { Task { await gate.open() } }
        let f = try await fixture(automatic: true, returnToOwner: ownerRecipient, failsDelivery: true,
            failureGate: gate, groupOrigin: groupOrigin)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        let queued = try await reviewedPeerDelivery(f), target = try #require(queued.origin?.conversationID)
        defer { f.model.selectRoute(.conversation(target)); f.model.cancel() }
        let actual = ownerRecipient ? f.owner : f.peer
        await failAndReconcile(f, delivery: queued)
        try await eventually { await gate.isWaiting }
        if mode == "stop" { f.model.selectRoute(.conversation(target)); f.model.cancel() }
        if mode == "persona-ABA" {
            var changed = actual; changed.instructions = "CHANGED_FAILURE_PERSONA"
            #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(actual))
        }
        if mode == "account-ABA" {
            await f.model.cancelAutoReviewApprovals(nextAccountID: "other"); f.model.settings.accountScope = "other"
            await f.model.cancelAutoReviewApprovals(nextAccountID: "local"); f.model.settings.accountScope = "local"
        }
        await gate.open()
        try await eventually {
            let values = await f.channels.failureFollowUps(), attempts = await f.probe.failureAttempts
            return values.count == 1 && values[0].status != .running && attempts == 1 && !f.model.isConversationWorking(target)
        }
        let claims = await f.channels.failureFollowUps(), requests = await failureRequests(f)
        expectNoDifference(claims.first?.status, .cancelled); expectNoDifference(requests.count, 1)
        let saved = try #require(try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).conversation(id: target))
        #expect(!saved.messages.contains { $0.text.hasPrefix("The reviewed peer channel message") || $0.text == "PRIVATE_FAILURE_DRAFT" })
        let terminal = try #require(await f.channels.delivery(id: queued.id))
        expectNoDifference(saved.messages.compactMap(\.externalChannelPublication), [try #require(ChannelTranscriptProjection.publication(for: terminal))])
        for _ in 0..<3 { await f.model.reconcileChannelFailureFollowUps() }
        let finalRequests = await failureRequests(f), sends = await f.probe.sent, deliveries = await f.channels.deliveries()
        #expect(diff(requests, finalRequests) == nil); expectNoDifference(sends, [queued.outbound])
        expectNoDifference(deliveries, [terminal])
    }

    @Test(arguments: [(false, false), (true, false), (false, true), (true, true)])
    func actualPeerFailureCannotAcquireAnExternalRetry(scenario: (Bool, Bool)) async throws {
        let (ownerRecipient, groupOrigin) = scenario
        let f = try await fixture(automatic: true, returnToOwner: ownerRecipient, failsDelivery: true,
            triesExternalFailureRetry: true, groupOrigin: groupOrigin)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        let queued = try await reviewedPeerDelivery(f), target = try #require(queued.origin?.conversationID)
        defer { f.model.selectRoute(.conversation(target)); f.model.cancel() }
        await failAndReconcile(f, delivery: queued)
        try await eventually {
            let values = await f.channels.failureFollowUps()
            return values.count == 1 && values[0].status != .running && !f.model.isConversationWorking(target)
        }
        let claims = await f.channels.failureFollowUps(), requests = await failureRequests(f)
        expectNoDifference(claims.first?.status, .failed); expectNoDifference(requests.count, 1)
        let rejections = await f.probe.protocolRejections
        expectNoDifference(rejections, [.schemaMismatch(callID: "peer-failure-correction", detail: "unknown property 'channel'")])
        let saved = try #require(try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).conversation(id: target))
        #expect(!saved.messages.contains { $0.text.hasPrefix("The reviewed peer channel message") || $0.text == "PRIVATE_FAILURE_DRAFT" })
        let sends = await f.probe.sent, deliveries = await f.channels.deliveries()
        expectNoDifference(sends, [queued.outbound]); expectNoDifference(deliveries.count, 1)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty)
    }

    @Test(arguments: [(false, "direct"), (true, "direct"), (false, "group"), (true, "group"),
                      (false, "manual"), (true, "manual"), (false, "manual-existing"), (true, "manual-existing")],
          ["approve", "deny-source", "deny-send", "stop-source", "stop-send", "stop-target-source", "stop-target-send", "persona-ABA-source"])
    func localAndHTTPSAttachmentsRetainIndependentSourceAndSendConsent(scenario: (Bool, String), mode: String) async throws {
        let (local, route) = scenario
        let manual = route.hasPrefix("manual"), existing = route == "manual-existing"
        let preventsSource = ["deny-source", "stop-source", "stop-target-source", "persona-ABA-source"].contains(mode)
        let reference = try RemoteAttachmentReference(url: "https://source.example/peer.html?signature=exact", alt: "Reviewed peer file")
        let f = try await fixture(automatic: true, arguments: ["type": "attachment", "channel": "slack:C_PEER",
            "url": reference.url, "alt": reference.alt ?? ""], localFile: local, groupOrigin: route == "group",
            manual: manual, existingPeer: existing)
        defer { f.model.cancel(); try? FileManager.default.removeItem(at: f.root) }
        var origin = f.group?.id ?? originID
        let groupWork: Task<Void, Never>?
        if manual {
            groupWork = nil
            #expect(await f.model.sendAgentMessage(senderID: f.owner.id, recipientID: f.peer.id, text: "EXACT_MANUAL_FILE_TASK"))
            try await eventually { f.model.agentMessages.first?.delivery?.originConversationID != nil }
            origin = try #require(f.model.agentMessages.first?.delivery?.originConversationID)
            #expect(origin != originID && origin != otherID)
        } else if let group = f.group {
            groupWork = Task { await f.model.sendGroupMessage(groupID: group.id, text: "GROUP_HUMAN_PRIVATE: delegate the shared task") }
            try await eventually { f.model.runningGroups.contains(group.id) }
        } else { groupWork = nil; f.model.send() }
        defer { groupWork?.cancel() }
        func stop() async {
            if let group = f.group { await f.model.stopGroup(id: group.id) }
            else if manual { await f.model.stopAgentMessages(scopeID: origin) }
            else { f.model.cancel() }
        }
        func stopTarget() throws {
            let target = try #require(f.model.conversations.first { $0.agentBinding?.agentID == f.peer.id })
            f.model.selectRoute(.conversation(target.id)); f.model.cancel()
        }
        func resolve(_ pending: PendingApproval, approve: Bool) async {
            if let group = f.group { await f.model.resolveGroupApproval(pending, groupID: group.id, approve: approve) }
            else if manual { await f.model.resolveGroupApproval(pending, groupID: origin, approve: approve) }
            else { f.model.handleTranscriptCardIntent(approve ? .approveReview(reviewID: pending.id) : .rejectReview(reviewID: pending.id)) }
        }
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970; decoder.dateDecodingStrategy = .secondsSince1970
        func persisted(_ value: Conversation) throws -> Conversation {
            try decoder.decode(Conversation.self, from: encoder.encode(value))
        }
        var manualHistory: [Conversation]?
        func captureManualHistory() async throws {
            guard manual else { return }
            let history = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
            let chat = try #require(history.first { $0.agentBinding?.agentID == f.peer.id })
            let incoming = try #require(f.model.agentMessages.first { $0.recipientID == f.peer.id })
            let source = try AgentMessageSource(accountID: "local", originConversationID: origin,
                deliveryID: incoming.id, senderAgentID: f.owner.id, recipientAgentID: f.peer.id, kind: .incoming)
            var expected = f.existingPeer ?? Conversation(id: chat.id, title: f.peer.name,
                providerID: f.peer.providerID, modelID: f.peer.modelID, updatedAt: incoming.createdAt)
            expected.agentBinding = .init(accountID: "local", agentID: f.peer.id)
            expected.messages.append(.init(id: incoming.id, role: .assistant, text: "EXACT_MANUAL_FILE_TASK",
                createdAt: incoming.createdAt, agentMessageSource: source))
            expected.updatedAt = max(expected.updatedAt, incoming.createdAt)
            DirectMessageAddressing.assignMissing(in: &expected)
            expectNoDifference(try persisted(chat), try persisted(expected))
            expectNoDifference(history.first { $0.id == otherID }, f.other)
            expectNoDifference(history.count, 2)
            #expect(history.allSatisfy { $0.id != origin })
            manualHistory = history
        }
        if local {
            try await eventually {
                if let delegation = f.model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["tool"] == "SendToAgent" }) {
                    await f.model.resolveGroupApproval(delegation, groupID: origin, approve: true)
                }
                return !f.model.pendingToolApprovals.isEmpty
            }
            let read = try #require(f.model.pendingToolApprovals.first)
            expectNoDifference(read.conversationID, origin)
            let before = await f.probe.reads
            expectNoDifference(before, [])
            try await captureManualHistory()
            if mode == "stop-source" { await stop() }
            if mode == "stop-target-source" { try stopTarget() }
            if mode == "persona-ABA-source" {
                var changed = f.peer; changed.instructions = "UNREVIEWED_PERSONA"
                #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(f.peer))
            }
            f.model.resolveLocalToolApproval(id: read.id, allowed: mode != "deny-source")
        } else {
            let source = try await channelReview(f, sourceDownload: true)
            expectNoDifference(source.action.context.conversationID, origin)
            let before = await f.probe.downloads
            expectNoDifference(before, [])
            try await captureManualHistory()
            if mode == "stop-source" { await stop() }
            if mode == "stop-target-source" { try stopTarget() }
            if mode == "persona-ABA-source" {
                var changed = f.peer; changed.instructions = "UNREVIEWED_PERSONA"
                #expect(await f.model.updateAgent(changed)); #expect(await f.model.updateAgent(f.peer))
            }
            await resolve(source, approve: mode != "deny-source")
        }
        if !preventsSource {
            let send = try await channelReview(f)
            expectNoDifference(send.action.context.conversationID, origin)
            let before = await f.channels.deliveries()
            expectNoDifference(before, [])
            if let source = f.localSource { try Data("UNREVIEWED_REPLACEMENT".utf8).write(to: source) }
            await f.probe.replaceBytes()
            if mode == "stop-send" { await stop() }
            if mode == "stop-target-send" { try stopTarget() }
            await resolve(send, approve: mode != "deny-send")
        }
        if let groupWork { await groupWork.value }
        else if manual { try await eventually { f.model.runningAgentMessageScopes.isEmpty } }
        else { try await eventually { !f.model.running.contains(originID) } }
        let bytes = Data("EXACT_CAPTURED_PEER_FILE".utf8)
        let prepared = try PreparedAgentPublicationFile(bytes: bytes, filename: "peer.html")
        let attachment = ChannelAttachment(blobID: prepared.digest, filename: prepared.filename,
            mimeType: "application/octet-stream", byteCount: Int64(bytes.count))
        let queue = await f.channels.deliveries(), downloads = await f.probe.downloads, reads = await f.probe.reads
        let succeeds = mode == "approve", acquired = !preventsSource
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
            #expect(actual.conversationID != origin)
        } else { #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "channel-attachments").path)) }
        if manual {
            var expectedHistory = try #require(manualHistory)
            let peerIndex = try #require(expectedHistory.firstIndex { $0.agentBinding?.agentID == f.peer.id })
            let peerID = expectedHistory[peerIndex].id
            if succeeds {
                let delivery = try #require(queue.first), queueOrigin = try #require(delivery.origin)
                let expectedOrigin = ChannelDeliveryOrigin(route: .directConversation, conversationID: peerID,
                    senderID: peerID, senderName: f.peer.name, runID: queueOrigin.runID, callID: "peer-channel",
                    intent: .init(kind: .attachment, text: "Reviewed peer file", sources: [
                        .init(url: local ? try #require(f.localSource).absoluteString : reference.url, alt: "Reviewed peer file")
                    ]))
                let expectedDelivery = ChannelDelivery(id: delivery.id, connectionID: f.peerConnection.id,
                    address: .init(platform: "slack", channelID: "C_PEER"),
                    outbound: .init(text: "Reviewed peer file", attachments: [attachment]), idempotencyKey: delivery.idempotencyKey,
                    nextAttemptAt: delivery.nextAttemptAt, createdAt: delivery.createdAt,
                    authorization: .init(ownerAccountID: "local", agentID: f.peer.id,
                        configurationRevision: try #require(delivery.authorization).configurationRevision), origin: expectedOrigin)
                expectNoDifference(queue, [expectedDelivery])
                let publication = try #require(ChannelTranscriptProjection.publication(for: expectedDelivery))
                expectedHistory[peerIndex].messages.append(publication.directMessage)
                expectedHistory[peerIndex].updatedAt = max(expectedHistory[peerIndex].updatedAt, publication.queuedAt)
                DirectMessageAddressing.assignMissing(in: &expectedHistory[peerIndex])
            }
            let saved = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
            expectNoDifference(try saved.map(persisted), try expectedHistory.map(persisted))
            let reopenedHistory = try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).load()
            expectNoDifference(reopenedHistory, saved)
            let reopenedChannels = try ChannelService(storeURL: f.root.appending(path: "channels.json"))
            let reopenedQueue = await reopenedChannels.deliveries()
            // Keep every Date and field, but compare the persisted wire value:
            // ChannelService uses milliseconds, whereas SQL uses seconds.
            let channelEncoder = JSONEncoder(), channelDecoder = JSONDecoder()
            channelEncoder.dateEncodingStrategy = .millisecondsSince1970
            channelDecoder.dateDecodingStrategy = .millisecondsSince1970
            let persistedQueue = try channelDecoder.decode([ChannelDelivery].self, from: channelEncoder.encode(queue))
            expectNoDifference(reopenedQueue, persistedQueue)
            let contexts = try AgentConversationStore(url: f.root.appending(path: "agent-conversations.json"))
            let context = try await contexts.context(accountID: "local", originID: origin, agentID: f.peer.id)
            expectNoDifference(context.transcriptConversationID, peerID)
            let requests = await f.probe.requests
            expectNoDifference(requests.count, 1)
            expectNoDifference(requests.first?.conversationID, context.conversationID)
            #expect(requests.allSatisfy { request in request.messages.allSatisfy {
                !$0.text.contains("EXISTING_PEER_PRIVATE_HISTORY") && !$0.text.contains("UNRELATED_PRIVATE_HISTORY")
            } })
            #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty)
        }
        let sent = await f.probe.sent
        expectNoDifference(sent, [])
    }
}
