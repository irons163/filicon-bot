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

    @Test func routinePreviewRendersInSevenLanguages() throws {
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for action in ["pause", "resume", "delete"] {
                try FiliconLocalization.$languageOverride.withValue(language) {
                    let title = action == "delete" ? "Delete own routine" : action == "pause" ? "Pause own routine" : "Resume own routine"
                    if language != "en" { #expect(FiliconLocalization.string(title) != title) }
                    let metadata = ["agentName": "Designer", "agentRoutineAction": action, "agentRoutineName": "Daily design review",
                                    "agentRoutineID": "00000000-0000-0000-0000-000000000010",
                                    "agentRoutinePrompt": "Review accessible contrast. Do not publish.",
                                    "agentRoutineTrigger": "{\n  cron: {\n    expression: 0 9 * * *,\n    timeZoneIdentifier: Asia/Taipei\n  }\n}"]
                    let host = NSHostingView(rootView: AgentRoutineApprovalDetails(metadata: metadata)
                        .padding(20).frame(width: 380).background(FiliconTheme.canvas)
                        .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, .light))
                    host.appearance = NSAppearance(named: .aqua)
                    host.frame = .init(x: 0, y: 0, width: 380, height: 500)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.height <= 500)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appending(path: "routine-\(action)-\(language).png"))
                    }
                }
            }
        }
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
