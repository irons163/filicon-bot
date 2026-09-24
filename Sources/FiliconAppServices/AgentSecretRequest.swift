import Foundation
import FiliconChannels
import FiliconAgents

public typealias AgentSecretRequest = FiliconAgents.AgentSecretRequest
public typealias AgentSecretRequestError = FiliconAgents.AgentSecretRequestError

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
                && $0.authorizationAccountID == accountID
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
