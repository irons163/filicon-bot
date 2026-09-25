import SwiftUI
import FiliconAgents

struct CursorAgentReferenceCard: View {
    let reference: CursorAgentReference
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(reference.url) } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "cloud").font(.title2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(l10n("Cursor cloud agent")).font(.headline)
                    Text(reference.bcID).font(.caption.monospaced()).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(l10n("Open on cursor.com. Remote status has not been verified."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cursor-agent-reference")
    }
}
