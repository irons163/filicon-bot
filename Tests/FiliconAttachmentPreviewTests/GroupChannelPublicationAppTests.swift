import Foundation
import AppKit
import SwiftUI
import Vision
import Testing
import CustomDump
import FiliconAppServices
import FiliconAutoReview
import FiliconChannels
import FiliconDomain
import FiliconProviderKit
@testable import FiliconAgents
@testable import Filicon

private actor GroupChannelProbe {
    var sent: [ChannelOutbound] = []
    var requests: [InferenceRequest] = []
    func record(_ message: ChannelOutbound) { sent.append(message) }
    func request(_ value: InferenceRequest) { requests.append(value) }
}

/// No credentials, HTTP session or platform transport can be reached by this
/// fixture, even if the App's ordinary delivery observer flushes the queue.
private struct GroupChannelConnector: ChannelConnector {
    var supportsAttachments = true
    var fails = false
    var descriptor: ChannelConnectorDescriptor {
        .init(id: "slack", displayName: "Isolated fixture", supportsAttachments: supportsAttachments)
    }
    let probe: GroupChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.record(message)
        if fails { throw ChannelServiceError.authExpired("PRIVATE_GROUP_FAILURE_TOKEN must not become a model instruction") }
    }
}

private struct GroupChannelProvider: AIProvider {
    let descriptor = ProviderDescriptor(id: "group-channel-fixture", displayName: "Offline publication", requiresAPIKey: false)
    let content: String
    var expectedSuccess: Bool
    var attachment = false
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                if request.toolExchanges.isEmpty {
                    let tool = try #require(request.tools.first { $0.name == "SendMessage" })
                    let schema = try #require(JSONSerialization.jsonObject(with: tool.inputSchema) as? [String: Any])
                    #expect((schema["properties"] as? [String: Any])?["channel"] != nil)
                    let arguments = attachment
                        ? ["type": "attachment", "url": "file:///never-read.txt", "channel": "slack:C_FIXTURE"]
                        : ["type": "text", "content": content, "channel": "slack:C_FIXTURE"]
                    let call = try NormalizedToolCall(id: "external-publication", name: "SendMessage",
                        argumentsJSON: JSONEncoder().encode(arguments))
                    continuation.yield(.toolCallStarted(id: call.id, name: call.name))
                    continuation.yield(.toolCallCompleted(call))
                    continuation.yield(.completed(.toolUse))
                } else {
                    let result = try #require(request.toolExchanges.last?.results.first)
                    expectNoDifference(result.isError, !expectedSuccess)
                    expectNoDifference(result.wireText.contains("durably queued, not confirmed delivered"), expectedSuccess)
                    expectNoDifference(result.wireText.contains("Saved message receipt:"), expectedSuccess)
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

/// Records complete requests around the existing offline tool-loop fixture.
/// It cannot conceal an unintended background wake or retry after failure.
private struct RecordedGroupChannelProvider: AIProvider {
    let base: GroupChannelProvider
    let probe: GroupChannelProbe
    var descriptor: ProviderDescriptor { base.descriptor }
    func models() async throws -> [AIModel] { try await base.models() }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.request(request)
                do {
                    for try await event in base.stream(request) { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Foreground group channel publication", .timeLimit(.minutes(1)))
@MainActor struct GroupChannelPublicationAppTests {
    @Test(arguments: [false, true])
    func terminalSavedGroupFailureKeepsItsReceiptWithoutWakingTheGroupOrResending(automaticReviewEnabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-failure-contract-\(UUID())")
        let probe = GroupChannelProbe(), connector = GroupChannelConnector(fails: true, probe: probe)
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [connector])
        defer { model.cancel(); try? FileManager.default.removeItem(at: root) }
        await model.registry.register(RecordedGroupChannelProvider(
            base: GroupChannelProvider(content: "EXACT_REVIEWED_GROUP_OUTBOUND", expectedSuccess: true), probe: probe))
        await model.bootstrap()
        await model.setAutomationRuntimeActive(false); model.setWorkflowRuntimeActive(false)
        let sender = try #require(await model.createAgent(name: "Original sender", summary: "",
            instructions: "ORIGINAL_GROUP_MEMBER_PERSONA", providerID: "group-channel-fixture", modelID: "fixture"))
        #expect(await model.createGroup(name: "Saved group failure", summary: "PRIVATE_SAVED_GROUP_CONTEXT", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        let connection = ChannelConnection(connectorID: "slack", displayName: "Offline original connection",
            secretReference: "keychain://channels/TEST-group-failure-never-read", agentID: sender.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        await model.setAutoReviewEnabled(automaticReviewEnabled)
        let run = Task { await model.sendGroupMessage(groupID: group.id, text: "Publish only the reviewed group result") }
        defer { run.cancel() }
        let review = try await pending(model)
        expectNoDifference(review.action.context.conversationID, group.id)
        expectNoDifference(review.action.context.metadata["agentChannelPublication"], "true")
        let queueBeforeReview = await channels.deliveries(), sendsBeforeReview = await probe.sent
        expectNoDifference(queueBeforeReview, []); expectNoDifference(sendsBeforeReview, [])
        await model.resolveGroupApproval(review, groupID: group.id, approve: true)
        await run.value
        let queued = try #require(await channels.deliveries().first)
        expectNoDifference(queued.origin?.route, .groupConversation)
        expectNoDifference(queued.origin?.conversationID, group.id)
        expectNoDifference(queued.origin?.senderID, sender.id)
        expectNoDifference(queued.status, .queued)
        let requestsBefore = await probe.requests
        expectNoDifference(requestsBefore.count, 2)
        let chats = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        let chatsBefore = try await chats.load(), messagesBefore = model.groupMessages[group.id] ?? []
        let groupsBefore = model.groups, mailboxBefore = model.agentMessages
        let publicationIndex = try #require(messagesBefore.firstIndex { $0.id == queued.id })
        let publication = try #require(messagesBefore[publicationIndex].externalPublication)
        let failedAt = queued.createdAt.addingTimeInterval(1)
        var expectedDelivery = queued
        expectedDelivery.status = .deadLetter; expectedDelivery.attemptCount = 1
        expectedDelivery.lastError = ChannelServiceError.authExpired(
            "PRIVATE_GROUP_FAILURE_TOKEN must not become a model instruction").localizedDescription
        var expectedMessages = messagesBefore
        expectedMessages[publicationIndex].externalPublication?.delivery = .init(status: .deadLetter, attemptCount: 1, deliveredAt: nil)
        for _ in 0..<3 {
            await channels.flush(now: failedAt)
            await model.reconcileChannelPublications()
            await model.reconcileChannelFailureFollowUps()
        }
        let queue = await channels.deliveries(), requests = await probe.requests, sends = await probe.sent
        let followUps = await channels.failureFollowUps(), wakes = await channels.failureWakes()
        expectNoDifference(queue, [expectedDelivery]); expectNoDifference(sends, [queued.outbound])
        expectNoDifference(String(customDumping: requests), String(customDumping: requestsBefore))
        expectNoDifference(followUps, [])
        let wake = try #require(wakes.first)
        expectNoDifference(wakes, [ChannelFailureWake(id: wake.id, connectionID: queued.connectionID,
            deliveryID: queued.id, error: try #require(expectedDelivery.lastError), createdAt: failedAt, reason: .authorizationExpired)])
        expectNoDifference(model.groupMessages[group.id], expectedMessages)
        expectNoDifference(model.groups, groupsBefore); expectNoDifference(model.agentMessages, mailboxBefore)
        expectNoDifference(model.runningGroups, []); expectNoDifference(model.runningAgentMessageScopes, [])
        expectNoDifference(model.pendingAutoReviewApprovals, []); expectNoDifference(model.pendingToolApprovals, [])
        let chatsAfter = try await chats.load()
        expectNoDifference(chatsAfter, chatsBefore)
        var expectedPublication = publication
        expectedPublication.delivery = .init(status: .deadLetter, attemptCount: 1, deliveredAt: nil)
        expectNoDifference(expectedMessages[publicationIndex].externalPublication, expectedPublication)

        // The complete persisted values use the real JSON millisecond codec;
        // keep generated IDs, authors, aliases, timestamps and every payload.
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970; decoder.dateDecodingStrategy = .millisecondsSince1970
        let reopenedGroups = try GroupService(agents: AgentService(storeURL: root.appending(path: "agents.json")),
            storeURL: root.appending(path: "groups.json"))
        let durableMessages = await reopenedGroups.messages(groupID: group.id), durableGroups = await reopenedGroups.list()
        expectNoDifference(durableMessages, try decoder.decode([RoomMessage].self, from: encoder.encode(expectedMessages)))
        expectNoDifference(durableGroups, try decoder.decode([AgentGroup].self, from: encoder.encode(groupsBefore)))
        let restoredChannels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: restoredChannels, channelConnectors: [connector])
        defer { reopened.cancel() }
        await reopened.registry.register(RecordedGroupChannelProvider(
            base: GroupChannelProvider(content: "FORBIDDEN_REOPEN_RETRY", expectedSuccess: true), probe: probe))
        await reopened.bootstrap()
        await reopened.setAutomationRuntimeActive(false); reopened.setWorkflowRuntimeActive(false)
        await reopened.reconcileChannelPublications(); await reopened.reconcileChannelFailureFollowUps()
        let reopenedQueue = await restoredChannels.deliveries(), reopenedWakes = await restoredChannels.failureWakes()
        let reopenedFollowUps = await restoredChannels.failureFollowUps(), reopenedRequests = await probe.requests, reopenedSends = await probe.sent
        expectNoDifference(reopenedQueue, try decoder.decode([ChannelDelivery].self, from: encoder.encode([expectedDelivery])))
        expectNoDifference(reopenedWakes, try decoder.decode([ChannelFailureWake].self, from: encoder.encode(wakes)))
        expectNoDifference(reopenedFollowUps, [])
        expectNoDifference(String(customDumping: reopenedRequests), String(customDumping: requestsBefore))
        expectNoDifference(reopenedSends, [queued.outbound])
        let finalChats = try await chats.load()
        expectNoDifference(finalChats, chatsBefore)
        expectNoDifference(reopened.groupMessages[group.id], durableMessages)
        expectNoDifference(reopened.groups, durableGroups)
        expectNoDifference(reopened.runningGroups, []); expectNoDifference(reopened.pendingAutoReviewApprovals, [])
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "members", "connection", "connector"], [false, true])
    func completeOutgoingTextRequiresFreshHumanReview(mode: String, automaticReviewEnabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = GroupChannelProbe(), connector = GroupChannelConnector(probe: probe)
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [connector])
        await model.bootstrap()
        let content = "BEGIN exact outgoing text\n" + String(repeating: "核准前不能傳送；", count: 600) + "\nEND exact outgoing text"
        await model.registry.register(GroupChannelProvider(content: content, expectedSuccess: mode == "approve"))
        let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "",
            providerID: "group-channel-fixture", modelID: "fixture"))
        #expect(await model.createGroup(name: "Reviewed channel", summary: "", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        let connection = ChannelConnection(connectorID: "slack", displayName: "My fixture connection",
            secretReference: "keychain://channels/TEST-only-never-resolved", agentID: sender.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        await model.setAutoReviewEnabled(automaticReviewEnabled)
        let run = Task { await model.sendGroupMessage(groupID: group.id, text: "Publish the reviewed result externally") }
        defer { run.cancel() }
        let approval = try await pending(model)
        expectNoDifference(approval.action.context.conversationID, group.id)
        expectNoDifference(approval.action.context.metadata["tool"], "SendMessage")
        expectNoDifference(approval.action.context.metadata["agentChannelPublication"], "true")
        expectNoDifference(approval.action.target, .resource(kind: "channel", identifier: connection.id.uuidString))
        #expect(approval.action.risks.contains(.sensitive))
        #expect(approval.action.risks.contains(.externalSideEffect))
        let details = try #require(approval.action.context.metadata["agentMessage"])
        #expect(details.contains(content))
        #expect(details.contains("slack:C_FIXTURE"))
        #expect(details.contains(connection.displayName))
        #expect(!details.contains(connection.secretReference))
        let queuedBeforeApproval = await channels.deliveries(), sentBeforeApproval = await probe.sent
        expectNoDifference(queuedBeforeApproval, [])
        expectNoDifference(sentBeforeApproval, [])
        if mode == "stop" { await model.stopGroup(id: group.id) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "members" { await model.updateGroupMembers(groupID: group.id, memberIDs: []) }
        if mode == "connection" { try await channels.setConnectionEnabled(id: connection.id, enabled: false) }
        if mode == "connector" { await channels.register(connector) }
        await model.resolveGroupApproval(approval, groupID: group.id, approve: mode != "deny")
        await run.value
        let deliveries = await channels.deliveries()
        expectNoDifference(deliveries.map(\.outbound), mode == "approve" ? [.init(text: content)] : [])
        expectNoDifference(deliveries.map(\.address), mode == "approve" ? [.init(platform: "slack", channelID: "C_FIXTURE")] : [])
        expectNoDifference(deliveries.compactMap { $0.authorization?.agentID }, mode == "approve" ? [sender.id] : [])
        if mode == "approve" {
            let delivery = try #require(deliveries.first)
            let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(delivery)) as? [String: Any])
            let origin = try #require(encoded["origin"] as? [String: Any], "The durable queue must retain its host-bound group and member")
            expectNoDifference(origin["conversationID"] as? String, group.id.uuidString)
            expectNoDifference(origin["senderID"] as? String, sender.id.uuidString)
            expectNoDifference(origin["senderName"] as? String, sender.name)
            expectNoDifference(origin["route"] as? String, "groupConversation")
            expectNoDifference(origin["callID"] as? String, "external-publication")
            let publication = try #require(model.groupMessages[group.id, default: []].first { $0.id == delivery.id },
                "The approved external message must have a canonical entry in its original group")
            expectNoDifference(publication.text, content)
        }
        #expect(!model.runningGroups.contains(group.id))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        // Only successful, durable canonical saves acquire a local receipt.
        expectNoDifference(model.groupMessages[group.id, default: []].filter { $0.externalPublication != nil }.map(\.text), mode == "approve" ? [content] : [])
        #expect(model.groupMessages[group.id, default: []].filter { $0.senderID != nil && $0.externalPublication == nil }.allSatisfy { $0.text.isEmpty })
        if mode != "approve" {
            let sentAfterRejection = await probe.sent
            expectNoDifference(sentAfterRejection, [])
        }
    }

    @Test(arguments: ["no-connection", "peer", "foreign-account", "ambiguous", "attachment"])
    func unavailableDestinationNeverQueuesOrFallsBack(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-unavailable-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = GroupChannelProbe()
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [GroupChannelConnector(supportsAttachments: mode != "attachment", probe: probe)])
        await model.bootstrap()
        await model.registry.register(GroupChannelProvider(content: "Private result", expectedSuccess: false, attachment: mode == "attachment"))
        let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "",
            providerID: "group-channel-fixture", modelID: "fixture"))
        #expect(await model.createGroup(name: "Unavailable route", summary: "", memberIDs: [sender.id]))
        let group = try #require(model.groups.first)
        if mode != "no-connection" {
            try await channels.saveConnection(.init(connectorID: "slack", displayName: "Fixture",
                secretReference: "keychain://channels/TEST-only", agentID: mode == "peer" ? UUID() : sender.id,
                ownerAccountID: mode == "foreign-account" ? "other" : "local"))
        }
        if mode == "ambiguous" {
            try await channels.saveConnection(.init(connectorID: "slack", displayName: "Second fixture",
                secretReference: "keychain://channels/TEST-only-second", agentID: sender.id, ownerAccountID: "local"))
        }
        await model.sendGroupMessage(groupID: group.id, text: "Attempt unavailable external route")
        let queued = await channels.deliveries(), sent = await probe.sent
        expectNoDifference(queued, [])
        expectNoDifference(sent, [])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(model.pendingToolApprovals.isEmpty)
        #expect(model.pendingWorkspaceFolders.isEmpty)
        #expect(!model.runningGroups.contains(group.id))
        #expect(model.groupMessages[group.id, default: []].filter { $0.senderID != nil }.allSatisfy { $0.text.isEmpty })
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], [340.0, 620.0])
    func approvalCardRetainsWholePayload(language: String, width: Double) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-card-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let content = "BEGIN OUTGOING\n" + String(repeating: "Reviewed outgoing payload. ", count: 110) + "\nEND OUTGOING"
        try await FiliconLocalization.$languageOverride.withValue(language) {
            let probe = GroupChannelProbe()
            let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
            let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
                channelService: channels, channelConnectors: [GroupChannelConnector(probe: probe)])
            await model.bootstrap()
            await model.registry.register(GroupChannelProvider(content: content, expectedSuccess: false))
            let sender = try #require(await model.createAgent(name: "Sender", summary: "", instructions: "",
                providerID: "group-channel-fixture", modelID: "fixture"))
            #expect(await model.createGroup(name: "Reviewed channel", summary: "", memberIDs: [sender.id]))
            let groupID = try #require(model.groups.first?.id)
            try await channels.saveConnection(.init(connectorID: "slack", displayName: "My fixture connection",
                secretReference: "keychain://channels/TEST-only-never-resolved", agentID: sender.id, ownerAccountID: "local"))
            let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Review the full outgoing text") }
            defer { run.cancel() }
            let approval = try await pending(model)
            let details = try #require(approval.action.context.metadata["agentMessage"])
            #expect(details.contains(content))
            for dark in [false, true] {
                try await withUIRenderTurn(language: language) {
                    let heading = l10n("Queue this message to an external channel?")
                    let notice = l10n("Queued is not delivered. Stop does not recall a queued message.")
                    if language != "en" {
                        #expect(heading != "Queue this message to an external channel?")
                        #expect(notice != "Queued is not delivered. Stop does not recall a queued message.")
                    }
                    #expect(details.contains(heading))
                    #expect(details.contains(notice))
                    #expect(!l10n("Channel").trimmingCharacters(in: .whitespaces).hasSuffix(":"))
                    let host = NSHostingView(rootView: GroupToolApprovalPanel(groupID: groupID)
                        .environmentObject(model).foregroundStyle(FiliconTheme.textPrimary).padding(16)
                        .frame(width: width).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let size = host.fittingSize
                    // AppKit's fitting calculation can retain a subpixel
                    // rounding residue even for a fixed-width SwiftUI frame.
                    #expect(abs(size.width - CGFloat(width)) < 0.5)
                    #expect(size.height > 400 && size.height < 5_000)
                    host.frame = .init(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    recognition.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([recognition])
                    let visible = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                    #expect(visible.contains("BEGIN OUTGOING"))
                    #expect(visible.contains("END OUTGOING"))
                    #expect(visible.contains("C_FIXTURE"))
                    if let path = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: directory.appending(path: "channel-message-\(language)-\(Int(width))-\(dark ? "dark" : "light").png"))
                    }
                }
            }
            await model.resolveGroupApproval(approval, groupID: groupID, approve: false)
            await run.value
            let queued = await channels.deliveries(), sent = await probe.sent
            expectNoDifference(queued, [])
            expectNoDifference(sent, [])
        }
    }

    private func pending(_ model: AppModel) async throws -> PendingApproval {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.pendingAutoReviewApprovals.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(model.pendingAutoReviewApprovals.first, "\(model.errorMessage ?? "No channel approval")")
    }
}
