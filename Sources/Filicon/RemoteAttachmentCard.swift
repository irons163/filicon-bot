import SwiftUI
import FiliconAgents

typealias RemoteRedirectReview = @MainActor @Sendable (RemoteAttachmentReference, RemoteAttachmentReference) async throws -> Bool
typealias RemotePreviewAction = (@escaping RemoteRedirectReview) async throws -> Void

@MainActor final class RemoteRedirectReviewModel: ObservableObject {
    struct Request {
        let id: UUID
        let source: RemoteAttachmentReference
        let destination: RemoteAttachmentReference
    }
    @Published private(set) var request: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func review(_ source: RemoteAttachmentReference, _ destination: RemoteAttachmentReference) async throws -> Bool {
        try Task.checkCancellation()
        resolve(approved: false)
        let id = UUID()
        return try await withTaskCancellationHandler {
            let approved = await withCheckedContinuation { continuation in
                self.continuation = continuation
                request = Request(id: id, source: source, destination: destination)
            }
            try Task.checkCancellation()
            return approved
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.request?.id == id else { return }
                self?.resolve(approved: false)
            }
        }
    }

    func resolve(approved: Bool) {
        let pending = continuation
        continuation = nil
        request = nil
        pending?.resume(returning: approved)
    }
}

/// A saved locator is not a downloaded or verified media file.
struct RemoteAttachmentCard: View {
    let reference: RemoteAttachmentReference
    var onPreview: RemotePreviewAction?
    @StateObject private var redirectReview = RemoteRedirectReviewModel()
    @Environment(\.openURL) private var openURL
    @State private var previewTask: Task<Void, Never>?
    @State private var previewFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        Button { openReference() } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "link").font(.title2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n("Remote attachment")).font(.headline)
                    if let alt = reference.alt {
                        Text(verbatim: alt).lineLimit(3)
                    }
                    Text(verbatim: reference.url).font(.caption.monospaced()).lineLimit(2)
                    Text(l10n("Open external link. Content has not been downloaded or verified."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(reference.url)
        .accessibilityIdentifier("remote-attachment-reference")
            if let onPreview {
                HStack {
                    if previewTask != nil {
                        ProgressView().controlSize(.small)
                        Button(l10n("Cancel")) { cancelButtonTapped() }
                    } else {
                        Button(l10n("Download preview"), systemImage: "eye") { previewButtonTapped(onPreview) }
                    }
                }
                if let request = redirectReview.request {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(l10n("Confirm download redirect")).font(.headline)
                        Text(verbatim: request.source.url).font(.caption.monospaced()).textSelection(.enabled)
                        Image(systemName: "arrow.down")
                        Text(verbatim: request.destination.url).font(.caption.monospaced()).textSelection(.enabled)
                        Button(l10n("Download from this address")) { redirectReview.resolve(approved: true) }
                        Button(l10n("Cancel")) { cancelButtonTapped() }
                    }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                }
                if previewFailed {
                    Text(l10n("Preview unavailable. You can open the external link instead."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { cancelButtonTapped() }
    }

    private func cancelButtonTapped() {
        previewTask?.cancel()
        previewTask = nil
        redirectReview.resolve(approved: false)
    }

    private func previewButtonTapped(_ action: @escaping RemotePreviewAction) {
        previewFailed = false
        previewTask = Task { @MainActor in
            defer { if !Task.isCancelled { previewTask = nil } }
            do { try await action { source, destination in try await redirectReview.review(source, destination) } }
            catch is CancellationError {}
            catch { if !Task.isCancelled { previewFailed = true } }
        }
    }

    private func openReference() {
        guard let url = URL(string: reference.url) else { return }
        openURL(url)
    }
}
