import Foundation

public protocol MCPConnection: Sendable {
    func connect() async throws
    func listTools() async throws -> [MCPToolDescriptor]
    func callTool(name: String, arguments: MCPJSONValue) async throws -> MCPToolResult
    func listResources() async throws -> [MCPResourceDescriptor]
    func readResource(uri: String) async throws -> MCPResourceResult
    func close() async
}

public actor MCPClient: MCPConnection {
    public enum Mode: Sendable { case modern, legacy }
    private let serverIdentifier: String
    private let transport: any MCPTransport
    private var nextID = 1
    private(set) public var mode: Mode?
    private var connected = false

    public init(serverIdentifier: String, transport: any MCPTransport) { self.serverIdentifier = serverIdentifier; self.transport = transport }

    public func connect() async throws {
        guard !connected else { return }
        do {
            let response = try await rawRequest(method: "server/discover", params: modernMeta(), timeout: .seconds(3))
            if let error = response.error {
                if let versions = error.data?.objectValue?["supportedVersions"]?.arrayValue?.compactMap(\.stringValue), !versions.contains(MCPProtocol.current) { throw MCPError.unsupportedProtocol(versions.joined(separator: ", ")) }
                throw MCPError.rpc(code: error.code, message: error.message)
            }
            guard response.result?.objectValue?["supportedVersions"]?.arrayValue?.compactMap(\.stringValue).contains(MCPProtocol.current) == true else { throw MCPError.unsupportedProtocol("server/discover did not advertise \(MCPProtocol.current)") }
            mode = .modern; connected = true
        } catch let error as MCPError {
            if case .unsupportedProtocol = error { throw error }
            try await legacyInitialize()
        } catch { try await legacyInitialize() }
    }

    private func legacyInitialize() async throws {
        let params: MCPJSONValue = .object([
            "protocolVersion": .string(MCPProtocol.legacy), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("Filicon"), "version": .string("1")])
        ])
        let response = try await rawRequest(method: "initialize", params: params, timeout: .seconds(10))
        _ = try unwrap(response)
        guard response.result?.objectValue?["protocolVersion"]?.stringValue == MCPProtocol.legacy else { throw MCPError.unsupportedProtocol(response.result?.objectValue?["protocolVersion"]?.stringValue ?? "missing") }
        try await transport.notify(MCPRPCNotification(method: "notifications/initialized"))
        mode = .legacy; connected = true
    }

    public func listTools() async throws -> [MCPToolDescriptor] {
        try await ensureConnected(); var cursor: String?, result: [MCPToolDescriptor] = []
        for _ in 0..<100 {
            var p: [String: MCPJSONValue] = [:]; if let cursor { p["cursor"] = .string(cursor) }
            let value = try await call(method: "tools/list", params: .object(p))
            guard let object = value.objectValue, let items = object["tools"]?.arrayValue else { throw MCPError.malformedMessage("tools/list result") }
            for item in items {
                guard let o = item.objectValue, let name = o["name"]?.stringValue, !name.isEmpty else { throw MCPError.malformedMessage("tool descriptor") }
                let annotations = o["annotations"].map { MCPToolAnnotations(rawValue: $0) }
                result.append(MCPToolDescriptor(serverIdentifier: serverIdentifier, name: String(name.prefix(256)), description: boundedSanitize(o["description"]?.stringValue), inputSchema: o["inputSchema"] ?? .object([:]), annotations: annotations))
            }
            cursor = object["nextCursor"]?.stringValue; if cursor == nil { return result }
        }
        throw MCPError.outputLimitExceeded
    }

    public func callTool(name: String, arguments: MCPJSONValue) async throws -> MCPToolResult {
        let value = try await call(method: "tools/call", params: .object(["name": .string(name), "arguments": arguments]))
        guard let o = value.objectValue, let items = o["content"]?.arrayValue else { throw MCPError.malformedMessage("tools/call result") }
        let content = try items.prefix(1_000).map(Self.content)
        let encoded = try JSONEncoder().encode(content); guard encoded.count <= 4 * 1_024 * 1_024 else { throw MCPError.outputLimitExceeded }
        return MCPToolResult(content: content, isError: o["isError"]?.boolValue ?? false)
    }

    public func listResources() async throws -> [MCPResourceDescriptor] {
        try await ensureConnected(); var cursor: String?, result: [MCPResourceDescriptor] = []
        for _ in 0..<100 {
            var p: [String: MCPJSONValue] = [:]; if let cursor { p["cursor"] = .string(cursor) }
            let value = try await call(method: "resources/list", params: .object(p))
            guard let o = value.objectValue, let items = o["resources"]?.arrayValue else { throw MCPError.malformedMessage("resources/list result") }
            for item in items { guard let x = item.objectValue, let uri = x["uri"]?.stringValue, let name = x["name"]?.stringValue else { throw MCPError.malformedMessage("resource descriptor") }; result.append(.init(uri: uri, name: String(name.prefix(512)), description: boundedSanitize(x["description"]?.stringValue), mimeType: x["mimeType"]?.stringValue)) }
            cursor = o["nextCursor"]?.stringValue; if cursor == nil { return result }
        }
        throw MCPError.outputLimitExceeded
    }

    public func readResource(uri: String) async throws -> MCPResourceResult {
        let value = try await call(method: "resources/read", params: .object(["uri": .string(uri)]))
        guard let items = value.objectValue?["contents"]?.arrayValue else { throw MCPError.malformedMessage("resources/read result") }
        return MCPResourceResult(contents: try items.prefix(1_000).map(Self.content))
    }

    public func close() async { connected = false; await transport.close() }

    private func ensureConnected() async throws { if !connected { try await connect() } }
    private func call(method: String, params: MCPJSONValue) async throws -> MCPJSONValue {
        try await ensureConnected()
        let merged: MCPJSONValue
        if mode == .modern { var o = params.objectValue ?? [:]; for (k, v) in modernMeta().objectValue ?? [:] { o[k] = v }; merged = .object(o) } else { merged = params }
        return try unwrap(await rawRequest(method: method, params: merged, timeout: .seconds(30)))
    }
    private func rawRequest(method: String, params: MCPJSONValue?, timeout: Duration) async throws -> MCPRPCResponse {
        let id = nextID; nextID += 1
        return try await transport.request(MCPRPCRequest(id: id, method: method, params: params), timeout: timeout)
    }
    private func unwrap(_ response: MCPRPCResponse) throws -> MCPJSONValue { if let e = response.error { throw MCPError.rpc(code: e.code, message: String(e.message.prefix(2_000))) }; guard let result = response.result else { throw MCPError.malformedMessage("missing result") }; return result }
    private func modernMeta() -> MCPJSONValue { .object(["_meta": .object([
        "io.modelcontextprotocol/protocolVersion": .string(MCPProtocol.current),
        "io.modelcontextprotocol/clientInfo": .object(["name": .string("Filicon"), "version": .string("1")]),
        "io.modelcontextprotocol/clientCapabilities": .object([:])
    ])]) }
    private static func content(_ value: MCPJSONValue) throws -> MCPContent {
        guard let o = value.objectValue, let type = o["type"]?.stringValue else { throw MCPError.malformedMessage("content") }
        return MCPContent(type: type, text: o["text"]?.stringValue.map { String($0.prefix(1_000_000)) }, data: o["blob"]?.stringValue ?? o["data"]?.stringValue, mimeType: o["mimeType"]?.stringValue, uri: o["uri"]?.stringValue)
    }
}
