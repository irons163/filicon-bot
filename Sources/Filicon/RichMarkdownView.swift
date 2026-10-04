import AppKit
import Foundation
import SwiftUI
import WebKit
import FiliconRichContent

enum RichMarkdownProjectedBlock: Sendable, Equatable {
    case prose(String)
    case code(language: String?, source: String, isTerminated: Bool)
    case table(MarkdownTable)
    case math(source: String, mode: MathMode, presentation: MathPresentation)
    case mermaid(source: String, presentation: MermaidPresentation)
}

struct RichMarkdownProjection: Sendable, Equatable {
    let blocks: [RichMarkdownProjectedBlock]

    static func make(source: String) -> Self {
        let presenter = OfflineMathPresenter()
        return .init(blocks: RichMarkdownParser().parse(source).map { block in
            switch block {
            case .prose(let value): .prose(value)
            case .code(let language, let source, let terminated): .code(language: language, source: source, isTerminated: terminated)
            case .table(let table): .table(table)
            case .math(let source, let mode): .math(source: source, mode: mode, presentation: presenter.presentation(for: source, mode: mode))
            case .mermaid(let source, let presentation): .mermaid(source: source, presentation: presentation)
            }
        })
    }

    func safeHTTPLinks(maximum: Int) -> [URL] {
        guard maximum > 0 else { return [] }
        var seen = Set<String>()
        var result: [URL] = []
        for block in blocks {
            guard case .prose(let source) = block,
                  let attributed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full)) else { continue }
            for run in attributed.runs {
                guard let url = run.link, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      case .allowed(let safeURL) = TranscriptLinkPolicy.decision(for: url),
                      seen.insert(safeURL.absoluteString).inserted else { continue }
                result.append(safeURL)
                if result.count == maximum { return result }
            }
            // Foundation's Markdown parser intentionally leaves autolink-like bare URLs as
            // plain text. Detect those only inside prose blocks (never code/math/diagrams).
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let scanSource = source.replacingOccurrences(
                    of: #"`+[^`\n]*`+"#, with: " ", options: .regularExpression
                )
                let range = NSRange(scanSource.startIndex..<scanSource.endIndex, in: scanSource)
                for match in detector.matches(in: scanSource, range: range) {
                    guard let url = match.url,
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          case .allowed(let safeURL) = TranscriptLinkPolicy.decision(for: url),
                          seen.insert(safeURL.absoluteString).inserted else { continue }
                    result.append(safeURL)
                    if result.count == maximum { return result }
                }
            }
        }
        return result
    }
}

/// One process-wide production client shares its bounded cache and in-flight fetches across
/// transcript renderers. Individual SwiftUI `.task`s still cancel with their message view.
enum AppRichLinkMetadata {
    static let productionClient = SafeLinkMetadataClient.production()
    static let productionController = RichLinkMetadataController(client: productionClient)
}

struct RichLinkMetadataController: Sendable {
    let load: @Sendable (URL) async throws -> SafeLinkMetadata

    init(load: @escaping @Sendable (URL) async throws -> SafeLinkMetadata) { self.load = load }
    init(client: SafeLinkMetadataClient) {
        self.load = { try await client.metadata(for: $0) }
    }
}

struct MermaidNativePoint: Sendable, Equatable {
    let x: Double
    let y: Double
}

struct MermaidNativeNode: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let position: MermaidNativePoint
}

struct MermaidNativeEdge: Sendable, Equatable {
    let from: MermaidNativePoint
    let to: MermaidNativePoint
    let label: String?
}

struct MermaidNativeLayout: Sendable, Equatable {
    let kind: MermaidDiagramKind
    let nodes: [MermaidNativeNode]
    let edges: [MermaidNativeEdge]

