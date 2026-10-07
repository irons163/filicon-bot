import Foundation
import Testing
import CustomDump
import FiliconDomain

@Suite("Incoming native card source locators")
struct ChannelInboundCardOriginTests {
    private let runID = UUID(uuidString: "46000000-0000-0000-0000-000000000001")!
    private let messageID = UUID(uuidString: "46000000-0000-0000-0000-000000000002")!
    private let date = Date(timeIntervalSince1970: 2_000)
    private func card(kind: String, origin: ChannelInboundCardOrigin?) throws -> TranscriptCard {
        let payload: TranscriptCardPayload
        if kind == "question" {
            let question = try AgentQuestion.parse(Data(#"{"prompt":"Exact question","options":[{"label":"Continue","value":"Exact answer"}]}"#.utf8))
            payload = .widget(.init(title: question.prompt, widgetKind: "choice",
                question: .init(question: question, accountID: "fixture", memberIDs: []), channelInboundOrigin: origin))
        } else {
            let request = try AgentSecretRequest.parse(Data(#"{"label":"Exact secure request","connector":"slack","field":"token"}"#.utf8))
            payload = .secretRequest(.init(requestID: runID.uuidString, service: "slack",
                directRequest: .init(requestID: runID, request: request, binding: .init(accountID: "fixture", agentID: runID),
                    conversationID: messageID, connectionID: messageID), channelInboundOrigin: origin))
        }
        return .init(id: runID, lifecycle: .waiting, createdAt: date, updatedAt: date, payload: payload)
    }
    @Test(arguments: ["question", "secret"], [false, true])
    func fullCardsAndLegacyAbsentOriginsRoundTrip(kind: String, located: Bool) throws {
        let origin = located ? ChannelInboundCardOrigin(runID: runID, messageID: messageID) : nil
        let original = try card(kind: kind, origin: origin)
        let decoded = try JSONDecoder().decode(TranscriptCard.self, from: JSONEncoder().encode(original))
        expectNoDifference(decoded, original); expectNoDifference(decoded.directChannelInboundOrigin, origin)
        let row = ChatMessage(id: messageID, role: .assistant, text: "Exact saved card", createdAt: date, transcriptCards: [original])
        expectNoDifference(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(row)), row)
    }
    @Test(arguments: ["question", "secret"], ["missing-message", "collision", "malformed-run"])
    func malformedOriginsAreInertNotDowngradedToOrdinaryCards(kind: String, mutation: String) throws {
        let original = try card(kind: kind, origin: nil)
        var raw = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        var payload = try #require(raw["payload"] as? [String: Any])
        var origin: [String: String] = ["runID": runID.uuidString, "messageID": messageID.uuidString]
        if mutation == "missing-message" { origin["messageID"] = nil }
        else if mutation == "collision" { origin["messageID"] = runID.uuidString }
        else { origin["runID"] = "not-a-native-id" }
        payload["channelInboundOrigin"] = origin; raw["payload"] = payload
        let decoded = try JSONDecoder().decode(TranscriptCard.self, from: JSONSerialization.data(withJSONObject: raw))
        guard case .unknown(let type, let value) = decoded.payload else { Issue.record("A malformed origin revived an actionable card"); return }
        expectNoDifference(type, original.payload.type)
        let expectedRaw = try JSONDecoder().decode(TranscriptJSONValue.self, from: JSONSerialization.data(withJSONObject: payload))
        expectNoDifference(value, expectedRaw.redactingSensitiveFields)
        expectNoDifference(decoded.directChannelInboundOrigin, nil)
        var expected = original; expected.payload = .unknown(type: type, payload: expectedRaw.redactingSensitiveFields)
        expectNoDifference(decoded, expected)
    }
}
