import SwiftUI
import Observation
import FiliconAppServices
import FiliconChannels

@MainActor @Observable
final class AgentSecretRequestCardModel: CustomReflectable, CustomStringConvertible {
    enum Status: Equatable {
        case pending, submitting, stored, cancelled, invalidValue, writeFailed, unavailable
    }

    var draft = ""
    private(set) var status: Status = .pending
    let label: String
    let helpText: String?
    let destinationName: String
    private let submitValue: (AgentSecretValue) async throws -> AgentSecretReceipt
    private let closeSubmission: () -> Void
    private let didStore: (AgentSecretReceipt) -> Void
    private var active = true

    nonisolated var description: String { "<secure credential card>" }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

    init(label: String, helpText: String? = nil, destinationName: String,
         submit: @escaping (AgentSecretValue) async throws -> AgentSecretReceipt,
         close: @escaping () -> Void,
         didStore: @escaping (AgentSecretReceipt) -> Void) {
        self.label = label
        self.helpText = helpText
        self.destinationName = destinationName
        submitValue = submit
        closeSubmission = close
        self.didStore = didStore
    }

    convenience init(submission: AgentSecretSubmission, channels: ChannelService,
                     writer: @escaping AgentSecretSubmission.Writer,
                     didStore: @escaping (AgentSecretReceipt) -> Void) {
        let destination = submission.destination
        self.init(label: destination.request.label, helpText: destination.request.description,
                  destinationName: "\(destination.request.connector) · \(destination.displayName)",
                  submit: { value in
            try await submission.submit(value, accountID: destination.accountID,
                agentID: destination.agentID, conversationID: destination.conversationID,
                channels: channels, write: writer)
        }, close: { submission.close() }, didStore: didStore)
    }

    var canEdit: Bool {
        active && (status == .pending || status == .invalidValue || status == .writeFailed)
    }

    func submitButtonTapped() async {
        guard canEdit else { return }
        let value: AgentSecretValue
        do { value = try AgentSecretValue(draft) }
        catch {
            draft = ""
            status = .invalidValue
            return
        }
        draft = ""
        status = .submitting
        do {
            try Task.checkCancellation()
            let receipt = try await submitValue(value)
            guard active else { return }
            if Task.isCancelled {
                invalidate()
                return
            }
            active = false
            draft = ""
            status = .stored
            closeSubmission()
            didStore(receipt)
        } catch {
            guard active else { return }
            draft = ""
            if error is CancellationError {
                invalidate()
            } else if error as? AgentSecretSubmissionError == .writeFailed {
                status = .writeFailed
            } else {
                active = false
                status = .unavailable
                closeSubmission()
            }
        }
    }

    func invalidate() {
        draft = ""
        guard active else { return }
        active = false
        status = .cancelled
        closeSubmission()
    }
}

struct AgentSecretRequestCard: View {
    @Bindable var model: AgentSecretRequestCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(l10n("Secure credential request"), systemImage: "lock.shield")
                .font(.headline)
            Text(model.label).fixedSize(horizontal: false, vertical: true)
            if let helpText = model.helpText {
                Text(helpText).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.destinationName).font(.caption)
                .foregroundStyle(FiliconTheme.textSecondary)
            Text(l10n("Stored securely on this Mac, not sent to the conversation. This does not verify the connection or approve other tools."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if model.canEdit {
                SecureField(l10n("Credential"), text: $model.draft)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("agent-secret-input")
            }
            if model.status == .submitting {
                ProgressView().controlSize(.small)
            }
            if let message = statusMessage {
                Text(FiliconLocalization.string(message)).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.canEdit || model.status == .submitting {
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(FiliconTheme.textPrimary)
        .background(FiliconTheme.incomingBubble, in: RoundedRectangle(cornerRadius: 16))
        .onDisappear { model.invalidate() }
    }

    private var statusMessage: String? {
        switch model.status {
        case .pending: nil
        case .submitting: "Saving credential securely…"
        case .stored: "Credential stored. Remote authentication has not been verified."
        case .cancelled: "Cancelled"
        case .invalidValue: "Enter a nonempty credential without line breaks."
        case .writeFailed: "Could not store the credential. Enter it again to retry."
        case .unavailable: "This credential request is no longer available."
        }
    }

    @ViewBuilder private var actions: some View {
        Button(l10n("Save credential")) {
            Task { await model.submitButtonTapped() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canEdit || model.draft.isEmpty)
        Button(l10n("Dismiss")) { model.invalidate() }
            .buttonStyle(.bordered)
    }
}
