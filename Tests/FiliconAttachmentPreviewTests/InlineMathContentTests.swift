import AppKit
import Foundation
import SwiftUI
import Testing
import CustomDump
import WebKit
import FiliconAgents
import FiliconDomain
import FiliconRichContent
@testable import Filicon

@Suite("Continuous inline math content", .timeLimit(.minutes(1)))
@MainActor struct InlineMathContentTests {
    @Test func macroGeneratedTokenTextNeverReentersPlaceholderReplacement() throws {
        let source = #"\(\def\prefix{FILICONINLINEFORMULA}\text{\prefix0N1END}\) then \(z\)"#
        let plan = try #require(MarkdownInlineMath.protect(source))
        expectNoDifference(plan.formulas.map(\.token), ["FILICONINLINEFORMULA0N0END", "FILICONINLINEFORMULA0N1END"])
        guard case .rendered(let first) = OfflineMathPresenter().presentation(for: plan.formulas[0].source, mode: .inline)
        else { Issue.record("Macro fixture must use the real engine"); return }
        #expect(first.html.contains("FILICONINLINEFORMULA0N1END"))
        let prose = try #require(RichMarkdownView(source: source).inlineMathContent(source))
        let table = try #require(RichMarkdownInlineContent.table(.init(headers: ["Formula"], rows: [[source]])))
        for content in [prose, table] {
            #expect(content.html.contains(first.html), "Generated formula HTML must remain byte-preserved")
            expectNoDifference(content.html.components(separatedBy: "class=\"inline-math\"").count - 1, 2)
            expectNoDifference(content.allowedLinks, [])
        }
    }

    @Test func headingsTasksFormattingAndResolvedReferencesSurviveAroundMath() throws {
        let reference = try #require(URL(string: "sand-msg:t0u"))
        let source = #"# **Heading \(x_1\) tail**"# + "\n\n3. [x] Read " + #"\(y\) and [original][r]."# + "\n\n[r]: sand-msg:t0u"
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000071")!
        let view = RichMarkdownView(source: source, messageReferences: .init(target: { $0 == reference ? id : nil }, show: { _ in }))
        let content = try #require(view.inlineMathContent(source))
        #expect(content.html.contains("<h1"))
        #expect(content.html.contains("<strong>Heading <span class=\"inline-math\">"))
        #expect(content.html.contains("3. "))
        #expect(content.html.contains("role=\"checkbox\" aria-checked=\"true\" aria-disabled=\"true\""))
        #expect(content.html.contains("katex-html") && content.html.contains("<math"))
        #expect(content.html.contains("class=\"message-reference\""))
        #expect(!content.html.contains("FILICONINLINEFORMULA"))
        expectNoDifference(content.allowedLinks, [reference])
        let unresolved = try #require(RichMarkdownView(source: source).inlineMathContent(source))
        expectNoDifference(unresolved.allowedLinks, [])
        #expect(unresolved.html.contains("original"))
        #expect(!unresolved.html.contains("href="))
        let literal = try #require(view.attributedProse(source))
        expectNoDifference(String(literal.characters), "Heading x_1 tail\n\n3. ☑ Read y and original.")
    }

