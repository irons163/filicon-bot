import AppKit
import FiliconRichContent
import Observation
import SwiftUI

struct MermaidFigureRequest: Hashable {
    let source: String
    let theme: MermaidTheme
}

@MainActor @Observable final class MermaidRenderedFigureModel {
    private(set) var request: MermaidFigureRequest?
    private(set) var presentation: MermaidEnginePresentation?
    private(set) var viewer: MermaidViewerModel?
    @ObservationIgnored private(set) var revision: UInt64 = 0
    @ObservationIgnored private let render: @MainActor (String, MermaidTheme) async throws -> MermaidEnginePresentation

    init(render: @escaping @MainActor (String, MermaidTheme) async throws -> MermaidEnginePresentation = {
        try await OfflineMermaidRenderer.shared.render(source: $0, theme: $1)
    }) { self.render = render }

    func task(request next: MermaidFigureRequest) async {
        messageChanged(next)
        revision &+= 1
        let ticket = revision
        viewer?.closeButtonTapped()
        viewer = nil
        presentation = nil
        do {
            let result = try await render(next.source, next.theme)
            guard !Task.isCancelled, revision == ticket, request == next else { return }
            presentation = result
        } catch {
            guard !Task.isCancelled, revision == ticket, request == next else { return }
            presentation = .fallback(.engineFailure)
        }
    }

    func messageChanged(_ next: MermaidFigureRequest) {
        guard request != next else { return }
        figureRemoved()
        request = next
    }

    func figureClicked(request expected: MermaidFigureRequest, revision expectedRevision: UInt64) {
        guard revision == expectedRevision, request == expected, case .rendered(let svg) = presentation else { return }
        if let viewer, !viewer.state.isClosed { viewer.figureOpenedAgain() }
        else { viewer = MermaidViewerModel(svg: svg, source: expected.source) }
    }

    func svgDisplayFailed(_ svg: MermaidSVG, request expected: MermaidFigureRequest, revision expectedRevision: UInt64) {
        guard revision == expectedRevision, request == expected, presentation == .rendered(svg) else { return }
        viewer?.closeButtonTapped()
        viewer = nil
        presentation = .fallback(.engineFailure)
    }

    func figureRemoved() {
        revision &+= 1
        viewer?.closeButtonTapped()
        viewer = nil
        request = nil
        presentation = nil
    }

    func previewClosed(_ closed: MermaidViewerModel) {
        guard viewer === closed else { return }
        viewer?.closeButtonTapped()
        viewer = nil
    }
}

struct OfflineMermaidView: View {
    @Environment(\.colorScheme) private var colorScheme
    let source: String
    @State private var model = MermaidRenderedFigureModel()

    var body: some View {
        let request = MermaidFigureRequest(source: source, theme: colorScheme == .dark ? .dark : .light)
        Group {
            if model.request == request, case .rendered(let svg) = model.presentation {
                OfflineMermaidFigure(model: model, svg: svg, request: request, revision: model.revision)
            } else {
                MermaidSourceFallback(source: source, isLoading: model.request != request || model.presentation == nil)
            }
        }
        .task(id: request) { await model.task(request: request) }
        .onChange(of: request) { _, next in model.messageChanged(next) }
        .onDisappear { model.figureRemoved() }
    }
}

struct MermaidSourceFallback: View {
    @Environment(\.locale) private var locale
    let source: String
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(FiliconLocalization.string("Rendering diagram…", language: locale.identifier))
                }.font(.caption).foregroundStyle(.secondary)
            } else {
                Label(FiliconLocalization.string("Diagram shown as source", language: locale.identifier), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(240, max(48, Double(source.split(separator: "\n", omittingEmptySubsequences: false).count) * 16)))
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct OfflineMermaidFigure: View {
    @Environment(\.locale) private var locale
    let model: MermaidRenderedFigureModel
    let svg: MermaidSVG
    let request: MermaidFigureRequest
    let revision: UInt64
    var showsPreviewWindow = true
    @State private var width: Double = 320

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            MermaidExpandButton { model.figureClicked(request: request, revision: revision) }.fixedSize()
            GeometryReader { geometry in
                MermaidSVGWebView(svg: svg, onFailure: { model.svgDisplayFailed(svg, request: request, revision: revision) })
                    .allowsHitTesting(false)
                    .overlay(MermaidFigureInput { model.figureClicked(request: request, revision: revision) })
                    .onAppear { width = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, value in width = value }
            }.frame(height: min(480, max(90, svg.height * min(1, max(1, width) / svg.width))))
        }
        .padding(6).frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(FiliconLocalization.string("Diagram preview", language: locale.identifier))
        .accessibilityAction(named: FiliconLocalization.string("Open diagram full screen", language: locale.identifier)) { model.figureClicked(request: request, revision: revision) }
        .background(MermaidPreviewWindowPresenter(model: model.viewer,
            foregroundRequest: model.viewer?.foregroundRequest ?? 0, show: showsPreviewWindow,
            onClose: model.previewClosed))
    }
}

struct MermaidFigureInput: NSViewRepresentable {
    @Environment(\.locale) private var locale
    let action: () -> Void

    func makeCoordinator() -> MermaidExpandButton.Coordinator { .init(action: action) }
    func makeNSView(context: Context) -> MermaidFigureNativeButton {
        let button = MermaidFigureNativeButton(title: "", target: context.coordinator,
            action: #selector(MermaidExpandButton.Coordinator.buttonClicked))
        button.isTransparent = true
        button.isBordered = false
        return button
    }
    func updateNSView(_ button: MermaidFigureNativeButton, context: Context) {
        context.coordinator.action = action
        button.setAccessibilityLabel(FiliconLocalization.string("Open diagram full screen", language: locale.identifier))
    }
}

final class MermaidFigureNativeButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self, event.characters == "\r" || event.characters == " ",
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            performClick(nil)
        } else { super.keyDown(with: event) }
    }
}
