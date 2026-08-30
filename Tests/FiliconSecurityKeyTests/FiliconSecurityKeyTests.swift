import Foundation
import XCTest
@testable import FiliconSecurityKey

final class FiliconSecurityKeyTests: XCTestCase {
    func testReferenceTimingContract() {
        XCTAssertEqual(SecurityKeyCoordinator.ceremonyDeadlineMilliseconds, 120_000)
        XCTAssertEqual(RemoteSecurityKeyProxy.heartbeatMilliseconds, 10_000)
    }

    func testRequestAndResponseFramesUseGatewayWireShape() throws {
        let request = RemoteSecurityKeyRequestFrame.welcome(providerID: "provider-1")
        let requestJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(requestJSON["kind"] as? String, "welcome")
        XCTAssertEqual(requestJSON["providerId"] as? String, "provider-1")

        let response = RemoteSecurityKeyResponseFrame.hello(computerID: "mac-1", label: "Desk Mac")
        let responseJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        XCTAssertEqual(responseJSON["kind"] as? String, "hello")
        XCTAssertEqual(responseJSON["computerId"] as? String, "mac-1")
        XCTAssertEqual(responseJSON["label"] as? String, "Desk Mac")
    }

    func testValidationRejectsUnsafeChallengeAndRequestSize() {
        XCTAssertThrowsError(try SecurityKeyValidation.validate(ceremony(challenge: Data(repeating: 1, count: 15)))) {
            XCTAssertEqual($0 as? SecurityKeyError, .challengeOutOfBounds)
        }
        XCTAssertThrowsError(try SecurityKeyValidation.validate(ceremony(), encodedBytes: SecurityKeyValidation.maximumRequestBytes + 1)) {
            XCTAssertEqual($0 as? SecurityKeyError, .requestTooLarge(limit: SecurityKeyValidation.maximumRequestBytes))
            XCTAssertTrue($0.localizedDescription.contains("131072"))
        }
    }

    func testValidationRejectsOriginRPIDMismatchAndNonHTTPS() {
        XCTAssertThrowsError(try SecurityKeyValidation.validate(ceremony(origin: "http://login.example.com", rpID: "example.com"))) {
            XCTAssertEqual($0 as? SecurityKeyError, .invalidOrigin)
        }
        XCTAssertThrowsError(try SecurityKeyValidation.validate(ceremony(origin: "https://attacker.example", rpID: "example.com"))) {
            XCTAssertEqual($0 as? SecurityKeyError, .invalidRPID)
        }
        XCTAssertNoThrow(try SecurityKeyValidation.validate(ceremony(origin: "https://login.example.com", rpID: "example.com")))
    }

    func testDisabledFailsClosedWithoutConsentOrProvider() async {
        let provider = RecordingProvider(result: .success(response()))
        let consent = RecordingConsent(approved: true)
        let coordinator = SecurityKeyCoordinator(enabled: false, provider: provider, consent: consent)
        let frames = await coordinator.run(requestID: "request-1", ceremony: ceremony())
        XCTAssertEqual(errorCode(frames), "disabled")
        let performs = await provider.performCount()
        let requests = await consent.requestCount()
        XCTAssertEqual(performs, 0)
        XCTAssertEqual(requests, 0)
    }

    func testExplicitConsentDisplaysOriginAndRPIDAndDeclineStopsProvider() async {
        let provider = RecordingProvider(result: .success(response()))
        let consent = RecordingConsent(approved: false)
        let coordinator = SecurityKeyCoordinator(enabled: true, provider: provider, consent: consent)
        let frames = await coordinator.run(requestID: "request-2", ceremony: ceremony())
        let seen = await consent.lastConsent()
        XCTAssertEqual(seen?.origin, "https://login.example.com")
        XCTAssertEqual(seen?.rpID, "example.com")
        XCTAssertEqual(errorCode(frames), "invalid_or_unavailable")
        let performs = await provider.performCount()
        XCTAssertEqual(performs, 0)
        XCTAssertTrue(frames.contains(.stage(requestID: "request-2", stage: "grant", outcome: "declined")))
    }

    func testSuccessfulExternalProviderCeremonyReportsProgressAndResult() async {
        let provider = RecordingProvider(result: .success(response()), statuses: [.waitingForPresence, .waitingForSystemPIN])
        let consent = RecordingConsent(approved: true)
        let statuses = StatusRecorder()
        let coordinator = SecurityKeyCoordinator(
            enabled: true, provider: provider, consent: consent, clock: NeverClock(),
            status: { await statuses.append($0) }
        )
        let frames = await coordinator.run(requestID: "request-3", ceremony: ceremony())
        XCTAssertTrue(frames.contains(.stage(requestID: "request-3", stage: "grant", outcome: "ok")))
        XCTAssertTrue(frames.contains(.stage(requestID: "request-3", stage: "sign", outcome: "ok")))
        XCTAssertTrue(frames.contains(.result(requestID: "request-3", credential: response())))
        let values = await statuses.values()
        XCTAssertTrue(values.contains(.waitingForPresence))
        XCTAssertTrue(values.contains(.waitingForSystemPIN))
        XCTAssertTrue(values.contains(.completed))
    }

