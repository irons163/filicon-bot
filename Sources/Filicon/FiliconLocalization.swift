import Foundation

enum FiliconLocalization {
    static let preferenceKey = "FiliconPreferredLanguage"
    @TaskLocal static var languageOverride: String?

    // NSCache's accessors are thread-safe; cache values are immutable Bundles.
    nonisolated(unsafe) private static let bundles = NSCache<NSString, Bundle>()

    static func localizedBundle() -> Bundle? {
        if let languageOverride { return bundle(for: languageOverride) ?? bundle(for: "en") }
        let rawValue = UserDefaults.standard.string(forKey: preferenceKey) ?? AppLanguage.system.rawValue
        let language = (AppLanguage(rawValue: rawValue) ?? .system).locale.identifier
        return bundle(for: language) ?? bundle(for: "en")
    }

    static func string(_ key: String, language: String? = nil) -> String {
        let selected = language.map { bundle(for: $0) ?? bundle(for: "en") } ?? localizedBundle()
        guard let selected else { return key }
        let direct = selected.localizedString(forKey: key, value: key, table: nil)
        if direct != key { return direct }
        // Persisted enum identifiers stay unchanged; only their display label
        // uses an existing catalog entry (e.g. queued → Queued).
        if !key.contains(" "), key.first?.isLowercase == true {
            let words = key.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            for candidate in [words.capitalized, key.capitalized] {
                let translated = selected.localizedString(forKey: candidate, value: key, table: nil)
                if translated != key { return translated }
            }
        }
        return direct
    }

    /// Translate app-authored errors received from the non-UI modules. Unknown
    /// provider/OS diagnostics remain intact rather than being guessed at.
    static func message(_ text: String) -> String {
        let exact = string(text)
        if exact != text { return exact }
        for (key, expression) in errorTemplates {
            let range = NSRange(text.startIndex..., in: text)
            guard let match = expression.firstMatch(in: text, range: range) else { continue }
            let source = text as NSString
            let arguments = (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
            return render(LocalizedText(key: key, arguments: arguments))
        }
        return text
    }

    private static let errorTemplates: [(String, NSRegularExpression)] = {
        guard let url = bundle(for: "en")?.url(forResource: "Localizable", withExtension: "strings"),
              let data = try? Data(contentsOf: url),
              let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [] }
        return table.keys.sorted { $0.count > $1.count }.compactMap { key in
            let pieces = key.components(separatedBy: try! NSRegularExpression(pattern: #"\{\d+\}"#))
            guard pieces.count > 1, pieces.joined().filter(\.isLetter).count >= 15 else { return nil }
            let pattern = "^" + pieces.map(NSRegularExpression.escapedPattern).joined(separator: "(.*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
            return (key, regex)
        }
    }()

    static func render(_ value: LocalizedText, language: String? = nil) -> String {
        let template = string(value.key, language: language)
        // Replace placeholders in a single pass: inserted user content must never
        // be interpreted as another placeholder or localization key.
        let regex = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
        let source = template as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: template, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let index = Int(source.substring(with: match.range(at: 1)))!
            result += value.arguments.indices.contains(index) ? value.arguments[index] : source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    private static func bundle(for language: String) -> Bundle? {
        if let cached = bundles.object(forKey: language as NSString) { return cached }
        let result = resourceRoots().lazy.compactMap { root in
            localizedDirectory(in: root, language: language).flatMap(Bundle.init(path:))
        }.first
        if let result { bundles.setObject(result, forKey: language as NSString) }
        return result
    }

    private static func resourceRoots() -> [URL] {
        var roots: [URL] = []

        // Xcode launches SwiftPM executable targets with the resource bundle
        // supplied explicitly.  In that launch mode `Bundle.main` describes
        // the bare executable rather than an app bundle, so consult the same
        // override used by SwiftPM's generated `Bundle.module` accessor first.
        // This also keeps Debug launches independent of Xcode's DerivedData
        // directory layout.
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? environment["PACKAGE_RESOURCE_BUNDLE_URL"]
        {
            appendResourceRoots(for: URL(fileURLWithPath: override), to: &roots)
        }

        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        if let executableURL = Bundle.main.executableURL {
            let resourceBundleURL = executableURL.deletingLastPathComponent().appending(path: "Filicon_Filicon.bundle")
            appendResourceRoots(for: resourceBundleURL, to: &roots)
        }
        // XCTest's main executable belongs to Xcode, not this package. Locate
        // resources beside the bundle containing our code without hard-coding
        // a developer's build directory or invoking Bundle.module's fatal path.
        let codeBundle = Bundle(for: LocalizationResourceAnchor.self)
        appendResourceRoots(
            for: codeBundle.bundleURL.deletingLastPathComponent().appending(path: "Filicon_Filicon.bundle"),
            to: &roots
        )
        return roots
    }

    private static func appendResourceRoots(for bundleURL: URL, to roots: inout [URL]) {
        roots.append(bundleURL)
        if let resourceURL = Bundle(url: bundleURL)?.resourceURL {
            roots.append(resourceURL)
        }
    }

    private static func localizedDirectory(in root: URL, language: String) -> String? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }
        let expected = language.replacingOccurrences(of: "_", with: "-").lowercased() + ".lproj"
        return entries.first { $0.lastPathComponent.lowercased() == expected }?.path
    }
}

private final class LocalizationResourceAnchor: NSObject {}

/// Interpolation is captured before lookup, so translated sentences can reorder
/// values without translating user names, messages, paths, or remote content.
struct LocalizedText: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    let arguments: [String]

    init(key: String, arguments: [String]) {
        self.key = key
        self.arguments = arguments
    }

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{\(arguments.count)}"
            arguments.append(String(describing: value))
        }
        mutating func appendInterpolation(_ value: Double, specifier: String) {
            appendInterpolation(String(format: specifier, locale: localizedLocale, value))
        }
        mutating func appendInterpolation<F: FormatStyle>(_ value: F.FormatInput, format: F) where F.FormatOutput == String {
            appendInterpolation(format.locale(localizedLocale).format(value))
        }
        private var localizedLocale: Locale {
            let raw = UserDefaults.standard.string(forKey: FiliconLocalization.preferenceKey) ?? "system"
            return (AppLanguage(rawValue: raw) ?? .system).locale
        }
    }
}

func l10n(_ value: LocalizedText) -> String {
    FiliconLocalization.render(value)
}

private extension String {
    func components(separatedBy expression: NSRegularExpression) -> [String] {
        let source = self as NSString
        var cursor = 0
        var result: [String] = []
        for match in expression.matches(in: self, range: NSRange(location: 0, length: source.length)) {
            result.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = NSMaxRange(match.range)
        }
        result.append(source.substring(from: cursor))
        return result
    }
}
