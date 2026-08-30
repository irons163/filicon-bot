import Foundation
import Testing
import FiliconAgents
import FiliconDomain
@testable import Filicon

@Suite("Agent messaging app integration")
struct AgentMessagingAppIntegrationTests {
    @Test @MainActor func sendReadAndRestartProjectDurableMailboxes() async throws {
        let root = Self.temporaryRoot("durability")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await first.createAgent(name: "Planner", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream")
        await first.createAgent(name: "Builder", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream")
        let planner = try #require(first.agents.first(where: { $0.name == "Planner" }))
        let builder = try #require(first.agents.first(where: { $0.name == "Builder" }))

        let sent = await first.sendAgentMessage(
            senderID: planner.id,
            recipientID: builder.id,
            text: "  Please implement the parser.  ",
            priority: AgentMessagePriority.priority
        )

        #expect(sent)
        #expect(first.agentInbox(for: builder.id).map { $0.text } == ["Please implement the parser."])
        #expect(first.agentOutbox(for: planner.id).count == 1)
        #expect(first.agentThread(between: planner.id, and: builder.id).count == 1)
        #expect(first.agentMessageUnreadCounts[builder.id] == 1)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "agent-messages.json").path))

        await first.markAgentMessagesRead(recipientID: builder.id)
        #expect(first.agentMessageUnreadCounts[builder.id] == nil)
        #expect(first.agentInbox(for: builder.id).first?.deliveredAt != nil)

        let restarted = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await restarted.reloadWorkspaceData()
        #expect(restarted.agentThread(between: planner.id, and: builder.id).map { $0.text } == ["Please implement the parser."])
        #expect(restarted.agentInbox(for: builder.id).first?.deliveredAt != nil)
        #expect(restarted.agentMessageUnreadCounts[builder.id] == nil)
    }

    @Test @MainActor func invalidOrArchivedParticipantsNeverAppendToAnotherMailbox() async throws {
        let root = Self.temporaryRoot("validation")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        await model.createAgent(name: "Sender", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream")
        await model.createAgent(name: "Recipient", summary: "", instructions: "", providerID: "fake", modelID: "fake-stream")
        let sender = try #require(model.agents.first(where: { $0.name == "Sender" }))
        let recipient = try #require(model.agents.first(where: { $0.name == "Recipient" }))

        #expect(!(await model.sendAgentMessage(senderID: sender.id, recipientID: sender.id, text: "self")))
        #expect(!(await model.sendAgentMessage(senderID: sender.id, recipientID: UUID(), text: "unknown")))
        #expect(!(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: String(repeating: "x", count: 8_001))))
        await model.archiveAgent(id: recipient.id)
        #expect(!(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "archived recipient")))
        await model.restoreAgent(id: recipient.id)
        await model.archiveAgent(id: sender.id)
        #expect(!(await model.sendAgentMessage(senderID: sender.id, recipientID: recipient.id, text: "archived sender")))

        #expect(model.agentMessages.isEmpty)
        #expect(model.agentInbox(for: recipient.id).isEmpty)
        #expect(model.agentOutbox(for: sender.id).isEmpty)
    }

    private static func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "filicon-agent-messaging-\(suffix)-\(UUID().uuidString)", directoryHint: .isDirectory)
    }
}
