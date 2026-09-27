import Foundation
import Testing
import CustomDump
import FiliconAgents

private struct RemoteGroupResponder: GroupAgentResponder {
    let run: @Sendable (@escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("Expected durable publication callback"); return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        try await run(onSavedPublication)
    }
}

@Suite("Reviewed group remote attachment persistence")
struct GroupRemotePublicationTests {
    @Test(arguments: ["approved", "revoked", "wrong-group", "wrong-sender", "mixed-text", "mixed-lifetime", "duplicate"])
    func persistsOnlyReviewedScopedReference(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-remote-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", providerID: "fixture", modelID: "test")
        let url = root.appending(path: "groups.json")
        let groups = try GroupService(agents: agents, storeURL: url)
        let group = try await groups.create(name: "Remote", memberIDs: [sender.id])
        let user = try await groups.postUserMessage("Share report", groupID: group.id)
        let reference = try RemoteAttachmentReference(url: "https://example.com/report.pdf?sig=a%2Bb", alt: "Report")
        let lifetime = AgentPublicationLifetime()
        if mode == "revoked" { lifetime.close() }
        let reviewed = ReviewedGroupRemoteAttachment(reference: reference,
            groupID: mode == "wrong-group" ? UUID() : group.id,
            senderID: mode == "wrong-sender" ? UUID() : sender.id, lifetime: lifetime)
        let accepted = mode == "approved" || mode == "duplicate"
        let responder = RemoteGroupResponder { publish in
            do {
                let saved = try await publish(.init(text: mode == "mixed-text" ? "Caption" : "",
                    lifetime: mode == "mixed-lifetime" ? AgentPublicationLifetime() : nil,
                    replyToMessageID: user.id, remoteAttachment: reviewed))
                #expect(accepted)
                expectNoDifference(saved?.remoteAttachment, reference)
                expectNoDifference(saved?.shortAddress, "t0s0")
                if mode == "duplicate" {
                    let duplicate = ReviewedGroupRemoteAttachment(reference: reference, groupID: group.id,
                        senderID: sender.id, lifetime: lifetime)
                    await #expect(throws: (any Error).self) {
                        try await publish(.init(text: "", remoteAttachment: duplicate))
                    }
                }
            } catch { #expect(!accepted) }
            return ["PASS"]
        }
        _ = try await groups.run(groupID: group.id, responder: responder)
        let reopened = try GroupService(agents: agents, storeURL: url)
        let history = await reopened.messages(groupID: group.id)
        let remote = history.filter { $0.remoteAttachment != nil }
        expectNoDifference(remote.count, accepted ? 1 : 0)
        if let saved = remote.first {
            expectNoDifference(saved.id, reviewed.messageID)
            expectNoDifference(saved.remoteAttachment, reference)
            expectNoDifference(saved.files, nil)
            expectNoDifference(saved.images, nil)
            expectNoDifference(saved.replyToMessageID, user.id)
            #expect(GroupThreadProjection(history: history, groupID: group.id).canReply(to: saved.id))
            let later = try await reopened.postUserMessage("Next", groupID: group.id)
            let updated = await reopened.messages(groupID: group.id)
            let directory = GroupMessageReferenceDirectory(history: updated, groupID: group.id)
            let link = try #require(URL(string: "sand-msg:t0s0"))
            expectNoDifference(directory.target(for: link, from: later.id), saved.id)
        }
    }

    @Test func legacyMessagesHaveNoRemoteLocator() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","groupID":"22222222-2222-4222-8222-222222222222","text":"Old","createdAt":0}"#
        let value = try JSONDecoder().decode(RoomMessage.self, from: Data(json.utf8))
        expectNoDifference(value.remoteAttachment, nil)
        expectNoDifference(try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(value)), value)
    }
}
