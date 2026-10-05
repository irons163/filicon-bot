import AppKit
import Observation
import SwiftUI
import FiliconRichContent

struct MermaidViewerTransform: Equatable {
    var scale = 1.0
    var x = 0.0
    var y = 0.0
}

struct MermaidViewerDrag: Equatable {
    let start: CGPoint
    let origin: CGPoint
    var moved = false
}

struct MermaidViewerState: Equatable {
    static let minimumZoom = 0.1
    static let maximumZoom = 8.0
    static let zoomStep = 1.4

    let imageSize: CGSize
    var viewportSize = CGSize.zero
    var transform = MermaidViewerTransform()
    var drag: MermaidViewerDrag?
    var isClosed = false

    init(imageSize: CGSize) {
        self.imageSize = Self.validSize(imageSize) ? imageSize : .zero
    }

    mutating func resize(_ size: CGSize) {
        guard !isClosed, Self.validSize(imageSize), Self.validSize(size) else { return }
        let firstSize = viewportSize == .zero
        viewportSize = size
        drag = nil
        if firstSize { fit() } else { clamp() }
    }

    mutating func fit() {
        guard !isClosed, Self.validSize(imageSize), Self.validSize(viewportSize) else { return }
        transform = .init(scale: min(1, viewportSize.width / imageSize.width, viewportSize.height / imageSize.height))
        drag = nil
        clamp()
    }

    mutating func zoom(factor: Double, point: CGPoint? = nil) {
        guard !isClosed, factor.isFinite, factor > 0,
              Self.validSize(imageSize), Self.validSize(viewportSize) else { return }
        let anchor = point ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        guard Self.validPoint(anchor) else { return }
        let next = min(Self.maximumZoom, max(Self.minimumZoom, transform.scale * factor))
        guard next != transform.scale else { return }
        let ratio = 1 - next / transform.scale
        transform.x += (anchor.x - viewportSize.width / 2 - transform.x) * ratio
        transform.y += (anchor.y - viewportSize.height / 2 - transform.y) * ratio
        transform.scale = next
        drag = nil
        clamp()
    }

    mutating func scroll(delta: Double, precise: Bool, accelerated: Bool, point: CGPoint) {
        guard delta.isFinite else { return }
        let exponent = min(50, max(-50, delta * (precise ? 1 : 16) * (accelerated ? 0.01 : 0.002)))
        zoom(factor: exp(exponent), point: point)
    }

    mutating func beginDrag(at point: CGPoint) {
        guard !isClosed, Self.validSize(viewportSize), Self.validPoint(point) else { return }
        drag = .init(start: point, origin: CGPoint(x: transform.x, y: transform.y))
    }

    mutating func moveDrag(to point: CGPoint) {
        guard !isClosed, Self.validPoint(point), var pointer = drag else { return }
        let x = point.x - pointer.start.x, y = point.y - pointer.start.y
        guard pointer.moved || hypot(x, y) > 4 else { return }
        pointer.moved = true
        drag = pointer
        transform.x = pointer.origin.x + x
        transform.y = pointer.origin.y + y
        clamp()
    }

    mutating func endDrag() { drag = nil }

    mutating func close() {
        isClosed = true
        drag = nil
    }

    private mutating func clamp() {
        transform.scale = min(Self.maximumZoom, max(Self.minimumZoom, transform.scale))
        let maxX = max(0, (imageSize.width * transform.scale - viewportSize.width) / 2)
        let maxY = max(0, (imageSize.height * transform.scale - viewportSize.height) / 2)
        transform.x = min(maxX, max(-maxX, transform.x))
        transform.y = min(maxY, max(-maxY, transform.y))
    }

    private static func validSize(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
            && size.width <= 1_000_000 && size.height <= 1_000_000
    }

    private static func validPoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
    }
}

@MainActor @Observable final class MermaidViewerModel: Identifiable {
    let diagram: MermaidDiagram?
    let layout: MermaidNativeLayout?
    let svg: MermaidSVG?
    let source: String?
    private(set) var hasDisplayFailure = false
    private(set) var state: MermaidViewerState
    private(set) var foregroundRequest: UInt = 0

    init(diagram: MermaidDiagram) {
        self.diagram = diagram
        layout = MermaidNativeLayout.project(diagram)
        svg = nil; source = nil
        let size: CGSize
        switch diagram.kind {
        case .sequence:
            size = CGSize(width: max(600, Double(diagram.nodes.count + 1) * 160),
                          height: max(300, Double(diagram.edges.count + 1) * 52))
        case .flowchart, .state:
            let columns = min(max(diagram.nodes.count, 1), 3)
            let rows = ceil(Double(max(diagram.nodes.count, 1)) / Double(columns))
            size = CGSize(width: Double(columns + 1) * 200, height: max(300, (rows + 1) * 100))
        }
        state = .init(imageSize: size)
    }

