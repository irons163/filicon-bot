import Testing
import Foundation
import FiliconComputer
import FiliconAccount
@testable import Filicon

@Suite("VNC WebView security integration")
struct VNCWebViewSecurityIntegrationTests {
    @Test @MainActor func bridgeUsesDedicatedContentWorldAndTrustedGestureScript() {
        let view = VNCWebView(
            url: URL(string: "https://computer.example/vnc.html?token=secret")!,
            sessionToken: "secret",
            accountID: "acct-exact",
            computerID: "computer-exact",
            onRendererCrash: {},
            onVisible: {}
        )
        let coordinator = view.makeCoordinator()
        #expect(coordinator.authorityIdentity.accountID == "acct-exact")
        #expect(coordinator.authorityIdentity.computerID == "computer-exact")
        #expect(coordinator.contentWorld.name == VNCIsolationPolicy.contentWorldName)
        let source = VNCWebView.Coordinator.bridgeScript(generation: 7)
        #expect(source.contains("generation: 7"))
        #expect(source.contains("event.isTrusted"))
        #expect(source.contains("explicitGesture"))
        #expect(source.contains("reportUserPresence"))
        #expect(source.contains("pointerdown"))
        #expect(source.contains("keydown"))
        #expect(source.contains("pagehide"))
        #expect(!source.contains("window.addEventListener('focus'"))
        #expect(!source.contains("visiblePoll"))
    }

    @Test @MainActor func connectionPinsExactAccountAndComputerAuthority() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "filicon-vnc-authority-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(applicationSupportRoot: root, bootstrapImmediately: false)
        let profile = try AccountProfile(id: "account-exact")
        model.accountState = .signedIn(AccountSession(profile: profile))

        await model.connectVNC(endpoint: "http://127.0.0.1:6080/vnc.html", sessionToken: "secret")

        #expect(model.activeVNCAccountID == "account-exact")
        #expect(model.activeVNCComputerID == model.vncComputerID)
        #expect(model.vncControlSnapshot?.owner == .user)
        await model.disconnectVNC()
    }

    @Test @MainActor func originCanonicalizationPinsSchemeHostAndPort() {
        #expect(VNCWebView.Coordinator.origin(of: URL(string: "https://Computer.Example:443/vnc.html")!) == "https://computer.example")
        #expect(VNCWebView.Coordinator.origin(of: URL(string: "http://127.0.0.1:6080/vnc.html")!) == "http://127.0.0.1:6080")
        #expect(VNCWebView.Coordinator.origin(of: URL(string: "file:///tmp/vnc.html")!) == nil)
    }
}
