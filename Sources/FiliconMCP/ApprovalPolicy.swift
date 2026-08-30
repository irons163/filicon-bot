import CryptoKit
import Foundation

public enum MCPToolRisk: String, Codable, Hashable, Sendable {
    case localRead, openWorldRead, mutation, destructive, unknown
}

public struct MCPToolRiskAssessment: Codable, Hashable, Sendable {
    public let risk: MCPToolRisk
    public let reasons: [String]
    public var canBeAutomaticallyApproved: Bool { risk == .localRead }

    public init(descriptor: MCPToolDescriptor) {
        let value = descriptor.annotations ?? MCPToolAnnotations()
        var reasons: [String] = []
        if value.isMalformed { reasons.append("Malformed annotations") }
        if value.hasUnknownFields { reasons.append("Unknown annotation fields") }
        if value.hasContradictoryHints { reasons.append("Read-only and destructive hints conflict") }
        if !reasons.isEmpty {
            risk = .unknown
        } else if value.readOnlyHint {
            risk = value.openWorldHint ? .openWorldRead : .localRead
        } else if value.destructiveHint {
            risk = .destructive
        } else {
            risk = .mutation
        }
        self.reasons = reasons
    }
}

public enum MCPPermissionMode: Int, Codable, Hashable, Sendable {
    case always = 0
    case ask = 1
    case never = 2
}

/// The managed value is a ceiling: it may make a user policy more restrictive,
/// but can never grant an operation the user policy denied.
public struct MCPDispatchPolicy: Codable, Hashable, Sendable {
    public let userMode: MCPPermissionMode
    public let managedCeiling: MCPPermissionMode
    public let permitsAutomaticLocalReads: Bool

    public init(userMode: MCPPermissionMode = .ask, managedCeiling: MCPPermissionMode = .always, permitsAutomaticLocalReads: Bool = true) {
        self.userMode = userMode
        self.managedCeiling = managedCeiling
        self.permitsAutomaticLocalReads = permitsAutomaticLocalReads
    }

    public var effectiveMode: MCPPermissionMode {
        MCPPermissionMode(rawValue: max(userMode.rawValue, managedCeiling.rawValue)) ?? .never
    }
}

public enum MCPAutoReviewRecommendation: Codable, Hashable, Sendable {
    case allow, ask, deny
}

public struct MCPCallTarget: Codable, Hashable, Sendable {
    public let serverIdentifier: String
    public let accountIdentifier: String
    public let conversationIdentifier: String
    public let toolName: String
    public let argumentsHash: String
    public let generation: UInt64

    public init(serverIdentifier: String, accountIdentifier: String, conversationIdentifier: String, toolName: String, arguments: MCPJSONValue, generation: UInt64) {
        self.serverIdentifier = serverIdentifier
        self.accountIdentifier = accountIdentifier
        self.conversationIdentifier = conversationIdentifier
        self.toolName = toolName
        self.argumentsHash = Self.hash(arguments)
        self.generation = generation
    }

    public static func hash(_ arguments: MCPJSONValue) -> String {
        let data = canonicalData(arguments)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalData(_ value: MCPJSONValue) -> Data {
        var data = Data()
        func appendLength(_ length: Int) {
            let value = UInt64(length)
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xff))
            }
        }
        func append(_ value: MCPJSONValue) {
            switch value {
            case .null: data.append(0)
            case .bool(let boolean): data.append(boolean ? 2 : 1)
            case .number(let number):
                data.append(3)
                let bits = number.bitPattern
                for shift in stride(from: 56, through: 0, by: -8) {
                    data.append(UInt8((bits >> UInt64(shift)) & 0xff))
                }
            case .string(let string):
                data.append(4)
                let bytes = Data(string.utf8)
                appendLength(bytes.count)
                data.append(bytes)
            case .array(let values):
                data.append(5)
                appendLength(values.count)
                values.forEach(append)
            case .object(let object):
                data.append(6)
                appendLength(object.count)
                for key in object.keys.sorted() {
                    append(.string(key))
                    append(object[key]!)
                }
            }
        }
        append(value)
        return data
    }
}

public enum MCPAlwaysScope: Codable, Hashable, Sendable {
    /// All identity fences, including the canonical arguments hash, must match.
    case exactArguments
    /// Server, account, conversation and tool must match. This is an explicit
    /// user choice and is unavailable when the managed ceiling is `ask`/`never`.
    case tool
}

public enum MCPApprovalResolution: Codable, Hashable, Sendable {
    case allowOnce
    case allowAlways(scope: MCPAlwaysScope)
    case deny
}

public struct MCPApprovalRequest: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let target: MCPCallTarget
    public let risk: MCPToolRiskAssessment
    public let createdAt: Date
    public let expiresAt: Date
}

