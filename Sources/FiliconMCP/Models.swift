import Foundation

public enum MCPProtocol {
    public static let current = "2026-07-28"
    public static let legacy = "2025-11-25"
}

public enum MCPError: LocalizedError, Equatable, Sendable {
    case invalidConfiguration(String), duplicateIdentifier(String), insecureEndpoint
    case unavailable(String), timeout, cancelled, processExited(Int32), outputLimitExceeded
    case malformedMessage(String), mismatchedResponse, rpc(code: Int, message: String)
    case unsupportedProtocol(String), http(status: Int), unsafeRedirect, invalidContentType(String)
    case capabilityUnavailable(String), toolDisabled(String), unknownServer(String), unknownTool(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let s): s; case .duplicateIdentifier(let s): "Duplicate MCP identifier: \(s)"; case .insecureEndpoint: "MCP HTTP endpoints require HTTPS or explicit loopback."
        case .unavailable(let s): s; case .timeout: "MCP request timed out."; case .cancelled: "MCP request cancelled."; case .processExited(let c): "MCP process exited (\(c))."; case .outputLimitExceeded: "MCP output exceeded its safety limit."
        case .malformedMessage(let s): "Malformed MCP message: \(s)"; case .mismatchedResponse: "MCP response id did not match the request."; case .rpc(let c, let s): "MCP RPC \(c): \(s)"
        case .unsupportedProtocol(let s): "Unsupported MCP protocol: \(s)"; case .http(let s): "MCP HTTP \(s)."; case .unsafeRedirect: "Unsafe MCP HTTP redirect blocked."; case .invalidContentType(let s): "Unsupported MCP content type: \(s)"
        case .capabilityUnavailable(let s): "MCP capability unavailable: \(s)"; case .toolDisabled(let s): "MCP tool disabled: \(s)"; case .unknownServer(let s): "Unknown MCP server: \(s)"; case .unknownTool(let s): "Unknown MCP tool: \(s)"
        }
    }
}

public struct MCPRPCRequest: Codable, Sendable {
    public let jsonrpc = "2.0"; public let id: Int; public let method: String; public let params: MCPJSONValue?
    enum CodingKeys: String, CodingKey { case jsonrpc, id, method, params }
    public init(id: Int, method: String, params: MCPJSONValue? = nil) { self.id = id; self.method = method; self.params = params }
}
public struct MCPRPCNotification: Codable, Sendable {
    public let jsonrpc: String; public let method: String; public let params: MCPJSONValue?
    public init(method: String, params: MCPJSONValue? = nil) { jsonrpc = "2.0"; self.method = method; self.params = params }
}
public struct MCPRPCErrorObject: Codable, Equatable, Sendable { public let code: Int; public let message: String; public let data: MCPJSONValue?; public init(code: Int, message: String, data: MCPJSONValue? = nil) { self.code = code; self.message = message; self.data = data } }
public struct MCPRPCResponse: Codable, Sendable { public let jsonrpc: String; public let id: Int?; public let result: MCPJSONValue?; public let error: MCPRPCErrorObject?; public init(jsonrpc: String = "2.0", id: Int?, result: MCPJSONValue? = nil, error: MCPRPCErrorObject? = nil) { self.jsonrpc = jsonrpc; self.id = id; self.result = result; self.error = error } }

public struct MCPToolDescriptor: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(serverIdentifier):\(name)" }
    public var readOnlyHint: Bool { (annotations ?? MCPToolAnnotations()).readOnlyHint }
    public var destructiveHint: Bool { (annotations ?? MCPToolAnnotations()).destructiveHint }
    public var idempotentHint: Bool { (annotations ?? MCPToolAnnotations()).idempotentHint }
    public var openWorldHint: Bool { (annotations ?? MCPToolAnnotations()).openWorldHint }
    public let serverIdentifier: String; public let name: String; public let description: String?; public let inputSchema: MCPJSONValue
    public let annotations: MCPToolAnnotations?
    public init(serverIdentifier: String, name: String, description: String?, inputSchema: MCPJSONValue, annotations: MCPToolAnnotations? = nil) {
        self.serverIdentifier = serverIdentifier; self.name = name; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations
    }

    private enum CodingKeys: String, CodingKey { case serverIdentifier, name, description, inputSchema, annotations }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverIdentifier = try container.decode(String.self, forKey: .serverIdentifier)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        inputSchema = try container.decodeIfPresent(MCPJSONValue.self, forKey: .inputSchema) ?? .object([:])
        if container.contains(.annotations) {
            let raw = try? container.decode(MCPJSONValue.self, forKey: .annotations)
            annotations = MCPToolAnnotations(rawValue: raw)
        } else {
            annotations = nil
        }
    }
}