    static func project(_ diagram: MermaidDiagram) -> Self {
        switch diagram.kind {
        case .sequence:
            let count = max(diagram.nodes.count, 1)
            let nodes = diagram.nodes.enumerated().map { index, node in
                MermaidNativeNode(id: node.id, label: node.label, position: .init(x: Double(index + 1) / Double(count + 1), y: 0.12))
            }
            let points = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
            let edgeCount = max(diagram.edges.count, 1)
            let edges = diagram.edges.enumerated().compactMap { index, edge -> MermaidNativeEdge? in
                guard let from = points[edge.from], let to = points[edge.to] else { return nil }
                let y = 0.30 + (Double(index) / Double(edgeCount)) * 0.55
                return .init(from: .init(x: from.x, y: y), to: .init(x: to.x, y: y), label: edge.label)
            }
            return .init(kind: diagram.kind, nodes: nodes, edges: edges)
        case .flowchart, .state:
            let columns = min(max(diagram.nodes.count, 1), 3)
            let rows = Int(ceil(Double(max(diagram.nodes.count, 1)) / Double(columns)))
            let nodes = diagram.nodes.enumerated().map { index, node in
                MermaidNativeNode(
                    id: node.id,
                    label: node.id == "__state_boundary" ? "●" : node.label,
                    position: .init(x: Double(index % columns + 1) / Double(columns + 1), y: Double(index / columns + 1) / Double(rows + 1))
                )
            }
            let points = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.position) })
            let edges = diagram.edges.compactMap { edge -> MermaidNativeEdge? in
                guard let from = points[edge.from], let to = points[edge.to] else { return nil }
                return .init(from: from, to: to, label: edge.label)
            }
            return .init(kind: diagram.kind, nodes: nodes, edges: edges)
        }
    }
}

/// An explicit, in-memory navigation capability. Other Markdown surfaces have none.
@MainActor struct RichMarkdownMessageReferences {
    let target: (URL) -> UUID?
    let show: (UUID) -> Void
}

/// Foundation preserves block structure as presentation intents, not characters.
/// SwiftUI Text needs explicit separators/markers; parse the whole prose first so
/// reference-style links, inline formatting and hard breaks keep their meaning.
enum RichMarkdownProseLayout {
    static func make(_ source: String) -> AttributedString? {
        paragraphs(source).map(join)
    }

    struct Paragraph: Sendable, Equatable {
        let separator: String
        let prefix: String
        let isTaskChecked: Bool?
        var content: AttributedString
    }

    static func join(_ paragraphs: [Paragraph]) -> AttributedString {
        var result = AttributedString()
        for paragraph in paragraphs {
            result.append(AttributedString(paragraph.separator + paragraph.prefix))
            if let checked = paragraph.isTaskChecked {
                result.append(AttributedString(checked ? "☑ " : "☐ "))
            }
            result.append(paragraph.content)
        }
        return result
    }

