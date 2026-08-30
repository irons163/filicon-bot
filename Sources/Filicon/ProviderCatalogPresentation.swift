import Foundation
import FiliconDomain
import FiliconProviderKit

enum ProviderCatalogPresentation {
    static func statusLabel(
        source: ProviderCatalogSource?,
        isStale: Bool,
        error: String?
    ) -> String {
        if let error, !error.isEmpty {
            if source == .builtInFallback { return "Built-in fallback — \(error)" }
            return isStale ? "Stale catalog — \(error)" : "Catalog error — \(error)"
        }
        if isStale { return "Stale catalog" }
        switch source {
        case .dynamic: return "Live provider catalog"
        case .builtIn: return "Built-in catalog"
        case .builtInFallback: return "Built-in fallback"
        case nil: return "Catalog not loaded"
        }
    }

    static func modelLabel(_ model: AIModel) -> String {
        var details: [String] = []
        if let context = model.contextWindow { details.append("\(formatTokens(context)) context") }
        if let output = model.maximumOutputTokens { details.append("\(formatTokens(output)) max output") }
        let inputs = model.capabilities.inputModalities.subtracting([.text, .tools]).map(\.rawValue).sorted()
        if !inputs.isEmpty { details.append(inputs.joined(separator: ", ")) }
        if model.capabilities.inputModalities.contains(.tools) { details.append("tools") }
        if model.isDeprecated { details.append("deprecated") }
        return details.isEmpty ? model.displayName : "\(model.displayName) · \(details.joined(separator: " · "))"
    }

    static func reasoningEfforts(for model: AIModel?) -> [ReasoningEffort] {
        let supported = model?.capabilities.reasoningEfforts ?? [.disabled]
        return ReasoningEffort.allCases.filter(supported.contains)
    }

    static func validationError(
        conversation: Conversation,
        models: [AIModel],
        catalogProviderID: ProviderID?,
        catalogConversationID: UUID?,
        loading: Bool
    ) -> String? {
        guard !loading else { return "Wait for the model catalog to finish loading before sending." }
        guard catalogProviderID == conversation.providerID, catalogConversationID == conversation.id else {
            return "Refresh the model catalog for this conversation before sending."
        }
        guard let model = models.first(where: { $0.id == conversation.modelID }) else {
            return "Model \(conversation.modelID.rawValue) is not available in the current provider catalog. Choose an available model."
        }
        guard model.capabilities.supports(conversation.reasoningEffort) else {
            return "Model \(model.displayName) does not support reasoning effort \(conversation.reasoningEffort.rawValue). Choose a supported effort."
        }
        return nil
    }

    private static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000, value.isMultiple(of: 1_000_000) { return "\(value / 1_000_000)M" }
        if value >= 1_000, value.isMultiple(of: 1_000) { return "\(value / 1_000)K" }
        return value.formatted()
    }
}