    init(svg: MermaidSVG, source: String) {
        self.svg = svg; self.source = source
        diagram = nil; layout = nil
        state = .init(imageSize: CGSize(width: svg.width, height: svg.height))
    }

    func figureOpenedAgain() { if !state.isClosed { foregroundRequest &+= 1 } }
    func viewportResized(_ size: CGSize) { state.resize(size) }
    func zoomInButtonTapped() { state.zoom(factor: MermaidViewerState.zoomStep) }
    func zoomOutButtonTapped() { state.zoom(factor: 1 / MermaidViewerState.zoomStep) }
    func fitButtonTapped() { state.fit() }
    func canvasDoubleClicked() { state.fit() }
    func canvasScrolled(delta: Double, precise: Bool, accelerated: Bool, point: CGPoint) {
        state.scroll(delta: delta, precise: precise, accelerated: accelerated, point: point)
    }
    func canvasMagnified(_ increment: Double, point: CGPoint) { state.zoom(factor: 1 + increment, point: point) }
    func canvasMouseDown(at point: CGPoint) { state.beginDrag(at: point) }
    func canvasMouseDragged(to point: CGPoint) { state.moveDrag(to: point) }
    func canvasMouseUp() { state.endDrag() }
    func closeButtonTapped() { state.close() }
    func svgDisplayFailed() { if !state.isClosed { hasDisplayFailure = true } }

    func canvasKeyPressed(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !state.isClosed, modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
        switch key {
        case "+", "=": zoomInButtonTapped()
        case "-", "_": zoomOutButtonTapped()
        case "0", "f", "F": fitButtonTapped()
        case "\u{1b}": closeButtonTapped()
        default: return false
        }
        return true
    }
}

@MainActor @Observable final class MermaidFigureModel {
    private(set) var source: String
    private(set) var presentation: MermaidPresentation
    private(set) var viewer: MermaidViewerModel?

    init(source: String, presentation: MermaidPresentation) {
        self.source = source
        self.presentation = presentation
    }

    func figureClicked() {
        guard case .diagram(let diagram) = presentation, !diagram.nodes.isEmpty else { return }
        if let viewer, !viewer.state.isClosed { viewer.figureOpenedAgain() }
        else { viewer = MermaidViewerModel(diagram: diagram) }
    }

    func messageChanged(source: String, presentation: MermaidPresentation) {
        guard source != self.source || presentation != self.presentation else { return }
        figureRemoved()
        self.source = source
        self.presentation = presentation
    }

    func figureRemoved() {
        viewer?.closeButtonTapped()
        viewer = nil
    }

    func previewClosed(_ closed: MermaidViewerModel) {
        guard closed === viewer else { return }
        figureRemoved()
    }
}

struct MermaidDiagramFigure: View {
    @Environment(\.locale) private var uiLocale
    let model: MermaidFigureModel
    var showsPreviewWindow = true

    var body: some View {
        let _ = uiLocale.identifier
        if case .diagram(let diagram) = model.presentation {
            VStack(alignment: .trailing, spacing: 4) {
                MermaidExpandButton(action: model.figureClicked).fixedSize()
                MermaidDiagramCanvas(layout: MermaidNativeLayout.project(diagram))
                    .frame(minHeight: diagram.kind == .sequence ? 220 : 170)
                    .contentShape(Rectangle())
                    .onTapGesture { model.figureClicked() }
                    .accessibilityAction(named: l10n("Open diagram full screen")) { model.figureClicked() }
            }
            .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l10n("\(diagram.kind.rawValue.capitalized) diagram"))
            .background(MermaidPreviewWindowPresenter(model: model.viewer,
                foregroundRequest: model.viewer?.foregroundRequest ?? 0, show: showsPreviewWindow,
                onClose: model.previewClosed))
        }
    }
}

struct MermaidDiagramCanvas: View {
    let layout: MermaidNativeLayout
    var imageSize: CGSize?
    var transform = MermaidViewerTransform()

