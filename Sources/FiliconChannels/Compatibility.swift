import Foundation

public enum ChannelAvailability: String, Codable, Hashable, Sendable { case available, comingSoon }

public struct ChannelManifest: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let blurb: String
    public let credentialLabel: String
    public let availability: ChannelAvailability
    public let connectGuide: String
}

public enum BuiltInChannelManifests {
    public static let all: [ChannelManifest] = [
        .init(id: "discord", displayName: "Discord", blurb: "Connect a Discord bot to an agent.", credentialLabel: "Bot token", availability: .available, connectGuide: "Create a Discord bot, invite it with message permissions, then enter its token and channel IDs."),
        .init(id: "slack", displayName: "Slack", blurb: "Connect a Slack bot to an agent.", credentialLabel: "Bot token", availability: .available, connectGuide: "Create a Slack app with channels:history and chat:write, install it, then enter its bot token and channel IDs."),
    ]
}

public enum ChannelAddressParser {
    public static func parse(_ raw: String) -> ChannelAddress? {
        guard let separator = raw.firstIndex(of: ":") else { return nil }
        let platform = raw[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let chat = raw[raw.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !platform.isEmpty, !chat.isEmpty else { return nil }
        return .init(platform: platform, channelID: chat)
    }
}

public enum ChannelMessagePart: Hashable, Sendable {
    case text(String)
    case image(url: String, caption: String?)
    case attachment(url: String, alt: String?)
    case unsupported
}

public enum ChannelMessageShaper {
    public static func shape(text: String?, imageURL: String? = nil, attachmentURL: String? = nil, alt: String? = nil) -> ChannelMessagePart? {
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let image = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines), !image.isEmpty {
            return .image(url: image, caption: text?.isEmpty == false ? text : nil)
        }
        if let attachment = attachmentURL?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if !attachment.isEmpty { return .attachment(url: attachment, alt: alt?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty) }
            if let alt = alt?.trimmingCharacters(in: .whitespacesAndNewlines), !alt.isEmpty { return .text(alt) }
        }
        if let text, !text.isEmpty { return .text(text) }
        return nil
    }
}

public enum ChannelCompatibility {
    public static func normalizedLabel(_ raw: String, platform: String) -> String {
        let normalized = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let fallback = BuiltInChannelManifests.all.first(where: { $0.id.caseInsensitiveCompare(platform) == .orderedSame })?.displayName
            ?? platform
        return String((normalized.isEmpty ? fallback : normalized).prefix(80))
    }

    public static func safePlatformIdentifier(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) == nil ? nil : value
    }

    public static func humanizedDeliveryFailure(address: String, error: Error) -> String {
        if ChannelAddressParser.parse(address) == nil { return "\"\(address)\" isn't a valid channel address, so that message wasn't delivered." }
        let detail = error.localizedDescription
        if detail.contains("No channel delivery mechanism is registered") {
            return "Channel messaging isn't available on this computer, so that message wasn't delivered."
        }
        if detail.lowercased().contains("no live") && detail.lowercased().contains("connection") {
            let platform = ChannelAddressParser.parse(address)?.platform.capitalized ?? "That channel"
            return "\(platform) isn't connected on this computer, so that message wasn't delivered. Connect \(platform) (add its token) to send there."
        }
        return "That channel message wasn't delivered: \(detail)"
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
