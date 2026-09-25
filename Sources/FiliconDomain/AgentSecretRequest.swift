import Foundation

/// Public request metadata only. The credential itself must never be added to
/// this type, a chat message, tool arguments, or a model-visible receipt.
public struct AgentSecretRequest: Codable, Hashable, Sendable {
    public let label: String
    public let description: String?
    public let connector: String
    public let field: String

    private init(label: String, description: String?, connector: String, field: String) {
        self.label = label; self.description = description; self.connector = connector; self.field = field
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    public init(from decoder: any Decoder) throws {
        do {
            let container = try decoder.container(keyedBy: Key.self)
            var values: [String: String] = [:]
            for key in container.allKeys {
                values[key.stringValue] = try container.decode(String.self, forKey: key)
            }
            self = try Self.parse(JSONEncoder().encode(values))
        } catch {
            throw AgentSecretRequestError.invalid
        }
    }

    public static func parse(_ data: Data) throws -> Self {
        // Accept only the reference's `secret` object, not a supplied value,
        // account, keychain reference, destination path or agent identity.
        do {
            guard data.count <= 16_384,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["label", "description", "connector", "field"]),
                  let rawLabel = object["label"] as? String,
                  let rawConnector = object["connector"] as? String,
                  let rawField = object["field"] as? String,
                  object["description"] == nil || object["description"] is String else {
                throw AgentSecretRequestError.invalid
            }
            let label = String(rawLabel.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
            let description = (object["description"] as? String).map {
                String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400))
            }.flatMap { $0.isEmpty ? nil : $0 }
            let connector = rawConnector.trimmingCharacters(in: .whitespacesAndNewlines)
            let field = rawField.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, safeText(label), description.map(safeText) ?? true,
                  safeIdentifier(connector), safeIdentifier(field) else { throw AgentSecretRequestError.invalid }
            return .init(label: label, description: description, connector: connector, field: field)
        } catch {
            // Never forward decoder errors that could echo user/model input.
            throw AgentSecretRequestError.invalid
        }
    }

    private static func safeIdentifier(_ value: String) -> Bool {
        (1...64).contains(value.utf8.count)
            && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
            && value.utf8.first.map { (97...122).contains($0) } == true
    }

    private static func safeText(_ value: String) -> Bool {
        !value.unicodeScalars.contains {
            (CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0.value != 0x200D)
                || (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value)
        }
    }
}

public enum AgentSecretRequestError: Error, Equatable, Sendable {
    case invalid, unsupported, unavailable, ambiguous, stale
}