    var body: some View {
        GeometryReader { geometry in
            let logicalSize = imageSize ?? geometry.size
            let origin = CGPoint(x: (geometry.size.width - logicalSize.width * transform.scale) / 2 + transform.x,
                                 y: (geometry.size.height - logicalSize.height * transform.scale) / 2 + transform.y)
            ZStack {
                MermaidEdgesCanvas(layout: layout, imageSize: logicalSize, transform: transform)
                ForEach(layout.nodes) { node in
                    Text(verbatim: node.label).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: layout.kind == .state ? 10 : 5))
                        .overlay(RoundedRectangle(cornerRadius: layout.kind == .state ? 10 : 5).stroke(Color.accentColor.opacity(0.5)))
                        .scaleEffect(transform.scale)
                        .position(x: origin.x + logicalSize.width * node.position.x * transform.scale,
                                  y: origin.y + logicalSize.height * node.position.y * transform.scale)
                        .accessibilityLabel(node.label)
                }
            }
        }
    }
}

struct MermaidExpandButton: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> MermaidExpandNativeButton {
        let button = MermaidExpandNativeButton(title: "", target: context.coordinator, action: #selector(Coordinator.buttonClicked))
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        return button
    }
    func updateNSView(_ button: MermaidExpandNativeButton, context: Context) {
        context.coordinator.action = action
        button.title = FiliconLocalization.string("Open diagram full screen", language: locale.identifier)
        button.setAccessibilityLabel(button.title)
        button.toolTip = button.title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MermaidExpandNativeButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func buttonClicked() { action() }
    }
}

final class MermaidExpandNativeButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self, event.characters == "\r" || event.characters == " ",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            performClick(nil)
        } else { super.keyDown(with: event) }
    }
}

