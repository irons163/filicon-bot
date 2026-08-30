import Foundation

public struct AutoReviewInstructions: Codable, Equatable, Sendable {
    public static let maximumRulesPerKind = 20
    public static let maximumRuleLength = 1_000

    public var isEnabled: Bool
    public var allowRules: [String] {
        didSet { allowRules = Self.normalized(allowRules) }
    }
    public var askRules: [String] {
        didSet { askRules = Self.normalized(askRules) }
    }

    public init(isEnabled: Bool = false, allowRules: [String] = [], askRules: [String] = []) {
        self.isEnabled = isEnabled
        self.allowRules = Self.normalized(allowRules)
        self.askRules = Self.normalized(askRules)
    }

    public mutating func setAllowRules(_ rules: [String]) { allowRules = Self.normalized(rules) }
    public mutating func setAskRules(_ rules: [String]) { askRules = Self.normalized(rules) }

    private static func normalized(_ rules: [String]) -> [String] {
        rules.prefix(maximumRulesPerKind).map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumRuleLength))
        }.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, allowRules, askRules, enabled, allow, ask, block, blockRules, mode
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try values.decodeIfPresent(String.self, forKey: .mode)?.lowercased()
        let enabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled)
            ?? values.decodeIfPresent(Bool.self, forKey: .enabled)
            ?? (mode.map { $0 != "off" && $0 != "disabled" } ?? false)
        let allow = try values.decodeIfPresent([String].self, forKey: .allowRules)
            ?? values.decodeIfPresent([String].self, forKey: .allow)
            ?? []
        let ask = try values.decodeIfPresent([String].self, forKey: .askRules)
            ?? values.decodeIfPresent([String].self, forKey: .ask)
            ?? values.decodeIfPresent([String].self, forKey: .blockRules)
            ?? values.decodeIfPresent([String].self, forKey: .block)
            ?? []
        self.init(isEnabled: enabled, allowRules: allow, askRules: ask)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(allowRules, forKey: .allowRules)
        try values.encode(askRules, forKey: .askRules)
        try values.encode(isEnabled ? "enabled" : "disabled", forKey: .mode)
    }
}

public enum AutoReviewTarget: Codable, Hashable, Sendable {
    case file(path: String)
    case command(executable: String)
    case network(host: String)
    case account(identifier: String)
    case recipient(identifier: String)
    case resource(kind: String, identifier: String)

    public var searchableText: String {
        switch self {
        case .file(let path): "file \(path)"
        case .command(let executable): "command \(executable)"
        case .network(let host): "network \(host)"
        case .account(let identifier): "account \(identifier)"
        case .recipient(let identifier): "recipient \(identifier)"
        case .resource(let kind, let identifier): "\(kind) \(identifier)"
        }
    }
}

public enum AutoReviewRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case readOnly
    case externalSideEffect
    case destructive
    case sensitive
    case irreversible
}

public struct ApprovalFence: Codable, Hashable, Sendable {
    public let accountID: String
    public let agentID: String
    public let runID: UUID
    public let generation: UInt64

    public init(accountID: String, agentID: String, runID: UUID, generation: UInt64) {
        self.accountID = accountID
        self.agentID = agentID
        self.runID = runID
        self.generation = generation
    }
}

public struct AutoReviewActionContext: Codable, Hashable, Sendable {
    public let fence: ApprovalFence
    public let conversationID: UUID
    public let toolCallID: String
    public let metadata: [String: String]

    public init(
        fence: ApprovalFence,
        conversationID: UUID,
        toolCallID: String,
        metadata: [String: String] = [:]
    ) {
        self.fence = fence
        self.conversationID = conversationID
        self.toolCallID = toolCallID
        self.metadata = metadata
    }
}

public struct AutoReviewAction: Codable, Hashable, Sendable {
    public let summary: String
    public let target: AutoReviewTarget
    public let risks: Set<AutoReviewRisk>
    public let context: AutoReviewActionContext

    public init(
        summary: String,
        target: AutoReviewTarget,
        risks: Set<AutoReviewRisk>,
        context: AutoReviewActionContext
    ) {
        self.summary = String(summary.prefix(2_000))
        self.target = target
        self.risks = risks
        self.context = context
    }

    public var searchableText: String {
        ([summary, target.searchableText] + risks.map(\.rawValue)).joined(separator: " ").lowercased()
    }
}

public enum AutoReviewDecision: String, Codable, Equatable, Sendable {
    case allow
    case ask
}

public struct AutoReviewClassification: Codable, Equatable, Sendable {
    public let decision: AutoReviewDecision
    public let reason: String
    public let isTrusted: Bool

    public init(decision: AutoReviewDecision, reason: String, isTrusted: Bool) {
        self.decision = decision
        self.reason = reason
        self.isTrusted = isTrusted
    }
}

public struct AutoReviewEvaluation: Equatable, Sendable {
    public let decision: AutoReviewDecision
    public let reason: String

    public init(decision: AutoReviewDecision, reason: String) {
        self.decision = decision
        self.reason = reason
    }
}
