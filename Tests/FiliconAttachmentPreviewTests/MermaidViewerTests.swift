import AppKit
import CustomDump
import FiliconRichContent
import SwiftUI
import Testing
import Vision
@testable import Filicon

@Suite("Mermaid diagram viewport")
struct MermaidViewportTests {
    @Test func firstViewportFitsWithoutUpscalingAndLaterResizeRetainsZoom() {
        var state = MermaidViewerState(imageSize: CGSize(width: 1200, height: 800))
        expectDifference(state) {
            state.resize(CGSize(width: 600, height: 400))
        } changes: {
            $0.viewportSize = CGSize(width: 600, height: 400)
            $0.transform.scale = 0.5
        }
        state.zoom(factor: 4)
        state.beginDrag(at: CGPoint(x: 200, y: 100))
        state.moveDrag(to: CGPoint(x: 800, y: 500))
        expectDifference(state) {
            state.resize(CGSize(width: 1000, height: 1000))
        } changes: {
            $0.viewportSize = CGSize(width: 1000, height: 1000)
            $0.transform.y = 300
            $0.drag = nil
        }
        expectNoDifference(state.transform, .init(scale: 2, x: 600, y: 300))
        var small = MermaidViewerState(imageSize: CGSize(width: 300, height: 200))
        small.resize(CGSize(width: 1200, height: 1000))
        expectNoDifference(small.transform, .init())
    }

    @Test func pointerAnchoredZoomRetainsThePointAndClampsAtBothLimits() {
        var state = MermaidViewerState(imageSize: CGSize(width: 1200, height: 800))
        state.resize(CGSize(width: 600, height: 400))
        expectDifference(state) {
            state.zoom(factor: 2, point: CGPoint(x: 450, y: 200))
        } changes: {
            $0.transform.scale = 1
            $0.transform.x = -150
        }
        state.zoom(factor: Double.greatestFiniteMagnitude)
        expectNoDifference(state.transform.scale, 8)
        state.zoom(factor: Double.leastNormalMagnitude)
        expectNoDifference(state.transform, .init(scale: 0.1))
        state.fit()
        expectNoDifference(state.transform, .init(scale: 0.5))
    }

    @Test func draggingHasAThresholdAndCannotMoveTheDiagramBeyondItsEdges() {
        var state = MermaidViewerState(imageSize: CGSize(width: 1200, height: 800))
        state.resize(CGSize(width: 600, height: 400))
        state.zoom(factor: 2)
        state.beginDrag(at: CGPoint(x: 100, y: 100))
        let before = state
        state.moveDrag(to: CGPoint(x: 104, y: 100))
        expectNoDifference(state, before)
        expectDifference(state) {
            state.moveDrag(to: CGPoint(x: 1100, y: 1100))
        } changes: {
            $0.drag?.moved = true
            $0.transform.x = 300
            $0.transform.y = 200
        }
        state.moveDrag(to: CGPoint(x: -1100, y: -1100))
        expectNoDifference(state.transform, .init(scale: 1, x: -300, y: -200))
        state.endDrag()
        let released = state
        state.moveDrag(to: .zero)
        expectNoDifference(state, released)
    }

    @Test func wheelUnitsAndModifiersAreConsistentAndExtremeDeltasStayFinite() {
        var precise = MermaidViewerState(imageSize: CGSize(width: 1200, height: 800))
        precise.resize(CGSize(width: 600, height: 400))
        var coarse = precise, accelerated = precise
        let center = CGPoint(x: 300, y: 200)
        precise.scroll(delta: 16, precise: true, accelerated: false, point: center)
        coarse.scroll(delta: 1, precise: false, accelerated: false, point: center)
        expectNoDifference(precise, coarse)
        accelerated.scroll(delta: 16, precise: true, accelerated: true, point: center)
        #expect(accelerated.transform.scale > precise.transform.scale)
        precise.scroll(delta: .greatestFiniteMagnitude, precise: true, accelerated: true, point: center)
        expectNoDifference(precise.transform.scale, 8)
        precise.scroll(delta: -.greatestFiniteMagnitude, precise: false, accelerated: true, point: center)
        expectNoDifference(precise.transform, .init(scale: 0.1))
    }

