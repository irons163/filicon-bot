import Foundation
import FiliconDomain
import FiliconProviderKit

/// A per-turn, host-bound publishing capability. The model cannot choose a
/// recipient, impersonate a member, or publish after the turn has ended.
public actor AgentUserMessageTool: ToolExecutor {
    public nonisolated let descriptor = ToolDescriptor(
        name: "SendMessage",
        description: "Publish a useful message to the user in the current conversation. This does not message a peer or perform other actions. At most two messages per turn; do not repeat them in final text.",
        inputSchema: Data(#"{"type":"object","properties":{"text":{"type":"string","minLength":1,"maxLength":8000}},"required":["text"],"additionalProperties":false}"#.utf8),
        parallelSafe: false
    )
    private let conversationID: UUID
    private let publish: @Sendable (String) async throws -> Void
    private struct Key: Hashable { let runID: UUID; let callID: ToolCallID }
    private var calls: [Key: (String, NormalizedToolResult)] = [:]
    private var texts: [String] = []
    private var reserved = false
    private var closed = false

    public init(conversationID: UUID, publish: @escaping @Sendable (String) async throws -> Void) {
        self.conversationID = conversationID
        self.publish = publish
    }

    public var publishedTexts: [String] { texts }
    public func close() { closed = true }

    public func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult {
        try Task.checkCancellation()
        guard !closed else { throw AgentMessagingError.closed }
        guard context.conversationID == conversationID else { throw AgentMessagingError.scopeMismatch }
        struct Arguments: Decodable { let text: String }
        do {
            guard call.name == "SendMessage", call.argumentsJSON.count <= 40_000,
                  let object = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: String],
                  Set(object.keys) == ["text"] else {
                return .init(callID: call.id, content: [.text("SendMessage currently accepts text only. Images and other fields are not published.")], isError: true)
            }
            let args = try JSONDecoder().decode(Arguments.self, from: call.argumentsJSON)
            let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = Key(runID: context.runID, callID: call.id)
            if let existing = calls[key] {
                guard existing.0 == text else { throw AgentMessagingError.duplicateMessage }
                return existing.1
            }
            guard !text.isEmpty, text.count <= 8_000, !reserved, texts.count < 2, !texts.contains(text) else {
                return .init(callID: call.id, content: [.text("SendMessage accepts up to two distinct, nonempty messages of at most 8,000 characters per turn.")], isError: true)
            }
            reserved = true
            defer { reserved = false }
            try await publish(text)
            // The callback's successful durable publication is the side effect.
            // Remember it even if cancellation arrived while it was saving.
            let result = NormalizedToolResult(callID: call.id, content: [.text("Published to the user in this conversation. Do not repeat this message in your final response.")])
            texts.append(text)
            calls[key] = (text, result)
            try Task.checkCancellation()
            return result
        } catch {
            if error is CancellationError { throw error }
            return .init(callID: call.id, content: [.text(error.localizedDescription)], isError: true)
        }
    }
}
