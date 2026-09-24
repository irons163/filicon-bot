import Foundation
import FiliconChannels

/// Public request metadata only. The credential itself must never be added to
/// this type, a chat message, tool arguments, or a model-visible receipt.
public struct AgentSecretRequest: Encodable, Hashable, Sendable {
    public let label: String
    public let description: String?
    public let connector: String
    public let field: String

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

/// An existing connector destination selected from host-owned connection data.
/// This is neither Codable nor model-constructible: the model cannot supply a
/// Keychain key. It deliberately does not perform writes or claim connection
/// success; the future secure-input submit path must revalidate at commit time.
public struct AgentSecretRequestDestination: Sendable, Equatable {
    public let request: AgentSecretRequest
    public let accountID: String
    public let agentID: UUID
    public let conversationID: UUID
    public let connectionID: UUID
    public let displayName: String
    private let connection: ChannelConnection

    // Only a successfully host-resolved destination can reach this mapping.
    var credentialReference: CredentialRef {
        let identifier = String(connection.secretReference.dropFirst("keychain://channels/".count))
        return CredentialRef(providerID: .init(rawValue: "channel.\(identifier)"))
    }

    public static func resolve(_ request: AgentSecretRequest, accountID: String, agentID: UUID,
                               conversationID: UUID, connections: [ChannelConnection]) throws -> Self {
        // These are Filicon's implemented token-based messaging connectors.
        // Other platforms/fields need real storage and adapter support first.
        guard ["slack", "discord"].contains(request.connector), request.field == "token" else {
            throw AgentSecretRequestError.unsupported
        }
        guard !accountID.isEmpty else { throw AgentSecretRequestError.unavailable }
        let candidates = connections.filter {
            $0.connectorID == request.connector && $0.agentID == agentID
                && ($0.accountID ?? "local") == accountID
        }
        guard candidates.count <= 1 else { throw AgentSecretRequestError.ambiguous }
        guard let connection = candidates.first, connection.enabled,
              connection.authKind == nil || connection.authKind == .botToken else {
            throw AgentSecretRequestError.unavailable
        }
        let prefix = "keychain://channels/"
        guard connection.secretReference.hasPrefix(prefix),
              UUID(uuidString: String(connection.secretReference.dropFirst(prefix.count))) != nil else {
            throw AgentSecretRequestError.unavailable
        }
        return .init(request: request, accountID: accountID, agentID: agentID,
            conversationID: conversationID, connectionID: connection.id,
            displayName: connection.displayName, connection: connection)
    }

    /// Re-resolve the exact target after the user sees it. Renames, owner/account
    /// changes, replacement credentials, duplicate destinations and disconnects
    /// must not silently redirect the user's secret.
    public func validate(accountID: String, agentID: UUID, conversationID: UUID,
                         connections: [ChannelConnection]) throws {
        guard self.accountID == accountID, self.agentID == agentID,
              self.conversationID == conversationID,
              let current = try? Self.resolve(request, accountID: accountID, agentID: agentID,
                  conversationID: conversationID, connections: connections) else {
            throw AgentSecretRequestError.stale
        }
        // Normal inbound polling does not change who receives the credential.
        var expected = connection
        expected.cursor = current.connection.cursor
        expected.lastActivityAt = current.connection.lastActivityAt
        guard current.connection == expected else { throw AgentSecretRequestError.stale }
    }
}
