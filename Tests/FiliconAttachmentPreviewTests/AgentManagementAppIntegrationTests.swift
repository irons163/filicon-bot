import AppKit
import SwiftUI
import Foundation
import Testing
import CustomDump
@testable import Filicon
import FiliconAgents
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview
import FiliconAutomations
import FiliconChannels
import FiliconAppServices

private struct ManagingAgentProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "management-fixture", displayName: "Profile fixture", requiresAPIKey: false)
    let run: @Sendable (InferenceRequest, @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) async throws -> String
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.textDelta(try await run(request, executeTool)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor ManagementWakeProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) { requests.append(request) }
}

@Suite("Agent profile tools app integration", .timeLimit(.minutes(1)))
@MainActor struct AgentManagementAppIntegrationTests {
    private func fixture() async throws -> (URL, AppModel, UUID, AgentProfile, AgentProfile) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-profile-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let sender = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "ENGINEER_PRIVATE_PERSONA",
                                                          providerID: "management-fixture", modelID: "test"))
        let target = try #require(await model.createAgent(name: "Designer", summary: "Visual review", instructions: "DESIGNER_PRIVATE_PERSONA",
                                                          providerID: "management-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Implementation", summary: "", memberIDs: [sender.id]))
        await model.reloadWorkspaceData()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["CreateAgent", "UpdateAgent", "update_state", "SendToAgent"], ask: [])
        return (root, model, try #require(model.groups.first?.id), sender, target)
    }
    private func pending(_ model: AppModel, tool: String) async throws -> PendingApproval {
        for _ in 0..<1_000 {
            if let value = model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["tool"] == tool }) { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No \(tool) approval appeared")
    }
    private func waitForMailbox(_ model: AppModel) async throws {
        for _ in 0..<1_000 {
            if model.runningAgentMessageScopes.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("Mailbox execution did not finish")
    }
    private func channelFixture(mailbox: Bool = false) async throws -> (URL, AppModel, UUID, AgentProfile, AgentProfile, ChannelConnection, ChannelConnection) {
        let (root, _, groupID, sender, recipient) = try await fixture()
        let owner = mailbox ? recipient : sender
        let peer = mailbox ? sender : recipient
        let service = try ChannelService(storeURL: root.appending(path: "channels.json"))
        let own = ChannelConnection(connectorID: "slack", displayName: "Workspace connection", accountLabel: "C_FIXTURE",
            secretReference: "keychain://channels/SECRET_MARKER", enabled: false, agentID: owner.id)
        let other = ChannelConnection(connectorID: "slack", displayName: "PEER_CHANNEL_MARKER",
            secretReference: own.secretReference, enabled: false, agentID: peer.id)
        try await service.saveConnection(own); try await service.saveConnection(other)
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadWorkspaceData()
        return (root, model, groupID, sender, recipient, own, other)
    }

    private func storedProjects(_ root: URL) throws -> [AgentProject] {
        struct Saved: Decodable { let projects: [AgentProject]? }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Saved.self, from: Data(contentsOf: root.appending(path: "agents.json"))).projects ?? []
    }

    private func projectMemoryFixture() async throws -> (URL, AppModel, UUID, AgentProfile, AgentProfile) {
        let (root, _, group, owner, peer) = try await fixture()
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        for agent in [owner, peer] {
            let change = try await agents.proposeProjectChange(accountID: "local", agentID: agent.id, action: .create,
                slug: "website", name: "Public website")
            try await agents.applyProjectChange(change, lifetime: .init())
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadWorkspaceData()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["update_state"], ask: [])
        return (root, model, group, owner, peer)
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "archive", "save-failure"])
    func projectMemoryRequiresExplicitApprovalAndKeepsPrivateScopes(mode: String) async throws {
        let (root, model, group, owner, peer) = try await projectMemoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "project-fact", name: "update_state",
                argumentsJSON: Data(#"{"target":"memory","action":"write","fact":"Use accessible layouts","scope":"project","project":"website"}"#.utf8)))
            expectNoDifference(result.isError, mode != "approve"); return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: group, text: "Remember for the website project") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "project-memory", identifier: "website"))
        expectNoDifference(approval.action.context.metadata["agentMemoryScope"], "project")
        expectNoDifference(approval.action.context.metadata["agentMemoryProjectName"], "Public website")
        expectNoDifference(approval.action.context.metadata["agentMemoryProjectMembers"], "2")
        let empty = try await model.savedAgentMemories(agentID: owner.id, scope: .project); expectNoDifference(empty, [])
        if mode == "stop" { await model.stopGroup(id: group) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        let file = root.appending(path: "agents.json"), backup = root.appending(path: "backup-agents.json")
        if mode == "save-failure" {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        await model.resolveGroupApproval(approval, groupID: group, approve: mode != "deny")
        await run.value
        if mode == "save-failure" {
            try FileManager.default.removeItem(at: file); try FileManager.default.moveItem(at: backup, to: file)
        }
        let agents = try AgentService(storeURL: file)
        let saved = await agents.projectMemoriesForEditor(accountID: "local")
        expectNoDifference(saved.count, mode == "approve" ? 1 : 0)
        if mode == "approve" {
            let record = try #require(saved.first)
            expectNoDifference(record.fact, "Use accessible layouts"); expectNoDifference(record.agentID, owner.id)
            let editor = try await model.savedAgentMemories(agentID: peer.id, scope: .project)
            // Compare the complete records at the persisted date precision.
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
            expectNoDifference(try decoder.decode([AgentMemory].self, from: encoder.encode(editor)), saved)
            let privateFacts = try await model.savedAgentMemories(agentID: owner.id)
            let userFacts = try await model.savedAgentMemories(agentID: owner.id, scope: .user)
            expectNoDifference(privateFacts, []); expectNoDifference(userFacts, [])
            try await model.forgetAgentMemory(record)
            let forgotten = try await model.savedAgentMemories(agentID: peer.id, scope: .project)
            expectNoDifference(forgotten, [])
        }
        #expect(model.runningGroups.isEmpty && model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func mailboxProjectMemoryUsesRecipientIdentityAndHumanCanForgetArchivedAuthor() async throws {
        let (root, model, _, sender, recipient) = try await projectMemoryFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "project-fact", name: "update_state",
                argumentsJSON: Data(#"{"target":"memory","action":"write","fact":"Visual review uses amber","scope":"project","project":"website"}"#.utf8)))
            #expect(!result.isError); return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Remember for the website project"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.context.metadata["agentMemoryOwner"], recipient.name)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        let saved = try await model.savedAgentMemories(agentID: sender.id, scope: .project)
        let fact = try #require(saved.first); expectNoDifference(fact.agentID, recipient.id)
        await model.archiveAgent(id: recipient.id)
        try await model.forgetAgentMemory(fact)
        let empty = try await model.savedAgentMemories(agentID: sender.id, scope: .project); expectNoDifference(empty, [])
    }

    @Test func projectMemoryApprovalRendersInSevenLanguagesAndBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try FiliconLocalization.$languageOverride.withValue(language) {
                    if language != "en" {
                        for key in ["Project memory", "Save project memory", "Forget project memory", "Forget this fact for all project members?",
                                    AgentMemoryError.projectUnavailable.rawValue, AgentMemoryError.projectDuplicate.rawValue,
                                    AgentMemoryError.projectLimit.rawValue, AgentMemoryError.invalid.rawValue, AgentMemorySearchError.invalid.rawValue] {
                            #expect(FiliconLocalization.string(key) != key)
                        }
                    }
                    for action in ["write", "forget"] {
                        let host = NSHostingView(rootView: AgentMemoryApprovalDetails(metadata: [
                            "agentMemoryScope": "project", "agentMemoryAction": action, "agentMemoryOwner": "Designer",
                            "agentMemoryProject": "website", "agentMemoryProjectName": "Public website", "agentMemoryProjectMembers": "2",
                            "agentMemoryFact": "Use accessible amber buttons and readable contrast.", "agentMemoryTier": "profile"])
                            .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        host.frame = .init(x: 0, y: 0, width: 380, height: 1_000); host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.height <= 1_000)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        if let output {
                            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            try data.write(to: output.appending(path: "project-memory-\(action)-\(language)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }

    @Test func projectQuotaIdentityIncludesAccountAndFitsLedgerLimit() {
        let accounts = ["local", "other", "a:b", "a\u{1f}b", String(repeating: "a", count: 256)]
        let keys = accounts.map { AppModel.projectQuotaKey(accountID: $0, slug: String(repeating: "s", count: 64)) }
        expectNoDifference(Set(keys).count, accounts.count)
        #expect(keys.allSatisfy { $0.utf8.count <= 512 && !$0.contains("\u{1f}") })
        #expect(AppModel.projectQuotaKey(accountID: "a:b", slug: "c") != AppModel.projectQuotaKey(accountID: "a", slug: "b-c"))
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "archive", "save-failure"])
    func projectMembershipRequiresExplicitApproval(mode: String) async throws {
        let (root, model, groupID, owner, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "project", name: "update_state",
                argumentsJSON: Data(#"{"target":"project","action":"create","project":"website","name":"Public website","description":"Shared description"}"#.utf8)))
            expectNoDifference(result.isError, mode != "approve")
            return "PASS"
        })
        let groups = model.groups
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Create and join this collaboration project") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent-project", identifier: "website"))
        expectNoDifference(approval.action.context.metadata["agentStateTarget"], "project")
        expectNoDifference(approval.action.context.metadata["projectName"], "Public website")
        expectNoDifference(approval.action.context.metadata["projectDescription"], "Shared description")
        expectNoDifference(approval.action.context.metadata["projectCreates"], "true")
        expectNoDifference(approval.action.context.metadata["projectBeforeJoined"], "false")
        expectNoDifference(approval.action.context.metadata["projectAfterJoined"], "true")
        expectNoDifference(try storedProjects(root), [])
        var expected: [AgentProject] = []
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        let file = root.appending(path: "agents.json"), backup = root.appending(path: "agents-backup.json")
        if mode == "save-failure" {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        if mode == "save-failure" {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
        }
        let saved = try storedProjects(root)
        if mode == "approve" {
            let project = try #require(saved.first)
            expectNoDifference(project.memberIDs, [owner.id]); expectNoDifference(project.name, "Public website")
            expectNoDifference(project.summary, "Shared description"); expectNoDifference(saved.count, 1)
            expected = saved
            let ledger = try StorageQuotaLedger.live(dataRoot: root)
            let record = try #require(await ledger.record(scope: "workflow", key: AppModel.projectQuotaKey(accountID: "local", slug: "website")))
            #expect(record.byteCount > 0)
            expectNoDifference(record, .init(scope: "workflow", key: AppModel.projectQuotaKey(accountID: "local", slug: "website"),
                byteCount: record.byteCount, generation: 1))
            let other = await ledger.record(scope: "workflow", key: AppModel.projectQuotaKey(accountID: "other", slug: "website"))
            expectNoDifference(other, nil)
        }
        expectNoDifference(saved, expected)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty)
        // Posting the request changes room history, not the group's members or metadata.
        expectNoDifference(model.groups.map(\.memberIDs), groups.map(\.memberIDs))
        let reopened = try AgentService(storeURL: file)
        let durable = await reopened.projects(accountID: "local")
        // The store uses millisecond timestamps; compare the full wire representation.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.outputFormatting = [.sortedKeys]
        expectNoDifference(try encoder.encode(durable), try encoder.encode(expected))
    }

    @Test func mailboxProjectMembershipUsesRecipientIdentity() async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "project", name: "update_state",
                argumentsJSON: Data(#"{"target":"project","action":"create","project":"design-system","name":"Design system"}"#.utf8)))
            #expect(!result.isError); return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Create the collaboration project"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        let project = try #require(storedProjects(root).first)
        expectNoDifference(project.memberIDs, [recipient.id])
    }

    @Test func projectApprovalRendersInSevenLanguagesAndBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try FiliconLocalization.$languageOverride.withValue(language) {
                    if language != "en" {
                        for key in ["Collaboration project membership", "Create and join project", "Join existing project", "Leave project",
                            "Project member", "Not a project member", "Project member count", AgentProjectApprovalDetails.notice,
                            AgentProjectError.invalid.rawValue, AgentProjectError.unavailable.rawValue, AgentProjectError.limit.rawValue,
                            AgentProjectError.unchanged.rawValue, AgentProjectError.stale.rawValue] {
                            #expect(FiliconLocalization.string(key) != key)
                        }
                    }
                    for mode in ["create", "join", "leave"] {
                        let metadata = ["agentName": "Designer", "projectSlug": "design-system", "projectName": "Product design system",
                            "projectDescription": "Shared project metadata for a responsive, accessible website. No private memory.",
                            "projectCreates": String(mode == "create"), "projectAction": mode,
                            "projectBeforeJoined": String(mode == "leave"), "projectAfterJoined": String(mode != "leave"),
                            "projectBeforeCount": mode == "create" ? "0" : "2",
                            "projectAfterCount": mode == "create" ? "1" : mode == "leave" ? "1" : "3"]
                        let host = NSHostingView(rootView: AgentProjectApprovalDetails(metadata: metadata)
                            .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        host.frame = .init(x: 0, y: 0, width: 380, height: 820); host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.height <= 820)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        if let output {
                            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            try data.write(to: output.appending(path: "project-\(mode)-\(language)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "stale", "archive", "save-failure"])
    func channelDisconnectRequiresExplicitApprovalAndPreservesPeers(mode: String) async throws {
        let (root, model, groupID, owner, _, own, other) = try await channelFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "channel", name: "update_state",
                argumentsJSON: Data(#"{"target":"channel","action":"disconnect","platform":"slack"}"#.utf8)))
            expectNoDifference(result.isError, mode != "approve")
            #expect(!result.wireText.contains("SECRET_MARKER") && !result.wireText.contains("PEER_CHANNEL_MARKER"))
            return "PASS"
        })
        let before = model.channelConnections
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Disconnect your Slack connection") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "channel", identifier: own.id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentStateTarget"], "channel")
        expectNoDifference(approval.action.context.metadata["channelName"], own.displayName)
        expectNoDifference(approval.action.context.metadata["channelAccountLabel"], own.accountLabel)
        #expect(approval.action.risks.contains(.destructive))
        #expect(!approval.action.context.metadata.values.joined().contains("SECRET_MARKER"))
        #expect(!approval.action.context.metadata.values.joined().contains("PEER_CHANNEL_MARKER"))
        expectNoDifference(model.channelConnections, before)
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "stale" { await model.setChannelConnectionEnabled(id: own.id, enabled: false) }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        let file = root.appending(path: "channels.json"), backup = root.appending(path: "channels-backup.json")
        if mode == "save-failure" {
            try FileManager.default.moveItem(at: file, to: backup)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        let expected = mode == "approve" ? before.filter { $0.id != own.id } : before
        expectNoDifference(model.channelConnections, expected)
        expectNoDifference(model.channelConnections.first { $0.id == other.id }, other)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty)
        if mode == "save-failure" {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: backup, to: file)
        }
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.channelConnections, expected)
        expectNoDifference(restored.groups.first { $0.id == groupID }?.memberIDs, [owner.id])
    }

    @Test func mailboxDisconnectTargetsRecipientNotSender() async throws {
        let (root, model, _, sender, recipient, own, other) = try await channelFixture(mailbox: true)
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "channel", name: "update_state",
                argumentsJSON: Data(#"{"target":"channel","action":"disconnect","platform":"slack"}"#.utf8)))
            #expect(!result.isError)
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Disconnect your Slack connection"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "channel", identifier: own.id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        expectNoDifference(model.channelConnections, [other])
    }

    @Test func channelApprovalRendersInSevenLanguagesAndBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try FiliconLocalization.$languageOverride.withValue(language) {
                    if language != "en" {
                        for key in ["Disconnect agent channel", "Connection enabled", "Connection disabled",
                                    ChannelDisconnectionError.invalid.rawValue, ChannelDisconnectionError.unavailable.rawValue,
                                    ChannelDisconnectionError.ambiguous.rawValue, ChannelDisconnectionError.stale.rawValue] {
                            #expect(FiliconLocalization.string(key) != key)
                        }
                    }
                    let metadata = ["agentName": "Designer", "channelName": "Product workspace", "channelPlatform": "slack",
                        "channelAccountLabel": "C0123456789, C9876543210", "channelID": "00000000-0000-0000-0000-000000000001",
                        "channelEnabled": "true", "channelInboundCount": "10000", "channelDeliveryCount": "1500",
                        "channelPendingCount": "500", "channelFailureCount": "20"]
                    let host = NSHostingView(rootView: AgentChannelDisconnectionDetails(metadata: metadata)
                        .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 380, height: 800)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 800)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try data.write(to: output.appending(path: "channel-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "aba", "archive"], [false, true])
    func ownNotificationSettingsAlwaysAskAndRespectLifecycle(mode: String, enabled: Bool) async throws {
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var initial = owner; initial.notifyOnAgentUpdates = !enabled
        #expect(await model.updateAgent(initial))
        await model.registry.register(ManagingAgentProvider { request, execute in
            let instructions = request.messages.filter { $0.role == .system }.map(\.text).joined()
            #expect(instructions.contains("Own notify_on_updates: \(!enabled)"))
            let result = try await execute(.init(id: "settings", name: "update_state",
                argumentsJSON: Data("{\"target\":\"settings\",\"action\":\"set\",\"notify_on_updates\":\(enabled)}".utf8)))
            expectNoDifference(result.isError, mode != "approve")
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Change your update notification preference") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent", identifier: owner.id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentStateTarget"], "settings")
        expectNoDifference(approval.action.context.metadata["previousAgentNotifyOnUpdates"], String(!enabled))
        expectNoDifference(approval.action.context.metadata["agentNotifyOnUpdates"], String(enabled))
        expectNoDifference(model.agents.first { $0.id == owner.id }?.notifyOnAgentUpdates, !enabled)
        #expect(!approval.action.context.metadata.values.joined().contains("PRIVATE"))
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "archive" { await model.archiveAgent(id: owner.id) }
        if mode == "aba" {
            for value in [enabled, !enabled] {
                var changed = try #require(model.agents.first { $0.id == owner.id })
                changed.notifyOnAgentUpdates = value
                #expect(await model.updateAgent(changed))
            }
        }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        let expected = mode == "approve" ? enabled : !enabled
        expectNoDifference(model.agents.first { $0.id == owner.id }?.notifyOnAgentUpdates, expected)
        expectNoDifference(model.agents.first { $0.id == peer.id }?.notifyOnAgentUpdates, true)
        expectNoDifference(model.groups.first { $0.id == groupID }?.memberIDs, [owner.id])
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty)
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.agents.first { $0.id == owner.id }?.notifyOnAgentUpdates, expected)
        let projected = AgentNotificationProjection.notificationSnapshots(profiles: restored.agents, tasks: [])
        expectNoDifference(projected.first { $0.id == owner.id.uuidString.lowercased() }?.notifyEnabled, expected)
    }

    @Test func mailboxSettingsBelongToRecipientAndManualEditsPersist() async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "settings", name: "update_state",
                argumentsJSON: Data(#"{"target":"settings","action":"set","notify_on_updates":false}"#.utf8)))
            #expect(!result.isError)
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Mute your own update alerts"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent", identifier: recipient.id.uuidString))
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        expectNoDifference(model.agents.first { $0.id == sender.id }?.notifyOnAgentUpdates, true)
        let muted = try #require(model.agents.first { $0.id == recipient.id })
        expectNoDifference(muted.notifyOnAgentUpdates, false)
        #expect(await model.updateAgent(recipient) == false)
        var fresh = muted; fresh.notifyOnAgentUpdates = true
        #expect(await model.updateAgent(fresh))
        let newAgent = try #require(await model.createAgent(name: "Quiet", summary: "", instructions: "",
            providerID: "management-fixture", modelID: "test", notifyOnAgentUpdates: false))
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.agents.first { $0.id == recipient.id }?.notifyOnAgentUpdates, true)
        expectNoDifference(restored.agents.first { $0.id == newAgent.id }?.notifyOnAgentUpdates, false)
    }

    @Test func notificationApprovalRendersInSevenLanguagesAndBothAppearances() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for enabled in [false, true] {
                for dark in [false, true] {
                    try FiliconLocalization.$languageOverride.withValue(language) {
                        if language != "en" { #expect(FiliconLocalization.string("Agent update notifications") != "Agent update notifications") }
                        let metadata = ["agentName": "Designer", "previousAgentNotifyOnUpdates": String(!enabled), "agentNotifyOnUpdates": String(enabled)]
                        let host = NSHostingView(rootView: AgentSettingsApprovalDetails(metadata: metadata)
                            .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                            .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                        host.frame = .init(x: 0, y: 0, width: 380, height: 440)
                        host.layoutSubtreeIfNeeded()
                        #expect(host.fittingSize.height <= 440)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        if let output {
                            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                            try data.write(to: output.appending(path: "settings-\(enabled)-\(language)-\(dark ? "dark" : "light").png"))
                        }
                    }
                }
            }
        }
    }

    private func persistedRoutine(_ value: Automation?) throws -> Automation? {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Automation?.self, from: encoder.encode(value))
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "stale"], ["pause", "resume", "delete"])
    func ownRoutineUsesExplicitApprovalAndLifecycleFences(mode: String, action: String) async throws {
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = String(repeating: "Review accessible layout; do not publish. ", count: 100) + "END_OF_FULL_TASK"
        await model.createAutomation(agentID: owner.id, name: "Design check", prompt: prompt, schedule: "@every 1h")
        await model.createAutomation(agentID: peer.id, name: "PRIVATE_PEER_ROUTINE", prompt: "PRIVATE_PEER_TASK", schedule: "@daily")
        let id = try #require(model.automations.first { $0.agentID == owner.id }?.id)
        if action == "resume" { await model.setAutomationEnabled(id: id, enabled: false) }
        let before = try #require(model.automations.first { $0.id == id })
        let other = try #require(model.automations.first { $0.agentID == peer.id })
        await model.registry.register(ManagingAgentProvider { request, execute in
            let system = request.messages.filter { $0.role == .system }.map(\.text).joined()
            #expect(system.contains(id.uuidString) && !system.contains(other.id.uuidString) && !system.contains("PRIVATE_PEER_"))
            let result = try await execute(.init(id: "routine", name: "update_state",
                argumentsJSON: JSONEncoder().encode(["target": "routine", "action": action, "id": id.uuidString])))
            expectNoDifference(result.isError, mode != "approve")
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "\(action) your routine") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "automation", identifier: id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentStateTarget"], "routine")
        expectNoDifference(approval.action.context.metadata["agentRoutineAction"], action)
        expectNoDifference(approval.action.context.metadata["agentRoutineID"], id.uuidString)
        expectNoDifference(approval.action.risks.contains(.destructive), action == "delete")
        expectNoDifference(approval.action.context.metadata["agentRoutinePrompt"], prompt)
        expectNoDifference(approval.action.context.metadata["agentRoutineTrigger"], try AutomationStateChange(operation: .pause, automation: before).triggerJSON)
        expectNoDifference(approval.action.context.metadata["agentName"], owner.name)
        #expect(!approval.action.context.metadata.values.joined().contains("PRIVATE_"))
        expectNoDifference(model.automations.first { $0.id == id }, before)
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "stale" { await model.setAutomationEnabled(id: id, enabled: before.enabled) }
        if action == "delete" && mode == "approve" {
            await expectDifference(model.automations) {
                await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
                await run.value
            } changes: {
                $0.removeAll { $0.id == id }
            }
        } else {
            await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        }
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        let saved = model.automations.first { $0.id == id }
        if action == "delete" && mode == "approve" { #expect(saved == nil) }
        else {
            let saved = try #require(saved)
            expectNoDifference(saved.enabled, mode == "approve" ? !before.enabled : before.enabled)
            expectNoDifference(saved.name, before.name); expectNoDifference(saved.prompt, before.prompt)
            expectNoDifference(saved.trigger, before.trigger)
            expectNoDifference(saved.revision, before.revision + ((mode == "approve" || mode == "stale") ? 1 : 0))
        }
        expectNoDifference(model.automations.first { $0.id == other.id }, other)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty && model.agentMessages.isEmpty)
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.automations.first { $0.id == id }, try persistedRoutine(saved))
        expectNoDifference(restored.automationHistory[id] ?? [], [])
    }

    @Test(arguments: ["pause", "delete"]) func mailboxRoutineBelongsToRecipientOnly(action: String) async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for owner in [sender, recipient] {
            await model.createAutomation(agentID: owner.id, name: owner.name + " task", prompt: "Review", schedule: "@daily")
        }
        let own = try #require(model.automations.first { $0.agentID == recipient.id })
        let other = try #require(model.automations.first { $0.agentID == sender.id })
        await model.registry.register(ManagingAgentProvider { _, execute in
            await #expect(throws: AutomationStateChangeError.unavailable) {
                _ = try await execute(.init(id: "other", name: "update_state",
                    argumentsJSON: JSONEncoder().encode(["target": "routine", "action": action, "id": other.id.uuidString])))
            }
            let result = try await execute(.init(id: "own", name: "update_state",
                argumentsJSON: JSONEncoder().encode(["target": "routine", "action": action, "id": own.id.uuidString])))
            #expect(!result.isError)
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "\(action) your own routine"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "automation", identifier: own.id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        expectNoDifference(model.automations.first { $0.id == own.id }?.enabled, action == "delete" ? nil : false)
        expectNoDifference(model.automations.first { $0.id == other.id }, other)
        expectNoDifference(model.agentMessages.first?.delivery?.state, .completed)
    }

    @Test(arguments: ["approve", "deny", "stop", "account"], ["create", "update", "create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-cycle", "update-cycle", "create-sentry", "update-sentry", "create-pagerduty", "update-pagerduty", "create-teams", "update-teams"])
    func routineWritesShowCompleteReviewAndRespectLifecycle(mode: String, scenario: String) async throws {
        let action = scenario.hasPrefix("create") ? "create" : "update"
        let github = scenario.hasSuffix("github"), slack = scenario.hasSuffix("slack"), linear = scenario.hasSuffix("linear"), cycle = scenario.hasSuffix("cycle"), sentry = scenario.hasSuffix("sentry"), pagerDuty = scenario.hasSuffix("pagerduty"), teams = scenario.hasSuffix("teams")
        let mixed = scenario.hasSuffix("mixed")
        let group = scenario.hasSuffix("group") || mixed
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.setTimeZone("Asia/Taipei")
        let previousPrompt = String(repeating: "Review previous layout. ", count: 100) + "OLD_TASK_END"
        let proposedPrompt = String(repeating: "Review contrast; do not publish. ", count: 100) + "NEW_TASK_END"
        await model.createAutomation(agentID: owner.id, name: "Original", prompt: previousPrompt, schedule: "@every 1h")
        await model.createAutomation(agentID: peer.id, name: "PRIVATE_PEER_ROUTINE", prompt: "PRIVATE_PEER_TASK", schedule: "@daily")
        let before = model.automations
        let own = try #require(before.first { $0.agentID == owner.id })
        let other = try #require(before.first { $0.agentID == peer.id })
        var fields: [String: Any] = ["target": "routine", "action": action, "name": "Approved review",
                                    "prompt": proposedPrompt, "schedule": "@every 2h"]
        if action == "update" { fields["id"] = own.id.uuidString; fields["enabled"] = false }
        if github {
            fields.removeValue(forKey: "schedule")
            fields["trigger"] = ["type": "github", "repo": "example/project", "events": ["review-approved", "ci-failed"],
                "ciBranch": "main", "userAllowlist": ["author", "reviewer"]]
        }
        if slack {
            fields.removeValue(forKey: "schedule")
            fields["trigger"] = ["type": "slack", "channel": "*", "match": ["kind": "reaction", "emoji": ["eyes"]]]
        }
        if linear { fields.removeValue(forKey: "schedule"); fields["trigger"] = linearRoutineFields }
        if cycle { fields.removeValue(forKey: "schedule"); fields["trigger"] = cycleRoutineFields }
        if sentry { fields.removeValue(forKey: "schedule"); fields["trigger"] = sentryRoutineFields }
        if pagerDuty { fields.removeValue(forKey: "schedule"); fields["trigger"] = pagerDutyRoutineFields }
        if teams { fields.removeValue(forKey: "schedule"); fields["trigger"] = ["type": "microsoftTeams", "tenantId": "aaaaaaaa-0000-0000-0000-000000000001", "teamId": "19:team@thread.tacv2", "messageContains": "deploy"] }
        if group { fields.removeValue(forKey: "schedule"); fields["trigger"] = mixed ? mixedGroupFields : eventGroupFields }
        let arguments = try JSONSerialization.data(withJSONObject: fields)
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "routine-write", name: "update_state", argumentsJSON: arguments))
            #expect(!result.isError)
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "\(action) your own routine") }
        let approval = try await pending(model, tool: "update_state")
        let metadata = approval.action.context.metadata
        let id = try #require(metadata["agentRoutineID"].flatMap(UUID.init(uuidString:)))
        expectNoDifference(approval.action.target, .resource(kind: "automation", identifier: id.uuidString))
        expectNoDifference(metadata["agentRoutineAction"], action)
        expectNoDifference(metadata["agentName"], owner.name)
        expectNoDifference(metadata["agentRoutineName"], "Approved review")
        expectNoDifference(metadata["agentRoutinePrompt"], proposedPrompt)
        expectNoDifference(metadata["agentRoutineEnabled"], action == "create" ? "true" : "false")
        expectNoDifference(metadata["agentRoutineGitHubTrigger"], github || group ? "true" : nil)
        expectNoDifference(metadata["agentRoutineSlackTrigger"], slack || group ? "true" : nil)
        expectNoDifference(metadata["agentRoutineLinearTrigger"], linear || cycle || group ? "true" : nil)
        expectNoDifference(metadata["agentRoutineSentryTrigger"], sentry || group ? "true" : nil)
        expectNoDifference(metadata["agentRoutinePagerDutyTrigger"], pagerDuty || group ? "true" : nil)
        expectNoDifference(metadata["agentRoutineTeamsTrigger"], teams ? "true" : nil)
        expectNoDifference(metadata["agentRoutineAnyOfTrigger"], group ? "true" : nil)
        expectNoDifference(metadata["agentRoutineTimeGroupTrigger"], mixed ? "true" : nil)
        let trigger: AutomationTrigger = teams ? try teamsRoutineTrigger() : cycle ? try cycleRoutineTrigger() : pagerDuty ? try pagerDutyRoutineTrigger() : sentry ? try sentryRoutineTrigger() : linear ? try linearRoutineTrigger() : group ? try (mixed ? mixedGroupTrigger() : eventGroupTrigger()) : github ? .platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
            ciBranch: "main", userAllowlist: ["author", "reviewer"]))) : slack ? .platform(.slack(try .init(channel: "*", match: .reaction(emoji: ["eyes"], bySelf: false)))) : .cron(expression: "@every 2h", timeZoneIdentifier: "Asia/Taipei")
        let proposed = Automation(id: id, agentID: owner.id, name: "Approved review", prompt: proposedPrompt, trigger: trigger)
        expectNoDifference(metadata["agentRoutineTrigger"], try AutomationStateChange(operation: .create, automation: proposed).triggerJSON)
        if action == "update" {
            expectNoDifference(id, own.id)
            expectNoDifference(metadata["previousAgentRoutineName"], own.name)
            expectNoDifference(metadata["previousAgentRoutinePrompt"], previousPrompt)
            expectNoDifference(metadata["previousAgentRoutineEnabled"], "true")
            expectNoDifference(metadata["previousAgentRoutineTrigger"], try AutomationStateChange(operation: .pause, automation: own).triggerJSON)
        } else {
            #expect(id != own.id && id != other.id)
            #expect(metadata.keys.allSatisfy { !$0.hasPrefix("previousAgentRoutine") })
        }
        #expect(!metadata.values.joined().contains("PRIVATE_"))
        expectNoDifference(model.automations, before)
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        if mode == "approve" {
            let saved = try #require(model.automations.first { $0.id == id })
            expectNoDifference(saved.agentID, owner.id)
            expectNoDifference(saved.name, "Approved review"); expectNoDifference(saved.prompt, proposedPrompt)
            expectNoDifference(saved.trigger, trigger); expectNoDifference(saved.enabled, action == "create")
            expectNoDifference(saved.revision, action == "create" ? 1 : own.revision + 1)
            expectNoDifference(saved.lastRunAt, nil)
            if action == "create" && ((!github && !slack && !linear && !cycle && !sentry && !pagerDuty && !teams && !group) || mixed) { #expect(try #require(saved.nextRunAt) > saved.createdAt) }
            else { expectNoDifference(saved.nextRunAt, nil) }
            if action == "update" { expectNoDifference(saved.createdAt, own.createdAt) }
            expectNoDifference(model.automations.count, before.count + (action == "create" ? 1 : 0))
        } else { expectNoDifference(model.automations, before) }
        expectNoDifference(model.automations.first { $0.id == other.id }, other)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty && model.agentMessages.isEmpty)
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.automations.first { $0.id == id }, try persistedRoutine(model.automations.first { $0.id == id }))
        expectNoDifference(restored.automationHistory[id] ?? [], [])
    }

    @Test(arguments: ["create", "update", "create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-cycle", "update-cycle", "create-sentry", "update-sentry", "create-pagerduty", "update-pagerduty", "create-teams", "update-teams"]) func mailboxRoutineWritesAreBoundToRecipient(scenario: String) async throws {
        let action = scenario.hasPrefix("create") ? "create" : "update"
        let github = scenario.hasSuffix("github"), slack = scenario.hasSuffix("slack"), linear = scenario.hasSuffix("linear"), cycle = scenario.hasSuffix("cycle"), sentry = scenario.hasSuffix("sentry"), pagerDuty = scenario.hasSuffix("pagerduty"), teams = scenario.hasSuffix("teams")
        let mixed = scenario.hasSuffix("mixed")
        let group = scenario.hasSuffix("group") || mixed, groupJSON = try JSONSerialization.data(withJSONObject: mixed ? mixedGroupFields : eventGroupFields)
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.setTimeZone("Asia/Taipei")
        for owner in [sender, recipient] {
            await model.createAutomation(agentID: owner.id, name: owner.name, prompt: "Original", schedule: "@daily")
        }
        let own = try #require(model.automations.first { $0.agentID == recipient.id })
        let other = try #require(model.automations.first { $0.agentID == sender.id })
        await model.registry.register(ManagingAgentProvider { _, execute in
            await #expect(throws: AutomationStateChangeError.unavailable) {
                _ = try await execute(.init(id: "foreign", name: "update_state", argumentsJSON: JSONEncoder().encode([
                    "target": "routine", "action": "update", "id": other.id.uuidString, "prompt": "Do not write"])))
            }
            var fields: [String: Any] = ["target": "routine", "action": action, "prompt": "Recipient's new task"]
            if action == "create" { fields["name"] = "Recipient review"; fields["schedule"] = "@daily" }
            else { fields["id"] = own.id.uuidString }
            if github {
                fields.removeValue(forKey: "schedule")
                fields["trigger"] = ["type": "github", "repo": "example/project", "events": ["pr-opened"]]
            }
            if slack {
                fields.removeValue(forKey: "schedule")
                fields["trigger"] = ["type": "slack", "channel": "C123", "match": ["kind": "keyword", "keyword": "design"]]
            }
            if linear { fields.removeValue(forKey: "schedule"); fields["trigger"] = ["type": "linear", "event": ["case": "issueCreated"]] }
            if cycle { fields.removeValue(forKey: "schedule"); fields["trigger"] = ["type": "linear", "event": ["case": "endOfCycle"]] }
            if sentry { fields.removeValue(forKey: "schedule"); fields["trigger"] = ["type": "sentry", "event": ["case": "issueAny"]] }
            if pagerDuty { fields.removeValue(forKey: "schedule"); fields["trigger"] = ["type": "pagerduty", "event": ["case": "incidentAny"]] }
            if teams { fields.removeValue(forKey: "schedule"); fields["trigger"] = ["type": "microsoftTeams", "tenantId": "aaaaaaaa-0000-0000-0000-000000000001", "teamId": "19:team@thread.tacv2", "messageContains": "deploy"] }
            if group { fields.removeValue(forKey: "schedule"); fields["trigger"] = try JSONSerialization.jsonObject(with: groupJSON) }
            _ = try await execute(.init(id: "own", name: "update_state", argumentsJSON: JSONSerialization.data(withJSONObject: fields)))
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "\(action) your routine"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        let id = try #require(approval.action.context.metadata["agentRoutineID"].flatMap(UUID.init(uuidString:)))
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        let saved = try #require(model.automations.first { $0.id == id })
        expectNoDifference(saved.agentID, recipient.id); expectNoDifference(saved.prompt, "Recipient's new task")
        if group { expectNoDifference(saved.trigger, try (mixed ? mixedGroupTrigger() : eventGroupTrigger())) }
        if linear { expectNoDifference(saved.trigger, .platform(.linear(try .init(event: "issueCreated", allowedEvents: ["issueCreated"])))) }
        if cycle { expectNoDifference(saved.trigger, .platform(.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"])))) }
        if sentry { expectNoDifference(saved.trigger, .platform(.sentry(try .init(event: "issueAny", allowedEvents: ["issueAny"])))) }
        if pagerDuty { expectNoDifference(saved.trigger, .platform(.pagerDuty(try .init(event: "incidentAny", allowedEvents: ["incidentAny"])))) }
        if teams { expectNoDifference(saved.trigger, try teamsRoutineTrigger()) }
        expectNoDifference(model.automations.first { $0.id == other.id }, other)
        expectNoDifference(model.agentMessages.first?.delivery?.state, .completed)
    }

    @Test func routinePreviewRendersInSevenLanguages() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for scenario in ["pause", "resume", "delete", "create", "update", "create-github", "update-github", "create-slack", "update-slack", "create-group", "update-group", "create-mixed", "update-mixed", "create-linear", "update-linear", "create-cycle", "update-cycle", "create-sentry", "update-sentry", "create-pagerduty", "update-pagerduty", "create-teams", "update-teams"] {
                let github = scenario.hasSuffix("github"), slack = scenario.hasSuffix("slack"), linear = scenario.hasSuffix("linear"), cycle = scenario.hasSuffix("cycle"), sentry = scenario.hasSuffix("sentry"), pagerDuty = scenario.hasSuffix("pagerduty"), teams = scenario.hasSuffix("teams")
                let mixed = scenario.hasSuffix("mixed")
                let group = scenario.hasSuffix("group") || mixed
                let action = scenario.replacingOccurrences(of: "-github", with: "").replacingOccurrences(of: "-slack", with: "").replacingOccurrences(of: "-group", with: "").replacingOccurrences(of: "-mixed", with: "").replacingOccurrences(of: "-linear", with: "").replacingOccurrences(of: "-cycle", with: "").replacingOccurrences(of: "-sentry", with: "").replacingOccurrences(of: "-pagerduty", with: "").replacingOccurrences(of: "-teams", with: "")
                try FiliconLocalization.$languageOverride.withValue(language) {
                    let titles = ["pause": "Pause own routine", "resume": "Resume own routine", "delete": "Delete own routine",
                                  "create": "Create own routine", "update": "Update own routine"]
                    let title = try #require(titles[action])
                    if language != "en" { #expect(FiliconLocalization.string(title) != title) }
                    var metadata = ["agentName": "Designer", "agentRoutineAction": action, "agentRoutineName": "Daily design review",
                                    "agentRoutineEnabled": "true",
                                    "agentRoutineID": "00000000-0000-0000-0000-000000000010",
                                    "agentRoutinePrompt": "Review accessible contrast. Do not publish.",
                                    "agentRoutineTrigger": "{\n  cron: {\n    expression: 0 9 * * *,\n    timeZoneIdentifier: Asia/Taipei\n  }\n}"]
                    if action == "update" {
                        metadata["previousAgentRoutineName"] = "Weekly design review"
                        metadata["previousAgentRoutineEnabled"] = "false"
                        metadata["previousAgentRoutinePrompt"] = "Review previous layout. Do not publish."
                        metadata["previousAgentRoutineTrigger"] = "{\n  cron: {\n    expression: @weekly,\n    timeZoneIdentifier: Asia/Taipei\n  }\n}"
                    }
                    if github {
                        metadata["agentRoutineGitHubTrigger"] = "true"
                        let trigger = AutomationTrigger.platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
                            ciBranch: "main", userAllowlist: ["author", "reviewer"])))
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: trigger)).triggerJSON
                    }
                    if slack {
                        metadata["agentRoutineSlackTrigger"] = "true"
                        let trigger = AutomationTrigger.platform(.slack(try .init(channel: "*", match: .reaction(emoji: ["eyes", "thumbsup"], bySelf: false))))
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: trigger)).triggerJSON
                    }
                    if linear || cycle || group {
                        metadata["agentRoutineLinearTrigger"] = "true"
                        let disclosure = "Linear requires existing authenticated ingress; no webhook or connection is installed or started. Supports issue creation, actual status changes and cycle completion. Completion requires completedAt changing from null to a valid time, including early completion; a scheduled end date alone does not trigger it. Filters use exact UUIDs, not names; empty means any. statusIds is only for statusChanged; cycleIds is only for endOfCycle. Cycles have no project relationship, so projectIds must be omitted or empty. Replay protection is bounded. Queued events may trigger after approval and incur model costs."
                        if language != "en" { #expect(FiliconLocalization.string(disclosure) != disclosure) }
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: cycle ? cycleRoutineTrigger() : linearRoutineTrigger())).triggerJSON
                    }
                    if sentry || group {
                        metadata["agentRoutineSentryTrigger"] = "true"
                        let disclosure = "Sentry requires existing authenticated ingress; no webhook or connection is installed or started. Supports issue creation, resolution, assignment, archiving and reopening; issueAny matches these five cases, not all events. Project filters use exact decimal IDs, not names; empty means any project. Replay protection is bounded and signatures do not prove freshness. Queued events may trigger after approval and incur model costs."
                        if language != "en" { #expect(FiliconLocalization.string(disclosure) != disclosure) }
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: sentryRoutineTrigger())).triggerJSON
                    }
                    if teams {
                        metadata["agentRoutineTeamsTrigger"] = "true"
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: teamsRoutineTrigger())).triggerJSON
                    }
                    if pagerDuty || group {
                        metadata["agentRoutinePagerDutyTrigger"] = "true"
                        let disclosure = "PagerDuty requires existing authenticated ingress; no webhook or connection is installed or started. Supports incident triggering, acknowledgment, resolution and escalation; incidentAny matches these four cases only. Service filters use exact case-sensitive IDs with no name lookup; empty means any service. Replay protection is bounded; occurred_at is event time, not delivery freshness. Queued events may trigger after approval and incur model costs."
                        if language != "en" { #expect(FiliconLocalization.string(disclosure) != disclosure) }
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: pagerDutyRoutineTrigger())).triggerJSON
                    }
                    if group {
                        metadata["agentRoutineGitHubTrigger"] = "true"
                        metadata["agentRoutineSlackTrigger"] = "true"
                        metadata["agentRoutineAnyOfTrigger"] = "true"
                        if mixed {
                            metadata["agentRoutineTimeGroupTrigger"] = "true"
                            let disclosure = "Time conditions use the earliest next run; simultaneous time matches run once without catch-up. Event and manual runs also reset interval timers. Each approved time zone stays fixed. More conditions may cause more runs and model costs."
                            if language != "en" { #expect(FiliconLocalization.string(disclosure) != disclosure) }
                        }
                        metadata["agentRoutineTrigger"] = try AutomationStateChange(operation: .create, automation: .init(agentID: UUID(),
                            name: "Review", prompt: "Review contrast", trigger: mixed ? mixedGroupTrigger() : eventGroupTrigger())).triggerJSON
                        let disclosure = "Any one condition can trigger this same task (OR, not AND). A delivery matching several conditions is included once. Different deliveries may cause additional runs and model costs. Each condition keeps its own filters; no new connections or permissions are granted."
                        if language != "en" { #expect(FiliconLocalization.string(disclosure) != disclosure) }
                    }
                    let host = NSHostingView(rootView: AgentRoutineApprovalDetails(metadata: metadata)
                        .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                    host.appearance = NSAppearance(named: .aqua)
                    let height: CGFloat = (action == "update" ? 830 : 570) + (mixed ? 5_000 : group ? 4_500 : linear || cycle || sentry || pagerDuty || teams ? 1_100 : github || slack ? 600 : 0)
                    host.frame = .init(x: 0, y: 0, width: 380, height: height)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= height)
                    host.frame.size.height = host.fittingSize.height
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "routine-\(scenario)-\(language).png"))
                    }
                }
            }
        }
    }

    @Test func teamsApprovalDisclosureRendersInSevenLanguagesAndBothAppearances() throws {
        let enabledLabels = ["en": "Enabled", "zh-Hant": "已啟用", "zh-Hans": "已启用", "fr": "Activé", "es": "Activado", "ja": "有効", "ko": "활성화됨"]
        let disclosure = "Approval saves a Teams definition only. Teams events cannot run because trusted user identity is unavailable; the signed-in-user restriction stays on and regex stays off. Use exact IDs and literal text; empty channel IDs allow any channel in the selected teams. Other OR conditions and explicit Run Now may still run and incur model costs. No connection, login or tool permissions are granted."
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        let trigger = try teamsRoutineTrigger()
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for dark in [false, true] {
                try FiliconLocalization.$languageOverride.withValue(language) {
                    if language != "en" {
                        #expect(FiliconLocalization.string(disclosure) != disclosure)
                        #expect(FiliconLocalization.string(AutomationStateChangeError.invalidTeamsTrigger.rawValue) != AutomationStateChangeError.invalidTeamsTrigger.rawValue)
                    }
                    expectNoDifference(FiliconLocalization.string("Enabled"), enabledLabels[language])
                    let routine = Automation(agentID: UUID(), name: "Teams review", prompt: "Review only; do not publish.",
                        trigger: .anyOf([.cron(expression: "@daily", timeZoneIdentifier: "Asia/Taipei"), trigger]))
                    let metadata = ["agentName": "Designer", "agentRoutineAction": "update", "agentRoutineName": routine.name,
                        "agentRoutineID": routine.id.uuidString, "agentRoutinePrompt": routine.prompt, "agentRoutineEnabled": "true",
                        "agentRoutineTrigger": try AutomationStateChange(operation: .create, automation: routine).triggerJSON,
                        "previousAgentRoutineName": "Daily review", "previousAgentRoutinePrompt": "Review only",
                        "previousAgentRoutineTrigger": "@daily · Asia/Taipei", "previousAgentRoutineEnabled": "false",
                        "agentRoutineTeamsTrigger": "true", "agentRoutineAnyOfTrigger": "true", "agentRoutineTimeGroupTrigger": "true"]
                    let host = NSHostingView(rootView: AgentRoutineApprovalDetails(metadata: metadata)
                        .padding(20).frame(width: 440).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    host.frame = .init(x: 0, y: 0, width: 440, height: 3_000)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height < 3_000 && host.fittingSize.height > 600)
                    host.frame.size.height = host.fittingSize.height
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:]))
                            .write(to: output.appending(path: "teams-proposal-\(language)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
    }

    private func teamsRoutineTrigger() throws -> AutomationTrigger {
        .platform(.microsoftTeams(try .init(tenantID: "aaaaaaaa-0000-0000-0000-000000000001",
            teamIDs: ["19:team@thread.tacv2"], messageContains: "deploy")))
    }

    private var mixedGroupFields: [String: Any] {
        var value = eventGroupFields
        value["listeners"] = [["type": "cron", "schedule": "@every 2h"]] + (value["listeners"] as? [[String: Any]] ?? [])
        return value
    }

    private var cycleRoutineFields: [String: Any] {
        ["type": "linear", "event": ["case": "endOfCycle", "cycleIds": ["dddddddd-0000-0000-0000-000000000001"]],
         "teamIds": ["bbbbbbbb-0000-0000-0000-000000000001"]]
    }
    private func cycleRoutineTrigger() throws -> AutomationTrigger {
        .platform(.linear(try .init(event: "endOfCycle", allowedEvents: ["endOfCycle"],
            primaryIDs: ["bbbbbbbb-0000-0000-0000-000000000001"], cycleIDs: ["dddddddd-0000-0000-0000-000000000001"])))
    }
    private var linearRoutineFields: [String: Any] {
        ["type": "linear", "event": ["case": "statusChanged", "statusIds": ["aaaaaaaa-0000-0000-0000-000000000001"]],
         "teamIds": ["bbbbbbbb-0000-0000-0000-000000000001"], "projectIds": ["cccccccc-0000-0000-0000-000000000001"]]
    }
    private var sentryRoutineFields: [String: Any] {
        ["type": "sentry", "event": ["case": "issueAny"], "projectIds": ["123", "007"]]
    }
    private var pagerDutyRoutineFields: [String: Any] {
        ["type": "pagerduty", "event": ["case": "incidentAny"], "serviceIds": ["PF9KMXH", "PA12345"]]
    }
    private func pagerDutyRoutineTrigger() throws -> AutomationTrigger {
        .platform(.pagerDuty(try .init(event: "incidentAny", allowedEvents: ["incidentAny"], primaryIDs: ["PF9KMXH", "PA12345"])))
    }
    private func sentryRoutineTrigger() throws -> AutomationTrigger {
        .platform(.sentry(try .init(event: "issueAny", allowedEvents: ["issueAny"], primaryIDs: ["123", "007"])))
    }
    private func linearRoutineTrigger() throws -> AutomationTrigger {
        .platform(.linear(try .init(event: "statusChanged", allowedEvents: ["statusChanged"],
            primaryIDs: ["bbbbbbbb-0000-0000-0000-000000000001"], secondaryIDs: ["cccccccc-0000-0000-0000-000000000001"],
            statusIDs: ["aaaaaaaa-0000-0000-0000-000000000001"])))
    }
    private func mixedGroupTrigger() throws -> AutomationTrigger {
        guard case .anyOf(let members) = try eventGroupTrigger() else { throw AutomationStateChangeError.invalidDefinition }
        return .anyOf([.cron(expression: "@every 2h", timeZoneIdentifier: "Asia/Taipei")] + members)
    }

    private var eventGroupFields: [String: Any] {
        ["type": "group", "listeners": [
            ["type": "github", "repo": "example/project", "events": ["review-approved", "ci-failed"],
             "ciBranch": "main", "userAllowlist": ["author", "reviewer"]],
            cycleRoutineFields,
            linearRoutineFields,
            pagerDutyRoutineFields,
            sentryRoutineFields,
            ["type": "slack", "channel": "*", "match": ["kind": "reaction", "emoji": ["eyes"]]]
        ]]
    }
    private func eventGroupTrigger() throws -> AutomationTrigger {
        .anyOf([
            .platform(.github(try .init(repo: "example/project", events: ["review-approved", "ci-failed"],
                ciBranch: "main", userAllowlist: ["author", "reviewer"]))),
            try cycleRoutineTrigger(),
            try linearRoutineTrigger(),
            try pagerDutyRoutineTrigger(),
            try sentryRoutineTrigger(),
            .platform(.slack(try .init(channel: "*", match: .reaction(emoji: ["eyes"], bySelf: false))))
        ])
    }

    @Test(arguments: ["approve", "deny", "stop", "account", "stale"], ["set", "clear"])
    func ownAvatarUsesExplicitPreviewAndLifecycleFences(mode: String, action: String) async throws {
        let (root, model, groupID, original, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var owner = original; owner.avatar = .pet(.dewey)
        #expect(await model.updateAgent(owner))
        let expectedPet: AgentPetAvatar = action == "set" ? .hoots : .codex
        await model.registry.register(ManagingAgentProvider { _, execute in
            var fields = ["target": "avatar", "action": action]
            if action == "set" { fields["pet_id"] = "hoots" }
            let result = try await execute(.init(id: "avatar", name: "update_state", argumentsJSON: JSONEncoder().encode(fields)))
            expectNoDifference(result.isError, mode != "approve")
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Change your avatar") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent", identifier: owner.id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentStateTarget"], "avatar")
        expectNoDifference(approval.action.context.metadata["agentAvatarAction"], action)
        expectNoDifference(approval.action.context.metadata["agentAvatarPet"], expectedPet.rawValue)
        expectNoDifference(approval.action.context.metadata["previousAgentAvatarPet"], "dewey")
        expectNoDifference(approval.action.context.metadata["agentName"], owner.name)
        #expect(!approval.action.context.metadata.values.joined().contains("PRIVATE_"))
        expectNoDifference(model.agents.first { $0.id == owner.id }?.avatar, .pet(.dewey))
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        if mode == "stale" { owner.avatar = .pet(.seedy); #expect(await model.updateAgent(owner)) }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true) // A late click cannot resurrect it.
        let expected: AgentAvatar = .pet(mode == "approve" ? expectedPet : mode == "stale" ? .seedy : .dewey)
        let saved = try #require(model.agents.first { $0.id == owner.id })
        expectNoDifference(saved.avatar, expected)
        expectNoDifference(saved.name, original.name); expectNoDifference(saved.instructions, original.instructions)
        expectNoDifference(saved.modelID, original.modelID); expectNoDifference(saved.summary, original.summary)
        expectNoDifference(model.agents.first { $0.id == peer.id }?.avatar, peer.avatar)
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty && model.agentMessages.isEmpty)
        let restored = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restored.reloadWorkspaceData()
        expectNoDifference(restored.agents.first { $0.id == owner.id }?.avatar, expected)
    }

    @Test func mailboxAvatarIsBoundToRecipientNotSender() async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "avatar", name: "update_state",
                argumentsJSON: Data(#"{"target":"avatar","action":"set","pet_id":"fireball"}"#.utf8)))
            #expect(!result.isError)
            return "PASS"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Use Fireball for your avatar"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent", identifier: recipient.id.uuidString))
        expectNoDifference(approval.action.context.metadata["agentName"], recipient.name)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        expectNoDifference(model.agents.first { $0.id == recipient.id }?.avatar, .pet(.fireball))
        expectNoDifference(model.agents.first { $0.id == sender.id }?.avatar, sender.avatar)
        expectNoDifference(model.agentMessages.first?.delivery?.state, .completed)
    }

    @Test func avatarPreviewRendersInSevenLanguages() throws {
        let disclosure = "Only this agent's avatar changes. Names, private instructions, models and permissions stay unchanged. Reset restores Codex; no image files are deleted."
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for pet in AgentPetAvatar.allCases { #expect(PetAvatarImages.image(for: pet) != nil) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for action in ["set", "clear"] {
                try FiliconLocalization.$languageOverride.withValue(language) {
                    if language != "en" { #expect(FiliconLocalization.string(disclosure) != disclosure) }
                    let metadata = ["agentName": "Designer", "agentAvatarAction": action,
                                    "agentAvatarPet": action == "set" ? "hoots" : "codex",
                                    "previousAgentAvatarPet": action == "set" ? "dewey" : ""]
                    let host = NSHostingView(rootView: AgentAvatarApprovalDetails(metadata: metadata)
                        .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                    host.appearance = NSAppearance(named: .aqua)
                    host.frame = .init(x: 0, y: 0, width: 380, height: 390)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 390)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let data = try #require(bitmap.representation(using: .png, properties: [:]))
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try data.write(to: output.appending(path: "avatar-\(action)-\(language).png"))
                    }
                }
            }
        }
    }

    @Test(arguments: ["deny", "stop", "account"], [AgentMemory.Scope.agent, .user])
    func pendingMemoryWritesCannotBypassApprovalOrLifecycle(mode: String, scope: AgentMemory.Scope) async throws {
        let (root, model, groupID, owner, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            _ = try await execute(.init(id: "remember", name: "update_state",
                argumentsJSON: JSONEncoder().encode(["target": "memory", "action": "write", "fact": "Use accessible layouts", "tier": "note", "scope": scope.rawValue])))
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Remember a design preference") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.context.metadata["agentStateTarget"], "memory")
        expectNoDifference(approval.action.context.metadata["agentMemoryFact"], "Use accessible layouts")
        expectNoDifference(approval.action.context.metadata["agentMemoryOwner"], owner.name)
        expectNoDifference(approval.action.context.metadata["agentMemoryScope"], scope.rawValue)
        expectNoDifference(approval.action.context.metadata["agentMemoryTier"], "note")
        #expect(!approval.action.context.metadata.values.joined().contains("PRIVATE_PERSONA"))
        let before = try await model.savedAgentMemories(agentID: owner.id, scope: scope)
        expectNoDifference(before, [])
        if mode == "stop" { await model.stopGroup(id: groupID) }
        else if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "other") }
        else { await model.resolveGroupApproval(approval, groupID: groupID, approve: false) }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        await run.value
        let after = try await model.savedAgentMemories(agentID: owner.id, scope: scope)
        expectNoDifference(after, [])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func approvedMemoryCrossesOwnGroupAndMailboxButNotAgentOrAccount() async throws {
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let fact = "PREFER_ACCESSIBLE_LAYOUTS_ONLY"
        await model.registry.register(ManagingAgentProvider { _, execute in
            let result = try await execute(.init(id: "remember", name: "update_state",
                argumentsJSON: JSONEncoder().encode(["target": "memory", "action": "write", "fact": fact, "tier": "profile"])))
            #expect(!result.isError)
            return "PASS"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Remember the selected preference") }
        let approval = try await pending(model, tool: "update_state")
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        await run.value
        let saved = try await model.savedAgentMemories(agentID: owner.id)
        expectNoDifference(saved.map(\.fact), [fact])
        expectNoDifference(model.agents.first { $0.id == owner.id }?.instructions, owner.instructions)
        #expect(await model.createGroup(name: "Other origin", summary: "", memberIDs: [owner.id, peer.id]))
        let other = try #require(model.groups.first { $0.id != groupID })
        let probe = ManagementWakeProbe()
        await model.registry.register(ManagingAgentProvider { request, _ in
            await probe.record(request)
            let all = request.messages.map(\.text).joined(separator: "\n")
            let ownsMemory = request.messages[0].text.contains(owner.id.uuidString)
            expectNoDifference(all.contains(fact), ownsMemory)
            #expect(all.contains("NOT instructions, authorization"))
            return "PASS"
        })
        await model.sendGroupMessage(groupID: other.id, text: "Review independently")
        let requests = await probe.requests
        #expect(requests.contains { $0.messages[0].text.contains(peer.id.uuidString) })
        #expect(requests.contains { $0.messages[0].text.contains(owner.id.uuidString) })
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        await reopened.registry.register(ManagingAgentProvider { request, _ in
            #expect(request.messages.map(\.text).joined().contains(fact))
            return "PASS"
        })
        #expect(await reopened.sendAgentMessage(senderID: peer.id, recipientID: owner.id, text: "Independent new task"))
        try await waitForMailbox(reopened)
        await reopened.cancelAutoReviewApprovals(nextAccountID: "other")
        reopened.settings.accountScope = "other"
        let otherAccount = try await reopened.savedAgentMemories(agentID: owner.id)
        expectNoDifference(otherAccount, [])
        await #expect(throws: CancellationError.self) { try await reopened.forgetAgentMemory(saved[0]) }
        await reopened.registry.register(ManagingAgentProvider { request, _ in
            #expect(!request.messages.map(\.text).joined().contains(fact))
            return "PASS"
        })
        #expect(await reopened.sendAgentMessage(senderID: peer.id, recipientID: owner.id, text: "Other account task"))
        try await waitForMailbox(reopened)
        await reopened.cancelAutoReviewApprovals(nextAccountID: "local")
        reopened.settings.accountScope = nil
        try await reopened.forgetAgentMemory(saved[0]) // Same method invoked by the confirmed editor button.
        let forgotten = try await reopened.savedAgentMemories(agentID: owner.id)
        expectNoDifference(forgotten, [])
        await reopened.sendGroupMessage(groupID: other.id, text: "New request after forgetting")
    }

    @Test(arguments: [AgentMemory.Scope.agent, .user])
    func mailboxMemoryUsesRecipientIdentityAndForgetRequiresNewApproval(scope: AgentMemory.Scope) async throws {
        let (root, model, _, sender, recipient) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for action in ["write", "forget"] {
            await model.registry.register(ManagingAgentProvider { _, execute in
                var arguments = ["target": "memory", "action": action, "fact": "Designer preference", "scope": scope.rawValue]
                if action == "write" { arguments["tier"] = "note" }
                let result = try await execute(.init(id: ToolCallID(rawValue: "memory-\(action)"), name: "update_state",
                    argumentsJSON: JSONEncoder().encode(arguments)))
                #expect(!result.isError)
                return "PASS"
            })
            #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "Propose a memory change"))
            let approval = try await pending(model, tool: "update_state")
            expectNoDifference(approval.action.target, scope == .user ? .resource(kind: "shared-user-memory", identifier: "local")
                : .resource(kind: "agent", identifier: recipient.id.uuidString))
            expectNoDifference(approval.action.context.metadata["agentMemoryAction"], action)
            expectNoDifference(approval.action.context.metadata["agentMemoryScope"], scope.rawValue)
            expectNoDifference(approval.action.context.metadata["agentMemoryTier"], "note")
            await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
            try await waitForMailbox(model)
            let senderFacts = try await model.savedAgentMemories(agentID: sender.id)
            let recipientFacts = try await model.savedAgentMemories(agentID: recipient.id, scope: scope)
            expectNoDifference(senderFacts, [])
            expectNoDifference(recipientFacts.map(\.fact), action == "write" ? ["Designer preference"] : [])
            expectNoDifference(recipientFacts.map(\.agentID), action == "write" ? [recipient.id] : [])
        }
    }

    @Test(arguments: [AgentMemory.Scope.agent, .user], [AgentMemory.Tier.profile, .note])
    func memoryApprovalDetailsRenderInSevenLanguages(scope: AgentMemory.Scope, tier: AgentMemory.Tier) throws {
        let metadata = ["agentMemoryAction": "forget", "agentMemoryOwner": "Designer", "agentMemoryTier": tier.rawValue, "agentMemoryScope": scope.rawValue,
                        "agentMemoryFact": "Prefer accessible layouts with keyboard navigation and clear contrast.\n優先採用支援鍵盤操作、對比清晰的版面。"]
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
                let title = scope == .user ? "Forget shared user memory" : "Forget agent memory"
                if language != "en" { #expect(FiliconLocalization.string(title) != title) }
                if language != "en", tier == .note { #expect(l10n(tier.memoryTitleKey) != "Low-importance note") }
                let host = NSHostingView(rootView: AgentMemoryApprovalDetails(metadata: metadata).padding(20).frame(width: 420)
                    .background(FiliconTheme.input).environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 420, height: 550)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.height <= 550)
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                if let output {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try png.write(to: output.appending(path: "agent-memory-\(scope.rawValue)-\(tier.rawValue)-\(language).png"))
                }
            }
        }
    }

    @Test func sharedMemoryApprovalAudiencePersistenceAndUserForgettingAreWiredAcrossGroupAndMailbox() async throws {
        let (root, model, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let privateFact = "PRIVATE_OWNER_ONLY", sharedFact = "SHARED_ACCESSIBILITY_PREFERENCE"
        for scope in [AgentMemory.Scope.agent, .user] {
            let fact = scope == .agent ? privateFact : sharedFact
            await model.registry.register(ManagingAgentProvider { _, execute in
                let result = try await execute(.init(id: "remember", name: "update_state",
                    argumentsJSON: JSONEncoder().encode(["target": "memory", "action": "write", "fact": fact, "scope": scope.rawValue])))
                #expect(!result.isError)
                return "PASS"
            })
            let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Propose the selected fact") }
            let approval = try await pending(model, tool: "update_state")
            expectNoDifference(approval.action.context.metadata["agentMemoryScope"], scope.rawValue)
            expectNoDifference(approval.action.context.metadata["agentMemoryFact"], fact)
            if scope == .user {
                expectNoDifference(approval.action.target, .resource(kind: "shared-user-memory", identifier: "local"))
                let notYetShared = try await model.savedAgentMemories(agentID: peer.id, scope: .user)
                expectNoDifference(notYetShared, [])
                FiliconLocalization.$languageOverride.withValue("en") {
                    #expect(l10n(scope.memoryDisclosureKey).contains("future"))
                }
            }
            await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
            await run.value
        }
        #expect(await model.createGroup(name: "Independent group", summary: "", memberIDs: [owner.id, peer.id]))
        let independent = try #require(model.groups.first { $0.id != groupID })
        let probe = ManagementWakeProbe()
        await model.registry.register(ManagingAgentProvider { request, _ in
            await probe.record(request)
            let text = request.messages.map(\.text).joined()
            #expect(text.contains(sharedFact))
            expectNoDifference(text.contains(privateFact), request.messages[0].text.contains(owner.id.uuidString))
            return "PASS"
        })
        await model.sendGroupMessage(groupID: independent.id, text: "Review independently")
        let groupRequests = await probe.requests
        #expect(groupRequests.contains { $0.messages[0].text.contains(peer.id.uuidString) })
        #expect(groupRequests.contains { $0.messages[0].text.contains(owner.id.uuidString) })

        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await reopened.reloadWorkspaceData()
        await reopened.registry.register(ManagingAgentProvider { request, _ in
            let text = request.messages.map(\.text).joined()
            #expect(text.contains(sharedFact) && !text.contains(privateFact))
            return "PASS"
        })
        #expect(await reopened.sendAgentMessage(senderID: owner.id, recipientID: peer.id, text: "Independent mailbox task"))
        try await waitForMailbox(reopened)
        let shared = try await reopened.savedAgentMemories(agentID: peer.id, scope: .user)
        expectNoDifference(shared.map(\.agentID), [owner.id])
        expectNoDifference(shared.map(\.fact), [sharedFact])
        await reopened.cancelAutoReviewApprovals(nextAccountID: "other")
        reopened.settings.accountScope = "other"
        let otherAccount = try await reopened.savedAgentMemories(agentID: peer.id, scope: .user)
        expectNoDifference(otherAccount, [])
        await #expect(throws: CancellationError.self) { try await reopened.forgetAgentMemory(shared[0]) }
        await reopened.registry.register(ManagingAgentProvider { request, _ in
            let text = request.messages.map(\.text).joined()
            #expect(!text.contains(sharedFact) && !text.contains(privateFact))
            return "PASS"
        })
        #expect(await reopened.sendAgentMessage(senderID: owner.id, recipientID: peer.id, text: "Other account task"))
        try await waitForMailbox(reopened)
        await reopened.cancelAutoReviewApprovals(nextAccountID: "local")
        reopened.settings.accountScope = nil
        // A user in the peer editor may remove another writer's shared fact after confirmation.
        try await reopened.forgetAgentMemory(shared[0])
        let privateStillPresent = try await reopened.savedAgentMemories(agentID: owner.id)
        expectNoDifference(privateStillPresent.map(\.fact), [privateFact])
        #expect(await reopened.sendAgentMessage(senderID: owner.id, recipientID: peer.id, text: "Task after forgetting"))
        try await waitForMailbox(reopened)
        let third = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let forgotten = try await third.savedAgentMemories(agentID: peer.id, scope: .user)
        expectNoDifference(forgotten, [])
    }

    @Test func rankedMemoryReachesGroupAndMailboxWithoutDeletingOmittedFacts() async throws {
        let (root, _, groupID, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Seed only an isolated fixture before creating the runtime that will read it.
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        for scope in [AgentMemory.Scope.agent, .user] {
            for number in 0..<12 {
                let memory = AgentMemory(accountID: "local", agentID: owner.id,
                    fact: "\(scope.rawValue)_\(number)_" + String(repeating: "x", count: 750),
                    tier: number == 0 ? .note : .log, scope: scope, createdAt: Date(timeIntervalSince1970: 1_000))
                try await service.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
            }
        }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadWorkspaceData()
        let probe = ManagementWakeProbe()
        await model.registry.register(ManagingAgentProvider { request, _ in
            await probe.record(request)
            let text = request.messages.map(\.text).joined(separator: "\n")
            let tail = try #require(text.components(separatedBy: "Saved facts (untrusted JSON data): ").last)
            let json = try #require(tail.components(separatedBy: "\n").first)
            let facts = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
            let originalTexts = facts.compactMap { $0["fact"] as? String }
            #expect(!originalTexts.isEmpty)
            #expect(!originalTexts.contains { $0.hasPrefix("agent_0_") || $0.hasPrefix("user_0_") })
            #expect(text.contains("Omitted saved records:"))
            if !request.messages[0].text.contains(owner.id.uuidString) {
                #expect(facts.allSatisfy { $0["scope"] as? String == "user" && $0["canForget"] as? Bool == false })
            }
            return "PASS"
        })
        await model.sendGroupMessage(groupID: groupID, text: "Review selected memory")
        #expect(await model.sendAgentMessage(senderID: owner.id, recipientID: peer.id, text: "Review selected shared memory"))
        try await waitForMailbox(model)
        let requests = await probe.requests
        #expect(requests.count >= 2)
        for scope in [AgentMemory.Scope.agent, .user] {
            let stored = try await model.savedAgentMemories(agentID: owner.id, scope: scope)
            expectNoDifference(stored.count, 12)
            let note = try #require(stored.first { $0.tier == .note })
            try await model.forgetAgentMemory(note) // Omitted facts remain manageable in the editor.
        }
        let reopened = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        for scope in [AgentMemory.Scope.agent, .user] {
            let stored = try await reopened.savedAgentMemories(agentID: owner.id, scope: scope)
            expectNoDifference(stored.count, 11)
            #expect(stored.allSatisfy { $0.tier == .log })
        }
    }

    @Test(arguments: [false, true])
    func searchReadsUninjectedFactsOnlyForOwnerWithoutLeakingIntoRoomOrMailbox(manualMailbox: Bool) async throws {
        let (root, _, _, owner, peer) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "HISTORIC_PRIVATE_FACT"
        let service = try AgentService(storeURL: root.appending(path: "agents.json"))
        for number in 0..<32 {
            let memory = AgentMemory(accountID: "local", agentID: owner.id,
                fact: number == 0 ? secret : "GENERAL \(number) " + String(repeating: "x", count: 200),
                createdAt: Date(timeIntervalSince1970: Double(number)))
            try await service.applyMemoryChange(.init(operation: .write, memory: memory), lifetime: .init())
        }
        let before = try Data(contentsOf: root.appending(path: "agents.json"))
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.reloadWorkspaceData()
        #expect(await model.createGroup(name: "Search room", summary: "", memberIDs: [owner.id, peer.id]))
        let group = try #require(model.groups.first { $0.name == "Search room" })
        let probe = ManagementWakeProbe()
        await model.registry.register(ManagingAgentProvider { request, execute in
            await probe.record(request)
            #expect(request.tools.contains { $0.name == "SearchMemory" })
            #expect(!request.messages.map(\.text).joined().contains(secret)) // Omitted from recall AND earlier tool metadata.
            let result = try await execute(.init(id: "search", name: "SearchMemory",
                argumentsJSON: JSONEncoder().encode(["query": secret])))
            #expect(!result.isError)
            let json = try #require(JSONSerialization.jsonObject(with: Data(result.wireText.utf8)) as? [String: Any])
            let facts = try #require(json["facts"] as? [[String: Any]])
            let ownsMemory = request.messages[0].text.contains(owner.id.uuidString)
            expectNoDifference(facts.compactMap { $0["fact"] as? String }, ownsMemory ? [secret] : [])
            #expect(result.wireText.utf8.count <= 8_192)
            return "PASS"
        })
        if manualMailbox {
            #expect(await model.sendAgentMessage(senderID: peer.id, recipientID: owner.id, text: "Find older information"))
            try await waitForMailbox(model)
            #expect(await model.sendAgentMessage(senderID: owner.id, recipientID: peer.id, text: "Find older information"))
            try await waitForMailbox(model)
        } else {
            await model.sendGroupMessage(groupID: group.id, text: "Find older information")
        }
        let requests = await probe.requests
        #expect(requests.contains { $0.messages[0].text.contains(owner.id.uuidString) })
        #expect(requests.contains { $0.messages[0].text.contains(peer.id.uuidString) })
        #expect(model.pendingAutoReviewApprovals.isEmpty && model.runningGroups.isEmpty && model.runningAgentMessageScopes.isEmpty)
        let messages = model.groupMessages[group.id] ?? []
        #expect(!String(decoding: try JSONEncoder().encode(messages), as: UTF8.self).contains(secret))
        #expect(!String(decoding: try JSONEncoder().encode(model.agentMessages), as: UTF8.self).contains(secret))
        let after = try Data(contentsOf: root.appending(path: "agents.json"))
        expectNoDifference(after, before)
    }

    @Test func creationAndSubsequentDelegationRequireSeparateApproval() async throws {
        let (root, model, groupID, sender, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = ManagementWakeProbe()
        let description = String(repeating: "Write accessible product copy. ", count: 60) + "END_OF_REVIEWED_DESCRIPTION"
        await model.registry.register(ManagingAgentProvider { request, execute in
            #expect(request.tools.contains { $0.name == "CreateAgent" })
            #expect(request.tools.contains { $0.name == "UpdateAgent" })
            if request.messages.last?.text.hasPrefix("Incoming peer message") == true {
                await probe.record(request)
                return "Copy review completed"
            }
            let created = try await execute(.init(id: "create", name: "CreateAgent",
                                                  argumentsJSON: JSONEncoder().encode(["name": "Writer", "description": description])))
            #expect(!created.isError)
            let json = try #require(JSONSerialization.jsonObject(with: Data(created.wireText.utf8)) as? [String: String])
            let id = try #require(json["id"])
            let delegated = try await execute(.init(id: "delegate", name: "SendToAgent",
                                                    argumentsJSON: JSONEncoder().encode(["recipientID": id, "message": "Review the headline only"])))
            #expect(!delegated.isError)
            return "Review queued"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Create a writer and ask for a headline review") }
        let createApproval = try await pending(model, tool: "CreateAgent")
        expectNoDifference(createApproval.action.context.metadata["agentDescription"], description)
        expectNoDifference(createApproval.action.context.metadata["agentProvider"], "management-fixture")
        expectNoDifference(createApproval.action.context.metadata["agentModel"], "test")
        expectNoDifference(model.agents.count, 2)
        expectNoDifference(model.agentMessages.count, 0)
        await model.resolveGroupApproval(createApproval, groupID: groupID, approve: true)
        let delegationApproval = try await pending(model, tool: "SendToAgent")
        let created = try #require(model.agents.first { $0.name == "Writer" })
        expectNoDifference(created.instructions, description)
        expectNoDifference(model.groups.first?.memberIDs, [sender.id])
        expectNoDifference(model.agentMessages.count, 0)
        expectNoDifference(delegationApproval.action.target, .recipient(identifier: created.id.uuidString))
        let before = await probe.requests
        expectNoDifference(before.count, 0)
        await model.resolveGroupApproval(delegationApproval, groupID: groupID, approve: true)
        await run.value
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
        let transcript = try #require(requests.first).messages.map(\.text).joined(separator: "\n")
        #expect(transcript.contains(description))
        #expect(transcript.contains("Review the headline only"))
        #expect(!transcript.contains("ENGINEER_PRIVATE_PERSONA"))
        #expect(!transcript.contains("DESIGNER_PRIVATE_PERSONA"))
        expectNoDifference(model.agentMessages.map { $0.delivery?.state }, [.completed])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(groupID))
    }

    @Test(arguments: ["deny", "stop", "account"], ["CreateAgent", "update_state"])
    func rejectedOrInvalidatedProfileChangesNeverWrite(mode: String, tool: String) async throws {
        let (root, model, groupID, _, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { _, execute in
            let args = tool == "CreateAgent" ? ["name": "Writer"] : ["target": "profile", "action": "set", "name": "New own name"]
            let result = try await execute(.init(id: "change", name: .init(rawValue: tool), argumentsJSON: JSONEncoder().encode(args)))
            #expect(result.isError)
            return "No change was made"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Create a writer") }
        let approval = try await pending(model, tool: tool)
        let names = model.agents.map(\.name)
        if mode == "stop" { await model.stopGroup(id: groupID) }
        if mode == "account" { await model.cancelAutoReviewApprovals(nextAccountID: "different-account") }
        await model.resolveGroupApproval(approval, groupID: groupID, approve: mode != "deny")
        await run.value
        expectNoDifference(model.agents.count, 2)
        expectNoDifference(model.agents.map(\.name), names)
        expectNoDifference(model.agentMessages, [])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(groupID))
    }

    @Test(arguments: [false, true]) func updatesAreAvailableInGroupAndManualMailbox(manual: Bool) async throws {
        let (root, model, groupID, sender, target) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = manual ? sender : target
        await model.registry.register(ManagingAgentProvider { request, execute in
            #expect(request.tools.contains { $0.name == "UpdateAgent" })
            let result = try await execute(.init(id: "update", name: "UpdateAgent",
                                                 argumentsJSON: JSONEncoder().encode(["agent_id": changed.id.uuidString, "name": "Reviewed name"])))
            #expect(!result.isError)
            return "Profile updated"
        })
        let run: Task<Void, Never>?
        if manual {
            #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: target.id, text: "Rename the engineer"))
            run = nil
        } else {
            run = Task { await model.sendGroupMessage(groupID: groupID, text: "Rename the designer") }
        }
        let approval = try await pending(model, tool: "UpdateAgent")
        expectNoDifference(approval.action.context.metadata["previousAgentName"], changed.name)
        expectNoDifference(approval.action.context.metadata["previousAgentDescription"], changed.summary)
        expectNoDifference(approval.action.context.metadata["agentName"], "Reviewed name")
        expectNoDifference(model.agents.first { $0.id == changed.id }?.name, changed.name)
        let scope = approval.action.context.conversationID
        await model.resolveGroupApproval(approval, groupID: scope, approve: true)
        await run?.value
        if manual { try await waitForMailbox(model) }
        let updated = try #require(model.agents.first { $0.id == changed.id })
        expectNoDifference(updated.name, "Reviewed name")
        expectNoDifference(updated.summary, changed.summary)
        expectNoDifference(updated.instructions, changed.instructions)
        expectNoDifference(updated.providerID, changed.providerID)
        expectNoDifference(updated.modelID, changed.modelID)
        expectNoDifference(model.groups.first?.memberIDs, [sender.id])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func approvalDetailsRenderInSevenLanguages() throws {
        let metadata = ["tool": "UpdateAgent", "previousAgentName": "Designer", "agentName": "Accessibility reviewer",
                        "previousAgentDescription": "Visual review", "agentDescription": "Review keyboard navigation, contrast and mobile layouts.\n檢查鍵盤導覽、對比與手機版配置。"]
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
                let host = NSHostingView(rootView: AgentProfileApprovalDetails(metadata: metadata)
                    .padding(20).frame(width: 480, alignment: .leading)
                    .background(FiliconTheme.input)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(!png.isEmpty)
                if let output { try png.write(to: output.appending(path: "agent-profile-\(language).png")) }
            }
        }
    }

    @Test func ownProfileChangeRefreshesTheNextGroupTurnWithoutChangingMembership() async throws {
        let (root, model, groupID, sender, target) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await model.saveGroupSettings(groupID: groupID, name: "Implementation", summary: "", memberIDs: [sender.id, target.id]))
        let probe = ManagementWakeProbe()
        await model.registry.register(ManagingAgentProvider { request, execute in
            await probe.record(request)
            let persona = request.messages[0].text
            if persona.contains(sender.id.uuidString) {
                if persona.contains("Your name is Engineer,") {
                    let result = try await execute(.init(id: "self-update", name: "update_state",
                        argumentsJSON: Data(#"{"target":"profile","action":"set","name":"Project engineer","description":"Implementation and accessibility"}"#.utf8)))
                    #expect(!result.isError)
                    return "Profile updated after user approval"
                }
                #expect(persona.contains("Your name is Project engineer,"))
                #expect(persona.contains("Implementation and accessibility"))
                #expect(persona.contains("ENGINEER_PRIVATE_PERSONA"))
                return "PASS"
            }
            #expect(persona.contains("DESIGNER_PRIVATE_PERSONA"))
            #expect(!request.messages.map(\.text).joined().contains("ENGINEER_PRIVATE_PERSONA"))
            let metadata = request.messages.first { $0.text.hasPrefix("Room metadata") }?.text ?? ""
            #expect(metadata.contains("Project engineer"))
            return "The design review is complete"
        })
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Rename the engineer and then review the design together") }
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent", identifier: sender.id.uuidString))
        expectNoDifference(approval.action.context.metadata["previousAgentName"], "Engineer")
        expectNoDifference(approval.action.context.metadata["agentName"], "Project engineer")
        #expect(!approval.action.context.metadata.values.joined().contains("ENGINEER_PRIVATE_PERSONA"))
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        await run.value
        let requests = await probe.requests
        let engineerTurns = requests.filter { $0.messages[0].text.contains(sender.id.uuidString) }
        expectNoDifference(engineerTurns.count, 2)
        expectNoDifference(model.groups.first?.memberIDs, [sender.id, target.id])
        expectNoDifference(model.agents.first { $0.id == sender.id }?.name, "Project engineer")
        expectNoDifference(model.agents.first { $0.id == sender.id }?.instructions, sender.instructions)
        #expect(model.pendingAutoReviewApprovals.isEmpty)
    }

    @Test func mailboxSelfUpdateUsesTheRecipientIdentityAndCanClearPublicSummary() async throws {
        let (root, model, _, sender, target) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await model.registry.register(ManagingAgentProvider { request, execute in
            #expect(request.messages[0].text.contains(target.id.uuidString))
            let result = try await execute(.init(id: "clear-summary", name: "update_state",
                argumentsJSON: Data(#"{"target":"profile","action":"set","description":""}"#.utf8)))
            #expect(!result.isError)
            return "Public summary cleared"
        })
        #expect(await model.sendAgentMessage(senderID: sender.id, recipientID: target.id, text: "Clear your public summary"))
        let approval = try await pending(model, tool: "update_state")
        expectNoDifference(approval.action.target, .resource(kind: "agent", identifier: target.id.uuidString))
        expectNoDifference(approval.action.context.metadata["previousAgentDescription"], "Visual review")
        expectNoDifference(approval.action.context.metadata["agentDescription"], "")
        expectNoDifference(model.agents.first { $0.id == target.id }?.summary, target.summary)
        await model.resolveGroupApproval(approval, groupID: approval.action.context.conversationID, approve: true)
        try await waitForMailbox(model)
        let actual = try #require(model.agents.first { $0.id == target.id })
        expectNoDifference(actual.summary, "")
        expectNoDifference(actual.instructions, target.instructions)
        expectNoDifference(actual.name, target.name)
        expectNoDifference(model.agents.first { $0.id == sender.id }?.name, sender.name)
        expectNoDifference(model.agentMessages.map { $0.delivery?.state }, [.completed])
    }

    @Test func ownProfileApprovalRendersExplicitEmptyValueInSevenLanguages() throws {
        let metadata = ["tool": "update_state", "previousAgentName": "設計師", "agentName": "設計師",
                        "previousAgentDescription": "Visual review", "agentDescription": ""]
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
                for key in ["Update own profile", "Empty"] where language != "en" {
                    #expect(FiliconLocalization.string(key) != key)
                }
                let host = NSHostingView(rootView: AgentProfileApprovalDetails(metadata: metadata)
                    .padding(20).frame(width: 480, alignment: .leading).background(FiliconTheme.input)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(!png.isEmpty)
                if let output { try png.write(to: output.appending(path: "own-profile-\(language).png")) }
            }
        }
    }
}