    static func paragraphs(_ source: String) -> [Paragraph]? {
        guard let parsed = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, appliesSourcePositionAttributes: true)) else { return nil }
        var result: [Paragraph] = []
        var previous: Context?
        var seenItems: Set<Int> = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let context = Context(components: intent?.components ?? [])
            var separator = ""
            if let previous {
                let adjacentItems = context.itemID != previous.itemID && !context.listIDs.isDisjoint(with: previous.listIDs)
                separator = adjacentItems ? "\n" : "\n\n"
            }
            var prefix = String(repeating: "› ", count: context.quoteDepth)
            var firstItemParagraph = false
            if let itemID = context.itemID {
                firstItemParagraph = seenItems.insert(itemID).inserted
                prefix += String(repeating: "  ", count: max(context.listIDs.count - 1, 0))
                prefix += firstItemParagraph ? context.marker : String(repeating: " ", count: context.marker.count)
            }
            var piece = AttributedString(parsed[range])
            let task = firstItemParagraph ? taskMarker(in: piece, source: source) : nil
            if task != nil {
                let end = piece.characters.index(piece.startIndex, offsetBy: 3)
                piece.removeSubrange(piece.startIndex..<end)
                while piece.characters.first == " " || piece.characters.first == "\t" {
                    piece.removeSubrange(piece.startIndex..<piece.characters.index(after: piece.startIndex))
                }
            }
            if let level = context.headerLevel {
                piece.font = level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline
            }
            // Keep status and synthetic markers separate from the author's attributes.
            result.append(.init(separator: separator, prefix: prefix, isTaskChecked: task, content: piece))
            previous = context
        }
        return result
    }

    private static func taskMarker(in piece: AttributedString, source: String) -> Bool? {
        guard let first = piece.runs.first, first.link == nil, first.inlinePresentationIntent == nil,
              let position = first.markdownSourcePosition, let range = Range(position, in: source) else { return nil }
        // Parsed text alone cannot distinguish a task from an escaped/code/emphasized
        // '[x]'. Require the literal, unformatted source marker of the first paragraph.
        let raw = source[range]
        let marker = String(raw.prefix(3))
        guard ["[ ]", "[x]", "[X]"].contains(marker), raw.count > 3,
              raw.dropFirst(3).first == " " || raw.dropFirst(3).first == "\t",
              String(piece.characters.prefix(3)) == marker,
              piece.characters.dropFirst(3).contains(where: { !$0.isWhitespace }) else { return nil }
        return marker != "[ ]"
    }

    private struct Context {
        let components: [PresentationIntent.IntentType]
        var listIDs: Set<Int> {
            Set(components.compactMap {
                switch $0.kind {
                case .orderedList, .unorderedList: $0.identity
                default: nil
                }
            })
        }
        var itemID: Int? {
            components.first { if case .listItem = $0.kind { true } else { false } }?.identity
        }
        var marker: String {
            guard let index = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
                  case .listItem(let ordinal) = components[index].kind else { return "" }
            for parent in components.dropFirst(index + 1) {
                switch parent.kind {
                case .orderedList: return "\(ordinal). "
                case .unorderedList: return "• "
                default: continue
                }
            }
            return ""
        }
        var quoteDepth: Int { components.filter { $0.kind == .blockQuote }.count }
        var headerLevel: Int? {
            for component in components { if case .header(let level) = component.kind { return level } }
            return nil
        }
    }
}

/// Table cells are inline Markdown, never a second block parser or a resource loader.
/// No transcript navigation capability is inherited by a table cell.
enum RichMarkdownTableCellLayout {
    static func make(_ source: String) -> AttributedString {
        guard var value = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(source) }
        let blocked = value.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  case .allowed = TranscriptLinkPolicy.decision(for: url) else { return run.range }
            return nil
        }
        for range in blocked { value[range].link = nil }
        return value
    }
}

struct RichMarkdownView: View {
    @Environment(\.locale) private var uiLocale
    let source: String
    let metadataController: RichLinkMetadataController?
    let maximumMetadataCards: Int
    let fillsWidth: Bool
    let openLink: @MainActor (URL) -> Bool
    let messageReferences: RichMarkdownMessageReferences?

    @State private var metadata: [URL: SafeLinkMetadata] = [:]
    private var projection: RichMarkdownProjection { .make(source: source) }

    init(
        source: String,
        metadataController: RichLinkMetadataController? = nil,
        maximumMetadataCards: Int = 0,
        fillsWidth: Bool = true,
        messageReferences: RichMarkdownMessageReferences? = nil,
        openLink: @escaping @MainActor (URL) -> Bool = RichMarkdownDefaultLinkOpener.open
    ) {
        self.source = source
        self.metadataController = metadataController
        self.maximumMetadataCards = min(max(maximumMetadataCards, 0), 3)
        self.fillsWidth = fillsWidth
        self.openLink = openLink
        self.messageReferences = messageReferences
    }

    static func transcript(
        source: String,
        messageReferences: RichMarkdownMessageReferences? = nil,
        openLink: @escaping @MainActor (URL) -> Bool = RichMarkdownDefaultLinkOpener.open
    ) -> Self {
        .init(
            source: source,
            metadataController: AppRichLinkMetadata.productionController,
            maximumMetadataCards: 3,
            fillsWidth: false,
            messageReferences: messageReferences,
            openLink: openLink
        )
    }

