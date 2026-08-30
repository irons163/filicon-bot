import Foundation

public enum MCPDefinitionOwnership: String, Codable, Hashable, Sendable {
    case user
    case team
}

public enum MCPAccountAuthStatus: String, Codable, Hashable, Sendable {
    case signedOut
    case pending
    case authenticated
    case expired
    case failed
}

/// A display-safe account record. `tokenReference` is an opaque keychain/vault
/// reference; access and refresh tokens must never be placed in this model.
public struct MCPAccountSlot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var accountKey: String
    public var displayName: String
    public var serverIdentifier: String
    public var authStatus: MCPAccountAuthStatus
    public var tokenReference: String?
    public var enabledTools: Set<String>?
    public var disabledTools: Set<String>
    public var customInstructions: String

    public init(
        id: UUID = UUID(),
        accountKey: String,
        displayName: String,
        serverIdentifier: String,
        authStatus: MCPAccountAuthStatus = .signedOut,
        tokenReference: String? = nil,
        enabledTools: Set<String>? = nil,
        disabledTools: Set<String> = [],
        customInstructions: String = ""
    ) throws {
        let key = try Self.normalizeAccountKey(accountKey)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 256 else { throw MCPError.invalidConfiguration("Invalid MCP account display name.") }
        guard tokenReference.map(MCPServerConfig.isSecretReference) != false else {
            throw MCPError.invalidConfiguration("Invalid MCP token reference.")
        }
        self.id = id
        self.accountKey = key
        self.displayName = name
        self.serverIdentifier = try MCPServerConfig.normalizeIdentifier(serverIdentifier)
        self.authStatus = authStatus
        self.tokenReference = tokenReference
        self.enabledTools = enabledTools
        self.disabledTools = disabledTools
        self.customInstructions = String(customInstructions.prefix(16_384))
    }

    public static func normalizeAccountKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.count <= 128,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MCPError.invalidConfiguration("Invalid MCP account key.")
        }
        return key
    }

    private enum CodingKeys: String, CodingKey {
        case id, accountKey, displayName, serverIdentifier, authStatus, tokenReference
        case enabledTools, disabledTools, customInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            accountKey: c.decode(String.self, forKey: .accountKey),
            displayName: c.decodeIfPresent(String.self, forKey: .displayName) ?? c.decode(String.self, forKey: .accountKey),
            serverIdentifier: c.decode(String.self, forKey: .serverIdentifier),
            authStatus: c.decodeIfPresent(MCPAccountAuthStatus.self, forKey: .authStatus) ?? .signedOut,
            tokenReference: c.decodeIfPresent(String.self, forKey: .tokenReference),
            enabledTools: c.decodeIfPresent(Set<String>.self, forKey: .enabledTools),
            disabledTools: c.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? [],
            customInstructions: c.decodeIfPresent(String.self, forKey: .customInstructions) ?? ""
        )
    }
}

public struct MCPServerDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var ownership: MCPDefinitionOwnership
    public var popularity: Int
    public var managedReadOnly: Bool
    public var accounts: [MCPAccountSlot]

    public init(id: String, displayName: String, ownership: MCPDefinitionOwnership = .user, popularity: Int = 0, managedReadOnly: Bool = false, accounts: [MCPAccountSlot] = []) throws {
        self.id = try MCPServerConfig.normalizeIdentifier(id)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 256 else { throw MCPError.invalidConfiguration("Invalid MCP server display name.") }
        self.displayName = name
        self.ownership = ownership
        self.popularity = max(0, popularity)
        self.managedReadOnly = managedReadOnly || ownership == .team
        self.accounts = accounts
        try Self.validateAccounts(accounts)
    }

    private enum CodingKeys: String, CodingKey { case id, displayName, ownership, popularity, managedReadOnly, accounts }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            displayName: c.decode(String.self, forKey: .displayName),
            ownership: c.decodeIfPresent(MCPDefinitionOwnership.self, forKey: .ownership) ?? .user,
            popularity: c.decodeIfPresent(Int.self, forKey: .popularity) ?? 0,
            managedReadOnly: c.decodeIfPresent(Bool.self, forKey: .managedReadOnly) ?? false,
            accounts: c.decodeIfPresent([MCPAccountSlot].self, forKey: .accounts) ?? []
        )
    }

    fileprivate static func validateAccounts(_ accounts: [MCPAccountSlot]) throws {
        guard Set(accounts.map(\.accountKey)).count == accounts.count,
              Set(accounts.map(\.serverIdentifier)).count == accounts.count else {
            throw MCPError.invalidConfiguration("Duplicate MCP account slot.")
        }
    }
}

