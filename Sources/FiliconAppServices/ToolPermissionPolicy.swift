import Foundation
import FiliconDomain

/// Fail-closed local-tool permission policy.
///
/// `always/ask/never` follows the reconstructed app's ordering, while an
/// optional administrator ceiling can only reduce authority. One-time grants
/// are scoped to a conversation, call id, and action and are consumed exactly
/// once so they cannot authorize a replayed tool call.
public actor ToolPermissionPolicy {
    private struct PersistedChoices: Codable {
        var choices: [LocalToolAction: LocalToolPermission]
    }

    private struct GrantKey: Hashable {
        let conversationID: UUID
        let toolCallID: String
        let action: LocalToolAction
    }

    private struct Grant {
        let expiresAt: Date
    }

    private var choices: [LocalToolAction: LocalToolPermission]
    private var ceilings: [LocalToolAction: LocalToolPermission]
    private var grants: [GrantKey: Grant] = [:]
    private let persistenceURL: URL?

    public init(
        choices: [LocalToolAction: LocalToolPermission] = [:],
        adminCeilings: [LocalToolAction: LocalToolPermission] = [:],
        persistenceURL: URL? = nil
    ) {
        self.persistenceURL = persistenceURL
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let persisted = try? JSONDecoder().decode(PersistedChoices.self, from: data) {
            self.choices = persisted.choices
        } else {
            self.choices = choices
        }
        ceilings = adminCeilings
    }

    public func setChoice(_ permission: LocalToolPermission, for action: LocalToolAction) throws {
        let previous = choices[action]
        choices[action] = permission
        do { try persistChoices() }
        catch {
            choices[action] = previous
            throw error
        }
    }

    public func configuredChoices() -> [LocalToolAction: LocalToolPermission] { choices }

    public func setAdminCeiling(_ permission: LocalToolPermission?, for action: LocalToolAction) {
        ceilings[action] = permission
    }

    public func effectivePermission(for action: LocalToolAction) -> LocalToolPermission {
        (choices[action] ?? .ask).constrained(by: ceilings[action])
    }

    /// Advisory snapshot only. Does not issue or consume any execution grant.
    public func effectivePermissions() -> [LocalToolAction: LocalToolPermission] {
        Dictionary(uniqueKeysWithValues: LocalToolAction.allCases.map { ($0, effectivePermission(for: $0)) })
    }

    public func evaluate(
        action: LocalToolAction,
        conversationID: UUID,
        toolCallID: String,
        title: String,
        reason: String,
        now: Date = Date()
    ) -> ToolPermissionDecision {
        removeExpired(now: now)
        let key = GrantKey(conversationID: conversationID, toolCallID: toolCallID, action: action)
        if grants.removeValue(forKey: key) != nil { return .allowed }

        switch effectivePermission(for: action) {
        case .always:
            return .allowed
        case .never:
            return .denied
        case .ask:
            return .requiresApproval(.init(
                conversationID: conversationID,
                toolCallID: toolCallID,
                action: action,
                title: title,
                reason: reason,
                createdAt: now
            ))
        }
    }

    public func approveOnce(_ request: ToolApprovalRequest, expiresAt: Date) {
        guard expiresAt > Date() else { return }
        grants[GrantKey(
            conversationID: request.conversationID,
            toolCallID: request.toolCallID,
            action: request.action
        )] = Grant(expiresAt: expiresAt)
    }

    public func revokePendingGrants(conversationID: UUID) {
        grants = grants.filter { $0.key.conversationID != conversationID }
    }

    private func removeExpired(now: Date) {
        grants = grants.filter { $0.value.expiresAt > now }
    }

    private func persistChoices() throws {
        guard let persistenceURL else { return }
        try FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(PersistedChoices(choices: choices))
        try data.write(to: persistenceURL, options: [.atomic])
    }
}

/// Suspends an asynchronous tool call until the user makes an explicit
/// decision. Cancellation resolves and removes the continuation immediately,
/// preventing abandoned approvals from authorizing later calls.
public actor ToolApprovalBroker {
    public typealias ChangeHandler = @Sendable ([ToolApprovalRequest]) -> Void

    private struct Pending {
        let request: ToolApprovalRequest
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var pending: [UUID: Pending] = [:]
    private var claimed: [UUID: Pending] = [:]
    private let onChange: ChangeHandler

    public init(onChange: @escaping ChangeHandler = { _ in }) {
        self.onChange = onChange
    }

    public func requestApproval(_ request: ToolApprovalRequest) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pending[request.id] = Pending(request: request, continuation: continuation)
                publish()
            }
        } onCancel: {
            Task { await self.resolve(id: request.id, allowed: false) }
        }
    }

    public func resolve(id: UUID, allowed: Bool) {
        guard let value = pending.removeValue(forKey: id) ?? claimed.removeValue(forKey: id) else { return }
        value.continuation.resume(returning: allowed)
        publish()
    }

    /// Resolves only the exact request represented by a transcript card. The
    /// comparison and removal happen in one actor turn so a stale card cannot
    /// resolve a newer or already-handled approval between a read and write.
    @discardableResult
    public func resolveIfMatches(
        id: UUID,
        conversationID: UUID,
        action: LocalToolAction,
        title: String,
        allowed: Bool
    ) -> Bool {
        guard let value = pending[id],
              value.request.conversationID == conversationID,
              value.request.action == action,
              value.request.title == title else { return false }
        pending.removeValue(forKey: id)?.continuation.resume(returning: allowed)
        publish()
        return true
    }

    /// Temporarily removes an exact request while a durable policy change is
    /// committed. Cancellation can still resolve the claim by its original ID.
    @discardableResult
    public func claimIfMatches(
        id: UUID,
        conversationID: UUID,
        action: LocalToolAction,
        title: String
    ) -> Bool {
        guard let value = pending[id],
              value.request.conversationID == conversationID,
              value.request.action == action,
              value.request.title == title else { return false }
        pending.removeValue(forKey: id)
        claimed[id] = value
        publish()
        return true
    }

    @discardableResult
    public func completeClaim(id: UUID, allowed: Bool) -> Bool {
        guard let value = claimed.removeValue(forKey: id) else { return false }
        value.continuation.resume(returning: allowed)
        publish()
        return true
    }

    public func abandonClaim(id: UUID) {
        guard let value = claimed.removeValue(forKey: id) else { return }
        if pending[id] == nil { pending[id] = value }
        else { value.continuation.resume(returning: false) }
        publish()
    }

    public func cancel(conversationID: UUID) {
        let ids = pending.values
            .filter { $0.request.conversationID == conversationID }
            .map(\.request.id)
        for id in ids {
            pending.removeValue(forKey: id)?.continuation.resume(returning: false)
        }
        let claimedIDs = claimed.values
            .filter { $0.request.conversationID == conversationID }
            .map(\.request.id)
        for id in claimedIDs {
            claimed.removeValue(forKey: id)?.continuation.resume(returning: false)
        }
        if !ids.isEmpty || !claimedIDs.isEmpty { publish() }
    }

    public func requests() -> [ToolApprovalRequest] {
        pending.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    private func publish() { onChange(requests()) }
}
