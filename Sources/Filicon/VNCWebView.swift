import AppKit
import SwiftUI
import WebKit
import FiliconComputer

struct VNCWebView: NSViewRepresentable {
    let url: URL
    let sessionToken: String
    let accountID: String
    let computerID: String
    let onRendererCrash: @MainActor () -> Void
    let onVisible: @MainActor () -> Void
    var onUserPresence: @MainActor (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            url: url,
            sessionToken: sessionToken,
            accountID: accountID,
            computerID: computerID,
            onRendererCrash: onRendererCrash,
            onVisible: onVisible,
            onUserPresence: onUserPresence
        )
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator,
            contentWorld: context.coordinator.contentWorld,
            name: Coordinator.messageHandlerName
        )
        let view = IsolatedVNCWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.update(
            url: url,
            sessionToken: sessionToken,
            accountID: accountID,
            computerID: computerID
        )
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.messageHandlerName,
            contentWorld: coordinator.contentWorld
        )
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        static let messageHandlerName = "filiconVNCBridge"
        let contentWorld = WKContentWorld.world(name: VNCIsolationPolicy.contentWorldName)

        weak var webView: WKWebView?
        private var url: URL
        private var token: String
        private var accountID: String
        private var computerID: String
        private var policy: VNCTrustPolicy
        private var isolation: VNCIsolationPolicy?
        private var bridge: VNCTrustedBridge?
        private var bridgeSession: VNCBridgeSession?
        private var configurationRevision: UInt64 = 0
        private var authorityTask: Task<Void, Never>?
        private let onRendererCrash: @MainActor () -> Void
        private let onVisible: @MainActor () -> Void
        private let onUserPresence: @MainActor (Bool) -> Void

        var authorityIdentity: (accountID: String, computerID: String) {
            (accountID, computerID)
        }

        init(
            url: URL,
            sessionToken: String,
            accountID: String,
            computerID: String,
            onRendererCrash: @escaping @MainActor () -> Void,
            onVisible: @escaping @MainActor () -> Void,
            onUserPresence: @escaping @MainActor (Bool) -> Void
        ) {
            self.url = url
            token = sessionToken
            self.accountID = accountID
            self.computerID = computerID
            policy = Self.makePolicy(url: url, token: sessionToken)
            self.onRendererCrash = onRendererCrash
            self.onVisible = onVisible
            self.onUserPresence = onUserPresence
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            rebuildAuthorities()
        }

        func update(url: URL, sessionToken: String, accountID: String, computerID: String) {
            guard self.url != url || token != sessionToken || self.accountID != accountID || self.computerID != computerID else { return }
            self.url = url
            token = sessionToken
            self.accountID = accountID
            self.computerID = computerID
            policy = Self.makePolicy(url: url, token: sessionToken)
            rebuildAuthorities()
        }

        func invalidate() {
            configurationRevision &+= 1
            authorityTask?.cancel()
            authorityTask = nil
            bridgeSession = nil
            isolation = nil
            bridge = nil
        }

        private func rebuildAuthorities() {
            configurationRevision &+= 1
            let revision = configurationRevision
            authorityTask?.cancel()
            bridgeSession = nil
            guard let origin = Self.origin(of: url), !accountID.isEmpty, !computerID.isEmpty else { return }
            let nextIsolation: VNCIsolationPolicy
            do {
                nextIsolation = try VNCIsolationPolicy(
                    accountID: accountID,
                    computerID: computerID,
                    allowedOrigin: origin,
                    tokenOrigin: origin,
                    now: Self.nowMilliseconds
                )
            } catch { return }
            let nextBridge = VNCTrustedBridge(
                clipboard: .macOS(),
                now: Self.nowMilliseconds,
                onUserPresence: { [weak self] present in
                    await MainActor.run { self?.onUserPresence(present) }
                }
            )
            isolation = nextIsolation
            bridge = nextBridge
            authorityTask = Task { [weak self] in
                guard let self else { return }
                let session = await nextIsolation.currentSession()
                do {
                    let installed = try await nextBridge.install(
                        frameURL: self.url,
                        trustPolicy: self.policy,
                        generation: session.generation
                    )
                    guard !Task.isCancelled, self.configurationRevision == revision else { return }
                    self.bridgeSession = installed
                    self.installBridgeScript(generation: session.generation)
                    self.load(self.url)
                } catch {
                    guard self.configurationRevision == revision else { return }
                    self.bridgeSession = nil
                }
            }
        }

        private func installBridgeScript(generation: UInt64) {
            guard let controller = webView?.configuration.userContentController else { return }
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: Self.bridgeScript(generation: generation),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: contentWorld
            ))
        }

        private func load(_ url: URL) {
            guard let webView, bridgeSession != nil,
                  let trustHeaders = policy.authorizationHeaders(for: url) else { return }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            for (name, value) in trustHeaders { request.setValue(value, forHTTPHeaderField: name) }
            webView.load(request)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let destination = navigationAction.request.url else { return .cancel }
            if destination.absoluteString == "about:blank" { return .allow }
            guard !navigationAction.shouldPerformDownload,
                  case .allowed = policy.evaluate(destination),
                  let isolation,
                  await isolation.navigation(to: destination, isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true) == .allow
            else { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            guard navigationResponse.canShowMIMEType,
                  let destination = navigationResponse.response.url,
                  case .allowed = policy.evaluate(destination) else { return .cancel }
            return .allow
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            let isolation = isolation
            let bridge = bridge
            let policy = policy
            let currentURL = url
            authorityTask?.cancel()
            authorityTask = Task { [weak self] in
                guard let self, let isolation, let bridge else { return }
                do {
                    let disposition = try await isolation.processDidCrash()
                    self.onRendererCrash()
                    guard case .reload(let generation) = disposition else { return }
                    let installed = try await bridge.install(frameURL: currentURL, trustPolicy: policy, generation: generation)
                    self.bridgeSession = installed
                    self.installBridgeScript(generation: generation)
                    self.load(currentURL)
                } catch {
                    self.bridgeSession = nil
                    self.onRendererCrash()
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onVisible()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? { nil }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) async -> (Any?, String?) {
            guard message.name == Self.messageHandlerName,
                  message.frameInfo.isMainFrame,
                  let frameURL = message.frameInfo.request.url,
                  let webView,
                  !webView.isHidden,
                  webView.window != nil,
                  let isolation,
                  let bridge,
                  let bridgeSession,
                  JSONSerialization.isValidJSONObject(message.body),
                  let data = try? JSONSerialization.data(withJSONObject: message.body)
            else {
                return (nil, "VNC bridge request was not trusted")
            }
            do {
                let request = try await isolation.validateMessage(
                    data,
                    frameURL: frameURL,
                    contentWorld: VNCIsolationPolicy.contentWorldName
                )
                guard let method = VNCBridgeMethod(rawValue: request.method) else {
                    throw VNCIsolationError.forbiddenMethod
                }
                let trigger = request.payload["trigger"].flatMap(VNCClipboardTrigger.init(rawValue:))
                let envelope = VNCBridgeEnvelope(
                    requestID: request.requestID,
                    sessionIdentifier: bridgeSession.identifier,
                    frameURL: frameURL,
                    origin: bridgeSession.origin,
                    sessionToken: bridgeSession.sessionToken,
                    generation: request.generation,
                    method: method,
                    visible: true,
                    clipboardTrigger: trigger
                )
                switch method {
                case .readClipboard:
                    return (try await bridge.readClipboard(envelope), nil)
                case .writeClipboard:
                    guard let text = request.payload["text"] else { throw VNCIsolationError.malformedMessage }
                    try await bridge.writeClipboard(text, envelope: envelope)
                    return (true, nil)
                case .reportUserPresence:
                    guard let raw = request.payload["isPresent"], let present = Bool(raw) else {
                        throw VNCIsolationError.malformedMessage
                    }
                    try await bridge.reportUserPresence(present, envelope: envelope)
                    return (true, nil)
                }
            } catch {
                return (nil, String(describing: error))
            }
        }

        private static func makePolicy(url: URL, token: String) -> VNCTrustPolicy {
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
                return VNCTrustPolicy(trustedHTTPSOrigins: [], sessionToken: token)
            }
            let port = url.port.map { ":\($0)" } ?? ""
            return VNCTrustPolicy(trustedHTTPSOrigins: ["https://\(host)\(port)"], sessionToken: token)
        }

        static func origin(of url: URL) -> String? {
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host?.lowercased() else { return nil }
            let isDefaultPort = (scheme == "https" && url.port == 443) || (scheme == "http" && url.port == 80)
            let port = url.port == nil || isDefaultPort ? "" : ":\(url.port!)"
            return "\(scheme)://\(host)\(port)"
        }

        nonisolated private static func nowMilliseconds() -> Int64 {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        }

        static func bridgeScript(generation: UInt64) -> String {
            """
            (() => {
              'use strict';
              const bridge = window.webkit.messageHandlers.\(messageHandlerName);
              const uuid = () => crypto.randomUUID();
              const call = (method, payload) => bridge.postMessage({
                version: 1, method, requestID: uuid(), generation: \(generation), payload
              });
              const reportPresence = (event) => {
                if (!event.isTrusted) return;
                void call('reportUserPresence', { isPresent: 'true' });
              };
              window.addEventListener('pointerdown', reportPresence, true);
              window.addEventListener('keydown', reportPresence, true);
              window.addEventListener('blur', () => { void call('reportUserPresence', { isPresent: 'false' }); });
              window.addEventListener('pagehide', () => { void call('reportUserPresence', { isPresent: 'false' }); });
              document.addEventListener('visibilitychange', () => {
                if (document.hidden) void call('reportUserPresence', { isPresent: 'false' });
              });
              document.addEventListener('paste', (event) => {
                if (!event.isTrusted) return;
                void call('readClipboard', { trigger: 'explicitGesture' }).then((text) => {
                  document.dispatchEvent(new CustomEvent('filicon:clipboard-read', { detail: { text } }));
                }).catch(() => {});
              }, true);
              document.addEventListener('copy', (event) => {
                if (!event.isTrusted) return;
                const text = String(window.getSelection()?.toString() ?? '');
                void call('writeClipboard', { text, trigger: 'explicitGesture' }).catch(() => {});
              }, true);
            })();
            """
        }
    }
}

private final class IsolatedVNCWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? ""
        if VNCHostShortcutRouter.shouldRouteToHost(
            key: key,
            command: flags.contains(.command),
            option: flags.contains(.option),
            control: flags.contains(.control)
        ) {
            if NSApplication.shared.mainMenu?.performKeyEquivalent(with: event) == true { return true }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