    @Test func invalidGeometryAndLateEventsNeverContaminateTheTransform() {
        var state = MermaidViewerState(imageSize: CGSize(width: 1200, height: 800))
        state.resize(CGSize(width: 600, height: 400))
        let before = state
        for number in [Double.nan, Double.infinity, -Double.infinity, -1, 0, 1_000_001] {
            state.resize(CGSize(width: number, height: 400))
        }
        for number in [Double.nan, Double.infinity, -1, 0] { state.zoom(factor: number) }
        state.zoom(factor: 2, point: CGPoint(x: Double.nan, y: 0))
        state.scroll(delta: Double.nan, precise: true, accelerated: false, point: .zero)
        state.beginDrag(at: CGPoint(x: Double.infinity, y: 0))
        expectNoDifference(state, before)
        expectDifference(state) { state.close() } changes: { $0.isClosed = true }
        let closed = state
        state.resize(CGSize(width: 1000, height: 1000))
        state.zoom(factor: 2)
        state.fit()
        state.beginDrag(at: .zero)
        state.moveDrag(to: CGPoint(x: 100, y: 100))
        state.scroll(delta: 16, precise: true, accelerated: false, point: .zero)
        expectNoDifference(state, closed)
        var invalid = MermaidViewerState(imageSize: CGSize(width: Double.infinity, height: 100))
        invalid.resize(CGSize(width: 600, height: 400))
        expectNoDifference(invalid, MermaidViewerState(imageSize: .zero))
    }
}

@Suite("Mermaid diagram presentation actions", .timeLimit(.minutes(1)))
@MainActor struct MermaidViewerActionTests {
    @Test func keyboardAndMagnificationUseTheSameBoundedTransform() {
        let model = MermaidViewerModel(diagram: diagram())
        model.viewportResized(CGSize(width: 600, height: 300))
        #expect(model.canvasKeyPressed("+", modifiers: []))
        expectNoDifference(model.state.transform.scale, 1.4)
        #expect(model.canvasKeyPressed("_", modifiers: .shift))
        expectNoDifference(model.state.transform.scale, 1)
        model.canvasMagnified(1, point: CGPoint(x: 300, y: 150))
        expectNoDifference(model.state.transform.scale, 2)
        for key in ["f", "F", "0"] {
            model.zoomInButtonTapped()
            #expect(model.canvasKeyPressed(key, modifiers: []))
            expectNoDifference(model.state.transform, .init())
        }
        let before = model.state
        for key in ["x", "\r", " "] { #expect(!model.canvasKeyPressed(key, modifiers: [])) }
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(!model.canvasKeyPressed("+", modifiers: modifiers))
        }
        model.canvasMagnified(Double.nan, point: .zero)
        expectNoDifference(model.state, before)
        #expect(model.canvasKeyPressed("\u{1b}", modifiers: []))
        #expect(model.state.isClosed)
        #expect(!model.canvasKeyPressed("+", modifiers: []))
    }

    @Test func sourceChangesAndStaleCloseCallbacksCannotCloseANewerFigure() throws {
        let source = "flowchart LR\nA[Design] --> B[Build]"
        let figure = MermaidFigureModel(source: source, presentation: .diagram(diagram()))
        figure.figureClicked()
        let first = try #require(figure.viewer)
        figure.figureClicked()
        #expect(figure.viewer === first)
        expectNoDifference(first.foregroundRequest, 1)
        figure.messageChanged(source: source, presentation: .diagram(diagram()))
        #expect(figure.viewer === first)
        figure.messageChanged(source: source + "\nB --> C", presentation: .diagram(diagram()))
        #expect(first.state.isClosed)
        #expect(figure.viewer == nil)
        figure.figureClicked()
        let second = try #require(figure.viewer)
        #expect(second !== first)
        figure.previewClosed(first)
        #expect(figure.viewer === second)
        figure.previewClosed(second)
        #expect(figure.viewer == nil)
        #expect(second.state.isClosed)
        figure.messageChanged(source: "unsafe source", presentation: .fallback(original: "unsafe source", reason: "unsafe_directive"))
        figure.figureClicked()
        #expect(figure.viewer == nil)
        expectNoDifference(figure.source, "unsafe source")
    }

