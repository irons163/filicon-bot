import Foundation
import WebKit

public enum MermaidTheme: String, Sendable, Hashable {
    case light, dark
}

public enum MermaidEngineFailure: String, Sendable, Equatable, Error {
    case unavailable, invalidSource, unsafeOutput, timedOut, queueFull, webProcessTerminated, engineFailure
}

public enum MermaidEnginePresentation: Sendable, Equatable {
    case rendered(MermaidSVG)
    case fallback(MermaidEngineFailure)
}

enum MermaidEnginePolicy {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"

    static func acceptsSource(_ source: String) -> Bool {
        source.utf8.count <= 65_536 && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && source.split(separator: "\n", omittingEmptySubsequences: false).count <= 1_000 && !source.contains("\u{0000}")
    }

    static func allowsNavigation(_ url: URL?) -> Bool { url == nil || url?.absoluteString == "about:blank" }

    static let document = """
    <!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
    <style>\(OfflineMathPresenter.stylesheet ?? "")
    html,body{margin:0;padding:0;background:transparent;font-family:-apple-system,system-ui;font-size:13px}
    #render{width:1200px}*,*::before,*::after{animation:none!important;transition:none!important}
    </style></head><body><div id="render"></div></body></html>
    """

    static let renderJavaScript = #"""
    const container = document.getElementById('render');
    container.replaceChildren();
    mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:theme === 'dark' ? 'dark' : 'default',
      fontFamily:'inherit',themeCSS:'',maxTextSize:65536,maxEdges:512,suppressErrorRendering:true,logLevel:5,
      deterministicIds:true,deterministicIDSeed:'filicon-offline',
      secure:['secure','securityLevel','startOnLoad','fontFamily','theme','themeCSS','themeVariables','logLevel',
        'maxTextSize','maxEdges','suppressErrorRendering','deterministicIds','deterministicIDSeed','look',
        'handDrawnSeed','htmlLabels','flowchart','sequence','gantt','layout','registerLayoutLoaders'],
      flowchart:{htmlLabels:true}});
    try {
      const parsed = await mermaid.parse(source,{suppressErrors:true});
      if (!parsed) return {valid:false};
      const result = await mermaid.render('filicon-diagram',source,container);
      const svg = result.svg;
      container.replaceChildren();
      if (typeof svg !== 'string' || svg.length > 2097152) return {valid:true,oversized:true};
      return {valid:true,svg};
    } catch (_) {
      container.replaceChildren();
      return {valid:false};
    }
    """#
}

@MainActor protocol MermaidRenderDriver: AnyObject {
    func start(source: String, theme: MermaidTheme, completion: @escaping @MainActor (Result<String, MermaidEngineFailure>) -> Void)
    func cancel()
}

@MainActor public final class OfflineMermaidRenderer {
    public static let shared = OfflineMermaidRenderer()
    static let maximumRequests = 32
    static let maximumCacheEntries = 64
    static let maximumCacheBytes = 8_388_608

    private struct Key: Hashable {
        let source: String
        let theme: MermaidTheme
    }

    private struct Request {
        let id: UInt64
        let key: Key
        let continuation: CheckedContinuation<MermaidEnginePresentation, any Error>
    }

    private let driver: any MermaidRenderDriver
    private let deadline: Duration
    private var nextID: UInt64 = 0
    private var active: Request?
    private var waiting: [Request] = []
    private var deadlineTask: Task<Void, Never>?
    private var cache: [Key: MermaidEnginePresentation] = [:]
    private var cacheOrder: [Key] = []
    private var cacheBytes = 0

    public convenience init() { self.init(driver: MermaidWebRenderDriver(), deadline: .seconds(20)) }

    init(driver: any MermaidRenderDriver, deadline: Duration = .seconds(20)) {
        self.driver = driver
        self.deadline = deadline
    }

    public func render(source: String, theme: MermaidTheme) async throws -> MermaidEnginePresentation {
        try Task.checkCancellation()
        guard MermaidEnginePolicy.acceptsSource(source) else { return .fallback(.invalidSource) }
        let key = Key(source: source, theme: theme)
        if let result = cache[key] {
            cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
            return result
        }
        guard waiting.count + (active == nil ? 0 : 1) < Self.maximumRequests else { return .fallback(.queueFull) }
        nextID &+= 1
        let id = nextID
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append(.init(id: id, key: key, continuation: continuation))
                advance()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        try Task.checkCancellation()
        return result
    }

    private func advance() {
        guard active == nil, !waiting.isEmpty else { return }
        while let first = waiting.first, let cached = cache[first.key] {
            waiting.removeFirst().continuation.resume(returning: cached)
        }
        guard !waiting.isEmpty else { return }
        let request = waiting.removeFirst()
        active = request
        let interval = deadline
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: interval) } catch { return }
            self?.deadlineReached(request.id)
        }
        driver.start(source: request.key.source, theme: request.key.theme) { [weak self] in self?.completed($0, id: request.id) }
    }

    private func completed(_ result: Result<String, MermaidEngineFailure>, id: UInt64) {
        guard let request = active, request.id == id else { return }
        let presentation: MermaidEnginePresentation
        switch result {
        case .success(let source):
            if let svg = MermaidSVG.validated(source) { presentation = .rendered(svg) }
            else { presentation = .fallback(.unsafeOutput) }
        case .failure(let error): presentation = .fallback(error)
        }
        deadlineTask?.cancel(); deadlineTask = nil
        active = nil
        if case .rendered = presentation { remember(presentation, key: request.key) }
        else if presentation == .fallback(.invalidSource) || presentation == .fallback(.unsafeOutput) { remember(presentation, key: request.key) }
        request.continuation.resume(returning: presentation)
        advance()
    }

    func deadlineReached(_ id: UInt64) {
        guard active?.id == id else { return }
        driver.cancel()
        completed(.failure(.timedOut), id: id)
    }

    private func cancel(_ id: UInt64) {
        if let request = active, request.id == id {
            deadlineTask?.cancel(); deadlineTask = nil
            driver.cancel()
            active = nil
            request.continuation.resume(throwing: CancellationError())
            advance()
        } else if let index = waiting.firstIndex(where: { $0.id == id }) {
            waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    func shutdown() {
        deadlineTask?.cancel(); deadlineTask = nil
        driver.cancel()
        let requests = (active.map { [$0] } ?? []) + waiting
        active = nil; waiting.removeAll()
        cache.removeAll(); cacheOrder.removeAll(); cacheBytes = 0
        for request in requests { request.continuation.resume(throwing: CancellationError()) }
    }

    private func remember(_ presentation: MermaidEnginePresentation, key: Key) {
        let size = weight(presentation, key: key)
        guard size <= Self.maximumCacheBytes else { return }
        if let previous = cache.removeValue(forKey: key) {
            cacheBytes -= weight(previous, key: key)
            cacheOrder.removeAll { $0 == key }
        }
        while cacheOrder.count >= Self.maximumCacheEntries || cacheBytes + size > Self.maximumCacheBytes {
            guard !cacheOrder.isEmpty else { return }
            let removed = cacheOrder.removeFirst()
            if let value = cache.removeValue(forKey: removed) { cacheBytes -= weight(value, key: removed) }
        }
        cache[key] = presentation; cacheOrder.append(key); cacheBytes += size
    }

    private func weight(_ value: MermaidEnginePresentation, key: Key) -> Int {
        if case .rendered(let svg) = value { return key.source.utf8.count + svg.markup.utf8.count }
        return key.source.utf8.count
    }
}

@MainActor final class MermaidWebRenderDriver: NSObject, MermaidRenderDriver, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private var navigation: WKNavigation?
    private var engineLoaded = false
    private var revision: UInt64 = 0
    private var source = ""
    private var theme = MermaidTheme.light
    private var completion: (@MainActor (Result<String, MermaidEngineFailure>) -> Void)?

    func start(source: String, theme: MermaidTheme, completion: @escaping @MainActor (Result<String, MermaidEngineFailure>) -> Void) {
        guard self.completion == nil else { completion(.failure(.engineFailure)); return }
        revision &+= 1
        self.source = source; self.theme = theme; self.completion = completion
        guard OfflineMermaidResources.verified != nil else { finish(.failure(.unavailable)); return }
        if let webView, engineLoaded { render(webView, revision: revision); return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.isInspectable = false; view.allowsLinkPreview = false; view.allowsMagnification = false
        webView = view
        navigation = view.loadHTMLString(MermaidEnginePolicy.document, baseURL: nil)
    }

    func cancel() {
        revision &+= 1
        completion = nil; source = ""; engineLoaded = false; navigation = nil
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil; webView?.stopLoading()
        webView = nil
    }

    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        guard view === webView, navigation === self.navigation, completion != nil,
              let script = OfflineMermaidResources.verified?.script else { return }
        self.navigation = nil
        let ticket = revision
        view.evaluateJavaScript(script + "\n;true;", in: nil, in: .defaultClient) { [weak self, weak view] result in
            guard let self, let view, owned(view, revision: ticket) else { return }
            guard case .success = result else { failAndRetire(.engineFailure); return }
            engineLoaded = true
            render(view, revision: ticket)
        }
    }

    private func render(_ view: WKWebView, revision ticket: UInt64) {
        view.callAsyncJavaScript(MermaidEnginePolicy.renderJavaScript, arguments: ["source": source, "theme": theme.rawValue], in: nil, in: .defaultClient) { [weak self, weak view] result in
            guard let self, let view, owned(view, revision: ticket) else { return }
            guard case .success(let value) = result, let object = value as? [String: Any], let valid = object["valid"] as? Bool else {
                failAndRetire(.engineFailure); return
            }
            if !valid { finish(.failure(.invalidSource)); return }
            guard let svg = object["svg"] as? String, svg.utf8.count <= MermaidSVG.maximumBytes else {
                finish(.failure(.unsafeOutput)); return
            }
            finish(.success(svg))
        }
    }

    private func owned(_ view: WKWebView, revision ticket: UInt64) -> Bool {
        view === webView && revision == ticket && completion != nil
    }

    private func finish(_ result: Result<String, MermaidEngineFailure>) {
        let callback = completion
        completion = nil; source = ""
        callback?(result)
    }

    private func failAndRetire(_ error: MermaidEngineFailure) {
        let callback = completion
        cancel()
        callback?(.failure(error))
    }

    func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(view === webView && action.navigationType != .linkActivated && !action.shouldPerformDownload
            && action.targetFrame?.isMainFrame == true && MermaidEnginePolicy.allowsNavigation(action.request.url) ? .allow : .cancel)
    }

    func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(view === webView && response.isForMainFrame && response.canShowMIMEType
            && MermaidEnginePolicy.allowsNavigation(response.response.url) ? .allow : .cancel)
    }

    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        if view === webView, navigation === self.navigation { failAndRetire(.engineFailure) }
    }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        if view === webView, navigation === self.navigation { failAndRetire(.engineFailure) }
    }
    func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
        if view === webView { failAndRetire(.webProcessTerminated) }
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel() }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel() }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
}
