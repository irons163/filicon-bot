import Foundation
import Testing
import CustomDump
import FiliconAgents
@testable import FiliconAppServices
import FiliconAutomations
import FiliconAutoReview
import FiliconChannels
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor BackgroundChannelProbe {
    var requests: [InferenceRequest] = []
    var capabilities: [Bool] = []
    var results: [NormalizedToolResult] = []
    var sent: [ChannelOutbound] = []
    var downloads: [RemoteAttachmentReference] = []
    var bytes = Data("REVIEWED_BACKGROUND_ATTACHMENT".utf8)
    func record(_ request: InferenceRequest, channel: Bool) -> Int {
        requests.append(request); capabilities.append(channel); return requests.count
    }
    func record(_ result: NormalizedToolResult) { results.append(result) }
    func record(_ outbound: ChannelOutbound) { sent.append(outbound) }
    func replaceBytes(_ value: Data) { bytes = value }
    func download(_ reference: RemoteAttachmentReference, redirect: Bool) throws -> RemoteAttachmentDownload {
        downloads.append(reference)
        if redirect && reference.url.contains("source.example") {
            throw RemoteAttachmentDownloadError.redirect("https://redirect.example/background.txt?signature=exact")
        }
        return .init(reference: reference, data: bytes, declaredMIMEType: "text/html")
    }
}

private struct BackgroundChannelDownloader: RemoteAttachmentDownloading {
    let probe: BackgroundChannelProbe
    var redirect = false
    func download(_ reference: RemoteAttachmentReference, maximumBytes: Int) async throws -> RemoteAttachmentDownload {
        try await probe.download(reference, redirect: redirect)
    }
}

/// No credentials, platform transport, or real account exists in this fixture.
private struct BackgroundChannelConnector: ChannelConnector {
    var supportsAttachments = true
    var fails = false
    var descriptor: ChannelConnectorDescriptor {
        .init(id: "slack", displayName: "Offline background fixture", supportsAttachments: supportsAttachments)
    }
    let probe: BackgroundChannelProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.record(message)
        if fails { throw ChannelServiceError.authExpired("PRIVATE_BACKGROUND_CREDENTIAL must not reach the model") }
    }
}

private struct BackgroundChannelProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "background-channel-fixture", displayName: "Offline background publication", requiresAPIKey: false)
    let probe: BackgroundChannelProbe
    var arguments: Data?
    var numbered = false
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.transport("The legacy text runner must not be used")) }
    }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tool = try #require(request.tools.first { $0.name == "SendMessage" })
                    let schema = try #require(JSONSerialization.jsonObject(with: tool.inputSchema) as? [String: Any])
                    let index = await probe.record(request, channel: (schema["properties"] as? [String: Any])?["channel"] != nil)
                    let failure = request.messages.contains { $0.role == .system && $0.text == ChannelFailureFollowUpNotice.instructions }
                    let payload = try failure
                        ? JSONEncoder().encode(["type": "text", "content": "BACKGROUND_CHANNEL_NOT_DELIVERED"])
                        : arguments ?? JSONEncoder().encode(["type": "text", "content": "EXACT_BACKGROUND_RESULT" + (numbered ? "_\(index)" : ""), "channel": "slack:C_BACKGROUND"])
                    let callID = ToolCallID(rawValue: failure ? "background-failure-correction" : "background-publication" + (numbered ? "-\(index)" : ""))
                    let result = try await executeTool(.init(id: callID,
                        name: "SendMessage", argumentsJSON: payload))
                    await probe.record(result)
                    continuation.yield(.textDelta("PRIVATE_BACKGROUND_DRAFT"))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Reviewed background direct channel publication", .serialized, .timeLimit(.minutes(1)))
