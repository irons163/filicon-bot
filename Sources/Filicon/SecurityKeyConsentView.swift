import SwiftUI
import FiliconSecurityKey

@MainActor
final class AppSecurityKeyConsentPresenter: ObservableObject, SecurityKeyConsentProvider, @unchecked Sendable {
    struct Request: Identifiable, Equatable {
        let consent: SecurityKeyConsent
        var id: String { consent.requestID }
    }

    @Published private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestConsent(_ consent: SecurityKeyConsent) async -> Bool {
        guard pending == nil, continuation == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.pending = Request(consent: consent)
            self.continuation = continuation
        }
    }

    func dismissConsent(requestID: String) async {
        guard pending?.id == requestID else { return }
        finish(false)
    }

    func resolve(approved: Bool) { finish(approved) }

    private func finish(_ approved: Bool) {
        pending = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: approved)
    }
}

struct SecurityKeyConsentView: View {
    @ObservedObject var presenter: AppSecurityKeyConsentPresenter

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Use Hardware Security Key?", systemImage: "key.horizontal")
                .font(.title2.weight(.semibold))
            Text("A remote computer is asking this Mac to perform a WebAuthn ceremony. Verify both values before allowing it.")
                .foregroundStyle(.secondary)
            if let request = presenter.pending?.consent {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow { Text("Origin").foregroundStyle(.secondary); Text(request.origin).textSelection(.enabled) }
                    GridRow { Text("Relying-party ID").foregroundStyle(.secondary); Text(request.rpID).textSelection(.enabled) }
                }
            }
            Text("Any PIN or biometric prompt is displayed by macOS Authentication Services. Filicon never asks for or handles the PIN itself.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Decline") { presenter.resolve(approved: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Allow Once") { presenter.resolve(approved: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled()
    }
}

struct SecurityKeyConsentHost: View {
    @ObservedObject var presenter: AppSecurityKeyConsentPresenter

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(item: Binding(
                get: { presenter.pending },
                set: { if $0 == nil { presenter.resolve(approved: false) } }
            )) { _ in
                SecurityKeyConsentView(presenter: presenter)
            }
    }
}