public protocol MCPTokenReferenceStore: Sendable {
    func remove(reference: String) async throws
}

public protocol MCPAccountMutationClient: Sendable {
    /// Implementations must authenticate and authorize every call. This is the
    /// only path by which a managed/team definition can be changed remotely.
    func renameAccount(serverID: String, accountKey: String, newAccountKey: String) async throws
    func removeAccount(serverID: String, accountKey: String) async throws
    func logoutAccount(serverID: String, accountKey: String) async throws
}

public enum MCPAccountLifecycleError: Error, LocalizedError, Equatable {
    case serverNotFound
    case accountNotFound
    case duplicateAccount
    case managedDefinition
    case authorizedClientRequired
    case concurrentMutation

    public var errorDescription: String? {
        switch self {
        case .serverNotFound: "MCP server not found."
        case .accountNotFound: "MCP account not found."
        case .duplicateAccount: "That MCP account already exists."
        case .managedDefinition: "This MCP definition is managed by the team and is read-only."
        case .authorizedClientRequired: "An explicitly authorized account client is required."
        case .concurrentMutation: "The MCP account changed while this operation was in progress. Retry the operation."
        }
    }
}

public actor MCPAccountLibrary {
    private let fileURL: URL
    private let tokens: any MCPTokenReferenceStore
    private let managedClient: (any MCPAccountMutationClient)?
    private var definitions: [MCPServerDefinition]?
    private var revision: UInt64 = 0

    public init(fileURL: URL, tokenStore: any MCPTokenReferenceStore, managedClient: (any MCPAccountMutationClient)? = nil) {
        self.fileURL = fileURL
        self.tokens = tokenStore
        self.managedClient = managedClient
    }

    public func list() throws -> [MCPServerDefinition] {
        try load().sorted { $0.popularity == $1.popularity ? $0.displayName < $1.displayName : $0.popularity > $1.popularity }
    }

    public func replace(_ values: [MCPServerDefinition]) throws {
        guard Set(values.map(\.id)).count == values.count else { throw MCPError.invalidConfiguration("Duplicate MCP server definition.") }
        try persist(values)
        definitions = values
    }

    /// Merge-only migration from the legacy flat configuration store. Existing
    /// user and managed definitions are never replaced or reclassified.
    @discardableResult
    public func reconcile(existingConfigs configs: [MCPServerConfig]) throws -> [MCPServerDefinition] {
        try MCPServerConfig.validateUnique(configs)
        var values = try load()
        let represented = Set(values.flatMap(\.accounts).map(\.serverIdentifier))
        for config in configs where !represented.contains(config.identifier) {
            let reference = Self.authorizationReference(in: config.transport)
            let slot = try MCPAccountSlot(
                accountKey: "default",
                displayName: config.displayName,
                serverIdentifier: config.identifier,
                authStatus: reference == nil ? .signedOut : .authenticated,
                tokenReference: reference,
                enabledTools: config.enabledTools,
                disabledTools: config.disabledTools,
                customInstructions: config.customInstructions
            )
            if let index = values.firstIndex(where: { $0.id == config.identifier && !$0.managedReadOnly }),
               !values[index].accounts.contains(where: { $0.accountKey == slot.accountKey }) {
                values[index].accounts.append(slot)
            } else {
                let definitionID = try Self.availableDefinitionID(base: config.identifier, existing: values)
                values.append(try MCPServerDefinition(
                    id: definitionID, displayName: config.displayName, ownership: .user, accounts: [slot]
                ))
            }
        }
        if values != definitions {
            try persist(values)
            definitions = values
        }
        return try list()
    }

    /// Applies account preferences to the exact runtime identified by each
    /// slot. Configurations without a slot are retained so reconciliation is
    /// non-destructive even if a future definition cannot be decoded.
    public func materializeRuntimeConfigs(existingConfigs configs: [MCPServerConfig]) throws -> [MCPServerConfig] {
        try MCPServerConfig.validateUnique(configs)
        let slots = Dictionary(uniqueKeysWithValues: try load().flatMap(\.accounts).map { ($0.serverIdentifier, $0) })
        return try configs.map { config in
            guard let slot = slots[config.identifier] else { return config }
            var runtime = config
            runtime.displayName = slot.displayName
            runtime.enabledTools = slot.enabledTools
            runtime.disabledTools = slot.disabledTools
            runtime.customInstructions = slot.customInstructions
            try runtime.validate()
            return runtime
        }.sorted { $0.identifier < $1.identifier }
    }

    @discardableResult
    public func addAccount(serverID: String, slot: MCPAccountSlot) throws -> MCPServerDefinition {
        var values = try load()
        guard let index = values.firstIndex(where: { $0.id == serverID }) else { throw MCPAccountLifecycleError.serverNotFound }
        guard !values[index].managedReadOnly else { throw MCPAccountLifecycleError.managedDefinition }
        guard !values[index].accounts.contains(where: { $0.accountKey == slot.accountKey || $0.serverIdentifier == slot.serverIdentifier }) else { throw MCPAccountLifecycleError.duplicateAccount }
        values[index].accounts.append(slot)
        try persist(values); definitions = values
        return values[index]
    }

    @discardableResult
    public func renameAccount(serverID: String, accountKey: String, newAccountKey: String, displayName: String? = nil) async throws -> MCPServerDefinition {
        var values = try load()
        guard let serverIndex = values.firstIndex(where: { $0.id == serverID }) else { throw MCPAccountLifecycleError.serverNotFound }
        guard let accountIndex = values[serverIndex].accounts.firstIndex(where: { $0.accountKey == accountKey }) else { throw MCPAccountLifecycleError.accountNotFound }
        let expectedRevision = revision
        let normalized = try MCPAccountSlot.normalizeAccountKey(newAccountKey)
        guard !values[serverIndex].accounts.contains(where: { $0.accountKey == normalized && $0.accountKey != accountKey }) else { throw MCPAccountLifecycleError.duplicateAccount }
        if values[serverIndex].managedReadOnly {
            guard let managedClient else { throw MCPAccountLifecycleError.authorizedClientRequired }
            try await managedClient.renameAccount(serverID: serverID, accountKey: accountKey, newAccountKey: normalized)
        }
        guard revision == expectedRevision else { throw MCPAccountLifecycleError.concurrentMutation }
        values[serverIndex].accounts[accountIndex].accountKey = normalized
        if let displayName {
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 256 else { throw MCPError.invalidConfiguration("Invalid MCP account display name.") }
            values[serverIndex].accounts[accountIndex].displayName = name
        }
        try persist(values); definitions = values
        return values[serverIndex]
    }

    @discardableResult
    public func setPreferences(serverID: String, accountKey: String, enabledTools: Set<String>?, disabledTools: Set<String>, customInstructions: String) throws -> MCPAccountSlot {
        var values = try load()
        guard let serverIndex = values.firstIndex(where: { $0.id == serverID }) else { throw MCPAccountLifecycleError.serverNotFound }
        guard !values[serverIndex].managedReadOnly else { throw MCPAccountLifecycleError.authorizedClientRequired }
        guard let accountIndex = values[serverIndex].accounts.firstIndex(where: { $0.accountKey == accountKey }) else { throw MCPAccountLifecycleError.accountNotFound }
        var slot = values[serverIndex].accounts[accountIndex]
        slot.enabledTools = enabledTools
        slot.disabledTools = disabledTools
        slot.customInstructions = String(customInstructions.prefix(16_384))
        values[serverIndex].accounts[accountIndex] = slot
        try persist(values); definitions = values
        return slot
    }

    /// Updates display-safe authentication metadata. Secret material must first
    /// be placed in the host's vault and supplied here only as an opaque reference.
    @discardableResult
    public func setAuthentication(
        serverID: String,
        accountKey: String,
        status: MCPAccountAuthStatus,
        tokenReference: String?
    ) async throws -> MCPAccountSlot {
        guard tokenReference.map(MCPServerConfig.isSecretReference) != false,
              status != .authenticated || tokenReference != nil else {
            throw MCPError.invalidConfiguration("Authenticated MCP accounts require a secret reference.")
        }
        var values = try load()
        guard let serverIndex = values.firstIndex(where: { $0.id == serverID }) else { throw MCPAccountLifecycleError.serverNotFound }
        guard !values[serverIndex].managedReadOnly else { throw MCPAccountLifecycleError.authorizedClientRequired }
        guard let accountIndex = values[serverIndex].accounts.firstIndex(where: { $0.accountKey == accountKey }) else { throw MCPAccountLifecycleError.accountNotFound }
        let expectedRevision = revision
        let oldReference = values[serverIndex].accounts[accountIndex].tokenReference
        if let oldReference, oldReference != tokenReference { try await tokens.remove(reference: oldReference) }
        guard revision == expectedRevision else { throw MCPAccountLifecycleError.concurrentMutation }
        values[serverIndex].accounts[accountIndex].authStatus = status
        values[serverIndex].accounts[accountIndex].tokenReference = tokenReference
        try persist(values); definitions = values
        return values[serverIndex].accounts[accountIndex]
    }

    public func logout(serverID: String, accountKey: String) async throws {
        try await mutateAndClean(serverID: serverID, accountKey: accountKey, remove: false)
    }

    public func removeAccount(serverID: String, accountKey: String) async throws {
        try await mutateAndClean(serverID: serverID, accountKey: accountKey, remove: true)
    }

    private func mutateAndClean(serverID: String, accountKey: String, remove: Bool) async throws {
        var values = try load()
        guard let serverIndex = values.firstIndex(where: { $0.id == serverID }) else { throw MCPAccountLifecycleError.serverNotFound }
        guard let accountIndex = values[serverIndex].accounts.firstIndex(where: { $0.accountKey == accountKey }) else { throw MCPAccountLifecycleError.accountNotFound }
        let expectedRevision = revision
        if values[serverIndex].managedReadOnly {
            guard let managedClient else { throw MCPAccountLifecycleError.authorizedClientRequired }
            if remove { try await managedClient.removeAccount(serverID: serverID, accountKey: accountKey) }
            else { try await managedClient.logoutAccount(serverID: serverID, accountKey: accountKey) }
        }
        let reference = values[serverIndex].accounts[accountIndex].tokenReference
        // Delete the secret before dropping its durable reference. If deletion
        // fails, the account record remains intact so cleanup can be retried.
        if let reference { try await tokens.remove(reference: reference) }
        guard revision == expectedRevision else { throw MCPAccountLifecycleError.concurrentMutation }
        if remove { values[serverIndex].accounts.remove(at: accountIndex) }
        else {
            values[serverIndex].accounts[accountIndex].tokenReference = nil
            values[serverIndex].accounts[accountIndex].authStatus = .signedOut
        }
        try persist(values)
        definitions = values
    }

    private func load() throws -> [MCPServerDefinition] {
        if let definitions { return definitions }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { definitions = []; return [] }
        let data = try Data(contentsOf: fileURL)
        if let legacy = try? JSONDecoder().decode([MCPServerDefinition].self, from: data) { definitions = legacy; return legacy }
        let state = try JSONDecoder().decode(State.self, from: data)
        guard state.schemaVersion == 1 else { throw MCPError.invalidConfiguration("Unsupported MCP account library schema.") }
        definitions = state.definitions
        return state.definitions
    }

    private func persist(_ values: [MCPServerDefinition]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(State(definitions: values)).write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        revision &+= 1
    }

    private struct State: Codable { var schemaVersion = 1; var definitions: [MCPServerDefinition] }

    private static func authorizationReference(in transport: MCPTransportConfiguration) -> String? {
        switch transport {
        case .streamableHTTP(_, let references), .legacySSE(_, let references):
            return references.first { $0.key.caseInsensitiveCompare("Authorization") == .orderedSame }?.value
        case .stdio:
            return nil
        }
    }

    private static func availableDefinitionID(
        base: String, existing: [MCPServerDefinition]
    ) throws -> String {
        let used = Set(existing.map(\.id))
        if !used.contains(base) { return base }
        for suffix in 1...9_999 {
            let tail = "-local-\(suffix)"
            let prefix = String(base.prefix(max(1, 64 - tail.count)))
            let candidate = try MCPServerConfig.normalizeIdentifier(prefix + tail)
            if !used.contains(candidate) { return candidate }
        }
        throw MCPError.invalidConfiguration("Unable to allocate an MCP definition identifier.")
    }
}

