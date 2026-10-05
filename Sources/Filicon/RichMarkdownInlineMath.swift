import Foundation
import SwiftUI
import FiliconRichContent

/// Only escaped, host-generated Markdown HTML and verified engine markup enter WebKit.
/// This is a presentation value, not a browser or an agent navigation capability.
struct RichMarkdownInlineContent: Sendable, Equatable {
    let html: String
    let allowedLinks: Set<URL>

    @MainActor static func prose(paragraphs: [RichMarkdownProseLayout.Paragraph], formulas: [MarkdownInlineMath.Formula]) -> Self? {
        var builder = Builder(formulas: formulas)
        var html = ""
        for paragraph in paragraphs {
            let tag = paragraph.headerLevel.map { "h\(min(max($0, 1), 6))" } ?? "p"
            let gap = paragraph.separator == "\n" ? 4 : paragraph.separator == "\n\n" ? 12 : 0
            var prefix = "<span class=\"prose-marker\" aria-hidden=\"true\">\(escape(paragraph.prefix))</span>"
            if let checked = paragraph.isTaskChecked {
                prefix += "<span role=\"checkbox\" aria-checked=\"\(checked)\" aria-disabled=\"true\" aria-label=\"\(escape(l10n("Task status")))\" title=\"\(escape(l10n("Status from the message; this checkbox cannot be changed.")))\">\(checked ? "☑" : "☐")</span> "
            }
            html += "<\(tag) class=\"prose-paragraph\" style=\"margin-top:\(gap)px\">\(prefix)\(builder.html(paragraph.content))</\(tag)>"
            guard html.utf8.count <= 2_097_152 else { return nil }
        }
        return .init(html: html, allowedLinks: builder.allowedLinks)
    }

    @MainActor static func table(_ table: MarkdownTable) -> Self? {
        let cells = table.headers + table.rows.flatMap { $0 }
        guard cells.count <= 2_048, cells.reduce(0, { $0 + $1.utf8.count }) <= 262_144 else { return nil }
        let protected = cells.map(MarkdownInlineMath.protect)
        let count = protected.reduce(0) { $0 + ($1?.formulas.count ?? 0) }
        guard count > 0, count <= 128 else { return nil }
        var allowedLinks: Set<URL> = [], contents: [String] = []
        var bytes = 0
        for (index, cell) in cells.enumerated() {
            let plan = protected[index]
            var builder = Builder(formulas: plan?.formulas ?? [])
            let html = builder.html(RichMarkdownTableCellLayout.make(plan?.markdown ?? cell))
            bytes += html.utf8.count
            guard bytes <= 2_097_152 else { return nil }
            contents.append(html); allowedLinks.formUnion(builder.allowedLinks)
        }
        let headers = contents.prefix(table.headers.count).map { "<th>\($0)</th>" }.joined()
        var rows = "", offset = table.headers.count
        for row in table.rows {
            rows += "<tr>" + contents[offset..<(offset + row.count)].map { "<td>\($0)</td>" }.joined() + "</tr>"
            offset += row.count
        }
        let html = "<table><thead><tr>\(headers)</tr></thead><tbody>\(rows)</tbody></table>"
        guard html.utf8.count <= 2_097_152 else { return nil }
        return .init(html: html, allowedLinks: allowedLinks)
    }

    /// Literal fallback/test projection restores TeX after parsing, not before.
    /// TeX-looking links or Markdown commands inside a formula stay plain text.
    static func literal(_ value: AttributedString, formulas: [MarkdownInlineMath.Formula]) -> AttributedString {
        guard !formulas.isEmpty else { return value }
        var result = AttributedString()
        for run in value.runs {
            var text = String(value[run.range].characters)
            for formula in formulas { text = text.replacingOccurrences(of: formula.token, with: formula.source) }
            result.append(AttributedString(text, attributes: run.attributes))
        }
        return result
    }

    private struct Builder {
        let formulas: [MarkdownInlineMath.Formula]
        var allowedLinks: Set<URL> = []
        var formulaMarkup: [String: String] = [:]
        var formulaBytes = 0

