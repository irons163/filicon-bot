import Foundation
import FiliconDomain

public protocol AIProvider: Sendable {
    var descriptor: ProviderDescriptor { get }
    func models() async throws -> [AIModel]
    func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error>
}

/// A provider with an interactive protocol that waits for host-owned tool results.
/// The executor is supplied by ToolLoop, never by the model or CLI.
public protocol InteractiveToolProvider: AIProvider {
    func stream(_ request: InferenceRequest,
                executeTool: @escaping @Sendable (NormalizedToolCall) async throws -> NormalizedToolResult)
        -> AsyncThrowingStream<InferenceEvent, Error>
}

public enum ProviderError: LocalizedError, Sendable, Equatable {
    case missingCredential(ProviderID)
    case authentication(String)
    case rateLimit(String)
    case refusal(String)
    case transport(String)
    case truncated(String)
    case invalidResponse
    case http(status: Int, message: String)
    case malformedEvent(String)
    case unsupportedAttachment(String)
    case unsupportedReasoningEffort(model: ModelID, effort: ReasoningEffort)
    case modelUnavailable(ModelID)
    case catalog(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let id): "Missing API key for \(id.rawValue)."
        case .authentication(let message): "Provider authentication failed: \(message)"
        case .rateLimit(let message): "Provider rate limit: \(message)"
        case .refusal(let message): "Provider refused the request: \(message)"
        case .transport(let message): "Provider transport error: \(message)"
        case .truncated(let message): "Provider stream ended before completion: \(message)"
        case .invalidResponse: "The provider returned an invalid response."
        case .http(let status, let message): "Provider HTTP \(status): \(message)"
        case .malformedEvent(let message): "Malformed provider event: \(message)"
        case .unsupportedAttachment(let name): "This provider cannot send attachment \(name)."
        case .unsupportedReasoningEffort(let model, let effort): "Model \(model.rawValue) does not support reasoning effort \(effort.rawValue)."
        case .modelUnavailable(let model): "Model \(model.rawValue) is not present in the current provider catalog."
        case .catalog(let message): "Provider model catalog failed: \(message)"
        }
    }

    static func httpStatus(_ status: Int, message: String? = nil) -> ProviderError {
        let detail = message ?? HTTPURLResponse.localizedString(forStatusCode: status)
        switch status {
        case 401, 403: return .authentication(detail)
        case 429: return .rateLimit(detail)
        default: return .http(status: status, message: detail)
        }
    }
}

public enum ProviderCatalogSource: String, Hashable, Sendable { case dynamic, builtIn, builtInFallback }
public struct ProviderModelCatalogSnapshot: Hashable, Sendable {
    public var models: [AIModel]
    public var source: ProviderCatalogSource
    public var fetchedAt: Date
    public var isStale: Bool
    public var errorDescription: String?
    public init(models: [AIModel], source: ProviderCatalogSource, fetchedAt: Date = .now,
                isStale: Bool = false, errorDescription: String? = nil) {
        self.models = models; self.source = source; self.fetchedAt = fetchedAt
        self.isStale = isStale; self.errorDescription = errorDescription
    }
}

public protocol DynamicModelCatalogProviding: Sendable {
    func modelCatalog(forceRefresh: Bool) async -> ProviderModelCatalogSnapshot
}

public actor ProviderRegistry {
    private var providers: [ProviderID: any AIProvider] = [:]
    public init() {}
    public func register(_ provider: any AIProvider) { providers[provider.descriptor.id] = provider }
    public func provider(id: ProviderID) -> (any AIProvider)? { providers[id] }
    public func descriptors() -> [ProviderDescriptor] { providers.values.map(\.descriptor).sorted { $0.displayName < $1.displayName } }
    /// App integration entry point. Dynamic providers expose refresh/staleness details;
    /// simple or third-party providers remain valid as an explicit built-in catalog.
    public func modelCatalog(providerID: ProviderID, forceRefresh: Bool = false) async -> ProviderModelCatalogSnapshot? {
        guard let provider = providers[providerID] else { return nil }
        if let dynamic = provider as? any DynamicModelCatalogProviding { return await dynamic.modelCatalog(forceRefresh: forceRefresh) }
        do { return .init(models: try await provider.models(), source: .builtIn) }
        catch { return .init(models: [], source: .builtInFallback, isStale: true, errorDescription: String(describing: error)) }
    }
}

public struct FakeProvider: AIProvider {
    public let descriptor = ProviderDescriptor(id: "fake", displayName: "Demo (offline)", requiresAPIKey: false)
    private let delay: Duration
    private let chunks: [String]
    private let observer: (@Sendable (UUID) async -> Void)?
    public init(chunks: [String] = ["Hello", " from", " Filicon."], delay: Duration = .milliseconds(80), observer: (@Sendable (UUID) async -> Void)? = nil) {
        self.chunks = chunks; self.delay = delay; self.observer = observer
    }
    public func models() async throws -> [AIModel] { [AIModel(id: "fake-stream")] }
    public func stream(_ request: InferenceRequest) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await observer?(request.conversationID)
                continuation.yield(.responseStarted(id: UUID().uuidString))
                do {
                    for chunk in chunks { try Task.checkCancellation(); try await Task.sleep(for: delay); continuation.yield(.textDelta(chunk)) }
                    continuation.yield(.usage(Usage(inputTokens: request.messages.count, outputTokens: chunks.count)))
                    continuation.yield(.completed(.stop)); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
