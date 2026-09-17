import Foundation
import FiliconDomain
import FiliconProviderKit

public enum ToolLoopError: LocalizedError, Equatable, Sendable {
    case duplicateCallID(ToolCallID)
    case unknownTool(ToolName)
    case malformedArguments(ToolCallID)
    case schemaMismatch(callID: ToolCallID, detail: String)
    case resultCallIDMismatch(expected: ToolCallID, actual: ToolCallID)
    case toolStepLimit(maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .duplicateCallID(let id): "Duplicate tool call ID: \(id.rawValue)."
        case .unknownTool(let name): "Unknown tool: \(name.rawValue)."
        case .malformedArguments(let id): "Tool \(id.rawValue) did not provide one complete JSON object."
        case .schemaMismatch(let id, let detail): "Tool \(id.rawValue) arguments failed schema validation: \(detail)"
        case .resultCallIDMismatch(let expected, let actual): "Tool result ID \(actual.rawValue) does not match \(expected.rawValue)."
        case .toolStepLimit(let maximum): "Tool loop exceeded its \(maximum)-step limit."
        }
    }
}

public actor ToolCatalog {
    private var executors: [ToolName: any ToolExecutor]
    public init(_ executors: [any ToolExecutor] = []) { self.executors = Dictionary(uniqueKeysWithValues: executors.map { ($0.descriptor.name, $0) }) }
    public func register(_ executor: any ToolExecutor) { executors[executor.descriptor.name] = executor }
    public func replace(with values: [any ToolExecutor]) { executors = Dictionary(uniqueKeysWithValues: values.map { ($0.descriptor.name, $0) }) }
    public func snapshot(for context: ToolContext) -> ToolCatalogSnapshot { ToolCatalogSnapshot(executors: executors) }
}

public struct ToolCatalogSnapshot: Sendable {
    fileprivate let executors: [ToolName: any ToolExecutor]
    public var descriptors: [ToolDescriptor] { executors.values.map(\.descriptor).sorted { $0.name.rawValue < $1.name.rawValue } }
    fileprivate func executor(named name: ToolName) -> (any ToolExecutor)? { executors[name] }
}

public protocol ToolLoopTransactionHook: Sendable {
    func persist(step: Int, calls: [NormalizedToolCall], results: [NormalizedToolResult], context: ToolContext) async throws
}

public struct NoopToolLoopTransactionHook: ToolLoopTransactionHook {
    public init() {}
    public func persist(step: Int, calls: [NormalizedToolCall], results: [NormalizedToolResult], context: ToolContext) async throws {}
}

