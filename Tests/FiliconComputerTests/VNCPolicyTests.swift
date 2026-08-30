import Foundation
import XCTest
@testable import FiliconComputer

final class VNCPolicyTests: XCTestCase {
    func testAllowsLoopbackAndTrustedHTTPSOnlyWithSessionToken() {
        let policy = VNCTrustPolicy(trustedHTTPSOrigins: ["https://box.example"], sessionToken: "secret")
        XCTAssertEqual(
            policy.evaluate(URL(string: "http://127.0.0.1:6080/vnc.html?session_token=secret")!),
            .allowed(origin: "http://127.0.0.1:6080", sessionToken: "secret")
        )
        XCTAssertEqual(
            policy.evaluate(URL(string: "https://box.example/vnc.html?session_token=secret")!),
            .allowed(origin: "https://box.example", sessionToken: "secret")
        )
        XCTAssertEqual(policy.evaluate(URL(string: "http://box.example/vnc.html?session_token=secret")!), .denied(.untrustedOrigin))
        XCTAssertEqual(policy.evaluate(URL(string: "https://evil.example/vnc.html?session_token=secret")!), .denied(.untrustedOrigin))
    }

    func testRejectsMissingWrongTokenAndWrongEntryPage() {
        let policy = VNCTrustPolicy(trustedHTTPSOrigins: ["https://box.example"], sessionToken: "secret")
        XCTAssertEqual(policy.evaluate(URL(string: "https://box.example/vnc.html")!), .denied(.missingSessionToken))
        XCTAssertEqual(policy.evaluate(URL(string: "https://box.example/vnc.html?session_token=nope")!), .denied(.invalidSessionToken))
        XCTAssertEqual(policy.evaluate(URL(string: "https://box.example/index.html?session_token=secret")!), .denied(.invalidEntryPage))
    }

    func testLivenessRequiresThreeImpactfulInputsAndNoResponse() {
        var detector = VNCLivenessDetector()
        XCTAssertNil(detector.sample(at: 0, counters: .init(keys: 0, clicks: 0, moves: 0, drawOperations: 0, inboundBytes: 0)))
        XCTAssertNil(detector.sample(at: 5_000, counters: .init(keys: 1, clicks: 1, moves: 20, drawOperations: 0, inboundBytes: 0)))
        let report = detector.sample(at: 10_000, counters: .init(keys: 2, clicks: 1, moves: 40, drawOperations: 0, inboundBytes: 0))
        XCTAssertEqual(report?.keys, 2)
        XCTAssertEqual(report?.clicks, 1)
        XCTAssertNil(detector.sample(at: 11_000, counters: .init(keys: 3, clicks: 2, moves: 50, drawOperations: 0, inboundBytes: 0)))
    }

    func testLivenessDoesNotTripOnMovementOrResponsiveFrames() {
        var detector = VNCLivenessDetector()
        _ = detector.sample(at: 0, counters: .init(keys: 0, clicks: 0, moves: 0, drawOperations: 0, inboundBytes: 0))
        XCTAssertNil(detector.sample(at: 10_000, counters: .init(keys: 0, clicks: 0, moves: 100, drawOperations: 0, inboundBytes: 0)))
        XCTAssertNil(detector.sample(at: 11_000, counters: .init(keys: 2, clicks: 1, moves: 100, drawOperations: 1, inboundBytes: 10)))
    }

    func testInputThrottleUsesSourceIntervals() {
        var throttle = VNCInputThrottle()
        XCTAssertTrue(throttle.shouldEmit(.clipboard, at: 0))
        XCTAssertFalse(throttle.shouldEmit(.clipboard, at: 499))
        XCTAssertTrue(throttle.shouldEmit(.clipboard, at: 500))
        XCTAssertTrue(throttle.shouldEmit(.gesture, at: 0))
        XCTAssertFalse(throttle.shouldEmit(.gesture, at: 199))
        XCTAssertTrue(throttle.shouldEmit(.gesture, at: 200))
        XCTAssertTrue(throttle.shouldEmit(.telemetry, at: 0))
        XCTAssertFalse(throttle.shouldEmit(.telemetry, at: 999))
        XCTAssertTrue(throttle.shouldEmit(.telemetry, at: 1_000))
    }
}
