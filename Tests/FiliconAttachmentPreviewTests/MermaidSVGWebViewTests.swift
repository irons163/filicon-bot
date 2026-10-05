import AppKit
import CustomDump
import FiliconRichContent
import Testing
import WebKit
@testable import Filicon

@Suite("Offline Mermaid SVG surface", .serialized, .timeLimit(.minutes(1)))
@MainActor struct MermaidSVGWebViewTests {
    @Test func documentPolicyOnlyAcceptsValidatedSVGAndBlankNavigation() throws {
        let svg = try fixtureSVG()
        let document = MermaidSVGWebPolicy.document(svg)
        #expect(document.contains(svg.markup))
        for rule in ["default-src 'none'", "script-src 'none'", "connect-src 'none'", "img-src 'none'", "frame-src 'none'", "font-src data:"] {
            #expect(document.contains(rule))
        }
        #expect(!document.contains("<script") && !document.contains(" src="))
        #expect(document.contains("color-scheme:light!important;background:Canvas!important"))
        #expect(MermaidSVGWebPolicy.document(svg, dark: true).contains("color-scheme:dark!important;background:Canvas!important"))
        #expect(MermaidSVGWebPolicy.allowsNavigation(nil))
        #expect(MermaidSVGWebPolicy.allowsNavigation(URL(string: "about:blank")))
        for value in ["https://example.invalid", "http://example.invalid", "file:///private/tmp/mermaid-private", "data:text/html,x", "about:srcdoc", "javascript:alert(1)"] {
            #expect(!MermaidSVGWebPolicy.allowsNavigation(URL(string: value)))
        }
    }

