import SwiftUI
import AppKit

/// Warm paper surfaces, peach incoming messages and ink outgoing messages.
/// Dark appearance keeps the same hierarchy with warm charcoal surfaces.
enum FiliconTheme {
    static let canvas = adaptive(
        light: NSColor(calibratedRed: 1.0, green: 0.989, blue: 0.927, alpha: 1),
        dark: NSColor(calibratedRed: 0.12, green: 0.112, blue: 0.102, alpha: 1)
    )
    static let sidebar = adaptive(
        light: NSColor(calibratedRed: 0.992, green: 0.970, blue: 0.905, alpha: 1),
        dark: NSColor(calibratedRed: 0.145, green: 0.133, blue: 0.118, alpha: 1)
    )
    static let surface = adaptive(
        light: NSColor(calibratedRed: 1.0, green: 0.989, blue: 0.927, alpha: 1),
        dark: NSColor(calibratedRed: 0.15, green: 0.137, blue: 0.123, alpha: 1)
    )
    static let surfaceRaised = adaptive(
        light: NSColor(calibratedRed: 0.966, green: 0.900, blue: 0.820, alpha: 1),
        dark: NSColor(calibratedRed: 0.23, green: 0.202, blue: 0.178, alpha: 1)
    )
    static let input = adaptive(
        light: NSColor(calibratedRed: 0.992, green: 0.937, blue: 0.863, alpha: 1),
        dark: NSColor(calibratedRed: 0.19, green: 0.170, blue: 0.148, alpha: 1)
    )
    static let border = adaptive(
        light: NSColor(calibratedRed: 0.915, green: 0.869, blue: 0.790, alpha: 1),
        dark: NSColor(calibratedRed: 0.29, green: 0.262, blue: 0.231, alpha: 1)
    )
    static let borderStrong = adaptive(
        light: NSColor(calibratedRed: 0.83, green: 0.77, blue: 0.68, alpha: 1),
        dark: NSColor(calibratedRed: 0.38, green: 0.34, blue: 0.29, alpha: 1)
    )
    static let textPrimary = adaptive(
        light: NSColor(calibratedRed: 0.18, green: 0.16, blue: 0.13, alpha: 1),
        dark: NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.87, alpha: 1)
    )
    static let textSecondary = adaptive(
        light: NSColor(calibratedRed: 0.43, green: 0.39, blue: 0.32, alpha: 1),
        dark: NSColor(calibratedRed: 0.76, green: 0.71, blue: 0.64, alpha: 1)
    )
    static let textTertiary = adaptive(
        light: NSColor(calibratedRed: 0.53, green: 0.48, blue: 0.40, alpha: 1),
        dark: NSColor(calibratedRed: 0.64, green: 0.59, blue: 0.51, alpha: 1)
    )
    static let accent = adaptive(
        light: NSColor(calibratedWhite: 0.08, alpha: 1),
        dark: NSColor(calibratedRed: 0.97, green: 0.88, blue: 0.73, alpha: 1)
    )
    static let accentStrong = adaptive(
        light: NSColor.black,
        dark: NSColor(calibratedRed: 1, green: 0.94, blue: 0.84, alpha: 1)
    )
    static let accentText = adaptive(
        light: NSColor.white,
        dark: NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.06, alpha: 1)
    )
    static let userBubble = adaptive(
        light: NSColor(calibratedWhite: 0.025, alpha: 1),
        dark: NSColor(calibratedWhite: 0.035, alpha: 1)
    )
    static let userBubbleText = Color(red: 1, green: 0.98, blue: 0.93)
    static let incomingBubble = adaptive(
        light: NSColor(calibratedRed: 1, green: 0.933, blue: 0.858, alpha: 1),
        dark: NSColor(calibratedRed: 0.235, green: 0.197, blue: 0.164, alpha: 1)
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
        return .clear
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
