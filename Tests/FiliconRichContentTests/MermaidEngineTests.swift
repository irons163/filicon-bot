import AppKit
import Foundation
import WebKit
import Testing
import CustomDump
@testable import FiliconRichContent

@Suite("Serialized offline Mermaid engine", .serialized, .timeLimit(.minutes(1)))
@MainActor struct MermaidEngineTests {
    @Test func queueSerializesAndSharesOnlyValidatedCachedResults() async throws {
        let driver = ManualDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        let first = Task { try await renderer.render(source: "pie one", theme: .light) }
        var starts = driver.starts.makeAsyncIterator()
        let firstStart = await starts.next()
        expectNoDifference(firstStart, "pie one:light")
        let second = Task { try await renderer.render(source: "pie two", theme: .dark) }
        let same = Task { try await renderer.render(source: "pie one", theme: .light) }
        driver.finish(.success(validSVG))
        let firstResult = try await first.value
        expectNoDifference(firstResult, .rendered(try #require(MermaidSVG.validated(validSVG))))
        let secondStart = await starts.next()
        expectNoDifference(secondStart, "pie two:dark")
        let duplicateResult = try await same.value
        expectNoDifference(duplicateResult, firstResult)
        driver.finish(.success(validSVG))
        _ = try await second.value
        expectNoDifference(driver.startCount, 2)
        _ = try await renderer.render(source: "pie two", theme: .dark)
        expectNoDifference(driver.startCount, 2)
    }

    @Test func queuedAndActiveCancellationRetireTheirOwnRequestAndIgnoreLateCompletions() async throws {
        let driver = ManualDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        var starts = driver.starts.makeAsyncIterator()
        let first = Task { try await renderer.render(source: "one", theme: .light) }
        let firstStart = await starts.next()
        expectNoDifference(firstStart, "one:light")
        let ready = AsyncStream.makeStream(of: Bool.self)
        let second = Task {
            ready.continuation.yield(true)
            return try await renderer.render(source: "two", theme: .light)
        }
        var readiness = ready.stream.makeAsyncIterator()
        #expect(await readiness.next() == true)
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        expectNoDifference(driver.startCount, 1)
        let old = try #require(driver.completion)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        expectNoDifference(driver.cancelCount, 1)
        let third = Task { try await renderer.render(source: "three", theme: .dark) }
        let thirdStart = await starts.next()
        expectNoDifference(thirdStart, "three:dark")
        old(.success("<script/>"))
        driver.finish(.success(validSVG))
        let thirdResult = try await third.value
        expectNoDifference(thirdResult, .rendered(try #require(MermaidSVG.validated(validSVG))))
        _ = try await renderer.render(source: "three", theme: .dark)
        expectNoDifference(driver.startCount, 2)
    }

    @Test func deadlinesCannotTimeOutANewerRequestAndDoNotCacheTransientFailures() async throws {
        let driver = ManualDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        var starts = driver.starts.makeAsyncIterator()
        let first = Task { try await renderer.render(source: "one", theme: .light) }
        _ = await starts.next()
        let old = try #require(driver.completion)
        renderer.deadlineReached(1)
        let firstResult = try await first.value
        expectNoDifference(firstResult, .fallback(.timedOut))
        let second = Task { try await renderer.render(source: "one", theme: .light) }
        _ = await starts.next()
        renderer.deadlineReached(1)
        old(.success(validSVG))
        driver.finish(.failure(.webProcessTerminated))
        let secondResult = try await second.value
        expectNoDifference(secondResult, .fallback(.webProcessTerminated))
        let third = Task { try await renderer.render(source: "one", theme: .light) }
        _ = await starts.next()
        driver.finish(.success(validSVG))
        let thirdResult = try await third.value
        expectNoDifference(thirdResult, .rendered(try #require(MermaidSVG.validated(validSVG))))
        expectNoDifference(driver.startCount, 3)
    }

    @Test func actualDeadlineReturnsWithoutAResponseAndShutsDownOnlyItsDriver() async throws {
        let driver = ManualDriver()
        let renderer = OfflineMermaidRenderer(driver: driver, deadline: .milliseconds(20))
        defer { renderer.shutdown() }
        let result = try await renderer.render(source: "one", theme: .light)
        expectNoDifference(result, .fallback(.timedOut))
        expectNoDifference(driver.cancelCount, 1)
    }

    @Test func invalidSourceIsNotExecutedAndUnsafeSVGIsNeverReturnedOrRetriedFromCache() async throws {
        let driver = ManualDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        for source in ["", " \n", "x\u{0000}y", String(repeating: "a", count: 65_537), String(repeating: "a\n", count: 1_001)] {
            let result = try await renderer.render(source: source, theme: .light)
            expectNoDifference(result, .fallback(.invalidSource))
        }
        expectNoDifference(driver.startCount, 0)
        let task = Task { try await renderer.render(source: "unsafe", theme: .light) }
        var starts = driver.starts.makeAsyncIterator()
        _ = await starts.next()
        driver.finish(.success("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1 1\"><image href=\"https://example.invalid\"/></svg>"))
        let result = try await task.value
        expectNoDifference(result, .fallback(.unsafeOutput))
        let cached = try await renderer.render(source: "unsafe", theme: .light)
        expectNoDifference(cached, .fallback(.unsafeOutput))
        expectNoDifference(driver.startCount, 1)
    }

    @Test func cacheKeepsThemeSeparatedAndEvictsAtTheEntryLimit() async throws {
        let driver = ManualDriver()
        driver.immediate = validSVG
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        for index in 0..<64 { _ = try await renderer.render(source: "fixture-\(index)", theme: .light) }
        _ = try await renderer.render(source: "fixture-0", theme: .light)
        expectNoDifference(driver.startCount, 64)
        _ = try await renderer.render(source: "fixture-0", theme: .dark)
        expectNoDifference(driver.startCount, 65)
        _ = try await renderer.render(source: "fixture-0", theme: .light)
        expectNoDifference(driver.startCount, 65)
        _ = try await renderer.render(source: "fixture-1", theme: .light)
        expectNoDifference(driver.startCount, 66)
    }

    @Test func cacheEvictsLargeDiagramsByBytesBeforeReachingTheEntryLimit() async throws {
        let driver = ManualDriver()
        driver.immediate = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><text>" + String(repeating: "x", count: 1_048_576) + "</text></svg>"
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        for index in 0..<9 { _ = try await renderer.render(source: "large-\(index)", theme: .light) }
        expectNoDifference(driver.startCount, 9)
        _ = try await renderer.render(source: "large-8", theme: .light)
        expectNoDifference(driver.startCount, 9)
        _ = try await renderer.render(source: "large-0", theme: .light)
        expectNoDifference(driver.startCount, 10)
    }

    @Test func queueIsBoundedAndShutdownResumesEveryWaitingRequestOnce() async throws {
        let driver = ManualDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        let ready = AsyncStream.makeStream(of: Int.self)
        var readiness = ready.stream.makeAsyncIterator()
        var tasks: [Task<MermaidEnginePresentation, any Error>] = []
        for index in 0..<32 {
            tasks.append(Task {
                ready.continuation.yield(index)
                return try await renderer.render(source: "fixture-\(index)", theme: .light)
            })
            let readied = await readiness.next()
            expectNoDifference(readied, index)
        }
        let extra = try await renderer.render(source: "extra", theme: .light)
        expectNoDifference(extra, .fallback(.queueFull))
        expectNoDifference(driver.startCount, 1)
        let old = try #require(driver.completion)
        renderer.shutdown()
        for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
        old(.success(validSVG))
        let next = Task { try await renderer.render(source: "next", theme: .light) }
        var starts = driver.starts.makeAsyncIterator()
        _ = await starts.next()
        let nextStart = await starts.next()
        expectNoDifference(nextStart, "next:light")
        driver.finish(.success(validSVG))
        #expect(try await next.value != .fallback(.unsafeOutput))
    }

    private var validSVG: String { "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 200 100\"><rect width=\"100\" height=\"40\"/></svg>" }

    @MainActor private final class ManualDriver: MermaidRenderDriver {
        let events = AsyncStream.makeStream(of: String.self)
        var starts: AsyncStream<String> { events.stream }
        var completion: (@MainActor (Result<String, MermaidEngineFailure>) -> Void)?
        var immediate: String?
        var startCount = 0
        var cancelCount = 0
        func start(source: String, theme: MermaidTheme, completion: @escaping @MainActor (Result<String, MermaidEngineFailure>) -> Void) {
            #expect(self.completion == nil)
            startCount += 1
            self.completion = completion
            events.continuation.yield("\(source):\(theme.rawValue)")
            if let immediate { finish(.success(immediate)) }
        }
        func finish(_ result: Result<String, MermaidEngineFailure>) {
            let callback = completion
            completion = nil
            callback?(result)
        }
        func cancel() { cancelCount += 1; completion = nil }
    }
}

@Suite("Actual public Mermaid engine in isolated WebKit", .serialized, .timeLimit(.minutes(1)))
@MainActor struct MermaidWebEngineTests {
    @Test(arguments: [MermaidTheme.light, .dark])
    func publicEngineRendersTwelveDiagramFamiliesWithoutPageScriptExecution(theme: MermaidTheme) async throws {
        _ = NSApplication.shared
        let driver = MermaidWebRenderDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        for source in sources {
            let result = try await renderer.render(source: source, theme: theme)
            guard case .rendered(let svg) = result else { Issue.record("Expected safe public-engine diagram: \(source) → \(result)"); continue }
            #expect(svg.width.isFinite && svg.width > 0 && svg.height.isFinite && svg.height > 0)
            #expect(svg.markup.contains("filicon-diagram"))
            let web = try #require(driver.webView)
            #expect(web.window == nil)
            #expect(!web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
            let page: Bool = try await evaluate(web, script: "Boolean(globalThis.mermaid || globalThis.diagramInjection)", world: .page)
            expectNoDifference(page, false)
            expectNoDifference(MermaidSVG.validated(svg.markup), svg)
        }
    }

    @Test func frontmatterCannotUnlockResourcesOrScriptsAndFailureDoesNotPoisonTheNextDiagram() async throws {
        _ = NSApplication.shared
        let driver = MermaidWebRenderDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        let source = "---\nconfig:\n  securityLevel: loose\n  maxEdges: 999999\n  themeCSS: '@import url(https://example.invalid/style)'\n---\nflowchart LR\nA[\"<img src='https://example.invalid/image' onerror='globalThis.diagramInjection=true'>\"]"
        let result = try await renderer.render(source: source, theme: .light)
        expectNoDifference(result, .fallback(.unsafeOutput))
        let web = try #require(driver.webView)
        let config: String = try await evaluate(web, script: "JSON.stringify({security:mermaid.mermaidAPI.getConfig().securityLevel,edges:mermaid.mermaidAPI.getConfig().maxEdges,css:mermaid.mermaidAPI.getConfig().themeCSS})", world: .defaultClient)
        let json = try #require(config.data(using: .utf8))
        let value = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        expectNoDifference(value["security"] as? String, "strict")
        expectNoDifference(value["edges"] as? Int, 512)
        expectNoDifference(value["css"] as? String, "")
        let page: Bool = try await evaluate(web, script: "Boolean(globalThis.diagramInjection)", world: .page)
        expectNoDifference(page, false)
        let recovery = try await renderer.render(source: sources[0], theme: .dark)
        guard case .rendered = recovery else { Issue.record("A refused resource must not poison a subsequent safe diagram"); return }
        let invalid = try await renderer.render(source: "not a diagram", theme: .light)
        expectNoDifference(invalid, .fallback(.invalidSource))
    }

    @Test func retirementDropsTheHiddenSurfaceAndNavigationNeverGrantsAHostOpener() async throws {
        _ = NSApplication.shared
        let driver = MermaidWebRenderDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        _ = try await renderer.render(source: sources[0], theme: .light)
        let retired = try #require(driver.webView)
        driver.cancel()
        #expect(driver.webView == nil && retired.navigationDelegate == nil && retired.uiDelegate == nil)
        for url in ["https://example.invalid", "http://127.0.0.1", "file:///private/fixture", "data:text/html,bad", "javascript:bad()", "sand-msg:fixture", "about:blank#jump"] {
            #expect(!MermaidEnginePolicy.allowsNavigation(URL(string: url)))
        }
        #expect(MermaidEnginePolicy.allowsNavigation(nil))
        #expect(MermaidEnginePolicy.allowsNavigation(URL(string: "about:blank")))
        #expect(MermaidEnginePolicy.contentSecurityPolicy.contains("img-src 'none'"))
        #expect(MermaidEnginePolicy.contentSecurityPolicy.contains("script-src 'none'"))
    }

    @Test func cancellationOfAnActualHiddenWebKitRequestCanRecoverOnANewSurface() async throws {
        _ = NSApplication.shared
        let driver = ObservedDriver()
        let renderer = OfflineMermaidRenderer(driver: driver)
        defer { renderer.shutdown() }
        var started = driver.events.stream.makeAsyncIterator()
        let first = Task { try await renderer.render(source: sources[0], theme: .light) }
        #expect(await started.next() == true)
        let retired = try #require(driver.base.webView)
        #expect(retired.window == nil)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(driver.base.webView == nil)
        #expect(retired.navigationDelegate == nil && retired.uiDelegate == nil)
        let recovery = try await renderer.render(source: sources[1], theme: .dark)
        guard case .rendered = recovery else { Issue.record("A cancelled hidden renderer must recover"); return }
        #expect(driver.base.webView !== retired)
        #expect(driver.base.webView?.window == nil)
        driver.base.webViewWebContentProcessDidTerminate(retired)
        #expect(driver.base.webView != nil)
    }

    private var sources: [String] { [
        "flowchart LR\nA{Choice} -->|Yes| B((Done))\nA -.-> C[Wait]",
        "sequenceDiagram\nparticipant A as Client\nparticipant B as Service\nA->>+B: Request\nNote over A,B: Reminder\nalt Accepted\nB-->>-A: Response\nelse Rejected\nB-->>A: Failure\nend",
        "stateDiagram-v2\n[*] --> Idle\nstate Active {\n[*] --> Working\nWorking --> Done\n}\nIdle --> Active\nActive --> [*]",
        "pie title Tasks\n\"Done\" : 7\n\"Waiting\" : 3",
        "classDiagram\nclass Animal {\n+String name\n+speak()\n}\nAnimal <|-- Bird",
        "erDiagram\nCUSTOMER ||--o{ ORDER : places\nCUSTOMER {\nstring name\n}",
        "gantt\ntitle Project\ndateFormat YYYY-MM-DD\nsection Plan\nDesign :a1, 2026-09-01, 3d\nBuild :after a1, 5d",
        "mindmap\n  root((Team))\n    Design\n    Build",
        "journey\ntitle Delivery\nsection Planning\nDesign: 5: Designer\nBuild: 3: Engineer",
        "timeline\ntitle Delivery\n2026 : Design : Build\n2027 : Review",
        "quadrantChart\ntitle Delivery priorities\nx-axis Low effort --> High effort\ny-axis Low value --> High value\nquadrant-1 Plan\nquadrant-2 Deliver\nquadrant-3 Ignore\nquadrant-4 Review\nDesign: [0.25, 0.75]\nBuild: [0.75, 0.75]",
        "requirementDiagram\nrequirement delivery {\nid: 1\ntext: Ready for delivery\nrisk: low\nverifymethod: test\n}\nelement build {\ntype: project\ndocref: Delivery\n}\nbuild - satisfies -> delivery"
    ] }

    private func evaluate<Value: Sendable>(_ web: WKWebView, script: String, world: WKContentWorld) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(script, in: nil, in: world) { result in
                switch result {
                case .success(let value):
                    if let typed = value as? Value { continuation.resume(returning: typed) }
                    else { continuation.resume(throwing: MermaidEngineFailure.engineFailure) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    @MainActor private final class ObservedDriver: MermaidRenderDriver {
        let base = MermaidWebRenderDriver()
        let events = AsyncStream.makeStream(of: Bool.self)
        func start(source: String, theme: MermaidTheme, completion: @escaping @MainActor (Result<String, MermaidEngineFailure>) -> Void) {
            base.start(source: source, theme: theme, completion: completion)
            events.continuation.yield(true)
        }
        func cancel() { base.cancel() }
    }
}