@MainActor struct BackgroundDirectChannelPublicationAppTests {
    private let base = Date(timeIntervalSince1970: 1_000)
    private let id = UUID(uuidString: "36000000-0000-0000-0000-000000000001")!
    private let otherID = UUID(uuidString: "36000000-0000-0000-0000-000000000002")!
    private struct Fixture {
        let root: URL
        let model: AppModel
        let channels: ChannelService
        let probe: BackgroundChannelProbe
        let owner: AgentProfile
        let connection: ChannelConnection
        let routine: Automation
        let workflow: AgentWorkflow
        let other: Conversation
    }
    private func fixture(kind: String, scheduled: Bool = false, reviewed: Bool = true, arguments: Data? = nil,
                         supportsAttachments: Bool = true, fails: Bool = false, twoSteps: Bool = false) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-background-channel-\(UUID())")
        let profiles = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await profiles.create(name: "Original background owner", instructions: "BACKGROUND_PERSONA",
            providerID: "background-channel-fixture", modelID: "fixture", at: base)
        let routines = try AutomationService(storeURL: root.appending(path: "automations.json"))
        let savedRoutine = try await routines.save(.init(agentID: owner.id, name: "Reviewed channel routine",
            prompt: "BACKGROUND_ROUTINE_TASK", trigger: .cron(expression: "@hourly", timeZoneIdentifier: "UTC"),
            enabled: false, createdAt: base), now: base)
        let recipes = try AgentWorkflowStore(persistenceURL: root.appending(path: "workflows.json"))
        let savedWorkflow = try await recipes.create(.init(id: "background-channel", agentID: owner.id,
            name: "Reviewed channel workflow", isEnabled: false, trigger: scheduled ? .schedule("@hourly") : .manual,
            steps: [.prompt("BACKGROUND_WORKFLOW_TASK")] + (twoSteps ? [.prompt("BACKGROUND_WORKFLOW_SECOND_TASK")] : [])))
        var chat = Conversation(id: id, title: "Original background chat", providerID: owner.providerID,
            modelID: owner.modelID, messages: [.init(role: .user, text: "OWN_REVIEWED_HISTORY", createdAt: base)], updatedAt: base)
        chat.agentBinding = .init(accountID: "local", agentID: owner.id)
        chat.messages[0].remoteAttachment = try .init(url: "https://history.example/NEVER_AUTOMATICALLY_FORWARD.txt")
        let other = Conversation(id: otherID, title: "Unrelated chat", messages: [
            .init(id: otherID, role: .user, text: "UNRELATED_PRIVATE_HISTORY", createdAt: base)
        ], updatedAt: base)
        try await ConversationStore(fileURL: root.appending(path: "conversations.json")).save([chat, other])
        let probe = BackgroundChannelProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let connection = ChannelConnection(connectorID: "slack", displayName: "Original owner's connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: owner.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [BackgroundChannelConnector(supportsAttachments: supportsAttachments, fails: fails, probe: probe)])
        model.remoteAttachmentDownloader = BackgroundChannelDownloader(probe: probe)
        await model.registry.register(BackgroundChannelProvider(probe: probe, arguments: arguments, numbered: twoSteps))
        await model.bootstrap()
        await model.setAutomationRuntimeActive(false)
        model.setWorkflowRuntimeActive(false)
        if kind == "routine" { await model.setAutomationEnabled(id: savedRoutine.id, enabled: true) }
        else { await model.setWorkflowEnabled(id: savedWorkflow.id, enabled: true) }
        let routine = try #require(model.automations.first { $0.id == savedRoutine.id })
        let workflow = try #require(model.workflows.first { $0.id == savedWorkflow.id })
        try await model.loadAllMessages(for: id)
        if reviewed {
            if kind == "routine" {
                let edit = try #require(model.beginRoutineDirectSessionEdit(routine))
                try #require(await model.saveRoutineDirectSession(edit, conversationID: id, memoryAccess: .none))
            } else {
                let edit = try #require(model.beginWorkflowDirectSessionEdit(workflow))
                try #require(await model.saveWorkflowDirectSession(edit, conversationID: id, memoryAccess: .none))
            }
        }
        // Background publication must use its own chat, not the selected one.
        model.selectRoute(.conversation(otherID))
        return .init(root: root, model: model, channels: channels, probe: probe, owner: owner,
            connection: connection, routine: routine, workflow: workflow, other: other)
    }
    private func dispatch(_ f: Fixture, kind: String, scheduled: Bool = false) async throws {
        if kind == "routine" {
            if scheduled { await f.model.runAutomationScheduleTick(at: try #require(f.routine.nextRunAt)) }
            else { await f.model.runAutomationNow(id: f.routine.id) }
        } else {
            if scheduled { await f.model.runWorkflowScheduleTick(now: try #require(f.model.workflowNextRuns["@hourly"])) }
            else { await f.model.runWorkflowNow(id: f.workflow.id) }
        }
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<800 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The isolated background publication did not reach its expected boundary")
        throw AutomationDirectSessionError.unavailable
    }
    private func nextReview(_ f: Fixture, after previous: String? = nil) async throws -> PendingApproval {
        // A workflow briefly releases the chat between prompt steps. Only the
        // next captured review is this boundary; an idle chat is not completion.
        try await eventually {
            f.model.pendingAutoReviewApprovals.contains { $0.id != previous }
        }
        return try #require(f.model.pendingAutoReviewApprovals.first { $0.id != previous })
    }

    private func reopenWithoutScheduling(_ f: Fixture) async throws -> AppModel {
        // Native disabling occurs only after the captured task is finished.
        // Both definitions are disabled so bootstrap cannot create a new run.
        await f.model.setAutomationEnabled(id: f.routine.id, enabled: false)
        await f.model.setWorkflowEnabled(id: f.workflow.id, enabled: false)
        let channels = try ChannelService(storeURL: f.root.appending(path: "channels.json"))
        let reopened = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [BackgroundChannelConnector(probe: f.probe)])
        await reopened.registry.register(BackgroundChannelProvider(probe: f.probe))
        await reopened.bootstrap()
        await reopened.setAutomationRuntimeActive(false)
        reopened.setWorkflowRuntimeActive(false)
        return reopened
    }
    @Test(arguments: ["routine", "workflow"], [false, true])
    func actualBackgroundRunnerRequiresHumanPublicationApprovalAndUsesOriginalCanonicalChat(kind: String, scheduled: Bool) async throws {
        let f = try await fixture(kind: kind, scheduled: scheduled)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await f.model.setAutoReviewEnabled(true)
        let work = Task { try await dispatch(f, kind: kind, scheduled: scheduled) }
        defer { work.cancel() }
        try await eventually {
            let started = await f.probe.capabilities.count == 1
            return !f.model.pendingAutoReviewApprovals.isEmpty || started && !f.model.isConversationWorking(id)
        }
        let pending = try #require(f.model.pendingAutoReviewApprovals.first, "A reviewed background session needs its own fresh channel approval")
        let metadata = try #require(pending.action.context.metadata["agentMessage"])
        #expect(metadata.contains("EXACT_BACKGROUND_RESULT") && metadata.contains("slack:C_BACKGROUND") && metadata.contains(f.connection.displayName))
        #expect(!metadata.contains(f.connection.secretReference))
        expectNoDifference(pending.action.context.conversationID, id)
        let before = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(before, [])
        expectNoDifference(sent, [])
        // A click from the unrelated selected chat cannot approve the original.
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: pending.id))
        try await Task.sleep(for: .milliseconds(20))
        let beforeReturn = await f.channels.deliveries()
        expectNoDifference(beforeReturn, [])
        f.model.selectRoute(.conversation(id))
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: pending.id))
        try await work.value
        let deliveries = await f.channels.deliveries()
        let delivery = try #require(deliveries.first)
        expectNoDifference(deliveries.count, 1)
        expectNoDifference(delivery.outbound, .init(text: "EXACT_BACKGROUND_RESULT"))
        expectNoDifference(delivery.connectionID, f.connection.id)
        expectNoDifference(delivery.authorization?.agentID, f.owner.id)
        expectNoDifference(delivery.origin?.conversationID, id)
        expectNoDifference(delivery.origin?.senderID, id)
        expectNoDifference(delivery.origin?.senderName, f.owner.name)
        expectNoDifference(delivery.origin?.route, .directConversation)
        expectNoDifference(delivery.origin?.callID, "background-publication")
        expectNoDifference(delivery.origin?.runID, pending.fence.runID)
        let capabilities = await f.probe.capabilities
        expectNoDifference(capabilities, [true])
        let request = try #require(await f.probe.requests.first)
        expectNoDifference(request.conversationID, id)
        #expect(request.messages.contains { $0.text.contains("BACKGROUND_PERSONA") })
        #expect(request.messages.contains { $0.text.contains("OWN_REVIEWED_HISTORY") })
        #expect(!request.messages.contains { $0.text.contains("UNRELATED_PRIVATE_HISTORY") })
        #expect(request.attachmentsByMessageID.isEmpty && !request.tools.contains { $0.name == "SearchMemory" })
        if kind == "routine" {
            let run = try #require(f.model.automationHistory[f.routine.id]?.first)
            expectNoDifference(run.status, .ok)
            expectNoDifference(run.trigger, scheduled ? .schedule : .manual)
            expectNoDifference(run.id, delivery.origin?.runID)
        } else {
            let run = try #require(f.model.workflowRuns.first { $0.workflowID == f.workflow.id })
            expectNoDifference(run.status, .succeeded)
            expectNoDifference(run.origin, scheduled ? .trigger("schedule:@hourly") : .manual)
            expectNoDifference(run.id, delivery.origin?.runID)
            expectNoDifference(run.outputs, ["EXACT_BACKGROUND_RESULT"])
        }
        let results = await f.probe.results
        expectNoDifference(results.count, 1)
        #expect(results[0].wireText.contains("durably queued, not confirmed delivered"))
        #expect(results[0].wireText.contains("Saved message receipt:") && !results[0].isError)
        let saved = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let canonical = try #require(try await saved.conversation(id: id))
        let row = try #require(canonical.messages.first { $0.id == delivery.id })
        expectNoDifference(row, try #require(row.externalChannelPublication).directMessageWithAddress(from: row))
        #expect(!canonical.messages.contains { $0.text.contains("PRIVATE_BACKGROUND_DRAFT") || $0.role == .user && $0.text.contains("BACKGROUND_" ) })
        let savedOther = try await saved.conversation(id: otherID)
        expectNoDifference(savedOther, f.other)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test(arguments: ["routine", "workflow"], ["deny", "stop", "account", "consent", "definition", "persona-ABA", "saved-persona-ABA", "binding-ABA", "model-ABA", "reasoning-ABA", "hidden-ABA", "duplicate-ABA", "durable-rebind", "connection", "connector"])
    func revokedBackgroundPublicationCannotUseAnOldHumanReview(kind: String, mode: String) async throws {
        let f = try await fixture(kind: kind)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selectRoute(.conversation(id))
        let work = Task { try await dispatch(f, kind: kind) }
        defer { work.cancel() }
        try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty }
        let pending = try #require(f.model.pendingAutoReviewApprovals.first)
        let ci = try #require(f.model.conversations.firstIndex { $0.id == id })
        let original = f.model.conversations[ci]
        switch mode {
        case "stop": f.model.cancel()
        case "account": await f.model.cancelAutoReviewApprovals(nextAccountID: "other")
        case "consent":
            if kind == "routine" { await f.model.revokeRoutineDirectSession(try #require(f.model.automationDirectBindings.first)) }
            else { await f.model.revokeWorkflowDirectSession(try #require(f.model.workflowDirectBindings.first)) }
        case "definition":
            if kind == "routine" { await f.model.setAutomationEnabled(id: f.routine.id, enabled: false) }
            else { await f.model.setWorkflowEnabled(id: f.workflow.id, enabled: false) }
        case "persona-ABA":
            let ai = try #require(f.model.agents.firstIndex { $0.id == f.owner.id })
            f.model.agents[ai].instructions = "A different persona"
            f.model.agents[ai].instructions = f.owner.instructions
        case "saved-persona-ABA":
            var changed = f.owner; changed.instructions = "A different durable persona"
            #expect(await f.model.updateAgent(changed))
            #expect(await f.model.updateAgent(f.owner))
        case "binding-ABA":
            f.model.conversations[ci].agentBinding = nil
            f.model.conversations[ci].agentBinding = original.agentBinding
        case "model-ABA":
            f.model.conversations[ci].modelID = "changed"
            f.model.conversations[ci].modelID = original.modelID
        case "reasoning-ABA":
            f.model.conversations[ci].reasoningEffort = original.reasoningEffort == .low ? .high : .low
            f.model.conversations[ci].reasoningEffort = original.reasoningEffort
        case "hidden-ABA":
            f.model.conversations[ci].hiddenAt = base
            f.model.conversations[ci].hiddenAt = original.hiddenAt
        case "duplicate-ABA":
            var duplicate = Conversation(title: "Ambiguous owner", updatedAt: base)
            duplicate.agentBinding = original.agentBinding
            f.model.conversations.append(duplicate)
            f.model.conversations.removeAll { $0.id == duplicate.id }
        case "durable-rebind":
            let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
            var changed = try #require(try await store.conversation(id: id)); changed.agentBinding = nil
            try await store.upsert(changed, replacingLoadedMessageIDs: Set(changed.messages.map(\.id)), historyComplete: true)
        case "connection": try await f.channels.setConnectionEnabled(id: f.connection.id, enabled: false)
        case "connector": await f.channels.register(BackgroundChannelConnector(probe: f.probe))
        default: break
        }
        f.model.handleTranscriptCardIntent(mode == "deny" ? .rejectReview(reviewID: pending.id) : .approveReview(reviewID: pending.id))
        try await work.value
        try await eventually { !f.model.isConversationWorking(id) && f.model.pendingAutoReviewApprovals.isEmpty }
        let deliveries = await f.channels.deliveries(), sent = await f.probe.sent, capabilities = await f.probe.capabilities
        expectNoDifference(deliveries, []); expectNoDifference(sent, []); expectNoDifference(capabilities, [true])
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let canonical = try #require(try await store.conversation(id: id)), other = try await store.conversation(id: otherID)
        #expect(canonical.messages.allSatisfy { $0.externalChannelPublication == nil && !$0.text.contains("PRIVATE_BACKGROUND_DRAFT") })
        expectNoDifference(other, f.other)
        // Retired review actions cannot revive a cancelled/denied publication.
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: pending.id))
        let afterLateClick = await f.channels.deliveries()
        expectNoDifference(afterLateClick, [])
    }

    @Test(arguments: ["routine", "workflow"])
    func presenceAndUnreadUpdatesDoNotInvalidateReviewedBackgroundSender(kind: String) async throws {
        let f = try await fixture(kind: kind)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selectRoute(.conversation(id))
        let work = Task { try await dispatch(f, kind: kind) }; defer { work.cancel() }
        try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty }
        let pending = try #require(f.model.pendingAutoReviewApprovals.first)
        let ai = try #require(f.model.agents.firstIndex { $0.id == f.owner.id })
        var updated = f.model.agents[ai]
        updated.unreadCount = 9; updated.updatedAt = base.addingTimeInterval(1_000)
        #expect(await f.model.updateAgent(updated))
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: pending.id))
        try await work.value
        let queue = await f.channels.deliveries()
        expectNoDifference(queue.map(\.outbound), [.init(text: "EXACT_BACKGROUND_RESULT")])
    }

    @Test(arguments: ["routine", "workflow"], ["approve", "deny-source", "deny-send", "stop-source", "stop-send", "redirect", "deny-redirect", "unsupported"])
    func backgroundAttachmentNeedsIndependentSourceRedirectAndSendReviews(kind: String, mode: String) async throws {
        let sourceURL = "https://source.example/report.txt?signature=exact"
        let f = try await fixture(kind: kind, arguments: JSONEncoder().encode([
            "type": "attachment", "url": sourceURL, "alt": "EXACT_BACKGROUND_CAPTION", "channel": "slack:C_BACKGROUND"
        ]), supportsAttachments: mode != "unsupported")
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.remoteAttachmentDownloader = BackgroundChannelDownloader(probe: f.probe, redirect: mode == "redirect" || mode == "deny-redirect")
        await f.model.setAutoReviewEnabled(true)
        f.model.selectRoute(.conversation(id))
        let work = Task { try await dispatch(f, kind: kind) }; defer { work.cancel() }
        try await eventually {
            let started = await f.probe.capabilities.count == 1
            return !f.model.pendingAutoReviewApprovals.isEmpty || started && !f.model.isConversationWorking(id)
        }
        let captured = try PreparedAgentPublicationFile(bytes: Data("REVIEWED_BACKGROUND_ATTACHMENT".utf8), filename: "report.txt")
        if mode != "unsupported" {
            let source = try await nextReview(f)
            expectNoDifference(source.action.context.metadata["agentChannelSourceDownload"], "true")
            expectNoDifference(source.action.target, .resource(kind: "remote-attachment-source", identifier: sourceURL))
            let beforeDownloads = await f.probe.downloads, beforeQueue = await f.channels.deliveries()
            expectNoDifference(beforeDownloads, []); expectNoDifference(beforeQueue, [])
            if mode == "stop-source" { f.model.cancel() }
            f.model.handleTranscriptCardIntent(mode == "deny-source" ? .rejectReview(reviewID: source.id) : .approveReview(reviewID: source.id))
            if !["deny-source", "stop-source"].contains(mode) {
                var previous = source.id
                if mode == "redirect" || mode == "deny-redirect" {
                    let redirect = try await nextReview(f, after: previous)
                    expectNoDifference(redirect.action.context.metadata["agentChannelSourceDownload"], "true")
                    let details = try #require(redirect.action.context.metadata["agentMessage"])
                    #expect(details.contains(sourceURL) && details.contains("https://redirect.example/background.txt?signature=exact"))
                    previous = redirect.id
                    f.model.handleTranscriptCardIntent(mode == "deny-redirect" ? .rejectReview(reviewID: redirect.id) : .approveReview(reviewID: redirect.id))
                }
                if mode != "deny-redirect" {
                    let send = try await nextReview(f, after: previous)
                    expectNoDifference(send.action.context.metadata["agentChannelPublication"], "true")
                    let details = try #require(send.action.context.metadata["agentMessage"])
                    for marker in [sourceURL, captured.digest, "text/plain", "EXACT_BACKGROUND_CAPTION", "slack:C_BACKGROUND"] {
                        #expect(details.contains(marker))
                    }
                    let beforeSend = await f.channels.deliveries()
                    expectNoDifference(beforeSend, [])
                    await f.probe.replaceBytes(Data("UNREVIEWED_REPLACEMENT".utf8))
                    if mode == "stop-send" { f.model.cancel() }
                    f.model.handleTranscriptCardIntent(mode == "deny-send" ? .rejectReview(reviewID: send.id) : .approveReview(reviewID: send.id))
                }
            }
        }
        try await work.value
        let succeeds = mode == "approve" || mode == "redirect"
        let queue = await f.channels.deliveries(), downloads = await f.probe.downloads, sent = await f.probe.sent
        let metadata = ChannelAttachment(blobID: captured.digest, filename: "report.txt", mimeType: "text/plain", byteCount: Int64(captured.bytes.count))
        expectNoDifference(queue.map(\.outbound), succeeds ? [.init(text: "EXACT_BACKGROUND_CAPTION", attachments: [metadata])] : [])
        let first = try RemoteAttachmentReference(url: sourceURL, alt: "EXACT_BACKGROUND_CAPTION")
        let expectedDownloads = ["unsupported", "deny-source", "stop-source"].contains(mode) ? []
            : mode == "redirect" ? [first, try .init(url: "https://redirect.example/background.txt?signature=exact", alt: first.alt)] : [first]
        expectNoDifference(downloads, expectedDownloads)
        expectNoDifference(sent, [])
        let canonical = try #require(try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).conversation(id: id))
        expectNoDifference(canonical.messages.compactMap(\.externalChannelPublication).count, succeeds ? 1 : 0)
        if succeeds {
            let publication = try #require(canonical.messages.compactMap(\.externalChannelPublication).first)
            expectNoDifference(publication.sources, [.init(url: sourceURL, alt: "EXACT_BACKGROUND_CAPTION")])
            let bytes = try await AttachmentStore(rootURL: f.root.appending(path: "channel-attachments")).data(for:
                .init(id: captured.digest, filename: "report.txt", mimeType: "text/plain", byteCount: metadata.byteCount, kind: .document))
            expectNoDifference(bytes, captured.bytes)
        } else { #expect(!FileManager.default.fileExists(atPath: f.root.appending(path: "channel-attachments").path)) }
        let request = try #require(await f.probe.requests.first)
        #expect(request.attachmentsByMessageID.isEmpty && request.messages.allSatisfy { $0.attachments.isEmpty && $0.remoteAttachment == nil && $0.remoteImages == nil })
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty)
    }

    @Test(arguments: [false, true])
    func workflowStepsHaveFreshReviewsAndReopenDoesNotResend(scheduled: Bool) async throws {
        let f = try await fixture(kind: "workflow", scheduled: scheduled, twoSteps: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selectRoute(.conversation(id))
        let work = Task { try await dispatch(f, kind: "workflow", scheduled: scheduled) }; defer { work.cancel() }
        try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty }
        let first = try await nextReview(f)
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: first.id))
        let second = try await nextReview(f, after: first.id)
        #expect(first.id != second.id)
        expectNoDifference(first.fence.runID, second.fence.runID)
        let beforeSecond = await f.channels.deliveries()
        expectNoDifference(beforeSecond.map(\.outbound), [.init(text: "EXACT_BACKGROUND_RESULT_1")])
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: second.id))
        try await work.value
        let queue = await f.channels.deliveries()
        expectNoDifference(queue.map(\.outbound), [.init(text: "EXACT_BACKGROUND_RESULT_1"), .init(text: "EXACT_BACKGROUND_RESULT_2")])
        expectNoDifference(queue.compactMap { $0.origin?.callID }, ["background-publication-1", "background-publication-2"])
        let run = try #require(f.model.workflowRuns.first { $0.workflowID == f.workflow.id })
        expectNoDifference(run.status, .succeeded)
        expectNoDifference(run.outputs, ["EXACT_BACKGROUND_RESULT_1", "EXACT_BACKGROUND_RESULT_2"])
        expectNoDifference(queue.compactMap { $0.origin?.runID }, [run.id, run.id])
        let requests = await f.probe.requests
        #expect(requests[1].messages.contains { $0.text.contains("EXACT_BACKGROUND_RESULT_1") })
        #expect(!requests[1].messages.contains { $0.text.contains("PRIVATE_BACKGROUND_DRAFT") })
        let reopened = try await reopenWithoutScheduling(f)
        let finalRequests = await f.probe.requests, sent = await f.probe.sent, finalQueue = await f.channels.deliveries()
        expectNoDifference(String(customDumping: finalRequests), String(customDumping: requests))
        expectNoDifference(finalQueue, queue); expectNoDifference(sent, [])
        let canonical = try #require(try await ConversationStore(fileURL: f.root.appending(path: "conversations.json")).conversation(id: id))
        expectNoDifference(canonical.messages.compactMap(\.externalChannelPublication).count, 2)
        #expect(!reopened.isConversationWorking(id) && reopened.pendingAutoReviewApprovals.isEmpty)
    }

    @Test(arguments: ["routine", "workflow"])
    func backgroundQueueFailureReturnsToOriginalMemberWithoutAnotherExternalSend(kind: String) async throws {
        let f = try await fixture(kind: kind, fails: true)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selectRoute(.conversation(id))
        let work = Task { try await dispatch(f, kind: kind) }; defer { work.cancel() }
        try await eventually { !f.model.pendingAutoReviewApprovals.isEmpty }
        let review = try await nextReview(f)
        f.model.handleTranscriptCardIntent(.approveReview(reviewID: review.id))
        try await work.value
        f.model.selectRoute(.conversation(otherID))
        await f.channels.flush()
        await f.model.reconcileChannelPublications()
        await f.model.reconcileChannelFailureFollowUps()
        try await eventually {
            let count = await f.probe.requests.count, records = await f.channels.failureFollowUps()
            return count == 2 && !f.model.isConversationWorking(id) && records.first?.status == .completed
        }
        let requests = await f.probe.requests, capabilities = await f.probe.capabilities, queue = await f.channels.deliveries(), sent = await f.probe.sent
        expectNoDifference(capabilities, [true, false])
        expectNoDifference(requests.map(\.conversationID), [id, id])
        expectNoDifference(queue.count, 1); expectNoDifference(queue.first?.status, .deadLetter)
        expectNoDifference(sent, [.init(text: "EXACT_BACKGROUND_RESULT")])
        #expect(requests[1].messages.contains { $0.text == ChannelFailureFollowUpNotice.instructions })
        #expect(!requests[1].messages.contains { $0.text.contains("UNRELATED_PRIVATE_HISTORY") || $0.text.contains("PRIVATE_BACKGROUND_CREDENTIAL") })
        let store = ConversationStore(fileURL: f.root.appending(path: "conversations.json"))
        let canonical = try #require(try await store.conversation(id: id)), other = try await store.conversation(id: otherID)
        #expect(canonical.messages.contains { $0.text == "BACKGROUND_CHANNEL_NOT_DELIVERED" })
        #expect(!canonical.messages.contains { $0.text.contains("PRIVATE_BACKGROUND_DRAFT") })
        expectNoDifference(other, f.other)
        _ = try await reopenWithoutScheduling(f)
        let finalRequests = await f.probe.requests, finalSent = await f.probe.sent
        expectNoDifference(String(customDumping: finalRequests), String(customDumping: requests))
        expectNoDifference(finalSent, sent)
    }
}

private extension ExternalChannelTranscriptPublication {
    func directMessageWithAddress(from row: ChatMessage) -> ChatMessage {
        var expected = directMessage
        expected.shortAddress = row.shortAddress
        return expected
    }
}