public actor ToolLoop {
    public static let maximumSteps = 8
    private let provider: any AIProvider
    private let catalog: ToolCatalog
    private let transactionHook: any ToolLoopTransactionHook

    public init(provider: any AIProvider, catalog: ToolCatalog, transactionHook: any ToolLoopTransactionHook = NoopToolLoopTransactionHook()) {
        self.provider = provider; self.catalog = catalog; self.transactionHook = transactionHook
    }

    public func run(_ request: InferenceRequest, context: ToolContext) -> AsyncThrowingStream<InferenceEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do { try await execute(request, context: context, continuation: continuation); continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func execute(_ initial: InferenceRequest, context: ToolContext, continuation: AsyncThrowingStream<InferenceEvent, Error>.Continuation) async throws {
        let snapshot = await catalog.snapshot(for: context)
        var exchanges = initial.toolExchanges
        var seen = Set<ToolCallID>()

        for step in 1...Self.maximumSteps {
            try Task.checkCancellation()
            let request = InferenceRequest(conversationID: initial.conversationID, modelID: initial.modelID, messages: initial.messages, tools: snapshot.descriptors, toolExchanges: exchanges, attachmentsByMessageID: initial.attachmentsByMessageID, reasoningEffort: initial.reasoningEffort)
            var calls: [NormalizedToolCall] = []
            var assistantText = ""
            var pending = Set<ToolCallID>()
            for try await event in provider.stream(request) {
                try Task.checkCancellation()
                // Only our executors may produce results. A provider event is not
                // evidence that an operation actually ran on the user's machine.
                if case .toolResult = event { throw ProviderError.invalidResponse }
                continuation.yield(event)
                if case .toolCallStarted(let id, _) = event {
                    guard !seen.contains(id), pending.insert(id).inserted else { throw ToolLoopError.duplicateCallID(id) }
                }
                if case .toolCallArgumentsDelta(let id, _) = event, !pending.contains(id) { throw ToolLoopError.malformedArguments(id) }
                if case .toolCallCompleted(let call) = event {
                    guard pending.remove(call.id) != nil else {
                        if seen.contains(call.id) { throw ToolLoopError.duplicateCallID(call.id) }
                        throw ToolLoopError.malformedArguments(call.id)
                    }
                    guard seen.insert(call.id).inserted else { throw ToolLoopError.duplicateCallID(call.id) }
                    calls.append(call)
                }
                if case .textDelta(let text) = event { assistantText += text }
            }
            if let unfinished = pending.first { throw ToolLoopError.malformedArguments(unfinished) }
            guard !calls.isEmpty else { return }
            guard step < Self.maximumSteps else { throw ToolLoopError.toolStepLimit(maximum: Self.maximumSteps) }

            let work = try calls.map { call -> (NormalizedToolCall, any ToolExecutor) in
                guard let executor = snapshot.executor(named: call.name) else { throw ToolLoopError.unknownTool(call.name) }
                try validate(arguments: call.argumentsJSON, schema: executor.descriptor.inputSchema, callID: call.id)
                return (call, executor)
            }
            let allParallelSafe = work.allSatisfy { $0.1.descriptor.parallelSafe }
            let results = try await (allParallelSafe ? executeParallel(work, context: context) : executeSequential(work, context: context))
            try Task.checkCancellation()
            try await transactionHook.persist(step: step, calls: calls, results: results, context: context)
            for result in results { continuation.yield(.toolResult(result)) }
            exchanges.append(ToolExchange(assistantText: assistantText, calls: calls, results: results))
        }
    }

    private func executeSequential(_ work: [(NormalizedToolCall, any ToolExecutor)], context: ToolContext) async throws -> [NormalizedToolResult] {
        var results: [NormalizedToolResult] = []
        for (call, executor) in work {
            try Task.checkCancellation()
            let result = try await executor.execute(call, context: context)
            guard result.callID == call.id else { throw ToolLoopError.resultCallIDMismatch(expected: call.id, actual: result.callID) }
            results.append(result)
        }
        return results
    }

    private func executeParallel(_ work: [(NormalizedToolCall, any ToolExecutor)], context: ToolContext) async throws -> [NormalizedToolResult] {
        try await withThrowingTaskGroup(of: (Int, NormalizedToolResult).self) { group in
            for (index, pair) in work.enumerated() {
                group.addTask {
                    let result = try await pair.1.execute(pair.0, context: context)
                    guard result.callID == pair.0.id else { throw ToolLoopError.resultCallIDMismatch(expected: pair.0.id, actual: result.callID) }
                    return (index, result)
                }
            }
            var ordered: [(Int, NormalizedToolResult)] = []
            for try await value in group { ordered.append(value) }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func validate(arguments data: Data, schema schemaData: Data, callID: ToolCallID) throws {
        let arguments: [String: Any]
        do { guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ToolLoopError.malformedArguments(callID) }; arguments = value }
        catch is ToolLoopError { throw ToolLoopError.malformedArguments(callID) }
        catch { throw ToolLoopError.malformedArguments(callID) }
        guard let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else { throw ToolLoopError.schemaMismatch(callID: callID, detail: "descriptor schema is invalid") }
        if let type = schema["type"] as? String, type != "object" { throw ToolLoopError.schemaMismatch(callID: callID, detail: "root schema must be object") }
        let required = schema["required"] as? [String] ?? []
        for key in required where arguments[key] == nil { throw ToolLoopError.schemaMismatch(callID: callID, detail: "missing required property '\(key)'") }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        if schema["additionalProperties"] as? Bool == false, let unknown = arguments.keys.first(where: { properties[$0] == nil }) { throw ToolLoopError.schemaMismatch(callID: callID, detail: "unknown property '\(unknown)'") }
        for (key, value) in arguments {
            guard let property = properties[key] as? [String: Any], let type = property["type"] as? String else { continue }
            guard matches(value, type: type) else { throw ToolLoopError.schemaMismatch(callID: callID, detail: "property '\(key)' must be \(type)") }
        }
    }

    private func matches(_ value: Any, type: String) -> Bool {
        switch type {
        case "string": return value is String
        case "boolean": return value is Bool
        case "integer": return (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue } ?? false
        case "number": return (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
        case "object": return value is [String: Any]
        case "array": return value is [Any]
        case "null": return value is NSNull
        default: return false
        }
    }
}
