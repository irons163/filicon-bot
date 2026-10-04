import Foundation
import Testing
import CustomDump
@testable import FiliconRichContent

@Suite("Pinned offline KaTeX engine", .timeLimit(.minutes(1)))
struct KaTeXEngineTests {
    @Test func inlineAndDisplayModesKeepAccessibleMathMLAndRealHTMLLayout() throws {
        let source = #"\frac{1}{\sqrt[3]{2}}+\mathbb{R}"#
        let inline = try markup(source, mode: .inline)
        let display = try markup(source, mode: .display)
        #expect(inline.html.contains("katex-html"))
        #expect(inline.html.contains("<mroot>"))
        #expect(inline.html.contains("<mfrac>"))
        #expect(!inline.html.contains("display=\"block\""))
        #expect(display.html.contains("display=\"block\""))
        #expect(display.html.contains("katex-display"))
        expectNoDifference(inline.hadParseError, false)
        expectNoDifference(display.hadParseError, false)
    }

    @Test func malformedAndUnknownCommandsHaveAnEscapedTolerantErrorPresentation() throws {
        for source in [#"\frac{broken"#, #"<script>alert("x")</script>\notARealCommand"#] {
            let rendered = try markup(source)
            #expect(rendered.hadParseError)
            #expect(!rendered.html.contains("<script"))
            #expect(!rendered.html.contains("href="))
        }
        let text = try markup(#"\text{<img src=x onerror=alert(1)>}"#)
        #expect(!text.hadParseError)
        #expect(!text.html.contains("<img"))
        #expect(text.html.contains("&lt;"))
    }

    @Test func trustRequiringCommandsNeverProduceLinksImagesOrHTMLAttributes() {
        for source in [
            #"\href{https://example.com}{link}"#, #"\href{javascript:alert(1)}{link}"#,
            #"\url{https://example.com}"#, #"\includegraphics{file:///tmp/secret}"#,
            #"\htmlClass{external}{x}"#, #"\htmlStyle{background:url(https://example.com)}{x}"#,
            #"\htmlId{external}{x}"#, #"\htmlData{foo=bar}{x}"#,
        ] {
            expectNoDifference(OfflineMathPresenter().presentation(for: source, mode: .display), .fallback(original: source))
        }
    }

    @Test func globalMacrosAreIsolatedAcrossMessagesModesAndFailedRenders() throws {
        let declaration = #"\gdef\filiconprivate{42}\filiconprivate"#
        #expect(!(try markup(declaration)).hadParseError)
        #expect(try markup(#"\filiconprivate"#).hadParseError)
        #expect(try markup(#"\filiconprivate"#, mode: .inline).hadParseError)
        #expect(try markup(#"\gdef\failedprivate{99}\frac{"#).hadParseError)
        #expect(try markup(#"\failedprivate"#).hadParseError)
        expectNoDifference(try markup(declaration), try markup(declaration))
    }

    @Test func expansionDepthOutputAndPhysicalSizeAreBounded() throws {
        let recursive = try markup(#"\def\recurse{\recurse}\recurse"#)
        #expect(recursive.hadParseError)
        let giant = try markup(#"\rule{1000000em}{1000000em}"#)
        #expect(giant.html.contains("20em"))
        #expect(!giant.html.contains("height:1000000em"))
        for source in [String(repeating: "{", count: 129) + "x" + String(repeating: "}", count: 129),
                       String(repeating: "x", count: 16_385), "x\u{0}y"] {
            expectNoDifference(OfflineMathPresenter().presentation(for: source, mode: .display), .fallback(original: source))
        }
        let large = OfflineMathPresenter().presentation(for: String(repeating: "x", count: 16_384), mode: .display)
        if case .rendered(let markup) = large { #expect(markup.html.utf8.count <= 1_048_576) }
    }

    @Test func concurrentMessagesDoNotShareMacrosOrMixTheirSources() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    let source = "\\gdef\\private{\(index)}\\private"
                    let rendered = try markup(source)
                    #expect(!rendered.hadParseError)
                    #expect(rendered.html.contains(">\(index)</mn>"))
                }
            }
            try await group.waitForAll()
        }
        #expect(try markup(#"\private"#).hadParseError)
    }

    @Test func missingInvalidOrWrongVersionRuntimeFailsClosed() {
        for script in [nil, "not valid JavaScript {", "var katex={version:'wrong'};"] as [String?] {
            #expect(KaTeXRuntime(script: script).render("x", display: true) == nil)
        }
    }

    @Test func cachedFailuresAndCountBoundDoNotReevaluateTheSameFormula() {
        let runtime = KaTeXRuntime(script: nil)
        expectDifference(runtime.cacheState) {
            #expect(runtime.render("x", display: true) == nil)
        } changes: {
            $0 = .init(entries: 1, bytes: 1)
        }
        let cached = runtime.cacheState
        #expect(runtime.render("x", display: true) == nil)
        expectNoDifference(runtime.cacheState, cached)
        for index in 0..<200 { _ = runtime.render("x+\(index)", display: true) }
        expectNoDifference(runtime.cacheState.entries, 128)
        #expect(runtime.cacheState.bytes <= 8_388_608)
    }

    @Test func stylesheetHasExactlyTwentyInlineFontsAndNoResourceURLs() throws {
        let css = try #require(OfflineMathPresenter.stylesheet)
        expectNoDifference(css.components(separatedBy: "data:font/woff2;base64,").count - 1, 20)
        #expect(!css.contains("https:"))
        #expect(!css.contains("http:"))
        #expect(!css.contains("file:"))
        #expect(!css.contains("url(fonts/"))
    }

    @Test func cacheByteBoundEvictsLargeFailedEntriesAndDoesNotStoreOversizedKeys() {
        let runtime = KaTeXRuntime(script: nil)
        for index in 0..<5 { _ = runtime.render(String(repeating: "x", count: 2_097_151) + String(index), display: true) }
        expectNoDifference(runtime.cacheState, .init(entries: 4, bytes: 8_388_608))
        let cached = runtime.cacheState
        _ = runtime.render(String(repeating: "x", count: 8_388_609), display: false)
        expectNoDifference(runtime.cacheState, cached)
    }

    private func markup(_ source: String, mode: MathMode = .display) throws -> KaTeXMarkup {
        guard case .rendered(let rendered) = OfflineMathPresenter().presentation(for: source, mode: mode)
        else { throw MathFixtureError.failed(source) }
        return rendered
    }
}

private enum MathFixtureError: Error { case failed(String) }