    func testRequestIDReplayIsRejected() async {
        let provider = RecordingProvider(result: .success(response()))
        let coordinator = SecurityKeyCoordinator(enabled: true, provider: provider, consent: RecordingConsent(approved: true), clock: NeverClock())
        _ = await coordinator.run(requestID: "same-id", ceremony: ceremony())
        let replay = await coordinator.run(requestID: "same-id", ceremony: ceremony())
        XCTAssertEqual(errorCode(replay), "replay")
        let performs = await provider.performCount()
        XCTAssertEqual(performs, 1)
    }

    func testDeadlineCancelsProviderAndFailsClosed() async {
        let provider = BlockingProvider()
        let coordinator = SecurityKeyCoordinator(enabled: true, provider: provider, consent: RecordingConsent(approved: true), clock: ImmediateClock())
        let frames = await coordinator.run(requestID: "timeout", ceremony: ceremony())
        XCTAssertEqual(errorCode(frames), "timeout")
        let cancels = await provider.cancelCount()
        XCTAssertGreaterThanOrEqual(cancels, 1)
    }

    func testInvalidateFencesAnInFlightGeneration() async {
        let provider = BlockingProvider()
        let coordinator = SecurityKeyCoordinator(enabled: true, provider: provider, consent: RecordingConsent(approved: true), clock: NeverClock())
        let value = ceremony()
        let task = Task { await coordinator.run(requestID: "stale", ceremony: value) }
        await waitUntil { await provider.performCount() == 1 }
        await coordinator.invalidate(reason: .disconnected)
        let frames = await task.value
        XCTAssertTrue(["stale_generation", "cancelled"].contains(errorCode(frames)))
        let cancels = await provider.cancelCount()
        XCTAssertGreaterThanOrEqual(cancels, 1)
    }

    func testSecondConcurrentCeremonyFailsClosedWithoutCrossingProviderState() async {
        let provider = BlockingProvider()
        let coordinator = SecurityKeyCoordinator(enabled: true, provider: provider, consent: RecordingConsent(approved: true), clock: NeverClock())
        let firstValue = ceremony()
        let first = Task { await coordinator.run(requestID: "first", ceremony: firstValue) }
        await waitUntil { await provider.performCount() == 1 }
        let second = await coordinator.run(requestID: "second", ceremony: ceremony())
        XCTAssertEqual(errorCode(second), "invalid_or_unavailable")
        let performs = await provider.performCount()
        XCTAssertEqual(performs, 1)
        await coordinator.cancel(requestID: "first")
        _ = await first.value
    }

    func testHTTPSBackendFailsClosedForUnconfiguredOrUnsafeEndpoint() {
        XCTAssertThrowsError(try HTTPSRemoteSecurityKeyBackend(baseURL: URL(string: "http://example.com")!) { "token" })
        XCTAssertThrowsError(try HTTPSRemoteSecurityKeyBackend(baseURL: URL(string: "https://user@example.com")!) { "token" })
        XCTAssertNoThrow(try HTTPSRemoteSecurityKeyBackend(baseURL: URL(string: "https://example.com/api")!) { "keychain-token" })
    }

    func testRemoteProxySendsHelloHeartbeatAndHandbackCancelsCeremony() async {
        let backend = RecordingBackend()
        let provider = BlockingProvider()
        let clock = PulseClock()
        let coordinator = SecurityKeyCoordinator(
            enabled: true, provider: provider, consent: RecordingConsent(approved: true), clock: NeverClock()
        )
        let proxy = RemoteSecurityKeyProxy(
            enabled: true, backend: backend, coordinator: coordinator, clock: clock,
            computerID: "mac-1", label: "Desk Mac"
        )
        await proxy.start()
        await waitUntil { await backend.connectionCount() == 1 }
        await backend.yield(.welcome(providerID: "provider-1"))
        await waitUntil {
            await backend.sentFrames().contains(.hello(computerID: "mac-1", label: "Desk Mac"))
        }
        await clock.pulse()
        await waitUntil { await backend.sentFrames().contains(.ping) }
        await backend.yield(.ceremony(requestID: "remote-request", ceremony: self.ceremony()))
        await waitUntil { await provider.performCount() == 1 }

        await proxy.handback()
        let providerCancels = await provider.cancelCount()
        let backendCancels = await backend.cancelCount()
        XCTAssertGreaterThanOrEqual(providerCancels, 1)
        XCTAssertGreaterThanOrEqual(backendCancels, 1)
    }

    func testRemoteProxyReconnectsAfterBackendFailure() async {
        let backend = RecordingBackend(failFirstConnection: true)
        let clock = PulseClock()
        let statuses = StatusRecorder()
        let coordinator = SecurityKeyCoordinator(
            enabled: true,
            provider: RecordingProvider(result: .success(response())),
            consent: RecordingConsent(approved: true),
            clock: NeverClock()
        )
        let proxy = RemoteSecurityKeyProxy(
            enabled: true, backend: backend, coordinator: coordinator, clock: clock,
            status: { await statuses.append($0) }
        )
        await proxy.start()
        await waitUntil { await backend.connectionCount() == 1 }
        await clock.pulse()
        await waitUntil { await backend.connectionCount() == 2 }
        let values = await statuses.values()
        XCTAssertTrue(values.contains(.reconnecting(attempt: 1)))
        await proxy.handback()
    }

