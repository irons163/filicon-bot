import Foundation
import CryptoKit
import Darwin
import FiliconAgents
import FiliconDomain

public enum WorkflowDirectSessionError: String, LocalizedError, Sendable {
    case unavailable = "The workflow agent session is unavailable."
    case reviewRequired = "Review the workflow session again after changing its steps, references, account, conversation, agent or model."
    case busy = "The workflow conversation is working or awaiting a reply. This step was not started or retried."
    case anotherAccount = "The workflow session belongs to another account. Revoke it in that account before reviewing a new session."
    public var errorDescription: String? { rawValue }
}

/// Host-only human consent, separate from imported/model-authored workflow
/// definitions. Review covers the entire recipe and its resolved references.
public struct WorkflowDirectSessionBinding: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let workflowID: String
    public let agentID: UUID
    public let accountID: String
    public let conversationID: UUID
    public let conversationTitle: String
    public let definitionDigest: String
    public let identityDigest: String
    public let memoryAccess: AutomationGroupSessionBinding.MemoryAccess
    public let reviewedAt: Date

    public init(id: UUID = UUID(), workflow: AgentWorkflow, references: [AgentWorkflow], accountID: String,
                conversation: Conversation, profile: AgentProfile,
                memoryAccess: AutomationGroupSessionBinding.MemoryAccess = .none, reviewedAt: Date = Date()) throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 1_024, workflow.agentID == profile.id,
              profile.archivedAt == nil, conversation.title.utf8.count <= 8_192,
              conversation.agentBinding == .init(accountID: accountID, agentID: profile.id),
              conversation.providerID == profile.providerID, conversation.modelID == profile.modelID else {
            throw WorkflowDirectSessionError.unavailable
        }
        self.id = id; workflowID = workflow.id; agentID = profile.id; self.accountID = accountID
        conversationID = conversation.id; conversationTitle = conversation.title
        definitionDigest = try Self.definitionDigest(workflow, references)
        identityDigest = try Self.identityDigest(conversation, profile)
        self.memoryAccess = memoryAccess; self.reviewedAt = reviewedAt
    }

    public func matches(workflow: AgentWorkflow, references: [AgentWorkflow], accountID: String,
                        conversation: Conversation, profile: AgentProfile) -> Bool {
        workflowID == workflow.id && agentID == workflow.agentID
            && matchesIdentity(accountID: accountID, conversation: conversation, profile: profile)
            && definitionDigest == (try? Self.definitionDigest(workflow, references))
    }

    public func matchesIdentity(accountID: String, conversation: Conversation, profile: AgentProfile) -> Bool {
        self.accountID == accountID && conversationID == conversation.id && profile.id == agentID && profile.archivedAt == nil
            && conversation.agentBinding == .init(accountID: accountID, agentID: agentID)
            && conversation.providerID == profile.providerID && conversation.modelID == profile.modelID
            && identityDigest == (try? Self.identityDigest(conversation, profile))
    }

    private static func definitionDigest(_ workflow: AgentWorkflow, _ references: [AgentWorkflow]) throws -> String {
        struct Definition: Encodable {
            let id: String; let agentID: UUID?; let name: String; let description: String
            let enabled: Bool; let trigger: AgentWorkflowTrigger; let steps: [AgentWorkflowStep]; let source: String?
            init(_ value: AgentWorkflow) throws {
                let value = try value.validated()
                id = value.id; agentID = value.agentID; name = value.name; description = value.description
                enabled = value.isEnabled; trigger = value.trigger; steps = value.steps; source = value.sourceReference
            }
        }
        guard references.count <= AgentWorkflowLimits.maximumReferences,
              Set(references.map(\.id)).count == references.count else { throw WorkflowDirectSessionError.unavailable }
        return try digest([Definition(workflow)] + references.map { try Definition($0) })
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

public actor WorkflowDirectSessionBindingStore {
    private let url: URL
    public init(url: URL) throws { self.url = url; _ = try Self.read(url) }
    public func list() throws -> [WorkflowDirectSessionBinding] { try Self.read(url) }
    public func binding(workflowID: String) throws -> WorkflowDirectSessionBinding? {
        try Self.read(url).first { $0.workflowID == workflowID }
    }
    public func save(_ value: WorkflowDirectSessionBinding, replacing expected: WorkflowDirectSessionBinding?,
                     lease: AgentWorkflowExecutionScope.Lease) throws {
        try lease.commit {
            guard expected == nil || expected?.accountID == value.accountID else { throw WorkflowDirectSessionError.anotherAccount }
            let current = try Self.read(url)
            guard current.first(where: { $0.workflowID == value.workflowID }) == expected else {
                throw WorkflowDirectSessionError.reviewRequired
            }
            try persist(current.filter { $0.workflowID != value.workflowID } + [value])
        }
    }
    public func revoke(_ expected: WorkflowDirectSessionBinding, lease: AgentWorkflowExecutionScope.Lease) throws {
        try lease.commit {
            let current = try Self.read(url)
            guard current.first(where: { $0.workflowID == expected.workflowID }) == expected else {
                throw WorkflowDirectSessionError.reviewRequired
            }
            try persist(current.filter { $0.workflowID != expected.workflowID })
        }
    }
    private static func checkPath(_ url: URL) throws {
        guard url.isFileURL else { throw WorkflowDirectSessionError.unavailable }
        var component = url.standardizedFileURL
        while component.path != "/" {
            if FileManager.default.fileExists(atPath: component.path) {
                let info = try component.resourceValues(forKeys: [.isSymbolicLinkKey])
                guard info.isSymbolicLink != true || ["/tmp", "/var", "/etc"].contains(component.path) else {
                    throw WorkflowDirectSessionError.unavailable
                }
            }
            component.deleteLastPathComponent()
        }
    }
    private static func read(_ url: URL) throws -> [WorkflowDirectSessionBinding] {
        try checkPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 1_000_000 else { throw WorkflowDirectSessionError.unavailable }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_000_000 else { throw WorkflowDirectSessionError.unavailable }
        let values = try JSONDecoder().decode([WorkflowDirectSessionBinding].self, from: data)
        try validate(values)
        return values
    }
    private static func validate(_ values: [WorkflowDirectSessionBinding]) throws {
        guard values.count <= AgentWorkflowLimits.maximumWorkflows,
              Set(values.map(\.workflowID)).count == values.count,
              values.allSatisfy({ AgentWorkflow.isSafeIdentifier($0.workflowID)
                  && !$0.accountID.isEmpty && $0.accountID.utf8.count <= 1_024 && $0.conversationTitle.utf8.count <= 8_192
                  && $0.definitionDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil
                  && $0.identityDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil }) else {
            throw WorkflowDirectSessionError.unavailable
        }
    }
    private func persist(_ values: [WorkflowDirectSessionBinding]) throws {
        try Self.checkPath(url); try Self.validate(values)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(values)
        guard bytes.count <= 1_000_000 else { throw WorkflowDirectSessionError.unavailable }
        let temporary = url.deletingLastPathComponent().appending(path: ".workflow-consent-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
