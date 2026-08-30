import Foundation
import XCTest
@testable import FiliconComputer

private actor ClipboardSpy {
    var text = "host"
    var reads = 0
    var writes: [String] = []
    func read() -> String { reads += 1; return text }
    func write(_ text: String) { writes.append(text); self.text = text }
    func counts() -> (Int, Int) { (reads, writes.count) }
}

final class VNCTrustedBridgeTests: XCTestCase {
    func testExactTrustClipboardBoundsVisibilityAndThrottle() async throws {
        let clock = ComputerTestMilliseconds()
        let clipboard = ClipboardSpy()
        let bridge = VNCTrustedBridge(clipboard: .init(readText: { await clipboard.read() }, writeText: { await clipboard.write($0) }), now: clock.now)
        let frame = URL(string: "https://box.example/vnc.html?session_token=secret")!
        let session = VNCBridgeSession(identifier: UUID(), exactFrameURL: frame, origin: "https://box.example", sessionToken: "secret", generation: 7)
        await bridge.install(session: session)

        let valid = envelope(session, frame: frame, method: .readClipboard, visible: true, trigger: .explicitGesture)
        let read = try await bridge.readClipboard(valid)
        XCTAssertEqual(read, "host")
        let counts = await clipboard.counts(); XCTAssertEqual(counts.0, 1)

        await XCTAssertThrowsComputerAsync { try await bridge.readClipboard(self.envelope(session, frame: frame, method: .readClipboard, visible: false, trigger: .visiblePoll)) }
        clock.advance(500)
        let write = envelope(session, frame: frame, method: .writeClipboard, visible: true, trigger: .focus)
        try await bridge.writeClipboard("guest", envelope: write)
        await XCTAssertThrowsComputerAsync { try await bridge.writeClipboard("again", envelope: self.envelope(session, frame: frame, method: .writeClipboard, visible: true, trigger: .focus)) }
        clock.advance(500)
        await XCTAssertThrowsComputerAsync {
            try await bridge.writeClipboard(String(repeating: "x", count: VNCTrustedBridge.maximumClipboardBytes + 1), envelope: self.envelope(session, frame: frame, method: .writeClipboard, visible: true, trigger: .focus))
        }
    }

    func testFrameOriginTokenGenerationAndReplayAreRejected() async throws {
        let clock = ComputerTestMilliseconds()
        let clipboard = ClipboardSpy()
        let bridge = VNCTrustedBridge(clipboard: .init(readText: { await clipboard.read() }, writeText: { await clipboard.write($0) }), now: clock.now)
        let frame = URL(string: "https://box.example/vnc.html?session_token=secret")!
        let session = VNCBridgeSession(identifier: UUID(), exactFrameURL: frame, origin: "https://box.example", sessionToken: "secret", generation: 2)
        await bridge.install(session: session)
        await XCTAssertThrowsComputerAsync { try await bridge.readClipboard(self.envelope(session, frame: URL(string: "https://box.example/vnc.html?session_token=secret#changed")!, method: .readClipboard, visible: true, trigger: .focus)) }
        var wrong = envelope(session, frame: frame, method: .readClipboard, visible: true, trigger: .focus, origin: "https://evil.example")
        await XCTAssertThrowsComputerAsync { try await bridge.readClipboard(wrong) }
        wrong = envelope(session, frame: frame, method: .readClipboard, visible: true, trigger: .focus, token: "wrong")
        await XCTAssertThrowsComputerAsync { try await bridge.readClipboard(wrong) }
        wrong = envelope(session, frame: frame, method: .readClipboard, visible: true, trigger: .focus, generation: 1)
        await XCTAssertThrowsComputerAsync { try await bridge.readClipboard(wrong) }
        let replay = envelope(session, frame: frame, method: .readClipboard, visible: true, trigger: .focus)
        _ = try await bridge.readClipboard(replay)
        await XCTAssertThrowsComputerAsync { try await bridge.readClipboard(replay) }
    }

    func testPresenceAndHostShortcutsNeverReachGuest() async throws {
        let presence = PresenceSpy()
        let bridge = VNCTrustedBridge(clipboard: .init(readText: { "" }, writeText: { _ in }), now: { 0 }, onUserPresence: { await presence.record($0) })
        let frame = URL(string: "https://box.example/vnc.html?session_token=t")!
        let session = VNCBridgeSession(identifier: UUID(), exactFrameURL: frame, origin: "https://box.example", sessionToken: "t", generation: 1)
        await bridge.install(session: session)
        try await bridge.reportUserPresence(true, envelope: envelope(session, frame: frame, method: .reportUserPresence, visible: true, trigger: nil))
        let values = await presence.values()
        XCTAssertEqual(values, [true])
        XCTAssertTrue(VNCHostShortcutRouter.shouldRouteToHost(key: "q", command: true))
        XCTAssertTrue(VNCHostShortcutRouter.shouldRouteToHost(key: "ArrowLeft", command: true, option: true))
        XCTAssertFalse(VNCHostShortcutRouter.shouldRouteToHost(key: "a", command: false))
    }

    func testSessionCanOnlyBeMintedFromTrustedPolicyAndIncreasingGeneration() async throws {
        let bridge = VNCTrustedBridge(clipboard: .init(readText: { "" }, writeText: { _ in }), now: { 0 })
        let frame = URL(string: "https://box.example/vnc.html?session_token=secret")!
        let policy = VNCTrustPolicy(trustedHTTPSOrigins: ["https://box.example"], sessionToken: "secret")
        let installed = try await bridge.install(frameURL: frame, trustPolicy: policy, generation: 1)
        XCTAssertEqual(installed.exactFrameURL, frame)
        await XCTAssertThrowsComputerAsync { _ = try await bridge.install(frameURL: frame, trustPolicy: policy, generation: 1) }
        await XCTAssertThrowsComputerAsync {
            _ = try await bridge.install(frameURL: URL(string: "https://evil.example/vnc.html?session_token=secret")!, trustPolicy: policy, generation: 2)
        }
    }

    private func envelope(_ session: VNCBridgeSession, frame: URL, method: VNCBridgeMethod, visible: Bool, trigger: VNCClipboardTrigger?, origin: String? = nil, token: String? = nil, generation: UInt64? = nil) -> VNCBridgeEnvelope {
        .init(requestID: UUID(), sessionIdentifier: session.identifier, frameURL: frame, origin: origin ?? session.origin, sessionToken: token ?? session.sessionToken, generation: generation ?? session.generation, method: method, visible: visible, clipboardTrigger: trigger)
    }
}

private actor PresenceSpy {
    private var recorded: [Bool] = []
    func record(_ value: Bool) { recorded.append(value) }
    func values() -> [Bool] { recorded }
}
