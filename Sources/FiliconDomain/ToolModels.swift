import Foundation

public struct ToolName: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct ToolCallID: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

public struct NormalizedToolCall: Codable, Hashable, Sendable {
    public let id: ToolCallID
    public let name: ToolName
    public let argumentsJSON: Data

    public init(id: ToolCallID, name: ToolName, argumentsJSON: Data) throws {
        guard !id.rawValue.isEmpty, !name.rawValue.isEmpty else { throw ToolCallValidationError.missingIdentity }
        let object = try JSONSerialization.jsonObject(with: argumentsJSON)
        guard object is [String: Any] else { throw ToolCallValidationError.argumentsMustBeObject }
        self.id = id; self.name = name; self.argumentsJSON = argumentsJSON
    }
}

public enum ToolCallValidationError: LocalizedError, Hashable, Sendable {
    case missingIdentity
    case argumentsMustBeObject
    public var errorDescription: String? {
        switch self { case .missingIdentity: "Tool calls require non-empty IDs and names."; case .argumentsMustBeObject: "Tool arguments must be one complete JSON object." }
    }
}

public enum ToolResultContent: Codable, Hashable, Sendable {
    case text(String)
    case resource(uri: String, mimeType: String?)
}

public struct NormalizedToolResult: Codable, Hashable, Sendable {
    public let callID: ToolCallID
    public let content: [ToolResultContent]
    public let isError: Bool
    public init(callID: ToolCallID, content: [ToolResultContent], isError: Bool = false) { self.callID = callID; self.content = content; self.isError = isError }
    public var wireText: String {
        content.map { switch $0 { case .text(let text): text; case .resource(let uri, let mime): "[resource \(mime ?? "unknown")] \(uri)" } }.joined(separator: "\n")
    }
}

public struct ToolDescriptor: Codable, Hashable, Sendable {
    public let name: ToolName
    public let description: String?
    public let inputSchema: Data
    public let parallelSafe: Bool
    public init(name: ToolName, description: String? = nil, inputSchema: Data = Data("{\"type\":\"object\"}".utf8), parallelSafe: Bool = false) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.parallelSafe = parallelSafe
    }
}

public struct ToolContext: Hashable, Sendable {
    public let conversationID: UUID
    public let runID: UUID
    public init(conversationID: UUID, runID: UUID = UUID()) { self.conversationID = conversationID; self.runID = runID }
}

public struct ToolExchange: Hashable, Sendable {
    public let assistantText: String
    public let calls: [NormalizedToolCall]
    public let results: [NormalizedToolResult]
    public init(assistantText: String = "", calls: [NormalizedToolCall], results: [NormalizedToolResult]) { self.assistantText = assistantText; self.calls = calls; self.results = results }
}

public protocol ToolExecutor: Sendable {
    var descriptor: ToolDescriptor { get }
    func execute(_ call: NormalizedToolCall, context: ToolContext) async throws -> NormalizedToolResult
}