public struct MCPAuthorizationReceipt: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let target: MCPCallTarget
    public let issuedAt: Date
    public let expiresAt: Date
}

public enum MCPDispatchPreparation: Sendable, Equatable {
    case authorized(MCPAuthorizationReceipt)
    case approvalRequired(MCPApprovalRequest)
    case denied(String)
}

public enum MCPAuthorizationError: LocalizedError, Equatable, Sendable {
    case unknownRequest, requestExpired, requestCancelled, denied
    case persistentGrantExceedsManagedCeiling, unsafePersistentGrant
    case invalidReceipt, receiptExpired, receiptAlreadyUsed, targetMismatch, staleGeneration

    public var errorDescription: String? {
        switch self {
        case .unknownRequest: "The MCP approval request does not exist."
        case .requestExpired: "The MCP approval request expired."
        case .requestCancelled: "The MCP approval request was cancelled."
        case .denied: "The MCP call was denied."
        case .persistentGrantExceedsManagedCeiling: "Managed policy does not permit an always grant."
        case .unsafePersistentGrant: "Unknown or contradictory annotations cannot receive an always grant."
        case .invalidReceipt: "The MCP authorization receipt is invalid."
        case .receiptExpired: "The MCP authorization receipt expired."
        case .receiptAlreadyUsed: "The MCP authorization receipt has already been used."
        case .targetMismatch: "The MCP authorization receipt does not match this exact call."
        case .staleGeneration: "The MCP authorization generation is stale."
        }
    }
}

