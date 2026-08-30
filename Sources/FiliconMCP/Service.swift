import Foundation

public protocol MCPConnectionFactory: Sendable {
    func connection(for config: MCPServerConfig) async throws -> any MCPConnection
}

public struct DefaultMCPConnectionFactory: MCPConnectionFactory {
    private let resolver: MCPSecretResolver

    public init(secretResolver: @escaping MCPSecretResolver) {
        resolver = secretResolver
    }

    public func connection(for config: MCPServerConfig) async throws -> any MCPConnection {
        let transport: any MCPTransport
        switch config.transport {
        case .stdio(let executable, let arguments, let references, let workingDirectory):
            transport = MCPStdioTransport(
                executable: executable,
                arguments: arguments,
                environmentReferences: references,
                workingDirectory: workingDirectory,
                secretResolver: resolver
            )
        case .streamableHTTP(let url, let references):
            transport = try MCPHTTPTransport(
                endpoint: url,
                headerReferences: references,
                secretResolver: resolver
            )
        case .legacySSE(let url, let references):
            transport = try MCPHTTPTransport(
                endpoint: url,
                headerReferences: references,
                legacy: true,
                secretResolver: resolver
            )
        }
        return MCPClient(serverIdentifier: config.identifier, transport: transport)
    }
}

public actor MCPService {
    private struct Lease {
        var connection: any MCPConnection
        var tools: [MCPToolDescriptor]
    }

    private let factory: any MCPConnectionFactory
    private var configs: [String: MCPServerConfig] = [:]
    private var leases: [String: Lease] = [:]
    private var statuses: [String: MCPServerStatus] = [:]
    private var revision: UInt64 = 0

    public init(factory: any MCPConnectionFactory) {
        self.factory = factory
    }

    public func replaceConfigs(_ values: [MCPServerConfig]) async throws {
        try MCPServerConfig.validateUnique(values)
        let next = Dictionary(uniqueKeysWithValues: values.map { ($0.identifier, $0) })
        let changed = Set(configs.keys).union(next.keys).filter { configs[$0] != next[$0] }
        for identifier in changed { await disconnect(identifier: identifier) }
        configs = next
        for config in values {
            statuses[config.identifier] = config.enabled ? .connecting : .disabled
        }
        for removed in statuses.keys where next[removed] == nil { statuses.removeValue(forKey: removed) }
        revision &+= 1
    }

    public func configsSnapshot() -> [MCPServerConfig] {
        configs.values.sorted { $0.identifier < $1.identifier }
    }

    public func refresh() async {
        let identifiers = configs.keys.sorted()
        for identifier in identifiers {
            guard configs[identifier]?.enabled == true else {
                statuses[identifier] = .disabled
                continue
            }
            do { _ = try await connectAndDiscover(identifier: identifier, force: true) }
            catch { statuses[identifier] = .error(Self.sanitizedError(error)) }
        }
        revision &+= 1
    }

    public func catalog() async -> MCPCatalogSnapshot {
        for identifier in configs.keys.sorted() where configs[identifier]?.enabled == true && leases[identifier] == nil {
            do { _ = try await connectAndDiscover(identifier: identifier, force: false) }
            catch { statuses[identifier] = .error(Self.sanitizedError(error)) }
        }
        let tools = leases.values.flatMap(\.tools).sorted {
            $0.serverIdentifier == $1.serverIdentifier
                ? $0.name < $1.name
                : $0.serverIdentifier < $1.serverIdentifier
        }
        return MCPCatalogSnapshot(revision: revision, tools: tools, statuses: statuses)
    }

    public func callTool(server identifier: String, name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        guard let config = configs[identifier] else { throw MCPError.unknownServer(identifier) }
        guard config.enabled else { throw MCPError.unavailable("MCP server is disabled.") }
        let lease = try await connectAndDiscover(identifier: identifier, force: false)
        guard lease.tools.contains(where: { $0.name == name }) else { throw MCPError.unknownTool(name) }
        if config.disabledTools.contains(name) || config.enabledTools.map({ !$0.contains(name) }) == true {
            throw MCPError.toolDisabled(name)
        }
        do { return try await lease.connection.callTool(name: name, arguments: arguments) }
        catch {
            if Self.isConnectionFailure(error) { await disconnect(identifier: identifier) }
            throw error
        }
    }

    public func listResources(server identifier: String) async throws -> [MCPResourceDescriptor] {
        try await connectAndDiscover(identifier: identifier, force: false).connection.listResources()
    }

    public func readResource(server identifier: String, uri: String) async throws -> MCPResourceResult {
        try await connectAndDiscover(identifier: identifier, force: false).connection.readResource(uri: uri)
    }

    public func disconnectAll() async {
        for identifier in leases.keys { await disconnect(identifier: identifier) }
    }

    private func connectAndDiscover(identifier: String, force: Bool) async throws -> Lease {
        guard let config = configs[identifier] else { throw MCPError.unknownServer(identifier) }
        guard config.enabled else { throw MCPError.unavailable("MCP server is disabled.") }
        if !force, let lease = leases[identifier] { return lease }
        if force { await disconnect(identifier: identifier) }
        statuses[identifier] = .connecting
        let connection = try await factory.connection(for: config)
        do {
            try await connection.connect()
            let discovered = try await connection.listTools()
            let tools = discovered
                .filter { descriptor in
                    !config.disabledTools.contains(descriptor.name)
                        && config.enabledTools.map { $0.contains(descriptor.name) } != false
                }
                .map { descriptor in
                    MCPToolDescriptor(
                        serverIdentifier: identifier,
                        name: String(descriptor.name.prefix(256)),
                        description: Self.toolDescription(
                            base: descriptor.description,
                            customInstructions: config.customInstructions
                        ),
                        inputSchema: descriptor.inputSchema,
                        annotations: descriptor.annotations
                    )
                }
            let lease = Lease(connection: connection, tools: tools)
            leases[identifier] = lease
            statuses[identifier] = .connected
            revision &+= 1
            return lease
        } catch {
            await connection.close()
            statuses[identifier] = .error(Self.sanitizedError(error))
            revision &+= 1
            throw error
        }
    }

    private func disconnect(identifier: String) async {
        if let lease = leases.removeValue(forKey: identifier) { await lease.connection.close() }
        if configs[identifier]?.enabled == false { statuses[identifier] = .disabled }
    }

    private static func sanitizedError(_ error: Error) -> String {
        String(error.localizedDescription
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .prefix(1_000))
    }

    private static func toolDescription(base: String?, customInstructions: String) -> String? {
        let instructions = boundedSanitize(customInstructions)
        let description = boundedSanitize(base)
        let parts = [instructions, description].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil
        }
        return parts.isEmpty ? nil : String(parts.joined(separator: "\n\n").prefix(16_384))
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        guard let error = error as? MCPError else { return true }
        switch error {
        case .rpc, .toolDisabled, .unknownTool, .capabilityUnavailable: return false
        default: return true
        }
    }
}
