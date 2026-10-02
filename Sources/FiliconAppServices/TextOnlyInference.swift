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
        var completed = false
        do {
            for try await event in stream {
                try check()
                switch event {
                case .textDelta(let delta):
                    guard !completed, delta.utf8.count <= maximumOutputBytes - bytes else {
                        throw ProviderError.invalidResponse
                    }
                    bytes += delta.utf8.count
                    text += delta
                case .usage(let value):
                    // OpenAI-compatible streams may send usage after finish_reason.
                    usage = value
                case .responseStarted, .reasoningDelta:
                    guard !completed else { throw ProviderError.invalidResponse }
                case .toolCallStarted, .toolCallArgumentsDelta, .toolCallCompleted, .toolResult:
                    throw ProviderError.invalidResponse
                case .completed(let reason):
                    if reason == .cancelled { throw CancellationError() }
                    guard !completed else { throw ProviderError.invalidResponse }
                    switch reason {
                    case .stop: completed = true
                    case .length: throw ProviderError.truncated(reason.rawValue)
                    case .toolUse, .unknown: throw ProviderError.invalidResponse
                    case .cancelled: throw CancellationError()
                    }
                }
            }
            try check()
            guard completed else { throw ProviderError.invalidResponse }
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
