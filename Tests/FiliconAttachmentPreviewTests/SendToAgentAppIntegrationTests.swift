import Foundation
import Testing
import CustomDump
@testable import Filicon
import FiliconAgents
import FiliconDomain
import FiliconProviderKit
import FiliconAutoReview

private actor AgentWakeProbe {
    var wakes: [UUID] = []
    func record(_ id: UUID) { wakes.append(id) }
}

private struct DelegatingGroupProvider: InteractiveToolProvider {
    let descriptor = ProviderDescriptor(id: "delegate-fixture", displayName: "Delegation fixture", requiresAPIKey: false)
    let sender: UUID
    let recipient: UUID
    let probe: AgentWakeProbe
    func models() async throws -> [AIModel] { [.init(id: "test")] }
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ProviderError.invalidResponse) }
    }
    func stream(_ request: InferenceRequest, executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let inbound = request.messages.last?.text.hasPrefix("Incoming peer message") == true
                    let isDesigner = request.messages[0].text.contains("You are Designer,")
                    let text: String
                    if inbound && !isDesigner {
                        await probe.record(sender)
                        #expect(request.messages.last?.text.contains("Improve contrast") == true)
                        text = "Updated implementation after the designer's review"
                    } else {
                        if inbound { await probe.record(recipient) }
                        let args = ["recipientID": (inbound ? sender : recipient).uuidString,
                                    "message": inbound ? "Improve contrast" : "Review just the button contrast"]
                        let result = try await executeTool(.init(id: "delegate", name: "SendToAgent", argumentsJSON: JSONEncoder().encode(args)))
                        text = result.isError ? "Delegation was not sent" : (inbound ? "Design review sent" : "Queued design review")
                    }
                    continuation.yield(.textDelta(text)); continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@Suite("SendToAgent app integration", .timeLimit(.minutes(1)))
@MainActor struct SendToAgentAppIntegrationTests {
    private func fixture() async throws -> (URL, AppModel, UUID, UUID, UUID, AgentWakeProbe) {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-delegating-app-\(UUID())")
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let sender = try #require(await model.createAgent(name: "Engineer", summary: "", instructions: "", providerID: "delegate-fixture", modelID: "test"))
        let recipient = try #require(await model.createAgent(name: "Designer", summary: "", instructions: "", providerID: "delegate-fixture", modelID: "test"))
        // Deliberately NOT a group member: no implicit @everyone expansion.
        #expect(await model.createGroup(name: "Implementation", summary: "", memberIDs: [sender.id]))
        await model.reloadWorkspaceData()
        await model.setAutoReviewEnabled(true)
        await model.setAutoReviewRules(allow: ["SendToAgent"], ask: [])
        let probe = AgentWakeProbe()
        await model.registry.register(DelegatingGroupProvider(sender: sender.id, recipient: recipient.id, probe: probe))
        return (root, model, try #require(model.groups.first?.id), sender.id, recipient.id, probe)
    }

    private func pending(_ model: AppModel) async throws -> PendingApproval {
        for _ in 0..<600 {
            if let value = model.pendingAutoReviewApprovals.first { return value }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PendingApprovalError.stale("No delegation approval appeared")
    }

    @Test(arguments: [false, true]) func newPeerRequiresExactApprovalThenReplyWakesOriginal(approve: Bool) async throws {
        let (root, model, groupID, sender, recipient, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Ask the designer for a contrast review") }
        let request = try await pending(model)
        expectNoDifference(request.action.target, .recipient(identifier: recipient.uuidString))
        #expect(request.action.summary.contains("Engineer → Designer"))
        expectNoDifference(request.action.context.metadata["agentMessage"], "Review just the button contrast")
        expectNoDifference(model.agentMessages.count, 0)
        let before = await probe.wakes
        expectNoDifference(before, [])
        await model.resolveGroupApproval(request, groupID: groupID, approve: approve)
        await run.value
        let wakes = await probe.wakes
        expectNoDifference(wakes, approve ? [recipient, sender] : [])
        expectNoDifference(model.agentMessages.count, approve ? 2 : 0)
        #expect(model.agentMessages.allSatisfy { $0.delivery?.state == .completed })
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(groupID))
        #expect(model.thinkingGroupMembers[groupID] == nil)
        if approve {
            let messages = model.groupMessages[groupID] ?? []
            #expect(messages.contains { $0.senderID == recipient && $0.text == "Design review sent" })
            #expect(messages.contains { $0.senderID == sender && $0.text == "Updated implementation after the designer's review" })
            #expect(messages.flatMap(\.toolActivities).filter { $0.name == "SendToAgent" }.allSatisfy { $0.status == .succeeded })
        }
    }

    @Test func stopWhileApprovalPendingBlocksLateApprovalAndWake() async throws {
        let (root, model, groupID, _, _, probe) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let run = Task { await model.sendGroupMessage(groupID: groupID, text: "Delegate the review") }
        let approval = try await pending(model)
        await model.stopGroup(id: groupID)
        await model.resolveGroupApproval(approval, groupID: groupID, approve: true)
        await run.value
        let wakes = await probe.wakes
        expectNoDifference(wakes, [])
        expectNoDifference(model.agentMessages, [])
        #expect(model.pendingAutoReviewApprovals.isEmpty)
        #expect(!model.runningGroups.contains(groupID))
    }
}
