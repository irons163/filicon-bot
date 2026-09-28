import Foundation
import FiliconDomain

enum TranscriptLinkDecision: Equatable {
    case allowed(URL)
    case blocked
}

/// A deliberately small allow-list for links originating in model output.
/// Filicon never hands arbitrary/custom schemes to Launch Services.
enum TranscriptLinkPolicy {
    static func decision(for url: URL) -> TranscriptLinkDecision {
        let serialized = url.absoluteString
        guard let scheme = url.scheme?.lowercased(),
              !containsUnsafeCharacters(serialized),
              !containsUnsafeCharacters(serialized.removingPercentEncoding ?? serialized)
        else { return .blocked }

        switch scheme {
        case "http", "https":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == scheme,
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  !serialized.contains("\\")
            else { return .blocked }
            return .allowed(url)
        case "mailto":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .blocked }
            let address = components.path.removingPercentEncoding ?? components.path
            let addressParts = address.split(separator: "@", omittingEmptySubsequences: false)
            let allowedHeaders = Set(["subject", "body"])
            guard addressParts.count == 2,
                  !addressParts[0].isEmpty,
                  !addressParts[1].isEmpty,
                  !address.contains(where: { $0.isWhitespace || $0 == "," || $0 == ";" }),
                  components.queryItems?.allSatisfy({ item in
                      allowedHeaders.contains(item.name.lowercased()) && !containsUnsafeCharacters(item.value ?? "")
                  }) ?? true
            else { return .blocked }
            return .allowed(url)
        default:
            return .blocked
        }
    }

    private static func containsUnsafeCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) || $0 == "\u{2028}" || $0 == "\u{2029}"
        }
    }
}

enum TranscriptMarkdownBlock: Equatable {
    case prose(String)
    case code(language: String?, source: String)
}

enum TranscriptMarkdownParser {
    /// Splits fenced code from prose so code has a dedicated, verifiable copy action.
    /// Unterminated fences remain code instead of being interpreted as rich content.
    static func blocks(in source: String) -> [TranscriptMarkdownBlock] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [TranscriptMarkdownBlock] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inFence = false

        func appendProse() {
            guard !prose.isEmpty else { return }
            blocks.append(.prose(prose.joined(separator: "\n")))
            prose.removeAll(keepingCapacity: true)
        }
        func appendCode() {
            blocks.append(.code(language: language, source: code.joined(separator: "\n")))
            code.removeAll(keepingCapacity: true)
            language = nil
        }

        for line in lines {
            if !inFence, line.hasPrefix("```") {
                appendProse()
                let tag = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                language = tag.isEmpty ? nil : tag
                inFence = true
            } else if inFence, line.hasPrefix("```") {
                appendCode()
                inFence = false
            } else if inFence {
                code.append(line)
            } else {
                prose.append(line)
            }
        }
        if inFence { appendCode() } else { appendProse() }
        return blocks.filter {
            switch $0 { case .prose(let value): !value.isEmpty; case .code: true }
        }
    }
}

enum TranscriptClipboardContent {
    static func messageText(_ message: ChatMessage) -> String {
        if !message.text.isEmpty { return message.text }
        if !message.reasoningText.isEmpty { return message.reasoningText }
        let tools = message.toolActivities.compactMap(\.result).joined(separator: "\n")
        if !tools.isEmpty { return tools }
        return message.transcriptCards.map(TranscriptCardPresenter.searchableText).joined(separator: "\n")
    }
}

enum ReplyPreviewKind: Equatable, Sendable {
    case text, attachment, reasoning, tool, card, unavailable
}

struct ReplyPreviewPresentation: Equatable, Sendable {
    let kind: ReplyPreviewKind
    let label: String
    let detail: String
    let symbolName: String