    private func ceremony(
        challenge: Data = Data(repeating: 7, count: 32),
        origin: String = "https://login.example.com",
        rpID: String = "example.com"
    ) -> SecurityKeyCeremony {
        SecurityKeyCeremony(kind: .get, origin: origin, rpID: rpID, challenge: challenge)
    }

    private func response() -> SecurityKeyCredentialResponse {
        .assertion(id: Data([1]), clientDataJSON: Data([2]), authenticatorData: Data([3]), signature: Data([4]), userHandle: nil)
    }

    private func errorCode(_ frames: [RemoteSecurityKeyResponseFrame]) -> String? {
        for case .error(_, _, _, let code) in frames { return code }
        return nil
    }

    private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true")
    }
}

private actor RecordingProvider: HardwareSecurityKeyProvider {
    private let result: Result<SecurityKeyCredentialResponse, Error>
    private let statuses: [SecurityKeyStatus]
    private var performs = 0
    private var cancels = 0

    init(result: Result<SecurityKeyCredentialResponse, Error>, statuses: [SecurityKeyStatus] = []) {
        self.result = result
        self.statuses = statuses
    }

    func perform(_ ceremony: SecurityKeyCeremony, status: @escaping @Sendable (SecurityKeyStatus) async -> Void) async throws -> SecurityKeyCredentialResponse {
        performs += 1
        for value in statuses { await status(value) }
        return try result.get()
    }

    func cancel() { cancels += 1 }
    func performCount() -> Int { performs }
    func cancelCount() -> Int { cancels }
}

private actor BlockingProvider: HardwareSecurityKeyProvider {
    private var performs = 0
    private var cancels = 0
    private var continuation: CheckedContinuation<SecurityKeyCredentialResponse, Error>?

    func perform(_ ceremony: SecurityKeyCeremony, status: @escaping @Sendable (SecurityKeyStatus) async -> Void) async throws -> SecurityKeyCredentialResponse {
        performs += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.resolveCancellation() }
        }
    }

    func cancel() { cancels += 1; resolveCancellation() }
    private func resolveCancellation() {
        let value = continuation
        continuation = nil
        value?.resume(throwing: SecurityKeyError.cancelled)
    }
    func performCount() -> Int { performs }
    func cancelCount() -> Int { cancels }
}

private actor RecordingConsent: SecurityKeyConsentProvider {
    private let approved: Bool
    private var requests: [SecurityKeyConsent] = []
    init(approved: Bool) { self.approved = approved }
    func requestConsent(_ consent: SecurityKeyConsent) -> Bool { requests.append(consent); return approved }
    func dismissConsent(requestID: String) {}
    func requestCount() -> Int { requests.count }
    func lastConsent() -> SecurityKeyConsent? { requests.last }
}

private actor StatusRecorder {
    private var recorded: [SecurityKeyStatus] = []
    func append(_ value: SecurityKeyStatus) { recorded.append(value) }
    func values() -> [SecurityKeyStatus] { recorded }
}

private struct NeverClock: SecurityKeyClock {
    func sleep(milliseconds: Int64) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private struct ImmediateClock: SecurityKeyClock {
    func sleep(milliseconds: Int64) async throws {}
}

private actor RecordingBackend: RemoteSecurityKeyBackend {
    private var continuation: AsyncThrowingStream<RemoteSecurityKeyRequestFrame, Error>.Continuation?
    private var sent: [RemoteSecurityKeyResponseFrame] = []
    private var connections = 0
    private var cancels = 0
    private let failFirstConnection: Bool

    init(failFirstConnection: Bool = false) {
        self.failFirstConnection = failFirstConnection
    }

    func connect() throws -> RemoteSecurityKeySession {
        connections += 1
        if failFirstConnection && connections == 1 { throw SecurityKeyError.backendUnavailable }
        let (stream, continuation) = AsyncThrowingStream<RemoteSecurityKeyRequestFrame, Error>.makeStream()
        self.continuation = continuation
        return RemoteSecurityKeySession(
            frames: stream,
            send: { frames, _ in await self.record(frames) },
            cancel: { await self.cancelSession() }
        )
    }

    func yield(_ frame: RemoteSecurityKeyRequestFrame) { continuation?.yield(frame) }
    func sentFrames() -> [RemoteSecurityKeyResponseFrame] { sent }
    func connectionCount() -> Int { connections }
    func cancelCount() -> Int { cancels }
    private func record(_ frames: [RemoteSecurityKeyResponseFrame]) { sent.append(contentsOf: frames) }
    private func cancelSession() { cancels += 1; continuation?.finish(); continuation = nil }
}

private actor PulseClock: SecurityKeyClock {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func sleep(milliseconds: Int64) async throws {
        var iterator = stream.makeAsyncIterator()
        guard await iterator.next() != nil else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func pulse() { continuation.yield(()) }
}
