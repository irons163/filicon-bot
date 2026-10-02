import Foundation
import CryptoKit
import Darwin
import FiliconAgents
import FiliconAutomations

public enum AutomationGroupSessionError: String, LocalizedError, Sendable {
    case unavailable = "The background group session is unavailable."
    case reviewRequired = "Review the background group session again after changing the routine, account, group or members."
    case busy = "The background group is already working. This run was not started or retried."
    public var errorDescription: String? { rawValue }
}

/// Saved separately from definitions. Only the human host UI can create this
/// consent; importing/editing a routine or update_state never creates a grant.
/// Existing memory consent is NOT consent for this unattended audience.
public struct AutomationGroupSessionBinding: Codable, Hashable, Sendable, Identifiable {
    public enum MemoryAccess: String, Codable, Sendable { case none, savedFacts }
    public let id: UUID
    public let automationID: UUID
    public let agentID: UUID
    public let accountID: String
    public let groupID: UUID
    public let groupName: String
    public let groupSummary: String
    public let memberIDs: [UUID]
    public let definitionDigest: String
    public let memoryAccess: MemoryAccess
    public let reviewedAt: Date

    public init(id: UUID = UUID(), automation: Automation, accountID: String, group: AgentGroup,
                memoryAccess: MemoryAccess = .none, reviewedAt: Date = Date()) throws {
        guard !accountID.isEmpty, !group.memberIDs.isEmpty,
              group.memberIDs.count <= GroupService.maximumMembers,
              Set(group.memberIDs).count == group.memberIDs.count,
              group.memberIDs.contains(automation.agentID) else { throw AutomationGroupSessionError.unavailable }
        self.id = id; self.automationID = automation.id; self.agentID = automation.agentID; self.accountID = accountID
        self.groupID = group.id; self.groupName = group.name; self.groupSummary = group.summary
        self.memberIDs = group.memberIDs; self.definitionDigest = try Self.digest(automation)
        self.memoryAccess = memoryAccess; self.reviewedAt = reviewedAt
    }

    public func matches(automation: Automation, accountID: String, group: AgentGroup) -> Bool {
        self.accountID == accountID && automationID == automation.id && agentID == automation.agentID
            && definitionDigest == (try? Self.digest(automation)) && groupID == group.id
            && groupName == group.name && groupSummary == group.summary && memberIDs == group.memberIDs
            && memberIDs.contains(agentID) && Set(memberIDs).count == memberIDs.count
            && !memberIDs.isEmpty && memberIDs.count <= GroupService.maximumMembers
    }

    private static func digest(_ automation: Automation) throws -> String {
        struct Definition: Encodable {
            let id: UUID; let agentID: UUID; let name: String; let prompt: String
            let trigger: AutomationTrigger; let revision: Int64
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Definition(id: automation.id, agentID: automation.agentID,
            name: automation.name, prompt: automation.prompt, trigger: automation.trigger, revision: automation.revision))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Compare-and-save is fenced through the final atomic write. A stale UI sheet,
/// account transition or revoked lease cannot leave a new grant on disk.
public actor AutomationGroupSessionBindingStore {
    private let url: URL
    private var bindings: [AutomationGroupSessionBinding]
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 1_000_000 else {
                throw AutomationGroupSessionError.unavailable
            }
            bindings = try JSONDecoder().decode([AutomationGroupSessionBinding].self, from: Data(contentsOf: url))
            guard bindings.count <= 1_000, Set(bindings.map(\.automationID)).count == bindings.count else {
                throw AutomationGroupSessionError.unavailable
            }
        } else { bindings = [] }
    }
    public func list() -> [AutomationGroupSessionBinding] { bindings }
    public func binding(automationID: UUID) -> AutomationGroupSessionBinding? { bindings.first { $0.automationID == automationID } }

    public func save(_ value: AutomationGroupSessionBinding, replacing expected: AutomationGroupSessionBinding?,
                     lease: AgentWorkflowExecutionScope.Lease) throws {
        try lease.commit {
            guard binding(automationID: value.automationID) == expected else { throw AutomationGroupSessionError.reviewRequired }
            var next = bindings.filter { $0.automationID != value.automationID }; next.append(value)
            guard next.count <= 1_000 else { throw AutomationGroupSessionError.unavailable }
            try persist(next); bindings = next
        }
    }
    public func revoke(_ expected: AutomationGroupSessionBinding, lease: AgentWorkflowExecutionScope.Lease) throws {
        try lease.commit {
            guard binding(automationID: expected.automationID) == expected else { throw AutomationGroupSessionError.reviewRequired }
            let next = bindings.filter { $0.automationID != expected.automationID }
            try persist(next); bindings = next
        }
    }
    private func persist(_ values: [AutomationGroupSessionBinding]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(values)
        guard bytes.count <= 1_000_000 else { throw AutomationGroupSessionError.unavailable }
        // Apply private permissions before the atomic commit. A failed chmod
        // must not leave durable consent while the caller observes failure.
        let temporary = url.deletingLastPathComponent().appending(path: ".group-consent-\(UUID()).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
