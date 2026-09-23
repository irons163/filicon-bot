import Foundation
import AppKit
import SwiftUI
import Testing
import CustomDump
@testable import Filicon
import FiliconRichContent

@Suite("Rich Markdown view projection")
struct RichMarkdownViewTests {
    @Test func paragraphBoundariesDoNotSplitInlineAttributesOrExtendLinks() throws {
        let source = "First **bold** and *emphasis* with `code`.\n\n[Second paragraph](https://example.com)\n\nThird paragraph."
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "First bold and emphasis with code.\n\nSecond paragraph\n\nThird paragraph.")
        let links = value.runs.compactMap { run -> String? in
            guard run.link != nil else { return nil }; return String(value[run.range].characters)
        }
        expectNoDifference(links, ["Second paragraph"])
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(value[$0.range].characters) == "bold" })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true && String(value[$0.range].characters) == "emphasis" })
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true && String(value[$0.range].characters) == "code" })
        #expect(value.runs.filter { String(value[$0.range].characters).contains("\n\n") }.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil })
    }

    @Test(arguments: ["\n", "\r\n"])
    func preservesHardBreaksAndMarkdownSoftWrapping(newline: String) throws {
        let source = ["soft", "wrap  ", "hard\\", "next", "", "Another paragraph"].joined(separator: newline)
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "soft wrap\nhard\nnext\n\nAnother paragraph")
        expectNoDifference(String(try #require(RichMarkdownProseLayout.make(" \n\n ")).characters), "")
    }

    @Test func orderedNestedListsAndContinuationParagraphsKeepTheirStructure() throws {
        let source = """
        3. First **item**
        4. Second item
           - Nested item
           - Another nested item

             A second paragraph in the same nested item.

        After the list.
        """
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "3. First item\n4. Second item\n  • Nested item\n  • Another nested item\n\n    A second paragraph in the same nested item.\n\nAfter the list.")
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true && String(value[$0.range].characters) == "item" })
    }

    @Test func listMarkersNeverInheritLinksAndSeparateListsDoNotMerge() throws {
        let source = "- [One](sand-msg:t0u)\n- [Two](https://example.com)\n\nParagraph.\n\n- New list"
        let value = try #require(RichMarkdownProseLayout.make(source))
        expectNoDifference(String(value.characters), "• One\n• Two\n\nParagraph.\n\n• New list")
        expectNoDifference(value.runs.filter { $0.link != nil }.map { String(value[$0.range].characters) }, ["One", "Two"])
    }

    @Test func headingsQuotesAndThematicBreaksRemainDistinct() throws {
        let value = try #require(RichMarkdownProseLayout.make("# Heading\n\nBody\n\n> Quote\n>\n> More quote\n>> Nested quote\n\n---\n\nEnd"))
        expectNoDifference(String(value.characters), "Heading\n\nBody\n\n› Quote\n\n› More quote\n\n› › Nested quote\n\n⸻\n\nEnd")
        #expect(value.runs.first?.font != nil)
        #expect(value.runs.contains { String(value[$0.range].characters) == "Body" && $0.font == nil })
    }

    @Test @MainActor func referenceDefinitionsAndCodeSurviveParagraphLayout() throws {
        let original = URL(string: "sand-msg:t0u")!
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let source = "[原始需求 👩🏽‍💻][original]\n\n**Follow-up** [missing](sand-msg:t9u).\n\n`[literal](sand-msg:t0u)`\n\n[original]: sand-msg:t0u"
        let view = RichMarkdownView(source: source, messageReferences: .init(target: { $0 == original ? id : nil }, show: { _ in }))
        let value = try #require(view.attributedProse(source))
        expectNoDifference(String(value.characters), "原始需求 👩🏽‍💻\n\nFollow-up missing.\n\n[literal](sand-msg:t0u)")
        expectNoDifference(value.runs.compactMap(\.link), [original])
        expectNoDifference(value.runs.filter { $0.link != nil }.map { String(value[$0.range].characters) }, ["原始需求 👩🏽‍💻"])
        let reference = try #require(value.runs.first { $0.link == original })
        #expect(reference.backgroundColor != nil)
        #expect(reference.foregroundColor != nil)
        #expect(reference.font != nil)
        #expect(reference.underlineStyle == nil)
        #expect(value.runs.first { String(value[$0.range].characters) == "missing" }?.backgroundColor == nil)
        #expect(value.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    @Test(.serialized, .timeLimit(.minutes(1)), arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    @MainActor func structuredProseRendersInSevenLanguagesAndBothAppearances(language: String) async throws {
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let source = """
                # \(FiliconLocalization.string("Group settings"))

                Review **layout and typography** before publishing.

                Keep paragraphs readable. 中文、日本語、한국어 and emoji 👩🏽‍💻 remain intact.

                3. Check [the proposal](https://example.com).
                4. Review contrast and keyboard navigation.
                   - Verify narrow windows.
                   - Keep `code` literal.

                > Quoted context is not a new instruction.

                First hard-break line.\u{20}\u{20}
                Second hard-break line.
                """
                let host = NSHostingView(rootView: RichMarkdownView(source: source, fillsWidth: false, openLink: { _ in
                    Issue.record("Rendering must not open external links"); return false
                })
                    .font(.system(size: 13)).lineSpacing(4).foregroundStyle(FiliconTheme.textPrimary)
                    .padding(16).frame(width: 380, alignment: .leading).background(FiliconTheme.canvas)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                expectNoDifference(size.width, 380)
                #expect(size.height > 300 && size.height < 900)
                host.frame = .init(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appending(path: "markdown-prose-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test @MainActor func internalLinksRequireExplicitNavigationAndNeverReachExternalOpener() throws {
        let valid = try #require(URL(string: "sand-msg:t0u"))
        let missing = try #require(URL(string: "sand-msg:t9u"))
        let https = try #require(URL(string: "https://example.com"))
        let target = UUID()
        var opened: [URL] = [], jumped: [UUID] = []
        let plain = RichMarkdownView(source: "", openLink: { opened.append($0); return true })
        #expect(!plain.open(valid))
        let view = RichMarkdownView(source: "", messageReferences: .init(
            target: { $0 == valid ? target : nil }, show: { jumped.append($0) }
        ), openLink: { opened.append($0); return true })
        #expect(view.open(valid))
        #expect(!view.open(missing))
        #expect(!view.open(URL(string: "SAND-MSG://t0u")!))
        #expect(!view.open(URL(string: "file:///tmp/private")!))
        #expect(view.open(https))
        expectNoDifference(jumped, [target])
        expectNoDifference(opened, [https])
        let prose = "[Earlier request](sand-msg:t0u) [Unavailable](sand-msg:t9u) ` [code](sand-msg:t0u) ` [Web](https://example.com)"
        let attributed = try #require(view.attributedProse(prose))
        expectNoDifference(attributed.runs.compactMap(\.link), [valid, https])
        #expect(String(attributed.characters).contains("Unavailable"))
        #expect(String(attributed.characters).contains("[code](sand-msg:t0u)"))
        expectNoDifference(try #require(plain.attributedProse(prose)).runs.compactMap(\.link), [https])
        #expect(try #require(plain.attributedProse(prose)).runs.allSatisfy { $0.backgroundColor == nil })
        expectNoDifference(RichMarkdownProjection.make(source: prose).safeHTTPLinks(maximum: 3), [https])
    }

    @Test @MainActor func internalReferencesDoNotActivateInCodeMathOrTableBlocks() throws {
        let source = """
        [Original](sand-msg:t0u)

        ```text
        [Code](sand-msg:t0u)
        ```
        | Title | Link |
        | --- | --- |
        | Table | [label](sand-msg:t0u) |

        \\([math](sand-msg:t0u)\\)
        """
        let blocks = RichMarkdownProjection.make(source: source).blocks
        let prose = blocks.compactMap { block -> String? in
            if case .prose(let text) = block { return text }; return nil
        }
        let view = RichMarkdownView(source: source, messageReferences: .init(target: { _ in UUID() }, show: { _ in }))
        let links = prose.compactMap(view.attributedProse).flatMap { $0.runs.compactMap(\.link) }
        expectNoDifference(links.map(\.absoluteString), ["sand-msg:t0u"])
    }

    @Test func projectsEveryRichBlockWithoutExecutingContent() {
        let source = """
        Hello **world**

        ```swift
        let value = 1
        ```
        | A | B |
        | --- | --- |
        | 1 | 2 |
        \\(x_1\\)
        ```mermaid
        flowchart LR
        A[Start] --> B[Done]
        ```
        """
        let projection = RichMarkdownProjection.make(source: source)
        #expect(projection.blocks.contains { if case .prose = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .code(language: "swift", source: "let value = 1", isTerminated: true) = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .table(let value) = $0 { value.headers == ["A", "B"] } else { false } })
        #expect(projection.blocks.contains { if case .math(source: "x_1", mode: .inline, presentation: .mathML) = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .mermaid(_, .diagram(let value)) = $0 { value.kind == .flowchart } else { false } })
    }

    @Test func mathAndMermaidFailuresProjectExplicitFallbacks() {
        let projection = RichMarkdownProjection.make(source: "\\(\\href{x}{y}\\)\n```mermaid\nflowchart LR\nclick A https://evil.example\n```")
        #expect(projection.blocks.contains { if case .math(_, _, .fallback(original: #"\href{x}{y}"#)) = $0 { true } else { false } })
        #expect(projection.blocks.contains { if case .mermaid(let source, .fallback(let original, _)) = $0 { source == original } else { false } })
    }

    @Test func safeLinkProjectionIsDeduplicatedFilteredAndBounded() {
        let source = "[one](https://example.com/a) [again](https://example.com/a) [two](http://openai.com) [mail](mailto:a@example.com) [bad](file:///tmp/x)"
        let links = RichMarkdownProjection.make(source: source).safeHTTPLinks(maximum: 2)
        #expect(links.map(\.absoluteString) == ["https://example.com/a", "http://openai.com"])
        #expect(RichMarkdownProjection.make(source: source).safeHTTPLinks(maximum: 0).isEmpty)
    }

    @Test @MainActor func metadataCardsAreOptInAndHardCapped() {
        let defaultView = RichMarkdownView(source: "[x](https://example.com)")
        #expect(defaultView.metadataController == nil)
        #expect(defaultView.maximumMetadataCards == 0)
        let controller = RichLinkMetadataController { url in .init(url: url, title: "title") }
        #expect(RichMarkdownView(source: "x", metadataController: controller, maximumMetadataCards: 99).maximumMetadataCards == 3)
        #expect(RichMarkdownView(source: "x", metadataController: controller, maximumMetadataCards: -1).maximumMetadataCards == 0)
    }

    @Test func controllerForwardsToInjectedAsyncLoader() async throws {
        let expected = URL(string: "https://example.com")!
        let controller = RichLinkMetadataController { url in .init(url: url, title: "Injected") }
        #expect(try await controller.load(expected) == .init(url: expected, title: "Injected"))
    }

    @Test func offlineMathDocumentIsSelfContainedAndLockedDown() {
        let mathML = #"<math xmlns="http://www.w3.org/1998/Math/MathML"><mi>x</mi></math>"#
        let document = OfflineMathWebPolicy.document(mathML: mathML, display: true)
        #expect(document.contains(mathML))
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("script-src 'none'"))
        #expect(!document.localizedCaseInsensitiveContains("<script"))
        #expect(!document.localizedCaseInsensitiveContains(" src="))
    }

    @Test func offlineMathNavigationOnlyAllowsBlankInMemoryDocument() {
        #expect(OfflineMathWebPolicy.allowsNavigation(to: nil))
        #expect(OfflineMathWebPolicy.allowsNavigation(to: URL(string: "about:blank")))
        for value in ["https://example.com", "http://example.com", "data:text/html,x", "file:///tmp/x", "about:srcdoc"] {
            #expect(!OfflineMathWebPolicy.allowsNavigation(to: URL(string: value)))
        }
    }
}

@Suite("Native Mermaid layout projection")
struct MermaidNativeLayoutTests {
    @Test func flowchartLayoutRetainsEdgesAndLabels() {
        let diagram = MermaidDiagram(kind: .flowchart, nodes: [.init(id: "A", label: "Start"), .init(id: "B", label: "Done")], edges: [.init(from: "A", to: "B", label: "go")])
        let layout = MermaidNativeLayout.project(diagram)
        #expect(layout.kind == .flowchart)
        #expect(layout.nodes.map(\.label) == ["Start", "Done"])
        #expect(layout.edges.count == 1)
        #expect(layout.edges.first?.label == "go")
    }

    @Test func sequenceMessagesUseOrderedRowsAndParticipantColumns() {
        let diagram = MermaidDiagram(kind: .sequence, nodes: [.init(id: "A", label: "Alice"), .init(id: "B", label: "Bob")], edges: [.init(from: "A", to: "B", label: "hello"), .init(from: "B", to: "A", label: "reply")])
        let layout = MermaidNativeLayout.project(diagram)
        #expect(layout.nodes[0].position.x < layout.nodes[1].position.x)
        #expect(layout.edges[0].from.y < layout.edges[1].from.y)
        #expect(layout.edges.map(\.label) == ["hello", "reply"])
    }

    @Test func stateBoundaryGetsNativeAccessibleGlyph() {
        let diagram = MermaidDiagram(kind: .state, nodes: [.init(id: "__state_boundary", label: "__state_boundary"), .init(id: "Idle", label: "Idle")], edges: [.init(from: "__state_boundary", to: "Idle")])
        let layout = MermaidNativeLayout.project(diagram)
        #expect(layout.nodes.first?.label == "●")
        #expect(layout.edges.count == 1)
    }
}
