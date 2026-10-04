import CryptoKit
import Foundation
import JavaScriptCore

public struct KaTeXMarkup: Sendable, Equatable {
    /// Engine-produced HTML and accessible MathML. This is not arbitrary user HTML.
    public let html: String
    public let hadParseError: Bool
}

public enum MathPresentation: Sendable, Equatable {
    case rendered(KaTeXMarkup)
    case fallback(original: String)
}

public struct OfflineMathPresenter: Sendable {
    public init() {}
    /// The pinned stylesheet embeds all 20 fonts as data, never a file or network URL.
    public static var stylesheet: String? { KaTeXAssets.loaded?.stylesheet }
    public static let engineVersion = "0.16.45"

    public func presentation(for source: String, mode: MathMode) -> MathPresentation {
        guard Self.accepts(source), let markup = KaTeXRuntime.shared.render(source, display: mode == .display)
        else { return .fallback(original: source) }
        return .rendered(markup)
    }

    private static func accepts(_ source: String) -> Bool {
        guard source.utf8.count <= 16_384, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0) && !["\n", "\r", "\t"].contains($0)
              }) else { return false }
        // A resource bound, not a replacement TeX grammar. Escaped braces are literals.
        var depth = 0
        var escaped = false
        for character in source {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "{" { depth += 1; if depth > 128 { return false } }
            if character == "}" { depth = max(0, depth - 1) }
        }
        return true
    }
}

/// One serialized JavaScriptCore VM evaluates only the verified bundled engine.
/// No source is interpolated into JavaScript; TeX is an ordinary function argument.
/// Each render gets a fresh macro namespace, including after a parse error.
final class KaTeXRuntime: @unchecked Sendable {
    static let shared = KaTeXRuntime(script: KaTeXAssets.loaded?.script)
    private let lock = NSLock()
    private let context: JSContext?
    private let function: JSValue?
    private struct Key: Hashable { let source: String; let display: Bool }
    private enum Entry {
        case rendered(KaTeXMarkup)
        case failed
        var markup: KaTeXMarkup? { if case .rendered(let value) = self { value } else { nil } }
        var byteCount: Int { markup?.html.utf8.count ?? 0 }
    }
    struct CacheState: Sendable, Equatable { let entries: Int; let bytes: Int }
    var cacheState: CacheState {
        lock.lock(); defer { lock.unlock() }
        return .init(entries: order.count, bytes: cacheBytes)
    }
    private var cache: [Key: Entry] = [:]
    private var order: [Key] = []
    private var cacheBytes = 0

    init(script: String?) {
        guard let script, let context = JSContext() else { self.context = nil; function = nil; return }
        context.evaluateScript(script)
        guard context.exception == nil,
              context.objectForKeyedSubscript("katex")?.objectForKeyedSubscript("version")?.toString() == OfflineMathPresenter.engineVersion
        else { self.context = nil; function = nil; return }
        let function = context.evaluateScript(Self.renderFunction)
        guard context.exception == nil, let function, !function.isUndefined, !function.isNull
        else { self.context = nil; self.function = nil; return }
        self.context = context
        self.function = function
    }

    func render(_ source: String, display: Bool) -> KaTeXMarkup? {
        lock.lock(); defer { lock.unlock() }
        let key = Key(source: source, display: display)
        if let cached = cache[key] { return cached.markup }
        let entry = evaluate(source, display: display).map(Entry.rendered) ?? .failed
        let bytes = source.utf8.count + entry.byteCount
        guard bytes <= 8_388_608 else { return entry.markup }
        while !order.isEmpty && (order.count >= 128 || cacheBytes + bytes > 8_388_608) {
            let oldest = order.removeFirst()
            if let removed = cache.removeValue(forKey: oldest) { cacheBytes -= oldest.source.utf8.count + removed.byteCount }
        }
        // Cache failures too: a rejected large formula must not repeatedly block
        // the chat's redraws. Entries remain bounded by both count and bytes.
        cache[key] = entry; order.append(key); cacheBytes += bytes
        return entry.markup
    }

    private func evaluate(_ source: String, display: Bool) -> KaTeXMarkup? {
        guard let context, let function else { return nil }
        context.exception = nil
        guard let value = function.call(withArguments: [source, display]), context.exception == nil,
              let result = value.toDictionary(), let html = result["html"] as? String,
              !html.isEmpty, html.utf8.count <= 1_048_576,
              let hadError = result["hadParseError"] as? Bool else { return nil }
        return KaTeXMarkup(html: html, hadParseError: hadError)
    }

