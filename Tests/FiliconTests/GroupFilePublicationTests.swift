import Foundation
import Testing
import CustomDump
import FiliconDomain
import FiliconAgents

private struct FileGroupResponder: GroupAgentResponder {
    let run: @Sendable (@escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String]
    func respond(agent: AgentProfile, history: [RoomMessage]) async throws -> [String] {
        Issue.record("Expected saved publication callback")
        return []
    }
    func respond(agent: AgentProfile, history: [RoomMessage], context: GroupTurnContext,
                 onTools: @escaping @Sendable ([RoomToolActivity]) async throws -> Void,
                 onSavedPublication: @escaping @Sendable (GroupAgentPublication) async throws -> RoomMessage?) async throws -> [String] {
        try await run(onSavedPublication)
    }
}

@Suite("Reviewed group file persistence")
struct GroupFilePublicationTests {
    private let file = AttachmentMetadata(id: String(repeating: "a", count: 64), filename: "report.txt",
        mimeType: "text/plain", byteCount: 5, kind: .document, createdAt: Date(timeIntervalSince1970: 123))

    @Test func oldMessagesDecodeWithoutFiles() throws {
        let json = #"{"id":"11111111-1111-4111-8111-111111111111","groupID":"22222222-2222-4222-8222-222222222222","text":"Old","createdAt":0}"#
        let message = try JSONDecoder().decode(RoomMessage.self, from: Data(json.utf8))
        expectNoDifference(message.files, nil)
        expectNoDifference(message.images, nil)
        let restored = try JSONDecoder().decode(RoomMessage.self, from: JSONEncoder().encode(message))
        expectNoDifference(restored, message)
    }

    @Test(arguments: ["approved", "revoked", "wrong-group", "wrong-sender", "mixed-images", "mixed-lifetime", "duplicate"])
    func publicationIsScopedAndDurable(mode: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-group-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let agents = try AgentService(storeURL: root.appending(path: "agents.json"))
        let sender = try await agents.create(name: "Sender", providerID: "fixture", modelID: "test")
        let url = root.appending(path: "groups.json")
        let groups = try GroupService(agents: agents, storeURL: url)
        let group = try await groups.create(name: "Files", memberIDs: [sender.id])
        let user = try await groups.postUserMessage("Send report", groupID: group.id)
        let lifetime = AgentPublicationLifetime()
        if mode == "revoked" { lifetime.close() }
        let reviewed = try ReviewedGroupFile(metadata: file,
            groupID: mode == "wrong-group" ? UUID() : group.id,
            senderID: mode == "wrong-sender" ? UUID() : sender.id, lifetime: lifetime)
        let accepted = mode == "approved" || mode == "duplicate"
        let responder = FileGroupResponder { publish in
            do {
                let saved = try await publish(.init(text: "", images: mode == "mixed-images" ? [file] : [],
                    lifetime: mode == "mixed-lifetime" ? AgentPublicationLifetime() : nil,
                    replyToMessageID: user.id, file: reviewed))
                #expect(accepted)
                expectNoDifference(saved?.files, [file])
                expectNoDifference(saved?.shortAddress, "t0s0")
                if mode == "duplicate" {
                    do {
                        _ = try await publish(.init(text: "Different caption", file: reviewed))
                        Issue.record("Duplicate content should not be published twice")
                    } catch {}
                }
            } catch {
                #expect(!accepted)
            }
            return ["PASS"]
        }
        _ = try await groups.run(groupID: group.id, responder: responder)
        let history = await groups.messages(groupID: group.id)
        let saved = history.filter { $0.files?.isEmpty == false }
        expectNoDifference(saved.count, accepted ? 1 : 0)
        let reopened = try GroupService(agents: agents, storeURL: url)
        let restored = await reopened.messages(groupID: group.id)
        // Match the existing store's millisecond date representation, not the
        // in-memory Date's sub-millisecond floating-point precision.
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let expected = try decoder.decode([RoomMessage].self, from: encoder.encode(history))
        expectNoDifference(restored, expected)
        if let message = saved.first {
            expectNoDifference(message.images, nil)
            expectNoDifference(message.replyToMessageID, user.id)
            let projection = GroupThreadProjection(history: restored, groupID: group.id)
            #expect(projection.canReply(to: message.id))
            expectNoDifference(projection.replies(to: user.id).map(\.message.id), [message.id])
        }
    }

    @Test(arguments: ["digest", "path", "negative", "oversize", "mime", "alt"])
    func rejectsMalformedMetadata(mode: String) {
        let invalid = AttachmentMetadata(id: mode == "digest" ? "../escape" : file.id,
            filename: mode == "path" ? "../report.txt" : file.filename,
            mimeType: mode == "mime" ? "text/plain\n" : file.mimeType,
            byteCount: mode == "negative" ? -1 : mode == "oversize" ? AttachmentLimits.regularBytes + 1 : 5,
            kind: .document, createdAt: file.createdAt, altText: mode == "alt" ? "\n" : nil)
        #expect(throws: AgentPublicationError.self) {
            try ReviewedGroupFile(metadata: invalid, groupID: UUID(), senderID: UUID(), lifetime: AgentPublicationLifetime())
        }
    }
}