/// Bounded MCP annotation data. Unknown or malformed fields are retained as an
/// integrity signal so policy code can fail closed instead of trusting them.
public struct MCPToolAnnotations: Codable, Hashable, Sendable {
    public static let maximumTitleLength = 256
    public let title: String?
    public let readOnlyHint: Bool
    public let destructiveHint: Bool
    public let idempotentHint: Bool
    public let openWorldHint: Bool
    public let hasUnknownFields: Bool
    public let isMalformed: Bool
    public let hasContradictoryHints: Bool

    public init(
        title: String? = nil,
        readOnlyHint: Bool = false,
        destructiveHint: Bool = true,
        idempotentHint: Bool = false,
        openWorldHint: Bool = true,
        hasUnknownFields: Bool = false,
        isMalformed: Bool = false,
        hasContradictoryHints: Bool? = nil
    ) {
        self.title = title.flatMap {
            let bounded = String($0.prefix(Self.maximumTitleLength))
            return bounded.isEmpty ? nil : bounded
        }
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
        self.hasUnknownFields = hasUnknownFields
        self.isMalformed = isMalformed
        self.hasContradictoryHints = hasContradictoryHints ?? (readOnlyHint && destructiveHint)
    }

    public init(rawValue: MCPJSONValue?) {
        guard let object = rawValue?.objectValue else {
            self.init(isMalformed: true)
            return
        }
        let known = Set(["title", "readOnlyHint", "destructiveHint", "idempotentHint", "openWorldHint"])
        let title: String?
        var malformed = false
        if let rawTitle = object["title"] {
            if let string = rawTitle.stringValue {
                let bounded = String(string.prefix(Self.maximumTitleLength))
                title = bounded.isEmpty ? nil : bounded
            } else {
                title = nil
                malformed = true
            }
        } else { title = nil }
        func hint(_ key: String, default defaultValue: Bool) -> Bool {
            guard let value = object[key] else { return defaultValue }
            guard let boolean = value.boolValue else { malformed = true; return defaultValue }
            return boolean
        }
        self.init(
            title: title,
            readOnlyHint: hint("readOnlyHint", default: false),
            destructiveHint: hint("destructiveHint", default: true),
            idempotentHint: hint("idempotentHint", default: false),
            openWorldHint: hint("openWorldHint", default: true),
            hasUnknownFields: object.keys.contains { !known.contains($0) },
            isMalformed: malformed,
            hasContradictoryHints: object["readOnlyHint"] != nil
                && object["destructiveHint"] != nil
                && object["readOnlyHint"]?.boolValue == true
                && object["destructiveHint"]?.boolValue == true
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title, readOnlyHint, destructiveHint, idempotentHint, openWorldHint
        case hasUnknownFields = "_hasUnknownFields", isMalformed = "_isMalformed", hasContradictoryHints = "_hasContradictoryHints"
    }

    public init(from decoder: Decoder) throws {
        let raw = (try? MCPJSONValue(from: decoder)) ?? .null
        self.init(rawValue: raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(readOnlyHint, forKey: .readOnlyHint)
        try container.encode(destructiveHint, forKey: .destructiveHint)
        try container.encode(idempotentHint, forKey: .idempotentHint)
        try container.encode(openWorldHint, forKey: .openWorldHint)
        if hasUnknownFields { try container.encode(true, forKey: .hasUnknownFields) }
        if isMalformed { try container.encode(true, forKey: .isMalformed) }
    }
}
public struct MCPResourceDescriptor: Codable, Hashable, Sendable { public let uri: String; public let name: String; public let description: String?; public let mimeType: String?; public init(uri: String, name: String, description: String? = nil, mimeType: String? = nil) { self.uri = uri; self.name = name; self.description = description; self.mimeType = mimeType } }
public struct MCPContent: Codable, Hashable, Sendable { public let type: String; public let text: String?; public let data: String?; public let mimeType: String?; public let uri: String?; public init(type: String, text: String? = nil, data: String? = nil, mimeType: String? = nil, uri: String? = nil) { self.type = type; self.text = text; self.data = data; self.mimeType = mimeType; self.uri = uri } }
public struct MCPToolResult: Codable, Hashable, Sendable { public let content: [MCPContent]; public let isError: Bool; public init(content: [MCPContent], isError: Bool = false) { self.content = content; self.isError = isError } }
public struct MCPResourceResult: Codable, Hashable, Sendable { public let contents: [MCPContent]; public init(contents: [MCPContent]) { self.contents = contents } }
public enum MCPServerStatus: Equatable, Sendable { case disabled, connecting, connected, needsAuth, error(String) }
public struct MCPCatalogSnapshot: Sendable { public let revision: UInt64; public let tools: [MCPToolDescriptor]; public let statuses: [String: MCPServerStatus]; public init(revision: UInt64, tools: [MCPToolDescriptor], statuses: [String: MCPServerStatus]) { self.revision = revision; self.tools = tools; self.statuses = statuses } }
