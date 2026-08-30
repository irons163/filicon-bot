import Foundation

public enum MCPTransportConfiguration: Codable, Hashable, Sendable {
    case stdio(executable: String, arguments: [String], environmentReferences: [String: String], workingDirectory: String?)
    case streamableHTTP(url: URL, headerReferences: [String: String])
    case legacySSE(url: URL, headerReferences: [String: String])

    private enum CodingKeys: String, CodingKey { case kind, executable, arguments, environmentReferences, workingDirectory, url, headerReferences }
    private enum Kind: String, Codable { case stdio, streamableHTTP, legacySSE }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .stdio: self = .stdio(executable: try c.decode(String.self, forKey: .executable), arguments: try c.decodeIfPresent([String].self, forKey: .arguments) ?? [], environmentReferences: try c.decodeIfPresent([String: String].self, forKey: .environmentReferences) ?? [:], workingDirectory: try c.decodeIfPresent(String.self, forKey: .workingDirectory))
        case .streamableHTTP: self = .streamableHTTP(url: try c.decode(URL.self, forKey: .url), headerReferences: try c.decodeIfPresent([String: String].self, forKey: .headerReferences) ?? [:])
        case .legacySSE: self = .legacySSE(url: try c.decode(URL.self, forKey: .url), headerReferences: try c.decodeIfPresent([String: String].self, forKey: .headerReferences) ?? [:])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stdio(let executable, let arguments, let refs, let cwd):
            try c.encode(Kind.stdio, forKey: .kind); try c.encode(executable, forKey: .executable); try c.encode(arguments, forKey: .arguments); try c.encode(refs, forKey: .environmentReferences); try c.encodeIfPresent(cwd, forKey: .workingDirectory)
        case .streamableHTTP(let url, let refs):
            try c.encode(Kind.streamableHTTP, forKey: .kind); try c.encode(url, forKey: .url); try c.encode(refs, forKey: .headerReferences)
        case .legacySSE(let url, let refs):
            try c.encode(Kind.legacySSE, forKey: .kind); try c.encode(url, forKey: .url); try c.encode(refs, forKey: .headerReferences)
        }
    }
}

public struct MCPServerConfig: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var identifier: String
    public var displayName: String
    public var transport: MCPTransportConfiguration
    public var enabledTools: Set<String>?
    public var disabledTools: Set<String>
    public var customInstructions: String
    public var enabled: Bool

    public init(id: UUID = UUID(), identifier: String, displayName: String, transport: MCPTransportConfiguration, enabledTools: Set<String>? = nil, disabledTools: Set<String> = [], customInstructions: String = "", enabled: Bool = true) throws {
        self.id = id; self.identifier = try MCPServerConfig.normalizeIdentifier(identifier); self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines); self.transport = transport; self.enabledTools = enabledTools; self.disabledTools = disabledTools; self.customInstructions = customInstructions; self.enabled = enabled
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            identifier: c.decode(String.self, forKey: .identifier),
            displayName: c.decode(String.self, forKey: .displayName),
            transport: c.decode(MCPTransportConfiguration.self, forKey: .transport),
            enabledTools: c.decodeIfPresent(Set<String>.self, forKey: .enabledTools),
            disabledTools: c.decodeIfPresent(Set<String>.self, forKey: .disabledTools) ?? [],
            customInstructions: c.decodeIfPresent(String.self, forKey: .customInstructions) ?? "",
            enabled: c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        )
    }

    public static func normalizeIdentifier(_ raw: String) throws -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "-")
        guard normalized.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil else { throw MCPError.invalidConfiguration("Invalid MCP server identifier.") }
        return normalized
    }

    public func validate() throws {
        guard !displayName.isEmpty else { throw MCPError.invalidConfiguration("MCP display name is required.") }
        switch transport {
        case .stdio(let executable, let arguments, let refs, let workingDirectory):
            guard executable.hasPrefix("/") else { throw MCPError.invalidConfiguration("stdio executable must be an absolute path.") }
            guard arguments.count <= 1_024, arguments.allSatisfy({ $0.utf8.count <= 16_384 && !$0.contains("\0") }) else {
                throw MCPError.invalidConfiguration("stdio arguments exceed their safety limits.")
            }
            if let workingDirectory {
                guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0") else {
                    throw MCPError.invalidConfiguration("stdio working directory must be an absolute path.")
                }
            }
            try Self.validateReferences(refs)
        case .streamableHTTP(let url, let refs), .legacySSE(let url, let refs):
            guard Self.isSecureEndpoint(url) else { throw MCPError.insecureEndpoint }
            try Self.validateReferences(refs)
        }
    }

    public static func validateUnique(_ configs: [MCPServerConfig]) throws {
        var identifiers = Set<String>()
        for config in configs { guard identifiers.insert(config.identifier).inserted else { throw MCPError.duplicateIdentifier(config.identifier) } }
    }

    public static func isSecureEndpoint(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.fragment == nil, let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.scheme?.lowercased() == "https" { return true }
        guard url.scheme?.lowercased() == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private static func validateReferences(_ refs: [String: String]) throws {
        let forbidden = Set(["host", "content-length", "origin", "mcp-protocol-version", "mcp-method", "mcp-name", "mcp-session-id"])
        for (name, reference) in refs {
            guard name.range(of: "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil,
                  !forbidden.contains(name.lowercased()),
                  Self.isSecretReference(reference) else { throw MCPError.invalidConfiguration("Invalid secret reference header/environment entry.") }
        }
    }

    static func isSecretReference(_ value: String) -> Bool {
        value.range(of: "^(keychain|vault|secret):[A-Za-z0-9][A-Za-z0-9._/@:-]{0,511}$", options: .regularExpression) != nil
    }
}
