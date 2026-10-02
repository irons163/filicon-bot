import Foundation
import CryptoKit
import Darwin
import FiliconAgents
import FiliconAutomations
import FiliconDomain

public enum AutomationDirectSessionError: String, LocalizedError, Sendable {
    case unavailable = "The background agent session is unavailable."
    case reviewRequired = "Review the background agent session again after changing the routine, account, conversation, agent or model."
    case busy = "The background conversation is already working or awaiting a reply. This run was not started or retried."
    case conflictingSession = "Revoke the existing background session before choosing a different session type."
    public var errorDescription: String? { rawValue }
}

/// Human-reviewed, host-only consent. A model-authored routine definition and
/// a conversation's identity binding are neither background nor memory consent.
public struct AutomationDirectSessionBinding: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let automationID: UUID
    public let agentID: UUID
    public let accountID: String
    public let conversationID: UUID
    public let conversationTitle: String
    public let definitionDigest: String
    public let identityDigest: String
    public let memoryAccess: AutomationGroupSessionBinding.MemoryAccess
    public let reviewedAt: Date

    public init(id: UUID = UUID(), automation: Automation, accountID: String, conversation: Conversation,
                profile: AgentProfile, memoryAccess: AutomationGroupSessionBinding.MemoryAccess = .none,
                reviewedAt: Date = Date()) throws {
        guard !accountID.isEmpty, automation.agentID == profile.id, profile.archivedAt == nil,
              conversation.agentBinding == .init(accountID: accountID, agentID: profile.id),
              conversation.providerID == profile.providerID, conversation.modelID == profile.modelID else {
            throw AutomationDirectSessionError.unavailable
        }
        self.id = id; automationID = automation.id; agentID = profile.id; self.accountID = accountID
        conversationID = conversation.id; conversationTitle = conversation.title
        definitionDigest = try Self.definitionDigest(automation)
        identityDigest = try Self.identityDigest(conversation, profile)
        self.memoryAccess = memoryAccess; self.reviewedAt = reviewedAt
    }

    public func matches(automation: Automation, accountID: String, conversation: Conversation, profile: AgentProfile) -> Bool {
        self.accountID == accountID && automationID == automation.id && agentID == automation.agentID
            && conversationID == conversation.id && profile.id == agentID && profile.archivedAt == nil
            && conversation.agentBinding == .init(accountID: accountID, agentID: agentID)
            && conversation.providerID == profile.providerID && conversation.modelID == profile.modelID
            && definitionDigest == (try? Self.definitionDigest(automation))
            && identityDigest == (try? Self.identityDigest(conversation, profile))
    }

    private static func definitionDigest(_ automation: Automation) throws -> String {
        struct Definition: Encodable {
            let id: UUID; let agentID: UUID; let name: String; let prompt: String
            let trigger: AutomationTrigger; let revision: Int64
        }
        return try digest(Definition(id: automation.id, agentID: automation.agentID, name: automation.name,
            prompt: automation.prompt, trigger: automation.trigger, revision: automation.revision))
    }
    private static func identityDigest(_ conversation: Conversation, _ profile: AgentProfile) throws -> String {
        struct Identity: Encodable {
            let provider: ProviderID; let model: ModelID; let reasoning: ReasoningEffort
            let name: String; let title: String; let summary: String; let instructions: String
        }
        return try digest(Identity(provider: conversation.providerID, model: conversation.modelID,
            reasoning: conversation.reasoningEffort, name: profile.name, title: profile.title,
            summary: profile.summary, instructions: profile.instructions))
    }
    private static func digest<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

public actor AutomationDirectSessionBindingStore {
    private let url: URL
    private var bindings: [AutomationDirectSessionBinding]
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1_000_000 else {
                throw AutomationDirectSessionError.unavailable
            }
            bindings = try JSONDecoder().decode([AutomationDirectSessionBinding].self, from: Data(contentsOf: url))
            guard bindings.count <= 1_000, Set(bindings.map(\.automationID)).count == bindings.count else {
                throw AutomationDirectSessionError.unavailable
            }
        } else { bindings = [] }
    }
    public func list() -> [AutomationDirectSessionBinding] { bindings }
    public func binding(automationID: UUID) -> AutomationDirectSessionBinding? { bindings.first { $0.automationID == automationID } }
    public func save(_ value: AutomationDirectSessionBinding, replacing expected: AutomationDirectSessionBinding?,
                     lease: AgentWorkflowExecutionScope.Lease) throws {
        try lease.commit {
            guard binding(automationID: value.automationID) == expected else { throw AutomationDirectSessionError.reviewRequired }
            var next = bindings.filter { $0.automationID != value.automationID }; next.append(value)
            guard next.count <= 1_000 else { throw AutomationDirectSessionError.unavailable }
            try persist(next); bindings = next
        }
    }
    public func revoke(_ expected: AutomationDirectSessionBinding, lease: AgentWorkflowExecutionScope.Lease) throws {
        try lease.commit {
            guard binding(automationID: expected.automationID) == expected else { throw AutomationDirectSessionError.reviewRequired }
            let next = bindings.filter { $0.automationID != expected.automationID }
            try persist(next); bindings = next
        }
    }
    private func persist(_ values: [AutomationDirectSessionBinding]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(values)
        guard bytes.count <= 1_000_000 else { throw AutomationDirectSessionError.unavailable }
        let temporary = url.deletingLastPathComponent().appending(path: ".direct-consent-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