    @Test func nativeKeyAndMouseEventsStayInsideTheirOwnUnshownWindow() throws {
        let model = MermaidViewerModel(diagram: diagram())
        model.viewportResized(CGSize(width: 600, height: 300))
        model.zoomInButtonTapped()
        var closed = 0
        let input = MermaidViewerInputView(model: model, onClose: { closed += 1 })
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = input
        defer { window.contentView = nil; window.close() }
        #expect(!window.isVisible)
        #expect(window.makeFirstResponder(input))
        let start = CGPoint(x: 100, y: 100), end = CGPoint(x: 140, y: 120)
        input.mouseDown(with: try mouse(.leftMouseDown, location: start, in: window))
        input.mouseDragged(with: try mouse(.leftMouseDragged, location: end, in: window))
        expectNoDifference(model.state.transform.x, 40)
        expectNoDifference(model.state.transform.y, -20)
        input.mouseUp(with: try mouse(.leftMouseUp, location: end, in: window))
        #expect(model.state.drag == nil)
        #expect(input.performKeyEquivalent(with: try key("0", in: window)))
        expectNoDifference(model.state.transform, .init())
        #expect(!input.performKeyEquivalent(with: try key("+", modifiers: .command, in: window)))
        input.keyDown(with: try key("=", in: window))
        expectNoDifference(model.state.transform.scale, 1.4)
        let cgScroll = try #require(CGEvent(scrollWheelEvent2Source: nil,
            units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        let scroll = try #require(NSEvent(cgEvent: cgScroll))
        var expected = model.state
        expected.scroll(delta: scroll.scrollingDeltaY, precise: scroll.hasPreciseScrollingDeltas,
            accelerated: false, point: input.convert(scroll.locationInWindow, from: nil))
        expectDifference(model.state) { input.scrollWheel(with: scroll) } changes: {
            $0.transform.scale = expected.transform.scale
            $0.transform.x = expected.transform.x
            $0.transform.y = expected.transform.y
        }
        #expect(model.state.transform.scale > 1.4)
        input.mouseDown(with: try mouse(.leftMouseDown, location: start, clicks: 2, in: window))
        expectNoDifference(model.state.transform, .init())
        input.keyDown(with: try key("\u{1b}", in: window))
        expectNoDifference(closed, 1)
        #expect(model.state.isClosed)
        #expect(!window.isVisible)
    }