    static func make(for message: ChatMessage?) -> ReplyPreviewPresentation {
        guard let message else {
            return .init(kind: .unavailable, label: l10n("Original message"), detail: l10n("Unavailable"), symbolName: "questionmark.circle")
        }
        let role = message.role == .user ? "You" : message.role == .assistant ? "Assistant" : message.role.rawValue.capitalized
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return .init(kind: .text, label: role, detail: oneLine(text), symbolName: "text.bubble")
        }
        if let attachment = message.attachments.first {
            return .init(kind: .attachment, label: role, detail: attachment.filename, symbolName: "paperclip")
        }
        if let remote = message.remoteAttachment {
            return .init(kind: .attachment, label: role, detail: remote.replyPreviewText, symbolName: "link")
        }
        let reasoning = message.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reasoning.isEmpty {
            return .init(kind: .reasoning, label: role, detail: l10n("Reasoning"), symbolName: "brain")
        }
        if let tool = message.toolActivities.first {
            let card = ToolCardClassifier.presentation(for: tool)
            return .init(kind: .tool, label: role, detail: card.title, symbolName: card.symbolName)
        }
        if let card = message.transcriptCards.first {
            let presentation = TranscriptCardPresenter.presentation(for: card)
            return .init(kind: .card, label: role, detail: presentation.title, symbolName: presentation.symbolName)
        }
        return .init(kind: .unavailable, label: role, detail: l10n("Empty message"), symbolName: "questionmark.circle")
    }

    private static func oneLine(_ value: String) -> String {
        String(value.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(240))
    }
}

extension RemoteAttachmentReference {
    var replyPreviewText: String {
        String((alt ?? url).split(whereSeparator: \.isNewline).joined(separator: " ").prefix(240))
    }
}

enum ToolCardKind: String, CaseIterable, Sendable {
    case connector, email, permission, secret, automation, cloudAgent, generic
}

struct ToolCardField: Equatable, Sendable {
    let label: String
    let value: String
}

struct ToolCardPresentation: Equatable, Sendable {
    let kind: ToolCardKind
    let title: String
    let subtitle: String
    let symbolName: String
    let fields: [ToolCardField]
    let links: [URL]
    let redactedArguments: String
    let redactedResult: String?
}

