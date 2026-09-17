import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain

private actor PublishedMessages {
    var texts: [String] = []
    func append(_ text: String) { texts.append(text) }
}

@Suite("SendMessage publication boundaries")
struct AgentUserMessageToolTests {
    private func call(_ id: ToolCallID, _ text: String) throws -> NormalizedToolCall {
        try .init(id: id, name: "SendMessage", argumentsJSON: JSONEncoder().encode(["text": text]))
    }

    @Test func boundedPublicationIdempotencyScopeAndClose() async throws {
        let origin = UUID(), output = PublishedMessages()
        let tool = AgentUserMessageTool(conversationID: origin) { await output.append($0) }
        let context = ToolContext(conversationID: origin)
        let first = try await tool.execute(call("one", "Progress"), context: context)
        let replay = try await tool.execute(call("one", "Progress"), context: context)
        expectNoDifference(first, replay)
        #expect(try await tool.execute(call("one", "Altered payload"), context: context).isError)
        #expect(try await tool.execute(call("duplicate", "Progress"), context: context).isError)
        await #expect(throws: AgentMessagingError.scopeMismatch) {
            _ = try await tool.execute(call("foreign", "Not allowed"), context: .init(conversationID: UUID()))
        }
        #expect(!(try await tool.execute(call("two", "Result"), context: context).isError))
        #expect(try await tool.execute(call("three", "Over limit"), context: context).isError)
        await tool.close()
        await #expect(throws: AgentMessagingError.closed) {
            _ = try await tool.execute(call("late", "Late"), context: context)
        }
        let texts = await output.texts
        expectNoDifference(texts, ["Progress", "Result"])
    }

    @Test func failedPublicationCannotReturnSuccess() async throws {
        struct StoreFailure: Error {}
        let origin = UUID()
        let tool = AgentUserMessageTool(conversationID: origin) { _ in throw StoreFailure() }
        let result = try await tool.execute(call("save", "Report"), context: .init(conversationID: origin))
        #expect(result.isError)
        let published = await tool.publishedTexts
        expectNoDifference(published, [])
    }
}
