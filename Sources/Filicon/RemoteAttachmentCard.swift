import SwiftUI
import FiliconAgents

/// A saved locator is not a downloaded or verified media file.
struct RemoteAttachmentCard: View {
    let reference: RemoteAttachmentReference
    var onPreview: (() async throws -> Void)?
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
                        Button(l10n("Cancel")) { previewTask?.cancel(); previewTask = nil }
                    } else {
                        Button(l10n("Download image preview"), systemImage: "photo") { previewButtonTapped(onPreview) }
                    }
                }
                if previewFailed {
                    Text(l10n("Image preview unavailable. You can open the external link instead."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear { previewTask?.cancel(); previewTask = nil }
    }

    private func previewButtonTapped(_ action: @escaping () async throws -> Void) {
        previewFailed = false
        previewTask = Task { @MainActor in
            defer { if !Task.isCancelled { previewTask = nil } }
            do { try await action() }
            catch { if !Task.isCancelled { previewFailed = true } }
        }
    }

    private func openReference() {
        guard let url = URL(string: reference.url) else { return }
        openURL(url)
    }
}
