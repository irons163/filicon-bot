import AppKit
import CustomDump
import FiliconRichContent
import SwiftUI
import Testing
@testable import Filicon

@Suite("Offline Mermaid figure lifecycle", .serialized, .timeLimit(.minutes(1)))
@MainActor struct OfflineMermaidFigureTests {
    @Test func initializationDoesNotRenderOrCreateAWindow() {
        var renders = 0
        let model = MermaidRenderedFigureModel(render: { _, _ in renders += 1; return .fallback(.engineFailure) })
        expectNoDifference(renders, 0)
        #expect(model.request == nil && model.presentation == nil && model.viewer == nil)
    }

    @Test func oldDisplayFailureCannotInvalidateTheSameSourceAfterRemovalAndReappearance() async throws {
        let svg = try validSVG("Fixture")
        let model = MermaidRenderedFigureModel(render: { _, _ in .rendered(svg) })
        let request = MermaidFigureRequest(source: "pie Fixture", theme: .light)
        await model.task(request: request)
        let oldRevision = model.revision
        let oldFailure = { model.svgDisplayFailed(svg, request: request, revision: oldRevision) }
        model.figureRemoved()
        await model.task(request: request)
        model.figureClicked(request: request, revision: model.revision)
        let current = try #require(model.viewer)
        oldFailure()
        expectNoDifference(model.presentation, .rendered(svg))
        #expect(model.viewer === current)
        #expect(!current.state.isClosed)
        model.figureRemoved()
    }

    @Test(arguments: [false, true])
    func sourceAndThemeChangesRejectLateResultsAndFailures(changeTheme: Bool) async throws {
        let probe = FigureRenderProbe()
        defer { probe.finishAll() }
        let model = MermaidRenderedFigureModel(render: probe.render)
        let first = MermaidFigureRequest(source: "first", theme: .light)
        let second = MermaidFigureRequest(source: changeTheme ? "first" : "second", theme: changeTheme ? .dark : .light)
        var started = probe.starts.makeAsyncIterator()
        let old = Task { await model.task(request: first) }
        let firstStarted = await started.next()
        expectNoDifference(firstStarted, first)
        let oldRevision = model.revision
        let fresh = Task { await model.task(request: second) }
        let secondStarted = await started.next()
        expectNoDifference(secondStarted, second)
        let svg = try validSVG("New")
        probe.finish(1, with: .success(.rendered(svg)))
        await fresh.value
        probe.finish(0, with: .failure(FigureRenderFailure.fixture))
        await old.value
        model.svgDisplayFailed(svg, request: first, revision: oldRevision)
        model.figureClicked(request: first, revision: oldRevision)
        expectNoDifference(model.request, second)
        expectNoDifference(model.presentation, .rendered(svg))
        #expect(model.viewer == nil)
        model.figureRemoved()
    }

    @Test(arguments: [false, true])
    func cancellationOrRemovalRejectsALateSuccessfulRenderer(remove: Bool) async throws {
        let probe = FigureRenderProbe()
        defer { probe.finishAll() }
        let model = MermaidRenderedFigureModel(render: probe.render)
        let request = MermaidFigureRequest(source: "fixture", theme: .light)
        var started = probe.starts.makeAsyncIterator()
        let task = Task { await model.task(request: request) }
        let requestStarted = await started.next()
        expectNoDifference(requestStarted, request)
        if remove { model.figureRemoved() } else { task.cancel() }
        probe.finish(0, with: .success(.rendered(try validSVG("Late"))))
        await task.value
        #expect(model.presentation == nil && model.viewer == nil)
        expectNoDifference(model.request, remove ? nil : request)
        model.figureRemoved()
    }

    @Test func repeatedOpenPreservesZoomAndOldButtonsAndChildCloseCannotTouchANewerViewer() async throws {
        let svg = try validSVG("Fixture")
        let model = MermaidRenderedFigureModel(render: { _, _ in .rendered(svg) })
        let request = MermaidFigureRequest(source: "pie Fixture", theme: .light)
        await model.task(request: request)
        let oldRevision = model.revision
        model.figureClicked(request: request, revision: oldRevision)
        let first = try #require(model.viewer)
        first.viewportResized(CGSize(width: 300, height: 200))
        first.zoomInButtonTapped()
        let before = first.state
        model.figureClicked(request: request, revision: oldRevision)
        model.messageChanged(request)
        #expect(model.viewer === first)
        expectNoDifference(first.foregroundRequest, 1)
        expectNoDifference(first.state, before)
        await model.task(request: request)
        #expect(first.state.isClosed && model.viewer == nil)
        model.figureClicked(request: request, revision: oldRevision)
        #expect(model.viewer == nil)
        model.figureClicked(request: request, revision: model.revision)
        let second = try #require(model.viewer)
        model.previewClosed(first)
        #expect(model.viewer === second)
        model.previewClosed(second)
        #expect(second.state.isClosed && model.viewer == nil)
        expectNoDifference(model.presentation, .rendered(svg))
        model.figureRemoved()
    }

    @Test func currentDisplayFailurePreservesSourceAndCanRecover() async throws {
        let svg = try validSVG("Fixture")
        let model = MermaidRenderedFigureModel(render: { _, _ in .rendered(svg) })
        let request = MermaidFigureRequest(source: "exact <raw> source", theme: .dark)
        await model.task(request: request)
        model.figureClicked(request: request, revision: model.revision)
        let first = try #require(model.viewer)
        model.svgDisplayFailed(svg, request: request, revision: model.revision)
        expectNoDifference(model.presentation, .fallback(.engineFailure))
        expectNoDifference(model.request, request)
        #expect(first.state.isClosed && model.viewer == nil)
        model.figureClicked(request: request, revision: model.revision)
        #expect(model.viewer == nil)
        await model.task(request: request)
        expectNoDifference(model.presentation, .rendered(svg))
        model.figureRemoved()
    }

    @Test func rendererFailureShowsSourceWithoutAnExpansionAction() async {
        let model = MermaidRenderedFigureModel(render: { _, _ in throw FigureRenderFailure.fixture })
        let request = MermaidFigureRequest(source: "raw", theme: .light)
        await model.task(request: request)
        expectNoDifference(model.presentation, .fallback(.engineFailure))
        expectNoDifference(model.request, request)
        model.figureClicked(request: request, revision: model.revision)
        #expect(model.viewer == nil)
        model.figureRemoved()
    }

    private func validSVG(_ text: String) throws -> MermaidSVG {
        try #require(MermaidSVG.validated("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 200\"><text x=\"10\" y=\"30\">\(text)</text></svg>"))
    }
}

@MainActor private final class FigureRenderProbe {
    let starts: AsyncStream<MermaidFigureRequest>
    private let started: AsyncStream<MermaidFigureRequest>.Continuation
    private var pending: [CheckedContinuation<MermaidEnginePresentation, any Error>?] = []

    init() {
        let pair = AsyncStream.makeStream(of: MermaidFigureRequest.self)
        starts = pair.stream; started = pair.continuation
    }

    func render(_ source: String, _ theme: MermaidTheme) async throws -> MermaidEnginePresentation {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            started.yield(.init(source: source, theme: theme))
        }
    }

    func finish(_ index: Int, with result: Result<MermaidEnginePresentation, any Error>) {
        pending[index]?.resume(with: result)
        pending[index] = nil
    }

    func finishAll() {
        for index in pending.indices { finish(index, with: .failure(CancellationError())) }
        started.finish()
    }
}

private enum FigureRenderFailure: Error { case fixture }