    var body: some View {
        let _ = uiLocale.identifier
        let value = projection
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(value.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
            ForEach(value.safeHTTPLinks(maximum: maximumMetadataCards), id: \.absoluteString) { url in
                if let value = metadata[url] { RichLinkMetadataCard(metadata: value, openLink: open) }
            }
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        .textSelection(.enabled)
        .task(id: "\(source.hashValue):\(maximumMetadataCards):\(metadataController != nil)") {
            metadata = [:]
            guard let metadataController, maximumMetadataCards > 0 else { return }
            for url in value.safeHTTPLinks(maximum: maximumMetadataCards) {
                guard !Task.isCancelled else { return }
                if let loaded = try? await metadataController.load(url) {
                    guard !Task.isCancelled else { return }
                    metadata[url] = loaded
                }
            }
        }
    }

    @ViewBuilder private func blockView(_ block: RichMarkdownProjectedBlock) -> some View {
        switch block {
        case .prose(let prose):
            Group {
                if let paragraphs = attributedProseParagraphs(prose) {
                    if paragraphs.contains(where: { $0.isTaskChecked != nil }) {
                        RichMarkdownTaskListView(paragraphs: paragraphs)
                    } else {
                        Text(RichMarkdownProseLayout.join(paragraphs)).accessibilityLabel(prose)
                    }
                }
                else { Text(prose) }
            }
            .environment(\.openURL, OpenURLAction { open($0) ? .handled : .discarded })
        case .code(let language, let source, let terminated):
            RichCodeBlock(language: language, source: source, isTerminated: terminated)
        case .table(let table):
            RichMarkdownTableView(table: table, openLink: open)
        case .math(let source, let mode, let presentation):
            OfflineMathView(source: source, mode: mode, presentation: presentation)
        case .mermaid(let source, let presentation):
            NativeMermaidView(source: source, presentation: presentation)
        }
    }

    func attributedProse(_ prose: String) -> AttributedString? {
        attributedProseParagraphs(prose).map(RichMarkdownProseLayout.join)
    }

    private func attributedProseParagraphs(_ prose: String) -> [RichMarkdownProseLayout.Paragraph]? {
        guard var paragraphs = RichMarkdownProseLayout.paragraphs(prose) else { return nil }
        for index in paragraphs.indices {
            paragraphs[index].content = attributedReferences(paragraphs[index].content)
        }
        return paragraphs
    }

    private func attributedReferences(_ value: AttributedString) -> AttributedString {
        var attributed = value
        // Only host-resolved message links get the inline reference treatment.
        // An unavailable address keeps its author's label, never a tappable chip.
        let references = attributed.runs.compactMap { run -> (Range<AttributedString.Index>, Bool)? in
            guard let url = run.link, url.scheme?.lowercased() == "sand-msg" else { return nil }
            return (run.range, messageReferences?.target(url) != nil)
        }
        for (range, available) in references {
            if available {
                attributed[range].foregroundColor = Color.accentColor
                attributed[range].backgroundColor = Color.accentColor.opacity(0.14)
                attributed[range].font = .system(.callout, design: .rounded).weight(.semibold)
                attributed[range].underlineStyle = nil
            } else {
                attributed[range].link = nil
            }
        }
        return attributed
    }

    func open(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "sand-msg" {
            guard let messageReferences, let id = messageReferences.target(url) else { return false }
            messageReferences.show(id)
            return true
        }
        guard case .allowed(let safeURL) = TranscriptLinkPolicy.decision(for: url) else { return false }
        return openLink(safeURL)
    }
}

@MainActor private enum RichMarkdownDefaultLinkOpener {
    static func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
}

private struct RichCodeBlock: View {
    @Environment(\.locale) private var uiLocale
    let language: String?
    let source: String
    let isTerminated: Bool
    @State private var copied = false

    var body: some View {
        let _ = uiLocale.identifier
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.isEmpty == false ? language! : l10n("Code")).font(.caption).foregroundStyle(.secondary)
                if !isTerminated { Text(l10n("Unterminated")).font(.caption2).foregroundStyle(.orange) }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(source, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                } label: {
                    Label(copied ? l10n("Copied") : l10n("Copy Code"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain).controlSize(.small)
                .accessibilityHint(l10n("Copies the complete code block"))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(source).font(.system(.callout, design: .monospaced)).padding(9).textSelection(.enabled)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.18)))
        .accessibilityElement(children: .contain)
    }
}

