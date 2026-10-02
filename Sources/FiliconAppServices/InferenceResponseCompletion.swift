import Foundation
import FiliconDomain
import FiliconProviderKit

/// One provider response, not a whole multi-step tool turn. Normal EOF is not a
/// completion signal. Host effects may start only after a valid tool-use response
/// has also reached EOF; interactive effects instead belong to owned callbacks.
struct InferenceResponseCompletion {
    let allowsToolCalls: Bool
    private var reason: FinishReason?

    init(allowsToolCalls: Bool = false) { self.allowsToolCalls = allowsToolCalls }

    mutating func consume(_ event: InferenceEvent) throws {
        // Cancellation wins even if a provider incorrectly reports it after stop.
        if case .completed(.cancelled) = event { throw CancellationError() }
        // Some compatible providers send usage after their terminal event.
        if case .usage = event { return }
        guard reason == nil else { throw ProviderError.invalidResponse }
        switch event {
        case .completed(let value):
            switch value {
            case .stop: reason = value
            case .toolUse:
                guard allowsToolCalls else { throw ProviderError.invalidResponse }
                reason = value
            case .length: throw ProviderError.truncated(value.rawValue)
            case .unknown: throw ProviderError.invalidResponse
            case .cancelled: throw CancellationError()
            }
        case .toolCallStarted, .toolCallArgumentsDelta, .toolCallCompleted:
            guard allowsToolCalls else { throw ProviderError.invalidResponse }
        case .toolResult:
            // Provider assertions are never evidence of host execution.
            throw ProviderError.invalidResponse
        case .responseStarted, .textDelta, .reasoningDelta, .usage: break
        }
    }

    func finish(hasToolCalls: Bool = false) throws {
        guard reason == (hasToolCalls ? .toolUse : .stop) else { throw ProviderError.invalidResponse }
    }
}
