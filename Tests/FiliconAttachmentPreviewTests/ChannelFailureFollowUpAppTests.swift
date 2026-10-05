import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconChannels
import FiliconDomain
import FiliconProviderKit
@testable import Filicon

private actor ChannelFailureProbe {
    var requests: [InferenceRequest] = []
    var sends: [ChannelOutbound] = []
    var results: [NormalizedToolResult] = []
    var attemptedTools = 0
    var toolFailures = 0
    var protocolRejections: [ToolLoopError] = []
    func request(_ value: InferenceRequest) { requests.append(value) }
    func send(_ value: ChannelOutbound) { sends.append(value) }
    func result(_ value: NormalizedToolResult) { results.append(value) }
    func attempted() { attemptedTools += 1 }
    func failed() { toolFailures += 1 }
    func rejected(_ error: ToolLoopError) { protocolRejections.append(error) }
}

private actor ChannelFailureGate {
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

private struct FailedChannelConnector: ChannelConnector {
    let descriptor = ChannelConnectorDescriptor(id: "slack", displayName: "Offline failure fixture")
    let probe: ChannelFailureProbe
    func inbound(connection: ChannelConnection) -> AsyncThrowingStream<ChannelEnvelope, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func send(_ message: ChannelOutbound, to address: ChannelAddress,
              connection: ChannelConnection, idempotencyKey: UUID) async throws {
        await probe.send(message)
        throw ChannelServiceError.authExpired("PRIVATE_CONNECTOR_TOKEN never belongs in a model request")
    }
}

private struct ChannelFailureProvider: InteractiveToolProvider {
    enum Behavior { case correction, privateText, silence, fail, externalAttempt }
    var supportsTools = true
    var descriptor: ProviderDescriptor {
        .init(id: "channel-failure-fixture", displayName: "Offline failure follow-up",
            requiresAPIKey: false, supportsToolCalling: supportsTools)
    }
    let probe: ChannelFailureProbe
    var behavior: Behavior = .correction
    var gate: ChannelFailureGate?
    func models() async throws -> [AIModel] { [.init(id: "fixture")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.transport("Wrong runner")) }
    }
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await probe.request(request)
                    // Deliberately allow a late callback after cancellation:
                    // the host, not a cooperative provider, must fence it.
                    await gate?.wait()
                    if behavior == .fail { throw ProviderError.transport("Offline failure follow-up fixture") }
                    if behavior == .externalAttempt {
                        await probe.attempted()
                        let result = try await executeTool(.init(id: "forbidden-retry", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(["type": "text", "content": "FORBIDDEN_EXTERNAL_RETRY", "channel": "slack:C_ORIGINAL"])))
                        await probe.result(result)
                    }
                    if behavior == .correction || behavior == .externalAttempt {
                        await probe.attempted()
                        let result = try await executeTool(.init(id: "failure-correction", name: "SendMessage",
                            argumentsJSON: JSONEncoder().encode(["type": "text", "content": "That Slack message was not delivered. Reconnect before any newly approved send."])))
                        await probe.result(result)
                    }
                    if behavior != .silence { continuation.yield(.textDelta("PRIVATE_FAILURE_DRAFT")) }
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch {
                    if let protocolError = error as? ToolLoopError { await probe.rejected(protocolError) }
                    await probe.failed(); continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("Original direct member channel failure follow-up", .timeLimit(.minutes(1)))
@MainActor struct ChannelFailureFollowUpAppTests {
    private let date = Date(timeIntervalSince1970: 1_900_000_000)
    private let conversationID = UUID(uuidString: "38000000-0000-0000-0000-000000000001")!

    private struct Fixture {
        let root: URL
        let model: AppModel
        let store: ConversationStore
        let owner: AgentProfile
        let other: Conversation
        let channels: ChannelService
        let connector: FailedChannelConnector
        let probe: ChannelFailureProbe
        let proposal: ChannelPublication
        let queued: ChannelDelivery
    }

    private func fixture(terminalBeforeBootstrap: Bool = true, route: ChannelDeliveryOrigin.Route = .directConversation,
                         behavior: ChannelFailureProvider.Behavior = .correction, gate: ChannelFailureGate? = nil,
                         memoryMode: String? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-failure-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Original owner", instructions: "FAILURE_ORIGINAL_PERSONA",
            providerID: "channel-failure-fixture", modelID: "fixture", at: date)
        if let memoryMode {
            let suggestions = try await agents.memorySuggestions(accountID: "local", agentID: owner.id)
            try await agents.setMemorySuggestionsEnabled(true, expected: suggestions.settings, lifetime: .init())
            if memoryMode == "episodes" {
                let episodes = try await agents.memoryEpisodeSettings(accountID: "local", agentID: owner.id)
                try await agents.setMemoryEpisodesEnabled(true, expected: episodes, lifetime: .init())
            } else {
                let synthesis = try await agents.memorySynthesisSettings(accountID: "local", agentID: owner.id)
                try await agents.setMemorySynthesisEnabled(true, expected: synthesis, lifetime: .init())
            }
        }
        var original = Conversation(id: conversationID, title: "Original", providerID: owner.providerID,
            modelID: owner.modelID, messages: [.init(role: .user, text: "ORIGINAL_REVIEWED_HISTORY", createdAt: date)], updatedAt: date)
        original.agentBinding = .init(accountID: "local", agentID: owner.id)
        let other = Conversation(id: UUID(uuidString: "38000000-0000-0000-0000-000000000002")!, title: "Unrelated",
            messages: [.init(id: UUID(uuidString: "38000000-0000-0000-0000-000000000003")!,
                             role: .user, text: "OTHER_CHAT_PRIVATE_HISTORY", createdAt: date)], updatedAt: date)
        let store = ConversationStore(fileURL: root.appending(path: "conversations.json"))
        try await store.save([original, other])
        let probe = ChannelFailureProbe(), channels = try ChannelService(storeURL: root.appending(path: "channels.json"),
            newDeliveryID: { UUID(uuidString: "38000000-0000-0000-0000-000000000004")! })
        let connector = FailedChannelConnector(probe: probe)
        await channels.register(connector)
        let connection = ChannelConnection(connectorID: "slack", displayName: "Own connection",
            secretReference: "keychain://channels/TEST-only-never-read", agentID: owner.id, ownerAccountID: "local")
        try await channels.saveConnection(connection)
        let proposal = try await channels.proposePublication(agentID: owner.id, accountID: "local",
            outbound: .init(text: "Original reviewed outbound"), to: .init(platform: "slack", channelID: "C_ORIGINAL"))
        let queued = try await channels.enqueueApprovedPublication(proposal, lifetime: .init(),
            idempotencyKey: UUID(uuidString: "38000000-0000-0000-0000-000000000005")!, at: date,
            origin: .init(route: route, conversationID: conversationID,
                senderID: route == .directConversation ? conversationID : owner.id,
                senderName: owner.name, runID: UUID(uuidString: "38000000-0000-0000-0000-000000000006")!,
                callID: "reviewed-original-send", intent: .init(kind: .text, text: proposal.outbound.text)))
        if terminalBeforeBootstrap { await channels.flush(now: date) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false,
            channelService: channels, channelConnectors: [connector])
        await model.registry.register(ChannelFailureProvider(probe: probe, behavior: behavior, gate: gate))
        await model.bootstrap()
        return .init(root: root, model: model, store: store, owner: owner, other: other,
            channels: channels, connector: connector, probe: probe, proposal: proposal, queued: queued)
    }

    private func deliverFailure(_ f: Fixture) async {
        await f.channels.flush(now: date)
        await f.model.reconcileChannelPublications()
        await f.model.reconcileChannelFailureFollowUps()
    }

    private func waitUntil(_ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try await condition(), "The isolated runner must settle rather than leave a spinner")
    }

    private func waitForCompletion(_ f: Fixture) async throws {
        try await waitUntil {
            let records = await f.channels.failureFollowUps()
            return records.count == 1 && records[0].status != .running && !f.model.isConversationWorking(conversationID)
        }
    }

    @Test func terminalFailureWakesOriginalBoundDirectRunnerWithoutResending() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try await waitForCompletion(f)
        let requests = await f.probe.requests
        #expect(requests.count == 1, "A terminal failure must reach the original bound member's shared runner")
        guard let request = requests.first else { return }
        expectNoDifference(request.conversationID, conversationID)
        #expect(request.messages.first?.text.contains("FAILURE_ORIGINAL_PERSONA") == true)
        #expect(request.messages.contains { $0.text.contains("ORIGINAL_REVIEWED_HISTORY") })
        #expect(!request.messages.contains { $0.text.contains("OTHER_CHAT_PRIVATE_HISTORY") || $0.text.contains("PRIVATE_CONNECTOR_TOKEN") })
        #expect(request.messages.contains { $0.role == .system && $0.text == ChannelFailureFollowUpNotice.instructions })
        #expect(request.messages.last?.text.contains("was not delivered") == true)
        let saved = try #require(try await f.store.conversation(id: conversationID))
        #expect(saved.messages.contains { $0.role == .assistant && $0.text.hasPrefix("That Slack message was not delivered.") })
        #expect(!saved.messages.contains { $0.text == "PRIVATE_FAILURE_DRAFT" })
        #expect(!saved.messages.contains { $0.role == .user && $0.text.contains("Host failure facts") })
        let terminal = try #require(await f.channels.delivery(id: f.queued.id))
        expectNoDifference(terminal.status, .deadLetter)
        let sends = await f.probe.sends, deliveries = await f.channels.deliveries(), records = await f.channels.failureFollowUps()
        expectNoDifference(sends, [f.proposal.outbound]); expectNoDifference(deliveries, [terminal])
        expectNoDifference(records.first?.status, .completed)
        let unrelated = try #require(try await f.store.conversation(id: f.other.id)); expectNoDifference(unrelated, f.other)
    }

    @Test(arguments: ["busy", "unselected", "off-page"])
    func originalOwnerIsDeferredOrRestoredWithoutRetargeting(mode: String) async throws {
        let f = try await fixture(terminalBeforeBootstrap: false)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selection = f.other.id
        if mode == "busy" { f.model.running.insert(conversationID) }
        if mode == "off-page" { f.model.conversations.removeAll { $0.id == conversationID } }
        await deliverFailure(f)
        if mode == "busy" {
            let unclaimed = await f.channels.failureFollowUps(), requests = await f.probe.requests
            expectNoDifference(unclaimed, []); expectNoDifference(requests.count, 0)
            f.model.running.remove(conversationID)
            await f.model.reconcileChannelFailureFollowUps()
        }
        try await waitForCompletion(f)
        let requests = await f.probe.requests
        expectNoDifference(requests.count, 1); expectNoDifference(requests.first?.conversationID, conversationID)
        expectNoDifference(f.model.selection, f.other.id)
        let other = try #require(try await f.store.conversation(id: f.other.id)); expectNoDifference(other, f.other)
        for _ in 0..<3 { await f.model.reconcileChannelFailureFollowUps() }
        let restored = try ChannelService(storeURL: f.root.appending(path: "channels.json"), now: { Date(timeIntervalSince1970: 1_900_000_100) })
        let reopened = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false,
            channelService: restored, channelConnectors: [f.connector])
        await reopened.registry.register(ChannelFailureProvider(probe: f.probe))
        await reopened.bootstrap(); await reopened.reconcileChannelFailureFollowUps()
        let finalRequests = await f.probe.requests, sends = await f.probe.sends
        expectNoDifference(finalRequests.count, requests.count); expectNoDifference(sends, [f.proposal.outbound])
    }

    @Test(arguments: ["foreign-account", "hidden", "unbound", "ambiguous", "archived", "no-tools", "group", "deleted"])
    func unavailableOriginalRecipientNeverFallsBackToSelectedChat(mode: String) async throws {
        let f = try await fixture(terminalBeforeBootstrap: false, route: mode == "group" ? .groupConversation : .directConversation)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selection = f.other.id
        let index = try #require(f.model.conversations.firstIndex { $0.id == conversationID })
        switch mode {
        case "foreign-account": f.model.settings.accountScope = "foreign-fixture"
        case "hidden": f.model.conversations[index].hiddenAt = date
        case "unbound": f.model.conversations[index].agentBinding = nil
        case "ambiguous":
            var duplicate = Conversation(title: "Ambiguous", updatedAt: date)
            duplicate.agentBinding = .init(accountID: "local", agentID: f.owner.id)
            try await f.store.upsert(duplicate, replacingLoadedMessageIDs: [], historyComplete: true)
            f.model.conversations.append(duplicate)
        case "archived": await f.model.archiveAgent(id: f.owner.id)
        case "no-tools": await f.model.registry.register(ChannelFailureProvider(supportsTools: false, probe: f.probe))
        case "deleted": f.model.deleteConversation(id: conversationID)
        default: break
        }
        await deliverFailure(f)
        for _ in 0..<3 { await f.model.reconcileChannelFailureFollowUps() }
        let records = await f.channels.failureFollowUps(), requests = await f.probe.requests, sends = await f.probe.sends
        expectNoDifference(records, []); expectNoDifference(requests.count, 0); expectNoDifference(sends, [f.proposal.outbound])
        #expect(!f.model.isConversationWorking(conversationID))
        let other = try #require(try await f.store.conversation(id: f.other.id)); expectNoDifference(other, f.other)
    }

    @Test(arguments: ["stop", "account-ABA", "binding-ABA", "provider-ABA", "model-ABA", "reasoning-ABA", "hidden-ABA", "sidebar-hide-ABA", "persona-ABA", "saved-persona-ABA", "archive-restore", "duplicate-ABA", "durable-rebind", "acknowledge"])
    func revokedWakeRejectsLateProviderPublicationAndCannotReplay(mode: String) async throws {
        let gate = ChannelFailureGate()
        defer { Task { await gate.open() } }
        let f = try await fixture(terminalBeforeBootstrap: false, gate: gate)
        defer { try? FileManager.default.removeItem(at: f.root) }
        f.model.selection = conversationID
        await deliverFailure(f)
        try await waitUntil { await gate.isWaiting }
        let index = try #require(f.model.conversations.firstIndex { $0.id == conversationID })
        let original = f.model.conversations[index]
        switch mode {
        case "stop": f.model.cancel()
        case "account-ABA":
            await f.model.cancelAutoReviewApprovals(nextAccountID: "foreign-fixture")
            f.model.settings.accountScope = "foreign-fixture"
            await f.model.cancelAutoReviewApprovals(nextAccountID: "local"); f.model.settings.accountScope = "local"
        case "binding-ABA":
            f.model.conversations[index].agentBinding = nil; f.model.conversations[index].agentBinding = original.agentBinding
        case "provider-ABA": f.model.conversations[index].providerID = "away"; f.model.conversations[index].providerID = original.providerID
        case "model-ABA": f.model.conversations[index].modelID = "away"; f.model.conversations[index].modelID = original.modelID
        case "reasoning-ABA": f.model.conversations[index].reasoningEffort = .high; f.model.conversations[index].reasoningEffort = original.reasoningEffort
        case "hidden-ABA": f.model.conversations[index].hiddenAt = date; f.model.conversations[index].hiddenAt = nil
        case "sidebar-hide-ABA":
            #expect(await f.model.saveBoundConversationVisibility(id: conversationID, hidden: true))
            #expect(await f.model.saveBoundConversationVisibility(id: conversationID, hidden: false))
        case "persona-ABA":
            let ai = try #require(f.model.agents.firstIndex { $0.id == f.owner.id })
            let instructions = f.model.agents[ai].instructions
            f.model.agents[ai].instructions = "Changed persona"; f.model.agents[ai].instructions = instructions
        case "saved-persona-ABA":
            var profile = f.owner; profile.instructions = "Changed saved persona"
            #expect(await f.model.updateAgent(profile)); #expect(await f.model.updateAgent(f.owner))
        case "archive-restore": await f.model.archiveAgent(id: f.owner.id); await f.model.restoreAgent(id: f.owner.id)
        case "duplicate-ABA":
            var duplicate = Conversation(title: "Ambiguous", updatedAt: date); duplicate.agentBinding = original.agentBinding
            f.model.conversations.append(duplicate); f.model.conversations.removeAll { $0.id == duplicate.id }
        case "durable-rebind":
            var rebound = try #require(try await f.store.conversation(id: conversationID))
            rebound.agentBinding = .init(accountID: "local", agentID: UUID(uuidString: "38000000-0000-0000-0000-000000000099")!)
            try await f.store.upsert(rebound, replacingLoadedMessageIDs: Set(rebound.messages.map(\.id)), historyComplete: true)
        case "acknowledge":
            let wake = try #require(await f.channels.failureWakes().first)
            await f.model.acknowledgeChannelFailure(id: wake.id)
        default: break
        }
        await gate.open()
        try await waitForCompletion(f)
        try await waitUntil { await f.probe.attemptedTools == 1 }
        let requests = await f.probe.requests, results = await f.probe.results, records = await f.channels.failureFollowUps()
        expectNoDifference(requests.count, 1); expectNoDifference(records.first?.status, .cancelled)
        #expect(results.allSatisfy { $0.isError })
        let canonical = try #require(try await f.store.conversation(id: conversationID))
        #expect(!canonical.messages.contains { $0.text.hasPrefix("That Slack message was not delivered.") || $0.text == "PRIVATE_FAILURE_DRAFT" })
        for _ in 0..<3 { await f.model.reconcileChannelFailureFollowUps() }
        let finalRequests = await f.probe.requests, sends = await f.probe.sends
        expectNoDifference(finalRequests.count, requests.count); expectNoDifference(sends, [f.proposal.outbound])
        let other = try #require(try await f.store.conversation(id: f.other.id)); expectNoDifference(other, f.other)
    }

    @Test(arguments: [ChannelFailureProvider.Behavior.privateText, .silence, .fail, .externalAttempt])
    fileprivate func privateOrFailedDraftSettlesAndNeverGrantsExternalRetry(behavior: ChannelFailureProvider.Behavior) async throws {
        let f = try await fixture(behavior: behavior); defer { try? FileManager.default.removeItem(at: f.root) }
        try await waitForCompletion(f)
        let records = await f.channels.failureFollowUps(), requests = await f.probe.requests, results = await f.probe.results
        expectNoDifference(records.first?.status, behavior == .fail || behavior == .externalAttempt ? .failed : .completed)
        expectNoDifference(requests.count, 1)
        let tool = try #require(requests.first?.tools.first { $0.name == "SendMessage" })
        let schema = try #require(JSONSerialization.jsonObject(with: tool.inputSchema) as? [String: Any])
        #expect((schema["properties"] as? [String: Any])?["channel"] == nil)
        let canonical = try #require(try await f.store.conversation(id: conversationID))
        #expect(!canonical.messages.contains { $0.text == "PRIVATE_FAILURE_DRAFT" || $0.text == "FORBIDDEN_EXTERNAL_RETRY" })
        if behavior == .externalAttempt {
            // The schema rejects this unsupported destination before any host
            // executor runs. A protocol error ends the interactive turn; it is
            // not an executor's normal error result or a successful correction.
            let rejections = await f.probe.protocolRejections, attempts = await f.probe.attemptedTools
            expectNoDifference(rejections, [.schemaMismatch(callID: "forbidden-retry", detail: "unknown property 'channel'")])
            expectNoDifference(attempts, 1); expectNoDifference(results, [])
            #expect(!canonical.messages.contains { $0.text.hasPrefix("That Slack message was not delivered.") })
        }
        let agentState = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.root.appending(path: "agents.json"))) as? [String: Any])
        #expect(try #require(agentState["memoryEpisodes"] as? [Any]).isEmpty)
        #expect(try #require(agentState["memorySuggestions"] as? [Any]).isEmpty)
        #expect(f.model.pendingAutoReviewApprovals.isEmpty && f.model.pendingToolApprovals.isEmpty)
        await f.channels.flush(now: date.addingTimeInterval(1_000))
        for _ in 0..<3 { await f.model.reconcileChannelFailureFollowUps() }
        let sends = await f.probe.sends, finalRequests = await f.probe.requests
        expectNoDifference(sends, [f.proposal.outbound]); expectNoDifference(finalRequests.count, requests.count)
    }

    @Test(arguments: ["episodes", "synthesis"])
    func failureNoticeDoesNotCollectMemoryEvenWhenHumanEnabledIt(mode: String) async throws {
        let f = try await fixture(memoryMode: mode); defer { try? FileManager.default.removeItem(at: f.root) }
        try await waitForCompletion(f)
        let state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.root.appending(path: "agents.json"))) as? [String: Any])
        for key in ["memoryEpisodes", "memorySuggestions", "memorySuggestionReceipts", "memoryTemporalReviews", "memories"] {
            #expect(try #require(state[key] as? [Any]).isEmpty, "A host failure wake must not become human memory evidence: \(key)")
        }
        let suggestions = try #require(state["memorySuggestionSettings"] as? [[String: Any]])
        #expect(suggestions.first?["enabled"] as? Bool == true)
        let memorySettings = try #require(state[mode == "episodes" ? "memoryEpisodeSettings" : "memorySynthesisSettings"] as? [[String: Any]])
        #expect(memorySettings.first?["enabled"] as? Bool == true)
        let requests = await f.probe.requests, sends = await f.probe.sends
        expectNoDifference(requests.count, 1); expectNoDifference(sends, [f.proposal.outbound])
        let canonical = try #require(try await f.store.conversation(id: conversationID))
        expectNoDifference(canonical.messages.filter { $0.role == .user }.map(\.text), ["ORIGINAL_REVIEWED_HISTORY"])
        #expect(canonical.messages.contains { $0.text.hasPrefix("That Slack message was not delivered.") })
    }

    @Test func presenceAndUnreadChangesDoNotRevokeOriginalPersona() async throws {
        let gate = ChannelFailureGate(); defer { Task { await gate.open() } }
        let f = try await fixture(terminalBeforeBootstrap: false, gate: gate)
        defer { try? FileManager.default.removeItem(at: f.root) }
        await deliverFailure(f); try await waitUntil { await gate.isWaiting }
        let index = try #require(f.model.agents.firstIndex { $0.id == f.owner.id })
        f.model.agents[index].status = .running; f.model.agents[index].unreadCount = 5
        f.model.agents[index].updatedAt = date.addingTimeInterval(10)
        await gate.open(); try await waitForCompletion(f)
        let records = await f.channels.failureFollowUps(), sends = await f.probe.sends
        expectNoDifference(records.first?.status, .completed); expectNoDifference(sends, [f.proposal.outbound])
        let canonical = try #require(try await f.store.conversation(id: conversationID))
        #expect(canonical.messages.contains { $0.text.hasPrefix("That Slack message was not delivered.") })
    }
}
