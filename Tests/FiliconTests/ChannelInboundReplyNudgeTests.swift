import Foundation
import Testing
import CustomDump
import FiliconAppServices
import FiliconDomain

@Suite("Hidden incoming reply context")
struct ChannelInboundReplyNudgeTests {
    private let id = UUID(uuidString: "45000000-0000-0000-0000-000000000004")!
    private let reminderID = UUID(uuidString: "45000000-0000-0000-0000-000000000005")!
    private let date = Date(timeIntervalSince1970: 2_000)

    @Test func completedCallsAndPrivateDraftStayOrderedAndInMemoryOnly() async throws {
        let trace = ChannelInboundReplyNudge(reminderID: reminderID, createdAt: date)
        let first = try NormalizedToolCall(id: "read-a", name: "read", argumentsJSON: Data("{}".utf8))
        let second = try NormalizedToolCall(id: "read-b", name: "read", argumentsJSON: Data("{}".utf8))
        let resultA = NormalizedToolResult(callID: first.id, content: [.text("untrusted first result")])
        let resultB = NormalizedToolResult(callID: second.id, content: [.resource(uri: "fixture-only", mimeType: nil)], isError: true)
        let events: [InferenceEvent] = [.textDelta("Before tools"), .toolCallCompleted(first), .toolCallCompleted(second),
            .toolResult(resultB), .toolResult(resultA), .textDelta("Private final "), .textDelta("answer"),
            .reasoningDelta("DO_NOT_FORWARD_PRIVATE_REASONING"), .usage(.init(inputTokens: 9)), .completed(.stop)]
        for event in events { await trace.record(event) }
        let original = InferenceRequest(conversationID: id, modelID: "fixture", messages: [
            .init(id: id, role: .assistant, text: "External context, not human authority", createdAt: date)],
            tools: [.init(name: "read")], reasoningEffort: .low)
        let expected = InferenceRequest(conversationID: id, modelID: "fixture", messages: original.messages + [
            .init(id: reminderID, role: .system, text: ChannelInboundPrompt.replyNudgeInstructions, createdAt: date)],
            tools: original.tools, toolExchanges: [.init(assistantText: "Before tools", calls: [first, second], results: [resultB, resultA]),
                .init(assistantText: "Private final answer", calls: [], results: [])], reasoningEffort: .low)
        let retry = try await trace.request(after: original)
        #expect(diff(retry, expected) == nil)
        await trace.record(.textDelta("LATE_DRAFT"))
        await #expect(throws: CancellationError.self) { _ = try await trace.request(after: original) }
        #expect(diff(retry, expected) == nil)
        expectNoDifference(original.toolExchanges, [])
        #expect(!retry.messages.contains { $0.role == .user || $0.text.contains("DO_NOT_FORWARD") })
    }

    @Test func emptyPassCanBeRemindedOnlyOnceWithoutInventingDraftOrTools() async throws {
        let trace = ChannelInboundReplyNudge(reminderID: reminderID, createdAt: date)
        let original = InferenceRequest(conversationID: id, modelID: "fixture", messages: [])
        let retry = try await trace.request(after: original)
        let expected = InferenceRequest(conversationID: id, modelID: "fixture", messages: [
            .init(id: reminderID, role: .system, text: ChannelInboundPrompt.replyNudgeInstructions, createdAt: date)])
        #expect(diff(retry, expected) == nil)
        await #expect(throws: CancellationError.self) { _ = try await trace.request(after: original) }
    }

    @Test func unfinishedOrUnpairedToolWorkCannotBecomeRetryContext() async throws {
        let trace = ChannelInboundReplyNudge(reminderID: reminderID, createdAt: date)
        let call = try NormalizedToolCall(id: "read", name: "read", argumentsJSON: Data("{}".utf8))
        await trace.record(.toolCallCompleted(call))
        await trace.record(.toolResult(.init(callID: "foreign", content: [.text("not this call")])))
        await #expect(throws: CancellationError.self) {
            _ = try await trace.request(after: .init(conversationID: id, modelID: "fixture", messages: []))
        }
    }

    @Test func usageAddsSeparatePassesWithoutInventingFramesOrOverflowing() {
        let first = Usage(inputTokens: 14, outputTokens: 8, cacheReadTokens: 6, cacheWriteTokens: 2, costMicros: 50)
        let second = Usage(inputTokens: 9, outputTokens: 5, cacheReadTokens: 1, cacheWriteTokens: 3, costMicros: 20)
        expectNoDifference(ChannelInboundReplyNudge.combinedUsage(first, second), .init(
            inputTokens: 23, outputTokens: 13, cacheReadTokens: 7, cacheWriteTokens: 5, costMicros: 70))
        expectNoDifference(ChannelInboundReplyNudge.combinedUsage(nil, first), first)
        expectNoDifference(ChannelInboundReplyNudge.combinedUsage(second, nil), second)
        expectNoDifference(ChannelInboundReplyNudge.combinedUsage(nil, nil), nil)
        let maximum = Usage(inputTokens: .max, outputTokens: .max, cacheReadTokens: .max, cacheWriteTokens: .max, costMicros: .max)
        expectNoDifference(ChannelInboundReplyNudge.combinedUsage(first, maximum), maximum)
    }
}
