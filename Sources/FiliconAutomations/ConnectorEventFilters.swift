import Foundation

public enum ConnectorEventFilterError: String, LocalizedError, Sendable {
    case invalidConnector = "Enter the exact UUID of an existing connector. Names and wildcard connectors are not supported."
    case invalidKind = "Enter an event kind of 1 to 128 characters, with no control characters or surrounding whitespace."
    case invalidFilters = "Filters must be a JSON object of at most 16 KiB, without duplicate keys. Maximum depth is 16 and maximum values is 4,096. Numbers allow up to 256 characters and exponent magnitude 10,000."
    public var errorDescription: String? { rawValue }
}

extension AutomationEventTrigger {
    /// Used at both write and execution boundaries: legacy malformed filters
    /// must never acquire match-all authority when loaded from persistence.
    public func validateFilters() throws {
        try validateKind()
        _ = try ConnectorFilterJSON.object(filtersJSON, limit: 16_384)
    }

    private func validateKind() throws {
        guard (1...128).contains(kind.count), kind == kind.trimmingCharacters(in: .whitespacesAndNewlines),
              !kind.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ConnectorEventFilterError.invalidKind
        }
    }

    func matches(_ event: AutomationEvent) -> Bool {
        guard connectorID == event.connectorID, kind.utf8.elementsEqual(event.kind.utf8),
              (try? validateKind()) != nil,
              let filters = try? ConnectorFilterJSON.object(filtersJSON, limit: 16_384),
              let payload = try? ConnectorFilterJSON.object(event.payloadJSON, limit: 1_048_576) else { return false }
        // Top-level subset, but each selected value has exact structural and
        // typed equality. Object order is irrelevant; array order is not.
        return filters.allSatisfy { payload[$0.key] == $0.value }
    }
}

/// A bounded, duplicate-rejecting JSON reader for execution conditions only.
/// Foundation's dictionary decoding discards duplicate keys, and Double/NSNumber
/// comparison can round distinct identifiers or equate booleans and numbers.
/// Keep decimal coefficients/exponents as text/integers instead of floating point.
private struct ConnectorFilterJSON {
    indirect enum Value: Equatable {
        case object([Data: Value]), array([Value]), string(Data), number(Number), bool(Bool), null
    }
    struct Number: Equatable {
        let coefficient: String
        let exponent: Int
    }
    private let bytes: [UInt8]
    private var cursor = 0
    private var values = 0
    private var invalid: ConnectorEventFilterError { .invalidFilters }

    static func object(_ data: Data, limit: Int) throws -> [Data: Value] {
        guard !data.isEmpty, data.count <= limit else { throw ConnectorEventFilterError.invalidFilters }
        var parser = Self(bytes: Array(data))
        let value = try parser.value(depth: 0)
        parser.whitespace()
        guard parser.cursor == parser.bytes.count, case .object(let object) = value else {
            throw ConnectorEventFilterError.invalidFilters
        }
        return object
    }

    private mutating func whitespace() {
        while cursor < bytes.count, [9, 10, 13, 32].contains(bytes[cursor]) { cursor += 1 }
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        whitespace()
        guard cursor < bytes.count, bytes[cursor] == byte else { return false }
        cursor += 1
        return true
    }
    private mutating func value(depth: Int) throws -> Value {
        whitespace(); values += 1
        guard depth <= 16, values <= 4096, cursor < bytes.count else { throw invalid }
        switch bytes[cursor] {
        case 123: // {
            cursor += 1
            var result: [Data: Value] = [:]
            if consume(125) { return .object(result) }
            repeat {
                whitespace()
                let key = try string()
                guard result[key] == nil, consume(58) else { throw invalid }
                result[key] = try value(depth: depth + 1)
                if consume(125) { return .object(result) }
                guard consume(44) else { throw invalid }
            } while true
        case 91: // [
            cursor += 1
            var result: [Value] = []
            if consume(93) { return .array(result) }
            repeat {
                result.append(try value(depth: depth + 1))
                if consume(93) { return .array(result) }
                guard consume(44) else { throw invalid }
            } while true
        case 34: return .string(try string())
        case 116: try literal("true"); return .bool(true)
        case 102: try literal("false"); return .bool(false)
        case 110: try literal("null"); return .null
        default: return .number(try number())
        }
    }
    private mutating func literal(_ text: String) throws {
        let token = Array(text.utf8)
        guard cursor + token.count <= bytes.count,
              bytes[cursor..<(cursor + token.count)].elementsEqual(token) else { throw invalid }
        cursor += token.count
    }
    private mutating func string() throws -> Data {
        guard cursor < bytes.count, bytes[cursor] == 34 else { throw invalid }
        let start = cursor; cursor += 1
        while cursor < bytes.count {
            let byte = bytes[cursor]; cursor += 1
            if byte == 92 { cursor += 1 } // Skip an escaped byte; decoder validates the escape.
            else if byte == 34 {
                guard let string = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<cursor])) else { throw invalid }
                // Decode escapes, but do not canonically normalize distinct
                // Unicode key/value spellings through Swift String equality.
                return Data(string.utf8)
            }
        }
        throw invalid
    }
    private mutating func number() throws -> Number {
        let start = cursor
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) || [43, 45, 46, 69, 101].contains(bytes[cursor]) {
            cursor += 1
        }
        guard (1...256).contains(cursor - start) else { throw invalid }
        let text = String(decoding: bytes[start..<cursor], as: UTF8.self)
        let pattern = #"-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?"#
        guard let range = text.range(of: pattern, options: .regularExpression), range == text.startIndex..<text.endIndex else { throw invalid }
        let parts = text.lowercased().split(separator: "e")
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0, (-10_000...10_000).contains(exponent) else { throw invalid }
        let negative = parts[0].first == "-"
        let mantissa = negative ? parts[0].dropFirst() : parts[0]
        let decimal = mantissa.split(separator: ".")
        var digits = String(decimal.joined()).drop(while: { $0 == "0" })
        if digits.isEmpty { return Number(coefficient: "0", exponent: 0) }
        var power = exponent - (decimal.count == 2 ? decimal[1].count : 0)
        while digits.last == "0" { digits = digits.dropLast(); power += 1 }
        return Number(coefficient: (negative ? "-" : "") + digits, exponent: power)
    }
}
