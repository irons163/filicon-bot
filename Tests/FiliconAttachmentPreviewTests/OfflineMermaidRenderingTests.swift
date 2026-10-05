import AppKit
import CustomDump
import FiliconRichContent
import SwiftUI
import Testing
import Vision
import WebKit
@testable import Filicon

@Suite("Offline Mermaid figure and viewer rendering", .serialized, .timeLimit(.minutes(1)))
@MainActor struct OfflineMermaidRenderingTests {
    @Test func nativeFigureAndExpandActionsOpenTheExactSVGWithoutShowingAWindow() async throws {
        try await withUIAsyncRenderTurn(language: "en") {
            let request = MermaidFigureRequest(source: source, theme: .light)
            let model = MermaidRenderedFigureModel()
            await model.task(request: request)
            guard case .rendered(let svg) = model.presentation else { Issue.record("Real Mermaid SVG required"); return }
            let host = NSHostingView(rootView: OfflineMermaidFigure(model: model, svg: svg, request: request,
                revision: model.revision, showsPreviewWindow: false).frame(width: 380).environment(\.locale, Locale(identifier: "en")))
            let window = makeWindow(host, size: host.fittingSize)
            defer { model.figureRemoved(); window.contentView = nil; window.close() }
            _ = try await waitForMermaidSVG(in: host) {
                window.setContentSize(host.fittingSize)
                host.layoutSubtreeIfNeeded()
            }
            let button = try #require(mermaidDescendants(in: host).compactMap { $0 as? MermaidExpandNativeButton }.first)
            let figure = try #require(mermaidDescendants(in: host).compactMap { $0 as? MermaidFigureNativeButton }.first)
            expectNoDifference(figure.accessibilityLabel(), "Open diagram full screen")
            expectNoDifference(button.keyEquivalent, "")
            figure.performClick(nil)
            let viewer = try #require(model.viewer)
            expectNoDifference(viewer.svg, svg)
            expectNoDifference(viewer.source, source)
            expectNoDifference(viewer.state.imageSize, CGSize(width: svg.width, height: svg.height))
            #expect(window.makeFirstResponder(figure))
            figure.keyDown(with: try key("\r", in: window))
            figure.keyDown(with: try key(" ", in: window))
            button.performClick(nil)
            #expect(window.makeFirstResponder(button))
            button.keyDown(with: try key("\r", in: window))
            button.keyDown(with: try key(" ", in: window))
            #expect(model.viewer === viewer)
            expectNoDifference(viewer.foregroundRequest, 5)
            #expect(!window.isVisible)
        }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"])
    func realSVGFigureAndViewerRenderAtNarrowWidthsInEveryLanguageAndAppearance(language: String) async throws {
        for dark in [false, true] {
            try await withUIAsyncRenderTurn(language: language) {
                let request = MermaidFigureRequest(source: source, theme: dark ? .dark : .light)
                let figure = MermaidRenderedFigureModel()
                await figure.task(request: request)
                guard case .rendered(let svg) = figure.presentation else { Issue.record("Real offline engine must render this fixture"); return }
                let host = NSHostingView(rootView: OfflineMermaidFigure(model: figure, svg: svg, request: request,
                    revision: figure.revision, showsPreviewWindow: false)
                    .padding(12).frame(width: 380).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = makeWindow(host, size: host.fittingSize)
                defer { figure.figureRemoved(); window.contentView = nil; window.close() }
                let view = try await waitForMermaidSVG(in: host) {
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                }
                let button = try #require(mermaidDescendants(in: host).compactMap { $0 as? MermaidExpandNativeButton }.first)
                expectNoDifference(button.title, FiliconLocalization.string("Open diagram full screen", language: language))
                #expect(host.bounds.contains(host.convert(button.bounds, from: button)))
                #expect(host.bounds.contains(host.convert(view.bounds, from: view)))
                let label = try await view.callAsyncJavaScript("return document.querySelector('svg').textContent", arguments: [:], in: nil, contentWorld: .defaultClient)
                let text = try #require(label as? String)
                #expect(text.contains("Design") && text.contains("Build") && text.contains("Ready"))
                let appearance = dark ? "dark" : "light"
                try await verifyFittedBounds(view)
                let figureBitmap = try await captureMermaidHost(host, webView: view, name: "mermaid-svg-figure-\(language)-\(appearance)")
                _ = try await captureMermaidSVG(view, name: "mermaid-svg-figure-surface-\(language)-\(appearance)")
                if language == "en" {
                    let visible = try recognizedText(figureBitmap)
                    #expect(visible.contains("Open diagram full screen"), "Missing native figure action: \(visible)")
                    #expect(visible.contains("Design") && visible.contains("Build") && visible.contains("Ready"), "Missing fitted diagram labels: \(visible)")
                }
                let viewer = MermaidViewerModel(svg: svg, source: request.source)
                let coordinator = MermaidPreviewWindowCoordinator()
                defer { coordinator.observeParent(nil); coordinator.dismiss() }
                coordinator.observeParent(window)
                coordinator.update(model: viewer, locale: Locale(identifier: language), dark: dark, show: false, onClose: { _ in })
                let preview = try #require(coordinator.window)
                expectNoDifference(preview.title, FiliconLocalization.string("Diagram preview", language: language))
                let viewerHost = try #require(preview.contentView)
                _ = try await waitForMermaidSVG(in: viewerHost) { viewerHost.layoutSubtreeIfNeeded() }
                viewer.zoomInButtonTapped()
                let enlarged = viewer.state.transform.scale
                preview.setContentSize(CGSize(width: 540, height: 420))
                let viewerSurface = try await waitForMermaidSVG(in: viewerHost) { viewerHost.layoutSubtreeIfNeeded() }
                expectNoDifference(viewer.state.imageSize, CGSize(width: svg.width, height: svg.height))
                expectNoDifference(viewer.state.viewportSize.width, 540)
                #expect(viewer.state.viewportSize.height > 200)
                expectNoDifference(viewer.state.transform.scale, enlarged)
                let input = try #require(mermaidDescendants(in: viewerHost).compactMap { $0 as? MermaidViewerInputView }.first)
                #expect(preview.makeFirstResponder(input))
                input.keyDown(with: try key("f", in: preview))
                let fitted = MermaidViewerTransform(scale: min(1, viewer.state.viewportSize.width / svg.width,
                    viewer.state.viewportSize.height / svg.height))
                expectNoDifference(viewer.state.transform, fitted)
                try await waitForTransform(fitted, in: viewerSurface, host: viewerHost)
                #expect(viewer.state.transform.scale >= 0.1 && viewer.state.transform.scale <= 1)
                let bitmap = try await captureMermaidHost(viewerHost, webView: viewerSurface, name: "mermaid-svg-viewer-\(language)-\(appearance)")
                try await verifyFittedBounds(viewerSurface)
                let surface = try await captureMermaidSVG(viewerSurface, name: "mermaid-svg-viewer-surface-\(language)-\(appearance)")
                let corner = try #require(surface.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
                #expect(corner.alphaComponent > 0.99)
                #expect(dark ? corner.redComponent < 0.4 : corner.redComponent > 0.7,
                    "The real SVG canvas margin must follow the native appearance")
                if language == "en" {
                    let visible = try recognizedText(bitmap)
                    #expect(visible.contains("Diagram preview"), "Missing native viewer header: \(visible)")
                    #expect(visible.contains("Design") && visible.contains("Build") && visible.contains("Ready"), "Missing viewer SVG labels: \(visible)")
                }
                #expect(bitmap.pixelsWide <= 1_080 && bitmap.pixelsHigh <= 840)
                #expect(!preview.isVisible && !window.isVisible)
                #expect(!viewer.hasDisplayFailure)
            }
        }
    }

    @Test func anSVGViewerKeepsItsTransformAcrossLanguageUpdatesAndClosesWithItsParent() async throws {
        try await withUIAsyncRenderTurn(language: "en") {
            let request = MermaidFigureRequest(source: source, theme: .light)
            let figure = MermaidRenderedFigureModel()
            await figure.task(request: request)
            figure.figureClicked(request: request, revision: figure.revision)
            let viewer = try #require(figure.viewer)
            let coordinator = MermaidPreviewWindowCoordinator()
            let parent = makeWindow(NSView(), size: CGSize(width: 400, height: 300))
            defer { coordinator.observeParent(nil); coordinator.dismiss(); figure.figureRemoved(); parent.contentView = nil; parent.close() }
            coordinator.observeParent(parent)
            let closed = AsyncStream.makeStream(of: MermaidViewerModel.self)
            coordinator.update(model: viewer, locale: Locale(identifier: "en"), dark: false, show: false) {
                figure.previewClosed($0); closed.continuation.yield($0)
            }
            let window = try #require(coordinator.window)
            let host = try #require(window.contentView)
            _ = try await waitForMermaidSVG(in: host) { host.layoutSubtreeIfNeeded() }
            viewer.zoomInButtonTapped()
            let before = viewer.state
            coordinator.update(model: viewer, locale: Locale(identifier: "fr"), dark: true, show: false) {
                figure.previewClosed($0); closed.continuation.yield($0)
            }
            #expect(coordinator.window === window)
            expectNoDifference(viewer.state, before)
            expectNoDifference(window.title, FiliconLocalization.string("Diagram preview", language: "fr"))
            parent.close()
            var iterator = closed.stream.makeAsyncIterator()
            let notification = await iterator.next()
            #expect(notification === viewer)
            #expect(figure.viewer == nil && viewer.state.isClosed)
            #expect(coordinator.window == nil && window.contentView == nil)
            closed.continuation.finish()
        }
    }

    @Test(arguments: ["journey", "timeline", "quadrantChart", "requirementDiagram"])
    func additionalGrammarFamiliesRenderInTheNativeFigureAndViewer(kind: String) async throws {
        let original = try #require(mermaidGrammarFixture(kind))
        for dark in [false, true] {
            try await withUIAsyncRenderTurn(language: "en") {
                let request = MermaidFigureRequest(source: original, theme: dark ? .dark : .light)
                let model = MermaidRenderedFigureModel()
                await model.task(request: request)
                guard case .rendered(let svg) = model.presentation else { Issue.record("Real \(kind) SVG required"); return }
                let host = NSHostingView(rootView: OfflineMermaidFigure(model: model, svg: svg, request: request,
                    revision: model.revision, showsPreviewWindow: false)
                    .padding(12).frame(width: 380).background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.locale, Locale(identifier: "en")).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let window = makeWindow(host, size: host.fittingSize)
                defer { model.figureRemoved(); window.contentView = nil; window.close() }
                let surface = try await waitForMermaidSVG(in: host) {
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                }
                try await verifyFittedBounds(surface)
                let appearance = dark ? "dark" : "light"
                _ = try await captureMermaidHost(host, webView: surface, name: "mermaid-grammar-figure-\(kind)-\(appearance)")
                let button = try #require(mermaidDescendants(in: host).compactMap { $0 as? MermaidExpandNativeButton }.first)
                #expect(button.isEnabled && host.bounds.contains(host.convert(button.bounds, from: button)))

                let viewer = MermaidViewerModel(svg: svg, source: original)
                let coordinator = MermaidPreviewWindowCoordinator()
                defer { coordinator.observeParent(nil); coordinator.dismiss() }
                coordinator.observeParent(window)
                coordinator.update(model: viewer, locale: Locale(identifier: "en"), dark: dark, show: false, onClose: { _ in })
                let preview = try #require(coordinator.window)
                preview.setContentSize(CGSize(width: 540, height: 420))
                let viewerHost = try #require(preview.contentView)
                let viewerSurface = try await waitForMermaidSVG(in: viewerHost) { viewerHost.layoutSubtreeIfNeeded() }
                viewer.fitButtonTapped()
                try await waitForTransform(viewer.state.transform, in: viewerSurface, host: viewerHost)
                try await verifyFittedBounds(viewerSurface)
                let text = try await viewerSurface.callAsyncJavaScript("return document.querySelector('svg').textContent", arguments: [:], in: nil, contentWorld: .defaultClient)
                #expect((text as? String ?? "").contains("Delivery"))
                expectNoDifference(viewer.svg, svg)
                expectNoDifference(viewer.source, original)
                #expect(!viewer.hasDisplayFailure && !preview.isVisible && !window.isVisible)
                _ = try await captureMermaidHost(viewerHost, webView: viewerSurface, name: "mermaid-grammar-viewer-\(kind)-\(appearance)")
            }
        }
    }

    @Test func anSVGDisplayFailureKeepsTheOriginalSourceInTheViewer() async throws {
        try await withUIRenderTurn(language: "en") {
            let svg = try #require(MermaidSVG.validated("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 200\"><text x=\"10\" y=\"30\">Fixture</text></svg>"))
            let model = MermaidViewerModel(svg: svg, source: "exact <raw> source")
            model.svgDisplayFailed()
            let host = NSHostingView(rootView: MermaidViewerContent(model: model, onClose: {}, onFullScreen: {})
                .environment(\.locale, Locale(identifier: "en")))
            let window = makeWindow(host, size: CGSize(width: 540, height: 420))
            defer { model.closeButtonTapped(); window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            #expect(mermaidDescendants(in: host).allSatisfy { !($0 is MermaidSVGNativeView) })
            #expect(mermaidDescendants(in: host).allSatisfy { !($0 is MermaidViewerInputView) },
                "A failed SVG must not leave a pan/zoom overlay intercepting source selection and scrolling")
            expectNoDifference(model.source, "exact <raw> source")
            #expect(model.hasDisplayFailure && !window.isVisible)
        }
    }

    private let source = "flowchart LR\nsubgraph Team\nA[Design] -->|Review| B[Build]\nB --> C[Ready]\nend"

    private func waitForTransform(_ transform: MermaidViewerTransform, in view: WKWebView, host: NSView) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            let result = try await view.callAsyncJavaScript("""
            const image = document.getElementById('filicon-host-image');
            const matrix = new DOMMatrixReadOnly(getComputedStyle(image).transform);
            return Math.abs(matrix.a-scale) < 0.00001;
            """, arguments: ["scale": transform.scale], in: nil, contentWorld: .defaultClient)
            if result as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("The fitted native transform never reached the displayed SVG")
    }

    private func verifyFittedBounds(_ view: WKWebView) async throws {
        let result = try await view.callAsyncJavaScript("""
        const bounds = document.querySelector('svg').getBoundingClientRect();
        const viewport = document.documentElement.getBoundingClientRect();
        return [bounds.left,bounds.top,bounds.right,bounds.bottom,viewport.width,viewport.height];
        """, arguments: [:], in: nil, contentWorld: .defaultClient)
        let coordinates = try #require(result as? [Double])
        expectNoDifference(coordinates.count, 6)
        #expect(coordinates[0] >= -1 && coordinates[1] >= -1)
        #expect(coordinates[2] <= coordinates[4] + 1 && coordinates[3] <= coordinates[5] + 1)
    }

    private func recognizedText(_ bitmap: NSBitmapImageRep) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }

    private func makeWindow(_ host: NSView, size: CGSize) -> NSWindow {
        host.frame = .init(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return window
    }

    private func key(_ characters: String, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }
}
