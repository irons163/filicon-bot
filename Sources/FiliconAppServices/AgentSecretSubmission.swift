import Foundation
import FiliconChannels
import FiliconAgents

/// Transient UI input, intentionally not Codable, Hashable or publicly readable.
/// Descriptions/reflection redact it; this is not a promise of memory zeroization
/// for Swift String copies. The UI must clear its input when submission ends.
public struct AgentSecretValue: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let rawValue: String
    public init(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 16_384,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentSecretSubmissionError.invalidValue
        }
        rawValue = value
    }
    public var description: String { "<redacted credential>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

public enum AgentSecretSubmissionError: Error, Equatable, Sendable {
    case invalidValue, unavailable, writeFailed
}

/// A value-free receipt. It says only that local storage succeeded, not that
/// remote authentication succeeded or that any additional tool was authorized.
public struct AgentSecretReceipt: Codable, Equatable, Sendable {
    public let requestID: UUID
    public var acknowledgement: String {
        "The user securely provided the requested credential. It was stored directly in its destination; the value is not in this conversation. This does not confirm remote authentication or grant additional tool permissions."
    }
}

/// One explicit secure-input submission. The host must close this synchronously
/// on Stop/account/owner changes before awaiting other cleanup. No value is kept
/// in this object's state, and only the credential writer ever receives it.
public final class AgentSecretSubmission: @unchecked Sendable {
    public typealias Writer = @Sendable (AgentSecretValue, CredentialRef) throws -> Void
    public enum State: Equatable, Sendable { case pending, stored(AgentSecretReceipt), dismissed, cancelled }
    public let id: UUID
    public let destination: AgentSecretRequestDestination
    private let lock = NSLock()
    private var current: State = .pending
    private var active = true

    public init(id: UUID = UUID(), destination: AgentSecretRequestDestination) {
        self.id = id; self.destination = destination
    }
    public var state: State { lock.withLock { current } }
    public func close() {
        lock.withLock {
            active = false
            if current == .pending { current = .cancelled }
        }
    }
    public func dismiss() throws {
        try lock.withLock {
            guard active, current == .pending else { throw AgentSecretSubmissionError.unavailable }
            active = false; current = .dismissed
        }
    }

    public func submit(_ value: AgentSecretValue, accountID: String, agentID: UUID, conversationID: UUID,
                       channels: ChannelService, write: @escaping Writer) async throws -> AgentSecretReceipt {
        try Task.checkCancellation()
        // Connections cannot be replaced between validation and the Keychain
        // call. The synchronous lifetime fence also excludes Stop/account swaps.
        return try await channels.commitCredential(connectionID: destination.connectionID) { [self] connections in
            try lock.withLock {
                guard active else { throw AgentSecretSubmissionError.unavailable }
                try Task.checkCancellation()
                try destination.validate(accountID: accountID, agentID: agentID,
                    conversationID: conversationID, connections: connections)
                if case .stored(let receipt) = current { return (receipt, false) }
                guard current == .pending else { throw AgentSecretSubmissionError.unavailable }
                do { try write(value, destination.credentialReference) }
                catch { throw AgentSecretSubmissionError.writeFailed }
                let receipt = AgentSecretReceipt(requestID: id)
                current = .stored(receipt)
                return (receipt, true)
            }
        }
    }

    public func recordMailboxReceipt(incomingMessageID: UUID, messenger: AgentMessenger,
                                      responseID: UUID = UUID(), chainID: UUID? = nil,
                                      directOriginBinding: DirectConversationAgentBinding? = nil,
                                      at: Date = Date(),
                                      lifetime: AgentPublicationLifetime) async throws -> AgentMessage {
        guard case .stored(let receipt) = state, receipt.requestID == id else {
            throw AgentSecretSubmissionError.unavailable
        }
        let messages = await messenger.allMessages()
        guard let incoming = messages.first(where: { $0.id == incomingMessageID }),
              incoming.recipientID == destination.agentID,
              let publication = incoming.delivery?.publications?.first(where: { $0.id == id }),
              let card = publication.secretRequest, card.request == destination.request,
              card.accountID == destination.accountID, card.connectionID == destination.connectionID,
              publication.groupID == destination.conversationID else {
            throw AgentSecretSubmissionError.unavailable
        }
        return try await messenger.resolveSecretRequest(replyingTo: incomingMessageID, publicationID: id,
            provided: true, accountID: destination.accountID, originID: destination.conversationID,
            connectionID: destination.connectionID, responseID: responseID, chainID: chainID,
            directOriginBinding: directOriginBinding, at: at, lifetime: lifetime)
    }

    /// Produces value-free direct-chat metadata only from this submission's
    /// actual outcome. Persisting the returned card/acknowledgement and checking
    /// the current account/lifetime remain the host's responsibility.
    public func resolvingDirectRequest(_ request: DirectSecretRequest, responseID: UUID) throws -> DirectSecretRequest {
        guard request.requestID == id, request.request == destination.request,
              request.binding.accountID == destination.accountID,
              request.binding.agentID == destination.agentID,
              request.conversationID == destination.conversationID,
              request.connectionID == destination.connectionID else {
            throw AgentSecretSubmissionError.unavailable
        }
        let provided: Bool
        switch state {
        case .stored(let receipt) where receipt.requestID == id: provided = true
        case .dismissed: provided = false
        default: throw AgentSecretSubmissionError.unavailable
        }
        let expectedState: DirectSecretRequest.State = provided ? .stored : .dismissed
        if request.state == expectedState, request.responseMessageID == responseID { return request }
        var resolved = request
        try resolved.resolve(provided: provided, responseMessageID: responseID)
        return resolved
    }
}