    @Test func nativeExpandButtonClicksAndFocusedReturnAndSpaceOpenTheExactFigure() async throws {
        try await withUIRenderTurn(language: "en") {
            let figure = MermaidFigureModel(source: "original", presentation: .diagram(diagram()))
            let host = NSHostingView(rootView: MermaidDiagramFigure(model: figure, showsPreviewWindow: false)
                .frame(width: 400).environment(\.locale, Locale(identifier: "en")))
            host.frame = .init(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { figure.figureRemoved(); window.contentView = nil; window.close() }
            host.layoutSubtreeIfNeeded()
            let button = try #require(descendants(in: host).compactMap { $0 as? MermaidExpandNativeButton }.first)
            expectNoDifference(button.keyEquivalent, "")
            expectNoDifference(button.accessibilityLabel(), "Open diagram full screen")
            button.performClick(nil)
            let opened = try #require(figure.viewer)
            expectNoDifference(opened.diagram, diagram())
            #expect(window.makeFirstResponder(button))
            button.keyDown(with: try key("\r", in: window))
            button.keyDown(with: try key(" ", in: window))
            #expect(figure.viewer === opened)
            expectNoDifference(opened.foregroundRequest, 2)
            expectNoDifference(figure.source, "original")
            #expect(!window.isVisible)
        }
    }

    @Test func viewerWindowsPreserveZoomAndCloseOnlyTheirCurrentPresentation() async throws {
        let figure = MermaidFigureModel(source: "first", presentation: .diagram(diagram()))
        figure.figureClicked()
        let first = try #require(figure.viewer)
        first.viewportResized(CGSize(width: 600, height: 300))
        first.zoomInButtonTapped()
        let coordinator = MermaidPreviewWindowCoordinator()
        let parent = NSWindow(contentRect: .init(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { coordinator.observeParent(nil); coordinator.dismiss(); parent.close() }
        coordinator.observeParent(parent)
        let callbacks = AsyncStream.makeStream(of: MermaidViewerModel.self)
        coordinator.update(model: first, locale: Locale(identifier: "en"), dark: false, show: false) {
            figure.previewClosed($0); callbacks.continuation.yield($0)
        }
        let firstWindow = try #require(coordinator.window)
        #expect(!firstWindow.isVisible)
        #expect(firstWindow.styleMask.contains(.resizable))
        #expect(firstWindow.collectionBehavior.contains(.fullScreenPrimary))
        coordinator.update(model: first, locale: Locale(identifier: "fr"), dark: true, show: false) {
            figure.previewClosed($0); callbacks.continuation.yield($0)
        }
        #expect(coordinator.window === firstWindow)
        expectNoDifference(first.state.transform.scale, 1.4)
        expectNoDifference(firstWindow.title, FiliconLocalization.string("Diagram preview", language: "fr"))
        figure.messageChanged(source: "second", presentation: .diagram(diagram()))
        figure.figureClicked()
        let second = try #require(figure.viewer)
        coordinator.update(model: second, locale: Locale(identifier: "en"), dark: false, show: false) {
            figure.previewClosed($0); callbacks.continuation.yield($0)
        }
        #expect(firstWindow.contentView == nil)
        #expect(first.state.isClosed)
        coordinator.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: firstWindow))
        #expect(coordinator.model === second)
        parent.close()
        #expect(coordinator.window == nil)
        #expect(second.state.isClosed)
        figure.messageChanged(source: "third", presentation: .diagram(diagram()))
        figure.figureClicked()
        let third = try #require(figure.viewer)
        var iterator = callbacks.stream.makeAsyncIterator()
        #expect(await iterator.next() === second)
        #expect(figure.viewer === third)
        callbacks.continuation.finish()
        coordinator.closeAndNotify()
        #expect(await iterator.next() == nil)
        figure.figureRemoved()
    }

    @Test func viewerActionsAreLocalizedWithoutTranslatingDiagramLabels() {
        let keys = ["Open diagram full screen", "Diagram preview", "Close diagram preview", "Zoom in", "Zoom out", "Fit to screen",
            "Drag to pan. Scroll or use + and − to zoom; F or 0 fits the diagram. Escape closes the preview."]
        for language in ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"] {
            for key in keys { expectNoDifference(FiliconLocalization.string(key, language: language) == key, language == "en") }
        }
        expectNoDifference(FiliconLocalization.string("Zoom in", language: "ja"), "拡大")
        expectNoDifference(FiliconLocalization.string("Fit to screen", language: "ko"), "창에 맞추기")
    }

    @Test func detachingTheAnchorClosesAndNotifiesItsOwnPreview() async throws {
        let coordinator = MermaidPreviewWindowCoordinator()
        let model = MermaidViewerModel(diagram: diagram())
        let parent = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { coordinator.observeParent(nil); coordinator.dismiss(); parent.close() }
        coordinator.observeParent(parent)
        let callbacks = AsyncStream.makeStream(of: MermaidViewerModel.self)
        coordinator.update(model: model, locale: Locale(identifier: "en"), dark: false, show: false) {
            callbacks.continuation.yield($0)
        }
        let window = try #require(coordinator.window)
        coordinator.observeParent(nil)
        #expect(coordinator.window == nil)
        #expect(window.contentView == nil)
        #expect(model.state.isClosed)
        var iterator = callbacks.stream.makeAsyncIterator()
        #expect(await iterator.next() === model)
        callbacks.continuation.finish()
        coordinator.closeAndNotify()
        #expect(await iterator.next() == nil)
    }

    private func diagram() -> MermaidDiagram {
        .init(kind: .flowchart, nodes: [.init(id: "A", label: "Design"), .init(id: "B", label: "Build")],
            edges: [.init(from: "A", to: "B", label: "Review")])
    }

