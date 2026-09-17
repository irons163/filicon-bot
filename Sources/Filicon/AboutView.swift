import AppKit
import SwiftUI

struct AboutView: View {
    @Environment(\.locale) private var uiLocale
    @EnvironmentObject private var model: AppModel
    @State private var copied = false
    @State private var copyGeneration = 0

    var body: some View {
        let _ = uiLocale.identifier
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(l10n("Filicon")).font(.title2.bold())
                Text(l10n("Version \(version) (\(build))"))
                    .foregroundStyle(.secondary)
                Text(l10n("Release track: \(model.settings.updatePolicy.effectiveTrack.rawValue.capitalized)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(l10n("© \(Calendar.current.component(.year, from: .now)) Filicon contributors"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(copied ? l10n("Copied") : l10n("Copy Version Info"), action: copyVersionInfo)
        }
        .padding(28)
        .frame(width: 360, height: 300)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "local"
    }

    private func copyVersionInfo() {
        let process = ProcessInfo.processInfo
        let os = process.operatingSystemVersion
        let text = [
            "Version: \(version) (\(build))",
            "Release Track: \(model.settings.updatePolicy.effectiveTrack.rawValue)",
            "OS: macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        copied = true
        copyGeneration += 1
        let generation = copyGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(1_200))
            guard generation == copyGeneration else { return }
            copied = false
        }
    }
}

struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(l10n("About Filicon")) { openWindow(id: "about") }
        }
    }
}
