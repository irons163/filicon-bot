import Foundation
import AppKit
import SwiftUI
import Vision
import Testing
import CustomDump
import FiliconAutoReview
import FiliconChannels
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor GroupChannelProbe {
    var sent: [ChannelOutbound] = []
    func record(_ message: ChannelOutbound) { sent.append(message) }
}

/// No credentials, HTTP session or platform transport can be reached by this
/// fixture, even if the App's ordinary delivery observer flushes the queue.
private struct GroupChannelConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Isolated fixture")
    let probe: GroupChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.record(message)
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
                    #expect(!result.wireText.contains("Saved message receipt:"))
                    continuation.yield(.completed(.stop))
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@Suite("Foreground group channel publication", .timeLimit(.minutes(1)))
@MainActor struct GroupChannelPublicationAppTests {
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
        #expect(!model.runningGroups.contains(group.id))
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        // The queue identity is not a fabricated local publication or reply.
        #expect(model.groupMessages[group.id, default: []].filter { $0.senderID != nil }.allSatisfy { $0.text.isEmpty })
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
            channelService: channels, channelConnectors: [GroupChannelConnector(probe: probe)])
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
