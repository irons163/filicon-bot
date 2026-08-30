import Foundation

public protocol MCPTransport: Sendable {
    func request(_ request: MCPRPCRequest, timeout: Duration) async throws -> MCPRPCResponse
    func notify(_ notification: MCPRPCNotification) async throws
    func close() async
}

func encodeLine<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    guard !data.contains(0x0A), !data.contains(0x0D) else { throw MCPError.malformedMessage("embedded newline") }
    return data
}

func boundedSanitize(_ input: String?, limit: Int = 2_000) -> String? {
    guard let input else { return nil }
    let cleaned = input.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(limit))
}
