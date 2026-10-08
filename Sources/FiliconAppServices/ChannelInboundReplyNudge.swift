import Foundation
import FiliconDomain

/// In-memory inference context only. Neither private drafts nor the host
/// reminder become saved messages, reference targets or publication grants.
public actor ChannelInboundReplyNudge {
    private let reminderID: UUID
    private let createdAt: Date
    private var text = ""
    private var calls: [NormalizedToolCall] = []
    private var results: [NormalizedToolResult] = []
    private var exchanges: [ToolExchange] = []
    private var used = false

    public init(reminderID: UUID = UUID(), createdAt: Date) {
        self.reminderID = reminderID; self.createdAt = createdAt
    }

    public func record(_ event: InferenceEvent) {
        guard !used else { return }
        switch event {
        case .textDelta(let delta): text += delta
        case .toolCallCompleted(let call): calls.append(call)
        case .toolResult(let result):
            results.append(result)
            if !calls.isEmpty, results.count == calls.count, Set(results.map(\.callID)) == Set(calls.map(\.id)) {
                exchanges.append(.init(assistantText: text, calls: calls, results: results))
                text = ""; calls = []; results = []
            }
        default: break
        }
    }

    /// The caller must first prove successful completion, no publication, and
    /// the still-live original native scope. This object conveys no authority.
    public func request(after original: InferenceRequest) throws -> InferenceRequest {
        guard !used, calls.isEmpty, results.isEmpty else { throw CancellationError() }
        used = true
        let tail: [ToolExchange] = text.isEmpty ? [] : [.init(assistantText: text, calls: [], results: [])]
        return .init(conversationID: original.conversationID, modelID: original.modelID,
            messages: original.messages + [.init(id: reminderID, role: .system,
                text: ChannelInboundPrompt.replyNudgeInstructions, createdAt: createdAt)],
            tools: original.tools, toolExchanges: original.toolExchanges + exchanges + tail,
            attachmentsByMessageID: original.attachmentsByMessageID, reasoningEffort: original.reasoningEffort)
    }

    /// Each provider pass has its own cumulative usage frames. Max-merge is
    /// correct inside a pass, not across two separately billed passes.
    public nonisolated static func combinedUsage(_ first: Usage?, _ second: Usage?) -> Usage? {
        guard let first else { return second }
        guard let second else { return first }
        func sum<Value: FixedWidthInteger>(_ lhs: Value, _ rhs: Value) -> Value {
            let result = lhs.addingReportingOverflow(rhs)
            return result.overflow ? .max : result.partialValue
        }
        return .init(inputTokens: sum(first.inputTokens, second.inputTokens),
            outputTokens: sum(first.outputTokens, second.outputTokens),
            cacheReadTokens: sum(first.cacheReadTokens, second.cacheReadTokens),
            cacheWriteTokens: sum(first.cacheWriteTokens, second.cacheWriteTokens),
            costMicros: sum(first.costMicros, second.costMicros))
    }
}
