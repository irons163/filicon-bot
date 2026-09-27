import SwiftUI
import FiliconAgents

/// A saved locator is not a downloaded or verified media file.
struct RemoteAttachmentCard: View {
    let reference: RemoteAttachmentReference
    @Environment(\.openURL) private var openURL

    var body: some View {
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
    }

    private func openReference() {
        guard let url = URL(string: reference.url) else { return }
        openURL(url)
    }
}
