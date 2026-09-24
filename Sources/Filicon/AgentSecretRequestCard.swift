import SwiftUI
import Observation
import FiliconAppServices
import FiliconChannels

@MainActor @Observable
final class AgentSecretRequestCardModel: CustomReflectable, CustomStringConvertible {
    enum Status: Equatable {
        case pending, submitting, stored, cancelled, invalidValue, writeFailed, unavailable, receiptFailed
    }

    var draft = ""
    private(set) var status: Status = .pending
    let label: String
    let helpText: String?
    let destinationName: String
    private let submitValue: (AgentSecretValue) async throws -> AgentSecretReceipt
    private let closeSubmission: () -> Void
    private let didStore: (AgentSecretReceipt) -> Void
    private let complete: ((AgentSecretReceipt) async throws -> Void)?
    private let dismiss: (() async throws -> Void)?
    private var storedReceipt: AgentSecretReceipt?
    private var finishing = false
    private var active = true

    nonisolated var description: String { "<secure credential card>" }
    nonisolated var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .class) }

    init(label: String, helpText: String? = nil, destinationName: String,
         submit: @escaping (AgentSecretValue) async throws -> AgentSecretReceipt,
         close: @escaping () -> Void,
         didStore: @escaping (AgentSecretReceipt) -> Void,
         complete: ((AgentSecretReceipt) async throws -> Void)? = nil,
         dismiss: (() async throws -> Void)? = nil) {
        self.label = label
        self.helpText = helpText
        self.destinationName = destinationName
        submitValue = submit
        closeSubmission = close
        self.didStore = didStore
        self.complete = complete
        self.dismiss = dismiss
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
            storedReceipt = receipt
            await retryButtonTapped()
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

    func retryButtonTapped() async {
        guard active, !finishing, let receipt = storedReceipt else { return }
        finishing = true
        defer { finishing = false }
        status = .submitting
        do {
            try await complete?(receipt)
            guard active, !Task.isCancelled else { invalidate(); return }
            active = false
            draft = ""
            status = .stored
            closeSubmission()
            didStore(receipt)
        } catch {
            guard active else { return }
            if error is CancellationError { invalidate() }
            else { status = .receiptFailed }
        }
    }

    func dismissButtonTapped() async {
        guard storedReceipt == nil else { invalidate(); return }
        invalidate()
        do { try await dismiss?() }
        catch { status = .unavailable }
    }

    func clearDraft() { draft = "" }

    func invalidate() {
        draft = ""
        guard active else { return }
        active = false
        status = storedReceipt == nil ? .cancelled : .stored
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
            if model.canEdit || model.status == .submitting || model.status == .receiptFailed {
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(FiliconTheme.textPrimary)
        .background(FiliconTheme.incomingBubble, in: RoundedRectangle(cornerRadius: 16))
        .onDisappear { model.clearDraft() }
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
        case .receiptFailed: "Credential stored, but the conversation receipt could not be saved. Retry without entering the credential again."
        }
    }

    @ViewBuilder private var actions: some View {
        if model.status == .receiptFailed {
            Button(l10n("Retry")) { Task { await model.retryButtonTapped() } }
                .buttonStyle(.borderedProminent)
        } else {
            Button(l10n("Save credential")) {
                Task { await model.submitButtonTapped() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canEdit || model.draft.isEmpty)
        }
        Button(l10n("Dismiss")) { Task { await model.dismissButtonTapped() } }
            .buttonStyle(.bordered)
    }
}
