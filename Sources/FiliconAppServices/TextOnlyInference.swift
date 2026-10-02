import Foundation
import FiliconDomain
import FiliconProviderKit

public struct TextOnlyInferenceResult: Hashable, Sendable {
    public let text: String
    public let usage: Usage?
}

/// Collects an explicitly text-only provider response. This is not a tool runner:
/// tool requests/results must fail, not be ignored or reported as executed.
public enum TextOnlyInference {
    public static func collect(
        _ stream: AsyncThrowingStream<InferenceEvent, Error>,
        maximumOutputBytes: Int,
        validate: @escaping @Sendable () throws -> Void = {}
    ) async throws -> TextOnlyInferenceResult {
        func check() throws {
            try Task.checkCancellation()
            try validate()
        }
        try check()
        guard maximumOutputBytes >= 0 else { throw ProviderError.invalidResponse }
        var text = "", bytes = 0
        var usage: Usage?
        var completion = InferenceResponseCompletion()
        do {
            for try await event in stream {
                try check()
                try completion.consume(event)
                switch event {
                case .textDelta(let delta):
                    guard delta.utf8.count <= maximumOutputBytes - bytes else {
                        throw ProviderError.invalidResponse
                    }
                    bytes += delta.utf8.count
                    text += delta
                case .usage(let value):
                    // OpenAI-compatible streams may send usage after finish_reason.
                    usage = value
                case .responseStarted, .reasoningDelta, .toolCallStarted, .toolCallArgumentsDelta,
                     .toolCallCompleted, .toolResult, .completed: break
                }
            }
            try check()
            try completion.finish()
            // Empty text with an explicit stop is a valid silent response.
            return .init(text: text, usage: usage)
        } catch {
            // Revocation/cancellation wins over a late transport error, including
            // a stream that finishes without yielding another event.
            try check()
            throw error
        }
    }
}