    private func key(_ characters: String, modifiers: NSEvent.ModifierFlags = [], in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0))
    }

    private func mouse(_ type: NSEvent.EventType, location: CGPoint, clicks: Int = 1, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1))
    }

    private func descendants(in view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(in: $0) } }
}

@Suite("Mermaid viewer localized rendering", .timeLimit(.minutes(1)))
@MainActor struct MermaidViewerRenderTests {
    @Test func maximumBoundedSequenceUsesAViewportSizedSurfaceEvenAtEightTimesZoom() async throws {
        let nodes = (0..<256).map { MermaidNode(id: "N\($0)", label: "Node \($0)") }
        let edges = (0..<512).map { MermaidEdge(from: "N\($0 % 256)", to: "N\(($0 + 1) % 256)", label: "Message \($0)") }
        let diagram = MermaidDiagram(kind: .sequence, nodes: nodes, edges: edges)
        try await withUIRenderTurn(language: "en") {
            let model = MermaidViewerModel(diagram: diagram)
            model.viewportResized(CGSize(width: 540, height: 312))
            model.canvasScrolled(delta: 1_000_000, precise: true, accelerated: false, point: CGPoint(x: 270, y: 156))
            expectNoDifference(model.state.transform.scale, 8)
            #expect(model.state.imageSize.width > 40_000 && model.state.imageSize.height > 26_000)
            let layout = try #require(model.layout)
            let host = NSHostingView(rootView: MermaidDiagramCanvas(layout: layout,
                imageSize: model.state.imageSize, transform: model.state.transform))
            host.frame = .init(x: 0, y: 0, width: 540, height: 312)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(bitmap.pixelsWide <= 1080 && bitmap.pixelsHigh <= 624)
            expectNoDifference(layout.nodes.count, 256)
            expectNoDifference(layout.edges.count, 512)
            #expect(!model.state.isClosed)
        }
    }

    @Test(arguments: ["en", "zh-Hant", "zh-Hans", "fr", "es", "ja", "ko"], ["flowchart", "sequence", "state"])
    func boundedDiagramsAndViewerControlsRenderInEveryLanguageAndAppearance(language: String, kind: String) async throws {
        let source: String
        switch kind {
        case "sequence": source = "sequenceDiagram\nparticipant A as Design\nparticipant B as Build\nA->>B: Review\nB-->>A: Ready"
        case "state": source = "stateDiagram-v2\nDraft --> Review\nReview --> Ready"
        default: source = "flowchart LR\nA[Design] -->|Review| B[Build]\nB --> C[Ready]"
        }
        guard case .diagram(let diagram) = MermaidParser().parse(source) else { Issue.record("Valid render fixture"); return }
        for dark in [false, true] {
            try await withUIRenderTurn(language: language) {
                let model = MermaidViewerModel(diagram: diagram)
                let size = CGSize(width: 540, height: 420)
                model.viewportResized(CGSize(width: size.width, height: size.height - 108))
                let host = NSHostingView(rootView: MermaidViewerContent(model: model,
                    onClose: { Issue.record("Rendering must not close a window") },
                    onFullScreen: { Issue.record("Rendering must not activate full screen") })
                    .environment(\.locale, Locale(identifier: language)).environment(\.colorScheme, dark ? .dark : .light))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.frame = .init(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(!png.isEmpty)
                expectNoDifference(model.diagram, diagram)
                #expect(model.state.transform.scale >= 0.1 && model.state.transform.scale <= 1)
                #expect(!window.isVisible)
                if language == "en" {
                    let recognition = VNRecognizeTextRequest()
                    recognition.recognitionLevel = .accurate
                    recognition.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
                    let text = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
                    #expect(text.contains("Diagram preview"), "Missing viewer header: \(text)")
                    #expect(text.contains("Review"), "Missing diagram content: \(text)")
                }
                if let output = ProcessInfo.processInfo.environment["FILICON_UI_REVIEW_OUTPUT"] {
                    let directory = URL(fileURLWithPath: output)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try png.write(to: directory.appending(path: "mermaid-viewer-\(kind)-\(language)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
