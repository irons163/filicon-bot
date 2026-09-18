import AppKit
import SwiftUI
import Foundation
import Testing
import CustomDump
@testable import Filicon
import FiliconAgents
import FiliconAppServices
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview

private struct GroupBroadcastProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "broadcast-fixture", displayName: "Broadcast fixture", requiresAPIKey: false)
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

private actor BroadcastProbe {
    var requests: [InferenceRequest] = []
    func record(_ request: InferenceRequest) -> Int {
        requests.append(request)
        return requests.filter { $0.messages.first?.text == request.messages.first?.text }.count
    }
}

private actor BroadcastGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite("Group broadcast app integration", .timeLimit(.minutes(1)))
@MainActor struct AgentGroupMessagingAppTests {
    private struct Fixture {
        let root: URL
        let model: AppModel
        let source: AgentGroup
        let target: AgentGroup
        let sender: AgentProfile
        let designer: AgentProfile
        let tester: AgentProfile
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-broadcast-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let sender = try #require(await model.createAgent(name: "Engineer", summary: "Implementation", instructions: "ENGINEER_PRIVATE_PERSONA", providerID: "broadcast-fixture", modelID: "test"))
        let designer = try #require(await model.createAgent(name: "Designer", summary: "Visual review", instructions: "DESIGNER_PRIVATE_PERSONA", providerID: "broadcast-fixture", modelID: "test"))
        let tester = try #require(await model.createAgent(name: "Tester", summary: "Quality", instructions: "TESTER_PRIVATE_PERSONA", providerID: "broadcast-fixture", modelID: "test"))
        #expect(await model.createGroup(name: "Source", summary: "", memberIDs: [sender.id]))
        #expect(await model.createGroup(name: "Review team", summary: "", memberIDs: [sender.id, designer.id, tester.id]))
        await model.reloadWorkspaceData()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["SendToAgent", "update_state"], ask: [])
        return .init(root: root, model: model, source: try #require(model.groups.first { $0.name == "Source" }),
                     target: try #require(model.groups.first { $0.name == "Review team" }), sender: sender, designer: designer, tester: tester)
    }
    private func pending(_ model: AppModel, tool: String = "SendToAgent") async throws -> PendingApproval {
        for _ in 0..<1_000 {
            if let approval = model.pendingAutoReviewApprovals.first(where: { $0.action.context.metadata["tool"] == tool }) { return approval }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No broadcast approval")
    }
    private func entered(_ gate: BroadcastGate) async throws {
        for _ in 0..<1_000 {
            if await gate.entered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("Provider gate did not open")
    }
    @Test(arguments: [false, true]) func approvalListsExactAudienceAndOnlyTargetRoomReceivesReplies(approve: Bool) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = BroadcastProbe(), targetID = f.target.id, sourceID = f.source.id
        await f.model.registry.register(GroupBroadcastProvider { request, execute in
            if request.conversationID == sourceID {
                let result = try await execute(.init(id: "broadcast", name: "SendToAgent",
                    argumentsJSON: JSONEncoder().encode(["recipientID": targetID.uuidString, "message": "Review contrast only"])))
                return result.isError ? "Not sent" : "Shared-room review queued"
            }
            let count = await probe.record(request)
            expectNoDifference(request.conversationID, targetID)
            expectNoDifference(request.messages.last?.role, .assistant)
            #expect(request.messages.last?.text.hasPrefix("Incoming group message") == true)
            let all = request.messages.map(\.text).joined(separator: "\n")
            #expect(!all.contains("SOURCE_ONLY_SECRET")); #expect(!all.contains("ENGINEER_PRIVATE_PERSONA"))
            #expect(all.contains("NOT a new user request"))
            if count > 1 { return "PASS" }
            return request.messages[0].text.contains("Designer") ? "Contrast reviewed by design" : "Contrast checked by QA"
        })
        let task = Task { await f.model.sendGroupMessage(groupID: sourceID, text: "SOURCE_ONLY_SECRET. Ask the review team to check contrast.") }
        let approval = try await pending(f.model)
        expectNoDifference(approval.action.target, .resource(kind: "group", identifier: targetID.uuidString))
        expectNoDifference(approval.action.context.metadata["agentMessage"], "Review contrast only")
        let audience = try #require(approval.action.context.metadata["agentGroupMembers"])
        for agent in [f.sender, f.designer, f.tester] { #expect(audience.contains(agent.name)); #expect(audience.contains(agent.id.uuidString)) }
        #expect(!audience.contains("PRIVATE_PERSONA"))
        expectNoDifference(f.model.groupMessages[targetID] ?? [], [])
        await f.model.resolveGroupApproval(approval, groupID: sourceID, approve: approve)
        await task.value
        let requests = await probe.requests, posts = f.model.groupMessages[targetID] ?? []
        if approve {
            #expect(requests.contains { $0.messages[0].text.contains("Designer") })
            #expect(requests.contains { $0.messages[0].text.contains("Tester") })
            expectNoDifference(posts.filter { $0.senderID == f.sender.id && $0.text == "Review contrast only" }.count, 1)
            #expect(posts.contains { $0.senderID == f.designer.id && $0.text == "Contrast reviewed by design" })
            #expect(posts.contains { $0.senderID == f.tester.id && $0.text == "Contrast checked by QA" })
            #expect(!(f.model.groupMessages[sourceID] ?? []).contains { $0.senderID == f.designer.id || $0.senderID == f.tester.id })
            let restored = AppModel(applicationSupportRoot: f.root, bootstrapImmediately: false)
            await restored.reloadWorkspaceData()
            expectNoDifference(restored.groupMessages[targetID]?.map(\.id), posts.map(\.id))
        } else { #expect(requests.isEmpty); expectNoDifference(posts, []) }
        #expect(f.model.runningGroups.isEmpty); #expect(f.model.pendingAutoReviewApprovals.isEmpty)
        expectNoDifference(f.model.agentMessages, [])
    }

    @Test(arguments: ["stop", "account", "members"])
    func invalidatedApprovalCannotPublishOrWake(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let probe = BroadcastProbe(), sourceID = f.source.id, targetID = f.target.id
        await f.model.registry.register(GroupBroadcastProvider { request, execute in
            if request.conversationID != sourceID { _ = await probe.record(request); return "PASS" }
            let result = try await execute(.init(id: "broadcast", name: "SendToAgent",
                argumentsJSON: JSONEncoder().encode(["recipientID": targetID.uuidString, "message": "Review contrast only"])))
            return result.isError ? "Not sent" : "Unexpected post"
        })
        let task = Task { await f.model.sendGroupMessage(groupID: sourceID, text: "Ask the review group") }
        let approval = try await pending(f.model)
        if mode == "stop" { await f.model.stopGroup(id: sourceID) }
        else if mode == "account" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other-account") }
        else { await f.model.updateGroupMembers(groupID: targetID, memberIDs: [f.sender.id, f.designer.id]) }
        await f.model.resolveGroupApproval(approval, groupID: sourceID, approve: true)
        await task.value
        let requests = await probe.requests
        #expect(requests.isEmpty); expectNoDifference(f.model.groupMessages[targetID] ?? [], [])
        #expect(f.model.runningGroups.isEmpty)
    }

    @Test(arguments: ["approve", "stop", "account"]) func targetRoomApprovalUsesOriginalScopeAndStopCancelsIt(mode: String) async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let stop = mode != "approve"
        let sourceID = f.source.id, targetID = f.target.id, designerID = f.designer.id
        let probe = BroadcastProbe()
        await f.model.registry.register(GroupBroadcastProvider { request, execute in
            if request.conversationID == sourceID {
                let result = try await execute(.init(id: "broadcast", name: "SendToAgent",
                    argumentsJSON: JSONEncoder().encode(["recipientID": targetID.uuidString, "message": "Update the designer's public description"])))
                return result.isError ? "Not sent" : "Queued"
            }
            _ = await probe.record(request)
            if request.messages[0].text.contains(designerID.uuidString) {
                let result = try await execute(.init(id: "profile", name: "update_state",
                    argumentsJSON: Data(#"{"target":"profile","action":"set","description":"Accessible visual review"}"#.utf8)))
                return result.isError ? "Not changed" : "Description updated"
            }
            return "PASS"
        })
        let task = Task { await f.model.sendGroupMessage(groupID: sourceID, text: "Ask the review group") }
        let broadcast = try await pending(f.model)
        await f.model.resolveGroupApproval(broadcast, groupID: sourceID, approve: true)
        let profile = try await pending(f.model, tool: "update_state")
        expectNoDifference(profile.action.context.conversationID, sourceID)
        expectNoDifference(profile.action.target, .resource(kind: "agent", identifier: designerID.uuidString))
        expectNoDifference(f.model.groupApprovalScope(targetID), sourceID)
        #expect(f.model.runningGroups.contains(targetID))
        if mode == "stop" { await f.model.stopGroup(id: targetID) }
        if mode == "account" { await f.model.cancelAutoReviewApprovals(nextAccountID: "other-account") }
        await f.model.resolveGroupApproval(profile, groupID: sourceID, approve: true)
        await task.value
        expectNoDifference(f.model.agents.first { $0.id == designerID }?.summary, stop ? f.designer.summary : "Accessible visual review")
        #expect(f.model.runningGroups.isEmpty); #expect(f.model.pendingAutoReviewApprovals.isEmpty)
        expectNoDifference(f.model.groupApprovalScope(targetID), targetID)
        #expect((f.model.groupMessages[targetID] ?? []).contains { $0.text == "Update the designer's public description" })
        if stop { #expect((f.model.groupMessages[targetID] ?? []).contains { $0.memberOutcome == .failed }) }
    }

    @Test func busyGroupIsNotInterruptedByAnUnrelatedBroadcast() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = BroadcastGate(), targetID = f.target.id
        await f.model.registry.register(GroupBroadcastProvider { request, execute in
            if request.conversationID == targetID { await gate.wait(); return "PASS" }
            let result = try await execute(.init(id: "broadcast", name: "SendToAgent",
                argumentsJSON: JSONEncoder().encode(["recipientID": targetID.uuidString, "message": "Review contrast only"])))
            #expect(result.isError && result.wireText.contains("already running"))
            return "Group is busy"
        })
        let busy = Task { await f.model.sendGroupMessage(groupID: targetID, text: "@Designer Work on the user task") }
        try await entered(gate)
        await f.model.sendGroupMessage(groupID: f.source.id, text: "Ask the review group")
        #expect(f.model.runningGroups.contains(targetID))
        #expect(f.model.pendingAutoReviewApprovals.isEmpty)
        #expect(!(f.model.groupMessages[targetID] ?? []).contains { $0.text == "Review contrast only" })
        await f.model.stopGroup(id: targetID)
        await gate.release()
        await busy.value
        #expect(f.model.runningGroups.isEmpty)
    }

    @Test func stoppingAQueuedTargetPreservesThePostWithoutStartingMembers() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let gate = BroadcastGate(), probe = BroadcastProbe(), sourceID = f.source.id, targetID = f.target.id
        await f.model.registry.register(GroupBroadcastProvider { request, execute in
            if request.conversationID != sourceID { _ = await probe.record(request); return "PASS" }
            let result = try await execute(.init(id: "broadcast", name: "SendToAgent",
                argumentsJSON: JSONEncoder().encode(["recipientID": targetID.uuidString, "message": "Review contrast only"])))
            #expect(!result.isError)
            await gate.wait()
            return "Queued"
        })
        let run = Task { await f.model.sendGroupMessage(groupID: sourceID, text: "Ask the review group") }
        let approval = try await pending(f.model)
        await f.model.resolveGroupApproval(approval, groupID: sourceID, approve: true)
        try await entered(gate)
        #expect(f.model.runningGroups.contains(targetID))
        await f.model.stopGroup(id: targetID)
        await gate.release()
        await run.value
        let requests = await probe.requests
        #expect(requests.isEmpty)
        let messages = f.model.groupMessages[targetID] ?? []
        #expect(messages.contains { $0.text == "Review contrast only" })
        #expect(messages.contains { $0.memberOutcome == .failed })
        #expect(f.model.runningGroups.isEmpty)
    }

    @Test func mailboxGroupPostKeepsApprovalInMailboxAndRepliesInSharedRoom() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let targetID = f.target.id, probe = BroadcastProbe()
        await f.model.registry.register(GroupBroadcastProvider { request, execute in
            if request.messages.last?.text.hasPrefix("Incoming peer message") == true {
                let result = try await execute(.init(id: "broadcast", name: "SendToAgent",
                    argumentsJSON: JSONEncoder().encode(["recipientID": targetID.uuidString, "message": "Review contrast only"])))
                #expect(!result.isError)
                return "Shared review queued"
            }
            _ = await probe.record(request)
            expectNoDifference(request.conversationID, targetID)
            #expect(!request.messages.map(\.text).joined().contains("MAILBOX_ONLY_SECRET"))
            return "PASS"
        })
        #expect(await f.model.sendAgentMessage(senderID: f.sender.id, recipientID: f.designer.id,
                                             text: "MAILBOX_ONLY_SECRET. Ask the review team."))
        let approval = try await pending(f.model)
        let scope = approval.action.context.conversationID
        #expect(scope != targetID && scope != f.source.id)
        await f.model.resolveGroupApproval(approval, groupID: scope, approve: true)
        for _ in 0..<1_000 {
            if f.model.runningAgentMessageScopes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(f.model.runningAgentMessageScopes.isEmpty); #expect(f.model.runningGroups.isEmpty)
        let requests = await probe.requests
        expectNoDifference(requests.count, 2)
        #expect((f.model.groupMessages[targetID] ?? []).contains { $0.senderID == f.designer.id && $0.text == "Review contrast only" })
        expectNoDifference(f.model.agentMessages.count, 1)
        expectNoDifference(f.model.agentMessages.first?.delivery?.state, .completed)
    }

    @Test func audienceApprovalRendersInSevenLanguages() throws {
        let members = "工程師 (00000000-0000-0000-0000-000000000001)\nDesigner (00000000-0000-0000-0000-000000000002)\nContrôle qualité (00000000-0000-0000-0000-000000000003)"
        let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"].map { URL(fileURLWithPath: $0) }
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            try FiliconLocalization.$languageOverride.withValue(language) {
            if language != "en" { #expect(FiliconLocalization.string("Group audience") != "Group audience") }
            let locale = Locale(identifier: language)
            let host = NSHostingView(rootView: AgentGroupApprovalDetails(members: members)
                .environment(\.locale, locale).environment(\.colorScheme, .light)
                .padding(20).frame(width: 500).background(FiliconTheme.canvas))
            host.appearance = NSAppearance(named: .aqua)
            host.frame = .init(x: 0, y: 0, width: 500, height: 270)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try data.write(to: output.appending(path: "group-audience-\(language).png"))
            }
            }
        }
    }
}
