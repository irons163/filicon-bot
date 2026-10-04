import Foundation
import Testing
import CustomDump
import FiliconDomain
@testable import Filicon

@Suite("Transcript card action authority")
struct TranscriptCardActionRouterTests {
    @Test func savedActivityMetadataCannotAcquireGenericActionAuthority() async throws {
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000010")!
        let metadata = AutomationActivityTranscriptCard(entryID: id, guardID: id,
            binding: .init(accountID: "fixture", agentID: id), conversationID: id, isPaused: true)
        for intent in [TranscriptCardActionIntent.retry(cardID: id), .dismiss(cardID: id)] {
            var card = makeCard(lifecycle: .failed,
                payload: .widget(.init(title: "Imported display data", widgetKind: "automationActivity", automationActivity: metadata)),
                intents: [intent])
            card.id = id
            expectNoDifference(card.rendererLifecycle, .retired)
            expectNoDifference(card.rendererActions, [])
            await expectRoutingError(.mismatchedTarget) {
                try await TranscriptCardActionRouter().begin(card: card, intent: intent)
            }
        }
        let legacy = try JSONDecoder().decode(WidgetTranscriptCard.self,
            from: Data(#"{"title":"Old widget","body":"Still readable","widgetKind":"summary","facts":{}}"#.utf8))
        #expect(legacy.automationActivity == nil)
    }

    @Test func boundSecretCannotUseLegacyCredentialAction() async throws {
        let request = try AgentSecretRequest.parse(Data(#"{"label":"Token","connector":"slack","field":"token"}"#.utf8))
        let id = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        let direct = DirectSecretRequest(requestID: id, request: request,
            binding: .init(accountID: "local", agentID: id), conversationID: id, connectionID: id)
        let intent = TranscriptCardActionIntent.provideSecret(requestID: id.uuidString)
        let card = makeCard(payload: .secretRequest(.init(requestID: id.uuidString,
            service: "slack", directRequest: direct)), intents: [intent])
        await expectRoutingError(.mismatchedTarget) {
            try await TranscriptCardActionRouter().begin(card: card, intent: intent)
        }
        for action in [TranscriptCardActionIntent.retry(cardID: card.id), .dismiss(cardID: card.id)] {
            var altered = card
            altered.lifecycle = .failed
            altered.actions = [.init(id: "action", label: "Action", intent: action)]
            expectNoDifference(altered.rendererActions, [])
            await expectRoutingError(.mismatchedTarget) {
                try await TranscriptCardActionRouter().begin(card: altered, intent: action)
            }
        }
    }

    @Test func externalReferenceCannotNavigateToLocalAgent() async throws {
        let intent = TranscriptCardActionIntent.openCloudAgent(agentID: "same-id", threadID: nil)
        let card = makeCard(payload: .cloudAgent(.init(agentID: "same-id", title: "Cloud",
            externalReferenceID: "same-id")), intents: [intent])
        await expectRoutingError(.mismatchedTarget) {
            try await TranscriptCardActionRouter().begin(card: card, intent: intent)
        }
        let legacy = Data(#"{"agentID":"local","title":"Local","detail":""}"#.utf8)
        let decoded = try JSONDecoder().decode(CloudAgentTranscriptCard.self, from: legacy)
        #expect(decoded.externalReferenceID == nil)
    }

    @Test func onlyAnActionDeclaredByTheExactCardMayBegin() async throws {
        let card = makeCard(
            lifecycle: .draft,
            payload: .draft(.init(draftID: "draft-1", channel: "slack", body: "hello")),
            intents: [.sendDraft(draftID: "draft-1")]
        )
        let router = TranscriptCardActionRouter()

        let ticket = try await router.begin(card: card, intent: .sendDraft(draftID: "draft-1"))
        #expect(ticket.cardID == card.id)
        #expect(ticket.successLifecycle == .sent)
        await router.abandon(ticket)

        await expectRoutingError(.unauthorizedAction) {
            try await router.begin(card: card, intent: .sendDraft(draftID: "not-declared"))
        }
    }

    @Test func payloadTargetMustMatchEvenWhenRendererDeclaresAction() async {
        let intent = TranscriptCardActionIntent.cancelShell(operationID: UUID().uuidString)
        let card = makeCard(
            payload: .shell(.init(operationID: UUID().uuidString, commandSummary: "safe summary")),
            intents: [intent]
        )
        await expectRoutingError(.mismatchedTarget) {
            try await TranscriptCardActionRouter().begin(card: card, intent: intent)
        }
    }

    @Test func connectorRequiresPayloadAllowListAsWellAsDeclaredAction() async {
        let intent = TranscriptCardActionIntent.connectorAction(connectorID: "slack", actionID: "open_channels")
        let card = makeCard(
            payload: .connector(.init(
                connectorID: "slack", service: "Slack", title: "Open",
                allowedActionIDs: []
            )),
            intents: [intent]
        )
        await expectRoutingError(.mismatchedTarget) {
            try await TranscriptCardActionRouter().begin(card: card, intent: intent)
        }
    }

    @Test func oneShotTicketPreventsConcurrentAndForgedFinishes() async throws {
        let card = makeCard(
            lifecycle: .waiting,
            payload: .listener(.init(listenerID: "listener", connector: "slack", event: "message")),
            intents: [.connectListener(listenerID: "listener")]
        )
        let router = TranscriptCardActionRouter()
        let ticket = try await router.begin(card: card, intent: .connectListener(listenerID: "listener"))

        await expectRoutingError(.actionInFlight) {
            try await router.begin(card: card, intent: .connectListener(listenerID: "listener"))
        }
        let forged = TranscriptCardActionTicket(
            id: UUID(), cardID: ticket.cardID, intent: ticket.intent,
            expectedUpdatedAt: ticket.expectedUpdatedAt,
            successLifecycle: ticket.successLifecycle
        )
        #expect(await router.finish(forged) == false)
        #expect(await router.finish(ticket))
        #expect(await router.finish(ticket) == false)
    }

    @Test func terminalAndStaleLifecycleRulesAreFailClosed() async {
        let approve = TranscriptCardActionIntent.approveReview(reviewID: "review")
        let terminal = makeCard(
            lifecycle: .approved,
            payload: .autoReview(.init(reviewID: "review", title: "Review")),
            intents: [approve]
        )
        await expectRoutingError(.alreadyHandled) {
            try await TranscriptCardActionRouter().begin(card: terminal, intent: approve)
        }

        let running = makeCard(
            lifecycle: .running,
            payload: terminal.payload,
            intents: [approve]
        )
        await expectRoutingError(.staleCard) {
            try await TranscriptCardActionRouter().begin(card: running, intent: approve)
        }
    }

    @Test func retryAndDismissHaveExactLifecycleTransitions() async throws {
        let failed = makeCard(lifecycle: .failed, payload: .notice(.init(title: "Failed", message: "Try again")))
        let retry = TranscriptCardActionIntent.retry(cardID: failed.id)
        var retryCard = failed
        retryCard.actions = [.init(id: "retry", label: "Retry", intent: retry)]
        let retryTicket = try await TranscriptCardActionRouter().begin(card: retryCard, intent: retry)
        #expect(retryTicket.successLifecycle == .pending)

        let waiting = makeCard(lifecycle: .waiting, payload: .notice(.init(title: "Wait", message: "Pending")))
        let dismiss = TranscriptCardActionIntent.dismiss(cardID: waiting.id)
        var dismissCard = waiting
        dismissCard.actions = [.init(id: "dismiss", label: "Dismiss", intent: dismiss)]
        let dismissTicket = try await TranscriptCardActionRouter().begin(card: dismissCard, intent: dismiss)
        #expect(dismissTicket.successLifecycle == .retired)
    }

    @Test func localPermissionDecisionTargetAndLifecycleAreExact() async throws {
        let requestID = UUID().uuidString
        let decision = TranscriptCardActionIntent.decideLocalToolPermission(requestID: requestID, decision: .deny)
        let card = makeCard(
            lifecycle: .waiting,
            payload: .localToolPermission(.init(requestID: requestID, toolName: "read-file", scope: "/workspace/file")),
            intents: [decision]
        )
        let ticket = try await TranscriptCardActionRouter().begin(card: card, intent: decision)
        #expect(ticket.successLifecycle == .denied)
    }

    private func makeCard(
        lifecycle: TranscriptCardLifecycle = .pending,
        payload: TranscriptCardPayload,
        intents: [TranscriptCardActionIntent] = []
    ) -> TranscriptCard {
        let timestamp = Date(timeIntervalSince1970: 1_234)
        return TranscriptCard(
            lifecycle: lifecycle, createdAt: timestamp, updatedAt: timestamp,
            payload: payload,
            actions: intents.enumerated().map { .init(id: "action-\($0.offset)", label: "Action", intent: $0.element) }
        )
    }

    private func expectRoutingError(
        _ expected: TranscriptCardActionRoutingError,
        operation: () async throws -> TranscriptCardActionTicket
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as TranscriptCardActionRoutingError {
            #expect(error == expected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
