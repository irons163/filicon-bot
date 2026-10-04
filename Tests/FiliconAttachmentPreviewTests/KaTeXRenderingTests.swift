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

@Suite("Offline KaTeX native rendering", .timeLimit(.minutes(1)))
@MainActor struct KaTeXRenderingTests {
    private let tallFormula = #"\begin{aligned}a_1&=\frac{1}{2}\\a_2&=\frac{2}{3}\\a_3&=\frac{3}{4}\\a_4&=\frac{4}{5}\\a_5&=\frac{5}{6}\\a_6&=\frac{6}{7}\end{aligned}"#

    @Test func measuredHeightsRejectInvalidNumbersAndBoundTallScrollableContent() {
        expectNoDifference(OfflineMathWebPolicy.height(150.1), 159)
        expectNoDifference(OfflineMathWebPolicy.height(1), 24)
        expectNoDifference(OfflineMathWebPolicy.height(100_000), 1_024)
        for value in [0, -1, Double.nan, .infinity, -.infinity] {
            #expect(OfflineMathWebPolicy.height(value) == nil)
        }
    }

    @Test(arguments: ["direct", "group"])
    func completeMathAndAutoHeightAreReachableInBothActualTranscriptRoutes(route: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "filicon-math-route-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let date = Date(timeIntervalSince1970: 1_000)
        let agentID = UUID(uuidString: "00000000-0000-0000-0000-000000000061")!
        let groupID = UUID(uuidString: "00000000-0000-0000-0000-000000000062")!
        let messageID = UUID(uuidString: "00000000-0000-0000-0000-000000000063")!
        let agent = AgentProfile(id: agentID, name: "Fixture author", createdAt: date, avatar: .pet(.codex))
        let source = "$$\n\(tallFormula)\n$$"
        let direct = ChatMessage(id: messageID, role: .assistant, text: source, createdAt: date)
        let conversation = Conversation(id: UUID(uuidString: "00000000-0000-0000-0000-000000000064")!, messages: [direct], updatedAt: date)
        let group = RoomMessage(id: messageID, groupID: groupID, senderID: agentID, text: source, createdAt: date)
        try await withUIAsyncRenderTurn(language: "en") {
            let content = Group {
                if route == "direct" {
                    TranscriptMessageView(message: direct, conversation: conversation, onJumpToMessage: { _ in
                        Issue.record("A formula must not navigate a transcript")
                    })
                } else {
                    GroupMessageBubble(message: group, agent: agent, onReaction: {
                        Issue.record("A formula must not mutate reactions")
                    })
                }
            }.padding(16).frame(width: 420).environmentObject(model)
            let host = NSHostingView(rootView: content)
            host.frame = .init(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let webView = try #require(descendants(host).compactMap { $0 as? OfflineMathWebKitView }.first)
            let stats = try await ready(webView)
            #expect(stats.height > 96, "Multiline math must not keep the old 96-point clipping limit")
            for _ in 0..<40 where webView.bounds.height < stats.height {
                try await Task.sleep(for: .milliseconds(25))
                host.frame.size = host.fittingSize
                host.layoutSubtreeIfNeeded()
            }
            #expect(webView.bounds.height >= stats.height)
            #expect(stats.hasHTML && stats.hasMathML && stats.fontsLoaded)
            #expect(!webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            #expect(!window.isVisible)
            try await capture(webView, name: "katex-route-\(route)")
        }
        expectNoDifference(direct.text, source)
        expectNoDifference(group.text, source)
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func formulasAndOfflineFontsRenderInEveryLanguageAndBothAppearances(language: String) async throws {
        let formula = #"\underbrace{\begin{pmatrix}a&b\\c&d\end{pmatrix}}_{\text{matrix}}+\mathbb{R}+\sqrt[3]{x}"#
        for dark in [false, true] {
            try await withUIAsyncRenderTurn(language: language) {
                guard case .rendered(let markup) = OfflineMathPresenter().presentation(for: formula, mode: .display)
                else { Issue.record("Missing complete engine"); return }
                let host = NSHostingView(rootView: OfflineMathWebView(markup: markup, display: true, dark: dark, measured: { _ in })
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.frame = .init(x: 0, y: 0, width: 420, height: 180)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                let webView = try #require(descendants(host).compactMap { $0 as? OfflineMathWebKitView }.first)
                let stats = try await ready(webView)
                #expect(stats.height > 40 && stats.height < 180)
                #expect(stats.hasHTML && stats.hasMathML && stats.fontsLoaded)
                #expect(!markup.hadParseError)
                #expect(!window.isVisible)
                try await capture(webView, name: "katex-\(language)-\(dark ? "dark" : "light")")
            }
        }
    }

    @Test func nativeMeasurementUsesAnIsolatedWorldAndPageScriptsStayDisabled() async throws {
        try await withUIAsyncRenderTurn(language: "en") {
            guard case .rendered(let markup) = OfflineMathPresenter().presentation(for: "x", mode: .inline)
            else { Issue.record("Missing engine"); return }
            let coordinator = OfflineMathWebView.Coordinator(measured: { _ in })
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let webView = OfflineMathWebKitView(frame: .init(x: 0, y: 0, width: 300, height: 60), configuration: configuration)
            webView.navigationDelegate = coordinator
            let document = OfflineMathWebPolicy.document(markup: markup, display: false) +
                "<script>document.body.dataset.pageScript='executed'</script>"
            coordinator.loadedDocument = document
            coordinator.navigation = webView.loadHTMLString(document, baseURL: nil)
            _ = try await ready(webView)
            let value = try await webView.callAsyncJavaScript("return document.body.dataset.pageScript || 'blocked'", arguments: [:], in: nil, contentWorld: .defaultClient)
            expectNoDifference(value as? String, "blocked")
            #expect(!configuration.defaultWebpagePreferences.allowsContentJavaScript)
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
    }

    @Test func changedFormulaAndDismantledViewRejectOldMeasurements() {
        var heights: [Double] = []
        let coordinator = OfflineMathWebView.Coordinator(measured: { heights.append($0) })
        coordinator.revision = 1
        coordinator.finished = true
        expectDifference(heights) { coordinator.measurementCompleted(40, revision: 1) } changes: { $0.append(48) }
        coordinator.revision = 2
        for raw in [800, .nan, .infinity] { coordinator.measurementCompleted(raw, revision: 1) }
        expectNoDifference(heights, [48])
        coordinator.finished = false
        coordinator.measurementCompleted(800, revision: 2)
        expectNoDifference(heights, [48])
        coordinator.finished = true
        expectDifference(heights) { coordinator.measurementCompleted(20, revision: 2) } changes: { $0.append(28) }
        let webView = OfflineMathWebKitView(frame: .zero, configuration: WKWebViewConfiguration())
        coordinator.loadedDocument = "old document"
        webView.navigationDelegate = coordinator
        webView.resized = { coordinator.measure(webView) }
        OfflineMathWebView.dismantleNSView(webView, coordinator: coordinator)
        expectNoDifference(coordinator.revision, 3)
        #expect(!coordinator.finished)
        #expect(coordinator.loadedDocument == nil && coordinator.navigation == nil)
        #expect(webView.resized == nil && webView.navigationDelegate == nil)
        coordinator.measurementCompleted(800, revision: 2)
        coordinator.measurementCompleted(800, revision: 3)
        expectNoDifference(heights, [48, 28])
    }

    @Test func veryTallFormulaScrollsInsideTheBoundedViewport() async throws {
        let rows = (1...48).map { "a_{\($0)}&=\\frac{1}{2}" }.joined(separator: "\\\\")
        let formula = "\\begin{aligned}\(rows)\\end{aligned}"
        try await withUIAsyncRenderTurn(language: "en") {
            guard case .rendered(let markup) = OfflineMathPresenter().presentation(for: formula, mode: .display)
            else { Issue.record("Missing engine"); return }
            let host = NSHostingView(rootView: OfflineMathWebView(markup: markup, display: true, dark: false, measured: { _ in }))
            host.frame = .init(x: 0, y: 0, width: 320, height: 1_024)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.layoutSubtreeIfNeeded()
            let webView = try #require(descendants(host).compactMap { $0 as? OfflineMathWebKitView }.first)
            let stats = try await ready(webView)
            #expect(stats.height > 1_024)
            expectNoDifference(OfflineMathWebPolicy.height(stats.height), 1_024)
            let scroll = try await webView.callAsyncJavaScript("window.scrollTo(0, document.body.scrollHeight); return window.scrollY;", arguments: [:], in: nil, contentWorld: .defaultClient)
            #expect((scroll as? Double ?? 0) > 0)
            #expect(!window.isVisible)
        }
    }

    private struct Statistics {
        let height: Double
        let hasHTML: Bool
        let hasMathML: Bool
        let fontsLoaded: Bool
    }

    private func ready(_ webView: WKWebView) async throws -> Statistics {
        for _ in 0..<100 {
            let value = try? await webView.callAsyncJavaScript("""
            if (!document.getElementById('math-content')) return null;
            await document.fonts.ready;
            return {height:document.getElementById('math-content').getBoundingClientRect().height,
              html:!!document.querySelector('.katex-html'), mathml:!!document.querySelector('math'),
              fonts:Array.from(document.fonts).some(f => f.status === 'loaded')};
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
            if let dictionary = value as? [String: Any], let height = dictionary["height"] as? Double, height > 0 {
                return .init(height: height, hasHTML: dictionary["html"] as? Bool == true,
                    hasMathML: dictionary["mathml"] as? Bool == true, fontsLoaded: dictionary["fonts"] as? Bool == true)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw KaTeXRenderFailure.notReady
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

private enum KaTeXRenderFailure: Error { case notReady }
