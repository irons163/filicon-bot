import AppKit
import FiliconRichContent
import SwiftUI
import WebKit

enum MermaidSVGWebPolicy {
    static let contentSecurityPolicy = "default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src 'none'; font-src data:; connect-src 'none'; frame-src 'none'; worker-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
    static func allowsNavigation(_ url: URL?) -> Bool { url == nil || url?.absoluteString == "about:blank" }

    static func document(_ svg: MermaidSVG, dark: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="color-scheme" content="\(dark ? "dark" : "light")">
        <style>\(OfflineMathPresenter.stylesheet ?? "")
        html,body{margin:0!important;padding:0!important;width:100%!important;height:100%!important;overflow:hidden!important;color-scheme:\(dark ? "dark" : "light")!important;background:Canvas!important;color:CanvasText;font-family:-apple-system,system-ui;font-size:13px}
        #filicon-host-image{position:absolute!important;left:50%!important;top:50%!important;transform-origin:center center!important;visibility:hidden}
        </style></head><body><div id="filicon-host-image">\(svg.markup)</div></body></html>
        """
    }

    static let viewportJavaScript = #"""
    const image = document.getElementById('filicon-host-image');
    const svg = image?.firstElementChild;
    if (!svg || !Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) return false;
    globalThis.filiconSVGGeometryTicket = ticket;
    await document.fonts.ready;
    if (globalThis.filiconSVGGeometryTicket !== ticket || document.getElementById('filicon-host-image') !== image) return false;
    for (const element of [document.documentElement, document.body])
      element.style.setProperty('color-scheme',dark ? 'dark' : 'light','important');
    const viewport = document.documentElement.getBoundingClientRect();
    if (viewport.width <= 0 || viewport.height <= 0) return false;
    const scale = fit ? Math.min(1, viewport.width/width, viewport.height/height) : zoom;
    if (!Number.isFinite(scale) || scale <= 0 || scale > 8 || !Number.isFinite(x) || !Number.isFinite(y)) return false;
    for (const [property,value] of Object.entries({width:width+'px',height:height+'px','max-width':'none','max-height':'none','min-width':'0','min-height':'0',display:'block'}))
      svg.style.setProperty(property,value,'important');
    image.style.setProperty('width',width+'px','important');
    image.style.setProperty('height',height+'px','important');
    image.style.setProperty('transform',`translate(calc(-50% + ${x}px),calc(-50% + ${y}px)) scale(${scale})`,'important');
    image.style.setProperty('visibility','visible','important');
    return true;
    """#
}

struct MermaidSVGWebView: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let svg: MermaidSVG
    var transform: MermaidViewerTransform?
    var onFailure: @MainActor () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MermaidSVGNativeView {
        context.coordinator.makeView(svg: svg, transform: transform, dark: colorScheme == .dark, onFailure: onFailure)
    }
    func updateNSView(_ view: MermaidSVGNativeView, context: Context) {
        context.coordinator.update(svg: svg, transform: transform, dark: colorScheme == .dark, view: view, onFailure: onFailure)
    }
    static func dismantleNSView(_ view: MermaidSVGNativeView, coordinator: Coordinator) {
        coordinator.dismantle(view)
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private(set) var svg: MermaidSVG?
        private(set) var revision: UInt64 = 0
        private(set) var finished = false
        private(set) var ready = false
        private var geometryRevision: UInt64 = 0
        private var transform: MermaidViewerTransform?
        private var dark = false
        private var navigation: WKNavigation?
        private weak var webView: MermaidSVGNativeView?
        private var onFailure: (@MainActor () -> Void)?
        private var failed = false
        private var deadlineTask: Task<Void, Never>?

        func makeView(svg: MermaidSVG, transform: MermaidViewerTransform? = nil, dark: Bool = false,
                      onFailure: @escaping @MainActor () -> Void) -> MermaidSVGNativeView {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let view = MermaidSVGNativeView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self; view.uiDelegate = self
            view.underPageBackgroundColor = .clear
            view.allowsMagnification = false; view.allowsLinkPreview = false; view.isInspectable = false
            view.setAccessibilityIdentifier("offline-mermaid-svg")
            view.resized = { [weak self, weak view] in
                guard let view else { return }
                self?.viewportChanged(view)
            }
            update(svg: svg, transform: transform, dark: dark, view: view, onFailure: onFailure)
            return view
        }

        func update(svg next: MermaidSVG, transform: MermaidViewerTransform?, dark: Bool = false, view: MermaidSVGNativeView,
                    onFailure: @escaping @MainActor () -> Void) {
            self.onFailure = onFailure
            let changed = self.transform != transform || self.dark != dark
            self.transform = transform
            self.dark = dark
            guard svg != next || webView !== view else {
                if changed { viewportChanged(view) }
                return
            }
            if let previous = webView, previous !== view {
                previous.resized = nil; previous.navigationDelegate = nil; previous.uiDelegate = nil; previous.stopLoading()
            }
            revision &+= 1
            webView = view; svg = next; finished = false; ready = false; failed = false
            navigation = view.loadHTMLString(MermaidSVGWebPolicy.document(next, dark: dark), baseURL: nil)
            deadlineTask?.cancel()
            let document = revision
            deadlineTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.deadlineReached(document)
            }
        }

        func viewportChanged(_ view: MermaidSVGNativeView) {
            guard view === webView, finished, !failed, let svg, view.bounds.width > 0, view.bounds.height > 0 else { return }
            geometryRevision &+= 1
            let document = revision, geometry = geometryRevision
            view.callAsyncJavaScript(MermaidSVGWebPolicy.viewportJavaScript,
                arguments: ["width": svg.width, "height": svg.height, "fit": transform == nil,
                    "dark": dark,
                    "zoom": transform?.scale ?? 1, "x": transform?.x ?? 0, "y": transform?.y ?? 0,
                    "ticket": String(geometry)], in: nil, in: .defaultClient) { [weak self, weak view] result in
                guard let self, let view, view === webView, revision == document,
                      geometryRevision == geometry, finished, !failed else { return }
                guard case .success(let value) = result, value as? Bool == true else { displayFailed(view); return }
                ready = true
                deadlineTask?.cancel(); deadlineTask = nil
            }
        }

        func dismantle(_ view: MermaidSVGNativeView) {
            guard view === webView else { return }
            revision &+= 1; geometryRevision &+= 1
            deadlineTask?.cancel(); deadlineTask = nil
            svg = nil; navigation = nil; webView = nil; onFailure = nil; transform = nil
            finished = false; ready = false; failed = true
            view.resized = nil; view.navigationDelegate = nil; view.uiDelegate = nil; view.stopLoading()
        }

        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            guard view === webView, let navigation, navigation === self.navigation, let view = view as? MermaidSVGNativeView else { return }
            self.navigation = nil; finished = true
            viewportChanged(view)
        }
        private func displayFailed(_ view: WKWebView) {
            guard view === webView, !failed else { return }
            failed = true; ready = false; finished = false
            deadlineTask?.cancel(); deadlineTask = nil
            view.stopLoading()
            onFailure?()
        }
        func deadlineReached(_ document: UInt64) {
            guard revision == document, !ready, let webView else { return }
            displayFailed(webView)
        }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if let navigation, navigation === self.navigation { displayFailed(view) }
        }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if let navigation, navigation === self.navigation { displayFailed(view) }
        }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { displayFailed(view) }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(view === webView && action.navigationType != .linkActivated && !action.shouldPerformDownload
                && action.targetFrame?.isMainFrame == true && MermaidSVGWebPolicy.allowsNavigation(action.request.url) ? .allow : .cancel)
        }
        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            decisionHandler(view === webView && response.isForMainFrame && response.canShowMIMEType
                && MermaidSVGWebPolicy.allowsNavigation(response.response.url) ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.cancel() }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.cancel() }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) { completionHandler(nil) }
    }
}

@MainActor final class MermaidSVGNativeView: WKWebView {
    var resized: (@MainActor () -> Void)?
    private var lastSize = CGSize.zero
    override func layout() {
        super.layout()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        resized?()
    }
}