struct RichMarkdownTaskStatus: View {
    let isChecked: Bool
    var statusLabel: String { isChecked ? l10n("Completed") : l10n("Not completed") }

    var body: some View {
        Toggle(l10n("Task status"), isOn: .constant(isChecked))
            .toggleStyle(.checkbox).labelsHidden().disabled(true)
            .fixedSize()
            .accessibilityValue(statusLabel)
            .help(l10n("Status from the message; this checkbox cannot be changed."))
    }
}

private struct RichMarkdownTaskListView: View {
    let paragraphs: [RichMarkdownProseLayout.Paragraph]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                Group {
                    if let checked = paragraph.isTaskChecked {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(verbatim: paragraph.prefix).accessibilityHidden(true)
                            RichMarkdownTaskStatus(isChecked: checked)
                            Text(paragraph.content).fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .contain)
                    } else {
                        Text(AttributedString(paragraph.prefix) + paragraph.content)
                    }
                }
                .padding(.top, paragraph.separator == "\n" ? 4 : paragraph.separator == "\n\n" ? 12 : 0)
            }
        }
    }
}

struct RichMarkdownTableView: View {
    @Environment(\.locale) private var uiLocale
    let table: MarkdownTable
    let openLink: @MainActor (URL) -> Bool
    var body: some View {
        let _ = uiLocale.identifier
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, value in
                        Text(RichMarkdownTableCellLayout.make(value)).font(.callout.bold())
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                            Text(RichMarkdownTableCellLayout.make(value)).font(.callout)
                        }
                    }
                }
            }
            .padding(9)
        }
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .environment(\.openURL, OpenURLAction { open($0) ? .handled : .discarded })
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n("Table with \(table.headers.count) columns and \(table.rows.count) rows"))
    }

    func open(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              case .allowed(let safeURL) = TranscriptLinkPolicy.decision(for: url) else { return false }
        return openLink(safeURL)
    }
}

private struct OfflineMathView: View {
    @Environment(\.locale) private var uiLocale
    let source: String
    let mode: MathMode
    let presentation: MathPresentation
    var body: some View {
        let _ = uiLocale.identifier
        switch presentation {
        case .mathML(let mathML):
            OfflineMathMLView(mathML: mathML, display: mode == .display)
                .frame(maxWidth: mode == .display ? .infinity : 640, minHeight: mode == .display ? 64 : 34, maxHeight: mode == .display ? 96 : 48)
                .accessibilityLabel(l10n("Math: \(source)"))
        case .fallback(let original):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "function").foregroundStyle(.secondary)
                Text(original).font(.system(.callout, design: .monospaced))
            }
            .padding(7).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel(l10n("Math fallback: \(original)"))
        }
    }
}

enum OfflineMathWebPolicy {
    static let contentSecurityPolicy = "default-src 'none'; connect-src 'none'; img-src 'none'; media-src 'none'; font-src 'none'; frame-src 'none'; object-src 'none'; script-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'"

