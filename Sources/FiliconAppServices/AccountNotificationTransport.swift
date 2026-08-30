import Foundation

public enum AccountNotificationTransportTransition: Equatable, Sendable {
    case unchanged
    case activated(scopeID: String, revision: UInt64)
    case deactivated(revision: UInt64)
}

/// Fences notification delivery to the currently connected account. Changing
/// or losing the account advances the revision so stale async work can be
/// rejected by callers before it reaches a tray or the system notification
/// center.
public struct AccountNotificationTransport: Equatable, Sendable {
    public private(set) var scopeID: String?
    public private(set) var revision: UInt64

    public init(scopeID: String? = nil, revision: UInt64 = 0) {
        self.scopeID = scopeID
        self.revision = revision
    }

    public var isActive: Bool { scopeID != nil }

    @discardableResult
    public mutating func activate(scopeID rawScopeID: String) -> AccountNotificationTransportTransition {
        let scopeID = rawScopeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scopeID.isEmpty else { return deactivate() }
        guard self.scopeID != scopeID else { return .unchanged }
        revision &+= 1
        self.scopeID = scopeID
        return .activated(scopeID: scopeID, revision: revision)
    }

    @discardableResult
    public mutating func deactivate() -> AccountNotificationTransportTransition {
        guard scopeID != nil else { return .unchanged }
        revision &+= 1
        scopeID = nil
        return .deactivated(revision: revision)
    }

    public func accepts(scopeID: String, revision: UInt64) -> Bool {
        self.scopeID == scopeID && self.revision == revision
    }
}
