import Foundation
import FiliconDomain

enum TranscriptCardActionRoutingError: LocalizedError, Equatable {
    case unauthorizedAction
    case mismatchedTarget
    case staleCard
    case actionInFlight
    case alreadyHandled
    case backendUnavailable(String)
    case operationNotConfirmed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorizedAction: "This action was not authorized by the card."
        case .mismatchedTarget: "The action target does not match this card."
        case .staleCard: "This card is stale and can no longer perform that action."
        case .actionInFlight: "This card action is already running."
        case .alreadyHandled: "This card action has already been handled."
        case .backendUnavailable(let operation):
            "\(operation) is unavailable. The card was not completed and can be retried."
        case .operationNotConfirmed(let operation):
            "\(operation) was not confirmed by its service. The card can be retried."
        }
    }
}

struct TranscriptCardActionTicket: Hashable, Sendable {
    let id: UUID
    let cardID: UUID
    let intent: TranscriptCardActionIntent
    let expectedUpdatedAt: Date
    let successLifecycle: TranscriptCardLifecycle
}

/// Authority boundary between provider-authored transcript data and app-side
/// services. It grants a one-shot ticket only when the exact typed intent was
/// emitted by the exact live card and its payload agrees with the target.
actor TranscriptCardActionRouter {
    private var inFlight: [UUID: TranscriptCardActionTicket] = [:]

    func begin(card: TranscriptCard, intent: TranscriptCardActionIntent) throws -> TranscriptCardActionTicket {
        guard intent.isRendererSafe, card.actions.contains(where: { $0.intent == intent }) else {
            throw TranscriptCardActionRoutingError.unauthorizedAction
        }
        guard Self.matches(intent, payload: card.payload, cardID: card.id) else {
            throw TranscriptCardActionRoutingError.mismatchedTarget
        }
        guard Self.canBegin(intent, lifecycle: card.lifecycle) else {
            if Self.isTerminal(card.lifecycle) { throw TranscriptCardActionRoutingError.alreadyHandled }
            throw TranscriptCardActionRoutingError.staleCard
        }
        guard inFlight[card.id] == nil else { throw TranscriptCardActionRoutingError.actionInFlight }
        let ticket = TranscriptCardActionTicket(
            id: UUID(), cardID: card.id, intent: intent,
            expectedUpdatedAt: card.updatedAt,
            successLifecycle: Self.successLifecycle(for: intent)
        )
        inFlight[card.id] = ticket
        return ticket
    }

    func finish(_ ticket: TranscriptCardActionTicket) -> Bool {
        guard inFlight[ticket.cardID]?.id == ticket.id else { return false }
        inFlight.removeValue(forKey: ticket.cardID)
        return true
    }

    func abandon(_ ticket: TranscriptCardActionTicket) {
        guard inFlight[ticket.cardID]?.id == ticket.id else { return }
        inFlight.removeValue(forKey: ticket.cardID)
    }

    private static func matches(_ intent: TranscriptCardActionIntent, payload: TranscriptCardPayload, cardID: UUID) -> Bool {
        switch (intent, payload) {
        case (.approveReview(let lhs), .autoReview(let rhs)), (.rejectReview(let lhs), .autoReview(let rhs)):
            return lhs == rhs.reviewID
        case (.sendDraft(let lhs), .draft(let rhs)): return lhs == rhs.draftID
        case (.connectListener(let lhs), .listener(let rhs)): return lhs == rhs.listenerID
        case (.provideSecret(let lhs), .secretRequest(let rhs)): return lhs == rhs.requestID
        case (.connectorAction(let connector, let action), .connector(let rhs)):
            return connector == rhs.connectorID && rhs.allowedActionIDs.contains(action)
        case (.decideLocalToolPermission(let lhs, _), .localToolPermission(let rhs)):
            return lhs == rhs.requestID
        case (.openCloudAgent(let agent, let thread), .cloudAgent(let rhs)):
            return agent == rhs.agentID && thread == rhs.threadID
        case (.revealFileDiff(let lhs), .fileOperation(let rhs)): return lhs == rhs.operationID
        case (.cancelShell(let lhs), .shell(let rhs)): return lhs == rhs.operationID
        case (.retry(let id), _), (.dismiss(let id), _): return id == cardID
        default: return false
        }
    }

    private static func canBegin(_ intent: TranscriptCardActionIntent, lifecycle: TranscriptCardLifecycle) -> Bool {
        switch intent {
        case .retry:
            return lifecycle == .failed || lifecycle == .cancelled || lifecycle == .denied
        case .dismiss:
            return lifecycle != .running && lifecycle != .retired
        case .decideLocalToolPermission:
            return lifecycle == .waiting || lifecycle == .pending
        default:
            return lifecycle == .pending || lifecycle == .draft || lifecycle == .waiting || lifecycle == .failed
        }
    }

    private static func successLifecycle(for intent: TranscriptCardActionIntent) -> TranscriptCardLifecycle {
        switch intent {
        case .approveReview: .approved
        case .rejectReview: .denied
        case .sendDraft: .sent
        case .connectListener: .connected
        case .provideSecret: .provided
        case .decideLocalToolPermission(_, let decision): decision == .deny ? .denied : .approved
        case .cancelShell: .cancelled
        case .dismiss: .retired
        case .retry: .pending
        default: .succeeded
        }
    }

    private static func isTerminal(_ value: TranscriptCardLifecycle) -> Bool {
        [.approved, .denied, .provided, .connected, .sent, .succeeded, .cancelled, .retired].contains(value)
    }
}