    static func document(mathML: String, display: Bool) -> String {
        let alignment = display ? "center" : "left"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>html,body{margin:0;padding:0;background:transparent;color:CanvasText;overflow:hidden}body{display:flex;align-items:center;justify-content:\(alignment);min-height:100vh}math{font-size:\(display ? "1.2rem" : "1rem")}</style>
        </head><body>\(mathML)</body></html>
        """
    }

    static func allowsNavigation(to url: URL?) -> Bool {
        guard let url else { return true } // The initial in-memory HTML load has no external URL.
        return url.scheme?.lowercased() == "about" && url.absoluteString.lowercased() == "about:blank"
    }
}

private struct OfflineMathMLView: NSViewRepresentable {
    let mathML: String
    let display: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsLinkPreview = false
        webView.isInspectable = false
        webView.enclosingScrollView?.hasHorizontalScroller = false
        webView.enclosingScrollView?.hasVerticalScroller = false
        load(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let document = OfflineMathWebPolicy.document(mathML: mathML, display: display)
        guard context.coordinator.loadedDocument != document else { return }
        load(webView)
    }

    private func load(_ webView: WKWebView) {
        let document = OfflineMathWebPolicy.document(mathML: mathML, display: display)
        (webView.navigationDelegate as? Coordinator)?.loadedDocument = document
        webView.loadHTMLString(document, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedDocument: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(OfflineMathWebPolicy.allowsNavigation(to: navigationAction.request.url) && navigationAction.shouldPerformDownload == false ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(OfflineMathWebPolicy.allowsNavigation(to: navigationResponse.response.url) && navigationResponse.canShowMIMEType ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel() }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel() }
    }
}

struct NativeMermaidView: View {
    @Environment(\.locale) private var uiLocale
    let source: String
    let presentation: MermaidPresentation
    @State private var model: MermaidFigureModel

    init(source: String, presentation: MermaidPresentation) {
        self.source = source
        self.presentation = presentation
        _model = State(initialValue: MermaidFigureModel(source: source, presentation: presentation))
    }

    var body: some View {
        let _ = uiLocale.identifier
        Group {
            switch presentation {
            case .diagram:
                MermaidDiagramFigure(model: model)
            case .fallback(let original, let reason):
                VStack(alignment: .leading, spacing: 4) {
                    Label(l10n("Diagram shown as source"), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal) { Text(original).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                }
                .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel(l10n("Diagram fallback, \(reason): \(original)"))
            }
        }
        .onChange(of: source) { _, _ in model.messageChanged(source: source, presentation: presentation) }
        .onChange(of: presentation) { _, _ in model.messageChanged(source: source, presentation: presentation) }
        .onDisappear { model.figureRemoved() }
    }
}

struct MermaidEdgesCanvas: View {
    @Environment(\.locale) private var uiLocale
    let layout: MermaidNativeLayout
    var imageSize: CGSize?
    var transform = MermaidViewerTransform()
    var body: some View {
        let _ = uiLocale.identifier
        Canvas { context, size in
            let viewport = size
            let size = imageSize ?? viewport
            context.translateBy(x: (viewport.width - size.width * transform.scale) / 2 + transform.x,
                                y: (viewport.height - size.height * transform.scale) / 2 + transform.y)
            context.scaleBy(x: transform.scale, y: transform.scale)
            if layout.kind == .sequence {
                for node in layout.nodes {
                    var line = Path(); let x = size.width * node.position.x
                    line.move(to: .init(x: x, y: size.height * 0.19)); line.addLine(to: .init(x: x, y: size.height * 0.92))
                    context.stroke(line, with: .color(.secondary.opacity(0.35)), style: .init(lineWidth: 1, dash: [4, 4]))
                }
            }
            for edge in layout.edges {
                let start = CGPoint(x: size.width * edge.from.x, y: size.height * edge.from.y)
                let end = CGPoint(x: size.width * edge.to.x, y: size.height * edge.to.y)
                var path = Path(); path.move(to: start); path.addLine(to: end)
                context.stroke(path, with: .color(.secondary), lineWidth: 1.3)
                let angle = atan2(end.y - start.y, end.x - start.x)
                var arrow = Path(); arrow.move(to: end)
                arrow.addLine(to: .init(x: end.x - 8 * cos(angle - 0.45), y: end.y - 8 * sin(angle - 0.45)))
                arrow.move(to: end)
                arrow.addLine(to: .init(x: end.x - 8 * cos(angle + 0.45), y: end.y - 8 * sin(angle + 0.45)))
                context.stroke(arrow, with: .color(.secondary), lineWidth: 1.3)
                if let label = edge.label, !label.isEmpty {
                    context.draw(Text(label).font(.caption2), at: .init(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 9))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RichLinkMetadataCard: View {
    @Environment(\.locale) private var uiLocale
    let metadata: SafeLinkMetadata
    let openLink: @MainActor (URL) -> Bool
    var body: some View {
        let _ = uiLocale.identifier
        Button { _ = openLink(metadata.url) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "link")
                VStack(alignment: .leading, spacing: 2) {
                    Text(metadata.title).font(.callout.bold()).lineLimit(2)
                    if let summary = metadata.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                    Text(metadata.url.host ?? metadata.url.absoluteString).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(l10n("Link preview: \(metadata.title)"))
    }
}
