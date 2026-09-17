import SwiftUI
import AppKit

/// The native shell palette used by the conversation workspace.
///
/// The reconstructed renderer uses a deliberately quiet, dark surface with one
/// high-contrast accent.  Keeping these values in one place makes it possible to
/// match that visual language without bringing a web renderer into the app.
enum FiliconTheme {
    static let canvas = adaptive(
        light: NSColor(calibratedWhite: 0.965, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.086, blue: 0.078, alpha: 1)
    )
    static let sidebar = adaptive(
        light: NSColor(calibratedWhite: 0.94, alpha: 1),
        dark: NSColor(calibratedRed: 0.090, green: 0.102, blue: 0.094, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedRed: 0.125, green: 0.141, blue: 0.125, alpha: 1)
    )
    static let surfaceRaised = adaptive(
        light: NSColor(calibratedWhite: 0.985, alpha: 1),
        dark: NSColor(calibratedRed: 0.165, green: 0.184, blue: 0.157, alpha: 1)
    )
    static let input = adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedRed: 0.145, green: 0.161, blue: 0.141, alpha: 1)
    )
    static let border = adaptive(
        light: NSColor(calibratedWhite: 0.84, alpha: 1),
        dark: NSColor(calibratedRed: 0.215, green: 0.239, blue: 0.208, alpha: 1)
    )
    static let borderStrong = adaptive(
        light: NSColor(calibratedWhite: 0.75, alpha: 1),
        dark: NSColor(calibratedRed: 0.285, green: 0.318, blue: 0.269, alpha: 1)
    )
    static let textPrimary = adaptive(
        light: NSColor(calibratedWhite: 0.12, alpha: 1),
        dark: NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.88, alpha: 1)
    )
    static let textSecondary = adaptive(
        light: NSColor(calibratedWhite: 0.36, alpha: 1),
        dark: NSColor(calibratedRed: 0.65, green: 0.69, blue: 0.62, alpha: 1)
    )
    static let textTertiary = adaptive(
        light: NSColor(calibratedWhite: 0.52, alpha: 1),
        dark: NSColor(calibratedRed: 0.45, green: 0.49, blue: 0.43, alpha: 1)
    )
    static let accent = adaptive(
        light: NSColor(calibratedRed: 0.22, green: 0.43, blue: 0.11, alpha: 1),
        dark: NSColor(calibratedRed: 0.78, green: 0.93, blue: 0.40, alpha: 1)
    )
    static let accentStrong = adaptive(
        light: NSColor(calibratedRed: 0.16, green: 0.34, blue: 0.07, alpha: 1),
        dark: NSColor(calibratedRed: 0.86, green: 0.98, blue: 0.53, alpha: 1)
    )
    static let accentText = adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.06, alpha: 1)
    )
    static let userBubble = adaptive(
        light: NSColor(calibratedRed: 0.88, green: 0.94, blue: 0.82, alpha: 1),
        dark: NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.15, alpha: 1)
    )
    static let warning = adaptive(
        light: NSColor(calibratedRed: 0.52, green: 0.27, blue: 0.02, alpha: 1),
        dark: NSColor(calibratedRed: 0.98, green: 0.68, blue: 0.27, alpha: 1)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct FiliconAvatar: View {
    @Environment(\.locale) private var uiLocale
    let title: String
    var systemName: String = "bubble.left.and.bubble.right.fill"
    var size: CGFloat = 30

    var body: some View {
        let _ = uiLocale.identifier
        ZStack {
            Circle().fill(FiliconTheme.accent.opacity(0.16))
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(FiliconTheme.accent)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(title)
    }
}

struct FiliconIconButton: View {
    @Environment(\.locale) private var uiLocale
    let label: String
    let systemName: String
    var size: CGFloat = 30
    var isProminent = false
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        let _ = uiLocale.identifier
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(foreground)
                .background(background, in: Circle())
                .overlay(Circle().stroke(border, lineWidth: isProminent ? 0 : 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        if isDestructive { return .red }
        return isProminent ? FiliconTheme.accentText : FiliconTheme.textSecondary
    }

    private var background: Color {
        if isProminent { return FiliconTheme.accent }
        return FiliconTheme.surfaceRaised.opacity(0.70)
    }

    private var border: Color {
        isDestructive ? .red.opacity(0.24) : FiliconTheme.border
    }
}

struct FiliconPill: View {
    @Environment(\.locale) private var uiLocale
    let title: String
    var symbolName: String?
    var tint: Color = FiliconTheme.textSecondary

    var body: some View {
        let _ = uiLocale.identifier
        HStack(spacing: 5) {
            if let symbolName { Image(systemName: symbolName).font(.caption2) }
            Text(title).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(FiliconTheme.surfaceRaised.opacity(0.72), in: Capsule())
        .overlay(Capsule().stroke(FiliconTheme.border, lineWidth: 0.7))
    }
}

struct FiliconSidebarRow: View {
    @Environment(\.locale) private var uiLocale
    let title: String
    let systemName: String
    var selected = false
    var badge: String?
    let action: () -> Void

    var body: some View {
        let _ = uiLocale.identifier
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemName)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge { Text(badge).font(.caption2.monospacedDigit()).foregroundStyle(FiliconTheme.textTertiary) }
            }
            .foregroundStyle(selected ? FiliconTheme.textPrimary : FiliconTheme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(selected ? FiliconTheme.surfaceRaised : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                if selected { RoundedRectangle(cornerRadius: 9).stroke(FiliconTheme.border, lineWidth: 0.7) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct FiliconSectionLabel: View {
    @Environment(\.locale) private var uiLocale
    let title: String

    var body: some View {
        let _ = uiLocale.identifier
        Text(title)
            .textCase(.uppercase)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(FiliconTheme.textTertiary)
            .padding(.horizontal, 11)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }
}
