import CustomDump
import FiliconDomain
import FiliconAppServices
import Foundation
import Testing

@Suite("Direct secret request transcript metadata")
struct DirectSecretRequestTests {
    let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    let responseID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!

    private func request() throws -> DirectSecretRequest {
        .init(requestID: id,
            request: try AgentSecretRequest.parse(Data(#"{"label":"Token","connector":"slack","field":"token"}"#.utf8)),
            binding: .init(accountID: "local", agentID: id), conversationID: id, connectionID: id)
    }

    @Test func terminalTransitionsAndMalformedReceipts() throws {
        var value = try request()
        expectNoDifference(value.acknowledgement, nil)
        try expectDifference(value.state) {
            try value.resolve(provided: false, responseMessageID: responseID)
        } changes: {
            $0 = .dismissed
        }
        expectNoDifference(value.responseMessageID, responseID)
        #expect(throws: AgentSecretRequestError.stale) {
            try value.resolve(provided: true, responseMessageID: id)
        }
        var pending = try request()
        pending.retire()
        expectNoDifference(pending.state, .retired)
        expectNoDifference(pending.acknowledgement, nil)
        var invalid = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(try request())) as? [String: Any])
        invalid["state"] = "stored"
        #expect(throws: AgentSecretRequestError.invalid) {
            try JSONDecoder().decode(DirectSecretRequest.self, from: JSONSerialization.data(withJSONObject: invalid))
        }
    }

    @Test func legacyAndSQLiteRoundTrip() async throws {
        let legacy = try JSONDecoder().decode(SecretRequestTranscriptCard.self,
            from: Data(#"{"requestID":"old","service":"legacy","prompt":"Credential required"}"#.utf8))
        expectNoDifference(legacy.directRequest, nil)
        let root = FileManager.default.temporaryDirectory.appending(path: "direct-secret-metadata-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "conversations.json")
        let direct = try request()
        let card = TranscriptCard(id: id, lifecycle: .waiting,
            payload: .secretRequest(.init(requestID: id.uuidString, service: "slack", directRequest: direct)))
        var message = ChatMessage(id: responseID, role: .assistant, text: "Credential request", createdAt: Date(timeIntervalSince1970: 1000))
        message.transcriptCards = [card]
        let conversation = Conversation(id: id, messages: [message], updatedAt: Date(timeIntervalSince1970: 1000))
        let store = ConversationStore(fileURL: file)
        try await store.upsert(conversation, replacingLoadedMessageIDs: [], historyComplete: true)
        let reopened = ConversationStore(fileURL: file)
        let saved = try #require(try await reopened.conversation(id: id))
        expectNoDifference(saved.messages.first?.transcriptCards, [card])
        expectNoDifference(try JSONDecoder().decode(DirectSecretRequest.self, from: JSONEncoder().encode(direct)), direct)
    }
}
