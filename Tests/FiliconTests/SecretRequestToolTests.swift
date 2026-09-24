import Foundation
import Testing
import CustomDump
import FiliconAgents
import FiliconDomain
import FiliconProviderKit
@testable import FiliconAppServices

private actor SecretToolProbe {
    var requests: [AgentSecretRequest] = []
    func append(_ value: AgentSecretRequest) { requests.append(value) }
}

@Suite("Secret-request tool boundary", .timeLimit(.minutes(1)))
struct SecretRequestToolTests {
    private let scope = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let payload = #"{"type":"secret-request","secret":{"label":"Token","connector":"slack","field":"token"}}"#

    @Test func requestSuspendsAndRetriesDoNotRepublish() async throws {
        let probe = SecretToolProbe()
        let tool = AgentUserMessageTool(conversationID: scope, availableImages: [], imageStore: nil,
            publishSecret: { await probe.append($0) }, publish: { _, _ in Issue.record("Unexpected text") })
        let context = ToolContext(conversationID: scope, runID: runID)
        let call = try NormalizedToolCall(id: "secret", name: "SendMessage", argumentsJSON: Data(payload.utf8))
        for _ in 0..<2 {
            await #expect(throws: ToolTurnSuspension.self) { _ = try await tool.execute(call, context: context) }
        }
        let requests = await probe.requests
        expectNoDifference(requests.count, 1)
        let late = try await tool.execute(.init(id: "late", name: "SendMessage", argumentsJSON: Data(#"{"text":"Late"}"#.utf8)), context: context)
        #expect(late.isError)
        let schema = try #require(try JSONSerialization.jsonObject(with: tool.descriptor.inputSchema) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(properties["secret"] != nil)
        let plain = AgentUserMessageTool(conversationID: scope, publish: { _ in })
        let unsupported = try await plain.execute(call, context: context)
        #expect(unsupported.isError)
    }

    @Test(arguments: [
        #"{"type":"secret-request","secret":{"label":"Token","connector":"slack","field":"token","value":"FAKE-SECRET"}}"#,
        #"{"type":"secret-request","text":"Extra","secret":{"label":"Token","connector":"slack","field":"token"}}"#,
        #"{"type":"secret-request","reply_to":"abc","secret":{"label":"Token","connector":"slack","field":"token"}}"#
    ])
    func rejectsExtraFields(payload: String) async throws {
        let tool = AgentUserMessageTool(conversationID: scope, availableImages: [], imageStore: nil,
            publishSecret: { _ in Issue.record("Invalid request reached host") }, publish: { _, _ in })
        let result = try await tool.execute(.init(id: "bad", name: "SendMessage", argumentsJSON: Data(payload.utf8)),
            context: .init(conversationID: scope, runID: runID))
        #expect(result.isError)
        #expect(!String(describing: result).contains("FAKE-SECRET"))
    }

    @Test func hostErrorsAreSanitized() async throws {
        let tool = AgentUserMessageTool(conversationID: scope, availableImages: [], imageStore: nil,
            publishSecret: { _ in throw NSError(domain: "FAKE-SECRET", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "FAKE-SECRET"]) }, publish: { _, _ in })
        let result = try await tool.execute(.init(id: "bad", name: "SendMessage", argumentsJSON: Data(payload.utf8)),
            context: .init(conversationID: scope, runID: runID))
        #expect(result.isError)
        #expect(!String(describing: result).contains("FAKE-SECRET"))
    }
}