/// Provider-neutral semantic presentation for tool calls. New card types can be
/// added here without coupling the transcript to any inference vendor.
enum ToolCardClassifier {
    static func presentation(for activity: ToolActivity) -> ToolCardPresentation {
        let name = activity.name.rawValue
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "_")
        let arguments = jsonObject(activity.argumentsJSON)
        let result = activity.result.flatMap(jsonObject)
        let kind = classify(name: normalized, arguments: arguments)
        let facts = safeFields(from: arguments, kind: kind)
        let urls = collectStrings(from: arguments)
            .compactMap(URL.init(string:))
            .filter { if case .allowed = TranscriptLinkPolicy.decision(for: $0) { true } else { false } }
        return ToolCardPresentation(
            kind: kind,
            title: title(for: kind, fallback: humanized(name)),
            subtitle: activity.status.rawValue.capitalized,
            symbolName: symbol(for: kind),
            fields: Array(facts.prefix(4)),
            links: Array(urls.prefix(3)),
            redactedArguments: redactedJSON(arguments, fallback: activity.argumentsJSON, protected: kind == .secret),
            redactedResult: activity.result.map {
                kind == .secret ? "Protected result hidden" : redactedJSON(result, fallback: $0, protected: false)
            }
        )
    }

    private static func classify(name: String, arguments: Any?) -> ToolCardKind {
        let keys = Set(flattenedKeys(arguments).map { $0.lowercased() })
        if containsAny(name, ["secret", "credential", "api_key", "access_token"]) ||
            !keys.intersection(["secret", "password", "api_key", "access_token", "private_key"]).isEmpty { return .secret }
        if containsAny(name, ["permission", "authorize", "approval", "consent"]) { return .permission }
        if containsAny(name, ["email", "mail", "gmail", "outlook"]) ||
            !keys.intersection(["recipient", "recipients", "to", "cc", "bcc", "subject"]).isEmpty { return .email }
        if containsAny(name, ["automation", "schedule", "cron", "trigger", "workflow"]) { return .automation }
        if (name.contains("cloud") && name.contains("agent")) || containsAny(name, ["delegate_agent", "agent_task", "subagent"]) { return .cloudAgent }
        if containsAny(name, ["connector", "slack", "discord", "teams", "github", "linear", "sentry", "pagerduty"]) { return .connector }
        return .generic
    }

    private static func safeFields(from object: Any?, kind: ToolCardKind) -> [ToolCardField] {
        guard let dictionary = object as? [String: Any] else { return [] }
        let preferred: [String]
        switch kind {
        case .email: preferred = ["to", "recipient", "subject", "account"]
        case .connector: preferred = ["connector", "service", "channel", "action"]
        case .permission: preferred = ["permission", "scope", "resource", "reason"]
        case .secret: preferred = ["service", "account", "scope"]
        case .automation: preferred = ["name", "schedule", "timezone", "trigger"]
        case .cloudAgent: preferred = ["agent", "task", "status", "workspace"]
        case .generic: preferred = ["action", "name", "query", "path"]
        }
        return preferred.compactMap { key in
            guard let pair = dictionary.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }),
                  !isSensitive(pair.key), let value = displayValue(pair.value) else { return nil }
            return ToolCardField(label: humanized(pair.key), value: value)
        }
    }

    private static func jsonObject(_ source: String) -> Any? {
        guard let data = source.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func redactedJSON(_ object: Any?, fallback: String, protected: Bool) -> String {
        guard let object else {
            return protected ? "Protected content hidden" : sanitizedPlainText(fallback)
        }
        let redacted = protected ? conceal(object) : redact(object)
        guard JSONSerialization.isValidJSONObject(redacted),
              let data = try? JSONSerialization.data(withJSONObject: redacted, options: [.prettyPrinted, .sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return protected ? "Protected content hidden" : sanitizedPlainText(fallback)
        }
        return value
    }

    private static func sanitizedPlainText(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        return String(String.UnicodeScalarView(scalars).prefix(8_000))
    }

    private static func redact(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                (key, isSensitive(key) ? "••••••••" : redact(value))
            })
        }
        if let array = object as? [Any] { return array.map(redact) }
        return object
    }

    private static func conceal(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return Dictionary(uniqueKeysWithValues: dictionary.map { key, value in
                (key, conceal(value))
            })
        }
        if let array = object as? [Any] { return array.map(conceal) }
        return "••••••••"
    }

    private static func flattenedKeys(_ object: Any?) -> [String] {
        if let dictionary = object as? [String: Any] {
            return Array(dictionary.keys) + dictionary.values.flatMap(flattenedKeys)
        }
        if let array = object as? [Any] { return array.flatMap(flattenedKeys) }
        return []
    }

    private static func collectStrings(from object: Any?) -> [String] {
        if let string = object as? String { return [string] }
        if let dictionary = object as? [String: Any] { return dictionary.values.flatMap(collectStrings) }
        if let array = object as? [Any] { return array.flatMap(collectStrings) }
        return []
    }

    private static func displayValue(_ value: Any) -> String? {
        if let string = value as? String, !string.isEmpty { return String(string.prefix(160)) }
        if let number = value as? NSNumber { return number.stringValue }
        if let strings = value as? [String], !strings.isEmpty { return strings.prefix(3).joined(separator: ", ") }
        return nil
    }

    private static func isSensitive(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return ["secret", "password", "passwd", "token", "api_key", "private_key", "authorization", "cookie", "credential", "client_secret"].contains(where: normalized.contains)
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool { needles.contains(where: value.contains) }
    private static func humanized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ").capitalized
    }
    private static func title(for kind: ToolCardKind, fallback: String) -> String {
        switch kind {
        case .connector: l10n("Connector Activity")
        case .email: l10n("Email")
        case .permission: l10n("Permission Request")
        case .secret: l10n("Protected Credential")
        case .automation: l10n("Automation")
        case .cloudAgent: l10n("Cloud Agent")
        case .generic: fallback
        }
    }
    private static func symbol(for kind: ToolCardKind) -> String {
        switch kind {
        case .connector: "link"
        case .email: "envelope"
        case .permission: "hand.raised"
        case .secret: "key"
        case .automation: "clock.arrow.circlepath"
        case .cloudAgent: "cloud"
        case .generic: "wrench.and.screwdriver"
        }
    }
}