public struct MCPOAuthPending: Codable, Hashable, Sendable, Identifiable {
    public var id: String { state }
    public let serverID: String
    public let accountKey: String
    public let state: String
    public let generation: UInt64
    public let authorizationURL: URL
    public let callbackURL: URL
    public let createdAt: Date
}

public enum MCPOAuthError: Error, LocalizedError, Equatable {
    case insecureAuthorizationURL
    case invalidCallbackURL
    case invalidState
    case superseded

    public var errorDescription: String? {
        switch self {
        case .insecureAuthorizationURL: "OAuth authorization URL must use HTTPS."
        case .invalidCallbackURL: "OAuth callback URL is not an approved loopback or HTTPS callback."
        case .invalidState: "OAuth state does not match a pending request."
        case .superseded: "OAuth request was cancelled or superseded."
        }
    }
}

/// Owns OAuth watches in memory. Generation checks prevent a late callback or
/// poll from committing after logout, rename, removal, or a newer auth attempt.
public actor MCPOAuthPendingCoordinator {
    private var generations: [String: UInt64] = [:]
    private var pending: [String: MCPOAuthPending] = [:]

    public init() {}

    public func begin(serverID: String, accountKey: String, authorizationURL: URL, callbackURL: URL, now: Date = .now) throws -> MCPOAuthPending {
        guard authorizationURL.scheme?.lowercased() == "https", authorizationURL.host != nil else { throw MCPOAuthError.insecureAuthorizationURL }
        guard Self.allowedCallback(callbackURL) else { throw MCPOAuthError.invalidCallbackURL }
        let pendingKey = Self.key(serverID, accountKey)
        let generation = (generations[pendingKey] ?? 0) &+ 1
        generations[pendingKey] = generation
        let state = UUID().uuidString
        let value = MCPOAuthPending(serverID: serverID, accountKey: accountKey, state: state, generation: generation, authorizationURL: authorizationURL, callbackURL: callbackURL, createdAt: now)
        pending[pendingKey] = value
        return value
    }

    public func pendingRequest(serverID: String, accountKey: String) -> MCPOAuthPending? { pending[Self.key(serverID, accountKey)] }

    public func validateCompletion(serverID: String, accountKey: String, state: String, callbackURL: URL, generation expected: UInt64) throws {
        let key = Self.key(serverID, accountKey)
        guard let value = pending[key], value.state == state else { throw MCPOAuthError.invalidState }
        guard value.generation == expected, value.generation == generations[key] else { throw MCPOAuthError.superseded }
        guard Self.sameCallback(value.callbackURL, callbackURL) else { throw MCPOAuthError.invalidCallbackURL }
        pending.removeValue(forKey: key)
    }

    public func cancel(serverID: String, accountKey: String) {
        let key = Self.key(serverID, accountKey)
        generations[key] = (generations[key] ?? 0) &+ 1
        pending.removeValue(forKey: key)
    }

    /// Renaming invalidates watches under both names. A callback that races the
    /// rename can therefore never commit to either the old or the new slot.
    public func accountRenamed(serverID: String, oldAccountKey: String, newAccountKey: String) {
        cancel(serverID: serverID, accountKey: oldAccountKey)
        cancel(serverID: serverID, accountKey: newAccountKey)
    }

    public func cancelAll() {
        for key in pending.keys { generations[key] = (generations[key] ?? 0) &+ 1 }
        pending.removeAll()
    }

    private static func key(_ serverID: String, _ accountKey: String) -> String { "\(serverID)\u{0}\(accountKey)" }
    private static func allowedCallback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), url.user == nil, url.password == nil, url.fragment == nil else { return false }
        return (scheme == "http" || scheme == "https")
            && (host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }
    private static func sameCallback(_ expected: URL, _ actual: URL) -> Bool {
        expected.scheme?.lowercased() == actual.scheme?.lowercased()
            && expected.host?.lowercased() == actual.host?.lowercased()
            && expected.port == actual.port
            && expected.path == actual.path
    }
}