    @Test func rawHTMLTeXURLsImagesAndUnsafeSchemesNeverBecomePageCapabilities() throws {
        let source = #"Before \(\href{javascript:alert(1)}{unsafe}\) after [web](https://example.com/a?q=%22) [file](file:///private) [credential](https://user:secret@example.com) ![image](https://image.example/a.png) <script>bad()</script>"#
        let content = try #require(RichMarkdownView(source: source).inlineMathContent(source))
        expectNoDifference(content.allowedLinks.map(\.absoluteString).sorted(), ["https://example.com/a?q=%22"])
        #expect(content.html.contains("math-fallback"))
        for tag in ["<script", "<img", "<iframe", "<object", "onerror="] { #expect(!content.html.contains(tag)) }
        #expect(!content.html.contains("href=\"javascript:") && !content.html.contains("href=\"file:"))
        let document = OfflineMathWebPolicy.document(content: content, dark: false)
        #expect(document.contains("script-src 'none'") && document.contains("connect-src 'none'"))
        #expect(document.contains("data:font/woff2;base64,"))
    }

    @Test func tableMathUsesInlineFormattingButNeverGetsTranscriptReferencesOrMetadata() throws {
        let table = MarkdownTable(headers: [#"**Symbol** \(n\)"#, "Meaning"], rows: [
            [#"before \(x^2\) after"#, "[web](https://example.com)"],
            [#"`\(code\)`"#, "[original](sand-msg:t0u)"],
        ])
        let content = try #require(RichMarkdownInlineContent.table(table))
        #expect(content.html.contains("<table>") && content.html.contains("<th><strong>Symbol</strong>"))
        #expect(content.html.contains("before <span class=\"inline-math\">"))
        #expect(content.html.contains(#"<code>\(code\)</code>"#))
        #expect(!content.html.contains("href=\"sand-msg:"))
        expectNoDifference(content.allowedLinks.map(\.absoluteString), ["https://example.com"])
        expectNoDifference(RichMarkdownProjection.make(source: "| Math | Link |\n| --- | --- |\n| \\(x\\) | [web](https://example.com) |").safeHTTPLinks(maximum: 3), [])
        #expect(RichMarkdownInlineContent.table(.init(headers: ["plain"], rows: [[#"`\(code\)`"#]])) == nil)
    }

    @Test func metadataSkipsTeXButKeepsRealLinksOutsideCodeLookalikes() {
        let source = #"[web](https://example.com) \(\text{https://math.example}\) `https://code.example \(x\)` https://outside.example"#
        expectNoDifference(RichMarkdownProjection.make(source: source).safeHTTPLinks(maximum: 3).map(\.absoluteString), ["https://example.com", "https://outside.example"])
        let codeOnly = #"`\(code\)` [web](https://example.com)"#
        expectNoDifference(RichMarkdownProjection.make(source: codeOnly).safeHTTPLinks(maximum: 3).map(\.absoluteString), ["https://example.com"])
    }

    @Test func rejectedProtectionRetainsTheExactOriginalAndNeverActivatesTeXLinks() throws {
        let formula = #"\(\text{[private](sand-msg:t0u)}\)"#
        for source in [Array(repeating: formula, count: 129).joined(separator: " "), String(repeating: "a", count: 262_145) + formula] {
            let id = UUID(uuidString: "00000000-0000-0000-0000-000000000077")!
            let view = RichMarkdownView(source: source, messageReferences: .init(target: { _ in id }, show: { _ in Issue.record("Fallback must not navigate") }))
            let literal = try #require(view.attributedProse(source))
            expectNoDifference(String(literal.characters), source)
            expectNoDifference(literal.runs.compactMap(\.link), [])
            let rendered = view.inlineMathContent(source) != nil
            expectNoDifference(rendered, false)
            expectNoDifference(RichMarkdownProjection.make(source: source).safeHTTPLinks(maximum: 3), [])
        }
    }

    @Test func nativeTableFallbackDoesNotReinterpretFormulaTextAsLinks() {
        let formula = #"\(\text{[inside](https://inside.example)}\)"#
        let cell = RichMarkdownTableCellLayout.make("before " + formula + " after [web](https://example.com)")
        expectNoDifference(String(cell.characters), #"before \text{[inside](https://inside.example)} after web"#)
        expectNoDifference(cell.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
        for source in [Array(repeating: formula, count: 129).joined(separator: " "), String(repeating: "a", count: 262_145) + formula] {
            let literal = RichMarkdownTableCellLayout.make(source)
            expectNoDifference(String(literal.characters), source)
            expectNoDifference(literal.runs.compactMap(\.link), [])
        }
    }

    @Test func renderedDocumentsHaveIndependentSourceCellFormulaAndOutputBounds() throws {
        let source = (0..<129).map { "\\(x_{\($0)}\\)" }.joined(separator: " ")
        #expect(RichMarkdownView(source: source).inlineMathContent(source) == nil)
        #expect(RichMarkdownInlineContent.table(.init(headers: [#"\(x\)"#], rows: Array(repeating: [""], count: 2_048))) == nil)
        #expect(RichMarkdownInlineContent.table(.init(headers: [#"\(x\)"#], rows: [[String(repeating: "a", count: 262_145)]])) == nil)
        let rows = Array(repeating: "a&b&c&d&e&f&g&h", count: 40).joined(separator: "\\\\")
        let formula = "\\begin{matrix}\(rows)\\end{matrix}"
        let large = Array(repeating: "\\(\(formula)\\)", count: 20).joined(separator: " ")
        let largeBytes = RichMarkdownView(source: large).inlineMathContent(large)?.html.utf8.count ?? 0
        #expect(largeBytes <= 2_097_152)
        #expect(!String(try #require(RichMarkdownView(source: large).attributedProse(large)).characters).contains("FILICONINLINEFORMULA"))
        let plan = try #require(MarkdownInlineMath.protect(#"\(x\)"#))
        var paragraphs = try #require(RichMarkdownProseLayout.paragraphs(plan.markdown))
        paragraphs[0].content.append(AttributedString(String(repeating: "&", count: 420_000)))
        let acceptedOversizedHTML = RichMarkdownInlineContent.prose(paragraphs: paragraphs, formulas: plan.formulas) != nil
        expectNoDifference(acceptedOversizedHTML, false)
    }

    @Test func userLinksRecheckTheOriginalHostAndDismantlingRevokesTheirHandler() throws {
        let https = try #require(URL(string: "https://example.com"))
        let original = try #require(URL(string: "sand-msg:t0u"))
        var opened: [URL] = [], shown: [UUID] = []
        var targetAvailable = true
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000072")!
        let view = RichMarkdownView(source: "", messageReferences: .init(target: { $0 == original && targetAvailable ? id : nil }, show: { shown.append($0) }), openLink: { opened.append($0); return true })
        let coordinator = OfflineMathWebView.Coordinator(measured: { _ in })
        coordinator.allowedLinks = [https, original]
        coordinator.openLink = view.open
        #expect(!coordinator.linkActivated(https))
        coordinator.finished = true
        expectDifference(opened) { #expect(coordinator.linkActivated(https)) } changes: { $0.append(https) }
        expectDifference(shown) { #expect(coordinator.linkActivated(original)) } changes: { $0.append(id) }
        targetAvailable = false
        #expect(!coordinator.linkActivated(original))
        #expect(!coordinator.linkActivated(https, download: true))
        for value in ["file:///tmp/private", "javascript:alert(1)", "https://not-listed.example", "about:blank"] {
            #expect(!coordinator.linkActivated(URL(string: value)))
        }
        let webView = OfflineMathWebKitView(frame: .zero, configuration: WKWebViewConfiguration())
        OfflineMathWebView.dismantleNSView(webView, coordinator: coordinator)
        #expect(!coordinator.linkActivated(https))
        #expect(coordinator.allowedLinks.isEmpty)
        expectNoDifference(opened, [https]); expectNoDifference(shown, [id])
    }

    @Test(arguments: ["direct", "group"], ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func actualTranscriptsKeepMathOnTheTextLineAndReflowWithTables(route: String, language: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-inline-math-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let date = Date(timeIntervalSince1970: 1_000)
        let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000073")!
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000074")!
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000075")!
        let agent = AgentProfile(id: agentID, name: "Fixture author", createdAt: date, avatar: .pet(.codex))
        let source = #"BEFORE \(x_1\) AFTER. **Bold** *italic* `code`."# + "\n\n# " +
            FiliconLocalization.string("Group settings", language: language) + #" \(y^2\)"# +
            "\n\n- [x] Review " + #"\(\frac{a}{b}\) and [web](https://example.com)."# +
            "\n\nA long paragraph with ordinary text around " + #"\(z\)"# + " so the whole sentence wraps naturally at narrower widths. 中文 日本語 한국어 👩🏽‍💻\n\n" +
            #"| **Symbol** \(n\) | Meaning |"# + "\n| --- | --- |\n" +
            #"| BEFORE \(a^2\) AFTER | [web](https://example.com) |"# + "\n" +
            #"| `\(literal\)` | \(\sqrt{x}\) |"#
        let direct = ChatMessage(id: messageID, role: .assistant, text: source, createdAt: date)
        let conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000076")!, messages: [direct], updatedAt: date)
        let group = RoomMessage(id: messageID, groupID: groupID, senderID: agentID, text: source, createdAt: date)
        for dark in [false, true] {
            try await withUIAsyncRenderTurn(language: language) {
                let content = Group {
                    if route == "direct" {
                        TranscriptMessageView(message: direct, conversation: conversation, onJumpToMessage: { _ in Issue.record("Rendering must not navigate") })
                    } else {
                        GroupMessageBubble(message: group, agent: agent, onReaction: { Issue.record("Rendering must not change a reaction") })
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).environmentObject(model)
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: content)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = .init(x: 0, y: 0, width: 460, height: 600)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                let webViews = descendants(host).compactMap { $0 as? OfflineMathWebKitView }
                expectNoDifference(webViews.count, 2)
                let prose = try #require(webViews.first)
                let table = try #require(webViews.last)
                let wide = try await settled(prose, host: host)
                let tableStats = try await settled(table, host: host)
                expectNoDifference(wide.mathCount, 4)
                expectNoDifference(tableStats.mathCount, 3)
                #expect(wide.baseline && tableStats.baseline, "Text and formulas must share a line")
                #expect(wide.fonts && tableStats.fonts)
                #expect(!prose.configuration.defaultWebpagePreferences.allowsContentJavaScript)
                #expect(!window.isVisible)
                try await capture(prose, name: "inline-\(route)-\(language)-\(dark ? "dark" : "light")-prose")
                try await capture(table, name: "inline-\(route)-\(language)-\(dark ? "dark" : "light")-table")
                // Resize the fixture window, not just its content view. AppKit
                // would otherwise restore the old width on the next layout turn.
                window.setContentSize(.init(width: 290, height: 600))
                host.layoutSubtreeIfNeeded()
                let narrow = try await settled(prose, host: host, maximumWidth: wide.width - 10)
                #expect(narrow.height > wide.height, "Narrower paragraphs must wrap")
                #expect(prose.bounds.height >= narrow.height)
                try await capture(prose, name: "inline-\(route)-\(language)-\(dark ? "dark" : "light")-narrow-prose")
            }
        }
        expectNoDifference(direct.text, source); expectNoDifference(group.text, source)
    }

    private struct Statistics {
        let height: Double
        let width: Double
        let mathCount: Int
        let baseline: Bool
        let fonts: Bool
    }

    private func ready(_ webView: WKWebView) async throws -> Statistics {
        for _ in 0..<100 {
            let value = try? await webView.callAsyncJavaScript("""
            const content = document.getElementById('math-content');
            if (!content || !content.querySelector('.inline-math')) return null;
            await document.fonts.ready;
            const math = Array.from(content.querySelectorAll('.inline-math')).find(m => /BEFORE/.test(m.closest('p,td,th')?.textContent));
            const parent = math.closest('p,td,th');
            const nodes = Array.from(parent.childNodes);
            const textRects = nodes.filter(n => n.nodeType === Node.TEXT_NODE && /BEFORE|AFTER/.test(n.textContent)).map(n => {
              const r = document.createRange(); r.selectNodeContents(n); return r.getBoundingClientRect();
            });
            const m = math.getBoundingClientRect();
            const baseline = textRects.length === 2 && textRects.every(r => Math.abs((r.top+r.bottom-m.top-m.bottom)/2) < 6);
            return {height:content.getBoundingClientRect().height, width:window.innerWidth, count:content.querySelectorAll('.inline-math').length,
              baseline, fonts:Array.from(document.fonts).some(f => f.status === 'loaded')};
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
            if let dictionary = value as? [String: Any], let height = dictionary["height"] as? Double, height > 0 {
                return .init(height: height, width: dictionary["width"] as? Double ?? 0, mathCount: dictionary["count"] as? Int ?? 0,
                    baseline: dictionary["baseline"] as? Bool == true, fonts: dictionary["fonts"] as? Bool == true)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw InlineMathRenderFailure.notReady
    }

    private func settled(_ webView: WKWebView, host: NSView, maximumWidth: Double = .infinity) async throws -> Statistics {
        var last = try await ready(webView)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            last = try await ready(webView)
            if last.width <= maximumWidth, abs(webView.bounds.width - last.width) < 1.1,
               webView.bounds.height >= (OfflineMathWebPolicy.height(last.height) ?? .infinity) { return last }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Layout did not settle: native \(webView.bounds.width)×\(webView.bounds.height), DOM \(last.width)×\(last.height)")
        return last
    }

    private func capture(_ webView: WKWebView, name: String) async throws {
        let snapshot = try await webView.takeSnapshot(configuration: nil)
        let bitmap = try #require(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 500)
        if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appending(path: "\(name).png"))
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
}

private enum InlineMathRenderFailure: Error { case notReady }
