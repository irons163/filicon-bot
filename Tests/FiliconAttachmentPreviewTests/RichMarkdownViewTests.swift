import Foundation
import Testing
@testable import Filicon
import FiliconRichContent

@Suite("Rich Markdown view projection")
struct RichMarkdownViewTests {
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