    private static let renderFunction = #"""
    (function(source, display) {
      let untrusted = false;
      const options = {displayMode:display, output:'htmlAndMathml', throwOnError:true,
        strict:'ignore', maxSize:20, maxExpand:1000, macros:{},
        trust:function() { untrusted = true; return false; }};
      let html, hadParseError = false;
      try { html = katex.renderToString(source, options); }
      catch (error) {
        // Match the reference's tolerant second pass, without swallowing resource errors.
        if (!(error instanceof katex.ParseError)) return null;
        hadParseError = true;
        options.throwOnError = false;
        options.macros = {};
        try { html = katex.renderToString(source, options); } catch (_) { return null; }
      }
      if (untrusted || typeof html !== 'string' || html.length > 1048576) return null;
      return {html:html, hadParseError:hadParseError};
    })
    """#
}

struct KaTeXAssets: Sendable {
    let script: String
    let stylesheet: String
    static let loaded: Self? = load()

    private static func load() -> Self? {
        // Packaged SwiftPM apps put this in Contents/Resources; native Xcode and
        // unit tests use SwiftPM's generated bundle. No user-selected path is read.
        // Do not access Bundle.module here: its generated accessor traps when a
        // bundle is missing. A damaged install must keep the original formula.
        return load(searchRoots: [Bundle.main.resourceURL, Bundle(for: KaTeXBundleFinder.self).resourceURL,
                                  Bundle.main.bundleURL].compactMap { $0 })
    }

    static func load(searchRoots: [URL]) -> Self? {
        for candidate in searchRoots {
            let url = candidate.appendingPathComponent("Filicon_FiliconRichContent.bundle")
            if isSymbolicLink(url) { return nil }
            guard let bundle = Bundle(url: url) else { continue }
            guard let root = bundle.url(forResource: "KaTeX", withExtension: nil) else { return nil }
            // An existing but damaged bundle fails closed; do not borrow assets
            // from another installation or a user-selected directory.
            return load(root: root)
        }
        return nil
    }

    static func load(root: URL) -> Self? {
        guard !isSymbolicLink(root), !isSymbolicLink(root.appendingPathComponent("manifest.json")),
              let manifest = try? Data(contentsOf: root.appendingPathComponent("manifest.json")),
              SHA256.hash(data: manifest).map({ String(format: "%02x", $0) }).joined() == "d4b959a788c2804d10b996b32be1eaf83f997eaf917b4a7767e0aaf26d6a7ee9",
              let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["version"] as? String == OfflineMathPresenter.engineVersion,
              let files = object["files"] as? [String: [String: Any]], files.count == 23 else { return nil }
        var data: [String: Data] = [:]
        for (path, metadata) in files {
            guard path == "LICENSE" || path == "katex.min.js" || path == "katex.min.css" ||
                    (path.hasPrefix("fonts/KaTeX_") && path.hasSuffix(".woff2") && !path.dropFirst(6).contains("/")),
                  !path.contains(".."), !isSymbolicLink(root.appendingPathComponent(path)),
                  !isSymbolicLink(root.appendingPathComponent(path).deletingLastPathComponent()),
                  let bytes = try? Data(contentsOf: root.appendingPathComponent(path)),
                  bytes.count == metadata["bytes"] as? Int,
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == metadata["sha256"] as? String
            else { return nil }
            data[path] = bytes
        }
        guard let scriptData = data["katex.min.js"], let script = String(data: scriptData, encoding: .utf8),
              let cssData = data["katex.min.css"], var css = String(data: cssData, encoding: .utf8), data["LICENSE"] != nil,
              let pattern = try? NSRegularExpression(pattern: #"src:url\(fonts/([A-Za-z0-9_-]+)\.woff2\) format\("woff2"\),url\(fonts/\1\.woff\) format\("woff"\),url\(fonts/\1\.ttf\) format\("truetype"\)"#)
        else { return nil }
        let matches = pattern.matches(in: css, range: NSRange(css.startIndex..<css.endIndex, in: css))
        guard matches.count == 20 else { return nil }
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: css), let range = Range(match.range, in: css),
                  let font = data["fonts/\(css[nameRange]).woff2"] else { return nil }
            css.replaceSubrange(range, with: "src:url(data:font/woff2;base64,\(font.base64EncodedString())) format(\"woff2\")")
        }
        guard !css.contains("url(fonts/") else { return nil }
        return .init(script: script, stylesheet: css)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}

private final class KaTeXBundleFinder {}
