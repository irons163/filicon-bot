import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconAppServices
import FiliconChannels
import FiliconDomain

private actor ChannelApprovalGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var entered = false
    func hold() async {
        await withCheckedContinuation {
            continuation = $0; entered = true; observer?.resume(); observer = nil
        }
    }
    func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Approved own-channel disconnection", .timeLimit(.minutes(1)))
struct AgentChannelDisconnectionTests {
    @Test func statusToolIsScopedAndRejectsOwnerOverrides() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session()
        let tool = try #require(session.tools(for: f.owner.id).first { $0.descriptor.name == "GetChannelStatus" })
        let call = try NormalizedToolCall(id: "status", name: "GetChannelStatus", argumentsJSON: Data(#"{"platform":"slack"}"#.utf8))
        let result = try await tool.execute(call, context: f.context)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(encoded.contains("disabled"))
        #expect(!encoded.contains("PRIVATE"))
        let invalid = try NormalizedToolCall(id: "invalid", name: "GetChannelStatus", argumentsJSON: Data(#"{"platform":"slack","agent_id":"other"}"#.utf8))
        await #expect(throws: (any Error).self) { _ = try await tool.execute(invalid, context: f.context) }
        session.close()
        await #expect(throws: (any Error).self) { _ = try await tool.execute(call, context: f.context) }
    }
    private struct Snapshot: Equatable {
        var connections: [ChannelConnection]
        var inbound: [ChannelEnvelope]
        var deliveries: [ChannelDelivery]
        var failures: [ChannelFailureWake]
        init(_ service: ChannelService) async {
            connections = await service.connections(); inbound = await service.inboundEvents()
            deliveries = await service.deliveries(); failures = await service.failureWakes()
        }
    }
    private struct Fixture: Sendable {
        let root: URL
        let agents: AgentService
        let channels: ChannelService
        let owner: AgentProfile
        let peer: AgentProfile
        let own: ChannelConnection
        let other: ChannelConnection
        let unowned: ChannelConnection
        let origin = UUID()
        var file: URL { root.appending(path: "channels.json") }
        var context: ToolContext { .init(conversationID: origin) }
        func session(authorize: @escaping AgentManagementSession.ChannelAuthorizer = { _, _, _, _ in },
                     commit: AgentManagementSession.ChannelCommitter? = nil) -> AgentManagementSession {
            .init(originID: origin, agents: agents, authorize: { _, _, _, _ in },
                  channels: channels, authorizeChannel: authorize, commitChannel: commit)
        }
    }
    private let date = Date(timeIntervalSince1970: 1_000)
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-channel-approval-\(UUID())")
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let owner = try await agents.create(name: "Owner", instructions: "OWNER_PRIVATE", providerID: "fixture", modelID: "test", at: date)
        let peer = try await agents.create(name: "Peer", instructions: "PEER_PRIVATE", providerID: "fixture", modelID: "test", at: date)
        let channels = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let own = ChannelConnection(connectorID: "slack", displayName: "Own", accountLabel: "C_TEST",
            secretReference: "keychain://channels/SHARED_PRIVATE", enabled: false, agentID: owner.id)
        let other = ChannelConnection(connectorID: "slack", displayName: "Peer", accountLabel: "PEER_PRIVATE",
            secretReference: own.secretReference, enabled: false, agentID: peer.id)
        let unowned = ChannelConnection(connectorID: "discord", displayName: "Receive only",
            secretReference: "keychain://channels/unowned", enabled: false)
        for connection in [own, other, unowned] {
            try await channels.saveConnection(connection)
            try await channels.ingest(.init(connectionID: connection.id, externalEventID: "one",
                address: .init(platform: connection.connectorID, channelID: "fixture"), senderID: "sender",
                senderDisplayName: "Fixture", text: "MESSAGE_PRIVATE", timestamp: date))
            _ = try await channels.enqueue(.init(text: "SEND_PRIVATE"), to: .init(platform: connection.connectorID, channelID: "fixture"),
                connectionID: connection.id, at: date)
        }
        await channels.flush(now: date) // Disabled connections: record failed attempts without network.
        _ = try await channels.enqueue(.init(text: "PENDING_PRIVATE"), to: .init(platform: "slack", channelID: "fixture"),
            connectionID: own.id, at: date.addingTimeInterval(60))
        return .init(root: root, agents: agents, channels: channels, owner: owner, peer: peer, own: own, other: other, unowned: unowned)
    }
    private func call(platform: String = "slack", id: ToolCallID = "disconnect") throws -> NormalizedToolCall {
        try .init(id: id, name: "update_state", argumentsJSON: Data("{\"target\":\"channel\",\"action\":\"disconnect\",\"platform\":\"\(platform)\"}".utf8))
    }

    @Test func approvalRemovesOnlyOwnerRecordsAndReplaysWithoutAnotherMutation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var state = await Snapshot(f.channels)
        let session = f.session(authorize: { sender, change, _, _ in
            expectNoDifference(sender.id, f.owner.id)
            expectNoDifference(change.connectionID, f.own.id)
            expectNoDifference(change.inboundCount, 1)
            expectNoDifference(change.deliveryCount, 2)
            expectNoDifference(change.pendingDeliveryCount, 1)
            expectNoDifference(change.failureCount, 1)
            expectNoDifference(change.enabled, false)
        })
        let tool = session.tools(for: f.owner.id)[2], context = f.context
        var result: NormalizedToolResult?
        await expectDifference(state) {
            result = try await tool.execute(call(), context: context)
            state = await Snapshot(f.channels)
        } changes: {
            $0.connections.removeAll { $0.id == f.own.id }
            $0.inbound.removeAll { $0.connectionID == f.own.id }
            $0.deliveries.removeAll { $0.connectionID == f.own.id }
            $0.failures.removeAll { $0.connectionID == f.own.id }
        }
        let reply = try #require(result)
        #expect(!reply.wireText.contains("PRIVATE") && reply.wireText.contains("retained"))
        let replay = try await tool.execute(call(), context: context)
        expectNoDifference(replay, reply)
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(id: "new"), context: context) }
        await #expect(throws: AgentProfileChangeError.duplicate) { _ = try await tool.execute(call(platform: "discord"), context: context) }
        let restored = await Snapshot(try ChannelService(storeURL: f.file))
        expectNoDifference(restored, state)
        await #expect(throws: ChannelDisconnectionError.unavailable) {
            _ = try await f.session().tools(for: f.owner.id)[2].execute(call(), context: f.context)
        }
    }

    @Test(arguments: [false, true])
    func disconnectionDoesNotSelectAnotherAccountsConnection(onlyForeign: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var foreign = f.other
        foreign.agentID = f.owner.id
        foreign.ownerAccountID = "other-account"
        try await f.channels.saveConnection(foreign)
        if onlyForeign { try await f.channels.removeConnection(id: f.own.id) }
        let session = f.session(authorize: { _, change, _, _ in
            #expect(!onlyForeign)
            expectNoDifference(change.ownerAccountID, "local")
            expectNoDifference(change.connectionID, f.own.id)
        })
        let tool = session.tools(for: f.owner.id)[2]
        if onlyForeign {
            await #expect(throws: ChannelDisconnectionError.unavailable) {
                _ = try await tool.execute(call(), context: f.context)
            }
        } else {
            _ = try await tool.execute(call(), context: f.context)
        }
        let remaining = await f.channels.connections()
        #expect(remaining.contains(foreign))
        let foreignProposal = try await f.channels.proposeDisconnection(agentID: f.owner.id, platform: "slack", accountID: "other-account")
        expectNoDifference(foreignProposal.connectionID, foreign.id)
    }

    @Test func approvalIsIndependentAndFieldsCannotChoosePeersOrCredentials() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = await Snapshot(f.channels)
        let denied = AgentManagementSession(originID: f.origin, agents: f.agents, authorize: { _, _, _, _ in }, channels: f.channels)
        await #expect(throws: AgentMessagingError.approvalRequired) {
            _ = try await denied.tools(for: f.owner.id)[2].execute(call(), context: f.context)
        }
        let tool = f.session().tools(for: f.owner.id)[2]
        for json in [
            #"{"target":"channel","action":"disconnect","platform":"Slack"}"#,
            #"{"target":"channel","action":"disconnect","platform":"telegram"}"#,
            #"{"target":"channel","action":"delete","platform":"slack"}"#,
            #"{"target":"channel","action":"disconnect","platform":true}"#,
            #"{"target":"channel","action":"disconnect","platform":"slack","id":"spoof"}"#,
            #"{"target":"channel","action":"disconnect","platform":"slack","agent_id":"spoof"}"#,
            #"{"target":"channel","action":"disconnect","platform":"slack","secretReference":"spoof"}"#,
            #"{"target":"channel","action":"disconnect"}"#,
            "{\"target\":\"channel\",\"action\":\"disconnect\",\"platform\":\"" + String(repeating: "x", count: 4_096) + "\"}"
        ] {
            await #expect(throws: ChannelDisconnectionError.invalid) {
                _ = try await tool.execute(.init(id: "invalid", name: "update_state", argumentsJSON: Data(json.utf8)), context: f.context)
            }
        }
        await #expect(throws: ChannelDisconnectionError.unavailable) {
            _ = try await tool.execute(call(platform: "discord"), context: f.context)
        }
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(call(), context: .init(conversationID: UUID()))
        }
        let after = await Snapshot(f.channels); expectNoDifference(after, before)
    }

    @Test func multipleOwnConnectionsAreAmbiguousAndNeverBulkRemoved() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var extra = f.other; extra.agentID = f.owner.id
        try await f.channels.saveConnection(extra)
        let before = await Snapshot(f.channels)
        await #expect(throws: ChannelDisconnectionError.ambiguous) {
            _ = try await f.session().tools(for: f.owner.id)[2].execute(call(), context: f.context)
        }
        let after = await Snapshot(f.channels); expectNoDifference(after, before)
    }

    @Test(arguments: ["configuration", "aba", "recreate", "inbound", "queue", "close", "cancel", "archive"])
    func pendingApprovalCannotOutliveAuthorityOrReviewedState(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelApprovalGate()
        let session = f.session(authorize: { _, _, _, _ in await gate.hold() })
        let task = Task { try await session.tools(for: f.owner.id)[2].execute(call(), context: f.context) }
        await gate.wait()
        switch mode {
        case "configuration":
            var value = f.own; value.accountLabel = "changed"; try await f.channels.saveConnection(value)
        case "aba":
            try await f.channels.setConnectionEnabled(id: f.own.id, enabled: true)
            try await f.channels.setConnectionEnabled(id: f.own.id, enabled: false)
        case "recreate":
            try await f.channels.removeConnection(id: f.own.id); try await f.channels.saveConnection(f.own)
        case "inbound":
            try await f.channels.ingest(.init(connectionID: f.own.id, externalEventID: "two",
                address: .init(platform: "slack", channelID: "fixture"), senderID: "sender", senderDisplayName: "Fixture", text: "new", timestamp: date))
        case "queue":
            _ = try await f.channels.enqueue(.init(text: "new"), to: .init(platform: "slack", channelID: "fixture"), connectionID: f.own.id, at: date)
        case "close": session.close()
        case "cancel": task.cancel()
        default: try await f.agents.archive(id: f.owner.id, at: date)
        }
        let before = await Snapshot(f.channels)
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        let after = await Snapshot(f.channels); expectNoDifference(after, before)
    }

    @Test func failedSavePreservesProposalAndStateWithoutReceipt() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let change = try await f.channels.proposeDisconnection(agentID: f.owner.id, platform: "slack")
        let lifetime = ChannelDisconnectionLifetime(), before = await Snapshot(f.channels)
        let backup = f.root.appending(path: "backup.json")
        try FileManager.default.moveItem(at: f.file, to: backup)
        try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await f.channels.applyDisconnection(change, lifetime: lifetime) }
        #expect(!lifetime.committed(change))
        let after = await Snapshot(f.channels); expectNoDifference(after, before)
        try FileManager.default.removeItem(at: f.file)
        try FileManager.default.moveItem(at: backup, to: f.file)
        try await f.channels.applyDisconnection(change, lifetime: lifetime)
        #expect(lifetime.committed(change))
    }

    @Test func closeDuringDelayedCommitCannotWrite() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = ChannelApprovalGate(), before = await Snapshot(f.channels)
        let session = f.session(commit: { change, lifetime in
            await gate.hold(); try await f.channels.applyDisconnection(change, lifetime: lifetime)
        })
        let task = Task { try await session.tools(for: f.owner.id)[2].execute(call(), context: f.context) }
        await gate.wait(); session.close(); await gate.release()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        let after = await Snapshot(f.channels); expectNoDifference(after, before)
    }

    @Test func durableReceiptSurvivesLaterFailureAndSharesFourChangeBudget() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = f.session(commit: { change, lifetime in
            try await f.channels.applyDisconnection(change, lifetime: lifetime)
            lifetime.close(); throw CancellationError()
        })
        let result = try await session.tools(for: f.owner.id)[2].execute(call(), context: f.context)
        #expect(result.wireText.contains("Disconnected"))
        for i in 0..<3 {
            _ = try await session.tools(for: f.owner.id)[0].execute(.init(id: .init(rawValue: "create-\(i)"), name: "CreateAgent",
                argumentsJSON: Data("{\"name\":\"Teammate \(i)\"}".utf8)), context: f.context)
        }
        await #expect(throws: AgentProfileChangeError.limitReached) {
            _ = try await session.tools(for: f.owner.id)[0].execute(.init(id: "extra", name: "CreateAgent",
                argumentsJSON: Data(#"{"name":"Fifth"}"#.utf8)), context: f.context)
        }
    }

    @Test func concurrentDuplicateCannotRemoveAnotherConnectionAndDeniedProposalCanRetry() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let discord = ChannelConnection(connectorID: "discord", displayName: "Own Discord",
            secretReference: "keychain://channels/discord", enabled: false, agentID: f.owner.id)
        try await f.channels.saveConnection(discord)
        let gate = ChannelApprovalGate()
        let session = f.session(authorize: { _, _, call, _ in
            if call.id == "first" { await gate.hold(); throw AgentMessagingError.approvalRequired }
        })
        let tool = session.tools(for: f.owner.id)[2], context = f.context
        let task = Task { try await tool.execute(call(platform: "discord", id: "first"), context: context) }
        await gate.wait()
        for id: ToolCallID in ["first", "second"] {
            await #expect(throws: AgentProfileChangeError.duplicate) {
                _ = try await tool.execute(call(platform: "discord", id: id), context: context)
            }
        }
        let before = await Snapshot(f.channels)
        await gate.release()
        await #expect(throws: AgentMessagingError.approvalRequired) { _ = try await task.value }
        let afterDenial = await Snapshot(f.channels); expectNoDifference(afterDenial, before)
        let result = try await tool.execute(call(platform: "discord", id: "retry"), context: context)
        #expect(result.wireText.contains(discord.id.uuidString))
        var after = await Snapshot(f.channels)
        // Both the unassigned Discord connection and peer-owned Slack survive.
        after.connections.append(discord)
        after.connections.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        expectNoDifference(after, before)
    }

    @Test func schemaAndRuntimeExplainDisconnectionBoundaries() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let tool = f.session().tools(for: f.owner.id)[2]
        let json = try #require(JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(json["properties"] as? [String: Any])
        #expect(properties["platform"] != nil)
        #expect(tool.descriptor.description?.contains("multiple connections") == true)
        let context = try await #require(tool as? any ToolRuntimeContextProviding).runtimeContext(for: f.context)
        #expect(context.contains("Own channel:") && context.contains("Keychain credentials are retained"))
        #expect(!context.contains(f.other.id.uuidString) && !context.contains("PEER_PRIVATE"))
    }
}