    @Test func nativeAppearanceChangesTheActualCanvasWithoutReloadingOrLosingItsTransform() async throws {
        try await withUIAsyncRenderTurn {
            let coordinator = MermaidSVGWebView.Coordinator()
            let svg = try fixtureSVG()
            let transform = MermaidViewerTransform(scale: 0.2, x: 0, y: 0)
            let view = coordinator.makeView(svg: svg, transform: transform, dark: false,
                onFailure: { Issue.record("Appearance must not fail") })
            let window = hiddenWindow(view, size: CGSize(width: 400, height: 300))
            defer { coordinator.dismantle(view); window.contentView = nil; window.close() }
            _ = try await waitForMermaidSVG(in: view)
            let document = coordinator.revision
            for dark in [false, true, false] {
                coordinator.update(svg: svg, transform: transform, dark: dark, view: view,
                    onFailure: { Issue.record("Appearance must not reload the SVG") })
                let expected = dark ? "dark" : "light"
                var applied = false
                for _ in 0..<100 {
                    let scheme = try await view.callAsyncJavaScript("return getComputedStyle(document.body).colorScheme",
                        arguments: [:], in: nil, contentWorld: .defaultClient)
                    if scheme as? String == expected { applied = true; break }
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(applied)
                let bitmap = try await captureMermaidSVG(view, name: "mermaid-svg-canvas-\(expected)")
                let corner = try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
                #expect(dark ? corner.redComponent < 0.4 : corner.redComponent > 0.7)
                let actualGeometry = try await geometry(view)
                expectNoDifference(actualGeometry, .init(width: 1_200, height: 800, scale: 0.2, x: -600, y: -400))
                expectNoDifference(coordinator.revision, document)
                #expect(coordinator.ready && !window.isVisible)
            }
        }
    }

    @Test func realSurfaceFitsResizesAndUsesActualVectorDimensionsAtEightTimesZoom() async throws {
        try await withUIAsyncRenderTurn {
            let coordinator = MermaidSVGWebView.Coordinator()
            let svg = try fixtureSVG(width: 20_000, height: 16_000)
            var failures = 0
            let view = coordinator.makeView(svg: svg, onFailure: { failures += 1 })
            let window = hiddenWindow(view, size: CGSize(width: 400, height: 320))
            defer { coordinator.dismantle(view); window.contentView = nil; window.close() }
            _ = try await waitForMermaidSVG(in: view)
            let initialGeometry = try await geometry(view)
            expectNoDifference(initialGeometry, .init(width: 20_000, height: 16_000, scale: 0.02, x: -10_000, y: -8_000))
            let document = coordinator.revision
            window.setContentSize(CGSize(width: 200, height: 160))
            view.layoutSubtreeIfNeeded()
            let fit = Geometry(width: 20_000, height: 16_000, scale: 0.01, x: -10_000, y: -8_000)
            try await waitForGeometry(fit, in: view)
            coordinator.update(svg: svg, transform: .init(scale: 8, x: 120, y: -80), view: view, onFailure: { failures += 1 })
            let enlarged = Geometry(width: 20_000, height: 16_000, scale: 8, x: -9_880, y: -8_080)
            try await waitForGeometry(enlarged, in: view)
            expectNoDifference(coordinator.revision, document)
            expectNoDifference(view.bounds.size, CGSize(width: 200, height: 160))
            let bitmap = try await captureMermaidSVG(view, name: "mermaid-svg-maximum-zoom")
            #expect(bitmap.pixelsWide <= 400 && bitmap.pixelsHigh <= 320)
            expectNoDifference(failures, 0)
            #expect(coordinator.ready && !window.isVisible)
            #expect(!view.configuration.websiteDataStore.isPersistent)
            #expect(!view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            #expect(!view.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
            let engine = try await view.callAsyncJavaScript("return typeof mermaid", arguments: [:], in: nil, contentWorld: .defaultClient)
            expectNoDifference(engine as? String, "undefined")
        }
    }

    @Test func laterGeometryWinsEvenWhenBothDOMOperationsAreWaitingForFonts() async throws {
        try await withUIAsyncRenderTurn {
            let coordinator = MermaidSVGWebView.Coordinator()
            let svg = try fixtureSVG()
            let view = coordinator.makeView(svg: svg, onFailure: { Issue.record("Geometry must not fail") })
            let window = hiddenWindow(view, size: CGSize(width: 400, height: 300))
            defer { coordinator.dismantle(view); window.contentView = nil; window.close() }
            _ = try await waitForMermaidSVG(in: view)
            _ = try await view.callAsyncJavaScript("""
            globalThis.blockedFonts = new Promise(resolve => { globalThis.releaseFonts = resolve });
            Object.defineProperty(document.fonts, 'ready', {configurable:true, get: () => globalThis.blockedFonts});
            return globalThis.filiconSVGGeometryTicket;
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
            let originalTicket = try await ticket(view)
            coordinator.update(svg: svg, transform: .init(scale: 2, x: 10, y: 20), view: view, onFailure: { Issue.record("Old geometry must be ignored") })
            try await waitForTicket(after: originalTicket, in: view)
            let oldTicket = try await ticket(view)
            coordinator.update(svg: svg, transform: .init(scale: 3, x: 30, y: 40), view: view, onFailure: { Issue.record("Current geometry must succeed") })
            try await waitForTicket(after: oldTicket, in: view)
            _ = try await view.callAsyncJavaScript("globalThis.releaseFonts(); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
            try await waitForGeometry(.init(width: 1_200, height: 800, scale: 3, x: -570, y: -360), in: view)
            #expect(coordinator.ready)
        }
    }

    @Test func documentChangesRetiredViewsAndDismantlingRejectOldDeadlinesAndFailures() async throws {
        try await withUIAsyncRenderTurn {
            let coordinator = MermaidSVGWebView.Coordinator()
            let first = try fixtureSVG()
            var firstFailures = 0, secondFailures = 0
            let old = coordinator.makeView(svg: first, onFailure: { firstFailures += 1 })
            let oldDocument = coordinator.revision
            let second = try fixtureSVG(text: "New diagram")
            let view = coordinator.makeView(svg: second, onFailure: { secondFailures += 1 })
            let window = hiddenWindow(view, size: CGSize(width: 400, height: 300))
            defer { coordinator.dismantle(view); window.contentView = nil; window.close() }
            #expect(old.navigationDelegate == nil && old.uiDelegate == nil && old.resized == nil)
            coordinator.deadlineReached(oldDocument)
            coordinator.webViewWebContentProcessDidTerminate(old)
            coordinator.dismantle(old)
            coordinator.webView(view, didFinish: nil)
            coordinator.webView(view, didFail: nil, withError: SurfaceFailure.fixture)
            coordinator.webView(view, didFailProvisionalNavigation: nil, withError: SurfaceFailure.fixture)
            expectNoDifference(firstFailures, 0)
            expectNoDifference(secondFailures, 0)
            _ = try await waitForMermaidSVG(in: view)
            #expect(coordinator.ready && coordinator.svg == second)
            let document = coordinator.revision
            coordinator.deadlineReached(document)
            expectNoDifference(secondFailures, 0)
            coordinator.dismantle(view)
            coordinator.deadlineReached(document)
            coordinator.webViewWebContentProcessDidTerminate(view)
            coordinator.viewportChanged(view)
            #expect(!coordinator.ready && !coordinator.finished && coordinator.svg == nil)
            #expect(view.navigationDelegate == nil && view.uiDelegate == nil && view.resized == nil)
            expectNoDifference(secondFailures, 0)
        }
    }

    @Test func aCurrentDeadlineReportsFailureOnlyOnceAndAChangedDocumentCanRecover() async throws {
        try await withUIAsyncRenderTurn {
            let coordinator = MermaidSVGWebView.Coordinator()
            var failures = 0
            let first = try fixtureSVG()
            let view = coordinator.makeView(svg: first, onFailure: { failures += 1 })
            coordinator.deadlineReached(coordinator.revision)
            coordinator.deadlineReached(coordinator.revision)
            coordinator.webViewWebContentProcessDidTerminate(view)
            expectNoDifference(failures, 1)
            #expect(!coordinator.ready && !coordinator.finished)
            let second = try fixtureSVG(text: "Recovered")
            coordinator.update(svg: second, transform: nil, view: view, onFailure: { failures += 1 })
            let window = hiddenWindow(view, size: CGSize(width: 400, height: 300))
            defer { coordinator.dismantle(view); window.contentView = nil; window.close() }
            _ = try await waitForMermaidSVG(in: view)
            #expect(coordinator.ready)
            expectNoDifference(failures, 1)
        }
    }

    @Test func injectedPageScriptAndAnExternalNavigationStayBlocked() async throws {
        try await withUIAsyncRenderTurn {
            let svg = try fixtureSVG()
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            let view = WKWebView(frame: .init(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
            let window = hiddenWindow(view, size: CGSize(width: 400, height: 300))
            defer { view.stopLoading(); window.contentView = nil; window.close() }
            view.loadHTMLString(MermaidSVGWebPolicy.document(svg) + "<script>document.body.dataset.injected='bad'</script>", baseURL: nil)
            var installed = false
            for _ in 0..<100 {
                let exists = try? await view.callAsyncJavaScript("return !!document.getElementById('filicon-host-image')", arguments: [:], in: nil, contentWorld: .defaultClient)
                if exists as? Bool == true { installed = true; break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(installed)
            let value = try await view.callAsyncJavaScript("return document.body.dataset.injected || 'blocked'", arguments: [:], in: nil, contentWorld: .defaultClient)
            expectNoDifference(value as? String, "blocked")
            let coordinator = MermaidSVGWebView.Coordinator()
            let protected = coordinator.makeView(svg: svg, onFailure: { Issue.record("Denied navigation must not destroy a displayed SVG") })
            window.contentView = protected
            defer { coordinator.dismantle(protected) }
            _ = try await waitForMermaidSVG(in: protected)
            protected.load(URLRequest(url: URL(string: "file:///private/tmp/filicon-mermaid-denied-fixture")!))
            for _ in 0..<80 where protected.isLoading { try await Task.sleep(for: .milliseconds(25)) }
            expectNoDifference(protected.url?.absoluteString, "about:blank")
            let content = try await protected.callAsyncJavaScript("return !!document.querySelector('svg')", arguments: [:], in: nil, contentWorld: .defaultClient)
            expectNoDifference(content as? Bool, true)
        }
    }

    private struct Geometry: Equatable {
        let width: Double
        let height: Double
        let scale: Double
        let x: Double
        let y: Double
    }

    private func geometry(_ view: WKWebView) async throws -> Geometry {
        let value = try await view.callAsyncJavaScript("""
        const image = document.getElementById('filicon-host-image'), svg = image.firstElementChild;
        const matrix = new DOMMatrixReadOnly(getComputedStyle(image).transform);
        return {width:parseFloat(svg.style.width),height:parseFloat(svg.style.height),scale:matrix.a,x:matrix.e,y:matrix.f};
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let object = try #require(value as? [String: Double])
        return .init(width: try #require(object["width"]), height: try #require(object["height"]),
            scale: try #require(object["scale"]), x: try #require(object["x"]), y: try #require(object["y"]))
    }

    private func waitForGeometry(_ expected: Geometry, in view: WKWebView) async throws {
        for _ in 0..<100 {
            if try await geometry(view) == expected { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        let value = try await geometry(view)
        expectNoDifference(value, expected)
    }

    private func ticket(_ view: WKWebView) async throws -> Int {
        let value = try await view.callAsyncJavaScript("return globalThis.filiconSVGGeometryTicket", arguments: [:], in: nil, contentWorld: .defaultClient)
        return try #require((value as? String).flatMap(Int.init))
    }

    private func waitForTicket(after previous: Int, in view: WKWebView) async throws {
        for _ in 0..<100 {
            if try await ticket(view) > previous { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The native viewport operation never reached its font barrier")
    }

    private func fixtureSVG(width: Int = 1_200, height: Int = 800, text: String = "Vector fixture") throws -> MermaidSVG {
        try #require(MermaidSVG.validated("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(width) \(height)\"><rect x=\"0\" y=\"0\" width=\"\(width)\" height=\"\(height)\" fill=\"#dedcff\"/><text x=\"10\" y=\"30\">\(text)</text></svg>"))
    }

    private func hiddenWindow(_ view: NSView, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return window
    }
}

private enum SurfaceFailure: Error { case fixture }