struct MermaidViewerContent: View {
    @Environment(\.locale) private var uiLocale
    let model: MermaidViewerModel
    let onClose: () -> Void
    let onFullScreen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(localized("Diagram preview")).font(.headline)
                Spacer()
                Button(action: onFullScreen) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .accessibilityLabel(localized("Full Screen")).help(localized("Full Screen"))
                Button(action: onClose) { Image(systemName: "xmark") }
                    .accessibilityLabel(localized("Close diagram preview")).help(localized("Close diagram preview"))
                    .keyboardShortcut(.cancelAction)
            }.padding(12)
            Divider()
            GeometryReader { geometry in
                ZStack {
                    Group {
                        if let layout = model.layout {
                            MermaidDiagramCanvas(layout: layout, imageSize: model.state.imageSize, transform: model.state.transform)
                        } else if let svg = model.svg, !model.hasDisplayFailure {
                            MermaidSVGWebView(svg: svg, transform: model.state.transform, onFailure: model.svgDisplayFailed)
                        } else if let source = model.source {
                            MermaidSourceFallback(source: source, isLoading: false)
                        }
                    }
                        .opacity(model.state.viewportSize == .zero ? 0 : 1)
                        .allowsHitTesting(model.hasDisplayFailure)
                    if !model.hasDisplayFailure {
                        MermaidViewerInput(model: model, onClose: onClose).accessibilityHidden(true)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .onAppear { model.viewportResized(geometry.size) }
                .onChange(of: geometry.size) { _, size in model.viewportResized(size) }
            }
            Divider()
            HStack(spacing: 12) {
                Button { model.zoomOutButtonTapped() } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel(localized("Zoom out")).help(localized("Zoom out"))
                    .disabled(model.hasDisplayFailure || model.state.transform.scale <= MermaidViewerState.minimumZoom)
                Button { model.zoomInButtonTapped() } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel(localized("Zoom in")).help(localized("Zoom in"))
                    .disabled(model.hasDisplayFailure || model.state.transform.scale >= MermaidViewerState.maximumZoom)
                Button { model.fitButtonTapped() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                    .accessibilityLabel(localized("Fit to screen")).help(localized("Fit to screen"))
                    .disabled(model.hasDisplayFailure)
                Spacer(minLength: 4)
                Text(model.state.transform.scale, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().accessibilityLabel(localized("Zoom"))
            }.padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .help(localized("Drag to pan. Scroll or use + and − to zoom; F or 0 fits the diagram. Escape closes the preview."))
        .onChange(of: model.state.isClosed) { _, closed in if closed { onClose() } }
    }

    private func localized(_ key: String) -> String { FiliconLocalization.string(key, language: uiLocale.identifier) }
}

struct MermaidViewerInput: NSViewRepresentable {
    let model: MermaidViewerModel
    let onClose: () -> Void

    func makeNSView(context: Context) -> MermaidViewerInputView { MermaidViewerInputView(model: model, onClose: onClose) }
    func updateNSView(_ view: MermaidViewerInputView, context: Context) {
        view.model = model
        view.onClose = onClose
    }
}

final class MermaidViewerInputView: NSView {
    var model: MermaidViewerModel
    var onClose: () -> Void
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(model: MermaidViewerModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { model.canvasDoubleClicked() }
        else { model.canvasMouseDown(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseDragged(with event: NSEvent) { model.canvasMouseDragged(to: convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { model.canvasMouseUp() }
    override func resignFirstResponder() -> Bool {
        model.canvasMouseUp()
        return super.resignFirstResponder()
    }

    override func scrollWheel(with event: NSEvent) {
        model.canvasScrolled(delta: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas,
            accelerated: !event.modifierFlags.intersection([.command, .control]).isEmpty,
            point: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        model.canvasMagnified(event.magnification, point: convert(event.locationInWindow, from: nil))
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { handleKey(event) || super.performKeyEquivalent(with: event) }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard model.canvasKeyPressed(event.characters ?? "", modifiers: event.modifierFlags) else { return false }
        if model.state.isClosed { onClose() }
        return true
    }
}

struct MermaidPreviewWindowPresenter: NSViewRepresentable {
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    let model: MermaidViewerModel?
    let foregroundRequest: UInt
    let show: Bool
    let onClose: (MermaidViewerModel) -> Void

    func makeCoordinator() -> MermaidPreviewWindowCoordinator { MermaidPreviewWindowCoordinator() }
    func makeNSView(context: Context) -> AttachmentPreviewAnchor {
        let view = AttachmentPreviewAnchor(frame: .zero)
        view.windowChanged = { [weak coordinator = context.coordinator] in coordinator?.observeParent($0) }
        return view
    }
    func updateNSView(_ view: AttachmentPreviewAnchor, context: Context) {
        context.coordinator.update(model: model, locale: locale, dark: colorScheme == .dark, show: show, onClose: onClose)
    }
    static func dismantleNSView(_ view: AttachmentPreviewAnchor, coordinator: MermaidPreviewWindowCoordinator) {
        coordinator.observeParent(nil)
        coordinator.closeAndNotify()
    }
}

@MainActor final class MermaidPreviewWindowCoordinator: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var model: MermaidViewerModel?
    private var foregroundRequest: UInt = 0
    private var onClose: ((MermaidViewerModel) -> Void)?
    private weak var parent: NSWindow?

    func observeParent(_ parent: NSWindow?) {
        guard self.parent !== parent else { return }
        if let old = self.parent {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: old)
            closeAndNotify()
        }
        self.parent = parent
        if let parent {
            NotificationCenter.default.addObserver(self, selector: #selector(parentWillClose),
                name: NSWindow.willCloseNotification, object: parent)
        }
    }

    @objc private func parentWillClose(_ notification: Notification) { closeAndNotify() }

    func update(model next: MermaidViewerModel?, locale: Locale, dark: Bool,
                show: Bool = true, onClose: @escaping (MermaidViewerModel) -> Void) {
        self.onClose = onClose
        guard let next, !next.state.isClosed else { dismiss(); return }
        if model === next, let window {
            window.title = FiliconLocalization.string("Diagram preview", language: locale.identifier)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            (window.contentView as? NSHostingView<AnyView>)?.rootView = content(model: next, locale: locale, dark: dark, window: window)
            if foregroundRequest != next.foregroundRequest, show { window.makeKeyAndOrderFront(nil) }
            foregroundRequest = next.foregroundRequest
            return
        }
        dismiss()
        model = next
        foregroundRequest = next.foregroundRequest
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentMinSize = NSSize(width: 540, height: 360)
        window.title = FiliconLocalization.string("Diagram preview", language: locale.identifier)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.delegate = self
        window.contentView = NSHostingView(rootView: content(model: next, locale: locale, dark: dark, window: window))
        self.window = window
        if let frame = parent?.screen?.visibleFrame { window.setFrame(frame, display: false) }
        else { window.center() }
        if show { window.makeKeyAndOrderFront(nil) }
    }

    private func content(model: MermaidViewerModel, locale: Locale, dark: Bool, window: NSWindow) -> AnyView {
        AnyView(MermaidViewerContent(model: model,
            onClose: { [weak self, weak model] in
                guard let self, let model, self.model === model else { return }
                closeAndNotify()
            }, onFullScreen: { [weak window] in window?.toggleFullScreen(nil) })
            .environment(\.locale, locale).environment(\.colorScheme, dark ? .dark : .light))
    }

    func dismiss(closeWindow: Bool = true) {
        let old = window
        window = nil
        model?.closeButtonTapped()
        model = nil
        old?.delegate = nil
        if closeWindow { old?.close() }
        old?.contentView = nil
    }

    func closeAndNotify(closeWindow: Bool = true) {
        let closed = model, callback = onClose
        dismiss(closeWindow: closeWindow)
        if let closed { Task { @MainActor in callback?(closed) } }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closeAndNotify(closeWindow: false)
    }
}