        mutating func html(_ value: AttributedString) -> String {
            var result = ""
            for run in value.runs {
                var text = htmlText(String(value[run.range].characters))
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.code) { text = "<code>\(text)</code>" }
                    if intent.contains(.strikethrough) { text = "<del>\(text)</del>" }
                    if intent.contains(.emphasized) { text = "<em>\(text)</em>" }
                    if intent.contains(.stronglyEmphasized) { text = "<strong>\(text)</strong>" }
                }
                if let url = run.link, Self.accepts(url) {
                    allowedLinks.insert(url)
                    let reference = url.scheme?.lowercased() == "sand-msg" ? " class=\"message-reference\"" : ""
                    text = "<a\(reference) href=\"\(RichMarkdownInlineContent.escape(url.absoluteString))\">\(text)</a>"
                }
                result += text
            }
            return result
        }

        private static let tokenPattern = try? NSRegularExpression(pattern: #"FILICONINLINEFORMULA[0-9]+N[0-9]+END"#)

        /// Locate tokens only in the protected original run. A macro may itself
        /// generate token-looking text, but rendered HTML must never be scanned
        /// again or interpreted as another formula placeholder.
        private mutating func htmlText(_ source: String) -> String {
            guard !formulas.isEmpty, let pattern = Self.tokenPattern else { return RichMarkdownInlineContent.escape(source) }
            var result = "", cursor = source.startIndex
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)) {
                guard let range = Range(match.range, in: source),
                      let formula = formulas.first(where: { $0.token == source[range] }) else { continue }
                result += RichMarkdownInlineContent.escape(String(source[cursor..<range.lowerBound])) + markup(formula)
                cursor = range.upperBound
            }
            return result + RichMarkdownInlineContent.escape(String(source[cursor...]))
        }

        private mutating func markup(_ formula: MarkdownInlineMath.Formula) -> String {
            if let cached = formulaMarkup[formula.token] { return cached }
            let markup: String
            if case .rendered(let rendered) = OfflineMathPresenter().presentation(for: formula.source, mode: .inline),
               formulaBytes + rendered.html.utf8.count <= 2_097_152 {
                markup = "<span class=\"inline-math\">\(rendered.html)</span>"
            } else {
                markup = "<code class=\"math-fallback\">\(RichMarkdownInlineContent.escape(formula.source))</code>"
            }
            formulaMarkup[formula.token] = markup; formulaBytes += markup.utf8.count
            return markup
        }

        private static func accepts(_ url: URL) -> Bool {
            // A sand-msg attribute only survives the prose host's explicit resolver.
            // Table cell attributes have already rejected this scheme.
            if url.scheme?.lowercased() == "sand-msg" { return true }
            return ["http", "https"].contains(url.scheme?.lowercased() ?? "") && {
                if case .allowed = TranscriptLinkPolicy.decision(for: url) { return true }; return false
            }()
        }
    }

    private static func escape(_ source: String) -> String {
        source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

struct RichMarkdownInlineMathView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var uiLocale
    let content: RichMarkdownInlineContent
    let openLink: @MainActor (URL) -> Bool
    @State private var measuredHeight: Double = 32

    var body: some View {
        let _ = uiLocale.identifier
        OfflineMathWebView(content: content, dark: colorScheme == .dark, openLink: openLink, measured: updateHeight)
            .frame(maxWidth: .infinity).frame(height: measuredHeight)
    }

    private func updateHeight(_ height: Double) {
        if abs(measuredHeight - height) > 0.5 { measuredHeight = height }
    }
}

extension OfflineMathWebPolicy {
    static func document(content: RichMarkdownInlineContent, dark: Bool) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>\(OfflineMathPresenter.stylesheet ?? "")
        html,body{margin:0;padding:0;background:transparent;color:\(dark ? "#f7f0de" : "#2e2921");font-family:-apple-system,system-ui;font-size:13px;line-height:1.5}
        body{padding:4px;overflow:auto}
        #math-content{display:block;overflow-wrap:anywhere}
        .prose-paragraph{margin:0;white-space:pre-wrap}
        h1{font-size:22px}h2{font-size:20px}h3,h4,h5,h6{font-size:15px}
        .inline-math{white-space:normal;display:inline}
        a{color:inherit;text-decoration:underline;cursor:pointer}
        .message-reference{color:AccentColor;background:rgba(127,127,127,.14);font-weight:600;border-radius:2px;text-decoration:none}
        code{font-family:ui-monospace,monospace;background:rgba(127,127,127,.12);border-radius:3px}
        table{border-collapse:collapse;white-space:pre-wrap;min-width:100%}
        th,td{text-align:left;padding:4px 7px;vertical-align:baseline}
        th{border-bottom:1px solid rgba(127,127,127,.3)}
        </style></head><body><div id="math-content">\(content.html)</div></body></html>
        """
    }
}