public actor MCPAuthorizationCoordinator {
    public static let receiptTTL: TimeInterval = 10 * 60

    private struct StoredRequest { let value: MCPApprovalRequest; var cancelled: Bool }
    private struct StoredReceipt { let value: MCPAuthorizationReceipt; var consumed: Bool }
    private struct Grant: Hashable { let target: MCPCallTarget; let scope: MCPAlwaysScope }
    private struct GenerationKey: Hashable { let server: String; let account: String; let conversation: String }

    private let now: @Sendable () -> Date
    private var requests: [UUID: StoredRequest] = [:]
    private var receipts: [UUID: StoredReceipt] = [:]
    private var grants: Set<Grant> = []
    private var generations: [GenerationKey: UInt64] = [:]

    public init(now: @escaping @Sendable () -> Date = Date.init) { self.now = now }

    public func currentGeneration(serverIdentifier: String, accountIdentifier: String, conversationIdentifier: String) -> UInt64 {
        generations[.init(server: serverIdentifier, account: accountIdentifier, conversation: conversationIdentifier), default: 0]
    }

    public func makeTarget(serverIdentifier: String, accountIdentifier: String, conversationIdentifier: String, toolName: String, arguments: MCPJSONValue) -> MCPCallTarget {
        let generation = currentGeneration(serverIdentifier: serverIdentifier, accountIdentifier: accountIdentifier, conversationIdentifier: conversationIdentifier)
        return .init(serverIdentifier: serverIdentifier, accountIdentifier: accountIdentifier, conversationIdentifier: conversationIdentifier, toolName: toolName, arguments: arguments, generation: generation)
    }

    public func prepare(
        target: MCPCallTarget,
        descriptor: MCPToolDescriptor,
        policy: MCPDispatchPolicy,
        autoReview: MCPAutoReviewRecommendation = .ask
    ) -> MCPDispatchPreparation {
        guard generationIsCurrent(target) else { return .denied(MCPAuthorizationError.staleGeneration.localizedDescription) }
        guard target.serverIdentifier == descriptor.serverIdentifier, target.toolName == descriptor.name else {
            return .denied(MCPAuthorizationError.targetMismatch.localizedDescription)
        }
        if autoReview == .deny || policy.effectiveMode == .never { return .denied(MCPAuthorizationError.denied.localizedDescription) }
        let risk = MCPToolRiskAssessment(descriptor: descriptor)
        if risk.risk != .unknown, policy.managedCeiling == .always, matchingGrant(for: target) {
            return .authorized(issueReceipt(for: target))
        }
        // Auto-review is advisory and may only narrow access. Its `allow` result
        // never upgrades an annotation/policy decision.
        if policy.effectiveMode == .always, policy.permitsAutomaticLocalReads, risk.canBeAutomaticallyApproved {
            return .authorized(issueReceipt(for: target))
        }
        let created = now()
        let request = MCPApprovalRequest(id: UUID(), target: target, risk: risk, createdAt: created, expiresAt: created.addingTimeInterval(Self.receiptTTL))
        requests[request.id] = .init(value: request, cancelled: false)
        return .approvalRequired(request)
    }

    public func resolve(requestID: UUID, resolution: MCPApprovalResolution, policy: MCPDispatchPolicy) throws -> MCPAuthorizationReceipt? {
        guard let stored = requests.removeValue(forKey: requestID) else { throw MCPAuthorizationError.unknownRequest }
        if stored.cancelled { throw MCPAuthorizationError.requestCancelled }
        if now() >= stored.value.expiresAt { throw MCPAuthorizationError.requestExpired }
        guard generationIsCurrent(stored.value.target) else { throw MCPAuthorizationError.staleGeneration }
        guard policy.effectiveMode != .never else { throw MCPAuthorizationError.denied }
        switch resolution {
        case .deny: throw MCPAuthorizationError.denied
        case .allowOnce: return issueReceipt(for: stored.value.target)
        case .allowAlways(let scope):
            guard policy.managedCeiling == .always else { throw MCPAuthorizationError.persistentGrantExceedsManagedCeiling }
            guard stored.value.risk.risk != .unknown else { throw MCPAuthorizationError.unsafePersistentGrant }
            grants.insert(.init(target: stored.value.target, scope: scope))
            return issueReceipt(for: stored.value.target)
        }
    }

    public func cancel(requestID: UUID) {
        guard var value = requests[requestID] else { return }
        value.cancelled = true
        requests[requestID] = value
    }

    public func advanceGeneration(serverIdentifier: String, accountIdentifier: String, conversationIdentifier: String) {
        let key = GenerationKey(server: serverIdentifier, account: accountIdentifier, conversation: conversationIdentifier)
        generations[key, default: 0] &+= 1
        requests = requests.filter { !matches($0.value.value.target, key) }
        receipts = receipts.filter { !matches($0.value.value.target, key) }
        grants = grants.filter { !matches($0.target, key) }
    }

    /// Atomically consumes the receipt before dispatch, preventing concurrent replay.
    public func consume(_ receipt: MCPAuthorizationReceipt, for target: MCPCallTarget, policy: MCPDispatchPolicy = .init()) throws {
        guard policy.effectiveMode != .never else { throw MCPAuthorizationError.denied }
        guard generationIsCurrent(target) else { throw MCPAuthorizationError.staleGeneration }
        guard var stored = receipts[receipt.id], stored.value == receipt else { throw MCPAuthorizationError.invalidReceipt }
        guard !stored.consumed else { throw MCPAuthorizationError.receiptAlreadyUsed }
        guard now() < stored.value.expiresAt else { receipts.removeValue(forKey: receipt.id); throw MCPAuthorizationError.receiptExpired }
        guard stored.value.target == target else { throw MCPAuthorizationError.targetMismatch }
        stored.consumed = true
        receipts[receipt.id] = stored
    }

    private func issueReceipt(for target: MCPCallTarget) -> MCPAuthorizationReceipt {
        let issued = now()
        let value = MCPAuthorizationReceipt(id: UUID(), target: target, issuedAt: issued, expiresAt: issued.addingTimeInterval(Self.receiptTTL))
        receipts[value.id] = .init(value: value, consumed: false)
        return value
    }

    private func matchingGrant(for target: MCPCallTarget) -> Bool {
        grants.contains { grant in
            let base = grant.target.serverIdentifier == target.serverIdentifier
                && grant.target.accountIdentifier == target.accountIdentifier
                && grant.target.conversationIdentifier == target.conversationIdentifier
                && grant.target.toolName == target.toolName
                && grant.target.generation == target.generation
            return base && (grant.scope == .tool || grant.target.argumentsHash == target.argumentsHash)
        }
    }

    private func generationIsCurrent(_ target: MCPCallTarget) -> Bool {
        target.generation == currentGeneration(serverIdentifier: target.serverIdentifier, accountIdentifier: target.accountIdentifier, conversationIdentifier: target.conversationIdentifier)
    }

    private func matches(_ target: MCPCallTarget, _ key: GenerationKey) -> Bool {
        target.serverIdentifier == key.server && target.accountIdentifier == key.account && target.conversationIdentifier == key.conversation
    }

}

/// App integration boundary: no MCP call reaches the service without atomically
/// consuming a receipt bound to the account, conversation, generation, tool and arguments.
public actor MCPAuthorizedDispatcher {
    private let service: MCPService
    private let authorization: MCPAuthorizationCoordinator

    public init(service: MCPService, authorization: MCPAuthorizationCoordinator) {
        self.service = service
        self.authorization = authorization
    }

    public func dispatch(target: MCPCallTarget, arguments: MCPJSONValue, receipt: MCPAuthorizationReceipt, policy: MCPDispatchPolicy = .init()) async throws -> MCPToolResult {
        guard target.argumentsHash == MCPCallTarget.hash(arguments) else { throw MCPAuthorizationError.targetMismatch }
        try await authorization.consume(receipt, for: target, policy: policy)
        return try await service.callTool(server: target.serverIdentifier, name: target.toolName, arguments: arguments)
    }
}
